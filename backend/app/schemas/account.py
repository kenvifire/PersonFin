"""Pydantic schemas for the `/accounts` API."""

from datetime import datetime

from pydantic import BaseModel


class AccountIn(BaseModel):
    name: str
    institution: str
    account_type: str


class AccountOut(BaseModel):
    id: int
    name: str
    institution: str
    account_type: str
    created_at: datetime

    model_config = {"from_attributes": True}
