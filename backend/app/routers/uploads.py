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
from app.schemas.upload import UploadExtractOut, UploadOut
from app.services import vision
from app.services.image_storage import get_upload_base_dir, save_upload_image, validate_upload
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
    # Task 3 adds a shared `get_owned_upload_or_404` helper; until then,
    # the ownership-scoped lookup is inlined here (same pattern as
    # `routers._ownership.get_owned_account_or_404`).
    upload = db.query(Upload).filter(Upload.id == upload_id, Upload.user_id == current_user.id).first()
    if upload is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Upload not found")
    if upload.status in TERMINAL_STATUSES:
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="Upload is already finalized")

    image_bytes = (Path(base_dir) / upload.image_path).read_bytes()
    try:
        result = extractor.extract(image_bytes, upload.mime_type)
    except ExtractionFailed as exc:
        upload.status = STATUS_FAILED
        upload.extraction_error = str(exc)
    else:
        upload.status = STATUS_EXTRACTED
        upload.extracted_payload = result.model_dump(mode="json")
        upload.extraction_error = None

    db.commit()
    db.refresh(upload)
    return upload
