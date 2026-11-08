"""Verification of Google-issued OpenID Connect ID tokens.

`verify_google_id_token` fetches Google's current public keys and checks
the token's signature, issuer, audience, and expiry via Authlib. Tests
monkeypatch this function rather than hitting Google's network endpoints.
"""

from dataclasses import dataclass

import httpx
from authlib.jose import JsonWebKey, jwt
from authlib.jose.errors import JoseError

from app.config import get_settings

GOOGLE_JWKS_URL = "https://www.googleapis.com/oauth2/v3/certs"
GOOGLE_ISSUERS = ["https://accounts.google.com", "accounts.google.com"]


class InvalidGoogleToken(Exception):
    """Raised when a Google ID token fails verification."""


@dataclass
class GoogleProfile:
    sub: str
    email: str


def verify_google_id_token(token: str) -> GoogleProfile:
    """Verify a Google-issued OpenID Connect ID token and return the
    caller's profile.

    Raises `InvalidGoogleToken` if the token's signature, issuer,
    audience, or expiry do not check out, or if it is missing required
    claims.
    """
    settings = get_settings()

    try:
        response = httpx.get(GOOGLE_JWKS_URL, timeout=10)
        response.raise_for_status()
        jwk_set = JsonWebKey.import_key_set(response.json())

        claims_options = {
            "iss": {"values": GOOGLE_ISSUERS},
            "aud": {"value": settings.google_client_id},
        }
        claims = jwt.decode(token, jwk_set, claims_options=claims_options)
        claims.validate()
    except JoseError as exc:
        raise InvalidGoogleToken("invalid Google ID token") from exc
    except httpx.HTTPError as exc:
        raise InvalidGoogleToken("could not reach Google to verify ID token") from exc

    sub = claims.get("sub")
    email = claims.get("email")
    if not sub or not email:
        raise InvalidGoogleToken("Google ID token is missing sub/email claims")

    return GoogleProfile(sub=sub, email=email)
