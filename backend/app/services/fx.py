from typing import Protocol

import httpx

SUPPORTED_CURRENCIES = {"CAD", "USD", "CNY", "HKD", "SGD"}

FRANKFURTER_URL = "https://api.frankfurter.app/latest"


class FXRateUnavailable(Exception):
    def __init__(self, base: str, quote: str):
        super().__init__(f"No FX rate available for {base} -> {quote}")
        self.base = base
        self.quote = quote


class FXRateProvider(Protocol):
    def get_rate(self, base: str, quote: str) -> float: ...


class HttpFXRateProvider:
    """Fetches spot rates from the free Frankfurter (ECB) API."""

    def __init__(self, client: httpx.Client | None = None):
        self._client = client or httpx.Client(timeout=10.0)

    def get_rate(self, base: str, quote: str) -> float:
        response = self._client.get(
            FRANKFURTER_URL, params={"from": base, "to": quote}
        )
        if response.status_code != 200:
            raise FXRateUnavailable(base, quote)
        rate = response.json().get("rates", {}).get(quote)
        if rate is None:
            raise FXRateUnavailable(base, quote)
        return float(rate)


def convert(
    amount: float,
    from_currency: str,
    to_currency: str,
    provider: FXRateProvider,
) -> float:
    if from_currency == to_currency:
        return amount
    return amount * provider.get_rate(from_currency, to_currency)


def get_fx_provider() -> FXRateProvider:
    """FastAPI dependency used by routers that need an `FXRateProvider`.
    Tests override this with a fake provider so they never hit the
    network (see `conftest.py`).
    """
    return HttpFXRateProvider()
