from collections.abc import Generator
from typing import Protocol

import httpx

SUPPORTED_CURRENCIES = {"CAD", "USD", "CNY", "HKD", "SGD"}

# Frankfurter moved from api.frankfurter.app to api.frankfurter.dev/v1;
# the old host now 301-redirects, which httpx does not follow by default.
FRANKFURTER_URL = "https://api.frankfurter.dev/v1/latest"

FX_HTTP_TIMEOUT_SECONDS = 10.0


class FXRateUnavailable(Exception):
    """The single exception type for every FX lookup failure (network
    error, timeout, bad status, malformed body, missing rate). Mapped to a
    503 response by the handler registered in `app.main`."""

    def __init__(self, base: str, quote: str):
        super().__init__(f"No FX rate available for {base} -> {quote}")
        self.base = base
        self.quote = quote


class FXRateProvider(Protocol):
    def get_rate(self, base: str, quote: str) -> float: ...


class HttpFXRateProvider:
    """Fetches spot rates from the free Frankfurter (ECB) API."""

    def __init__(self, client: httpx.Client):
        self._client = client

    def get_rate(self, base: str, quote: str) -> float:
        try:
            response = self._client.get(
                FRANKFURTER_URL, params={"from": base, "to": quote}
            )
            if response.status_code != 200:
                raise FXRateUnavailable(base, quote)
            body = response.json()
        except httpx.HTTPError as exc:  # connect errors, timeouts, etc.
            raise FXRateUnavailable(base, quote) from exc
        except ValueError as exc:  # non-JSON response body
            raise FXRateUnavailable(base, quote) from exc

        rates = body.get("rates") if isinstance(body, dict) else None
        rate = rates.get(quote) if isinstance(rates, dict) else None
        if rate is None:
            raise FXRateUnavailable(base, quote)
        try:
            return float(rate)
        except (TypeError, ValueError) as exc:
            raise FXRateUnavailable(base, quote) from exc


def convert(
    amount: float,
    from_currency: str,
    to_currency: str,
    provider: FXRateProvider,
) -> float:
    if from_currency == to_currency:
        return amount
    return amount * provider.get_rate(from_currency, to_currency)


def get_fx_provider() -> Generator[FXRateProvider, None, None]:
    """FastAPI dependency used by routers that need an `FXRateProvider`.

    Opens one `httpx.Client` per request and closes it once the request
    is done, so connections are never leaked. Tests override this with a
    fake provider so they never hit the network (see `conftest.py`).
    """
    client = httpx.Client(timeout=FX_HTTP_TIMEOUT_SECONDS)
    try:
        yield HttpFXRateProvider(client)
    finally:
        client.close()
