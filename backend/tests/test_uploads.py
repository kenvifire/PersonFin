"""`POST /uploads`: accepts a multipart screenshot upload, creates a
`pending` `Upload` row, and stores the file under the test-isolated
`upload_base_dir`.

`POST /uploads/{id}/extract`: runs vision extraction against the stored
image and records the outcome (success or failure) as upload status.
"""

from datetime import date

from app.main import app
from app.models import Upload
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
