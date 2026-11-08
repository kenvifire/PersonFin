# Vision Extraction Pipeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a user upload a screenshot of a financial account, have a vision
model extract structured holdings from it, let the user review/correct and
match it to an account (existing or new), and commit the result as an
immutable snapshot via Plan 1's existing `create_snapshot` service — without
ever bypassing Plan 1's holding validation or cross-user isolation patterns.

**Architecture:** A new `Upload` entity tracks one screenshot through a small
state machine (`pending → extracted → confirmed`, with `failed` and
`discarded` as alternate/terminal states). Three new service modules —
`image_storage` (local disk only, per the spec's anti-goal against sending
screenshots to third parties beyond the one extraction call),
`vision` (an injectable `VisionExtractor` protocol, real implementation calls
Azure OpenAI, tests use a fake — mirroring Plan 1's `FXRateProvider`
pattern), and `matching` (deterministic string-similarity account
suggestion, no LLM call) — sit behind a single `routers/uploads.py`. The
confirm step builds a `SnapshotIn` from the user's (possibly edited) holdings
and calls Plan 1's `services.snapshots.create_snapshot` directly, so every
validation rule Plan 1 already enforces (non-negative, finite, recognized
currency/asset-class) applies here too, unmodified.

**Tech Stack:** Same as Plan 1 — Python 3.12, FastAPI, SQLAlchemy 2.0,
Alembic, Pydantic v2, httpx, pytest. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-11-08-personal-finance-tracker-design.md`

**Builds on:** `docs/superpowers/plans/2026-11-08-backend-foundation.md`
(merged to `master`) — reuses `app.routers._ownership`, `app.services.fx`,
`app.services.allocation.normalize_asset_class`, `app.schemas.snapshot.{HoldingIn,SnapshotIn}`,
and `app.services.snapshots.create_snapshot` by their exact existing names.

## Global Constraints

- Every user-owned table has a `user_id` foreign key (directly, or — for
  rows that only make sense attached to something already user-scoped —
  transitively through a FK chain), and every query filters by the
  authenticated user's id. `Upload.user_id` is direct.
- Secrets (Azure OpenAI endpoint, API key, deployment name) are read from
  environment variables only, via `Settings`, never hardcoded.
- The confirm step MUST build its `SnapshotIn` from `app.schemas.snapshot.HoldingIn`
  and call `app.services.snapshots.create_snapshot` directly — never a
  parallel/looser validation path for extraction-sourced holdings.
- Raw screenshot images are stored only on local disk under a configured
  directory; they are never sent to any third party beyond the one
  vision-extraction API call. A confirmed upload's image is retained
  (never deleted); a discarded or failed upload's image may be deleted.
- Named constants required for the upload state machine's status strings
  and the matching threshold — no magic string/number literals scattered
  across files.
- Every external-dependency failure (bad upload, vision API error, timeout,
  malformed response) must map to a clear 4xx/5xx with a readable detail,
  never a bare unhandled 500 — the same resilience standard Plan 1's FX
  work was held to.

## Review Focus

- An oversized file or an unsupported MIME type is rejected with 422 before
  anything is written to disk or billed to the vision API — not silently
  truncated, not stored, not a 500.
- A vision-extraction failure (timeout, non-2xx, malformed/non-JSON
  response, a response that doesn't match the expected shape) sets the
  upload's status to `failed` with a readable `extraction_error` — never a
  bare 500, and never left stuck in `pending` with no way to know it failed.
- Confirming a draft whose user-edited holdings contain an invalid value
  (negative, non-finite, unrecognized currency or asset class) is rejected
  with 422 via the *reused* Plan 1 validation — this plan must prove the
  reuse is real, not bypassed, with a test that sends exactly the kind of
  bad value Plan 1's own tests reject.
- Acting on an upload that doesn't belong to the current user — via
  extract, view, confirm, or discard — returns 404, matching every other
  resource in this codebase; never a 403 that confirms existence, never a
  cross-user leak.
- Acting on an upload already in a terminal state (`confirmed` or
  `discarded`) — re-extracting, re-confirming, or discarding it again —
  returns 409, never a silent no-op and never a second snapshot/second
  file-deletion for the same upload.

---

## File Structure

```
backend/
  app/
    config.py                      # Modify: + upload_dir, azure_openai_*
    models/
      upload.py                     # Create: Upload + status constants
      __init__.py                    # Modify: register Upload
    schemas/
      extraction.py                   # Create: ExtractionResult, DraftHolding
      upload_confirm.py                 # Create: ConfirmUploadIn, NewAccountIn
    services/
      image_storage.py                  # Create: validate/save/delete + base_dir dep
      vision.py                          # Create: VisionExtractor + Azure impl + dep
      matching.py                         # Create: suggest_account
    routers/
      uploads.py                           # Create (T1), modified T2-T5
      _ownership.py                         # Modify: + get_owned_upload_or_404
    main.py                                 # Modify: register uploads router,
                                             #   exception handlers for new errors
  alembic/versions/0003_uploads.py           # Create
  tests/
    test_image_storage.py                     # Create
    test_vision.py                             # Create
    test_matching.py                            # Create
    test_uploads.py                              # Create, grown across T1-T5
    conftest.py                                   # Modify: + azure env defaults,
                                                   #   FakeVisionExtractor,
                                                   #   upload_base_dir override
```

---

### Task 1: Upload model, migration, image storage, and `POST /uploads`

**Files:**
- Create: `backend/app/models/upload.py`
- Modify: `backend/app/models/__init__.py`
- Create: `backend/app/services/image_storage.py`
- Modify: `backend/app/config.py`
- Create: `backend/alembic/versions/0003_uploads.py`
- Create: `backend/app/routers/uploads.py`
- Modify: `backend/app/main.py`
- Modify: `backend/tests/conftest.py`
- Test: `backend/tests/test_image_storage.py`, `backend/tests/test_uploads.py`

**Interfaces:**
- Consumes: `Base` (`app/db.py`), `get_current_user` (`app/auth/dependencies.py`),
  `get_db` (`app/db.py`), `get_settings` (`app/config.py`).
- Produces:
  - `Settings.upload_dir: str = "./data/uploads"` (new field, has a default —
    not a secret, just a path).
  - `models/upload.py`: `STATUS_PENDING = "pending"`, `STATUS_EXTRACTED = "extracted"`,
    `STATUS_FAILED = "failed"`, `STATUS_CONFIRMED = "confirmed"`,
    `STATUS_DISCARDED = "discarded"`, `TERMINAL_STATUSES = frozenset({STATUS_CONFIRMED, STATUS_DISCARDED})`,
    and `Upload(id: int, user_id: int, image_path: str, mime_type: str,
    status: str, extracted_payload: dict | None, extraction_error: str | None,
    suggested_account_id: int | None, matched_account_id: int | None,
    snapshot_id: int | None, created_at: datetime, updated_at: datetime)`.
    `user_id` FK → `users.id` `ondelete="CASCADE"`. `suggested_account_id` FK →
    `accounts.id` `ondelete="SET NULL"`. `matched_account_id`/`snapshot_id` FK →
    `accounts.id`/`snapshots.id` `ondelete="CASCADE"`. `extracted_payload` is a
    plain SQLAlchemy `JSON` column (portable across SQLite/Postgres).
  - `services/image_storage.py`: `ALLOWED_MIME_TYPES = {"image/png", "image/jpeg", "image/webp"}`,
    `MAX_UPLOAD_BYTES = 10 * 1024 * 1024`, `UnsupportedUploadError(Exception)`
    (message explains whether it was the mime type or the size), `validate_upload(mime_type: str, content: bytes) -> None`
    (raises `UnsupportedUploadError`; pure, no I/O), `save_upload_image(base_dir: str, user_id: int, upload_id: int, mime_type: str, content: bytes) -> str`
    (writes the file, returns the path *relative to `base_dir`* — assumes
    already validated), `delete_upload_image(base_dir: str, relative_path: str) -> None`
    (no error if the file is already gone), `get_upload_base_dir() -> str`
    (FastAPI dependency; returns `get_settings().upload_dir` — tests override
    this via `app.dependency_overrides` to point at a `tmp_path`, the same way
    Plan 1 overrides `fx.get_fx_provider`).
  - `routers/uploads.py`: `router = APIRouter(prefix="/uploads", tags=["uploads"])`,
    `POST /uploads` (multipart `file: UploadFile`) → 201 `{"id": int, "status": str}`
    on success; 422 (via a new exception handler mapping `UnsupportedUploadError`,
    mirroring `main.py`'s existing `FXRateUnavailable` → 503 handler pattern) on
    a bad mime type or oversized file. Creates the `Upload` row first (to get an
    id for the filename), then calls `save_upload_image`; on any write failure
    the row stays `pending` with no `image_path` set — acceptable for this task
    (no retry endpoint yet; a user can just re-upload).
  - `main.py`: registers the `uploads` router and an `UnsupportedUploadError` → 422
    exception handler.
  - `conftest.py`: exposes a named pytest fixture `upload_base_dir(tmp_path) -> str`
    that both wires `app.dependency_overrides[image_storage.get_upload_base_dir] = lambda: upload_base_dir`
    (so the `client` fixture automatically uses an isolated directory) and is
    directly requestable by any test that needs to inspect the filesystem
    itself (e.g. to confirm a file was actually deleted on discard). It must
    give each test an isolated directory, not
    write into the real repo tree).

- [ ] **Step 1: Write the failing tests**

```python
# backend/tests/test_image_storage.py
def test_validate_upload_rejects_unsupported_mime_type():
    with pytest.raises(UnsupportedUploadError):
        validate_upload("text/plain", b"not an image")

def test_validate_upload_rejects_oversized_file():
    with pytest.raises(UnsupportedUploadError):
        validate_upload("image/png", b"x" * (MAX_UPLOAD_BYTES + 1))

def test_save_and_delete_upload_image_roundtrip(tmp_path):
    base_dir = str(tmp_path)
    relative_path = save_upload_image(base_dir, user_id=1, upload_id=42, mime_type="image/png", content=b"fake-png-bytes")
    assert (tmp_path / relative_path).exists()
    delete_upload_image(base_dir, relative_path)
    assert not (tmp_path / relative_path).exists()
    delete_upload_image(base_dir, relative_path)  # already gone — no error
```

```python
# backend/tests/test_uploads.py
def test_upload_rejects_unsupported_mime_type(client, auth_header_for):
    headers = auth_header_for("a@example.com")
    response = client.post("/uploads", files={"file": ("x.txt", b"hello", "text/plain")}, headers=headers)
    assert response.status_code == 422

def test_upload_rejects_oversized_file(client, auth_header_for):
    headers = auth_header_for("a@example.com")
    big = b"x" * (image_storage.MAX_UPLOAD_BYTES + 1)
    response = client.post("/uploads", files={"file": ("x.png", big, "image/png")}, headers=headers)
    assert response.status_code == 422

def test_upload_creates_pending_record_and_stores_file(client, auth_header_for):
    headers = auth_header_for("a@example.com")
    response = client.post("/uploads", files={"file": ("x.png", b"fake-png-bytes", "image/png")}, headers=headers)
    assert response.status_code == 201
    assert response.json()["status"] == "pending"
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `pytest backend/tests/test_image_storage.py backend/tests/test_uploads.py -v`
Expected: FAIL (modules/routes don't exist)

- [ ] **Step 3: Implement everything listed in Interfaces**

One line on approach: derive the file extension from `mime_type` via a small
`{"image/png": "png", "image/jpeg": "jpg", "image/webp": "webp"}` mapping in
`image_storage.py`; write files at `{base_dir}/{user_id}/{upload_id}.{ext}`
and return that path relative to `base_dir`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `pytest backend/tests/test_image_storage.py backend/tests/test_uploads.py -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add backend/app/models/upload.py backend/app/models/__init__.py backend/app/services/image_storage.py backend/app/config.py backend/alembic/versions/0003_uploads.py backend/app/routers/uploads.py backend/app/main.py backend/tests/conftest.py backend/tests/test_image_storage.py backend/tests/test_uploads.py
git commit -m "feat: add Upload model, image storage service, and POST /uploads"
```

---

### Task 2: Vision extraction (`VisionExtractor` + Azure implementation + `POST /uploads/{id}/extract`)

**Files:**
- Create: `backend/app/schemas/extraction.py`
- Create: `backend/app/services/vision.py`
- Modify: `backend/app/config.py`
- Modify: `backend/app/routers/uploads.py`
- Modify: `backend/app/main.py`
- Modify: `backend/tests/conftest.py`
- Test: `backend/tests/test_vision.py`, additions to `backend/tests/test_uploads.py`

**Interfaces:**
- Consumes: `Upload`, `STATUS_PENDING/EXTRACTED/FAILED`, `TERMINAL_STATUSES`
  (Task 1), `get_owned_upload_or_404` (added in Task 3 — **not yet available**;
  for this task, reuse the pattern inline: `db.query(Upload).filter(Upload.id == upload_id, Upload.user_id == current_user.id).first()`,
  404 if `None`. Task 3 will replace this with the shared helper once it
  exists — note this explicitly so the deviation is intentional, not missed.)
- Produces:
  - `Settings.azure_openai_endpoint: str`, `Settings.azure_openai_api_key: str`,
    `Settings.azure_openai_deployment: str` (all required, no defaults —
    secrets/config, matching the existing pattern for `jwt_secret` etc.).
  - `schemas/extraction.py`: `DraftHolding(label: str, asset_class_guess: str | None, quantity: float | None, value: float | None, currency_guess: str | None, country_guess: str | None)`
    (loose — these are unvalidated guesses for the user to review, not the
    strict `HoldingIn`), `ExtractionResult(institution: str | None, account_label: str | None, account_type_guess: str | None, taken_at_guess: date | None, holdings: list[DraftHolding])`.
  - `services/vision.py`: `ExtractionFailed(Exception)` (the one exception
    type for every failure mode — bad status, timeout, non-JSON body,
    response that doesn't parse into `ExtractionResult` — mirroring
    `fx.FXRateUnavailable`'s role exactly), `VisionExtractor` protocol with
    `extract(image_bytes: bytes, mime_type: str) -> ExtractionResult`,
    `AzureOpenAIVisionExtractor` (constructor takes `endpoint: str, api_key: str, deployment: str, client: httpx.Client`;
    `extract()` POSTs to Azure OpenAI's chat-completions endpoint with the
    image base64-encoded in the message content, asks for a JSON object
    matching `ExtractionResult`'s shape, parses `response.json()["choices"][0]["message"]["content"]`
    as JSON and validates it against `ExtractionResult`, raising
    `ExtractionFailed` on any failure), `get_vision_extractor() -> Generator[VisionExtractor, None, None]`
    (FastAPI dependency — builds `AzureOpenAIVisionExtractor` from `get_settings()`
    plus a fresh `httpx.Client`, closes the client in `finally`; tests override
    this exactly like `fx.get_fx_provider`).
  - `routers/uploads.py`: `POST /uploads/{id}/extract` → looks up the upload
    (scoped to current user, 404 otherwise); 409 if `upload.status in TERMINAL_STATUSES`;
    otherwise reads the stored image file, calls `extractor.extract(...)`; on
    success sets `status = STATUS_EXTRACTED`, `extracted_payload = result.model_dump(mode="json")`,
    `extraction_error = None`; on `ExtractionFailed` sets `status = STATUS_FAILED`,
    `extraction_error = str(exc)`, commits, and returns 200 either way with
    `{"id", "status", "extracted_payload", "extraction_error"}` (never raises
    on extraction failure itself — the *endpoint* succeeds at recording the
    failure).
  - `main.py`: no new exception handler needed — `ExtractionFailed` is caught
    inside the router, not propagated.
  - `conftest.py`: adds `os.environ.setdefault("AZURE_OPENAI_ENDPOINT", "https://test.example/openai")`,
    `..._API_KEY`, `..._DEPLOYMENT` setdefaults (same pattern as the existing
    Google/JWT ones), and `FakeVisionExtractor(result: ExtractionResult | None = None, error: str | None = None)`
    whose `.extract(image_bytes, mime_type)` returns `self.result` if set, else
    raises `ExtractionFailed(self.error)` — tests pick one or the other per
    call via `app.dependency_overrides[vision.get_vision_extractor] = lambda: FakeVisionExtractor(...)`,
    the same per-test override style Plan 1 uses for `fx.get_fx_provider`. The
    `client` fixture's *default* override (no test-specific override set)
    should use a `FakeVisionExtractor` with a harmless empty `ExtractionResult`,
    so tests that don't care about extraction at all (e.g. just testing upload
    creation) don't need to set one up themselves.

- [ ] **Step 1: Write the failing tests**

```python
# backend/tests/test_vision.py
def test_azure_extractor_parses_valid_response():
    def handler(request):
        body = {"choices": [{"message": {"content": json.dumps({
            "institution": "RBC", "account_label": "RRSP", "account_type_guess": "rrsp",
            "taken_at_guess": "2026-11-01",
            "holdings": [{"label": "VFV", "asset_class_guess": "equity", "quantity": 10, "value": 1000.0, "currency_guess": "CAD", "country_guess": "CA"}],
        })}}]}
        return httpx.Response(200, json=body)
    client = httpx.Client(transport=httpx.MockTransport(handler))
    extractor = AzureOpenAIVisionExtractor(endpoint="https://x", api_key="k", deployment="d", client=client)
    result = extractor.extract(b"fake-bytes", "image/png")
    assert result.institution == "RBC"
    assert result.holdings[0].label == "VFV"

def test_azure_extractor_wraps_malformed_response_as_extraction_failed():
    def handler(request):
        return httpx.Response(200, json={"choices": [{"message": {"content": "not json"}}]})
    client = httpx.Client(transport=httpx.MockTransport(handler))
    extractor = AzureOpenAIVisionExtractor(endpoint="https://x", api_key="k", deployment="d", client=client)
    with pytest.raises(ExtractionFailed):
        extractor.extract(b"fake-bytes", "image/png")
```

```python
# additions to backend/tests/test_uploads.py
# (new imports needed: `from app.main import app`, `from app.services import vision`,
#  `from app.schemas.extraction import ExtractionResult, DraftHolding`, `from datetime import date`)

def test_extract_populates_payload_and_sets_status_extracted(client, auth_header_for):
    headers = auth_header_for("a@example.com")
    upload_id = client.post(
        "/uploads", files={"file": ("x.png", b"fake-png-bytes", "image/png")}, headers=headers
    ).json()["id"]

    fake_result = ExtractionResult(
        institution="RBC", account_label="RRSP", account_type_guess="rrsp",
        taken_at_guess=date(2026, 11, 1),
        holdings=[DraftHolding(label="VFV", asset_class_guess="equity", quantity=10, value=1000.0, currency_guess="CAD", country_guess="CA")],
    )
    app.dependency_overrides[vision.get_vision_extractor] = lambda: FakeVisionExtractor(result=fake_result)
    response = client.post(f"/uploads/{upload_id}/extract", headers=headers)
    del app.dependency_overrides[vision.get_vision_extractor]

    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "extracted"
    assert body["extracted_payload"]["institution"] == "RBC"
    assert body["extracted_payload"]["holdings"][0]["label"] == "VFV"

def test_extract_failure_sets_status_failed_not_500(client, auth_header_for):
    headers = auth_header_for("a@example.com")
    upload_id = client.post(
        "/uploads", files={"file": ("x.png", b"fake-png-bytes", "image/png")}, headers=headers
    ).json()["id"]

    app.dependency_overrides[vision.get_vision_extractor] = lambda: FakeVisionExtractor(error="Azure returned a non-JSON body")
    response = client.post(f"/uploads/{upload_id}/extract", headers=headers)
    del app.dependency_overrides[vision.get_vision_extractor]

    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "failed"
    assert body["extraction_error"]

def test_extract_for_other_users_upload_returns_404(client, auth_header_for):
    headers_a = auth_header_for("a@example.com")
    headers_b = auth_header_for("b@example.com")
    upload_id = client.post(
        "/uploads", files={"file": ("x.png", b"fake-png-bytes", "image/png")}, headers=headers_a
    ).json()["id"]
    response = client.post(f"/uploads/{upload_id}/extract", headers=headers_b)
    assert response.status_code == 404
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `pytest backend/tests/test_vision.py backend/tests/test_uploads.py -v`
Expected: FAIL

- [ ] **Step 3: Implement everything listed in Interfaces**

- [ ] **Step 4: Run tests to verify they pass**

Run: `pytest backend/tests -v`
Expected: PASS (full suite, to catch any regression from the `conftest.py` changes)

- [ ] **Step 5: Commit**

```bash
git add backend/app/schemas/extraction.py backend/app/services/vision.py backend/app/config.py backend/app/routers/uploads.py backend/tests/conftest.py backend/tests/test_vision.py backend/tests/test_uploads.py
git commit -m "feat: add vision extraction service and POST /uploads/{id}/extract"
```

---

### Task 3: Account matching + shared ownership helper + `GET /uploads`, `GET /uploads/{id}`

**Files:**
- Create: `backend/app/services/matching.py`
- Modify: `backend/app/routers/_ownership.py`
- Modify: `backend/app/routers/uploads.py`
- Test: `backend/tests/test_matching.py`, additions to `backend/tests/test_uploads.py`

**Interfaces:**
- Consumes: `Account` model, `Upload` model + status constants (Task 1),
  `get_current_user`.
- Produces:
  - `routers/_ownership.py`: `get_owned_upload_or_404(upload_id: int, current_user: User, db: Session) -> Upload`
    — exact same shape as `get_owned_account_or_404`/`get_owned_todo_or_404`
    already there. The extract handler added in Task 2 is updated in this
    task to use this helper instead of its inline Task-2-only query (replace
    the inline lookup from Task 2's Interfaces note).
  - `services/matching.py`: `MATCH_THRESHOLD = 0.6` (named constant — a
    `difflib.SequenceMatcher` ratio), `suggest_account(db: Session, user_id: int, institution: str | None, account_label: str | None) -> Account | None`
    — queries the user's `Account` rows, computes
    `SequenceMatcher(None, normalize(f"{institution} {account_label}"), normalize(f"{account.institution} {account.name}")).ratio()`
    for each (where `normalize` is `str.strip().lower()`), returns the
    highest-scoring account if its ratio ≥ `MATCH_THRESHOLD`, else `None`.
    Returns `None` immediately if the user has no accounts, or if both
    `institution` and `account_label` are `None`.
  - `routers/uploads.py`: the extract handler (from Task 2) is modified to
    call `suggest_account(db, current_user.id, result.institution, result.account_label)`
    after a successful extraction and set `upload.suggested_account_id = matched.id if matched else None`
    before committing. New routes: `GET /uploads` → list of the current
    user's uploads, newest first, each as `{"id", "status", "created_at"}`
    (summary only — not the full payload); `GET /uploads/{id}` → full detail:
    `{"id", "status", "mime_type", "extracted_payload", "extraction_error", "suggested_account_id", "matched_account_id", "snapshot_id", "created_at"}`.
    Both use `get_owned_upload_or_404`.

- [ ] **Step 1: Write the failing tests**

```python
# backend/tests/test_matching.py
# (imports: `from app.models import Account, User`, `from app.services.matching import suggest_account`)

def test_suggest_account_matches_similar_institution_name(db_session):
    user = User(google_sub="g-1", email="a@example.com")
    db_session.add(user)
    db_session.commit()
    account = Account(user_id=user.id, name="RRSP", institution="Royal Bank of Canada", account_type="rrsp")
    db_session.add(account)
    db_session.commit()

    matched = suggest_account(db_session, user.id, institution="RBC Royal Bank", account_label="RRSP")
    assert matched is not None
    assert matched.id == account.id

def test_suggest_account_returns_none_below_threshold(db_session):
    user = User(google_sub="g-2", email="b@example.com")
    db_session.add(user)
    db_session.commit()
    account = Account(user_id=user.id, name="Checking", institution="Totally Different Bank", account_type="cash")
    db_session.add(account)
    db_session.commit()

    assert suggest_account(db_session, user.id, institution="Unrelated Crypto Exchange", account_label="Wallet") is None

def test_suggest_account_with_no_accounts_returns_none(db_session):
    user = User(google_sub="g-3", email="c@example.com")
    db_session.add(user)
    db_session.commit()
    assert suggest_account(db_session, user.id, institution="RBC", account_label="RRSP") is None
```

```python
# additions to backend/tests/test_uploads.py
def test_extract_sets_suggested_account_when_similar_account_exists(client, auth_header_for):
    headers = auth_header_for("a@example.com")
    account_id = client.post(
        "/accounts", json={"name": "RRSP", "institution": "Royal Bank of Canada", "account_type": "rrsp"}, headers=headers
    ).json()["id"]
    upload_id = client.post(
        "/uploads", files={"file": ("x.png", b"fake-png-bytes", "image/png")}, headers=headers
    ).json()["id"]

    fake_result = ExtractionResult(institution="RBC Royal Bank", account_label="RRSP", account_type_guess="rrsp", taken_at_guess=None, holdings=[])
    app.dependency_overrides[vision.get_vision_extractor] = lambda: FakeVisionExtractor(result=fake_result)
    client.post(f"/uploads/{upload_id}/extract", headers=headers)
    del app.dependency_overrides[vision.get_vision_extractor]

    detail = client.get(f"/uploads/{upload_id}", headers=headers).json()
    assert detail["suggested_account_id"] == account_id

def test_list_uploads_scoped_to_user(client, auth_header_for):
    headers_a = auth_header_for("a@example.com")
    headers_b = auth_header_for("b@example.com")
    client.post("/uploads", files={"file": ("x.png", b"fake-png-bytes", "image/png")}, headers=headers_a)
    client.post("/uploads", files={"file": ("y.png", b"fake-png-bytes", "image/png")}, headers=headers_b)

    response = client.get("/uploads", headers=headers_a)
    assert response.status_code == 200
    assert len(response.json()) == 1

def test_get_upload_detail_for_other_user_returns_404(client, auth_header_for):
    headers_a = auth_header_for("a@example.com")
    headers_b = auth_header_for("b@example.com")
    upload_id = client.post(
        "/uploads", files={"file": ("x.png", b"fake-png-bytes", "image/png")}, headers=headers_a
    ).json()["id"]
    response = client.get(f"/uploads/{upload_id}", headers=headers_b)
    assert response.status_code == 404
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `pytest backend/tests/test_matching.py backend/tests/test_uploads.py -v`
Expected: FAIL

- [ ] **Step 3: Implement everything listed in Interfaces**

- [ ] **Step 4: Run tests to verify they pass**

Run: `pytest backend/tests -v`
Expected: PASS (full suite)

- [ ] **Step 5: Commit**

```bash
git add backend/app/services/matching.py backend/app/routers/_ownership.py backend/app/routers/uploads.py backend/tests/test_matching.py backend/tests/test_uploads.py
git commit -m "feat: add account matching and upload list/detail endpoints"
```

---

### Task 4: Confirm (`POST /uploads/{id}/confirm`) — commits via Plan 1's `create_snapshot`

**Files:**
- Create: `backend/app/schemas/upload_confirm.py`
- Modify: `backend/app/routers/uploads.py`
- Test: additions to `backend/tests/test_uploads.py`

**Interfaces:**
- Consumes: `HoldingIn`, `SnapshotIn` (`app/schemas/snapshot.py`),
  `create_snapshot` (`app/services/snapshots.py`), `fx.FXRateProvider`/`fx.get_fx_provider`
  (`app/services/fx.py`), `Account` model, `get_owned_account_or_404`
  (`app/routers/_ownership.py`), `get_owned_upload_or_404` (Task 3),
  `TERMINAL_STATUSES`/`STATUS_CONFIRMED` (Task 1).
- Produces:
  - `schemas/upload_confirm.py`: `NewAccountIn(name: str, institution: str, account_type: str)`
    (same shape as `AccountIn`, named separately since it's nested, not a
    top-level request body), `ConfirmUploadIn(account_id: int | None, new_account: NewAccountIn | None, taken_at: date, holdings: list[HoldingIn])`.
  - `routers/uploads.py`: `POST /uploads/{id}/confirm` → 404 if the upload
    isn't the current user's; 409 if `upload.status in TERMINAL_STATUSES`;
    422 if neither or both of `account_id`/`new_account` are provided; if
    `account_id` given, resolves it via `get_owned_account_or_404` (404 if it
    doesn't belong to the current user); if `new_account` given, creates the
    `Account` row first. Builds `SnapshotIn(taken_at=payload.taken_at, holdings=payload.holdings)`
    and calls `create_snapshot(db, account, snapshot_in, fx_provider)`
    unmodified. On success: sets `upload.status = STATUS_CONFIRMED`,
    `upload.matched_account_id = account.id`, `upload.snapshot_id = snapshot.id`,
    commits, and returns the created snapshot — same `SnapshotOut` shape
    Plan 1's `POST /accounts/{account_id}/snapshots` returns (status 201).

- [ ] **Step 1: Write the failing tests**

```python
# additions to backend/tests/test_uploads.py
def test_confirm_with_existing_account_creates_snapshot_and_marks_confirmed(client, auth_header_for):
    headers = auth_header_for("a@example.com")
    account_id = client.post(
        "/accounts", json={"name": "RRSP", "institution": "RBC", "account_type": "rrsp"}, headers=headers
    ).json()["id"]
    upload_id = client.post(
        "/uploads", files={"file": ("x.png", b"fake-png-bytes", "image/png")}, headers=headers
    ).json()["id"]

    response = client.post(
        f"/uploads/{upload_id}/confirm",
        json={
            "account_id": account_id,
            "new_account": None,
            "taken_at": "2026-11-08",
            "holdings": [{"label": "VFV", "asset_class": "equity", "quantity": 10, "value": 1000.0, "currency": "CAD", "country": "CA"}],
        },
        headers=headers,
    )
    assert response.status_code == 201
    assert response.json()["holdings"][0]["label"] == "VFV"

    detail = client.get(f"/uploads/{upload_id}", headers=headers).json()
    assert detail["status"] == "confirmed"
    assert detail["matched_account_id"] == account_id
    assert detail["snapshot_id"] is not None

def test_confirm_with_new_account_creates_account_and_snapshot(client, auth_header_for):
    headers = auth_header_for("a@example.com")
    upload_id = client.post(
        "/uploads", files={"file": ("x.png", b"fake-png-bytes", "image/png")}, headers=headers
    ).json()["id"]

    response = client.post(
        f"/uploads/{upload_id}/confirm",
        json={
            "account_id": None,
            "new_account": {"name": "New RRSP", "institution": "RBC", "account_type": "rrsp"},
            "taken_at": "2026-11-08",
            "holdings": [{"label": "VFV", "asset_class": "equity", "quantity": 10, "value": 1000.0, "currency": "CAD", "country": "CA"}],
        },
        headers=headers,
    )
    assert response.status_code == 201
    accounts = client.get("/accounts", headers=headers).json()
    assert any(a["name"] == "New RRSP" for a in accounts)

def test_confirm_rejects_both_account_id_and_new_account_given(client, auth_header_for):
    headers = auth_header_for("a@example.com")
    account_id = client.post(
        "/accounts", json={"name": "RRSP", "institution": "RBC", "account_type": "rrsp"}, headers=headers
    ).json()["id"]
    upload_id = client.post(
        "/uploads", files={"file": ("x.png", b"fake-png-bytes", "image/png")}, headers=headers
    ).json()["id"]
    response = client.post(
        f"/uploads/{upload_id}/confirm",
        json={
            "account_id": account_id,
            "new_account": {"name": "New RRSP", "institution": "RBC", "account_type": "rrsp"},
            "taken_at": "2026-11-08",
            "holdings": [],
        },
        headers=headers,
    )
    assert response.status_code == 422

def test_confirm_rejects_neither_account_id_nor_new_account_given(client, auth_header_for):
    headers = auth_header_for("a@example.com")
    upload_id = client.post(
        "/uploads", files={"file": ("x.png", b"fake-png-bytes", "image/png")}, headers=headers
    ).json()["id"]
    response = client.post(
        f"/uploads/{upload_id}/confirm",
        json={"account_id": None, "new_account": None, "taken_at": "2026-11-08", "holdings": []},
        headers=headers,
    )
    assert response.status_code == 422

def test_confirm_reuses_plan1_holding_validation(client, auth_header_for):
    headers = auth_header_for("a@example.com")
    account_id = client.post(
        "/accounts", json={"name": "RRSP", "institution": "RBC", "account_type": "rrsp"}, headers=headers
    ).json()["id"]
    upload_id = client.post(
        "/uploads", files={"file": ("x.png", b"fake-png-bytes", "image/png")}, headers=headers
    ).json()["id"]
    # Negative value is exactly what Plan 1's own HoldingIn.value rejects
    # (Field(ge=0, ...)) — this proves confirm routes through that same
    # validation rather than a looser, extraction-specific path.
    response = client.post(
        f"/uploads/{upload_id}/confirm",
        json={
            "account_id": account_id,
            "new_account": None,
            "taken_at": "2026-11-08",
            "holdings": [{"label": "VFV", "asset_class": "equity", "quantity": 10, "value": -5.0, "currency": "CAD", "country": "CA"}],
        },
        headers=headers,
    )
    assert response.status_code == 422

def test_confirm_twice_returns_409(client, auth_header_for):
    headers = auth_header_for("a@example.com")
    account_id = client.post(
        "/accounts", json={"name": "RRSP", "institution": "RBC", "account_type": "rrsp"}, headers=headers
    ).json()["id"]
    upload_id = client.post(
        "/uploads", files={"file": ("x.png", b"fake-png-bytes", "image/png")}, headers=headers
    ).json()["id"]
    payload = {
        "account_id": account_id, "new_account": None, "taken_at": "2026-11-08",
        "holdings": [{"label": "VFV", "asset_class": "equity", "quantity": 10, "value": 1000.0, "currency": "CAD", "country": "CA"}],
    }
    client.post(f"/uploads/{upload_id}/confirm", json=payload, headers=headers)
    response = client.post(f"/uploads/{upload_id}/confirm", json=payload, headers=headers)
    assert response.status_code == 409

def test_confirm_for_other_users_upload_returns_404(client, auth_header_for):
    headers_a = auth_header_for("a@example.com")
    headers_b = auth_header_for("b@example.com")
    upload_id = client.post(
        "/uploads", files={"file": ("x.png", b"fake-png-bytes", "image/png")}, headers=headers_a
    ).json()["id"]
    response = client.post(
        f"/uploads/{upload_id}/confirm",
        json={"account_id": None, "new_account": {"name": "N", "institution": "N", "account_type": "cash"}, "taken_at": "2026-11-08", "holdings": []},
        headers=headers_b,
    )
    assert response.status_code == 404

def test_extract_on_confirmed_upload_returns_409(client, auth_header_for):
    # Completes the state-machine coverage left open in Task 2 — only
    # buildable now that confirm exists.
    headers = auth_header_for("a@example.com")
    account_id = client.post(
        "/accounts", json={"name": "RRSP", "institution": "RBC", "account_type": "rrsp"}, headers=headers
    ).json()["id"]
    upload_id = client.post(
        "/uploads", files={"file": ("x.png", b"fake-png-bytes", "image/png")}, headers=headers
    ).json()["id"]
    client.post(
        f"/uploads/{upload_id}/confirm",
        json={
            "account_id": account_id, "new_account": None, "taken_at": "2026-11-08",
            "holdings": [{"label": "VFV", "asset_class": "equity", "quantity": 10, "value": 1000.0, "currency": "CAD", "country": "CA"}],
        },
        headers=headers,
    )
    response = client.post(f"/uploads/{upload_id}/extract", headers=headers)
    assert response.status_code == 409
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `pytest backend/tests/test_uploads.py -v`
Expected: FAIL

- [ ] **Step 3: Implement everything listed in Interfaces**

- [ ] **Step 4: Run tests to verify they pass**

Run: `pytest backend/tests -v`
Expected: PASS (full suite)

- [ ] **Step 5: Commit**

```bash
git add backend/app/schemas/upload_confirm.py backend/app/routers/uploads.py backend/tests/test_uploads.py
git commit -m "feat: add upload confirm endpoint, reusing Plan 1 snapshot validation"
```

---

### Task 5: Discard (`POST /uploads/{id}/discard`) + file cleanup

**Files:**
- Modify: `backend/app/routers/uploads.py`
- Test: additions to `backend/tests/test_uploads.py`

**Interfaces:**
- Consumes: `get_owned_upload_or_404`, `TERMINAL_STATUSES`/`STATUS_DISCARDED`
  (earlier tasks), `image_storage.delete_upload_image`/`get_upload_base_dir`
  (Task 1).
- Produces: `POST /uploads/{id}/discard` → 404 if not owned; 409 if
  `upload.status in TERMINAL_STATUSES`; otherwise deletes the stored image
  file via `delete_upload_image(base_dir, upload.image_path)`, sets
  `upload.status = STATUS_DISCARDED`, commits, returns 204.

- [ ] **Step 1: Write the failing tests**

```python
# additions to backend/tests/test_uploads.py
# (new import: `from pathlib import Path`)

def test_discard_deletes_file_and_marks_discarded(client, auth_header_for, upload_base_dir):
    headers = auth_header_for("a@example.com")
    upload_id = client.post(
        "/uploads", files={"file": ("x.png", b"fake-png-bytes", "image/png")}, headers=headers
    ).json()["id"]
    assert len(list(Path(upload_base_dir).rglob("*.png"))) == 1

    response = client.post(f"/uploads/{upload_id}/discard", headers=headers)
    assert response.status_code == 204
    assert client.get(f"/uploads/{upload_id}", headers=headers).json()["status"] == "discarded"
    assert list(Path(upload_base_dir).rglob("*.png")) == []

def test_discard_already_confirmed_returns_409(client, auth_header_for):
    headers = auth_header_for("a@example.com")
    account_id = client.post(
        "/accounts", json={"name": "RRSP", "institution": "RBC", "account_type": "rrsp"}, headers=headers
    ).json()["id"]
    upload_id = client.post(
        "/uploads", files={"file": ("x.png", b"fake-png-bytes", "image/png")}, headers=headers
    ).json()["id"]
    client.post(
        f"/uploads/{upload_id}/confirm",
        json={
            "account_id": account_id, "new_account": None, "taken_at": "2026-11-08",
            "holdings": [{"label": "VFV", "asset_class": "equity", "quantity": 10, "value": 1000.0, "currency": "CAD", "country": "CA"}],
        },
        headers=headers,
    )
    response = client.post(f"/uploads/{upload_id}/discard", headers=headers)
    assert response.status_code == 409

def test_extract_on_discarded_upload_returns_409(client, auth_header_for):
    # Completes the state-machine coverage from Task 2/4.
    headers = auth_header_for("a@example.com")
    upload_id = client.post(
        "/uploads", files={"file": ("x.png", b"fake-png-bytes", "image/png")}, headers=headers
    ).json()["id"]
    client.post(f"/uploads/{upload_id}/discard", headers=headers)
    response = client.post(f"/uploads/{upload_id}/extract", headers=headers)
    assert response.status_code == 409

def test_confirm_on_discarded_upload_returns_409(client, auth_header_for):
    # Completes the "already in a terminal state" Review Focus item for
    # confirm specifically (Task 4 only covered confirm-after-confirm).
    headers = auth_header_for("a@example.com")
    account_id = client.post(
        "/accounts", json={"name": "RRSP", "institution": "RBC", "account_type": "rrsp"}, headers=headers
    ).json()["id"]
    upload_id = client.post(
        "/uploads", files={"file": ("x.png", b"fake-png-bytes", "image/png")}, headers=headers
    ).json()["id"]
    client.post(f"/uploads/{upload_id}/discard", headers=headers)
    response = client.post(
        f"/uploads/{upload_id}/confirm",
        json={
            "account_id": account_id, "new_account": None, "taken_at": "2026-11-08",
            "holdings": [{"label": "VFV", "asset_class": "equity", "quantity": 10, "value": 1000.0, "currency": "CAD", "country": "CA"}],
        },
        headers=headers,
    )
    assert response.status_code == 409

def test_discard_for_other_users_upload_returns_404(client, auth_header_for):
    headers_a = auth_header_for("a@example.com")
    headers_b = auth_header_for("b@example.com")
    upload_id = client.post(
        "/uploads", files={"file": ("x.png", b"fake-png-bytes", "image/png")}, headers=headers_a
    ).json()["id"]
    response = client.post(f"/uploads/{upload_id}/discard", headers=headers_b)
    assert response.status_code == 404
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `pytest backend/tests/test_uploads.py -v`
Expected: FAIL

- [ ] **Step 3: Implement the discard route per Interfaces**

- [ ] **Step 4: Run tests to verify they pass**

Run: `pytest backend/tests -v`
Expected: PASS (full suite)

- [ ] **Step 5: Commit**

```bash
git add backend/app/routers/uploads.py backend/tests/test_uploads.py
git commit -m "feat: add upload discard endpoint with file cleanup"
```

---

### Task 6: Full-suite run

**Files:** none (verification only)

**Interfaces:** none

- [ ] **Step 1: Run the entire backend test suite**

Run: `pytest backend/tests -v`
Expected: PASS — all tests from Tasks 1-5 green together, including the full
Upload state machine (`pending → extracted → confirmed`, `→ failed`,
`→ discarded`, and every terminal-state 409 case) and the reused Plan 1
holding validation.

- [ ] **Step 2: Commit (only if Step 1 required fixes)**

```bash
git add -A
git commit -m "fix: resolve cross-task regressions from full suite run"
```
