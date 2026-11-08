"""Allocation target defaults and drift computation.

`get_or_create_targets` is the only function here that touches the
database — it lazily seeds a user's targets from `DEFAULT_TARGETS` the
first time they're requested, and is idempotent afterwards (existing
rows are never re-created or overwritten).

`compute_drift` is a pure function: given a percentage breakdown of a
user's actual holdings and their targets, it reports which asset
classes have drifted by at least `DRIFT_THRESHOLD_PCT` points. It has
no DB access and no opinion about currencies or dollar amounts — the
caller (the `/targets/drift` router) is responsible for converting a
dashboard's dollar-amount `by_asset_class` into percentages of net
worth before calling it.

Percentages across a user's targets are not required to sum to 100 —
that's left as a UI-level nudge (Plan 4), never enforced here.
"""

from sqlalchemy.orm import Session

from app.models import AllocationTarget
from app.schemas.target import DriftFlag

# Default allocation suggestions seeded for a user on first access.
# Named constant per project convention — never inline these values.
DEFAULT_TARGETS: dict[str, float] = {
    "equity": 60.0,
    "cash": 20.0,
    "crypto": 10.0,
    "bond": 10.0,
}

# Minimum absolute percentage-point gap between actual and target
# allocation before it's surfaced as drift.
DRIFT_THRESHOLD_PCT = 5.0


def get_or_create_targets(db: Session, user_id: int) -> list[AllocationTarget]:
    """Return a user's allocation targets, seeding `DEFAULT_TARGETS`
    (all `is_user_set=False`) on their first call. Subsequent calls
    return the existing rows untouched."""
    existing = (
        db.query(AllocationTarget).filter(AllocationTarget.user_id == user_id).all()
    )
    if existing:
        return existing

    targets = [
        AllocationTarget(
            user_id=user_id,
            asset_class=asset_class,
            target_pct=target_pct,
            is_user_set=False,
        )
        for asset_class, target_pct in DEFAULT_TARGETS.items()
    ]
    db.add_all(targets)
    db.commit()
    for target in targets:
        db.refresh(target)
    return targets


def compute_drift(
    by_asset_class_pct: dict[str, float],
    targets: list[AllocationTarget],
) -> list[DriftFlag]:
    """Compare actual allocation percentages against targets, flagging
    any asset class whose |actual - target| is at least
    `DRIFT_THRESHOLD_PCT` percentage points. Pure comparison — no DB
    access, no currency conversion."""
    flags: list[DriftFlag] = []
    for target in targets:
        actual_pct = by_asset_class_pct.get(target.asset_class, 0.0)
        delta_pct = actual_pct - target.target_pct
        if abs(delta_pct) >= DRIFT_THRESHOLD_PCT:
            flags.append(
                DriftFlag(
                    asset_class=target.asset_class,
                    target_pct=target.target_pct,
                    actual_pct=actual_pct,
                    delta_pct=delta_pct,
                )
            )
    return flags
