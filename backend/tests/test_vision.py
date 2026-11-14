"""`OpenAIVisionExtractor`: mocked-transport tests only, never the real
network."""

import json

import httpx
import pytest

from app.services.vision import ExtractionFailed, OpenAIVisionExtractor


def _minimal_pdf(text: str) -> bytes:
    """Builds a minimal, real, single-page PDF whose extracted text is
    exactly `text` — hand-assembled (correct object offsets and xref
    table) rather than relying on a PDF-writing library, so these tests
    don't need one just to produce a parseable fixture."""
    content = f"BT /F1 24 Tf 10 100 Td ({text}) Tj ET".encode()
    objects = [
        b"<</Type/Catalog/Pages 2 0 R>>",
        b"<</Type/Pages/Kids[3 0 R]/Count 1>>",
        b"<</Type/Page/Parent 2 0 R/Resources<</Font<</F1 4 0 R>>>>/MediaBox[0 0 200 200]/Contents 5 0 R>>",
        b"<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>",
        b"<</Length " + str(len(content)).encode() + b">>\nstream\n" + content + b"\nendstream",
    ]
    out = bytearray(b"%PDF-1.4\n")
    offsets = []
    for i, obj in enumerate(objects, start=1):
        offsets.append(len(out))
        out += f"{i} 0 obj".encode() + b"\n" + obj + b"\nendobj\n"
    xref_offset = len(out)
    n = len(objects) + 1
    out += f"xref\n0 {n}\n".encode() + b"0000000000 65535 f \n"
    for offset in offsets:
        out += f"{offset:010d} 00000 n \n".encode()
    out += f"trailer<</Size {n}/Root 1 0 R>>\nstartxref\n{xref_offset}\n%%EOF".encode()
    return bytes(out)


def test_openai_extractor_parses_valid_response():
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
    extractor = OpenAIVisionExtractor(api_key="k", client=client)
    result = extractor.extract(b"fake-bytes", "image/png")
    assert result.institution == "RBC"
    assert result.holdings[0].label == "VFV"


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
        httpx.Response(200, json={"choices": [{"message": {}}]}),
        httpx.Response(200, json={"choices": [{"message": {"content": json.dumps({"holdings": "not-a-list"})}}]}),
    ],
    ids=["server-error", "non-json", "no-choices", "no-content", "schema-mismatch"],
)
def test_openai_extractor_bad_responses_raise_extraction_failed(response):
    client = httpx.Client(transport=httpx.MockTransport(lambda request: response))
    extractor = OpenAIVisionExtractor(api_key="k", client=client)
    with pytest.raises(ExtractionFailed):
        extractor.extract(b"fake-bytes", "image/png")


@pytest.mark.parametrize(
    "error",
    [httpx.ConnectError("refused"), httpx.ReadTimeout("slow")],
    ids=["connect-error", "timeout"],
)
def test_openai_extractor_transport_errors_raise_extraction_failed(error):
    def handler(request):
        raise error

    client = httpx.Client(transport=httpx.MockTransport(handler))
    extractor = OpenAIVisionExtractor(api_key="k", client=client)
    with pytest.raises(ExtractionFailed):
        extractor.extract(b"fake-bytes", "image/png")


def test_openai_extractor_sends_pdf_text_as_a_text_only_message():
    captured = {}

    def handler(request):
        captured["body"] = json.loads(request.content)
        body = {"choices": [{"message": {"content": json.dumps({"holdings": []})}}]}
        return httpx.Response(200, json=body)

    client = httpx.Client(transport=httpx.MockTransport(handler))
    extractor = OpenAIVisionExtractor(api_key="k", client=client)
    pdf_bytes = _minimal_pdf("Account 123 USD 456.78")

    extractor.extract(pdf_bytes, "application/pdf")

    content_blocks = captured["body"]["messages"][0]["content"]
    assert len(content_blocks) == 1
    assert content_blocks[0]["type"] == "text"
    assert "Account 123 USD 456.78" in content_blocks[0]["text"]


def test_openai_extractor_wraps_an_unparseable_pdf_as_extraction_failed():
    client = httpx.Client(transport=httpx.MockTransport(lambda request: httpx.Response(200)))
    extractor = OpenAIVisionExtractor(api_key="k", client=client)
    with pytest.raises(ExtractionFailed):
        extractor.extract(b"not actually a pdf", "application/pdf")


def test_get_vision_extractor_closes_its_client_after_the_request():
    from app.services.vision import get_vision_extractor

    dependency = get_vision_extractor()
    extractor = next(dependency)
    client = extractor._client
    assert not client.is_closed

    with pytest.raises(StopIteration):
        next(dependency)  # FastAPI resumes the generator once the request is done

    assert client.is_closed
