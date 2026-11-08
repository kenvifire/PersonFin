"""HTTP layer for portfolio insights. Thin by design, like `dashboard.py`
and `targets.py`: validates the requested display currency, builds the
dashboard, and computes drift via `compute_drift_from_dashboard`.

Unlike `fx.FXRateUnavailable` (handled globally as a 503 because currency
conversion is load-bearing), a failure to generate the narrative is
caught right here and degraded into a 200 response with
`narrative_unavailable=True` — insight commentary is additive, not
load-bearing, so an LLM outage should never fail the whole request.
That catch is deliberately broad (any exception, not only
`InsightGenerationFailed`), so even an unanticipated failure type in a
generator can't turn this endpoint into a 500.
"""

import logging

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy.orm import Session

from app.auth.dependencies import get_current_user
from app.db import get_db
from app.models import User
from app.schemas.insights import ActionItem, InsightsNarrative, InsightsOut
from app.schemas.target import DriftFlag
from app.services import fx, insights
from app.services.allocation import compute_drift_from_dashboard, get_or_create_targets
from app.services.dashboard import build_dashboard
from app.services.insights import InsightGenerationFailed, InsightGenerator

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/insights", tags=["insights"])

NO_HOLDINGS_NARRATIVE = InsightsNarrative(
    summary="No holdings yet — once you add some accounts, insights will appear here.",
    action_items=[],
)

NARRATIVE_UNAVAILABLE_NARRATIVE = InsightsNarrative(
    summary="Insight commentary is temporarily unavailable — your numbers above are still accurate.",
    action_items=[],
)


def _only_drifted_action_items(narrative: InsightsNarrative, drift: list[DriftFlag]) -> InsightsNarrative:
    """Keep only action items for asset classes that actually drifted
    (one suggested action per drifted asset class is the whole point of
    them). Matching is case/whitespace-insensitive, and kept items carry
    the canonical asset-class name from `drift`."""
    drifted = {flag.asset_class.strip().lower(): flag.asset_class for flag in drift}
    kept = [
        ActionItem(asset_class=drifted[key], suggestion=item.suggestion)
        for item in narrative.action_items
        if (key := item.asset_class.strip().lower()) in drifted
    ]
    return narrative.model_copy(update={"action_items": kept})


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

    if dashboard.net_worth == 0:
        # Nothing to narrate yet (and no allocation to drift from), and
        # no reason to spend a network call doing it.
        return InsightsOut(
            dashboard=dashboard,
            drift=[],
            narrative=NO_HOLDINGS_NARRATIVE,
            narrative_unavailable=False,
        )

    # Fetched here (rather than inside `compute_drift_from_dashboard`)
    # because the narrative also needs each target's provenance: a
    # system-default target must never be narrated as the user's choice.
    targets = get_or_create_targets(db, current_user.id)
    drift = compute_drift_from_dashboard(db, current_user.id, dashboard, targets)
    user_set_asset_classes = frozenset(t.asset_class for t in targets if t.is_user_set)

    try:
        narrative = insight_generator.generate(dashboard, drift, user_set_asset_classes)
        return InsightsOut(
            dashboard=dashboard,
            drift=drift,
            narrative=_only_drifted_action_items(narrative, drift),
            narrative_unavailable=False,
        )
    except Exception as exc:
        # Only the failure's type and fixed category are logged — never
        # its message, the prompt, the response, or any credentials.
        logger.warning(
            "Insight narrative unavailable; degrading GET /insights (%s, category=%s)",
            type(exc).__name__,
            exc.category if isinstance(exc, InsightGenerationFailed) else "unanticipated",
        )
        return InsightsOut(
            dashboard=dashboard,
            drift=drift,
            narrative=NARRATIVE_UNAVAILABLE_NARRATIVE,
            narrative_unavailable=True,
        )
