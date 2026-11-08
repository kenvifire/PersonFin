"""Pure validation and local-disk I/O for uploaded screenshots.

No network/cloud calls here at all — these tests only touch `tmp_path`.
"""

import pytest

from app.services.image_storage import (
    MAX_UPLOAD_BYTES,
    UnsupportedUploadError,
    delete_upload_image,
    save_upload_image,
    validate_upload,
)


def test_validate_upload_rejects_unsupported_mime_type():
    with pytest.raises(UnsupportedUploadError):
        validate_upload("text/plain", b"not an image")


def test_validate_upload_rejects_oversized_file():
    with pytest.raises(UnsupportedUploadError):
        validate_upload("image/png", b"x" * (MAX_UPLOAD_BYTES + 1))


def test_validate_upload_accepts_supported_mime_type_within_size_limit():
    validate_upload("image/png", b"small file")
    validate_upload("image/jpeg", b"small file")
    validate_upload("image/webp", b"small file")


def test_save_and_delete_upload_image_roundtrip(tmp_path):
    base_dir = str(tmp_path)
    relative_path = save_upload_image(
        base_dir, user_id=1, upload_id=42, mime_type="image/png", content=b"fake-png-bytes"
    )

    full_path = tmp_path / relative_path
    assert full_path.exists()
    assert full_path.read_bytes() == b"fake-png-bytes"

    delete_upload_image(base_dir, relative_path)
    assert not full_path.exists()

    delete_upload_image(base_dir, relative_path)  # already gone — no error


def test_save_upload_image_uses_extension_matching_mime_type(tmp_path):
    base_dir = str(tmp_path)
    png_path = save_upload_image(base_dir, user_id=1, upload_id=1, mime_type="image/png", content=b"x")
    jpeg_path = save_upload_image(base_dir, user_id=1, upload_id=2, mime_type="image/jpeg", content=b"x")
    webp_path = save_upload_image(base_dir, user_id=1, upload_id=3, mime_type="image/webp", content=b"x")

    assert png_path.endswith(".png")
    assert jpeg_path.endswith(".jpg")
    assert webp_path.endswith(".webp")


def test_save_upload_image_scopes_path_by_user(tmp_path):
    base_dir = str(tmp_path)
    relative_path = save_upload_image(
        base_dir, user_id=7, upload_id=42, mime_type="image/png", content=b"x"
    )
    assert relative_path.startswith("7")
