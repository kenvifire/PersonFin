# Insights Engine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `GET /insights` endpoint that narrates a user's already-computed
dashboard breakdown and allocation drift in plain language via DeepSeek, so the
numbers Plan 1 already computes reliably get a human-readable summary and
per-asset-class suggestions on top — without ever letting an LLM failure take
down the underlying (already-correct) breakdown/drift data.

**Architecture:** Plan 1 already computes net worth, breakdown, and drift
deterministically and correctly (`build_dashboard`, `compute_drift`,
`get_or_create_targets`) — this plan adds a narration layer on top, not a
replacement. A small refactor first extracts the "dashboard → drift" glue
already living inside `routers/targets.py` into a shared service function, so
the new insights endpoint and the existing drift endpoint compute identically
without duplicating logic. Then a DeepSeek integration (mirroring the
existing `FXRateProvider`/`VisionExtractor` injectable-provider pattern
exactly: one exception type for every failure mode, a real HTTP
implementation, a fake for tests) turns the breakdown+drift into a short
natural-language summary plus one suggested action per drifted asset class.
Unlike FX conversion (load-bearing — a dashboard is wrong without it) or
vision extraction (the user is actively waiting on its result), insight
narration is additive: if DeepSeek fails or times out, `/insights` still
returns the correct breakdown and drift, with a clear "commentary
unavailable" fallback instead of failing the whole request.

**Tech Stack:** Same as Plans 1-2 — Python 3.12, FastAPI, SQLAlchemy 2.0,
Pydantic v2, httpx, pytest. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-11-08-personal-finance-tracker-design.md`

**Builds on:** `docs/superpowers/plans/2026-11-08-backend-foundation.md` and
`docs/superpowers/plans/2026-11-08-vision-extraction-pipeline.md` (both
merged to `master`) — reuses `app.services.dashboard.build_dashboard`,
`app.services.allocation.{compute_drift,get_or_create_targets,DEFAULT_TARGETS}`,
`app.schemas.target.DriftFlag`, `app.services.fx.{SUPPORTED_CURRENCIES,get_fx_provider}`
by their exact existing names (all confirmed by reading the actual merged
files before writing this plan, not guessed).

## Global Constraints

- An insight-generation failure (timeout, bad status, malformed response,
  schema mismatch) must NEVER fail the whole `GET /insights` request. The
  breakdown and drift data (already correct, from Plan 1's code) are always
  returned; only the narrative degrades to a clear fallback. This is a
  deliberate, different resilience choice than FX failures (which DO fail
  the whole dashboard request with 503, because currency conversion is
  load-bearing for correctness — narration is additive, not load-bearing).
- Secrets (`deepseek_api_key`) are read from environment variables only via
  `Settings`, never hardcoded, never echoed into any response or log.
- The refactored drift computation must produce IDENTICAL results to the
  pre-refactor inline logic in `routers/targets.py` — every existing drift
  test must keep passing unmodified.
- Named constants for the DeepSeek endpoint URL and model name — no magic
  strings.
- Currency validation happens before any DB/dashboard work (cheap fail-fast,
  matching the existing `/dashboard` and `/targets/drift` pattern).
- No insight-generation network call is made when there is nothing to
  narrate (`net_worth == 0`) — mirrors the existing "no FX call when nothing
  to convert" and "empty drift for zero net worth" patterns already
  established in Plan 1.

## Review Focus

- A DeepSeek failure of any kind results in a 200 response with correct
  breakdown/drift data and a clearly-marked unavailable narrative — never a
  500, and never breakdown/drift data silently dropped or wrong.
- The refactor (extracting `routers/targets.py`'s inline drift-computation
  glue into a shared function) doesn't change `GET /targets/drift`'s
  behavior at all — same inputs, same outputs, proven by the existing test
  suite passing unchanged plus a new test asserting the shared function
  produces identical output to what the old inline code did.
- A user with zero accounts/zero net worth gets a sensible `/insights`
  response (empty breakdown, no drift, a trivial "no holdings yet"
  narrative) without ever calling DeepSeek — not an error, not a wasted
  network call.
- `GET /insights` with an unsupported currency returns 422 before any
  dashboard/DeepSeek work happens — matching `/dashboard` and
  `/targets/drift`'s existing behavior exactly.
- The DeepSeek API key is never present in any error response body, even
  when the DeepSeek call itself fails with an error that might otherwise
  echo request details.

---

## File Structure

```
backend/
  app/
    config.py                       # Modify: + deepseek_api_key
    services/
      allocation.py                  # Modify: + compute_drift_from_dashboard
      insights.py                     # Create: InsightGenerator + DeepSeek impl
    schemas/
      insights.py                      # Create: ActionItem, InsightsNarrative, InsightsOut
    routers/
      targets.py                        # Modify: get_drift uses the shared function
      insights.py                        # Create: GET /insights
    main.py                                # Modify: register insights router
  tests/
    test_allocation.py                      # Create: unit tests for the shared function
    test_insights.py                         # Create
    conftest.py                               # Modify: + deepseek env default,
                                               #   FakeInsightGenerator
```

---

### Task 1: Extract shared drift computation (`compute_drift_from_dashboard`)

**Files:**
- Modify: `backend/app/services/allocation.py`
- Modify: `backend/app/routers/targets.py`
- Create: `backend/tests/test_allocation.py`
- Test (regression): existing `backend/tests/test_targets.py` must keep
  passing unmodified.

**Interfaces:**
- Consumes: `DashboardOut` (`app/schemas/dashboard.py`), `get_or_create_targets`/
  `compute_drift` (already in `app/services/allocation.py`).
- Produces: `compute_drift_from_dashboard(db: Session, user_id: int, dashboard: DashboardOut) -> list[DriftFlag]`
  in `app/services/allocation.py` — does exactly what `routers/targets.py`'s
  `get_drift` currently does inline: returns `[]` immediately if
  `dashboard.net_worth == 0`; otherwise converts `dashboard.by_asset_class`
  (dollar amounts) into percentages of `dashboard.net_worth`, calls
  `get_or_create_targets(db, user_id)`, and returns `compute_drift(...)`.
  Takes an already-built `DashboardOut` (not a currency/FX-provider) so a
  caller that already has a dashboard (this plan's `/insights` endpoint)
  never builds it twice.
- Modifies: `routers/targets.py`'s `get_drift` handler to build the
  dashboard itself (unchanged — it already does this) and then call
  `compute_drift_from_dashboard(db, current_user.id, dashboard)` instead of
  the current inline percentage-conversion + `compute_drift` call. The
  currency-validation and dashboard-building lines stay exactly as they are;
  only the body after `build_dashboard` changes.

- [ ] **Step 1: Write the failing test**

```python
# backend/tests/test_allocation.py
# (imports: `from app.models import AllocationTarget`, `from app.schemas.dashboard import DashboardOut`,
#  `from app.services.allocation import compute_drift_from_dashboard`)

def test_compute_drift_from_dashboard_returns_empty_for_zero_net_worth(db_session):
    dashboard = DashboardOut(net_worth=0.0, currency="USD", by_asset_class={}, by_country={}, accounts=[], trend=[])
    assert compute_drift_from_dashboard(db_session, user_id=1, dashboard=dashboard) == []

def test_compute_drift_from_dashboard_converts_dollars_to_percent_before_comparing(db_session):
    from app.models import User
    user = User(google_sub="g-drift-1", email="drift1@example.com")
    db_session.add(user)
    db_session.commit()
    target = AllocationTarget(user_id=user.id, asset_class="crypto", target_pct=10.0, is_user_set=True)
    db_session.add(target)
    db_session.commit()

    dashboard = DashboardOut(
        net_worth=1000.0, currency="USD",
        by_asset_class={"crypto": 160.0}, by_country={}, accounts=[], trend=[],
    )
    flags = compute_drift_from_dashboard(db_session, user.id, dashboard)
    assert len(flags) == 1
    assert flags[0].asset_class == "crypto"
    assert flags[0].actual_pct == 16.0  # 160/1000 * 100
    assert flags[0].delta_pct == 6.0
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest backend/tests/test_allocation.py -v`
Expected: FAIL (function doesn't exist)

- [ ] **Step 3: Implement `compute_drift_from_dashboard` in `app/services/allocation.py`, then update `routers/targets.py`'s `get_drift` to call it**

One line on approach: this is a pure extraction — copy the existing
percentage-conversion logic out of `targets.py` verbatim into the new
function, don't rewrite it.

- [ ] **Step 4: Run tests to verify everything passes**

Run: `pytest backend/tests/test_allocation.py backend/tests/test_targets.py -v`
Expected: PASS — the new tests pass, AND every existing `test_targets.py`
test (written against the old inline behavior) still passes unmodified,
proving the refactor is behavior-preserving.

- [ ] **Step 5: Commit**

```bash
git add backend/app/services/allocation.py backend/app/routers/targets.py backend/tests/test_allocation.py
git commit -m "refactor: extract compute_drift_from_dashboard, shared by /targets/drift and /insights"
```

---

### Task 2: DeepSeek insight generator service

**Files:**
- Create: `backend/app/schemas/insights.py`
- Create: `backend/app/services/insights.py`
- Modify: `backend/app/config.py`
- Modify: `backend/tests/conftest.py`
- Test: `backend/tests/test_insights_service.py`

**Interfaces:**
- Consumes: `DashboardOut` (`app/schemas/dashboard.py`), `DriftFlag`
  (`app/schemas/target.py`).
- Produces:
  - `Settings.deepseek_api_key: str` (required, no default — a secret,
    matching the existing pattern for `jwt_secret`/`google_client_secret`).
  - `schemas/insights.py`: `ActionItem(asset_class: str, suggestion: str)`,
    `InsightsNarrative(summary: str, action_items: list[ActionItem])` — the
    structured shape DeepSeek's response is parsed/validated into.
  - `services/insights.py`: `DEEPSEEK_API_URL = "https://api.deepseek.com/chat/completions"`,
    `DEEPSEEK_MODEL = "deepseek-chat"` (named constants), `DEEPSEEK_HTTP_TIMEOUT_SECONDS = 15.0`,
    `InsightGenerationFailed(Exception)` — the one exception type for every
    failure mode (bad HTTP status, timeout/connection error, non-JSON top-
    level body, missing `choices`/`message`/`content`, non-JSON inner
    content, content that doesn't validate against `InsightsNarrative`) —
    mirrors `vision.ExtractionFailed`'s role exactly. `InsightGenerator`
    protocol: `generate(dashboard: DashboardOut, drift: list[DriftFlag]) -> InsightsNarrative`.
    `DeepSeekInsightGenerator` (constructor takes `api_key: str, client: httpx.Client`;
    `generate()` POSTs to `DEEPSEEK_API_URL` with `Authorization: Bearer {api_key}`,
    `model: DEEPSEEK_MODEL`, a prompt built from the dashboard's
    `net_worth`/`currency`/`by_asset_class`/`by_country` and the drift
    flags' `asset_class`/`target_pct`/`actual_pct`/`delta_pct`, asking for a
    JSON object matching `InsightsNarrative`'s shape; parses
    `response.json()["choices"][0]["message"]["content"]` as JSON and
    validates it against `InsightsNarrative`, raising `InsightGenerationFailed`
    on any failure). `get_insight_generator() -> Generator[InsightGenerator, None, None]`
    (FastAPI dependency — builds `DeepSeekInsightGenerator` from
    `get_settings()` plus a fresh `httpx.Client`, closes the client in
    `finally` — exact same shape as `fx.get_fx_provider`/`vision.get_vision_extractor`).
  - `conftest.py`: adds `os.environ.setdefault("DEEPSEEK_API_KEY", "test-deepseek-key")`
    and `FakeInsightGenerator(result: InsightsNarrative | None = None, error: str | None = None)`
    whose `.generate(dashboard, drift)` returns `self.result` if set, else
    raises `InsightGenerationFailed(self.error)` — same shape as
    `FakeVisionExtractor`.

- [ ] **Step 1: Write the failing tests**

```python
# backend/tests/test_insights_service.py
# (imports: `import json`, `import httpx`, `import pytest`,
#  `from app.schemas.dashboard import DashboardOut`, `from app.schemas.target import DriftFlag`,
#  `from app.services.insights import DeepSeekInsightGenerator, InsightGenerationFailed`)

def _dashboard():
    return DashboardOut(
        net_worth=1000.0, currency="USD",
        by_asset_class={"crypto": 160.0, "cash": 840.0}, by_country={"CA": 1000.0},
        accounts=[], trend=[],
    )

def test_deepseek_generator_parses_valid_response():
    def handler(request):
        body = {"choices": [{"message": {"content": json.dumps({
            "summary": "Your portfolio is mostly cash with a growing crypto position.",
            "action_items": [{"asset_class": "crypto", "suggestion": "Consider trimming crypto back toward your 10% target."}],
        })}}]}
        return httpx.Response(200, json=body)
    client = httpx.Client(transport=httpx.MockTransport(handler))
    generator = DeepSeekInsightGenerator(api_key="k", client=client)

    drift = [DriftFlag(asset_class="crypto", target_pct=10.0, actual_pct=16.0, delta_pct=6.0)]
    result = generator.generate(_dashboard(), drift)
    assert "crypto" in result.summary.lower() or "cash" in result.summary.lower()
    assert result.action_items[0].asset_class == "crypto"

def test_deepseek_generator_wraps_bad_status_as_insight_generation_failed():
    def handler(request):
        return httpx.Response(500, text="server error")
    client = httpx.Client(transport=httpx.MockTransport(handler))
    generator = DeepSeekInsightGenerator(api_key="k", client=client)
    with pytest.raises(InsightGenerationFailed):
        generator.generate(_dashboard(), [])

def test_deepseek_generator_wraps_malformed_content_as_insight_generation_failed():
    def handler(request):
        return httpx.Response(200, json={"choices": [{"message": {"content": "not json"}}]})
    client = httpx.Client(transport=httpx.MockTransport(handler))
    generator = DeepSeekInsightGenerator(api_key="k", client=client)
    with pytest.raises(InsightGenerationFailed):
        generator.generate(_dashboard(), [])

def test_deepseek_generator_wraps_connection_error_as_insight_generation_failed():
    def handler(request):
        raise httpx.ConnectError("boom")
    client = httpx.Client(transport=httpx.MockTransport(handler))
    generator = DeepSeekInsightGenerator(api_key="k", client=client)
    with pytest.raises(InsightGenerationFailed):
        generator.generate(_dashboard(), [])
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `pytest backend/tests/test_insights_service.py -v`
Expected: FAIL (module doesn't exist)

- [ ] **Step 3: Implement everything listed in Interfaces**

- [ ] **Step 4: Run tests to verify they pass**

Run: `pytest backend/tests -v`
Expected: PASS (full suite, to catch any regression from the `conftest.py`/`config.py` changes)

- [ ] **Step 5: Commit**

```bash
git add backend/app/schemas/insights.py backend/app/services/insights.py backend/app/config.py backend/tests/conftest.py backend/tests/test_insights_service.py
git commit -m "feat: add DeepSeek insight generator service"
```

---

### Task 3: `GET /insights` endpoint with graceful degradation

**Files:**
- Create: `backend/app/routers/insights.py`
- Modify: `backend/app/main.py`
- Test: `backend/tests/test_insights.py`

**Interfaces:**
- Consumes: `build_dashboard` (`app/services/dashboard.py`),
  `compute_drift_from_dashboard` (Task 1), `fx.SUPPORTED_CURRENCIES`/`fx.get_fx_provider`
  (`app/services/fx.py`), `InsightGenerator`/`get_insight_generator`/`InsightGenerationFailed`
  (Task 2), `get_current_user`.
- Produces:
  - `schemas/insights.py` (extended): `InsightsOut(dashboard: DashboardOut, drift: list[DriftFlag], narrative: InsightsNarrative, narrative_unavailable: bool)`.
  - `routers/insights.py`: `router = APIRouter(prefix="/insights", tags=["insights"])`,
    `GET /insights?currency=X` → 422 if `currency not in fx.SUPPORTED_CURRENCIES`
    (before any DB work); builds the dashboard; computes drift via
    `compute_drift_from_dashboard`; if `dashboard.net_worth == 0`, skips
    calling the insight generator entirely and returns a canned
    `InsightsNarrative(summary="No holdings yet — once you add some accounts, insights will appear here.", action_items=[])`
    with `narrative_unavailable=False`; otherwise calls
    `insight_generator.generate(dashboard, drift)` — on success, returns it
    with `narrative_unavailable=False`; on `InsightGenerationFailed`, returns
    `InsightsNarrative(summary="Insight commentary is temporarily unavailable — your numbers above are still accurate.", action_items=[])`
    with `narrative_unavailable=True`. The response status is 200 in every
    case except the 422 currency check — an insight-generation failure never
    produces a non-200 response.
  - `main.py`: registers the `insights` router. No new exception handler
    needed — `InsightGenerationFailed` is caught inside the router, never
    propagated (same pattern as `vision.ExtractionFailed` in the uploads
    router).

- [ ] **Step 1: Write the failing tests**

```python
# backend/tests/test_insights.py
# (imports: `from app.main import app`, `from app.services import insights`,
#  `from app.schemas.insights import InsightsNarrative, ActionItem`)

def test_insights_for_new_user_skips_deepseek_and_returns_empty_narrative(client, auth_header_for):
    headers = auth_header_for("a@example.com")

    def exploding_generate(dashboard, drift):
        raise AssertionError("should not be called for a zero-net-worth user")
    app.dependency_overrides[insights.get_insight_generator] = lambda: type("G", (), {"generate": staticmethod(exploding_generate)})()

    response = client.get("/insights?currency=USD", headers=headers)
    del app.dependency_overrides[insights.get_insight_generator]

    assert response.status_code == 200
    body = response.json()
    assert body["dashboard"]["net_worth"] == 0.0
    assert body["drift"] == []
    assert body["narrative_unavailable"] is False
    assert "no holdings" in body["narrative"]["summary"].lower()

def test_insights_rejects_unsupported_currency(client, auth_header_for):
    headers = auth_header_for("a@example.com")
    response = client.get("/insights?currency=XYZ", headers=headers)
    assert response.status_code == 422

def test_insights_returns_narrative_on_success(client, auth_header_for):
    headers = auth_header_for("a@example.com")
    account_id = client.post(
        "/accounts", json={"name": "RBC", "institution": "RBC", "account_type": "cash"}, headers=headers
    ).json()["id"]
    client.post(
        f"/accounts/{account_id}/snapshots",
        json={"taken_at": "2026-11-08", "holdings": [{"label": "Cash", "asset_class": "cash", "quantity": None, "value": 1000.0, "currency": "USD", "country": "CA"}]},
        headers=headers,
    )

    fake_result = InsightsNarrative(summary="You're heavily weighted to cash.", action_items=[ActionItem(asset_class="cash", suggestion="Consider diversifying into equities.")])
    app.dependency_overrides[insights.get_insight_generator] = lambda: type("G", (), {"generate": staticmethod(lambda dashboard, drift: fake_result)})()
    response = client.get("/insights?currency=USD", headers=headers)
    del app.dependency_overrides[insights.get_insight_generator]

    assert response.status_code == 200
    body = response.json()
    assert body["narrative_unavailable"] is False
    assert body["narrative"]["summary"] == "You're heavily weighted to cash."
    assert body["dashboard"]["net_worth"] == 1000.0

def test_insights_degrades_gracefully_on_generation_failure(client, auth_header_for):
    headers = auth_header_for("a@example.com")
    account_id = client.post(
        "/accounts", json={"name": "RBC", "institution": "RBC", "account_type": "cash"}, headers=headers
    ).json()["id"]
    client.post(
        f"/accounts/{account_id}/snapshots",
        json={"taken_at": "2026-11-08", "holdings": [{"label": "Cash", "asset_class": "cash", "quantity": None, "value": 1000.0, "currency": "USD", "country": "CA"}]},
        headers=headers,
    )

    def failing_generate(dashboard, drift):
        raise insights.InsightGenerationFailed("DeepSeek timed out")
    app.dependency_overrides[insights.get_insight_generator] = lambda: type("G", (), {"generate": staticmethod(failing_generate)})()
    response = client.get("/insights?currency=USD", headers=headers)
    del app.dependency_overrides[insights.get_insight_generator]

    assert response.status_code == 200
    body = response.json()
    assert body["narrative_unavailable"] is True
    assert body["dashboard"]["net_worth"] == 1000.0
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `pytest backend/tests/test_insights.py -v`
Expected: FAIL (no `/insights` route)

- [ ] **Step 3: Implement everything listed in Interfaces**

- [ ] **Step 4: Run tests to verify they pass**

Run: `pytest backend/tests -v`
Expected: PASS (full suite)

- [ ] **Step 5: Commit**

```bash
git add backend/app/routers/insights.py backend/app/main.py backend/tests/test_insights.py
git commit -m "feat: add GET /insights with graceful degradation on LLM failure"
```

---

### Task 4: Full-suite run

**Files:** none (verification only)

**Interfaces:** none

- [ ] **Step 1: Run the entire backend test suite**

Run: `pytest backend/tests -v`
Expected: PASS — all tests from Tasks 1-3 green together, including proof
that the Task 1 refactor didn't change `/targets/drift`'s behavior and that
`/insights` never returns a non-200 response on an LLM failure.

- [ ] **Step 2: Commit (only if Step 1 required fixes)**

```bash
git add -A
git commit -m "fix: resolve cross-task regressions from full suite run"
```
