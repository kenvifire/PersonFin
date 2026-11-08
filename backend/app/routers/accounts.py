"""CRUD routes for a user's financial accounts. Every handler scopes its
query to `current_user.id`, so a valid id belonging to another user is
indistinguishable from a nonexistent one and returns 404.
"""

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.orm import Session

from app.auth.dependencies import get_current_user
from app.db import get_db
from app.models import Account, User
from app.schemas.account import AccountIn, AccountOut

router = APIRouter(prefix="/accounts", tags=["accounts"])


def _get_owned_account_or_404(account_id: int, current_user: User, db: Session) -> Account:
    account = (
        db.query(Account)
        .filter(Account.id == account_id, Account.user_id == current_user.id)
        .first()
    )
    if account is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Account not found")
    return account


@router.post("", response_model=AccountOut, status_code=status.HTTP_201_CREATED)
def create_account(
    payload: AccountIn,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> Account:
    account = Account(user_id=current_user.id, **payload.model_dump())
    db.add(account)
    db.commit()
    db.refresh(account)
    return account


@router.get("", response_model=list[AccountOut])
def list_accounts(
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> list[Account]:
    return db.query(Account).filter(Account.user_id == current_user.id).all()


@router.get("/{account_id}", response_model=AccountOut)
def get_account(
    account_id: int,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> Account:
    return _get_owned_account_or_404(account_id, current_user, db)


@router.patch("/{account_id}", response_model=AccountOut)
def update_account(
    account_id: int,
    payload: AccountIn,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> Account:
    account = _get_owned_account_or_404(account_id, current_user, db)
    for field, value in payload.model_dump().items():
        setattr(account, field, value)
    db.commit()
    db.refresh(account)
    return account


@router.delete("/{account_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_account(
    account_id: int,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> None:
    account = _get_owned_account_or_404(account_id, current_user, db)
    db.delete(account)
    db.commit()
