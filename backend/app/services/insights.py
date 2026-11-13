"""OpenAI-based generation of narrative insights from a user's dashboard
and allocation drift.

Mirrors `services.vision` exactly: one exception type for every failure
mode (`InsightGenerationFailed`), an `InsightGenerator` protocol, a real
HTTP-based implementation (`OpenAIInsightGenerator`) that wraps every
possible failure into that one exception, and a `get_insight_generator()`
FastAPI dependency that yields the generator and closes its
`httpx.Client` in `finally`.

The whole OpenAI call runs under a wall-clock deadline
(`OPENAI_HTTP_TIMEOUT_SECONDS`), not just httpx's per-read timeout —
a server trickling a byte at a time resets a per-read timeout forever.
"""

import json
import time
from collections.abc import Generator
from concurrent.futures import ThreadPoolExecutor
from concurrent.futures import TimeoutError as FutureTimeoutError
from typing import Protocol

import httpx
from pydantic import ValidationError

from app.config import get_settings
from app.schemas.dashboard import DashboardOut
from app.schemas.insights import InsightsNarrative
from app.schemas.target import DriftFlag

OPENAI_API_URL = "https://api.openai.com/v1/chat/completions"
OPENAI_MODEL = "gpt-4o-mini"
# Used both as httpx's per-operation timeout and as the wall-clock
# deadline for the whole OpenAI call (see `OpenAIInsightGenerator`).
OPENAI_HTTP_TIMEOUT_SECONDS = 15.0

# Decimal places every number in the prompt is rounded to.
PROMPT_DECIMAL_PLACES = 2

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
    "observations for the user to consider, not financial advice.\n"
    "Each drifted asset class's target is labelled either as a "
    "user-set target (the user chose it) or as a system default (the "
    "user did NOT choose it). Only a user-set target may be described "
    "as the user's own target or goal. Anything compared against a "
    "system-default target must be phrased as a suggestion to consider "
    "(e.g. \"a common starting point is ...\") — never as \"your stated "
    "goal\", \"your target\", or any other wording that implies the user "
    "chose it."
)


class InsightGenerationFailed(Exception):
    """The single exception type for every insight-generation failure
    (bad status, timeout, non-JSON body, a response that doesn't parse
    into `InsightsNarrative`, missing configuration) — mirroring
    `vision.ExtractionFailed`'s role exactly.

    `category` is a short fixed label (e.g. "timeout", "http_status",
    "transport", "invalid_json", "missing_fields", "schema_mismatch",
    "missing_api_key", "unexpected") that is safe to log: unlike the
    message, it never carries response content or user data.
    """

    def __init__(self, message: str = "", category: str = "unknown"):
        super().__init__(message)
        self.category = category


class InsightGenerator(Protocol):
    def generate(
        self,
        dashboard: DashboardOut,
        drift: list[DriftFlag],
        user_set_asset_classes: frozenset[str],
    ) -> InsightsNarrative:
        """`user_set_asset_classes` names the asset classes whose target
        the user chose themselves; every other target is a system
        default and must not be narrated as the user's choice."""
        ...


def _round(value: float) -> float:
    return round(value, PROMPT_DECIMAL_PLACES)


def _fmt(value: float) -> str:
    return f"{value:.{PROMPT_DECIMAL_PLACES}f}"


def _target_provenance(asset_class: str, user_set_asset_classes: frozenset[str]) -> str:
    # Fail-safe: anything not known to be user-set is caveated as a default.
    if asset_class in user_set_asset_classes:
        return "user-set target"
    return "system default — not something the user chose"


def _build_prompt(
    dashboard: DashboardOut,
    drift: list[DriftFlag],
    user_set_asset_classes: frozenset[str],
) -> str:
    drift_lines = [
        f"- {flag.asset_class}: target {_fmt(flag.target_pct)}% "
        f"({_target_provenance(flag.asset_class, user_set_asset_classes)}), "
        f"actual {_fmt(flag.actual_pct)}% (drift {flag.delta_pct:+.{PROMPT_DECIMAL_PLACES}f} points)"
        for flag in drift
    ]
    drift_section = "\n".join(drift_lines) if drift_lines else "- none"
    by_asset_class = {k: _round(v) for k, v in dashboard.by_asset_class.items()}
    by_country = {k: _round(v) for k, v in dashboard.by_country.items()}
    return (
        f"{INSIGHTS_PROMPT_INSTRUCTIONS}\n\n"
        f"Net worth: {_fmt(dashboard.net_worth)} {dashboard.currency}\n"
        f"By asset class ({dashboard.currency}): {json.dumps(by_asset_class)}\n"
        f"By country ({dashboard.currency}): {json.dumps(by_country)}\n"
        f"Allocation drift flags:\n{drift_section}"
    )


class OpenAIInsightGenerator:
    """Calls OpenAI's chat-completions API with a prompt built from the
    dashboard and drift flags, and parses its JSON response into an
    `InsightsNarrative`.

    The HTTP call runs in a worker thread and the caller waits at most
    `deadline_seconds` of wall-clock time for it, regardless of how the
    server paces its bytes. The worker also checks the same deadline
    between body chunks, so an abandoned call stops reading on its own
    shortly afterwards instead of trickling on in the background.
    """

    def __init__(
        self,
        api_key: str,
        client: httpx.Client,
        deadline_seconds: float = OPENAI_HTTP_TIMEOUT_SECONDS,
    ):
        self._api_key = api_key
        self._client = client
        self._deadline_seconds = deadline_seconds

    def generate(
        self,
        dashboard: DashboardOut,
        drift: list[DriftFlag],
        user_set_asset_classes: frozenset[str],
    ) -> InsightsNarrative:
        try:
            return self._generate(dashboard, drift, user_set_asset_classes)
        except InsightGenerationFailed:
            raise
        except Exception as exc:
            # Structural backstop: whatever else goes wrong (e.g. a
            # `RecursionError` somewhere unanticipated) is still reported
            # as the one documented failure type.
            raise InsightGenerationFailed(
                f"Unexpected error generating insights: {type(exc).__name__}",
                category="unexpected",
            ) from exc

    def _generate(
        self,
        dashboard: DashboardOut,
        drift: list[DriftFlag],
        user_set_asset_classes: frozenset[str],
    ) -> InsightsNarrative:
        payload = {
            "model": OPENAI_MODEL,
            "messages": [
                {"role": "user", "content": _build_prompt(dashboard, drift, user_set_asset_classes)}
            ],
            "response_format": {"type": "json_object"},
        }

        raw_body = self._post_with_deadline(payload)

        try:
            body = json.loads(raw_body)
        except (ValueError, RecursionError) as exc:  # non-JSON / pathologically nested body
            raise InsightGenerationFailed(
                f"OpenAI returned a non-JSON body: {type(exc).__name__}", category="invalid_json"
            ) from exc

        try:
            content = body["choices"][0]["message"]["content"]
        except (KeyError, IndexError, TypeError) as exc:
            raise InsightGenerationFailed(
                f"OpenAI response was missing expected fields: {exc}", category="missing_fields"
            ) from exc

        try:
            parsed = json.loads(content)
        except (TypeError, ValueError, RecursionError) as exc:
            raise InsightGenerationFailed(
                f"OpenAI message content was not JSON: {type(exc).__name__}", category="invalid_json"
            ) from exc

        try:
            return InsightsNarrative.model_validate(parsed)
        except ValidationError as exc:
            raise InsightGenerationFailed(
                f"OpenAI response didn't match the expected shape: {exc}", category="schema_mismatch"
            ) from exc

    def _post_with_deadline(self, payload: dict) -> bytes:
        deadline = time.monotonic() + self._deadline_seconds
        executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix="openai-insights")
        try:
            future = executor.submit(self._post, payload, deadline)
            return future.result(timeout=self._deadline_seconds)
        except FutureTimeoutError as exc:
            raise InsightGenerationFailed(
                f"OpenAI did not respond within {self._deadline_seconds}s", category="timeout"
            ) from exc
        except httpx.TimeoutException as exc:
            raise InsightGenerationFailed(f"OpenAI request timed out: {exc}", category="timeout") from exc
        except httpx.HTTPError as exc:  # connect errors, protocol errors, etc.
            raise InsightGenerationFailed(f"OpenAI request failed: {exc}", category="transport") from exc
        finally:
            # Never wait on the worker: if it's still running, it stops
            # itself at the deadline (see `_post`).
            executor.shutdown(wait=False, cancel_futures=True)

    def _post(self, payload: dict, deadline: float) -> bytes:
        """Runs in the worker thread. Streams the response body, giving up
        as soon as the wall-clock `deadline` has passed."""
        with self._client.stream(
            "POST",
            OPENAI_API_URL,
            headers={"Authorization": f"Bearer {self._api_key}"},
            json=payload,
        ) as response:
            if response.status_code != 200:
                raise InsightGenerationFailed(
                    f"OpenAI returned status {response.status_code}", category="http_status"
                )
            chunks: list[bytes] = []
            for chunk in response.iter_bytes():
                if time.monotonic() >= deadline:
                    raise InsightGenerationFailed("OpenAI response exceeded its deadline", category="timeout")
                chunks.append(chunk)
            return b"".join(chunks)


class UnconfiguredInsightGenerator:
    """Used when no `openai_api_key` is configured: every call fails
    immediately with `InsightGenerationFailed`, without any network I/O,
    so `/insights` degrades gracefully instead of the app failing to boot."""

    def generate(
        self,
        dashboard: DashboardOut,
        drift: list[DriftFlag],
        user_set_asset_classes: frozenset[str],
    ) -> InsightsNarrative:
        raise InsightGenerationFailed("OpenAI API key is not configured", category="missing_api_key")


def get_insight_generator() -> Generator[InsightGenerator, None, None]:
    """FastAPI dependency used by routers that need an `InsightGenerator`.

    Builds an `OpenAIInsightGenerator` from `get_settings()` plus a
    fresh `httpx.Client`, and closes the client once the request is
    done so connections are never leaked. Tests override this with a
    fake generator so they never hit the network (see `conftest.py`).

    With no API key configured, yields an `UnconfiguredInsightGenerator`
    instead (no client is ever built). It deliberately doesn't raise
    here: an exception during dependency resolution would happen before
    the route's own error handling and surface as a 500.
    """
    settings = get_settings()
    if not settings.openai_api_key:
        yield UnconfiguredInsightGenerator()
        return

    client = httpx.Client(timeout=OPENAI_HTTP_TIMEOUT_SECONDS)
    try:
        yield OpenAIInsightGenerator(api_key=settings.openai_api_key, client=client)
    finally:
        client.close()
