"""CRUD routes for a user's financial accounts. Every handler scopes its
query to `current_user.id`, so a valid id belonging to another user is
indistinguishable from a nonexistent one and returns 404.

Snapshots are immutable history that is never deleted, so an account
can only be deleted while it has no snapshots (e.g. one created by
mistake); otherwise `DELETE` returns 409.
"""

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.orm import Session

from app.auth.dependencies import get_current_user
from app.db import get_db
from app.models import Account, Snapshot, User
from app.routers._ownership import get_owned_account_or_404
from app.schemas.account import AccountIn, AccountOut, AccountUpdate

router = APIRouter(prefix="/accounts", tags=["accounts"])


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
    return get_owned_account_or_404(account_id, current_user, db)


@router.patch("/{account_id}", response_model=AccountOut)
def update_account(
    account_id: int,
    payload: AccountUpdate,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> Account:
    account = get_owned_account_or_404(account_id, current_user, db)
    # Partial update: only fields the client actually sent are changed.
    for field, value in payload.model_dump(exclude_unset=True).items():
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
    account = get_owned_account_or_404(account_id, current_user, db)
    has_snapshots = (
        db.query(Snapshot.id).filter(Snapshot.account_id == account.id).first() is not None
    )
    if has_snapshots:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="Account has snapshot history and cannot be deleted",
        )
    db.delete(account)
    db.commit()
