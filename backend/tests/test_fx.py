import httpx
import pytest

from app.services.fx import (
    FRANKFURTER_URL,
    FXRateUnavailable,
    HttpFXRateProvider,
    convert,
    get_fx_provider,
)


class FakeProvider:
    def get_rate(self, base, quote):
        return 0.72  # CAD -> USD

def test_convert_uses_provider_rate():
    assert convert(1000.0, "CAD", "USD", FakeProvider()) == 720.0

def test_convert_same_currency_skips_provider():
    class ExplodingProvider:
        def get_rate(self, base, quote):
            raise AssertionError("should not be called")
    assert convert(50.0, "USD", "USD", ExplodingProvider()) == 50.0

def test_unavailable_pair_raises():
    class EmptyProvider:
        def get_rate(self, base, quote):
            raise FXRateUnavailable(base, quote)
    with pytest.raises(FXRateUnavailable):
        convert(10.0, "XYZ", "USD", EmptyProvider())


# --- HttpFXRateProvider (mocked transport, never the live network) ---


def _provider(handler) -> HttpFXRateProvider:
    return HttpFXRateProvider(httpx.Client(transport=httpx.MockTransport(handler)))


def test_frankfurter_url_is_current_host():
    # api.frankfurter.app 301-redirects (not followed by httpx) — every
    # call against it failed.
    assert FRANKFURTER_URL == "https://api.frankfurter.dev/v1/latest"


def test_http_provider_parses_frankfurter_response():
    seen_requests = []

    def handler(request: httpx.Request) -> httpx.Response:
        seen_requests.append(request)
        return httpx.Response(
            200,
            json={"amount": 1.0, "base": "USD", "date": "2026-11-06", "rates": {"CAD": 1.4066}},
        )

    rate = _provider(handler).get_rate("USD", "CAD")

    assert rate == pytest.approx(1.4066)
    (request,) = seen_requests
    assert str(request.url.copy_with(query=None)) == FRANKFURTER_URL
    assert request.url.params["from"] == "USD"
    assert request.url.params["to"] == "CAD"


@pytest.mark.parametrize(
    "response",
    [
        httpx.Response(301, headers={"Location": "https://elsewhere.example/"}),
        httpx.Response(500, text="boom"),
        httpx.Response(200, text="<html>not json</html>"),
        httpx.Response(200, json=["not", "an", "object"]),
        httpx.Response(200, json={"rates": {"SGD": 1.3}}),  # requested quote missing
        httpx.Response(200, json={"rates": {"CAD": "not-a-number"}}),
    ],
    ids=["redirect", "server-error", "non-json", "non-object", "missing-rate", "bad-rate"],
)
def test_http_provider_bad_responses_raise_fx_unavailable(response):
    with pytest.raises(FXRateUnavailable):
        _provider(lambda request: response).get_rate("USD", "CAD")


@pytest.mark.parametrize(
    "error",
    [httpx.ConnectError("refused"), httpx.ReadTimeout("slow")],
    ids=["connect-error", "timeout"],
)
def test_http_provider_transport_errors_raise_fx_unavailable(error):
    def handler(request):
        raise error

    with pytest.raises(FXRateUnavailable):
        _provider(handler).get_rate("USD", "CAD")


def test_get_fx_provider_closes_its_client_after_the_request():
    dependency = get_fx_provider()
    provider = next(dependency)
    client = provider._client
    assert not client.is_closed

    with pytest.raises(StopIteration):
        next(dependency)  # FastAPI resumes the generator once the request is done

    assert client.is_closed
