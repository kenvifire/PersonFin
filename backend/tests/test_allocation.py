from app.models import AllocationTarget
from app.schemas.dashboard import DashboardOut
from app.services.allocation import compute_drift_from_dashboard


def test_compute_drift_from_dashboard_returns_empty_for_zero_net_worth(db_session):
    dashboard = DashboardOut(net_worth=0.0, currency="USD", by_asset_class={}, by_country={}, accounts=[], trend=[])
    assert compute_drift_from_dashboard(db_session, user_id=1, dashboard=dashboard) == []

def test_compute_drift_from_dashboard_converts_dollars_to_percent_before_comparing(db_session):
    from app.models import User
    user = User(google_sub="g-drift-1", email="drift1@example.com")
    db_session.add(user)
    db_session.commit()
    target = AllocationTarget(user_id=user.id, asset_class="crypto", target_pct=10.0, is_user_set=True)
    db_session.add(target)
    db_session.commit()

    dashboard = DashboardOut(
        net_worth=1000.0, currency="USD",
        by_asset_class={"crypto": 160.0}, by_country={}, accounts=[], trend=[],
    )
    # get_or_create_targets also seeds the default equity/cash/bond targets,
    # which drift against 0% here; only the crypto flag is under test.
    flags = [
        f for f in compute_drift_from_dashboard(db_session, user.id, dashboard)
        if f.asset_class == "crypto"
    ]
    assert len(flags) == 1
    assert flags[0].asset_class == "crypto"
    assert flags[0].actual_pct == 16.0  # 160/1000 * 100
    assert flags[0].delta_pct == 6.0
