def test_dashboard_for_new_user_is_empty(client, auth_header_for):
    headers = auth_header_for("new@example.com")
    response = client.get("/dashboard?currency=USD", headers=headers)
    assert response.status_code == 200
    body = response.json()
    assert body["net_worth"] == 0.0
    assert body["by_asset_class"] == {}
    assert body["accounts"] == []


def test_dashboard_sums_latest_snapshot_per_account(client, auth_header_for):
    headers = auth_header_for("a@example.com")
    account_id = client.post("/accounts", json={"name": "RBC", "institution": "RBC", "account_type": "cash"}, headers=headers).json()["id"]
    client.post(f"/accounts/{account_id}/snapshots", json={"taken_at": "2026-10-01", "holdings": [{"label": "Cash", "asset_class": "cash", "quantity": None, "value": 500.0, "currency": "USD", "country": "CA"}]}, headers=headers)
    client.post(f"/accounts/{account_id}/snapshots", json={"taken_at": "2026-11-08", "holdings": [{"label": "Cash", "asset_class": "cash", "quantity": None, "value": 800.0, "currency": "USD", "country": "CA"}]}, headers=headers)

    response = client.get("/dashboard?currency=USD", headers=headers)
    body = response.json()
    assert body["net_worth"] == 800.0  # latest snapshot only, not summed across both
    assert len(body["trend"]) == 2


def test_dashboard_rejects_unsupported_currency(client, auth_header_for):
    headers = auth_header_for("a@example.com")
    response = client.get("/dashboard?currency=XYZ", headers=headers)
    assert response.status_code == 422
