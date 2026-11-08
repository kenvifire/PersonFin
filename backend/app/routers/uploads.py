"""`POST /uploads`: receives a multipart screenshot upload, persists a
`pending` `Upload` row, and stores the file on local disk.

The row is created first (to get an id to name the file after), then
the file is saved; if the write fails, the row is simply left
`pending` with no `image_path` — there's no retry endpoint yet, so a
user who hits that would just re-upload.

Vision extraction (turning the stored image into structured holdings
data) is a later task; this router only receives and persists the
screenshot.
"""

from fastapi import APIRouter, Depends, UploadFile, status
from sqlalchemy.orm import Session

from app.auth.dependencies import get_current_user
from app.db import get_db
from app.models import Upload, User
from app.models.upload import STATUS_PENDING
from app.schemas.upload import UploadOut
from app.services.image_storage import get_upload_base_dir, save_upload_image, validate_upload

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
