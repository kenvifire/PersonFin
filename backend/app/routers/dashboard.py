"""HTTP layer for the dashboard summary. Thin by design: validates the
requested display currency and delegates all aggregation to
`services.dashboard.build_dashboard`.
"""

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy.orm import Session

from app.auth.dependencies import get_current_user
from app.db import get_db
from app.models import User
from app.schemas.dashboard import DashboardOut
from app.services import fx
from app.services.dashboard import build_dashboard

router = APIRouter(prefix="/dashboard", tags=["dashboard"])


@router.get("", response_model=DashboardOut)
def get_dashboard(
    currency: str = Query(..., description="ISO currency code to display amounts in"),
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
    fx_provider: fx.FXRateProvider = Depends(fx.get_fx_provider),
) -> DashboardOut:
    if currency not in fx.SUPPORTED_CURRENCIES:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail=f"Unsupported currency: {currency}",
        )
    return build_dashboard(db, current_user.id, currency, fx_provider)
