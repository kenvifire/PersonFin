"""Snapshot-creation service.

Plain Python, no HTTP concerns: this is the function Plan 2 (the vision
extraction pipeline) calls directly once a user has confirmed the
holdings extracted from a statement, so it takes an already-resolved
`Account` and validated `SnapshotIn` data rather than anything
request-shaped.

Every holding's USD value is locked at creation time via `fx.convert`
and never recomputed — snapshots are immutable historical records.
Crypto holdings (`currency == "CRYPTO"`) are a deliberate placeholder:
they get `fx_rate_to_usd = 1.0` and `value_usd = value` rather than a
real market-price lookup, which is out of scope for this plan.
"""

from sqlalchemy.orm import Session

from app.models import Account, Holding, Snapshot
from app.schemas.snapshot import SnapshotIn
from app.services import fx
from app.services.fx import FXRateProvider

CRYPTO_CURRENCY = "CRYPTO"
USD = "USD"


def create_snapshot(
    db: Session,
    account: Account,
    data: SnapshotIn,
    fx_provider: FXRateProvider,
) -> Snapshot:
    snapshot = Snapshot(account_id=account.id, taken_at=data.taken_at)

    for item in data.holdings:
        if item.currency == CRYPTO_CURRENCY:
            fx_rate_to_usd = 1.0
        else:
            fx_rate_to_usd = fx.convert(1.0, item.currency, USD, fx_provider)
        value_usd = item.value * fx_rate_to_usd

        snapshot.holdings.append(
            Holding(
                label=item.label,
                asset_class=item.asset_class,
                quantity=item.quantity,
                value=item.value,
                currency=item.currency,
                country=item.country,
                value_usd=value_usd,
                fx_rate_to_usd=fx_rate_to_usd,
            )
        )

    db.add(snapshot)
    db.commit()
    db.refresh(snapshot)
    return snapshot
