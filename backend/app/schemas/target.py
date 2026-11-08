"""Pydantic schemas for the `/targets` allocation-target and drift API."""

from datetime import datetime

from pydantic import BaseModel


class TargetOut(BaseModel):
    id: int
    asset_class: str
    target_pct: float
    is_user_set: bool
    updated_at: datetime

    model_config = {"from_attributes": True}


class TargetUpdateIn(BaseModel):
    target_pct: float


class DriftFlag(BaseModel):
    asset_class: str
    target_pct: float
    actual_pct: float
    delta_pct: float
