"""Vision-based extraction of account/holdings data from a screenshot.

Mirrors `services.fx` exactly: one exception type for every failure mode
(`ExtractionFailed`), a `VisionExtractor` protocol, a real HTTP-based
implementation (`OpenAIVisionExtractor`) that wraps every possible
failure into that one exception, and a `get_vision_extractor()` FastAPI
dependency that yields the extractor and closes its `httpx.Client` in
`finally`.
"""

import base64
import json
from collections.abc import Generator
from typing import Protocol

import httpx
from pydantic import ValidationError

from app.config import get_settings
from app.schemas.extraction import ExtractionResult

VISION_HTTP_TIMEOUT_SECONDS = 60.0
OPENAI_API_URL = "https://api.openai.com/v1/chat/completions"
OPENAI_VISION_MODEL = "gpt-4o-mini"

EXTRACTION_PROMPT = (
    "You are extracting account holdings data from a screenshot of a "
    "brokerage or bank account statement or portfolio page. The "
    "screenshot may be in any language, and may list several holdings "
    "under one account rather than just one. Respond with a single "
    "JSON object and nothing else, matching this shape exactly:\n"
    "{"
    '"institution": string or null, '
    '"account_label": string or null, '
    '"account_type_guess": string or null, '
    '"taken_at_guess": "YYYY-MM-DD" or null, '
    '"holdings": [{'
    '"label": string, '
    '"asset_class_guess": string or null, '
    '"quantity": number or null, '
    '"value": number or null, '
    '"currency_guess": string or null, '
    '"country_guess": string or null'
    "}]"
    "}\n"
    "If a field can't be determined from the image, use null rather than "
    "guessing. These are review-and-correct suggestions for the user, not "
    "final data. That said, use context that's actually visible rather "
    "than defaulting to null whenever a holding-level value isn't printed "
    "right next to the holding itself:\n"
    "- \"institution\": the broker/bank/platform name, usually visible in "
    "the app's header, logo, or an account-switcher label (e.g. "
    "\"FUTU HK\", \"Charles Schwab\") — not the account_label.\n"
    "- \"account_type_guess\": a short free-text guess like \"brokerage\", "
    "\"bank\", or \"retirement\", from context like the app's own labels "
    "(e.g. a stock-trading UI implies \"brokerage\").\n"
    "- \"currency_guess\" per holding: if the page shows one account-level "
    "currency (e.g. a total market value like \"69,953.16 USD\", or a "
    "market section labelled by currency), use that for every holding "
    "that doesn't show its own different currency — don't leave it null "
    "just because the currency isn't repeated next to each holding.\n"
    "- \"country_guess\" per holding: infer from clear visible context "
    "(a market/exchange label, a country flag icon, or an exchange this "
    "ticker is obviously listed on) even if it's not printed on the "
    "holding's own row — but still null when there's truly no such "
    "evidence, not from the ticker symbol alone."
)


class ExtractionFailed(Exception):
    """The single exception type for every vision-extraction failure
    (bad status, timeout, non-JSON body, a response that doesn't parse
    into `ExtractionResult`) — mirroring `fx.FXRateUnavailable`'s role
    exactly. The `/uploads/{id}/extract` router catches this itself and
    records it as the upload's status, so it never propagates as a 500."""


class VisionExtractor(Protocol):
    def extract(self, image_bytes: bytes, mime_type: str) -> ExtractionResult: ...


class OpenAIVisionExtractor:
    """Calls OpenAI's vision-capable chat-completions model with the image
    embedded as a base64 data URL, and parses its JSON response into an
    `ExtractionResult`."""

    def __init__(self, api_key: str, client: httpx.Client):
        self._api_key = api_key
        self._client = client

    def extract(self, image_bytes: bytes, mime_type: str) -> ExtractionResult:
        data_url = f"data:{mime_type};base64,{base64.b64encode(image_bytes).decode('ascii')}"
        payload = {
            "model": OPENAI_VISION_MODEL,
            "messages": [
                {
                    "role": "user",
                    "content": [
                        {"type": "text", "text": EXTRACTION_PROMPT},
                        {"type": "image_url", "image_url": {"url": data_url}},
                    ],
                }
            ],
            "response_format": {"type": "json_object"},
        }

        try:
            response = self._client.post(
                OPENAI_API_URL, headers={"Authorization": f"Bearer {self._api_key}"}, json=payload
            )
            if response.status_code != 200:
                raise ExtractionFailed(f"OpenAI returned status {response.status_code}")
            body = response.json()
        except httpx.HTTPError as exc:  # connect errors, timeouts, etc.
            raise ExtractionFailed(f"OpenAI request failed: {exc}") from exc
        except ValueError as exc:  # non-JSON response body
            raise ExtractionFailed(f"OpenAI returned a non-JSON body: {exc}") from exc

        try:
            content = body["choices"][0]["message"]["content"]
        except (KeyError, IndexError, TypeError) as exc:
            raise ExtractionFailed(f"OpenAI response was missing expected fields: {exc}") from exc

        try:
            parsed = json.loads(content)
        except (TypeError, ValueError) as exc:
            raise ExtractionFailed(f"OpenAI message content was not JSON: {exc}") from exc

        try:
            return ExtractionResult.model_validate(parsed)
        except ValidationError as exc:
            raise ExtractionFailed(f"OpenAI response didn't match the expected shape: {exc}") from exc


def get_vision_extractor() -> Generator[VisionExtractor, None, None]:
    """FastAPI dependency used by routers that need a `VisionExtractor`.

    Builds an `OpenAIVisionExtractor` from `get_settings()` plus a fresh
    `httpx.Client`, and closes the client once the request is done so
    connections are never leaked. Tests override this with a fake
    extractor so they never hit the network (see `conftest.py`).
    """
    settings = get_settings()
    client = httpx.Client(timeout=VISION_HTTP_TIMEOUT_SECONDS)
    try:
        yield OpenAIVisionExtractor(api_key=settings.openai_api_key, client=client)
    finally:
        client.close()
