"""Verification of Google-issued OpenID Connect ID tokens.

`verify_google_id_token` fetches Google's current public keys and checks
the token's signature, issuer, audience, and expiry via Authlib. Tests
monkeypatch this function rather than hitting Google's network endpoints.
"""

from dataclasses import dataclass

import httpx
from authlib.jose import JsonWebKey, jwt

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
    except httpx.HTTPError as exc:
        raise InvalidGoogleToken("could not reach Google to verify ID token") from exc

    try:
        jwk_set = JsonWebKey.import_key_set(response.json())

        claims_options = {
            "iss": {"values": GOOGLE_ISSUERS},
            "aud": {"value": settings.google_client_id},
        }
        claims = jwt.decode(token, jwk_set, claims_options=claims_options)
        claims.validate()
    except Exception as exc:
        # `token` is attacker-controlled input fed through several
        # layers of third-party parsing (JSON, base64, JWK coercion,
        # signature verification). Besides Authlib's own `JoseError`,
        # a malformed or adversarial token can trip a bare `KeyError`/
        # `ValueError`/`TypeError` deep inside that machinery (e.g. an
        # RS256->HS256 algorithm-confusion attempt that makes Authlib
        # try to use an RSA key as an HMAC secret). Every such failure
        # must fail closed as an invalid token, never as an unhandled
        # 500.
        raise InvalidGoogleToken("invalid Google ID token") from exc

    sub = claims.get("sub")
    email = claims.get("email")
    if not sub or not email:
        raise InvalidGoogleToken("Google ID token is missing sub/email claims")

    return GoogleProfile(sub=sub, email=email)
