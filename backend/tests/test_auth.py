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
