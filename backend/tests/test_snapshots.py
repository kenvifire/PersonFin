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


def _holding(**overrides) -> dict:
    holding = {"label": "VFV", "asset_class": "equity", "quantity": 10, "value": 1000.0, "currency": "USD", "country": "CA"}
    holding.update(overrides)
    return holding


def _new_account(client, headers) -> int:
    return client.post("/accounts", json={"name": "Broker", "institution": "Broker", "account_type": "brokerage"}, headers=headers).json()["id"]


@pytest.mark.parametrize("bad_number", ["Infinity", "-Infinity", "NaN"])
@pytest.mark.parametrize("field", ["value", "quantity"])
def test_create_snapshot_rejects_non_finite_numbers(client, auth_header_for, field, bad_number):
    """Snapshots are immutable, so a non-finite value accepted here would
    permanently corrupt the dashboard. Sent both as a bare JSON literal
    (which Python's json module parses to a float inf/nan) and as a
    string (which Pydantic's lax mode would otherwise coerce)."""
    headers = auth_header_for("inf@example.com")
    account_id = _new_account(client, headers)
    url = f"/accounts/{account_id}/snapshots"

    raw_literal_body = '{"taken_at": "2026-11-08", "holdings": [{"label": "VFV", "asset_class": "equity", "quantity": 10, "value": 1000.0, "currency": "USD", "country": "CA", "%s": %s}]}' % (field, bad_number)
    literal_response = client.post(url, content=raw_literal_body, headers={**headers, "Content-Type": "application/json"})
    string_response = client.post(url, json={"taken_at": "2026-11-08", "holdings": [_holding(**{field: bad_number})]}, headers=headers)

    assert literal_response.status_code == 422, literal_response.text
    assert string_response.status_code == 422, string_response.text
    assert client.get("/dashboard?currency=USD", headers=headers).json()["trend"] == []


def test_create_snapshot_normalizes_asset_class_case(client, auth_header_for):
    headers = auth_header_for("case@example.com")
    account_id = _new_account(client, headers)
    response = client.post(f"/accounts/{account_id}/snapshots", json={"taken_at": "2026-11-08", "holdings": [_holding(asset_class=" Equity ")]}, headers=headers)

    assert response.status_code == 201
    assert response.json()["holdings"][0]["asset_class"] == "equity"


def test_create_snapshot_rejects_unknown_asset_class(client, auth_header_for):
    headers = auth_header_for("badclass@example.com")
    account_id = _new_account(client, headers)
    response = client.post(f"/accounts/{account_id}/snapshots", json={"taken_at": "2026-11-08", "holdings": [_holding(asset_class="not_a_real_class")]}, headers=headers)

    assert response.status_code == 422


def test_create_snapshot_returns_503_when_fx_is_unavailable(client, auth_header_for, use_fx_provider, db_session):
    from conftest import FailingFXRateProvider
    from app.models import Snapshot

    headers = auth_header_for("fxdown@example.com")
    account_id = _new_account(client, headers)
    use_fx_provider(FailingFXRateProvider())

    response = client.post(f"/accounts/{account_id}/snapshots", json={"taken_at": "2026-11-08", "holdings": [_holding(currency="CAD")]}, headers=headers)

    assert response.status_code == 503
    assert response.json() == {"detail": "Exchange rate temporarily unavailable, try again shortly"}
    assert db_session.query(Snapshot).count() == 0  # nothing partially written


def test_create_snapshot_locks_one_rate_per_currency(client, auth_header_for, use_fx_provider):
    from conftest import FakeFXRateProvider

    headers = auth_header_for("onerate@example.com")
    account_id = _new_account(client, headers)
    provider = use_fx_provider(FakeFXRateProvider())

    response = client.post(f"/accounts/{account_id}/snapshots", json={"taken_at": "2026-11-08", "holdings": [_holding(currency="CAD", value=100.0), _holding(currency="CAD", value=200.0), _holding(currency="SGD", value=10.0)]}, headers=headers)

    assert response.status_code == 201
    assert provider.calls == [("CAD", "USD"), ("SGD", "USD")]
    assert [h["value_usd"] for h in response.json()["holdings"]] == pytest.approx([72.0, 144.0, 7.4])
