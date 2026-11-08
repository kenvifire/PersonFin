"""Upload: tracks one screenshot through the extraction workflow.

Status state machine (enforced by callers, not the database):

    pending --(extraction succeeds)--> extracted --(user confirms)--> confirmed
    pending --(extraction succeeds)--> extracted --(user discards)--> discarded
    pending --(extraction fails)-----> failed

`confirmed` and `discarded` are terminal: once there, an upload is never
revisited.
"""

from datetime import datetime
from typing import Any

from sqlalchemy import JSON, DateTime, ForeignKey, String, func
from sqlalchemy.orm import Mapped, mapped_column

from app.db import Base

STATUS_PENDING = "pending"
STATUS_EXTRACTED = "extracted"
STATUS_FAILED = "failed"
STATUS_CONFIRMED = "confirmed"
STATUS_DISCARDED = "discarded"

TERMINAL_STATUSES = frozenset({STATUS_CONFIRMED, STATUS_DISCARDED})


class Upload(Base):
    __tablename__ = "uploads"

    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True)
    # Relative to `Settings.upload_dir`. Null until the file is actually
    # written to disk — the row is created first (to get an id for the
    # filename) and a write failure leaves it `pending` with no path set.
    image_path: Mapped[str | None] = mapped_column(String, nullable=True)
    mime_type: Mapped[str] = mapped_column(String, nullable=False)
    status: Mapped[str] = mapped_column(String, nullable=False, default=STATUS_PENDING)
    extracted_payload: Mapped[dict[str, Any] | None] = mapped_column(JSON, nullable=True)
    extraction_error: Mapped[str | None] = mapped_column(String, nullable=True)
    suggested_account_id: Mapped[int | None] = mapped_column(
        ForeignKey("accounts.id", ondelete="SET NULL"), nullable=True, index=True
    )
    matched_account_id: Mapped[int | None] = mapped_column(
        ForeignKey("accounts.id", ondelete="CASCADE"), nullable=True, index=True
    )
    snapshot_id: Mapped[int | None] = mapped_column(
        ForeignKey("snapshots.id", ondelete="CASCADE"), nullable=True, index=True
    )
    created_at: Mapped[datetime] = mapped_column(DateTime, server_default=func.now(), nullable=False)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime, server_default=func.now(), onupdate=func.now(), nullable=False
    )
