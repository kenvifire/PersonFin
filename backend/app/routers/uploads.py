"""`POST /uploads`: receives a multipart screenshot upload, persists a
`pending` `Upload` row, and stores the file on local disk.

The row is created first (to get an id to name the file after), then
the file is saved; if the write fails, the row is simply left
`pending` with no `image_path` — there's no retry endpoint yet, so a
user who hits that would just re-upload.

`POST /uploads/{id}/extract`: reads the stored image back off disk and
runs vision extraction against it. Extraction failure is recorded as
upload status (`failed`, with `extraction_error` set), not an HTTP
error — the endpoint itself always succeeds at recording the outcome,
whichever way it goes.
"""

from pathlib import Path

from fastapi import APIRouter, Depends, HTTPException, UploadFile, status
from sqlalchemy.orm import Session

from app.auth.dependencies import get_current_user
from app.db import get_db
from app.models import Upload, User
from app.models.upload import STATUS_EXTRACTED, STATUS_FAILED, STATUS_PENDING, TERMINAL_STATUSES
from app.routers._ownership import get_owned_upload_or_404
from app.schemas.upload import UploadDetailOut, UploadExtractOut, UploadOut, UploadSummaryOut
from app.services import vision
from app.services.image_storage import get_upload_base_dir, save_upload_image, validate_upload
from app.services.matching import suggest_account
from app.services.vision import ExtractionFailed, VisionExtractor

router = APIRouter(prefix="/uploads", tags=["uploads"])


@router.post("", response_model=UploadOut, status_code=status.HTTP_201_CREATED)
async def create_upload(
    file: UploadFile,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
    base_dir: str = Depends(get_upload_base_dir),
) -> Upload:
    content = await file.read()
    validate_upload(file.content_type, content)

    upload = Upload(user_id=current_user.id, mime_type=file.content_type, status=STATUS_PENDING)
    db.add(upload)
    db.commit()
    db.refresh(upload)

    image_path = save_upload_image(
        base_dir,
        user_id=current_user.id,
        upload_id=upload.id,
        mime_type=file.content_type,
        content=content,
    )
    upload.image_path = image_path
    db.commit()
    db.refresh(upload)
    return upload


@router.post("/{upload_id}/extract", response_model=UploadExtractOut)
def extract_upload(
    upload_id: int,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
    base_dir: str = Depends(get_upload_base_dir),
    extractor: VisionExtractor = Depends(vision.get_vision_extractor),
) -> Upload:
    upload = get_owned_upload_or_404(upload_id, current_user, db)
    if upload.status in TERMINAL_STATUSES:
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="Upload is already finalized")

    # `image_path` can be `None` (the original upload's file write failed,
    # per `Upload`'s docstring) and even a set path can point at a file
    # since removed from disk — `pending` isn't a terminal status, so
    # nothing upstream of here rules either case out. Treat "no readable
    # image" the same way as an Azure extraction failure: record it on
    # the upload and return 200, never a bare 500 from a missing file.
    image_bytes: bytes | None = None
    if upload.image_path is not None:
        try:
            image_bytes = (Path(base_dir) / upload.image_path).read_bytes()
        except OSError:
            image_bytes = None

    if image_bytes is None:
        upload.status = STATUS_FAILED
        upload.extraction_error = "Stored image could not be read (missing or never saved)"
    else:
        try:
            result = extractor.extract(image_bytes, upload.mime_type)
        except ExtractionFailed as exc:
            upload.status = STATUS_FAILED
            upload.extraction_error = str(exc)
        else:
            upload.status = STATUS_EXTRACTED
            upload.extracted_payload = result.model_dump(mode="json")
            upload.extraction_error = None
            matched = suggest_account(db, current_user.id, result.institution, result.account_label)
            upload.suggested_account_id = matched.id if matched else None

    db.commit()
    db.refresh(upload)
    return upload


@router.get("", response_model=list[UploadSummaryOut])
def list_uploads(
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> list[Upload]:
    return (
        db.query(Upload)
        .filter(Upload.user_id == current_user.id)
        .order_by(Upload.created_at.desc())
        .all()
    )


@router.get("/{upload_id}", response_model=UploadDetailOut)
def get_upload(
    upload_id: int,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> Upload:
    return get_owned_upload_or_404(upload_id, current_user, db)
