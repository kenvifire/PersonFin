"""Pydantic schemas for the `/uploads` API."""

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
