# Backend Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the FastAPI + PostgreSQL backend core — Google-OAuth auth, the
user/account/snapshot/holding/target/todo data model, and the CRUD + dashboard
API — so later plans (vision extraction, insights, frontend) have a working,
tested foundation to build on.

**Architecture:** A single FastAPI service backed by PostgreSQL via SQLAlchemy
2.0 + Alembic migrations. Every table carries `user_id`; a shared auth
dependency resolves the current user from a session JWT and every router
filters by it, so cross-user access is structurally impossible rather than
checked ad hoc. Snapshot creation and dashboard aggregation are plain Python
service functions (not just HTTP handlers) so Plan 2 (vision pipeline) and
Plan 3 (insights engine) can call them directly in-process.

**Tech Stack:** Python 3.12, FastAPI, SQLAlchemy 2.0, Alembic, Pydantic v2,
PyJWT (session tokens), Authlib (Google OAuth), httpx (FX rate calls),
pytest + pytest-asyncio, SQLite in-memory for tests / PostgreSQL in
production.

**Spec:** `docs/superpowers/specs/2026-11-08-personal-finance-tracker-design.md`

## Global Constraints

- Every user-owned table has a `user_id` foreign key; every query that reads
  or writes user-owned rows filters by the authenticated user's id.
- Minimum currency set: CAD, USD, CNY, HKD, SGD, plus crypto assets (valued
  via a market-price lookup, not FX).
- Each holding stores its value converted to a single reference currency
  (USD) at the FX rate in effect when its snapshot was created; that locked
  USD value is what trend-over-time and historical rollups use — never
  recomputed against today's rate.
- `country`/jurisdiction and `currency` are separate fields on every holding.
- Secrets (DB URL, Google OAuth client secret, JWT signing key, FX API key)
  are read from environment variables only, never hardcoded or committed.
- Snapshots are immutable once created: no update/delete endpoint for a
  snapshot or its holdings in this plan.

## Review Focus

- A request for an account, snapshot, or todo belonging to a different user
  returns 404 (not a 403 that confirms the row exists, not the other user's
  data) — this is the anti-goal from the spec ("any user's data visible to
  another user, even partially").
- A dashboard request in a currency with no FX rate available returns a
  clear error rather than silently defaulting to 1:1 or crashing.
- A snapshot submitted with a negative holding value or an unrecognized
  currency code is rejected at the API boundary (422), not stored.
- Two snapshots for the same account on the same calendar date are both
  kept as distinct snapshots (not merged/overwritten) — "snapshots are
  never overwritten" from the spec applies even same-day.
- `GET /dashboard` for a brand-new user with zero accounts returns a valid
  empty summary (zero net worth, empty breakdowns) rather than erroring.

---

## File Structure

```
backend/
  app/
    main.py                  # FastAPI app, router registration
    config.py                # env-driven Settings
    db.py                     # engine/session, Base
    models/
      user.py                 # User
      account.py               # Account
      snapshot.py              # Snapshot
      holding.py               # Holding
      target.py                # AllocationTarget
      todo.py                  # Todo
    schemas/
      account.py
      snapshot.py
      target.py
      todo.py
      dashboard.py
    auth/
      google_oauth.py          # Google token verification
      session.py                # JWT issue/verify
      dependencies.py            # get_current_user
    services/
      fx.py                      # FXRateProvider + convert_to_usd/convert_from_usd
      snapshots.py                 # create_snapshot() service function
      dashboard.py                  # build_dashboard() service function
      allocation.py                  # default targets + drift computation
    routers/
      auth.py
      accounts.py
      snapshots.py
      targets.py
      todos.py
      dashboard.py
  alembic/
    env.py
    versions/
  alembic.ini
  requirements.txt
  tests/
    conftest.py
    test_auth.py
    test_accounts.py
    test_snapshots.py
    test_dashboard.py
    test_targets.py
    test_todos.py
    test_fx.py
```

---

### Task 1: Project scaffolding, config, DB wiring, health check

**Files:**
- Create: `backend/requirements.txt`
- Create: `backend/app/config.py`
- Create: `backend/app/db.py`
- Create: `backend/app/main.py`
- Create: `backend/alembic.ini`, `backend/alembic/env.py`
- Test: `backend/tests/conftest.py`, `backend/tests/test_health.py`

**Interfaces:**
- Produces: `Settings` (in `config.py`) with fields `database_url: str`,
  `jwt_secret: str`, `google_client_id: str`, `google_client_secret: str`,
  `fx_api_key: str | None`, loaded via `get_settings() -> Settings`
  (pydantic-settings, reads from env).
- Produces: `db.py` exports `engine`, `SessionLocal`, `Base` (declarative
  base), and `get_db()` FastAPI dependency yielding a session.
- Produces: `tests/conftest.py` exports a `client` fixture (FastAPI
  `TestClient`) wired to an in-memory SQLite engine, and a `db_session`
  fixture, both overriding `get_db`.

- [ ] **Step 1: Write the failing test**

```python
# backend/tests/test_health.py
def test_health_check(client):
    response = client.get("/health")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest backend/tests/test_health.py -v`
Expected: FAIL (no app / no `/health` route / import error)

- [ ] **Step 3: Implement scaffolding**

Write `config.py` (`Settings`/`get_settings`), `db.py` (`engine`,
`SessionLocal`, `Base`, `get_db`), `main.py` (FastAPI app with a
`GET /health` route returning `{"status": "ok"}`), `requirements.txt`
pinning fastapi, uvicorn, sqlalchemy, alembic, pydantic-settings, pyjwt,
authlib, httpx, pytest, pytest-asyncio, and `alembic.ini` +
`alembic/env.py` pointed at `Base.metadata` and `Settings.database_url`.
Write `tests/conftest.py` with the `client`/`db_session` fixtures
described above, using `sqlite:///:memory:` with `StaticPool` so all
connections in a test share one in-memory DB.

- [ ] **Step 4: Run test to verify it passes**

Run: `pytest backend/tests/test_health.py -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add backend/requirements.txt backend/app/config.py backend/app/db.py backend/app/main.py backend/alembic.ini backend/alembic/env.py backend/tests/conftest.py backend/tests/test_health.py
git commit -m "feat: scaffold FastAPI backend with health check"
```

---

### Task 2: Data models and migration

**Files:**
- Create: `backend/app/models/user.py`, `account.py`, `snapshot.py`,
  `holding.py`, `target.py`, `todo.py`
- Create: `backend/alembic/versions/0001_initial.py`
- Test: `backend/tests/test_models.py`

**Interfaces:**
- Consumes: `Base` from `app/db.py` (Task 1).
- Produces:
  - `User(id: int, google_sub: str, email: str, created_at: datetime)`
  - `Account(id: int, user_id: int, name: str, institution: str,
    account_type: str, created_at: datetime)` — `account_type` is a free
    string (e.g. "brokerage", "cash", "rrsp", "crypto"), not an enum, so
    new types don't need a migration.
  - `Snapshot(id: int, account_id: int, taken_at: date, created_at: datetime)`
  - `Holding(id: int, snapshot_id: int, label: str, asset_class: str,
    quantity: float | None, value: float, currency: str, country: str,
    value_usd: float, fx_rate_to_usd: float)` — `value`/`currency` is the
    as-reported amount, `value_usd`/`fx_rate_to_usd` is the locked
    reference-currency conversion from the time of creation.
  - `AllocationTarget(id: int, user_id: int, asset_class: str,
    target_pct: float, is_user_set: bool, updated_at: datetime)`
  - `Todo(id: int, user_id: int, description: str, done: bool,
    related_asset_class: str | None, created_at: datetime)`
  - All FKs use `ondelete="CASCADE"`.

- [ ] **Step 1: Write the failing test**

```python
# backend/tests/test_models.py
def test_create_full_holding_chain(db_session):
    user = User(google_sub="g-1", email="a@example.com")
    db_session.add(user)
    db_session.flush()
    account = Account(user_id=user.id, name="RBC RRSP", institution="RBC", account_type="rrsp")
    db_session.add(account)
    db_session.flush()
    snapshot = Snapshot(account_id=account.id, taken_at=date(2026, 11, 8))
    db_session.add(snapshot)
    db_session.flush()
    holding = Holding(
        snapshot_id=snapshot.id, label="VFV", asset_class="equity",
        quantity=10, value=1000.0, currency="CAD", country="CA",
        value_usd=720.0, fx_rate_to_usd=0.72,
    )
    db_session.add(holding)
    db_session.commit()

    assert db_session.get(Holding, holding.id).value_usd == 720.0
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest backend/tests/test_models.py -v`
Expected: FAIL (models don't exist)

- [ ] **Step 3: Implement the six models listed in Interfaces, and a single Alembic revision creating all six tables**

One line on approach: define relationships (`Account.snapshots`,
`Snapshot.holdings`) with `back_populates` so later tasks can navigate
without extra queries; `account_type`/`asset_class`/`currency`/`country`
are plain `String` columns, validated at the schema layer (Task 4/6), not
with DB-level enums.

- [ ] **Step 4: Run test to verify it passes**

Run: `pytest backend/tests/test_models.py -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add backend/app/models backend/alembic/versions/0001_initial.py backend/tests/test_models.py
git commit -m "feat: add core data model (user, account, snapshot, holding, target, todo)"
```

---

### Task 3: Google OAuth login and session auth

**Files:**
- Create: `backend/app/auth/google_oauth.py`
- Create: `backend/app/auth/session.py`
- Create: `backend/app/auth/dependencies.py`
- Create: `backend/app/routers/auth.py`
- Modify: `backend/app/main.py` (register `auth` router)
- Test: `backend/tests/test_auth.py`

**Interfaces:**
- Consumes: `Settings` (Task 1), `User` model (Task 2).
- Produces:
  - `google_oauth.verify_google_id_token(token: str) -> GoogleProfile`
    (`GoogleProfile` has `sub: str`, `email: str`) — raises
    `InvalidGoogleToken` on failure. Implementation calls Authlib's
    token-verification against Google's public keys; tests monkeypatch
    this function rather than hitting Google.
  - `session.create_session_token(user_id: int) -> str` and
    `session.decode_session_token(token: str) -> int` (returns user_id,
    raises `InvalidSessionToken` on failure/expiry) — PyJWT, signed with
    `Settings.jwt_secret`.
  - `dependencies.get_current_user(request, db=Depends(get_db)) -> User`
    — reads the `Authorization: Bearer <token>` header, decodes it, loads
    the `User` row, raises `HTTPException(401)` if missing/invalid. Every
    later router depends on this.
  - `POST /auth/google` accepts `{"id_token": str}`, verifies it, creates
    the `User` row if `google_sub` is new, returns
    `{"access_token": str, "user": {...}}`.

- [ ] **Step 1: Write the failing test**

```python
# backend/tests/test_auth.py
def test_google_login_creates_user_and_returns_token(client, monkeypatch):
    monkeypatch.setattr(
        "app.routers.auth.verify_google_id_token",
        lambda token: GoogleProfile(sub="g-42", email="new@example.com"),
    )
    response = client.post("/auth/google", json={"id_token": "fake"})
    assert response.status_code == 200
    body = response.json()
    assert body["user"]["email"] == "new@example.com"
    assert decode_session_token(body["access_token"]) is not None

def test_protected_route_rejects_missing_token(client):
    response = client.get("/accounts")
    assert response.status_code == 401
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest backend/tests/test_auth.py -v`
Expected: FAIL (no `/auth/google` route, no `/accounts` route yet for the
second test — acceptable; it will pass once Task 4 adds the route behind
this auth dependency)

- [ ] **Step 3: Implement `google_oauth.py`, `session.py`, `dependencies.py`, `routers/auth.py` as specified in Interfaces**

- [ ] **Step 4: Run test to verify it passes**

Run: `pytest backend/tests/test_auth.py::test_google_login_creates_user_and_returns_token -v`
Expected: PASS (the missing-token test is finished once Task 4 lands; note
it here and re-run the full file after Task 4)

- [ ] **Step 5: Commit**

```bash
git add backend/app/auth backend/app/routers/auth.py backend/app/main.py backend/tests/test_auth.py
git commit -m "feat: add Google OAuth login and session auth"
```

---

### Task 4: Accounts CRUD API

**Files:**
- Create: `backend/app/schemas/account.py`
- Create: `backend/app/routers/accounts.py`
- Modify: `backend/app/main.py` (register `accounts` router)
- Test: `backend/tests/test_accounts.py`

**Interfaces:**
- Consumes: `get_current_user` (Task 3), `Account` model (Task 2).
- Produces:
  - `AccountIn(name: str, institution: str, account_type: str)`,
    `AccountOut(id: int, name: str, institution: str, account_type: str,
    created_at: datetime)` (Pydantic).
  - `POST /accounts`, `GET /accounts`, `GET /accounts/{id}`,
    `PATCH /accounts/{id}`, `DELETE /accounts/{id}` — every handler filters
    by `current_user.id`; `GET/PATCH/DELETE` on another user's account id
    return 404.

- [ ] **Step 1: Write the failing test**

```python
# backend/tests/test_accounts.py
def test_account_crud_scoped_to_user(client, auth_header_for):
    headers_a = auth_header_for("a@example.com")
    headers_b = auth_header_for("b@example.com")

    created = client.post("/accounts", json={"name": "RBC RRSP", "institution": "RBC", "account_type": "rrsp"}, headers=headers_a).json()
    account_id = created["id"]

    assert client.get(f"/accounts/{account_id}", headers=headers_a).status_code == 200
    assert client.get(f"/accounts/{account_id}", headers=headers_b).status_code == 404
    assert len(client.get("/accounts", headers=headers_a).json()) == 1
    assert client.delete(f"/accounts/{account_id}", headers=headers_a).status_code == 204
    assert client.get(f"/accounts/{account_id}", headers=headers_a).status_code == 404
```

Add an `auth_header_for(email: str) -> dict` fixture to `conftest.py` that
creates/logs in a user via the Task 3 flow and returns
`{"Authorization": f"Bearer {token}"}`.

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest backend/tests/test_accounts.py -v`
Expected: FAIL (no `/accounts` routes)

- [ ] **Step 3: Implement `schemas/account.py` and `routers/accounts.py` per Interfaces**

- [ ] **Step 4: Run test to verify it passes**

Run: `pytest backend/tests/test_accounts.py backend/tests/test_auth.py -v`
Expected: PASS (this also completes Task 3's `test_protected_route_rejects_missing_token`)

- [ ] **Step 5: Commit**

```bash
git add backend/app/schemas/account.py backend/app/routers/accounts.py backend/app/main.py backend/tests/test_accounts.py backend/tests/conftest.py
git commit -m "feat: add accounts CRUD API scoped per user"
```

---

### Task 5: FX rate service

**Files:**
- Create: `backend/app/services/fx.py`
- Test: `backend/tests/test_fx.py`

**Interfaces:**
- Produces:
  - `FXRateProvider` protocol with `get_rate(base: str, quote: str) -> float`.
  - `HttpFXRateProvider(FXRateProvider)` — calls a free FX-rate HTTP API
    (implementer's choice) via `httpx`, raises `FXRateUnavailable` if the
    pair isn't returned.
  - `convert(amount: float, from_currency: str, to_currency: str,
    provider: FXRateProvider) -> float` — returns `amount *
    provider.get_rate(from_currency, to_currency)`; `from_currency ==
    to_currency` short-circuits to `amount` without calling the provider.
  - `SUPPORTED_CURRENCIES = {"CAD", "USD", "CNY", "HKD", "SGD"}` (crypto
    handled separately in Task 6, not through this FX path).

- [ ] **Step 1: Write the failing test**

```python
# backend/tests/test_fx.py
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest backend/tests/test_fx.py -v`
Expected: FAIL (module doesn't exist)

- [ ] **Step 3: Implement `fx.py` per Interfaces**

One line on approach: pick any one free FX API for `HttpFXRateProvider`
(e.g. exchangerate.host or similar) — it is not exercised by these tests,
which only test `convert()` against fakes.

- [ ] **Step 4: Run test to verify it passes**

Run: `pytest backend/tests/test_fx.py -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add backend/app/services/fx.py backend/tests/test_fx.py
git commit -m "feat: add FX rate conversion service"
```

---

### Task 6: Snapshot creation (service + API)

**Files:**
- Create: `backend/app/schemas/snapshot.py`
- Create: `backend/app/services/snapshots.py`
- Create: `backend/app/routers/snapshots.py`
- Modify: `backend/app/main.py`
- Test: `backend/tests/test_snapshots.py`

**Interfaces:**
- Consumes: `Account`, `Snapshot`, `Holding` models (Task 2),
  `get_current_user` (Task 3), `convert`/`FXRateProvider` (Task 5).
- Produces:
  - `HoldingIn(label: str, asset_class: str, quantity: float | None,
    value: float, currency: str, country: str)` — `value` must be `>= 0`;
    `currency` must be one of `fx.SUPPORTED_CURRENCIES | {"CRYPTO"}`
    (pydantic validators), else 422.
  - `SnapshotIn(taken_at: date, holdings: list[HoldingIn])`.
  - `services.snapshots.create_snapshot(db: Session, account: Account,
    data: SnapshotIn, fx_provider: FXRateProvider) -> Snapshot` — creates
    the `Snapshot` row and one `Holding` row per item, setting
    `value_usd`/`fx_rate_to_usd` via `fx.convert` (crypto holdings get
    `fx_rate_to_usd = 1.0` and `value_usd = value` for this plan — a real
    market-price lookup is out of scope here and left to Plan 2/3).
    Returns the created `Snapshot` with `holdings` populated. This is the
    function Plan 2 (vision pipeline) calls directly after extraction is
    confirmed.
  - `POST /accounts/{account_id}/snapshots` — 404 if the account doesn't
    belong to the current user; 422 on an invalid holding; otherwise 201
    with the created snapshot (id, taken_at, holdings).

- [ ] **Step 1: Write the failing test**

```python
# backend/tests/test_snapshots.py
def test_create_snapshot_locks_usd_value(client, auth_header_for):
    headers = auth_header_for("a@example.com")
    account_id = client.post("/accounts", json={"name": "Wealthsimple", "institution": "Wealthsimple", "account_type": "brokerage"}, headers=headers).json()["id"]

    response = client.post(
        f"/accounts/{account_id}/snapshots",
        json={"taken_at": "2026-11-08", "holdings": [
            {"label": "VFV", "asset_class": "equity", "quantity": 10, "value": 1000.0, "currency": "CAD", "country": "CA"}
        ]},
        headers=headers,
    )
    assert response.status_code == 201
    holding = response.json()["holdings"][0]
    assert holding["currency"] == "CAD"
    assert holding["value_usd"] == pytest.approx(holding["value"] * holding["fx_rate_to_usd"])

def test_create_snapshot_rejects_negative_value(client, auth_header_for):
    headers = auth_header_for("a@example.com")
    account_id = client.post("/accounts", json={"name": "Binance", "institution": "Binance", "account_type": "crypto"}, headers=headers).json()["id"]
    response = client.post(
        f"/accounts/{account_id}/snapshots",
        json={"taken_at": "2026-11-08", "holdings": [{"label": "BTC", "asset_class": "crypto", "quantity": 1, "value": -5.0, "currency": "CRYPTO", "country": "CA"}]},
        headers=headers,
    )
    assert response.status_code == 422

def test_create_snapshot_for_other_users_account_is_404(client, auth_header_for):
    headers_a = auth_header_for("a@example.com")
    headers_b = auth_header_for("b@example.com")
    account_id = client.post("/accounts", json={"name": "RBC", "institution": "RBC", "account_type": "cash"}, headers=headers_a).json()["id"]
    response = client.post(f"/accounts/{account_id}/snapshots", json={"taken_at": "2026-11-08", "holdings": []}, headers=headers_b)
    assert response.status_code == 404

def test_create_snapshot_rejects_unrecognized_currency(client, auth_header_for):
    headers = auth_header_for("a@example.com")
    account_id = client.post("/accounts", json={"name": "RBC", "institution": "RBC", "account_type": "cash"}, headers=headers).json()["id"]
    response = client.post(
        f"/accounts/{account_id}/snapshots",
        json={"taken_at": "2026-11-08", "holdings": [{"label": "Cash", "asset_class": "cash", "quantity": None, "value": 100.0, "currency": "ZZZ", "country": "CA"}]},
        headers=headers,
    )
    assert response.status_code == 422

def test_two_snapshots_same_date_both_kept(client, auth_header_for):
    headers = auth_header_for("a@example.com")
    account_id = client.post("/accounts", json={"name": "RBC", "institution": "RBC", "account_type": "cash"}, headers=headers).json()["id"]
    payload = {"taken_at": "2026-11-08", "holdings": [{"label": "Cash", "asset_class": "cash", "quantity": None, "value": 100.0, "currency": "USD", "country": "CA"}]}

    first = client.post(f"/accounts/{account_id}/snapshots", json=payload, headers=headers)
    second = client.post(f"/accounts/{account_id}/snapshots", json=payload, headers=headers)
    assert first.status_code == 201
    assert second.status_code == 201
    assert first.json()["id"] != second.json()["id"]
```

Monkeypatch `fx.HttpFXRateProvider` (or inject a fake via a FastAPI
dependency override) in `conftest.py` so these tests don't hit a real FX
API — return a fixed rate (e.g. CAD->USD = 0.72).

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest backend/tests/test_snapshots.py -v`
Expected: FAIL (no snapshot routes/service)

- [ ] **Step 3: Implement `schemas/snapshot.py`, `services/snapshots.py`, `routers/snapshots.py` per Interfaces**

- [ ] **Step 4: Run test to verify it passes**

Run: `pytest backend/tests/test_snapshots.py -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add backend/app/schemas/snapshot.py backend/app/services/snapshots.py backend/app/routers/snapshots.py backend/app/main.py backend/tests/test_snapshots.py backend/tests/conftest.py
git commit -m "feat: add snapshot creation service and API with locked USD conversion"
```

---

### Task 7: Dashboard summary API

**Files:**
- Create: `backend/app/schemas/dashboard.py`
- Create: `backend/app/services/dashboard.py`
- Create: `backend/app/routers/dashboard.py`
- Modify: `backend/app/main.py`
- Test: `backend/tests/test_dashboard.py`

**Interfaces:**
- Consumes: `Account`/`Snapshot`/`Holding` models (Task 2), `convert`
  (Task 5), `get_current_user` (Task 3).
- Produces:
  - `DashboardOut(net_worth: float, currency: str, by_asset_class:
    dict[str, float], by_country: dict[str, float], accounts:
    list[AccountSummary], trend: list[TrendPoint])` where
    `AccountSummary(account_id: int, name: str, as_of: date | None,
    value: float)` and `TrendPoint(taken_at: date, net_worth: float)`.
  - `services.dashboard.build_dashboard(db: Session, user_id: int,
    display_currency: str, fx_provider: FXRateProvider) -> DashboardOut` —
    for each account, takes its latest snapshot only (the "current state
    is a merge" rule from the spec); sums `value_usd` across those
    holdings, converts the USD total to `display_currency` via `convert`;
    buckets by `asset_class` and by `country`; builds `trend` from every
    distinct `taken_at` across all of the user's snapshots, summing that
    date's known holdings. A user with zero accounts gets `net_worth=0.0`,
    empty dicts/lists, not an error.
  - `GET /dashboard?currency=CAD` — 422 if `currency` isn't in
    `fx.SUPPORTED_CURRENCIES`.

- [ ] **Step 1: Write the failing test**

```python
# backend/tests/test_dashboard.py
def test_dashboard_for_new_user_is_empty(client, auth_header_for):
    headers = auth_header_for("new@example.com")
    response = client.get("/dashboard?currency=USD", headers=headers)
    assert response.status_code == 200
    body = response.json()
    assert body["net_worth"] == 0.0
    assert body["by_asset_class"] == {}
    assert body["accounts"] == []

def test_dashboard_sums_latest_snapshot_per_account(client, auth_header_for):
    headers = auth_header_for("a@example.com")
    account_id = client.post("/accounts", json={"name": "RBC", "institution": "RBC", "account_type": "cash"}, headers=headers).json()["id"]
    client.post(f"/accounts/{account_id}/snapshots", json={"taken_at": "2026-10-01", "holdings": [{"label": "Cash", "asset_class": "cash", "quantity": None, "value": 500.0, "currency": "USD", "country": "CA"}]}, headers=headers)
    client.post(f"/accounts/{account_id}/snapshots", json={"taken_at": "2026-11-08", "holdings": [{"label": "Cash", "asset_class": "cash", "quantity": None, "value": 800.0, "currency": "USD", "country": "CA"}]}, headers=headers)

    response = client.get("/dashboard?currency=USD", headers=headers)
    body = response.json()
    assert body["net_worth"] == 800.0  # latest snapshot only, not summed across both
    assert len(body["trend"]) == 2

def test_dashboard_rejects_unsupported_currency(client, auth_header_for):
    headers = auth_header_for("a@example.com")
    response = client.get("/dashboard?currency=XYZ", headers=headers)
    assert response.status_code == 422
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest backend/tests/test_dashboard.py -v`
Expected: FAIL (no dashboard route/service)

- [ ] **Step 3: Implement `schemas/dashboard.py`, `services/dashboard.py`, `routers/dashboard.py` per Interfaces**

- [ ] **Step 4: Run test to verify it passes**

Run: `pytest backend/tests/test_dashboard.py -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add backend/app/schemas/dashboard.py backend/app/services/dashboard.py backend/app/routers/dashboard.py backend/app/main.py backend/tests/test_dashboard.py
git commit -m "feat: add dashboard summary API with per-account latest-snapshot merge"
```

---

### Task 8: Allocation targets and drift

**Files:**
- Create: `backend/app/schemas/target.py`
- Create: `backend/app/services/allocation.py`
- Create: `backend/app/routers/targets.py`
- Modify: `backend/app/main.py`
- Test: `backend/tests/test_targets.py`

**Interfaces:**
- Consumes: `AllocationTarget` model (Task 2), `DashboardOut.by_asset_class`
  (Task 7), `get_current_user` (Task 3).
- Produces:
  - `DEFAULT_TARGETS: dict[str, float]` = `{"equity": 60.0, "cash": 20.0,
    "crypto": 10.0, "bond": 10.0}` (percentages; implementer may adjust
    the exact split but must keep it a named, documented constant here, not
    inline magic numbers).
  - `services.allocation.get_or_create_targets(db: Session, user_id: int)
    -> list[AllocationTarget]` — on first call for a user, inserts rows
    from `DEFAULT_TARGETS` with `is_user_set=False`; returns existing rows
    otherwise.
  - `services.allocation.compute_drift(by_asset_class_pct:
    dict[str, float], targets: list[AllocationTarget]) ->
    list[DriftFlag]` where `DriftFlag(asset_class: str, target_pct: float,
    actual_pct: float, delta_pct: float)` — included only when
    `abs(delta_pct) >= 5.0` (a fixed threshold constant,
    `DRIFT_THRESHOLD_PCT = 5.0`).
  - `GET /targets` → list of targets (creating defaults if none exist).
  - `PUT /targets/{asset_class}` body `{"target_pct": float}` → upserts,
    sets `is_user_set=True`; percentages across all of a user's targets
    need not sum to 100 (enforced nowhere in this plan — left as a
    UI-level nudge in Plan 4).
  - `GET /targets/drift?currency=CAD` → `list[DriftFlag]`, computed from
    `build_dashboard`'s `by_asset_class` converted to percentages of that
    dashboard's `net_worth`.

- [ ] **Step 1: Write the failing test**

```python
# backend/tests/test_targets.py
def test_get_targets_creates_defaults_on_first_call(client, auth_header_for):
    headers = auth_header_for("a@example.com")
    response = client.get("/targets", headers=headers)
    assert response.status_code == 200
    body = {t["asset_class"]: t for t in response.json()}
    assert body["crypto"]["target_pct"] == 10.0
    assert body["crypto"]["is_user_set"] is False

def test_updating_a_target_marks_it_user_set(client, auth_header_for):
    headers = auth_header_for("a@example.com")
    client.get("/targets", headers=headers)
    response = client.put("/targets/crypto", json={"target_pct": 25.0}, headers=headers)
    assert response.status_code == 200
    assert response.json()["target_pct"] == 25.0
    assert response.json()["is_user_set"] is True

def test_compute_drift_flags_only_over_threshold():
    targets = [AllocationTarget(asset_class="crypto", target_pct=10.0, is_user_set=False)]
    flags = compute_drift({"crypto": 16.0}, targets)
    assert len(flags) == 1
    assert flags[0].delta_pct == pytest.approx(6.0)

    flags_within_threshold = compute_drift({"crypto": 12.0}, targets)
    assert flags_within_threshold == []
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest backend/tests/test_targets.py -v`
Expected: FAIL (no targets module/routes)

- [ ] **Step 3: Implement `schemas/target.py`, `services/allocation.py`, `routers/targets.py` per Interfaces**

- [ ] **Step 4: Run test to verify it passes**

Run: `pytest backend/tests/test_targets.py -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add backend/app/schemas/target.py backend/app/services/allocation.py backend/app/routers/targets.py backend/app/main.py backend/tests/test_targets.py
git commit -m "feat: add allocation targets with default suggestions and drift computation"
```

---

### Task 9: To-dos API

**Files:**
- Create: `backend/app/schemas/todo.py`
- Create: `backend/app/routers/todos.py`
- Modify: `backend/app/main.py`
- Test: `backend/tests/test_todos.py`

**Interfaces:**
- Consumes: `Todo` model (Task 2), `get_current_user` (Task 3).
- Produces:
  - `TodoIn(description: str, related_asset_class: str | None)`,
    `TodoOut(id: int, description: str, done: bool,
    related_asset_class: str | None, created_at: datetime)`.
  - `POST /todos`, `GET /todos` (optional `?done=false` filter),
    `PATCH /todos/{id}` (body `{"done": bool}`), `DELETE /todos/{id}` — all
    scoped to current user; cross-user access returns 404.

- [ ] **Step 1: Write the failing test**

```python
# backend/tests/test_todos.py
def test_create_list_complete_todo_scoped_to_user(client, auth_header_for):
    headers_a = auth_header_for("a@example.com")
    headers_b = auth_header_for("b@example.com")

    created = client.post("/todos", json={"description": "Trim crypto to 10%", "related_asset_class": "crypto"}, headers=headers_a).json()
    todo_id = created["id"]

    assert client.get(f"/todos", headers=headers_a).json()[0]["done"] is False
    assert client.patch(f"/todos/{todo_id}", json={"done": True}, headers=headers_b).status_code == 404
    patched = client.patch(f"/todos/{todo_id}", json={"done": True}, headers=headers_a).json()
    assert patched["done"] is True
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest backend/tests/test_todos.py -v`
Expected: FAIL (no todos routes)

- [ ] **Step 3: Implement `schemas/todo.py`, `routers/todos.py` per Interfaces**

- [ ] **Step 4: Run test to verify it passes**

Run: `pytest backend/tests/test_todos.py -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add backend/app/schemas/todo.py backend/app/routers/todos.py backend/app/main.py backend/tests/test_todos.py
git commit -m "feat: add to-dos API scoped per user"
```

---

### Task 10: Full-suite run

**Files:** none (verification only)

**Interfaces:** none

- [ ] **Step 1: Run the entire backend test suite**

Run: `pytest backend/tests -v`
Expected: PASS — all tests from Tasks 1-9 green together (confirms no
cross-task regressions, e.g. the Task 3 test that depended on Task 4's
`/accounts` route).

- [ ] **Step 2: Commit (only if Step 1 required fixes)**

```bash
git add -A
git commit -m "fix: resolve cross-task regressions from full suite run"
```
