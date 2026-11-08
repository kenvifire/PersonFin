import pytest

from app.models import AllocationTarget
from app.services.allocation import compute_drift


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


def test_compute_drift_flags_only_over_threshold():
    targets = [AllocationTarget(asset_class="crypto", target_pct=10.0, is_user_set=False)]
    flags = compute_drift({"crypto": 16.0}, targets)
    assert len(flags) == 1
    assert flags[0].delta_pct == pytest.approx(6.0)

    flags_within_threshold = compute_drift({"crypto": 12.0}, targets)
    assert flags_within_threshold == []
