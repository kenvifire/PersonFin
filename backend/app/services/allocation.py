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

# The closed set of asset classes a holding or allocation target may use.
# Kept identical to DEFAULT_TARGETS' keys so every class a holding can be
# reported in always has a target (seeded on first access), and drift can
# never silently ignore a holding's class.
ASSET_CLASSES: frozenset[str] = frozenset(DEFAULT_TARGETS)


def normalize_asset_class(value: str) -> str:
    """Normalize (strip + lowercase) and validate an asset class.
    Raises `ValueError` if it isn't one of `ASSET_CLASSES`."""
    normalized = value.strip().lower()
    if normalized not in ASSET_CLASSES:
        raise ValueError(
            f"unrecognized asset_class: {value!r} (expected one of {sorted(ASSET_CLASSES)})"
        )
    return normalized

# Minimum absolute percentage-point gap between actual and target
# allocation before it's surfaced as drift.
DRIFT_THRESHOLD_PCT = 5.0


def get_or_create_targets(db: Session, user_id: int) -> list[AllocationTarget]:
    """Return a user's allocation targets, seeding any `DEFAULT_TARGETS`
    asset classes the user doesn't already have a row for (all seeded
    rows are `is_user_set=False`). This is keyed per asset class, not
    "any row exists for this user" — a user can reach this with a
    partial set of rows (e.g. `PUT /targets/{asset_class}` creating a
    single row before `GET /targets` is ever called), and the missing
    asset classes still need backfilling in that case. Existing rows,
    user-set or not, are never modified."""
    existing = (
        db.query(AllocationTarget).filter(AllocationTarget.user_id == user_id).all()
    )
    existing_asset_classes = {target.asset_class for target in existing}
    missing_asset_classes = [
        asset_class
        for asset_class in DEFAULT_TARGETS
        if asset_class not in existing_asset_classes
    ]
    if not missing_asset_classes:
        return existing

    new_targets = [
        AllocationTarget(
            user_id=user_id,
            asset_class=asset_class,
            target_pct=DEFAULT_TARGETS[asset_class],
            is_user_set=False,
        )
        for asset_class in missing_asset_classes
    ]
    db.add_all(new_targets)
    db.commit()
    for target in new_targets:
        db.refresh(target)
    return existing + new_targets


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
