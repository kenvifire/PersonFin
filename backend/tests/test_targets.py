import pytest

from app.models import AllocationTarget
from app.services.allocation import DEFAULT_TARGETS, compute_drift


def test_get_targets_creates_defaults_on_first_call(client, auth_header_for):
    headers = auth_header_for("a@example.com")
    response = client.get("/targets", headers=headers)
    assert response.status_code == 200
    body = {t["asset_class"]: t for t in response.json()}
    assert body["crypto"]["target_pct"] == 10.0
    assert body["crypto"]["is_user_set"] is False


def test_updating_a_target_marks_it_user_set(client, auth_header_for):
    headers = auth_header_for("a@example.com")
    client.get("/targets", headers=headers)
    response = client.put("/targets/crypto", json={"target_pct": 25.0}, headers=headers)
    assert response.status_code == 200
    assert response.json()["target_pct"] == 25.0
    assert response.json()["is_user_set"] is True


def test_put_before_get_still_backfills_remaining_defaults(client, auth_header_for):
    """A PUT for a single asset class, with no prior GET, must not
    leave the user's other default asset classes permanently
    unseeded — get_or_create_targets backfills by asset class, not by
    "any row exists for this user"."""
    headers = auth_header_for("b@example.com")

    put_response = client.put(
        "/targets/crypto", json={"target_pct": 42.0}, headers=headers
    )
    assert put_response.status_code == 200

    get_response = client.get("/targets", headers=headers)
    assert get_response.status_code == 200
    body = {t["asset_class"]: t for t in get_response.json()}

    assert set(body.keys()) == set(DEFAULT_TARGETS.keys())
    assert body["crypto"]["target_pct"] == 42.0
    assert body["crypto"]["is_user_set"] is True
    for asset_class, default_pct in DEFAULT_TARGETS.items():
        if asset_class == "crypto":
            continue
        assert body[asset_class]["target_pct"] == default_pct
        assert body[asset_class]["is_user_set"] is False


def test_compute_drift_flags_only_over_threshold():
    targets = [AllocationTarget(asset_class="crypto", target_pct=10.0, is_user_set=False)]
    flags = compute_drift({"crypto": 16.0}, targets)
    assert len(flags) == 1
    assert flags[0].delta_pct == pytest.approx(6.0)

    flags_within_threshold = compute_drift({"crypto": 12.0}, targets)
    assert flags_within_threshold == []


def test_drift_for_user_with_no_net_worth_is_empty(client, auth_header_for):
    """No holdings means no allocation to drift from — not one
    "fully missing" flag per target."""
    headers = auth_header_for("empty@example.com")
    response = client.get("/targets/drift?currency=USD", headers=headers)
    assert response.status_code == 200
    assert response.json() == []


def test_put_target_normalizes_asset_class(client, auth_header_for):
    headers = auth_header_for("norm@example.com")
    response = client.put("/targets/Crypto", json={"target_pct": 15.0}, headers=headers)
    assert response.status_code == 200
    assert response.json()["asset_class"] == "crypto"

    body = client.get("/targets", headers=headers).json()
    assert sorted(t["asset_class"] for t in body) == sorted(DEFAULT_TARGETS)


@pytest.mark.parametrize("asset_class", ["not_a_real_class", "drift"])
def test_put_target_rejects_unknown_asset_class(client, auth_header_for, asset_class):
    headers = auth_header_for("unknown@example.com")
    response = client.put(f"/targets/{asset_class}", json={"target_pct": 15.0}, headers=headers)
    assert response.status_code == 422
    body = client.get("/targets", headers=headers).json()
    assert asset_class not in {t["asset_class"] for t in body}


@pytest.mark.parametrize("target_pct", [-1, 100.5, "Infinity", "NaN"])
def test_put_target_rejects_out_of_range_pct(client, auth_header_for, target_pct):
    headers = auth_header_for("range@example.com")
    response = client.put("/targets/crypto", json={"target_pct": target_pct}, headers=headers)
    assert response.status_code == 422


@pytest.mark.parametrize("target_pct", [0, 100])
def test_put_target_accepts_range_bounds(client, auth_header_for, target_pct):
    headers = auth_header_for("bounds@example.com")
    response = client.put("/targets/crypto", json={"target_pct": target_pct}, headers=headers)
    assert response.status_code == 200
    assert response.json()["target_pct"] == target_pct
