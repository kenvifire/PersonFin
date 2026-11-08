"""FastAPI dependency that every protected router depends on to resolve
the current authenticated `User` from the request's bearer token.
"""

from fastapi import Depends, HTTPException, Request, status
from sqlalchemy.orm import Session

from app.auth.session import InvalidSessionToken, decode_session_token
from app.db import get_db
from app.models import User

UNAUTHORIZED = HTTPException(
    status_code=status.HTTP_401_UNAUTHORIZED,
    detail="Not authenticated",
    headers={"WWW-Authenticate": "Bearer"},
)


def get_current_user(request: Request, db: Session = Depends(get_db)) -> User:
    """Resolve the `User` identified by the request's
    `Authorization: Bearer <token>` header.

    Raises `HTTPException(401)` if the header is missing/malformed, the
    token is invalid or expired, or it names a user that no longer
    exists.
    """
    authorization = request.headers.get("Authorization")
    if not authorization or not authorization.startswith("Bearer "):
        raise UNAUTHORIZED

    token = authorization.removeprefix("Bearer ").strip()
    try:
        user_id = decode_session_token(token)
    except InvalidSessionToken as exc:
        raise UNAUTHORIZED from exc

    user = db.get(User, user_id)
    if user is None:
        raise UNAUTHORIZED

    return user
