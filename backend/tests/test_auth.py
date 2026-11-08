import base64
import hashlib
import hmac
import json

import httpx
import pytest
from authlib.jose import JsonWebKey

from app.auth.google_oauth import GoogleProfile, InvalidGoogleToken, verify_google_id_token
from app.auth.session import decode_session_token


def _b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def test_google_login_creates_user_and_returns_token(client, monkeypatch):
    monkeypatch.setattr(
        "app.routers.auth.verify_google_id_token",
        lambda token: GoogleProfile(sub="g-42", email="new@example.com"),
    )
    response = client.post("/auth/google", json={"id_token": "fake"})
    assert response.status_code == 200
    body = response.json()
    assert body["user"]["email"] == "new@example.com"
    assert decode_session_token(body["access_token"]) is not None


def test_protected_route_rejects_missing_token(client):
    response = client.get("/accounts")
    assert response.status_code == 401


def test_verify_google_id_token_rejects_algorithm_confusion_forgery(monkeypatch):
    """Exercise the real Authlib verification path (no monkeypatching of
    `verify_google_id_token` itself) with a crafted, adversarial token:
    header `{"alg": "HS256", "kid": "<a real key's kid>"}`, HMAC-"signed"
    using that key's RSA *public* key PEM bytes as the secret — an
    RS256->HS256 algorithm-confusion attempt.

    Authlib's `JsonWebKey`/`OctKey` machinery chokes on coercing the RSA
    key into an HMAC secret with a bare `KeyError`, not a `JoseError`.
    Before the fix, that `KeyError` propagated out of
    `verify_google_id_token` uncaught, which would surface as an
    unhandled 500 from `POST /auth/google` instead of a clean 401. This
    asserts it now fails closed as `InvalidGoogleToken`.

    The JWKS fetch is faked locally (no real network call to Google) by
    monkeypatching `httpx.get` to return a JWKS containing the
    attacker's own freshly generated RSA key under a chosen `kid` — this
    is exactly what `verify_google_id_token` would see for a Google
    `kid` it doesn't recognize, since the attacker's forged token can
    name any `kid` and the server has no way to know in advance which
    key a given token claims to use.
    """
    rsa_key = JsonWebKey.generate_key("RSA", 2048, is_private=True)
    kid = "test-key-1"
    public_jwk = rsa_key.as_dict(is_private=False)
    public_jwk["kid"] = kid
    fake_jwks = {"keys": [public_jwk]}

    def fake_get(url, timeout=10):
        return httpx.Response(200, json=fake_jwks, request=httpx.Request("GET", url))

    monkeypatch.setattr("app.auth.google_oauth.httpx.get", fake_get)

    public_pem = rsa_key.as_pem(is_private=False)
    header = {"alg": "HS256", "kid": kid, "typ": "JWT"}
    payload = {
        "sub": "attacker",
        "email": "attacker@example.com",
        "iss": "https://accounts.google.com",
        "aud": "test-google-client-id",
    }
    header_b64 = _b64url(json.dumps(header, separators=(",", ":")).encode())
    payload_b64 = _b64url(json.dumps(payload, separators=(",", ":")).encode())
    signing_input = f"{header_b64}.{payload_b64}".encode()
    signature = hmac.new(public_pem, signing_input, hashlib.sha256).digest()
    forged_token = f"{header_b64}.{payload_b64}.{_b64url(signature)}"

    with pytest.raises(InvalidGoogleToken):
        verify_google_id_token(forged_token)


def _login_as(client, monkeypatch, sub: str, email: str):
    monkeypatch.setattr(
        "app.routers.auth.verify_google_id_token",
        lambda token: GoogleProfile(sub=sub, email=email),
    )
    return client.post("/auth/google", json={"id_token": "fake"})


def test_distinct_google_subs_sharing_an_email_can_both_log_in(client, monkeypatch):
    """`google_sub` is the identity key; email is not unique."""
    first = _login_as(client, monkeypatch, "g-1", "shared@example.com")
    second = _login_as(client, monkeypatch, "g-2", "shared@example.com")

    assert first.status_code == 200
    assert second.status_code == 200
    assert first.json()["user"]["id"] != second.json()["user"]["id"]

    again = _login_as(client, monkeypatch, "g-1", "shared@example.com")
    assert again.json()["user"]["id"] == first.json()["user"]["id"]


def test_concurrent_first_login_race_is_a_successful_login(client, monkeypatch, db_session):
    """Simulate two simultaneous first logins for the same `sub`: the
    other request's row is committed after our lookup found nothing, so
    our insert hits the `google_sub` unique constraint. That must resolve
    to the existing user, not a 500."""
    from app.models import User
    from app.routers import auth as auth_router

    winner = User(google_sub="g-race", email="race@example.com")
    db_session.add(winner)
    db_session.commit()
    winner_id = winner.id

    real_find = auth_router._find_user_by_sub
    lookups = []

    def find_missing_on_first_lookup(db, google_sub):
        lookups.append(google_sub)
        if len(lookups) == 1:
            return None  # the other request hadn't committed yet when we looked
        return real_find(db, google_sub)

    monkeypatch.setattr(auth_router, "_find_user_by_sub", find_missing_on_first_lookup)

    response = _login_as(client, monkeypatch, "g-race", "race@example.com")

    assert response.status_code == 200
    assert response.json()["user"]["id"] == winner_id
    assert len(lookups) == 2  # the insert really did collide and re-query
    assert decode_session_token(response.json()["access_token"]) == winner_id
    assert db_session.query(User).filter(User.google_sub == "g-race").count() == 1


def _signed_google_token(monkeypatch, claims: dict) -> str:
    """A genuinely RS256-signed token, verifiable against a faked JWKS
    containing the signing key."""
    from authlib.jose import jwt as authlib_jwt

    rsa_key = JsonWebKey.generate_key("RSA", 2048, is_private=True)
    public_jwk = rsa_key.as_dict(is_private=False)
    public_jwk["kid"] = "test-key-1"

    def fake_get(url, timeout=10):
        return httpx.Response(200, json={"keys": [public_jwk]}, request=httpx.Request("GET", url))

    monkeypatch.setattr("app.auth.google_oauth.httpx.get", fake_get)
    token = authlib_jwt.encode({"alg": "RS256", "kid": "test-key-1"}, claims, rsa_key)
    return token.decode()


_VALID_CLAIMS = {
    "sub": "g-exp",
    "email": "exp@example.com",
    "iss": "https://accounts.google.com",
    "aud": "test-google-client-id",
}


def test_verify_google_id_token_accepts_valid_signed_token(monkeypatch):
    import time

    token = _signed_google_token(monkeypatch, {**_VALID_CLAIMS, "exp": int(time.time()) + 600})
    assert verify_google_id_token(token) == GoogleProfile(sub="g-exp", email="exp@example.com")


def test_verify_google_id_token_requires_exp_claim(monkeypatch):
    token = _signed_google_token(monkeypatch, dict(_VALID_CLAIMS))  # no `exp`
    with pytest.raises(InvalidGoogleToken):
        verify_google_id_token(token)


def test_verify_google_id_token_rejects_expired_token(monkeypatch):
    import time

    token = _signed_google_token(monkeypatch, {**_VALID_CLAIMS, "exp": int(time.time()) - 600})
    with pytest.raises(InvalidGoogleToken):
        verify_google_id_token(token)
