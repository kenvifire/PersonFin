"""Vision-based extraction of account/holdings data from a screenshot.

Mirrors `services.fx` exactly: one exception type for every failure mode
(`ExtractionFailed`), a `VisionExtractor` protocol, a real HTTP-based
implementation (`DeepSeekVisionExtractor`) that wraps every possible
failure into that one exception, and a `get_vision_extractor()` FastAPI
dependency that yields the extractor and closes its `httpx.Client` in
`finally`.

`OpenAIVisionExtractor` is the same call shape against OpenAI instead of
DeepSeek. `FallbackVisionExtractor` tries one extractor and, only if it
raises `ExtractionFailed`, retries with a second — used to fall back
from DeepSeek to OpenAI when an `openai_api_key` is configured.
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
DEEPSEEK_API_URL = "https://api.deepseek.com/chat/completions"
DEEPSEEK_VISION_MODEL = "deepseek-flash"
OPENAI_API_URL = "https://api.openai.com/v1/chat/completions"
OPENAI_VISION_MODEL = "gpt-4o-mini"

EXTRACTION_PROMPT = (
    "You are extracting account holdings data from a screenshot of a "
    "brokerage or bank account statement or portfolio page. Respond "
    "with a single JSON object and nothing else, matching this shape "
    "exactly:\n"
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
    "final data."
)


class ExtractionFailed(Exception):
    """The single exception type for every vision-extraction failure
    (bad status, timeout, non-JSON body, a response that doesn't parse
    into `ExtractionResult`) — mirroring `fx.FXRateUnavailable`'s role
    exactly. The `/uploads/{id}/extract` router catches this itself and
    records it as the upload's status, so it never propagates as a 500."""


class VisionExtractor(Protocol):
    def extract(self, image_bytes: bytes, mime_type: str) -> ExtractionResult: ...


def _extract_via_chat_completions(
    *,
    client: httpx.Client,
    url: str,
    api_key: str,
    model: str,
    provider: str,
    image_bytes: bytes,
    mime_type: str,
) -> ExtractionResult:
    """Shared OpenAI-compatible Chat Completions call with the image as a
    base64 data URL and JSON-mode response — the request/response shape
    both `DeepSeekVisionExtractor` and `OpenAIVisionExtractor` use,
    differing only in endpoint/model/auth."""
    data_url = f"data:{mime_type};base64,{base64.b64encode(image_bytes).decode('ascii')}"
    payload = {
        "model": model,
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
        response = client.post(url, headers={"Authorization": f"Bearer {api_key}"}, json=payload)
        if response.status_code != 200:
            raise ExtractionFailed(f"{provider} returned status {response.status_code}")
        body = response.json()
    except httpx.HTTPError as exc:  # connect errors, timeouts, etc.
        raise ExtractionFailed(f"{provider} request failed: {exc}") from exc
    except ValueError as exc:  # non-JSON response body
        raise ExtractionFailed(f"{provider} returned a non-JSON body: {exc}") from exc

    try:
        content = body["choices"][0]["message"]["content"]
    except (KeyError, IndexError, TypeError) as exc:
        raise ExtractionFailed(f"{provider} response was missing expected fields: {exc}") from exc

    try:
        parsed = json.loads(content)
    except (TypeError, ValueError) as exc:
        raise ExtractionFailed(f"{provider} message content was not JSON: {exc}") from exc

    try:
        return ExtractionResult.model_validate(parsed)
    except ValidationError as exc:
        raise ExtractionFailed(f"{provider} response didn't match the expected shape: {exc}") from exc


class DeepSeekVisionExtractor:
    """Calls the DeepSeek vision model with the image embedded as a base64
    data URL, and parses its JSON response into an `ExtractionResult`."""

    def __init__(self, api_key: str, client: httpx.Client):
        self._api_key = api_key
        self._client = client

    def extract(self, image_bytes: bytes, mime_type: str) -> ExtractionResult:
        return _extract_via_chat_completions(
            client=self._client,
            url=DEEPSEEK_API_URL,
            api_key=self._api_key,
            model=DEEPSEEK_VISION_MODEL,
            provider="DeepSeek",
            image_bytes=image_bytes,
            mime_type=mime_type,
        )


class OpenAIVisionExtractor:
    """Same call shape as `DeepSeekVisionExtractor`, against OpenAI's
    vision-capable chat-completions endpoint instead."""

    def __init__(self, api_key: str, client: httpx.Client):
        self._api_key = api_key
        self._client = client

    def extract(self, image_bytes: bytes, mime_type: str) -> ExtractionResult:
        return _extract_via_chat_completions(
            client=self._client,
            url=OPENAI_API_URL,
            api_key=self._api_key,
            model=OPENAI_VISION_MODEL,
            provider="OpenAI",
            image_bytes=image_bytes,
            mime_type=mime_type,
        )


class FallbackVisionExtractor:
    """Tries `primary`; if it raises `ExtractionFailed`, retries once with
    `secondary` before giving up. Used by `get_vision_extractor` to fall
    back from DeepSeek to OpenAI when `openai_api_key` is configured."""

    def __init__(self, primary: VisionExtractor, secondary: VisionExtractor):
        self._primary = primary
        self._secondary = secondary

    def extract(self, image_bytes: bytes, mime_type: str) -> ExtractionResult:
        try:
            return self._primary.extract(image_bytes, mime_type)
        except ExtractionFailed as primary_error:
            try:
                return self._secondary.extract(image_bytes, mime_type)
            except ExtractionFailed as secondary_error:
                raise ExtractionFailed(
                    f"Both vision providers failed — primary: {primary_error}; "
                    f"fallback: {secondary_error}"
                ) from secondary_error


def get_vision_extractor() -> Generator[VisionExtractor, None, None]:
    """FastAPI dependency used by routers that need a `VisionExtractor`.

    Builds a `DeepSeekVisionExtractor` from `get_settings()` plus a
    fresh `httpx.Client`, and closes the client once the request is
    done so connections are never leaked. Tests override this with a
    fake extractor so they never hit the network (see `conftest.py`).

    When `openai_api_key` is configured, wraps it in a
    `FallbackVisionExtractor` that retries with OpenAI if DeepSeek fails.
    """
    settings = get_settings()
    client = httpx.Client(timeout=VISION_HTTP_TIMEOUT_SECONDS)
    try:
        primary = DeepSeekVisionExtractor(api_key=settings.deepseek_api_key, client=client)
        if settings.openai_api_key:
            fallback = OpenAIVisionExtractor(api_key=settings.openai_api_key, client=client)
            yield FallbackVisionExtractor(primary=primary, secondary=fallback)
        else:
            yield primary
    finally:
        client.close()
