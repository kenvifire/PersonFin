def test_cors_allows_localhost_origin(client):
    response = client.get(
        "/health",
        headers={"Origin": "http://localhost:5173"},
    )
    assert response.headers["access-control-allow-origin"] == "http://localhost:5173"
