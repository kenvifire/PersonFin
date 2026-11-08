"""Pydantic schemas for the `/targets` allocation-target and drift API."""

from datetime import datetime

from pydantic import BaseModel, Field


class TargetOut(BaseModel):
    id: int
    asset_class: str
    target_pct: float
    is_user_set: bool
    updated_at: datetime

    model_config = {"from_attributes": True}


class TargetUpdateIn(BaseModel):
    target_pct: float = Field(ge=0, le=100, allow_inf_nan=False)


class DriftFlag(BaseModel):
    asset_class: str
    target_pct: float
    actual_pct: float
    delta_pct: float
