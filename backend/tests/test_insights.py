import json
import logging
from contextlib import contextmanager

import httpx

from app.main import app
from app.schemas.insights import ActionItem, InsightsNarrative
from app.services import insights

_NO_OVERRIDE = object()


@contextmanager
def override_insight_generator(generator=_NO_OVERRIDE):
    """Temporarily point `get_insight_generator` at `generator` (or, with
    no argument, remove any override so the real dependency runs), then
    restore whatever override was in place before — normally conftest's
    default fake — rather than deleting it outright."""
    key = insights.get_insight_generator
    previous = app.dependency_overrides.get(key, _NO_OVERRIDE)
    if generator is _NO_OVERRIDE:
        app.dependency_overrides.pop(key, None)
    else:
        app.dependency_overrides[key] = lambda: generator
    try:
        yield
    finally:
        if previous is _NO_OVERRIDE:
            app.dependency_overrides.pop(key, None)
        else:
            app.dependency_overrides[key] = previous


class _FnGenerator:
    """An `InsightGenerator` whose `generate` is the given function."""

    def __init__(self, fn):
        self._fn = fn

    def generate(self, dashboard, drift, user_set_asset_classes):
        return self._fn(dashboard, drift, user_set_asset_classes)


def _add_cash(client, headers, value=1000.0):
    account_id = client.post(
        "/accounts", json={"name": "RBC", "institution": "RBC", "account_type": "cash"}, headers=headers
    ).json()["id"]
    client.post(
        f"/accounts/{account_id}/snapshots",
        json={"taken_at": "2026-11-08", "holdings": [{"label": "Cash", "asset_class": "cash", "quantity": None, "value": value, "currency": "USD", "country": "CA"}]},
        headers=headers,
    )


def _set_target(client, headers, asset_class, pct):
    response = client.put(f"/targets/{asset_class}", json={"target_pct": pct}, headers=headers)
    assert response.status_code == 200


def test_insights_for_new_user_skips_deepseek_and_returns_empty_narrative(client, auth_header_for):
    headers = auth_header_for("a@example.com")

    def exploding_generate(dashboard, drift, user_set_asset_classes):
        raise AssertionError("should not be called for a zero-net-worth user")

    with override_insight_generator(_FnGenerator(exploding_generate)):
        response = client.get("/insights?currency=USD", headers=headers)

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
    _add_cash(client, headers)

    fake_result = InsightsNarrative(summary="You're heavily weighted to cash.", action_items=[ActionItem(asset_class="cash", suggestion="Consider diversifying into equities.")])
    with override_insight_generator(_FnGenerator(lambda *args: fake_result)):
        response = client.get("/insights?currency=USD", headers=headers)

    assert response.status_code == 200
    body = response.json()
    assert body["narrative_unavailable"] is False
    assert body["narrative"]["summary"] == "You're heavily weighted to cash."
    assert body["narrative"]["action_items"] == [{"asset_class": "cash", "suggestion": "Consider diversifying into equities."}]
    assert body["dashboard"]["net_worth"] == 1000.0


def test_insights_degrades_gracefully_on_generation_failure(client, auth_header_for):
    headers = auth_header_for("a@example.com")
    _add_cash(client, headers)

    def failing_generate(dashboard, drift, user_set_asset_classes):
        raise insights.InsightGenerationFailed("DeepSeek timed out")

    with override_insight_generator(_FnGenerator(failing_generate)):
        response = client.get("/insights?currency=USD", headers=headers)

    assert response.status_code == 200
    body = response.json()
    assert body["narrative_unavailable"] is True
    assert body["dashboard"]["net_worth"] == 1000.0


def test_override_helper_restores_the_default_fake_for_later_requests(client, auth_header_for):
    """A second request in the same test must fall back to conftest's
    default fake, not the real DeepSeek dependency."""
    headers = auth_header_for("a@example.com")
    _add_cash(client, headers)

    def failing_generate(dashboard, drift, user_set_asset_classes):
        raise insights.InsightGenerationFailed("boom")

    with override_insight_generator(_FnGenerator(failing_generate)):
        assert client.get("/insights?currency=USD", headers=headers).json()["narrative_unavailable"] is True

    body = client.get("/insights?currency=USD", headers=headers).json()
    assert body["narrative_unavailable"] is False
    assert body["narrative"]["summary"] == "Stub insight narrative."


# --- Fix 1: target provenance reaches the prompt -----------------------------


def test_insights_passes_user_set_provenance_to_the_generator(client, auth_header_for):
    headers = auth_header_for("a@example.com")
    _add_cash(client, headers)
    _set_target(client, headers, "crypto", 50.0)
    seen = []

    def recording_generate(dashboard, drift, user_set_asset_classes):
        seen.append(user_set_asset_classes)
        return InsightsNarrative(summary="ok", action_items=[])

    with override_insight_generator(_FnGenerator(recording_generate)):
        assert client.get("/insights?currency=USD", headers=headers).status_code == 200

    assert seen == [frozenset({"crypto"})]


def test_insights_prompt_distinguishes_default_and_user_set_targets_end_to_end(client, auth_header_for):
    """Through the real `DeepSeekInsightGenerator` (mock transport), the
    prompt actually sent caveats default targets and not user-set ones."""
    headers = auth_header_for("a@example.com")
    _add_cash(client, headers)  # 100% cash: every default target drifts
    _set_target(client, headers, "crypto", 50.0)  # user-set, actual 0% -> drifts
    captured = []

    def handler(request):
        captured.append(request)
        content = json.dumps({"summary": "ok", "action_items": []})
        return httpx.Response(200, json={"choices": [{"message": {"content": content}}]})

    generator = insights.DeepSeekInsightGenerator(api_key="k", client=httpx.Client(transport=httpx.MockTransport(handler)))
    with override_insight_generator(generator):
        assert client.get("/insights?currency=USD", headers=headers).json()["narrative_unavailable"] is False

    prompt = json.loads(captured[0].content)["messages"][0]["content"]
    lines = {line.split(":")[0][2:]: line for line in prompt.splitlines() if line.startswith("- ")}
    assert "user-set target" in lines["crypto"]
    assert "default" not in lines["crypto"]
    for default_class in ("cash", "equity", "bond"):
        assert "system default — not something the user chose" in lines[default_class]


# --- Fixes 3 & 4: structural never-500 backstop, and logging ----------------


def test_insights_backstop_degrades_on_an_unanticipated_exception_type(client, auth_header_for, caplog):
    headers = auth_header_for("a@example.com")
    _add_cash(client, headers)

    def surprising_generate(dashboard, drift, user_set_asset_classes):
        raise RuntimeError("secret-ish detail that must not be logged")

    with caplog.at_level(logging.WARNING, logger="app.routers.insights"):
        with override_insight_generator(_FnGenerator(surprising_generate)):
            response = client.get("/insights?currency=USD", headers=headers)

    assert response.status_code == 200
    body = response.json()
    assert body["narrative_unavailable"] is True
    assert body["dashboard"]["net_worth"] == 1000.0
    assert len(body["drift"]) > 0
    [record] = [r for r in caplog.records if r.name == "app.routers.insights"]
    assert record.levelno == logging.WARNING
    assert "RuntimeError" in record.getMessage()
    assert "secret-ish detail" not in caplog.text


def test_insights_backstop_degrades_when_generator_returns_garbage(client, auth_header_for):
    headers = auth_header_for("a@example.com")
    _add_cash(client, headers)

    with override_insight_generator(_FnGenerator(lambda *args: object())):
        response = client.get("/insights?currency=USD", headers=headers)

    assert response.status_code == 200
    assert response.json()["narrative_unavailable"] is True


def test_insights_logs_generation_failure_category_without_secrets_or_prompt(client, auth_header_for, caplog):
    headers = auth_header_for("a@example.com")
    _add_cash(client, headers)
    api_key = "sk-super-secret-deepseek-key"

    def handler(request):
        return httpx.Response(500, text="upstream exploded")

    generator = insights.DeepSeekInsightGenerator(api_key=api_key, client=httpx.Client(transport=httpx.MockTransport(handler)))
    with caplog.at_level(logging.DEBUG):
        with override_insight_generator(generator):
            response = client.get("/insights?currency=USD", headers=headers)

    assert response.json()["narrative_unavailable"] is True
    [record] = [r for r in caplog.records if r.name == "app.routers.insights"]
    assert record.levelno == logging.WARNING
    message = record.getMessage()
    assert "InsightGenerationFailed" in message
    assert "category=http_status" in message
    assert api_key not in caplog.text
    assert "Net worth" not in caplog.text  # no prompt content
    assert "upstream exploded" not in caplog.text


def test_insights_success_logs_nothing(client, auth_header_for, caplog):
    headers = auth_header_for("a@example.com")
    _add_cash(client, headers)
    with caplog.at_level(logging.WARNING, logger="app.routers.insights"):
        client.get("/insights?currency=USD", headers=headers)
    assert [r for r in caplog.records if r.name == "app.routers.insights"] == []


# --- Fix 5: action items limited to drifted asset classes -------------------


def test_insights_filters_action_items_to_drifted_asset_classes(client, auth_header_for):
    headers = auth_header_for("a@example.com")
    _add_cash(client, headers)
    # Only crypto (default 10% vs actual 0%) drifts; cash/equity/bond match.
    _set_target(client, headers, "cash", 100.0)
    _set_target(client, headers, "equity", 0.0)
    _set_target(client, headers, "bond", 0.0)

    fake_result = InsightsNarrative(
        summary="Mostly cash.",
        action_items=[
            ActionItem(asset_class="cash", suggestion="not drifted — must be dropped"),
            ActionItem(asset_class=" Crypto ", suggestion="Consider a small crypto allocation."),
            ActionItem(asset_class="gold", suggestion="not an asset class at all"),
        ],
    )
    with override_insight_generator(_FnGenerator(lambda *args: fake_result)):
        body = client.get("/insights?currency=USD", headers=headers).json()

    assert [flag["asset_class"] for flag in body["drift"]] == ["crypto"]
    assert body["narrative_unavailable"] is False
    assert body["narrative"]["action_items"] == [
        {"asset_class": "crypto", "suggestion": "Consider a small crypto allocation."}
    ]


# --- Fix 8: a missing API key degrades instead of failing ---------------------


def test_insights_degrades_when_no_deepseek_api_key_is_configured(client, auth_header_for, monkeypatch):
    from app.config import get_settings

    headers = auth_header_for("a@example.com")
    _add_cash(client, headers)
    settings = get_settings().model_copy(update={"deepseek_api_key": None})
    monkeypatch.setattr(insights, "get_settings", lambda: settings)

    def no_client(*args, **kwargs):
        raise AssertionError("no HTTP client may be built without an API key")

    monkeypatch.setattr(insights.httpx, "Client", no_client)

    with override_insight_generator():  # the real dependency
        response = client.get("/insights?currency=USD", headers=headers)

    assert response.status_code == 200
    body = response.json()
    assert body["narrative_unavailable"] is True
    assert body["dashboard"]["net_worth"] == 1000.0
