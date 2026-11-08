"""Login routes. `POST /auth/google` exchanges a Google ID token for a
PersonFin session token, creating the `User` row on first login.
"""

from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel
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


@router.post("/google", response_model=GoogleLoginResponse)
def google_login(payload: GoogleLoginRequest, db: Session = Depends(get_db)) -> GoogleLoginResponse:
    try:
        profile = verify_google_id_token(payload.id_token)
    except InvalidGoogleToken as exc:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid Google ID token",
        ) from exc

    user = db.query(User).filter(User.google_sub == profile.sub).first()
    if user is None:
        user = User(google_sub=profile.sub, email=profile.email)
        db.add(user)
        db.commit()
        db.refresh(user)

    access_token = create_session_token(user.id)
    return GoogleLoginResponse(access_token=access_token, user=UserOut.model_validate(user))
