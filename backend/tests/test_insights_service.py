"""`DeepSeekInsightGenerator`: mocked-transport tests only, never the
real network."""

import json

import httpx
import pytest

from app.schemas.dashboard import DashboardOut
from app.schemas.target import DriftFlag
from app.services.insights import DeepSeekInsightGenerator, InsightGenerationFailed


def _dashboard():
    return DashboardOut(
        net_worth=1000.0, currency="USD",
        by_asset_class={"crypto": 160.0, "cash": 840.0}, by_country={"CA": 1000.0},
        accounts=[], trend=[],
    )


def test_deepseek_generator_parses_valid_response():
    def handler(request):
        body = {"choices": [{"message": {"content": json.dumps({
            "summary": "Your portfolio is mostly cash with a growing crypto position.",
            "action_items": [{"asset_class": "crypto", "suggestion": "Consider trimming crypto back toward your 10% target."}],
        })}}]}
        return httpx.Response(200, json=body)
    client = httpx.Client(transport=httpx.MockTransport(handler))
    generator = DeepSeekInsightGenerator(api_key="k", client=client)

    drift = [DriftFlag(asset_class="crypto", target_pct=10.0, actual_pct=16.0, delta_pct=6.0)]
    result = generator.generate(_dashboard(), drift)
    assert "crypto" in result.summary.lower() or "cash" in result.summary.lower()
    assert result.action_items[0].asset_class == "crypto"


def test_deepseek_generator_wraps_bad_status_as_insight_generation_failed():
    def handler(request):
        return httpx.Response(500, text="server error")
    client = httpx.Client(transport=httpx.MockTransport(handler))
    generator = DeepSeekInsightGenerator(api_key="k", client=client)
    with pytest.raises(InsightGenerationFailed):
        generator.generate(_dashboard(), [])


def test_deepseek_generator_wraps_malformed_content_as_insight_generation_failed():
    def handler(request):
        return httpx.Response(200, json={"choices": [{"message": {"content": "not json"}}]})
    client = httpx.Client(transport=httpx.MockTransport(handler))
    generator = DeepSeekInsightGenerator(api_key="k", client=client)
    with pytest.raises(InsightGenerationFailed):
        generator.generate(_dashboard(), [])


def test_deepseek_generator_wraps_connection_error_as_insight_generation_failed():
    def handler(request):
        raise httpx.ConnectError("boom")
    client = httpx.Client(transport=httpx.MockTransport(handler))
    generator = DeepSeekInsightGenerator(api_key="k", client=client)
    with pytest.raises(InsightGenerationFailed):
        generator.generate(_dashboard(), [])


@pytest.mark.parametrize(
    "response",
    [
        httpx.Response(500, text="boom"),
        httpx.Response(200, text="<html>not json</html>"),
        httpx.Response(200, json={"choices": []}),
        httpx.Response(200, json={"choices": [{"message": {}}]}),
        httpx.Response(200, json={"choices": [{}]}),
        httpx.Response(
            200,
            json={"choices": [{"message": {"content": json.dumps({"summary": "ok", "action_items": "not-a-list"})}}]},
        ),
        httpx.Response(
            200,
            json={"choices": [{"message": {"content": json.dumps({"action_items": []})}}]},
        ),
    ],
    ids=[
        "server-error",
        "non-json",
        "no-choices",
        "no-content",
        "no-message",
        "schema-mismatch",
        "missing-summary",
    ],
)
def test_deepseek_generator_bad_responses_raise_insight_generation_failed(response):
    client = httpx.Client(transport=httpx.MockTransport(lambda request: response))
    generator = DeepSeekInsightGenerator(api_key="k", client=client)
    with pytest.raises(InsightGenerationFailed):
        generator.generate(_dashboard(), [])


@pytest.mark.parametrize(
    "error",
    [httpx.ConnectError("refused"), httpx.ReadTimeout("slow")],
    ids=["connect-error", "timeout"],
)
def test_deepseek_generator_transport_errors_raise_insight_generation_failed(error):
    def handler(request):
        raise error

    client = httpx.Client(transport=httpx.MockTransport(handler))
    generator = DeepSeekInsightGenerator(api_key="k", client=client)
    with pytest.raises(InsightGenerationFailed):
        generator.generate(_dashboard(), [])


def test_get_insight_generator_closes_its_client_after_the_request():
    from app.services.insights import get_insight_generator

    dependency = get_insight_generator()
    generator = next(dependency)
    client = generator._client
    assert not client.is_closed

    with pytest.raises(StopIteration):
        next(dependency)  # FastAPI resumes the generator once the request is done

    assert client.is_closed
