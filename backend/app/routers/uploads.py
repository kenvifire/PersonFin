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

`POST /uploads/{id}/confirm`: the one place a user's (possibly-edited)
holdings become a permanent snapshot. Deliberately thin — like
`routers.snapshots`, it resolves/creates the `Account` and then
delegates to `services.snapshots.create_snapshot` unmodified, with a
real `SnapshotIn` built from Plan 1's own `HoldingIn` items, so the
same value/currency/asset-class validation guards this path too.

Two near-simultaneous confirm requests for the same upload must never
both succeed — each would independently call `create_snapshot`,
creating two real, immutable Snapshot rows for one screenshot, with no
unique constraint to stop it. A plain "SELECT, check status, act"
sequence has a check-then-act race: both requests could read a
non-terminal status before either commits. `claim_upload_for_confirmation`
closes that race with a single atomic `UPDATE ... WHERE status IN
(...)`, moving the upload to the transitional `STATUS_CONFIRMING`
status before any real work happens; only the request whose `UPDATE`
actually matched a row proceeds.

`POST /uploads/{id}/discard`: deletes the stored image and marks the
upload discarded. No atomic claim here — see `discard_upload`'s
docstring for why that race is benign rather than needing Task 4's
treatment.
"""

from pathlib import Path

from fastapi import APIRouter, Depends, HTTPException, UploadFile, status
from sqlalchemy import update
from sqlalchemy.orm import Session

from app.auth.dependencies import get_current_user
from app.db import get_db
from app.models import Account, Snapshot, Upload, User
from app.models.upload import (
    STATUS_CONFIRMED,
    STATUS_CONFIRMING,
    STATUS_DISCARDED,
    STATUS_EXTRACTED,
    STATUS_FAILED,
    STATUS_PENDING,
    TERMINAL_STATUSES,
)
from app.routers._ownership import get_owned_account_or_404, get_owned_upload_or_404
from app.schemas.snapshot import SnapshotIn, SnapshotOut
from app.schemas.upload import UploadDetailOut, UploadExtractOut, UploadOut, UploadSummaryOut
from app.schemas.upload_confirm import ConfirmUploadIn
from app.services import fx, vision
from app.services.image_storage import delete_upload_image, get_upload_base_dir, save_upload_image, validate_upload
from app.services.matching import suggest_account
from app.services.snapshots import create_snapshot
from app.services.vision import ExtractionFailed, VisionExtractor

router = APIRouter(prefix="/uploads", tags=["uploads"])

# The only statuses a confirm attempt may start from. Deliberately an
# explicit allow-list, not "not in TERMINAL_STATUSES": the latter would
# still let a second, racing confirm request claim an upload that's
# already `STATUS_CONFIRMING` (which isn't terminal), defeating the
# whole point of the claim.
CLAIMABLE_STATUSES = (STATUS_PENDING, STATUS_EXTRACTED, STATUS_FAILED)


def claim_upload_for_confirmation(db: Session, upload_id: int) -> int:
    """Atomically move `upload_id` from a claimable status to the
    transitional `STATUS_CONFIRMING` in a single `UPDATE`, and return
    how many rows it matched (0 or 1, since `id` is a primary key).

    A caller that gets back `0` must treat the upload as unconfirmable
    right now (already terminal, or already being confirmed by another
    in-flight request) rather than proceeding. Commits immediately so
    the claim is visible to any other request as soon as it succeeds.
    """
    result = db.execute(
        update(Upload)
        .where(Upload.id == upload_id, Upload.status.in_(CLAIMABLE_STATUSES))
        .values(status=STATUS_CONFIRMING)
    )
    db.commit()
    return result.rowcount


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


@router.post("/{upload_id}/confirm", response_model=SnapshotOut, status_code=status.HTTP_201_CREATED)
def confirm_upload(
    upload_id: int,
    payload: ConfirmUploadIn,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
    fx_provider: fx.FXRateProvider = Depends(fx.get_fx_provider),
) -> Snapshot:
    upload = get_owned_upload_or_404(upload_id, current_user, db)
    original_status = upload.status

    # Atomic claim: closes the check-then-act race described in this
    # module's docstring. A rowcount of 0 means the upload was already
    # terminal, or another in-flight request already claimed it.
    if claim_upload_for_confirmation(db, upload_id) == 0:
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="Upload is already finalized")

    try:
        # `ConfirmUploadIn.exactly_one_of_account_id_or_new_account` already
        # guarantees exactly one of these is set.
        if payload.account_id is not None:
            account = get_owned_account_or_404(payload.account_id, current_user, db)
        else:
            assert payload.new_account is not None
            account = Account(user_id=current_user.id, **payload.new_account.model_dump())
            db.add(account)
            # `flush`, not `commit`: this gets a real `account.id` for
            # `create_snapshot` without persisting the account on its
            # own. If `create_snapshot` raises below, the `rollback` in
            # the `except` clause undoes this insert too, instead of
            # leaving an orphaned, snapshot-less `Account` behind that a
            # retry with the same `new_account` would then duplicate.
            db.flush()

        # Built from Plan 1's own `HoldingIn` items (via `payload.holdings`,
        # typed `list[HoldingIn]`) and passed to Plan 1's `create_snapshot`
        # unmodified — no separate validation or persistence path.
        snapshot_in = SnapshotIn(taken_at=payload.taken_at, holdings=payload.holdings)
        snapshot = create_snapshot(db, account, snapshot_in, fx_provider)
    except Exception:
        # Undo any uncommitted work from this attempt (e.g. the flushed
        # new Account above) and release the claim by restoring the
        # upload's pre-claim status, so it isn't stuck at
        # `STATUS_CONFIRMING` forever and a retry remains possible.
        # Re-raising lets existing global handlers (e.g.
        # `FXRateUnavailable` -> 503) still apply.
        db.rollback()
        db.execute(update(Upload).where(Upload.id == upload_id).values(status=original_status))
        db.commit()
        raise

    upload.status = STATUS_CONFIRMED
    upload.matched_account_id = account.id
    upload.snapshot_id = snapshot.id
    db.commit()
    db.refresh(snapshot)
    return snapshot


@router.post("/{upload_id}/discard", status_code=status.HTTP_204_NO_CONTENT)
def discard_upload(
    upload_id: int,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
    base_dir: str = Depends(get_upload_base_dir),
) -> None:
    """Deletes the stored image for `upload_id` and marks it discarded.

    Unlike `confirm_upload`, this doesn't need an atomic claim-before-act
    step. Two near-simultaneous discard requests both reading a
    non-terminal status before either commits would each call
    `delete_upload_image` (a no-op if the file's already gone, per its
    docstring) and each set `status = STATUS_DISCARDED` — the same
    final state either way, reached a harmless extra time. That's
    unlike confirm's race, where a duplicate "success" means a second,
    permanent, immutable Snapshot row with no unique constraint to
    catch it. There's no analogous bad side effect here, so a plain
    check-then-act is sufficient.
    """
    upload = get_owned_upload_or_404(upload_id, current_user, db)
    if upload.status in TERMINAL_STATUSES:
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="Upload is already finalized")

    if upload.image_path is not None:
        delete_upload_image(base_dir, upload.image_path)
    upload.status = STATUS_DISCARDED
    db.commit()
    return None
