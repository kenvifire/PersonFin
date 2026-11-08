"""DeepSeek-based generation of narrative insights from a user's
dashboard and allocation drift.

Mirrors `services.vision` exactly: one exception type for every failure
mode (`InsightGenerationFailed`), an `InsightGenerator` protocol, a real
HTTP-based implementation (`DeepSeekInsightGenerator`) that wraps every
possible failure into that one exception, and a `get_insight_generator()`
FastAPI dependency that yields the generator and closes its
`httpx.Client` in `finally`.
"""

import json
from collections.abc import Generator
from typing import Protocol

import httpx
from pydantic import ValidationError

from app.config import get_settings
from app.schemas.dashboard import DashboardOut
from app.schemas.insights import InsightsNarrative
from app.schemas.target import DriftFlag

DEEPSEEK_API_URL = "https://api.deepseek.com/chat/completions"
DEEPSEEK_MODEL = "deepseek-chat"
DEEPSEEK_HTTP_TIMEOUT_SECONDS = 15.0

INSIGHTS_PROMPT_INSTRUCTIONS = (
    "You are a personal finance assistant analyzing a user's portfolio "
    "dashboard and allocation drift. Respond with a single JSON object "
    "and nothing else, matching this shape exactly:\n"
    "{"
    '"summary": string, '
    '"action_items": [{'
    '"asset_class": string, '
    '"suggestion": string'
    "}]"
    "}\n"
    "Write a brief, plain-language summary of the portfolio and, for "
    "each asset class that has drifted from its target, a concrete "
    "suggestion for bringing it back in line. These are informational "
    "observations for the user to consider, not financial advice."
)


class InsightGenerationFailed(Exception):
    """The single exception type for every insight-generation failure
    (bad status, timeout, non-JSON body, a response that doesn't parse
    into `InsightsNarrative`) — mirroring `vision.ExtractionFailed`'s
    role exactly."""


class InsightGenerator(Protocol):
    def generate(self, dashboard: DashboardOut, drift: list[DriftFlag]) -> InsightsNarrative: ...


def _build_prompt(dashboard: DashboardOut, drift: list[DriftFlag]) -> str:
    drift_lines = [
        f"- {flag.asset_class}: target {flag.target_pct}%, actual {flag.actual_pct}% "
        f"(drift {flag.delta_pct}%)"
        for flag in drift
    ]
    drift_section = "\n".join(drift_lines) if drift_lines else "- none"
    return (
        f"{INSIGHTS_PROMPT_INSTRUCTIONS}\n\n"
        f"Net worth: {dashboard.net_worth} {dashboard.currency}\n"
        f"By asset class: {dashboard.by_asset_class}\n"
        f"By country: {dashboard.by_country}\n"
        f"Allocation drift flags:\n{drift_section}"
    )


class DeepSeekInsightGenerator:
    """Calls the DeepSeek chat-completions API with a prompt built from
    the dashboard and drift flags, and parses its JSON response into an
    `InsightsNarrative`."""

    def __init__(self, api_key: str, client: httpx.Client):
        self._api_key = api_key
        self._client = client

    def generate(self, dashboard: DashboardOut, drift: list[DriftFlag]) -> InsightsNarrative:
        payload = {
            "model": DEEPSEEK_MODEL,
            "messages": [{"role": "user", "content": _build_prompt(dashboard, drift)}],
            "response_format": {"type": "json_object"},
        }

        try:
            response = self._client.post(
                DEEPSEEK_API_URL,
                headers={"Authorization": f"Bearer {self._api_key}"},
                json=payload,
            )
            if response.status_code != 200:
                raise InsightGenerationFailed(f"DeepSeek returned status {response.status_code}")
            body = response.json()
        except httpx.HTTPError as exc:  # connect errors, timeouts, etc.
            raise InsightGenerationFailed(f"DeepSeek request failed: {exc}") from exc
        except ValueError as exc:  # non-JSON response body
            raise InsightGenerationFailed(f"DeepSeek returned a non-JSON body: {exc}") from exc

        try:
            content = body["choices"][0]["message"]["content"]
        except (KeyError, IndexError, TypeError) as exc:
            raise InsightGenerationFailed(f"DeepSeek response was missing expected fields: {exc}") from exc

        try:
            parsed = json.loads(content)
        except (TypeError, ValueError) as exc:
            raise InsightGenerationFailed(f"DeepSeek message content was not JSON: {exc}") from exc

        try:
            return InsightsNarrative.model_validate(parsed)
        except ValidationError as exc:
            raise InsightGenerationFailed(f"DeepSeek response didn't match the expected shape: {exc}") from exc


def get_insight_generator() -> Generator[InsightGenerator, None, None]:
    """FastAPI dependency used by routers that need an `InsightGenerator`.

    Builds a `DeepSeekInsightGenerator` from `get_settings()` plus a
    fresh `httpx.Client`, and closes the client once the request is
    done so connections are never leaked. Tests override this with a
    fake generator so they never hit the network (see `conftest.py`).
    """
    settings = get_settings()
    client = httpx.Client(timeout=DEEPSEEK_HTTP_TIMEOUT_SECONDS)
    try:
        yield DeepSeekInsightGenerator(api_key=settings.deepseek_api_key, client=client)
    finally:
        client.close()
