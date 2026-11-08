"""HTTP layer for snapshot creation.

Thin by design: confirms the account belongs to the current user (reusing
the shared ownership check in `routers._ownership`), then delegates
everything else to `services.snapshots.create_snapshot`. Snapshots are
immutable — there is deliberately no update/delete route here.
"""

from fastapi import APIRouter, Depends, status
from sqlalchemy.orm import Session

from app.auth.dependencies import get_current_user
from app.db import get_db
from app.models import Snapshot, User
from app.routers._ownership import get_owned_account_or_404
from app.schemas.snapshot import SnapshotIn, SnapshotOut
from app.services import fx
from app.services.snapshots import create_snapshot

router = APIRouter(prefix="/accounts/{account_id}/snapshots", tags=["snapshots"])


@router.post("", response_model=SnapshotOut, status_code=status.HTTP_201_CREATED)
def create_snapshot_endpoint(
    account_id: int,
    payload: SnapshotIn,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
    fx_provider: fx.FXRateProvider = Depends(fx.get_fx_provider),
) -> Snapshot:
    account = get_owned_account_or_404(account_id, current_user, db)
    return create_snapshot(db, account, payload, fx_provider)
