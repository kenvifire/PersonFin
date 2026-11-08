"""Pydantic schemas for the `/todos` API."""

from datetime import datetime

from pydantic import BaseModel


class TodoIn(BaseModel):
    description: str
    related_asset_class: str | None = None


class TodoOut(BaseModel):
    id: int
    description: str
    done: bool
    related_asset_class: str | None
    created_at: datetime

    model_config = {"from_attributes": True}


class TodoUpdate(BaseModel):
    done: bool
