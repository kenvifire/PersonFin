"""Pydantic schemas for `POST /uploads/{id}/confirm`.

`holdings` is typed as `list[HoldingIn]` directly (Plan 1's
`app.schemas.snapshot.HoldingIn`) rather than a new, looser type — the
same value/currency/asset-class validation that guards
`POST /accounts/{account_id}/snapshots` must guard this endpoint too,
since both paths ultimately call `services.snapshots.create_snapshot`
to create an immutable `Snapshot`.
"""

from datetime import date

from pydantic import BaseModel, model_validator

from app.schemas.snapshot import HoldingIn


class NewAccountIn(BaseModel):
    """Same shape as `app.schemas.account.AccountIn`, named separately
    because here it's nested inside `ConfirmUploadIn`, not a top-level
    request body."""

    name: str
    institution: str
    account_type: str


class ConfirmUploadIn(BaseModel):
    account_id: int | None = None
    new_account: NewAccountIn | None = None
    taken_at: date
    holdings: list[HoldingIn]

    @model_validator(mode="after")
    def exactly_one_of_account_id_or_new_account(self) -> "ConfirmUploadIn":
        if (self.account_id is None) == (self.new_account is None):
            raise ValueError("exactly one of account_id or new_account must be provided")
        return self
