"""Vision-based extraction of account/holdings data from a screenshot.

Mirrors `services.fx` exactly: one exception type for every failure mode
(`ExtractionFailed`), a `VisionExtractor` protocol, a real HTTP-based
implementation (`AzureOpenAIVisionExtractor`) that wraps every possible
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
AZURE_OPENAI_API_VERSION = "2024-02-15-preview"

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


class AzureOpenAIVisionExtractor:
    """Calls an Azure OpenAI chat-completions deployment with the image
    embedded as a base64 data URL, and parses its JSON response into an
    `ExtractionResult`."""

    def __init__(self, endpoint: str, api_key: str, deployment: str, client: httpx.Client):
        self._endpoint = endpoint.rstrip("/")
        self._api_key = api_key
        self._deployment = deployment
        self._client = client

    def extract(self, image_bytes: bytes, mime_type: str) -> ExtractionResult:
        url = (
            f"{self._endpoint}/openai/deployments/{self._deployment}/chat/completions"
            f"?api-version={AZURE_OPENAI_API_VERSION}"
        )
        data_url = f"data:{mime_type};base64,{base64.b64encode(image_bytes).decode('ascii')}"
        payload = {
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
            response = self._client.post(url, headers={"api-key": self._api_key}, json=payload)
            if response.status_code != 200:
                raise ExtractionFailed(f"Azure OpenAI returned status {response.status_code}")
            body = response.json()
        except httpx.HTTPError as exc:  # connect errors, timeouts, etc.
            raise ExtractionFailed(f"Azure OpenAI request failed: {exc}") from exc
        except ValueError as exc:  # non-JSON response body
            raise ExtractionFailed(f"Azure OpenAI returned a non-JSON body: {exc}") from exc

        try:
            content = body["choices"][0]["message"]["content"]
        except (KeyError, IndexError, TypeError) as exc:
            raise ExtractionFailed(f"Azure OpenAI response was missing expected fields: {exc}") from exc

        try:
            parsed = json.loads(content)
        except (TypeError, ValueError) as exc:
            raise ExtractionFailed(f"Azure OpenAI message content was not JSON: {exc}") from exc

        try:
            return ExtractionResult.model_validate(parsed)
        except ValidationError as exc:
            raise ExtractionFailed(f"Azure OpenAI response didn't match the expected shape: {exc}") from exc


def get_vision_extractor() -> Generator[VisionExtractor, None, None]:
    """FastAPI dependency used by routers that need a `VisionExtractor`.

    Builds an `AzureOpenAIVisionExtractor` from `get_settings()` plus a
    fresh `httpx.Client`, and closes the client once the request is
    done so connections are never leaked. Tests override this with a
    fake extractor so they never hit the network (see `conftest.py`).
    """
    settings = get_settings()
    client = httpx.Client(timeout=VISION_HTTP_TIMEOUT_SECONDS)
    try:
        yield AzureOpenAIVisionExtractor(
            endpoint=settings.azure_openai_endpoint,
            api_key=settings.azure_openai_api_key,
            deployment=settings.azure_openai_deployment,
            client=client,
        )
    finally:
        client.close()
