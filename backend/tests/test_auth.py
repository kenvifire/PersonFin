from app.auth.google_oauth import GoogleProfile
from app.auth.session import decode_session_token


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
