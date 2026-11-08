"""CRUD routes for a user's to-dos. Every handler scopes its query to
`current_user.id`, so a valid id belonging to another user is
indistinguishable from a nonexistent one and returns 404.
"""

from fastapi import APIRouter, Depends, status
from sqlalchemy.orm import Session

from app.auth.dependencies import get_current_user
from app.db import get_db
from app.models import Todo, User
from app.routers._ownership import get_owned_todo_or_404
from app.schemas.todo import TodoIn, TodoOut, TodoUpdate

router = APIRouter(prefix="/todos", tags=["todos"])


@router.post("", response_model=TodoOut, status_code=status.HTTP_201_CREATED)
def create_todo(
    payload: TodoIn,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> Todo:
    todo = Todo(user_id=current_user.id, **payload.model_dump())
    db.add(todo)
    db.commit()
    db.refresh(todo)
    return todo


@router.get("", response_model=list[TodoOut])
def list_todos(
    done: bool | None = None,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> list[Todo]:
    query = db.query(Todo).filter(Todo.user_id == current_user.id)
    if done is not None:
        query = query.filter(Todo.done == done)
    return query.all()


@router.patch("/{todo_id}", response_model=TodoOut)
def update_todo(
    todo_id: int,
    payload: TodoUpdate,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> Todo:
    todo = get_owned_todo_or_404(todo_id, current_user, db)
    todo.done = payload.done
    db.commit()
    db.refresh(todo)
    return todo


@router.delete("/{todo_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_todo(
    todo_id: int,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> None:
    todo = get_owned_todo_or_404(todo_id, current_user, db)
    db.delete(todo)
    db.commit()
