"""`DeepSeekInsightGenerator`: mocked-transport tests only, never the
real network."""

import json
import threading
import time

import httpx
import pytest
from pydantic import ValidationError

from app.schemas.dashboard import DashboardOut
from app.schemas.insights import InsightsNarrative
from app.schemas.target import DriftFlag
from app.services.insights import (
    DEEPSEEK_HTTP_TIMEOUT_SECONDS,
    DeepSeekInsightGenerator,
    InsightGenerationFailed,
)


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
    result = generator.generate(_dashboard(), drift, frozenset({"crypto"}))
    assert "crypto" in result.summary.lower() or "cash" in result.summary.lower()
    assert result.action_items[0].asset_class == "crypto"


def test_deepseek_generator_wraps_bad_status_as_insight_generation_failed():
    def handler(request):
        return httpx.Response(500, text="server error")
    client = httpx.Client(transport=httpx.MockTransport(handler))
    generator = DeepSeekInsightGenerator(api_key="k", client=client)
    with pytest.raises(InsightGenerationFailed):
        generator.generate(_dashboard(), [], frozenset())


def test_deepseek_generator_wraps_malformed_content_as_insight_generation_failed():
    def handler(request):
        return httpx.Response(200, json={"choices": [{"message": {"content": "not json"}}]})
    client = httpx.Client(transport=httpx.MockTransport(handler))
    generator = DeepSeekInsightGenerator(api_key="k", client=client)
    with pytest.raises(InsightGenerationFailed):
        generator.generate(_dashboard(), [], frozenset())


def test_deepseek_generator_wraps_connection_error_as_insight_generation_failed():
    def handler(request):
        raise httpx.ConnectError("boom")
    client = httpx.Client(transport=httpx.MockTransport(handler))
    generator = DeepSeekInsightGenerator(api_key="k", client=client)
    with pytest.raises(InsightGenerationFailed):
        generator.generate(_dashboard(), [], frozenset())


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
        generator.generate(_dashboard(), [], frozenset())


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
        generator.generate(_dashboard(), [], frozenset())


def test_get_insight_generator_closes_its_client_after_the_request():
    from app.services.insights import get_insight_generator

    dependency = get_insight_generator()
    generator = next(dependency)
    client = generator._client
    assert not client.is_closed

    with pytest.raises(StopIteration):
        next(dependency)  # FastAPI resumes the generator once the request is done

    assert client.is_closed


# --- Final-review fix wave -------------------------------------------------


def _valid_body(summary="Looks fine.", action_items=()):
    return {"choices": [{"message": {"content": json.dumps({
        "summary": summary, "action_items": list(action_items),
    })}}]}


def _capturing_generator(captured, **kwargs):
    """A real `DeepSeekInsightGenerator` over a mock transport that
    records every outgoing request and answers with a valid body."""

    def handler(request):
        captured.append(request)
        return httpx.Response(200, json=_valid_body())

    client = httpx.Client(transport=httpx.MockTransport(handler))
    return DeepSeekInsightGenerator(api_key="k", client=client, **kwargs)


def _prompt_from(request) -> str:
    return json.loads(request.content)["messages"][0]["content"]


def _drift_line(prompt: str, asset_class: str) -> str:
    [line] = [line for line in prompt.splitlines() if line.startswith(f"- {asset_class}:")]
    return line


def test_prompt_marks_default_targets_as_system_defaults_and_user_set_targets_as_user_set():
    """Spec anti-goal: a system-invented target must never be presented
    as if the user set it. The prompt has to tell the model which is which."""
    captured = []
    generator = _capturing_generator(captured)
    drift = [
        DriftFlag(asset_class="crypto", target_pct=10.0, actual_pct=16.0, delta_pct=6.0),  # user-set
        DriftFlag(asset_class="cash", target_pct=20.0, actual_pct=84.0, delta_pct=64.0),  # default
    ]

    generator.generate(_dashboard(), drift, frozenset({"crypto"}))

    prompt = _prompt_from(captured[0])
    cash_line = _drift_line(prompt, "cash")
    crypto_line = _drift_line(prompt, "crypto")
    assert "system default" in cash_line
    assert "not something the user chose" in cash_line
    assert "user-set" in crypto_line
    assert "default" not in crypto_line
    assert "not something the user chose" not in crypto_line
    # ...and the model is told how to treat the default ones.
    assert "suggestion to consider" in prompt
    assert "stated goal" in prompt


def test_prompt_treats_asset_classes_without_provenance_as_system_defaults():
    """Fail-safe direction: anything not explicitly known to be user-set
    is caveated as a default, never presented as the user's choice."""
    captured = []
    generator = _capturing_generator(captured)
    drift = [DriftFlag(asset_class="bond", target_pct=10.0, actual_pct=0.0, delta_pct=-10.0)]

    generator.generate(_dashboard(), drift, frozenset())

    assert "system default" in _drift_line(_prompt_from(captured[0]), "bond")


def test_prompt_rounds_numbers_and_serializes_breakdowns_as_json():
    captured = []
    generator = _capturing_generator(captured)
    dashboard = DashboardOut(
        net_worth=1234.56789, currency="USD",
        by_asset_class={"cash": 1000.123456, "crypto": 234.444444},
        by_country={"CA": 1234.56789},
        accounts=[], trend=[],
    )
    drift = [DriftFlag(asset_class="crypto", target_pct=10.0, actual_pct=18.98989898, delta_pct=8.98989898)]

    generator.generate(dashboard, drift, frozenset())

    prompt = _prompt_from(captured[0])
    assert "1234.57" in prompt
    assert "1234.56789" not in prompt
    assert "18.99" in prompt
    assert "8.98989898" not in prompt
    assert '{"cash": 1000.12, "crypto": 234.44}' in prompt
    assert '{"CA": 1234.57}' in prompt
    assert "{'cash'" not in prompt  # no Python dict repr


def test_generate_enforces_a_wall_clock_deadline_against_a_trickling_response():
    """A server that keeps sending a byte well inside the per-read
    timeout resets httpx's read timeout forever. The deadline has to be
    total wall-clock time, not per read."""
    stop = threading.Event()

    def trickle():
        # Capped at 5s so a regression fails the timing assertion below
        # rather than hanging the suite.
        started_trickling = time.monotonic()
        yield b"{"
        while not stop.is_set() and time.monotonic() - started_trickling < 5.0:
            time.sleep(0.05)
            yield b" "

    def handler(request):
        return httpx.Response(200, content=trickle())

    # Per-read timeout far larger than the deadline, so only the deadline can fire.
    client = httpx.Client(transport=httpx.MockTransport(handler), timeout=30.0)
    generator = DeepSeekInsightGenerator(api_key="k", client=client, deadline_seconds=0.5)

    started = time.monotonic()
    try:
        with pytest.raises(InsightGenerationFailed) as excinfo:
            generator.generate(_dashboard(), [], frozenset())
        elapsed = time.monotonic() - started
    finally:
        stop.set()

    assert elapsed < 2.0
    assert excinfo.value.category == "timeout"


def test_abandoned_deepseek_call_stops_reading_on_its_own():
    """After the caller gives up, the worker thread must not keep
    consuming a trickling response in the background."""
    chunks_sent = []

    def trickle():
        started_trickling = time.monotonic()
        yield b"{"
        while time.monotonic() - started_trickling < 5.0:
            time.sleep(0.02)
            chunks_sent.append(1)
            yield b" "

    client = httpx.Client(
        transport=httpx.MockTransport(lambda request: httpx.Response(200, content=trickle())),
        timeout=30.0,
    )
    generator = DeepSeekInsightGenerator(api_key="k", client=client, deadline_seconds=0.3)
    with pytest.raises(InsightGenerationFailed):
        generator.generate(_dashboard(), [], frozenset())

    time.sleep(0.3)  # let the worker notice the deadline on its next chunk
    sent_after_settling = len(chunks_sent)
    time.sleep(0.3)
    assert len(chunks_sent) == sent_after_settling


def test_generate_default_deadline_is_the_configured_http_timeout():
    client = httpx.Client(transport=httpx.MockTransport(lambda r: httpx.Response(200, json=_valid_body())))
    generator = DeepSeekInsightGenerator(api_key="k", client=client)
    assert generator._deadline_seconds == DEEPSEEK_HTTP_TIMEOUT_SECONDS


def test_deeply_nested_content_raising_recursion_error_is_wrapped():
    """`json.loads` raises `RecursionError` (not `ValueError`) on deeply
    nested input; that must not escape as a bare 500."""
    nested = "[" * 200_000 + "]" * 200_000
    client = httpx.Client(transport=httpx.MockTransport(
        lambda r: httpx.Response(200, json={"choices": [{"message": {"content": nested}}]})
    ))
    generator = DeepSeekInsightGenerator(api_key="k", client=client)
    with pytest.raises(InsightGenerationFailed):
        generator.generate(_dashboard(), [], frozenset())


def test_deeply_nested_response_body_raising_recursion_error_is_wrapped():
    nested = b"[" * 200_000 + b"]" * 200_000
    client = httpx.Client(transport=httpx.MockTransport(lambda r: httpx.Response(200, content=nested)))
    generator = DeepSeekInsightGenerator(api_key="k", client=client)
    with pytest.raises(InsightGenerationFailed):
        generator.generate(_dashboard(), [], frozenset())


def test_unanticipated_exception_inside_generate_is_wrapped(monkeypatch):
    import app.services.insights as insights_module

    def boom(*args, **kwargs):
        raise LookupError("something nobody planned for")

    monkeypatch.setattr(insights_module.InsightsNarrative, "model_validate", boom)
    client = httpx.Client(transport=httpx.MockTransport(lambda r: httpx.Response(200, json=_valid_body())))
    generator = DeepSeekInsightGenerator(api_key="k", client=client)
    with pytest.raises(InsightGenerationFailed):
        generator.generate(_dashboard(), [], frozenset())


@pytest.mark.parametrize("summary", ["", "   ", "\n\t "], ids=["empty", "spaces", "whitespace"])
def test_empty_summary_is_rejected_as_insight_generation_failed(summary):
    client = httpx.Client(transport=httpx.MockTransport(
        lambda r: httpx.Response(200, json=_valid_body(summary=summary))
    ))
    generator = DeepSeekInsightGenerator(api_key="k", client=client)
    with pytest.raises(InsightGenerationFailed) as excinfo:
        generator.generate(_dashboard(), [], frozenset())
    # Flows through the existing pydantic ValidationError path.
    assert excinfo.value.category == "schema_mismatch"
    assert isinstance(excinfo.value.__cause__, ValidationError)


@pytest.mark.parametrize("summary", ["", "   "])
def test_insights_narrative_rejects_blank_summary(summary):
    with pytest.raises(ValidationError):
        InsightsNarrative(summary=summary, action_items=[])


@pytest.mark.parametrize("missing_key", [None, ""], ids=["none", "empty"])
def test_missing_api_key_degrades_without_any_network_io(monkeypatch, missing_key):
    import app.services.insights as insights_module
    from app.config import get_settings

    settings = get_settings().model_copy(update={"deepseek_api_key": missing_key})
    monkeypatch.setattr(insights_module, "get_settings", lambda: settings)

    def no_client(*args, **kwargs):
        raise AssertionError("no HTTP client may be built without an API key")

    monkeypatch.setattr(insights_module.httpx, "Client", no_client)

    dependency = insights_module.get_insight_generator()
    generator = next(dependency)
    with pytest.raises(InsightGenerationFailed) as excinfo:
        generator.generate(_dashboard(), [], frozenset())
    assert excinfo.value.category == "missing_api_key"
    with pytest.raises(StopIteration):
        next(dependency)
