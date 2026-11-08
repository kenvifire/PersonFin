import pytest

from conftest import FailingFXRateProvider, FakeFXRateProvider


def _cash_snapshot(taken_at: str, value: float, currency: str = "USD") -> dict:
    return {
        "taken_at": taken_at,
        "holdings": [
            {"label": "Cash", "asset_class": "cash", "quantity": None, "value": value, "currency": currency, "country": "CA"}
        ],
    }


def _create_account(client, headers, name: str) -> int:
    response = client.post("/accounts", json={"name": name, "institution": name, "account_type": "cash"}, headers=headers)
    assert response.status_code == 201
    return response.json()["id"]


def _post_snapshot(client, headers, account_id: int, payload: dict) -> None:
    response = client.post(f"/accounts/{account_id}/snapshots", json=payload, headers=headers)
    assert response.status_code == 201, response.text


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


def test_trend_carries_each_accounts_latest_value_forward(client, auth_header_for):
    """Two accounts updated on different dates: an account's latest
    value as of each date carries forward, and an account with no
    snapshot yet contributes 0."""
    headers = auth_header_for("trend@example.com")
    bank = _create_account(client, headers, "Bank")
    broker = _create_account(client, headers, "Broker")

    _post_snapshot(client, headers, bank, _cash_snapshot("2026-10-01", 1000.0))
    _post_snapshot(client, headers, broker, _cash_snapshot("2026-10-15", 500.0))
    _post_snapshot(client, headers, bank, _cash_snapshot("2026-11-01", 1200.0))

    body = client.get("/dashboard?currency=USD", headers=headers).json()

    assert [(point["taken_at"], point["net_worth"]) for point in body["trend"]] == [
        ("2026-10-01", 1000.0),  # broker doesn't exist yet -> contributes 0
        ("2026-10-15", 1500.0),  # bank's 1000 carries forward + broker 500
        ("2026-11-01", 1700.0),  # bank's new 1200 + broker's 500 carried forward
    ]
    # The latest trend point is the current net worth.
    assert body["trend"][-1]["net_worth"] == body["net_worth"]


def test_trend_does_not_double_count_same_day_snapshots(client, auth_header_for):
    """One account uploading twice on the same date: only the later of
    the two counts for that date, never their sum."""
    headers = auth_header_for("sameday@example.com")
    bank = _create_account(client, headers, "Bank")
    broker = _create_account(client, headers, "Broker")

    _post_snapshot(client, headers, broker, _cash_snapshot("2026-10-01", 300.0))
    _post_snapshot(client, headers, bank, _cash_snapshot("2026-11-08", 100.0))
    _post_snapshot(client, headers, bank, _cash_snapshot("2026-11-08", 250.0))  # correction, same day

    body = client.get("/dashboard?currency=USD", headers=headers).json()

    assert [(point["taken_at"], point["net_worth"]) for point in body["trend"]] == [
        ("2026-10-01", 300.0),
        ("2026-11-08", 550.0),  # 250 (bank's latest that day) + 300 (broker), not 100 + 250 + 300
    ]
    assert body["net_worth"] == 550.0


def test_dashboard_converts_all_amounts_with_one_fx_lookup(client, auth_header_for, use_fx_provider):
    headers = auth_header_for("onefx@example.com")
    bank = _create_account(client, headers, "Bank")
    broker = _create_account(client, headers, "Broker")
    _post_snapshot(client, headers, bank, _cash_snapshot("2026-10-01", 720.0))
    _post_snapshot(client, headers, broker, _cash_snapshot("2026-10-15", 72.0))
    _post_snapshot(client, headers, bank, _cash_snapshot("2026-11-01", 144.0))

    provider = use_fx_provider(FakeFXRateProvider())
    response = client.get("/dashboard?currency=CAD", headers=headers)

    assert response.status_code == 200
    assert provider.calls == [("USD", "CAD")]
    body = response.json()
    assert body["net_worth"] == pytest.approx(300.0)  # (144 + 72) USD / 0.72
    assert [point["net_worth"] for point in body["trend"]] == pytest.approx([1000.0, 1100.0, 300.0])
    assert body["by_asset_class"] == {"cash": pytest.approx(300.0)}


def test_dashboard_returns_503_when_fx_is_unavailable(client, auth_header_for, use_fx_provider):
    headers = auth_header_for("fxdown@example.com")
    account_id = _create_account(client, headers, "Bank")
    _post_snapshot(client, headers, account_id, _cash_snapshot("2026-11-08", 100.0))

    use_fx_provider(FailingFXRateProvider())
    response = client.get("/dashboard?currency=CAD", headers=headers)

    assert response.status_code == 503
    assert response.json() == {"detail": "Exchange rate temporarily unavailable, try again shortly"}
