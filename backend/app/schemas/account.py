"""Pydantic schemas for the `/accounts` API."""

from datetime import datetime

from pydantic import BaseModel, field_validator


class AccountIn(BaseModel):
    name: str
    institution: str
    account_type: str


class AccountUpdate(BaseModel):
    """Partial update for `PATCH /accounts/{id}`: every field is optional
    and only fields present in the request are applied (the router uses
    `model_dump(exclude_unset=True)`)."""

    name: str | None = None
    institution: str | None = None
    account_type: str | None = None

    @field_validator("name", "institution", "account_type")
    @classmethod
    def explicit_null_not_allowed(cls, value: str | None) -> str:
        # Validators don't run for omitted fields (defaults aren't
        # validated), so this only rejects an explicit `null` — the
        # underlying columns are NOT NULL.
        if value is None:
            raise ValueError("field may be omitted but not null")
        return value


class AccountOut(BaseModel):
    id: int
    name: str
    institution: str
    account_type: str
    created_at: datetime

    model_config = {"from_attributes": True}
