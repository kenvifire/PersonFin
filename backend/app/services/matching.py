"""Best-effort account matching for a freshly extracted upload.

Plain string similarity, no LLM call: a vision extraction's guessed
`institution`/`account_label` strings are rarely exact matches for an
existing `Account`'s `institution`/`name` (e.g. "RBC Royal Bank" vs.
"Royal Bank of Canada"), so we score every one of the user's accounts
with `difflib.SequenceMatcher` and suggest the best match if it clears
a minimum similarity threshold. The result is a suggestion for the
user to confirm, not an authoritative link.
"""

from difflib import SequenceMatcher

from sqlalchemy.orm import Session

from app.models import Account

MATCH_THRESHOLD = 0.6


def _normalize(value: str) -> str:
    return value.strip().lower()


def suggest_account(
    db: Session,
    user_id: int,
    institution: str | None,
    account_label: str | None,
) -> Account | None:
    if institution is None and account_label is None:
        return None

    accounts = db.query(Account).filter(Account.user_id == user_id).all()
    if not accounts:
        return None

    extracted = _normalize(f"{institution} {account_label}")

    best_account: Account | None = None
    best_ratio = 0.0
    for account in accounts:
        candidate = _normalize(f"{account.institution} {account.name}")
        ratio = SequenceMatcher(None, extracted, candidate).ratio()
        if ratio > best_ratio:
            best_ratio = ratio
            best_account = account

    if best_account is not None and best_ratio >= MATCH_THRESHOLD:
        return best_account
    return None
