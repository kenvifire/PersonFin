from app.main import app
from app.schemas.insights import ActionItem, InsightsNarrative
from app.services import insights


def test_insights_for_new_user_skips_deepseek_and_returns_empty_narrative(client, auth_header_for):
    headers = auth_header_for("a@example.com")

    def exploding_generate(dashboard, drift):
        raise AssertionError("should not be called for a zero-net-worth user")
    app.dependency_overrides[insights.get_insight_generator] = lambda: type("G", (), {"generate": staticmethod(exploding_generate)})()

    response = client.get("/insights?currency=USD", headers=headers)
    del app.dependency_overrides[insights.get_insight_generator]

    assert response.status_code == 200
    body = response.json()
    assert body["dashboard"]["net_worth"] == 0.0
    assert body["drift"] == []
    assert body["narrative_unavailable"] is False
    assert "no holdings" in body["narrative"]["summary"].lower()


def test_insights_rejects_unsupported_currency(client, auth_header_for):
    headers = auth_header_for("a@example.com")
    response = client.get("/insights?currency=XYZ", headers=headers)
    assert response.status_code == 422


def test_insights_returns_narrative_on_success(client, auth_header_for):
    headers = auth_header_for("a@example.com")
    account_id = client.post(
        "/accounts", json={"name": "RBC", "institution": "RBC", "account_type": "cash"}, headers=headers
    ).json()["id"]
    client.post(
        f"/accounts/{account_id}/snapshots",
        json={"taken_at": "2026-11-08", "holdings": [{"label": "Cash", "asset_class": "cash", "quantity": None, "value": 1000.0, "currency": "USD", "country": "CA"}]},
        headers=headers,
    )

    fake_result = InsightsNarrative(summary="You're heavily weighted to cash.", action_items=[ActionItem(asset_class="cash", suggestion="Consider diversifying into equities.")])
    app.dependency_overrides[insights.get_insight_generator] = lambda: type("G", (), {"generate": staticmethod(lambda dashboard, drift: fake_result)})()
    response = client.get("/insights?currency=USD", headers=headers)
    del app.dependency_overrides[insights.get_insight_generator]

    assert response.status_code == 200
    body = response.json()
    assert body["narrative_unavailable"] is False
    assert body["narrative"]["summary"] == "You're heavily weighted to cash."
    assert body["dashboard"]["net_worth"] == 1000.0


def test_insights_degrades_gracefully_on_generation_failure(client, auth_header_for):
    headers = auth_header_for("a@example.com")
    account_id = client.post(
        "/accounts", json={"name": "RBC", "institution": "RBC", "account_type": "cash"}, headers=headers
    ).json()["id"]
    client.post(
        f"/accounts/{account_id}/snapshots",
        json={"taken_at": "2026-11-08", "holdings": [{"label": "Cash", "asset_class": "cash", "quantity": None, "value": 1000.0, "currency": "USD", "country": "CA"}]},
        headers=headers,
    )

    def failing_generate(dashboard, drift):
        raise insights.InsightGenerationFailed("DeepSeek timed out")
    app.dependency_overrides[insights.get_insight_generator] = lambda: type("G", (), {"generate": staticmethod(failing_generate)})()
    response = client.get("/insights?currency=USD", headers=headers)
    del app.dependency_overrides[insights.get_insight_generator]

    assert response.status_code == 200
    body = response.json()
    assert body["narrative_unavailable"] is True
    assert body["dashboard"]["net_worth"] == 1000.0
