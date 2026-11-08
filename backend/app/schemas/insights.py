"""Pydantic schemas for DeepSeek-generated portfolio insights.

The structured shape a DeepSeek chat-completion's JSON content is
parsed and validated into — the insights-generation analog of
`schemas/extraction.py`'s role for vision extraction.
"""

from pydantic import BaseModel, Field, field_validator

from app.schemas.dashboard import DashboardOut
from app.schemas.target import DriftFlag


class ActionItem(BaseModel):
    asset_class: str
    suggestion: str


class InsightsNarrative(BaseModel):
    summary: str
    action_items: list[ActionItem] = Field(default_factory=list)

    @field_validator("summary")
    @classmethod
    def _summary_not_blank(cls, summary: str) -> str:
        # A degenerate LLM response with an empty summary must fail
        # validation (and so degrade to `narrative_unavailable=True`)
        # rather than render as a blank narrative.
        if not summary.strip():
            raise ValueError("summary must not be empty")
        return summary


class InsightsOut(BaseModel):
    dashboard: DashboardOut
    drift: list[DriftFlag]
    narrative: InsightsNarrative
    narrative_unavailable: bool
