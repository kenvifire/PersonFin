"""Login routes. `POST /auth/google` exchanges a Google ID token for a
PersonFin session token, creating the `User` row on first login.

A user's identity is their Google `sub`, never their email: emails are
not unique across users, and `google_sub` is the only uniqueness
constraint on `users`.
"""

from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from app.auth.google_oauth import InvalidGoogleToken, verify_google_id_token
from app.auth.session import create_session_token
from app.db import get_db
from app.models import User

router = APIRouter(prefix="/auth", tags=["auth"])


class GoogleLoginRequest(BaseModel):
    id_token: str


class UserOut(BaseModel):
    id: int
    email: str

    model_config = {"from_attributes": True}


class GoogleLoginResponse(BaseModel):
    access_token: str
    user: UserOut


def _find_user_by_sub(db: Session, google_sub: str) -> User | None:
    return db.query(User).filter(User.google_sub == google_sub).first()


def _get_or_create_user(db: Session, google_sub: str, email: str) -> User:
    user = _find_user_by_sub(db, google_sub)
    if user is not None:
        return user

    user = User(google_sub=google_sub, email=email)
    db.add(user)
    try:
        db.commit()
    except IntegrityError:
        # A concurrent first login for the same `sub` committed between
        # our lookup and insert. That's a successful login, not an
        # error: roll back and use the row the other request created.
        db.rollback()
        user = _find_user_by_sub(db, google_sub)
        if user is None:
            raise
        return user
    db.refresh(user)
    return user


@router.post("/google", response_model=GoogleLoginResponse)
def google_login(payload: GoogleLoginRequest, db: Session = Depends(get_db)) -> GoogleLoginResponse:
    try:
        profile = verify_google_id_token(payload.id_token)
    except InvalidGoogleToken as exc:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid Google ID token",
        ) from exc

    user = _get_or_create_user(db, profile.sub, profile.email)
    access_token = create_session_token(user.id)
    return GoogleLoginResponse(access_token=access_token, user=UserOut.model_validate(user))
