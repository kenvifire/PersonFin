import pytest


def test_create_snapshot_locks_usd_value(client, auth_header_for):
    headers = auth_header_for("a@example.com")
    account_id = client.post("/accounts", json={"name": "Wealthsimple", "institution": "Wealthsimple", "account_type": "brokerage"}, headers=headers).json()["id"]

    response = client.post(
        f"/accounts/{account_id}/snapshots",
        json={"taken_at": "2026-11-08", "holdings": [
            {"label": "VFV", "asset_class": "equity", "quantity": 10, "value": 1000.0, "currency": "CAD", "country": "CA"}
        ]},
        headers=headers,
    )
    assert response.status_code == 201
    holding = response.json()["holdings"][0]
    assert holding["currency"] == "CAD"
    assert holding["value_usd"] == pytest.approx(holding["value"] * holding["fx_rate_to_usd"])


def test_create_snapshot_rejects_negative_value(client, auth_header_for):
    headers = auth_header_for("a@example.com")
    account_id = client.post("/accounts", json={"name": "Binance", "institution": "Binance", "account_type": "crypto"}, headers=headers).json()["id"]
    response = client.post(
        f"/accounts/{account_id}/snapshots",
        json={"taken_at": "2026-11-08", "holdings": [{"label": "BTC", "asset_class": "crypto", "quantity": 1, "value": -5.0, "currency": "CRYPTO", "country": "CA"}]},
        headers=headers,
    )
    assert response.status_code == 422


def test_create_snapshot_for_other_users_account_is_404(client, auth_header_for):
    headers_a = auth_header_for("a@example.com")
    headers_b = auth_header_for("b@example.com")
    account_id = client.post("/accounts", json={"name": "RBC", "institution": "RBC", "account_type": "cash"}, headers=headers_a).json()["id"]
    response = client.post(f"/accounts/{account_id}/snapshots", json={"taken_at": "2026-11-08", "holdings": []}, headers=headers_b)
    assert response.status_code == 404


def test_create_snapshot_rejects_unrecognized_currency(client, auth_header_for):
    headers = auth_header_for("a@example.com")
    account_id = client.post("/accounts", json={"name": "RBC", "institution": "RBC", "account_type": "cash"}, headers=headers).json()["id"]
    response = client.post(
        f"/accounts/{account_id}/snapshots",
        json={"taken_at": "2026-11-08", "holdings": [{"label": "Cash", "asset_class": "cash", "quantity": None, "value": 100.0, "currency": "ZZZ", "country": "CA"}]},
        headers=headers,
    )
    assert response.status_code == 422


def test_two_snapshots_same_date_both_kept(client, auth_header_for):
    headers = auth_header_for("a@example.com")
    account_id = client.post("/accounts", json={"name": "RBC", "institution": "RBC", "account_type": "cash"}, headers=headers).json()["id"]
    payload = {"taken_at": "2026-11-08", "holdings": [{"label": "Cash", "asset_class": "cash", "quantity": None, "value": 100.0, "currency": "USD", "country": "CA"}]}

    first = client.post(f"/accounts/{account_id}/snapshots", json=payload, headers=headers)
    second = client.post(f"/accounts/{account_id}/snapshots", json=payload, headers=headers)
    assert first.status_code == 201
    assert second.status_code == 201
    assert first.json()["id"] != second.json()["id"]
