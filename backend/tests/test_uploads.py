"""`POST /uploads`: accepts a multipart screenshot upload, creates a
`pending` `Upload` row, and stores the file under the test-isolated
`upload_base_dir`.

`POST /uploads/{id}/extract`: runs vision extraction against the stored
image and records the outcome (success or failure) as upload status.
"""

from datetime import date
from pathlib import Path

from app.main import app
from app.models import Account, Snapshot, Upload
from app.routers.uploads import claim_upload_for_confirmation
from app.schemas.extraction import DraftHolding, ExtractionResult
from app.services import image_storage, vision
from conftest import FakeVisionExtractor


def test_upload_rejects_unsupported_mime_type(client, auth_header_for):
    headers = auth_header_for("a@example.com")
    response = client.post("/uploads", files={"file": ("x.txt", b"hello", "text/plain")}, headers=headers)
    assert response.status_code == 422


def test_upload_rejects_oversized_file(client, auth_header_for):
    headers = auth_header_for("a@example.com")
    big = b"x" * (image_storage.MAX_UPLOAD_BYTES + 1)
    response = client.post("/uploads", files={"file": ("x.png", big, "image/png")}, headers=headers)
    assert response.status_code == 422


def test_upload_rejects_without_writing_to_disk(client, auth_header_for, upload_base_dir):
    import os

    headers = auth_header_for("a@example.com")
    client.post("/uploads", files={"file": ("x.txt", b"hello", "text/plain")}, headers=headers)

    # Nothing should have been written anywhere under the isolated base dir.
    written_files = []
    for root, _dirs, files in os.walk(upload_base_dir):
        written_files.extend(files)
    assert written_files == []


def test_upload_requires_authentication(client):
    response = client.post("/uploads", files={"file": ("x.png", b"fake-png-bytes", "image/png")})
    assert response.status_code == 401


def test_upload_creates_pending_record_and_stores_file(client, auth_header_for, upload_base_dir, db_session):
    headers = auth_header_for("a@example.com")
    response = client.post("/uploads", files={"file": ("x.png", b"fake-png-bytes", "image/png")}, headers=headers)

    assert response.status_code == 201
    body = response.json()
    assert body["status"] == "pending"
    assert isinstance(body["id"], int)

    upload = db_session.get(Upload, body["id"])
    assert upload is not None
    assert upload.status == "pending"
    assert upload.mime_type == "image/png"
    assert upload.image_path is not None

    from pathlib import Path

    stored_file = Path(upload_base_dir) / upload.image_path
    assert stored_file.exists()
    assert stored_file.read_bytes() == b"fake-png-bytes"


def test_upload_scopes_file_to_authenticated_user(client, auth_header_for, db_session):
    headers = auth_header_for("owner@example.com")
    response = client.post("/uploads", files={"file": ("x.png", b"fake-png-bytes", "image/png")}, headers=headers)
    upload = db_session.get(Upload, response.json()["id"])

    from app.models import User

    owner = db_session.query(User).filter(User.email == "owner@example.com").one()
    assert upload.user_id == owner.id


def test_extract_populates_payload_and_sets_status_extracted(client, auth_header_for):
    headers = auth_header_for("a@example.com")
    upload_id = client.post(
        "/uploads", files={"file": ("x.png", b"fake-png-bytes", "image/png")}, headers=headers
    ).json()["id"]

    fake_result = ExtractionResult(
        institution="RBC",
        account_label="RRSP",
        account_type_guess="rrsp",
        taken_at_guess=date(2026, 11, 1),
        holdings=[
            DraftHolding(
                label="VFV",
                asset_class_guess="equity",
                quantity=10,
                value=1000.0,
                currency_guess="CAD",
                country_guess="CA",
            )
        ],
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

    app.dependency_overrides[vision.get_vision_extractor] = lambda: FakeVisionExtractor(
        error="Azure returned a non-JSON body"
    )
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


def test_extract_on_terminal_upload_returns_409(client, auth_header_for, db_session):
    headers = auth_header_for("a@example.com")
    upload_id = client.post(
        "/uploads", files={"file": ("x.png", b"fake-png-bytes", "image/png")}, headers=headers
    ).json()["id"]

    upload = db_session.get(Upload, upload_id)
    upload.status = "confirmed"
    db_session.commit()

    response = client.post(f"/uploads/{upload_id}/extract", headers=headers)
    assert response.status_code == 409


def test_extract_with_missing_image_path_sets_status_failed_not_500(client, auth_header_for, db_session):
    """An upload can be left `pending` with `image_path = None` if the
    original file write failed (see `Upload`'s docstring). `pending`
    isn't terminal, so the 409 guard doesn't block calling extract on
    it — the missing-file case must be handled like any other
    extraction failure, not crash with a 500."""
    headers = auth_header_for("a@example.com")
    upload_id = client.post(
        "/uploads", files={"file": ("x.png", b"fake-png-bytes", "image/png")}, headers=headers
    ).json()["id"]

    upload = db_session.get(Upload, upload_id)
    upload.image_path = None
    upload.status = "pending"
    db_session.commit()

    response = client.post(f"/uploads/{upload_id}/extract", headers=headers)

    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "failed"
    assert body["extraction_error"]


def test_extract_requires_authentication(client, auth_header_for):
    headers = auth_header_for("a@example.com")
    upload_id = client.post(
        "/uploads", files={"file": ("x.png", b"fake-png-bytes", "image/png")}, headers=headers
    ).json()["id"]
    response = client.post(f"/uploads/{upload_id}/extract")
    assert response.status_code == 401


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


def test_confirm_twice_returns_409(client, auth_header_for, db_session):
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

    # The real risk of a confirm-twice race isn't the HTTP status of the
    # losing call — it's a second, permanent Snapshot silently existing
    # for the same screenshot. Check the database directly, not just
    # the HTTP-layer symptom.
    assert db_session.query(Snapshot).filter(Snapshot.account_id == account_id).count() == 1


def test_confirm_atomic_claim_rejects_a_second_simultaneous_claim(client, auth_header_for, db_session):
    """Real concurrent HTTP requests are awkward to simulate reliably in
    a synchronous TestClient, so this exercises the atomic-claim step
    directly, simulating two racers calling it back-to-back for the same
    upload. The first call must claim it (rowcount 1); the second must
    NOT be able to re-claim an upload already moved to
    `STATUS_CONFIRMING` (rowcount 0) — this is exactly what closes the
    check-then-act race that could otherwise let both racers proceed to
    call `create_snapshot` and each create a real Snapshot."""
    headers = auth_header_for("a@example.com")
    upload_id = client.post(
        "/uploads", files={"file": ("x.png", b"fake-png-bytes", "image/png")}, headers=headers
    ).json()["id"]

    first_claim = claim_upload_for_confirmation(db_session, upload_id)
    second_claim = claim_upload_for_confirmation(db_session, upload_id)

    assert first_claim == 1
    assert second_claim == 0


def test_confirm_creates_exactly_one_snapshot_for_the_account(client, auth_header_for, db_session):
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
    assert db_session.query(Snapshot).filter(Snapshot.account_id == account_id).count() == 1


def test_confirm_with_new_account_does_not_orphan_account_when_create_snapshot_fails(
    client, auth_header_for, use_fx_provider, db_session
):
    """If `create_snapshot` fails after a brand-new `Account` was
    created for this confirm, the account must not be left behind as an
    orphaned, snapshot-less row — otherwise a retry with the same
    `new_account` payload would create a duplicate account every time."""
    from conftest import FailingFXRateProvider

    headers = auth_header_for("a@example.com")
    upload_id = client.post(
        "/uploads", files={"file": ("x.png", b"fake-png-bytes", "image/png")}, headers=headers
    ).json()["id"]
    use_fx_provider(FailingFXRateProvider())

    response = client.post(
        f"/uploads/{upload_id}/confirm",
        json={
            "account_id": None,
            "new_account": {"name": "Orphan RRSP", "institution": "RBC", "account_type": "rrsp"},
            "taken_at": "2026-11-08",
            # CAD requires an FX lookup, which FailingFXRateProvider always fails.
            "holdings": [{"label": "VFV", "asset_class": "equity", "quantity": 10, "value": 1000.0, "currency": "CAD", "country": "CA"}],
        },
        headers=headers,
    )

    assert response.status_code == 503
    assert db_session.query(Account).filter(Account.name == "Orphan RRSP").count() == 0

    # The upload must also not be stuck at the transitional status —
    # it should have been reverted so a retry remains possible.
    detail = client.get(f"/uploads/{upload_id}", headers=headers).json()
    assert detail["status"] != "confirming"


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


def test_discard_during_in_flight_confirm_returns_409_and_keeps_file(
    client, auth_header_for, upload_base_dir, db_session
):
    """Regression for the discard-vs-confirm interleaving: a confirm
    that has already claimed the upload (moved it to the transitional
    `STATUS_CONFIRMING`, not yet committed `STATUS_CONFIRMED`) must not
    lose the image to a discard that lands in that window. Simulated
    directly by setting the upload to `STATUS_CONFIRMING` via
    `db_session` — standing in for "a confirm request has already run
    `claim_upload_for_confirmation` for this upload and is still doing
    its real work" — rather than racing real concurrent HTTP requests.
    """
    headers = auth_header_for("a@example.com")
    upload_id = client.post(
        "/uploads", files={"file": ("x.png", b"fake-png-bytes", "image/png")}, headers=headers
    ).json()["id"]
    assert len(list(Path(upload_base_dir).rglob("*.png"))) == 1

    upload = db_session.get(Upload, upload_id)
    upload.status = "confirming"
    db_session.commit()

    response = client.post(f"/uploads/{upload_id}/discard", headers=headers)
    assert response.status_code == 409

    # The file must survive: a discard that loses the race must never
    # have called delete_upload_image.
    assert len(list(Path(upload_base_dir).rglob("*.png"))) == 1


class _RacingVisionExtractor:
    """A `VisionExtractor` that, while "Azure is running", simulates a
    concurrent request moving the upload to `racing_status` — committed
    through the same `db_session` the handler uses — and then returns a
    real extraction result. By the time `extract_upload` tries to write
    that result, the row's status has already changed underneath it,
    reproducing the extract-vs-confirm / extract-vs-discard interleavings
    deterministically, without real threads."""

    def __init__(self, db_session, upload_id: int, racing_status: str, result: ExtractionResult):
        self.db_session = db_session
        self.upload_id = upload_id
        self.racing_status = racing_status
        self.result = result

    def extract(self, image_bytes: bytes, mime_type: str) -> ExtractionResult:
        from sqlalchemy import update

        self.db_session.execute(
            update(Upload).where(Upload.id == self.upload_id).values(status=self.racing_status)
        )
        self.db_session.commit()
        return self.result


_RACE_RESULT = ExtractionResult(
    institution="RBC",
    account_label="RRSP",
    account_type_guess="rrsp",
    taken_at_guess=date(2026, 11, 1),
    holdings=[
        DraftHolding(label="VFV", asset_class_guess="equity", quantity=10, value=1000.0, currency_guess="CAD", country_guess="CA")
    ],
)

_CONFIRM_PAYLOAD_HOLDINGS = [
    {"label": "VFV", "asset_class": "equity", "quantity": 10, "value": 1000.0, "currency": "CAD", "country": "CA"}
]


def test_extract_on_confirming_upload_returns_409(client, auth_header_for, db_session):
    """`STATUS_CONFIRMING` isn't terminal, but an upload a confirm has
    already claimed must not be extracted against: extract's entry check
    uses the `CLAIMABLE_STATUSES` allow-list, not "not terminal"."""
    headers = auth_header_for("a@example.com")
    upload_id = client.post(
        "/uploads", files={"file": ("x.png", b"fake-png-bytes", "image/png")}, headers=headers
    ).json()["id"]

    upload = db_session.get(Upload, upload_id)
    upload.status = "confirming"
    db_session.commit()

    response = client.post(f"/uploads/{upload_id}/extract", headers=headers)
    assert response.status_code == 409
    db_session.refresh(upload)
    assert upload.status == "confirming"
    assert upload.extracted_payload is None


def test_extract_vs_confirm_race_does_not_create_duplicate_snapshot(client, auth_header_for, db_session):
    """Regression for the extract-vs-confirm interleaving: extract passes
    its entry check, then (while Azure is "running") a confirm claims the
    upload (-> `STATUS_CONFIRMING`). Extract's write of its result must
    lose (409) rather than overwrite the status back to `extracted` —
    which would let a second confirm re-claim the upload and create a
    second permanent Snapshot."""
    headers = auth_header_for("a@example.com")
    account_id = client.post(
        "/accounts", json={"name": "RRSP", "institution": "RBC", "account_type": "rrsp"}, headers=headers
    ).json()["id"]
    upload_id = client.post(
        "/uploads", files={"file": ("x.png", b"fake-png-bytes", "image/png")}, headers=headers
    ).json()["id"]

    app.dependency_overrides[vision.get_vision_extractor] = lambda: _RacingVisionExtractor(
        db_session, upload_id, "confirming", _RACE_RESULT
    )
    response = client.post(f"/uploads/{upload_id}/extract", headers=headers)
    del app.dependency_overrides[vision.get_vision_extractor]

    assert response.status_code == 409
    upload = db_session.get(Upload, upload_id)
    db_session.refresh(upload)
    assert upload.status == "confirming"
    assert upload.extracted_payload is None
    assert upload.suggested_account_id is None

    # The simulated in-flight confirm owns the claim; a second confirm
    # arriving now must be rejected, not allowed to re-claim.
    payload = {"account_id": account_id, "new_account": None, "taken_at": "2026-11-08", "holdings": _CONFIRM_PAYLOAD_HOLDINGS}
    assert client.post(f"/uploads/{upload_id}/confirm", json=payload, headers=headers).status_code == 409

    # Release the simulated claim (as the in-flight confirm's revert
    # would on failure) and confirm legitimately: exactly one Snapshot.
    upload.status = "pending"
    db_session.commit()
    response = client.post(f"/uploads/{upload_id}/confirm", json=payload, headers=headers)
    assert response.status_code == 201
    assert client.post(f"/uploads/{upload_id}/confirm", json=payload, headers=headers).status_code == 409
    assert db_session.query(Snapshot).filter(Snapshot.account_id == account_id).count() == 1
    db_session.refresh(upload)
    assert upload.status == "confirmed"


def test_extract_vs_discard_race_does_not_resurrect_discarded_upload(
    client, auth_header_for, db_session, upload_base_dir
):
    """Regression for the extract-vs-discard interleaving: extract passes
    its entry check, then (while Azure is "running") a discard claims the
    upload, deletes the image, and commits `STATUS_DISCARDED`. Extract's
    write must lose (409) rather than resurrect the upload to
    `extracted` — which would let a later confirm succeed on an upload
    whose image is already gone."""
    headers = auth_header_for("a@example.com")
    account_id = client.post(
        "/accounts", json={"name": "RRSP", "institution": "RBC", "account_type": "rrsp"}, headers=headers
    ).json()["id"]
    upload_id = client.post(
        "/uploads", files={"file": ("x.png", b"fake-png-bytes", "image/png")}, headers=headers
    ).json()["id"]
    upload = db_session.get(Upload, upload_id)
    image_file = Path(upload_base_dir) / upload.image_path

    class _DiscardingExtractor(_RacingVisionExtractor):
        def extract(self, image_bytes: bytes, mime_type: str) -> ExtractionResult:
            image_file.unlink()  # discard deletes the image, then commits STATUS_DISCARDED
            return super().extract(image_bytes, mime_type)

    app.dependency_overrides[vision.get_vision_extractor] = lambda: _DiscardingExtractor(
        db_session, upload_id, "discarded", _RACE_RESULT
    )
    response = client.post(f"/uploads/{upload_id}/extract", headers=headers)
    del app.dependency_overrides[vision.get_vision_extractor]

    assert response.status_code == 409
    db_session.refresh(upload)
    assert upload.status == "discarded"
    assert upload.extracted_payload is None

    # And the follow-on harm from the original bug: confirm must not be
    # able to commit an upload whose image was deleted.
    payload = {"account_id": account_id, "new_account": None, "taken_at": "2026-11-08", "holdings": _CONFIRM_PAYLOAD_HOLDINGS}
    assert client.post(f"/uploads/{upload_id}/confirm", json=payload, headers=headers).status_code == 409
    db_session.refresh(upload)
    assert upload.status == "discarded"
    assert db_session.query(Snapshot).count() == 0


def test_extract_failure_result_also_loses_race_to_concurrent_discard(client, auth_header_for, db_session):
    """The failure branch (`STATUS_FAILED` + `extraction_error`) goes
    through the same conditional write as the success branch: a failed
    extraction finishing after a discard must not overwrite `discarded`."""
    from app.services.vision import ExtractionFailed

    headers = auth_header_for("a@example.com")
    upload_id = client.post(
        "/uploads", files={"file": ("x.png", b"fake-png-bytes", "image/png")}, headers=headers
    ).json()["id"]

    class _DiscardThenFail(_RacingVisionExtractor):
        def extract(self, image_bytes: bytes, mime_type: str) -> ExtractionResult:
            super().extract(image_bytes, mime_type)
            raise ExtractionFailed("Azure timed out")

    app.dependency_overrides[vision.get_vision_extractor] = lambda: _DiscardThenFail(
        db_session, upload_id, "discarded", _RACE_RESULT
    )
    response = client.post(f"/uploads/{upload_id}/extract", headers=headers)
    del app.dependency_overrides[vision.get_vision_extractor]

    assert response.status_code == 409
    upload = db_session.get(Upload, upload_id)
    db_session.refresh(upload)
    assert upload.status == "discarded"
    assert upload.extraction_error is None


def test_confirm_revert_on_failure_only_undoes_its_own_claim(client, auth_header_for, db_session, monkeypatch):
    """Confirm's revert-on-failure must only ever undo its own
    `STATUS_CONFIRMING` claim. If the row has somehow already moved on
    (simulated here by `create_snapshot` itself moving it to
    `discarded` before failing), the revert must leave it alone."""
    from sqlalchemy import update

    import app.routers.uploads as uploads_router

    headers = auth_header_for("a@example.com")
    account_id = client.post(
        "/accounts", json={"name": "RRSP", "institution": "RBC", "account_type": "rrsp"}, headers=headers
    ).json()["id"]
    upload_id = client.post(
        "/uploads", files={"file": ("x.png", b"fake-png-bytes", "image/png")}, headers=headers
    ).json()["id"]

    def _create_snapshot_that_races_then_fails(db, account, snapshot_in, fx_provider):
        db.execute(update(Upload).where(Upload.id == upload_id).values(status="discarded"))
        db.commit()
        raise RuntimeError("boom")

    monkeypatch.setattr(uploads_router, "create_snapshot", _create_snapshot_that_races_then_fails)

    payload = {"account_id": account_id, "new_account": None, "taken_at": "2026-11-08", "holdings": _CONFIRM_PAYLOAD_HOLDINGS}
    try:
        client.post(f"/uploads/{upload_id}/confirm", json=payload, headers=headers)
    except RuntimeError:
        pass  # TestClient re-raises unhandled server exceptions; the revert has already run.

    upload = db_session.get(Upload, upload_id)
    db_session.refresh(upload)
    assert upload.status == "discarded"


def test_upload_disk_write_failure_returns_clean_503_and_marks_failed(client, auth_header_for, db_session, monkeypatch):
    """If saving the file fails after the `Upload` row already exists
    (disk full, permissions), the client gets a deliberate 503 with a
    JSON `detail`, and the row is marked `failed` with a readable
    `extraction_error` — never an unhandled 500."""
    import app.routers.uploads as uploads_router

    def _raise_oserror(*args, **kwargs):
        raise OSError(28, "No space left on device")

    monkeypatch.setattr(uploads_router, "save_upload_image", _raise_oserror)
    headers = auth_header_for("a@example.com")
    response = client.post("/uploads", files={"file": ("x.png", b"fake-png-bytes", "image/png")}, headers=headers)

    assert response.status_code == 503
    assert response.headers["content-type"] == "application/json"
    assert response.json()["detail"] == "Could not store the uploaded image; please try again"

    uploads = db_session.query(Upload).all()
    assert len(uploads) == 1
    assert uploads[0].status == "failed"
    assert uploads[0].image_path is None
    assert uploads[0].extraction_error == "Uploaded image could not be saved to storage"
