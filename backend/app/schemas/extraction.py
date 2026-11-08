"""Pydantic schemas for vision-extracted screenshot data.

These are deliberately loose — unvalidated "best guesses" for the user
to review and correct before confirming an upload — unlike the strict
`HoldingIn`/`SnapshotIn` schemas used once a snapshot is actually
created.
"""

from datetime import date

from pydantic import BaseModel, Field


class DraftHolding(BaseModel):
    label: str
    asset_class_guess: str | None = None
    quantity: float | None = None
    value: float | None = None
    currency_guess: str | None = None
    country_guess: str | None = None


class ExtractionResult(BaseModel):
    institution: str | None = None
    account_label: str | None = None
    account_type_guess: str | None = None
    taken_at_guess: date | None = None
    holdings: list[DraftHolding] = Field(default_factory=list)
