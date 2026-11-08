"""One cross-task flow through the real API: account -> snapshot ->
dashboard -> drift -> to-do, with non-USD (CAD) money throughout."""

import pytest


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
