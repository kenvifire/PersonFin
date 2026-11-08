"""Local-disk storage for uploaded screenshots.

Deliberately local-disk only — no S3/GCS/cloud storage of any kind. Per
this project's privacy requirement, a user's screenshots never leave
the server except for the one vision-extraction API call (a later
task), so there is no reason to introduce a network dependency here.
"""

from pathlib import Path

from app.config import get_settings

ALLOWED_MIME_TYPES = {"image/png", "image/jpeg", "image/webp"}
MAX_UPLOAD_BYTES = 10 * 1024 * 1024

_EXTENSIONS_BY_MIME_TYPE = {"image/png": "png", "image/jpeg": "jpg", "image/webp": "webp"}


class UnsupportedUploadError(Exception):
    """Raised by `validate_upload` for a rejected file. The message says
    whether it was the MIME type or the size."""


def validate_upload(mime_type: str, content: bytes) -> None:
    """Pure validation — no I/O. Raises `UnsupportedUploadError` if
    `mime_type` isn't one of `ALLOWED_MIME_TYPES` or `content` is larger
    than `MAX_UPLOAD_BYTES`."""
    if mime_type not in ALLOWED_MIME_TYPES:
        raise UnsupportedUploadError(
            f"Unsupported file type {mime_type!r}; allowed types are {sorted(ALLOWED_MIME_TYPES)}"
        )
    if len(content) > MAX_UPLOAD_BYTES:
        raise UnsupportedUploadError(
            f"File is too large ({len(content)} bytes); the maximum is {MAX_UPLOAD_BYTES} bytes"
        )


def save_upload_image(
    base_dir: str, user_id: int, upload_id: int, mime_type: str, content: bytes
) -> str:
    """Writes `content` to disk under `base_dir`, at
    `{user_id}/{upload_id}.{ext}`. Assumes `content`/`mime_type` have
    already been checked by `validate_upload`. Returns the saved file's
    path relative to `base_dir`."""
    extension = _EXTENSIONS_BY_MIME_TYPE[mime_type]
    relative_path = Path(str(user_id)) / f"{upload_id}.{extension}"
    full_path = Path(base_dir) / relative_path
    full_path.parent.mkdir(parents=True, exist_ok=True)
    full_path.write_bytes(content)
    return str(relative_path)


def delete_upload_image(base_dir: str, relative_path: str) -> None:
    """Deletes the file at `relative_path` under `base_dir`. Not an
    error if the file is already gone."""
    full_path = Path(base_dir) / relative_path
    full_path.unlink(missing_ok=True)


def get_upload_base_dir() -> str:
    """FastAPI dependency for the configured upload base directory.
    Tests override this (via `app.dependency_overrides`) to point at an
    isolated `tmp_path`, the same way `fx.get_fx_provider` is overridden."""
    return get_settings().upload_dir
