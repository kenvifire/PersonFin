"""Pydantic schemas for the `/uploads` API."""

from datetime import datetime
from typing import Any

from pydantic import BaseModel


class UploadOut(BaseModel):
    id: int
    status: str

    model_config = {"from_attributes": True}


class UploadExtractOut(BaseModel):
    id: int
    status: str
    extracted_payload: dict[str, Any] | None
    extraction_error: str | None

    model_config = {"from_attributes": True}


class UploadSummaryOut(BaseModel):
    """`GET /uploads` list item: just enough to render a list, not the
    full extracted payload."""

    id: int
    status: str
    created_at: datetime

    model_config = {"from_attributes": True}


class UploadDetailOut(BaseModel):
    """`GET /uploads/{id}`: the full upload record."""

    id: int
    status: str
    mime_type: str
    extracted_payload: dict[str, Any] | None
    extraction_error: str | None
    suggested_account_id: int | None
    matched_account_id: int | None
    snapshot_id: int | None
    created_at: datetime

    model_config = {"from_attributes": True}
