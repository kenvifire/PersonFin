"""`POST /uploads`: accepts a multipart screenshot upload, creates a
`pending` `Upload` row, and stores the file under the test-isolated
`upload_base_dir`.
"""

from app.models import Upload
from app.services import image_storage


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
