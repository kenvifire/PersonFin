"""HTTP layer for portfolio insights. Thin by design, like `dashboard.py`
and `targets.py`: validates the requested display currency, builds the
dashboard, and computes drift via `compute_drift_from_dashboard`.

Unlike `fx.FXRateUnavailable` (handled globally as a 503 because currency
conversion is load-bearing), a failure to generate the narrative is
caught right here and degraded into a 200 response with
`narrative_unavailable=True` — insight commentary is additive, not
load-bearing, so an LLM outage should never fail the whole request.
"""

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy.orm import Session

from app.auth.dependencies import get_current_user
from app.db import get_db
from app.models import User
from app.schemas.insights import InsightsNarrative, InsightsOut
from app.services import fx, insights
from app.services.allocation import compute_drift_from_dashboard
from app.services.dashboard import build_dashboard
from app.services.insights import InsightGenerationFailed, InsightGenerator

router = APIRouter(prefix="/insights", tags=["insights"])

NO_HOLDINGS_NARRATIVE = InsightsNarrative(
    summary="No holdings yet — once you add some accounts, insights will appear here.",
    action_items=[],
)

NARRATIVE_UNAVAILABLE_NARRATIVE = InsightsNarrative(
    summary="Insight commentary is temporarily unavailable — your numbers above are still accurate.",
    action_items=[],
)


@router.get("", response_model=InsightsOut)
def get_insights(
    currency: str = Query(..., description="ISO currency code to display amounts in"),
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
    fx_provider: fx.FXRateProvider = Depends(fx.get_fx_provider),
    insight_generator: InsightGenerator = Depends(insights.get_insight_generator),
) -> InsightsOut:
    if currency not in fx.SUPPORTED_CURRENCIES:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail=f"Unsupported currency: {currency}",
        )

    dashboard = build_dashboard(db, current_user.id, currency, fx_provider)
    drift = compute_drift_from_dashboard(db, current_user.id, dashboard)

    if dashboard.net_worth == 0:
        # Nothing to narrate yet, and no reason to spend a network call
        # doing it.
        return InsightsOut(
            dashboard=dashboard,
            drift=drift,
            narrative=NO_HOLDINGS_NARRATIVE,
            narrative_unavailable=False,
        )

    try:
        narrative = insight_generator.generate(dashboard, drift)
    except InsightGenerationFailed:
        return InsightsOut(
            dashboard=dashboard,
            drift=drift,
            narrative=NARRATIVE_UNAVAILABLE_NARRATIVE,
            narrative_unavailable=True,
        )

    return InsightsOut(
        dashboard=dashboard,
        drift=drift,
        narrative=narrative,
        narrative_unavailable=False,
    )
