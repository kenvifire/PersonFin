"""Pydantic schemas for the `/accounts/{account_id}/snapshots` API.

Holdings are validated here, at the edge, so invalid data (negative
values, unrecognized currencies) never reaches
`services.snapshots.create_snapshot`.
"""

from datetime import date, datetime

from pydantic import BaseModel, field_validator

from app.services.fx import SUPPORTED_CURRENCIES

# Holdings may also be reported in "CRYPTO" — a placeholder currency for
# crypto assets, which get a locked 1:1 USD rate rather than a real FX
# lookup (see services/snapshots.py).
ALLOWED_HOLDING_CURRENCIES = SUPPORTED_CURRENCIES | {"CRYPTO"}


class HoldingIn(BaseModel):
    label: str
    asset_class: str
    quantity: float | None = None
    value: float
    currency: str
    country: str

    @field_validator("value")
    @classmethod
    def value_must_be_non_negative(cls, value: float) -> float:
        if value < 0:
            raise ValueError("value must be >= 0")
        return value

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
