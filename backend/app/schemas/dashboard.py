"""Pydantic schemas for the `GET /dashboard` summary API."""

from datetime import date

from pydantic import BaseModel


class AccountSummary(BaseModel):
    account_id: int
    name: str
    as_of: date | None
    value: float


class TrendPoint(BaseModel):
    taken_at: date
    net_worth: float


class DashboardOut(BaseModel):
    net_worth: float
    currency: str
    by_asset_class: dict[str, float]
    by_country: dict[str, float]
    accounts: list[AccountSummary]
    trend: list[TrendPoint]
