"""Session tokens: short-lived, server-signed JWTs identifying a logged-in
user, issued after a successful Google login and required by
`app.auth.dependencies.get_current_user` on every protected route.
"""

from datetime import datetime, timedelta, timezone

import jwt

from app.config import get_settings

ALGORITHM = "HS256"
DEFAULT_EXPIRY = timedelta(days=7)


class InvalidSessionToken(Exception):
    """Raised when a session token is missing, malformed, unsigned by us,
    or expired."""


def create_session_token(user_id: int, expires_delta: timedelta = DEFAULT_EXPIRY) -> str:
    """Issue a signed session token encoding `user_id`."""
    settings = get_settings()
    now = datetime.now(timezone.utc)
    payload = {"sub": str(user_id), "iat": now, "exp": now + expires_delta}
    return jwt.encode(payload, settings.jwt_secret, algorithm=ALGORITHM)


def decode_session_token(token: str) -> int:
    """Decode a session token and return the `user_id` it encodes.

    Raises `InvalidSessionToken` if the token is malformed, unsigned by
    us, or expired.
    """
    settings = get_settings()
    try:
        payload = jwt.decode(token, settings.jwt_secret, algorithms=[ALGORITHM])
        return int(payload["sub"])
    except (jwt.PyJWTError, KeyError, ValueError, TypeError) as exc:
        raise InvalidSessionToken("invalid or expired session token") from exc
