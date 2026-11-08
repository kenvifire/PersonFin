from datetime import date

from app.models.account import Account
from app.models.holding import Holding
from app.models.snapshot import Snapshot
from app.models.user import User


def test_create_full_holding_chain(db_session):
    user = User(google_sub="g-1", email="a@example.com")
    db_session.add(user)
    db_session.flush()
    account = Account(user_id=user.id, name="RBC RRSP", institution="RBC", account_type="rrsp")
    db_session.add(account)
    db_session.flush()
    snapshot = Snapshot(account_id=account.id, taken_at=date(2026, 11, 8))
    db_session.add(snapshot)
    db_session.flush()
    holding = Holding(
        snapshot_id=snapshot.id, label="VFV", asset_class="equity",
        quantity=10, value=1000.0, currency="CAD", country="CA",
        value_usd=720.0, fx_rate_to_usd=0.72,
    )
    db_session.add(holding)
    db_session.commit()

    assert db_session.get(Holding, holding.id).value_usd == 720.0
