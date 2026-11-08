"""Pydantic schemas for DeepSeek-generated portfolio insights.

The structured shape a DeepSeek chat-completion's JSON content is
parsed and validated into — the insights-generation analog of
`schemas/extraction.py`'s role for vision extraction.
"""

from pydantic import BaseModel, Field


class ActionItem(BaseModel):
    asset_class: str
    suggestion: str


class InsightsNarrative(BaseModel):
    summary: str
    action_items: list[ActionItem] = Field(default_factory=list)
