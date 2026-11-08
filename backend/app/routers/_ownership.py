"""Shared per-user ownership lookups for routers.

Each helper scopes its query to `current_user.id`, so a valid id that
belongs to another user is indistinguishable from a nonexistent one and
returns 404.
"""

from fastapi import HTTPException, status
from sqlalchemy.orm import Session

from app.models import Account, Todo, User


def get_owned_account_or_404(account_id: int, current_user: User, db: Session) -> Account:
    account = (
        db.query(Account)
        .filter(Account.id == account_id, Account.user_id == current_user.id)
        .first()
    )
    if account is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Account not found")
    return account


def get_owned_todo_or_404(todo_id: int, current_user: User, db: Session) -> Todo:
    todo = (
        db.query(Todo)
        .filter(Todo.id == todo_id, Todo.user_id == current_user.id)
        .first()
    )
    if todo is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Todo not found")
    return todo
