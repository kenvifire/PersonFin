"""Pydantic schemas for the `/accounts/{account_id}/snapshots` API.

Holdings are validated here, at the edge, so invalid data (negative or
non-finite values, unrecognized currencies or asset classes) never
reaches `services.snapshots.create_snapshot`. This matters doubly
because snapshots are immutable: a bad value accepted here could never
be removed.
"""

from datetime import date, datetime

from pydantic import BaseModel, Field, field_validator

from app.services.allocation import normalize_asset_class
from app.services.fx import SUPPORTED_CURRENCIES

# Holdings may also be reported in "CRYPTO" — a placeholder currency for
# crypto assets, which get a locked 1:1 USD rate rather than a real FX
# lookup (see services/snapshots.py).
ALLOWED_HOLDING_CURRENCIES = SUPPORTED_CURRENCIES | {"CRYPTO"}


class HoldingIn(BaseModel):
    label: str
    asset_class: str
    quantity: float | None = Field(default=None, allow_inf_nan=False)
    value: float = Field(ge=0, allow_inf_nan=False)
    currency: str
    country: str

    @field_validator("asset_class")
    @classmethod
    def asset_class_must_be_recognized(cls, asset_class: str) -> str:
        return normalize_asset_class(asset_class)

    @field_validator("currency")
    @classmethod
    def currency_must_be_recognized(cls, currency: str) -> str:
        if currency not in ALLOWED_HOLDING_CURRENCIES:
            raise ValueError(f"unrecognized currency: {currency}")
        return currency


class SnapshotIn(BaseModel):
    taken_at: date
    holdings: list[HoldingIn]


class HoldingOut(BaseModel):
    id: int
    label: str
    asset_class: str
    quantity: float | None
    value: float
    currency: str
    country: str
    value_usd: float
    fx_rate_to_usd: float

    model_config = {"from_attributes": True}


class SnapshotOut(BaseModel):
    id: int
    taken_at: date
    created_at: datetime
    holdings: list[HoldingOut]

    model_config = {"from_attributes": True}
