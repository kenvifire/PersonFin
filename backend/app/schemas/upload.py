"""Pydantic schemas for the `/uploads` API."""

from pydantic import BaseModel


class UploadOut(BaseModel):
    id: int
    status: str

    model_config = {"from_attributes": True}
