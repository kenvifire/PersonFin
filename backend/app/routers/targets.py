"""HTTP layer for allocation targets and drift. Defaults are seeded
lazily via `services.allocation.get_or_create_targets`; drift is
computed by converting the dashboard's dollar-amount `by_asset_class`
breakdown into percentages of `net_worth` before handing it to the
pure `compute_drift` function.
"""

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy.orm import Session

from app.auth.dependencies import get_current_user
from app.db import get_db
from app.models import AllocationTarget, User
from app.schemas.target import DriftFlag, TargetOut, TargetUpdateIn
from app.services import fx
from app.services.allocation import (
    compute_drift_from_dashboard,
    get_or_create_targets,
    normalize_asset_class,
)
from app.services.dashboard import build_dashboard

router = APIRouter(prefix="/targets", tags=["targets"])


@router.get("", response_model=list[TargetOut])
def list_targets(
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> list[AllocationTarget]:
    return get_or_create_targets(db, current_user.id)


@router.put("/{asset_class}", response_model=TargetOut)
def update_target(
    asset_class: str,
    payload: TargetUpdateIn,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> AllocationTarget:
    # Only known asset classes can ever become targets (this also keeps
    # arbitrary path segments, e.g. "drift", from being stored as one).
    try:
        asset_class = normalize_asset_class(asset_class)
    except ValueError as exc:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY, detail=str(exc)
        ) from exc

    target = (
        db.query(AllocationTarget)
        .filter(
            AllocationTarget.user_id == current_user.id,
            AllocationTarget.asset_class == asset_class,
        )
        .first()
    )
    if target is None:
        target = AllocationTarget(user_id=current_user.id, asset_class=asset_class)
        db.add(target)

    target.target_pct = payload.target_pct
    target.is_user_set = True
    db.commit()
    db.refresh(target)
    return target


@router.get("/drift", response_model=list[DriftFlag])
def get_drift(
    currency: str = Query(..., description="ISO currency code to compute drift in"),
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
    fx_provider: fx.FXRateProvider = Depends(fx.get_fx_provider),
) -> list[DriftFlag]:
    if currency not in fx.SUPPORTED_CURRENCIES:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail=f"Unsupported currency: {currency}",
        )

    dashboard = build_dashboard(db, current_user.id, currency, fx_provider)
    return compute_drift_from_dashboard(db, current_user.id, dashboard)
