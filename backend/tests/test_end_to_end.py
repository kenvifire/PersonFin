"""Cross-task flows through the real API:

- account -> snapshot -> dashboard -> drift -> to-do, with non-USD (CAD)
  money throughout.
- account -> screenshot upload -> extract -> confirm -> dashboard: the
  vision pipeline's output landing in Plan 1's read path.
"""

from datetime import date

import pytest

from app.main import app
from app.schemas.extraction import DraftHolding, ExtractionResult
from app.services import vision
from conftest import FakeVisionExtractor


def test_upload_extract_confirm_snapshot_shows_on_dashboard(client, auth_header_for):
    headers = auth_header_for("e2e-upload@example.com")

    # 1. Account to upload against.
    account = client.post(
        "/accounts",
        json={"name": "RRSP", "institution": "Royal Bank of Canada", "account_type": "rrsp"},
        headers=headers,
    )
    assert account.status_code == 201
    account_id = account.json()["id"]

    # 2. Screenshot upload.
    upload = client.post("/uploads", files={"file": ("rrsp.png", b"fake-png-bytes", "image/png")}, headers=headers)
    assert upload.status_code == 201
    upload_id = upload.json()["id"]

    # 3. Extraction (fake extractor standing in for Azure).
    extraction = ExtractionResult(
        institution="RBC Royal Bank",
        account_label="RRSP",
        account_type_guess="rrsp",
        taken_at_guess=date(2026, 11, 8),
        holdings=[
            DraftHolding(label="XEQT", asset_class_guess="equity", quantity=20, value=750.0, currency_guess="CAD", country_guess="CA"),
            DraftHolding(label="Cash", asset_class_guess="cash", quantity=None, value=250.0, currency_guess="CAD", country_guess="CA"),
        ],
    )
    app.dependency_overrides[vision.get_vision_extractor] = lambda: FakeVisionExtractor(result=extraction)
    extracted = client.post(f"/uploads/{upload_id}/extract", headers=headers)
    del app.dependency_overrides[vision.get_vision_extractor]
    assert extracted.status_code == 200
    extracted_body = extracted.json()
    assert extracted_body["status"] == "extracted"

    # 4. The review step reads the full record, including the suggested
    #    account match, from the detail endpoint.
    review = client.get(f"/uploads/{upload_id}", headers=headers).json()
    assert review["suggested_account_id"] == account_id

    # 5. Confirm the (unedited) draft against the suggested account.
    draft = review["extracted_payload"]
    confirmed = client.post(
        f"/uploads/{upload_id}/confirm",
        json={
            "account_id": review["suggested_account_id"],
            "new_account": None,
            "taken_at": draft["taken_at_guess"],
            "holdings": [
                {
                    "label": h["label"],
                    "asset_class": h["asset_class_guess"],
                    "quantity": h["quantity"],
                    "value": h["value"],
                    "currency": h["currency_guess"],
                    "country": h["country_guess"],
                }
                for h in draft["holdings"]
            ],
        },
        headers=headers,
    )
    assert confirmed.status_code == 201

    # 6. The snapshot is visible through Plan 1's dashboard, outside the
    #    uploads router entirely.
    dashboard = client.get("/dashboard?currency=CAD", headers=headers)
    assert dashboard.status_code == 200
    body = dashboard.json()
    assert body["net_worth"] == pytest.approx(1000.0)
    assert body["by_asset_class"] == {"equity": pytest.approx(750.0), "cash": pytest.approx(250.0)}
    assert body["by_country"] == {"CA": pytest.approx(1000.0)}
    assert [(a["account_id"], a["as_of"]) for a in body["accounts"]] == [(account_id, "2026-11-08")]
    assert [p["taken_at"] for p in body["trend"]] == ["2026-11-08"]

    # 7. And the upload records the link to that snapshot.
    detail = client.get(f"/uploads/{upload_id}", headers=headers).json()
    assert detail["status"] == "confirmed"
    assert detail["snapshot_id"] == confirmed.json()["id"]
    assert detail["matched_account_id"] == account_id


def test_cad_account_to_drift_flag_to_todo(client, auth_header_for):
    headers = auth_header_for("e2e@example.com")

    # 1. Account.
    account = client.post(
        "/accounts",
        json={"name": "Questrade TFSA", "institution": "Questrade", "account_type": "brokerage"},
        headers=headers,
    )
    assert account.status_code == 201
    account_id = account.json()["id"]

    # 2. CAD-denominated snapshot, skewed toward crypto and holding no
    #    bonds: equity 60%, cash 20%, crypto 20%, bond 0%.
    snapshot = client.post(
        f"/accounts/{account_id}/snapshots",
        json={
            "taken_at": "2026-11-08",
            "holdings": [
                {"label": "XEQT", "asset_class": "equity", "quantity": 20, "value": 600.0, "currency": "CAD", "country": "CA"},
                {"label": "Cash", "asset_class": "cash", "quantity": None, "value": 200.0, "currency": "CAD", "country": "CA"},
                {"label": "BTCX", "asset_class": "crypto", "quantity": 5, "value": 200.0, "currency": "CAD", "country": "CA"},
            ],
        },
        headers=headers,
    )
    assert snapshot.status_code == 201
    assert sum(h["value_usd"] for h in snapshot.json()["holdings"]) == pytest.approx(720.0)  # 1000 CAD @ 0.72

    # 3. Dashboard in CAD round-trips the locked USD values back to CAD.
    dashboard = client.get("/dashboard?currency=CAD", headers=headers)
    assert dashboard.status_code == 200
    body = dashboard.json()
    assert body["currency"] == "CAD"
    assert body["net_worth"] == pytest.approx(1000.0)
    assert body["by_asset_class"] == {
        "equity": pytest.approx(600.0),
        "cash": pytest.approx(200.0),
        "crypto": pytest.approx(200.0),
    }
    assert body["by_country"] == {"CA": pytest.approx(1000.0)}
    assert [(a["account_id"], a["as_of"]) for a in body["accounts"]] == [(account_id, "2026-11-08")]
    assert [p["taken_at"] for p in body["trend"]] == ["2026-11-08"]
    assert body["trend"][0]["net_worth"] == pytest.approx(1000.0)

    # 4. Drift against the default targets (equity 60, cash 20, crypto 10,
    #    bond 10): crypto is 10 points over, bond 10 points under.
    drift = client.get("/targets/drift?currency=CAD", headers=headers)
    assert drift.status_code == 200
    flags = {flag["asset_class"]: flag for flag in drift.json()}
    assert set(flags) == {"crypto", "bond"}
    assert flags["crypto"]["actual_pct"] == pytest.approx(20.0)
    assert flags["crypto"]["delta_pct"] == pytest.approx(10.0)
    assert flags["bond"]["actual_pct"] == pytest.approx(0.0)
    assert flags["bond"]["delta_pct"] == pytest.approx(-10.0)

    # 5. To-do raised from the crypto flag.
    crypto_flag = flags["crypto"]
    todo = client.post(
        "/todos",
        json={
            "description": f"Trim crypto from {crypto_flag['actual_pct']:.0f}% to {crypto_flag['target_pct']:.0f}%",
            "related_asset_class": crypto_flag["asset_class"],
        },
        headers=headers,
    )
    assert todo.status_code == 201

    # 6. It's listed as open.
    todos = client.get("/todos", headers=headers)
    assert todos.status_code == 200
    assert [(t["id"], t["description"], t["related_asset_class"], t["done"]) for t in todos.json()] == [
        (todo.json()["id"], "Trim crypto from 20% to 10%", "crypto", False)
    ]
