"""`AzureOpenAIVisionExtractor`: mocked-transport tests only, never the
real network."""

import json

import httpx
import pytest

from app.services.vision import AzureOpenAIVisionExtractor, ExtractionFailed


def test_azure_extractor_parses_valid_response():
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
    extractor = AzureOpenAIVisionExtractor(endpoint="https://x", api_key="k", deployment="d", client=client)
    result = extractor.extract(b"fake-bytes", "image/png")
    assert result.institution == "RBC"
    assert result.holdings[0].label == "VFV"


def test_azure_extractor_wraps_malformed_response_as_extraction_failed():
    def handler(request):
        return httpx.Response(200, json={"choices": [{"message": {"content": "not json"}}]})

    client = httpx.Client(transport=httpx.MockTransport(handler))
    extractor = AzureOpenAIVisionExtractor(endpoint="https://x", api_key="k", deployment="d", client=client)
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
def test_azure_extractor_bad_responses_raise_extraction_failed(response):
    client = httpx.Client(transport=httpx.MockTransport(lambda request: response))
    extractor = AzureOpenAIVisionExtractor(endpoint="https://x", api_key="k", deployment="d", client=client)
    with pytest.raises(ExtractionFailed):
        extractor.extract(b"fake-bytes", "image/png")


@pytest.mark.parametrize(
    "error",
    [httpx.ConnectError("refused"), httpx.ReadTimeout("slow")],
    ids=["connect-error", "timeout"],
)
def test_azure_extractor_transport_errors_raise_extraction_failed(error):
    def handler(request):
        raise error

    client = httpx.Client(transport=httpx.MockTransport(handler))
    extractor = AzureOpenAIVisionExtractor(endpoint="https://x", api_key="k", deployment="d", client=client)
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
