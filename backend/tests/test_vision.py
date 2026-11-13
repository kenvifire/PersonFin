"""`DeepSeekVisionExtractor`, `OpenAIVisionExtractor`, and
`FallbackVisionExtractor`: mocked-transport tests only, never the real
network."""

import json

import httpx
import pytest

from app.services.vision import (
    DeepSeekVisionExtractor,
    ExtractionFailed,
    ExtractionResult,
    FallbackVisionExtractor,
    OpenAIVisionExtractor,
)


def test_deepseek_extractor_parses_valid_response():
    def handler(request):
        body = {
            "choices": [
                {
                    "message": {
                        "content": json.dumps(
                            {
                                "institution": "RBC",
                                "account_label": "RRSP",
                                "account_type_guess": "rrsp",
                                "taken_at_guess": "2026-11-01",
                                "holdings": [
                                    {
                                        "label": "VFV",
                                        "asset_class_guess": "equity",
                                        "quantity": 10,
                                        "value": 1000.0,
                                        "currency_guess": "CAD",
                                        "country_guess": "CA",
                                    }
                                ],
                            }
                        )
                    }
                }
            ]
        }
        return httpx.Response(200, json=body)

    client = httpx.Client(transport=httpx.MockTransport(handler))
    extractor = DeepSeekVisionExtractor(api_key="k", client=client)
    result = extractor.extract(b"fake-bytes", "image/png")
    assert result.institution == "RBC"
    assert result.holdings[0].label == "VFV"


def test_deepseek_extractor_sends_model_and_bearer_auth():
    captured = {}

    def handler(request):
        captured["auth"] = request.headers.get("authorization")
        captured["body"] = json.loads(request.content)
        body = {"choices": [{"message": {"content": json.dumps({"holdings": []})}}]}
        return httpx.Response(200, json=body)

    client = httpx.Client(transport=httpx.MockTransport(handler))
    extractor = DeepSeekVisionExtractor(api_key="secret-key", client=client)
    extractor.extract(b"fake-bytes", "image/png")

    assert captured["auth"] == "Bearer secret-key"
    assert captured["body"]["model"] == "deepseek-flash"
    content_blocks = captured["body"]["messages"][0]["content"]
    assert content_blocks[1]["type"] == "image_url"
    assert content_blocks[1]["image_url"]["url"].startswith("data:image/png;base64,")


def test_deepseek_extractor_wraps_malformed_response_as_extraction_failed():
    def handler(request):
        return httpx.Response(200, json={"choices": [{"message": {"content": "not json"}}]})

    client = httpx.Client(transport=httpx.MockTransport(handler))
    extractor = DeepSeekVisionExtractor(api_key="k", client=client)
    with pytest.raises(ExtractionFailed):
        extractor.extract(b"fake-bytes", "image/png")


@pytest.mark.parametrize(
    "response",
    [
        httpx.Response(500, text="boom"),
        httpx.Response(200, text="<html>not json</html>"),
        httpx.Response(200, json={"choices": []}),
        httpx.Response(200, json={"choices": [{"message": {}}]}),
        httpx.Response(200, json={"choices": [{"message": {"content": json.dumps({"holdings": "not-a-list"})}}]}),
    ],
    ids=["server-error", "non-json", "no-choices", "no-content", "schema-mismatch"],
)
def test_deepseek_extractor_bad_responses_raise_extraction_failed(response):
    client = httpx.Client(transport=httpx.MockTransport(lambda request: response))
    extractor = DeepSeekVisionExtractor(api_key="k", client=client)
    with pytest.raises(ExtractionFailed):
        extractor.extract(b"fake-bytes", "image/png")


@pytest.mark.parametrize(
    "error",
    [httpx.ConnectError("refused"), httpx.ReadTimeout("slow")],
    ids=["connect-error", "timeout"],
)
def test_deepseek_extractor_transport_errors_raise_extraction_failed(error):
    def handler(request):
        raise error

    client = httpx.Client(transport=httpx.MockTransport(handler))
    extractor = DeepSeekVisionExtractor(api_key="k", client=client)
    with pytest.raises(ExtractionFailed):
        extractor.extract(b"fake-bytes", "image/png")


def test_get_vision_extractor_closes_its_client_after_the_request():
    from app.services.vision import get_vision_extractor

    dependency = get_vision_extractor()
    extractor = next(dependency)
    client = extractor._client
    assert not client.is_closed

    with pytest.raises(StopIteration):
        next(dependency)  # FastAPI resumes the generator once the request is done

    assert client.is_closed


# --- OpenAIVisionExtractor: same shape as DeepSeekVisionExtractor -------------


def test_openai_extractor_parses_valid_response():
    def handler(request):
        body = {"choices": [{"message": {"content": json.dumps({"institution": "Fidelity", "holdings": []})}}]}
        return httpx.Response(200, json=body)

    client = httpx.Client(transport=httpx.MockTransport(handler))
    extractor = OpenAIVisionExtractor(api_key="k", client=client)
    result = extractor.extract(b"fake-bytes", "image/png")
    assert result.institution == "Fidelity"


def test_openai_extractor_sends_model_and_bearer_auth():
    captured = {}

    def handler(request):
        captured["auth"] = request.headers.get("authorization")
        captured["body"] = json.loads(request.content)
        body = {"choices": [{"message": {"content": json.dumps({"holdings": []})}}]}
        return httpx.Response(200, json=body)

    client = httpx.Client(transport=httpx.MockTransport(handler))
    extractor = OpenAIVisionExtractor(api_key="secret-key", client=client)
    extractor.extract(b"fake-bytes", "image/png")

    assert captured["auth"] == "Bearer secret-key"
    assert captured["body"]["model"] == "gpt-4o-mini"
    content_blocks = captured["body"]["messages"][0]["content"]
    assert content_blocks[1]["type"] == "image_url"
    assert content_blocks[1]["image_url"]["url"].startswith("data:image/png;base64,")


def test_openai_extractor_wraps_malformed_response_as_extraction_failed():
    def handler(request):
        return httpx.Response(200, json={"choices": [{"message": {"content": "not json"}}]})

    client = httpx.Client(transport=httpx.MockTransport(handler))
    extractor = OpenAIVisionExtractor(api_key="k", client=client)
    with pytest.raises(ExtractionFailed):
        extractor.extract(b"fake-bytes", "image/png")


@pytest.mark.parametrize(
    "response",
    [
        httpx.Response(500, text="boom"),
        httpx.Response(200, text="<html>not json</html>"),
        httpx.Response(200, json={"choices": []}),
    ],
    ids=["server-error", "non-json", "no-choices"],
)
def test_openai_extractor_bad_responses_raise_extraction_failed(response):
    client = httpx.Client(transport=httpx.MockTransport(lambda request: response))
    extractor = OpenAIVisionExtractor(api_key="k", client=client)
    with pytest.raises(ExtractionFailed):
        extractor.extract(b"fake-bytes", "image/png")


# --- FallbackVisionExtractor ---------------------------------------------------


class _FakeExtractor:
    def __init__(self, result: ExtractionResult | None = None, error: str | None = None):
        self.result = result
        self.error = error
        self.calls = 0

    def extract(self, image_bytes: bytes, mime_type: str) -> ExtractionResult:
        self.calls += 1
        if self.result is not None:
            return self.result
        raise ExtractionFailed(self.error)


def test_fallback_extractor_returns_primary_result_without_touching_secondary():
    primary = _FakeExtractor(result=ExtractionResult(institution="Primary"))
    secondary = _FakeExtractor(result=ExtractionResult(institution="Secondary"))
    extractor = FallbackVisionExtractor(primary=primary, secondary=secondary)

    result = extractor.extract(b"bytes", "image/png")

    assert result.institution == "Primary"
    assert secondary.calls == 0


def test_fallback_extractor_uses_secondary_when_primary_fails():
    primary = _FakeExtractor(error="primary down")
    secondary = _FakeExtractor(result=ExtractionResult(institution="Secondary"))
    extractor = FallbackVisionExtractor(primary=primary, secondary=secondary)

    result = extractor.extract(b"bytes", "image/png")

    assert result.institution == "Secondary"


def test_fallback_extractor_raises_when_both_fail():
    primary = _FakeExtractor(error="primary down")
    secondary = _FakeExtractor(error="secondary down")
    extractor = FallbackVisionExtractor(primary=primary, secondary=secondary)

    with pytest.raises(ExtractionFailed) as exc_info:
        extractor.extract(b"bytes", "image/png")

    assert "primary down" in str(exc_info.value)
    assert "secondary down" in str(exc_info.value)


# --- get_vision_extractor: fallback wiring -------------------------------------


def test_get_vision_extractor_yields_plain_deepseek_without_an_openai_key(monkeypatch):
    from app.config import get_settings
    from app.services import vision as vision_module

    settings = get_settings().model_copy(update={"openai_api_key": None})
    monkeypatch.setattr(vision_module, "get_settings", lambda: settings)

    dependency = vision_module.get_vision_extractor()
    extractor = next(dependency)
    assert isinstance(extractor, DeepSeekVisionExtractor)
    next(dependency, None)


def test_get_vision_extractor_yields_fallback_when_openai_key_is_configured(monkeypatch):
    from app.config import get_settings
    from app.services import vision as vision_module

    settings = get_settings().model_copy(update={"openai_api_key": "k"})
    monkeypatch.setattr(vision_module, "get_settings", lambda: settings)

    dependency = vision_module.get_vision_extractor()
    extractor = next(dependency)
    assert isinstance(extractor, FallbackVisionExtractor)
    assert isinstance(extractor._primary, DeepSeekVisionExtractor)
    assert isinstance(extractor._secondary, OpenAIVisionExtractor)
    next(dependency, None)
