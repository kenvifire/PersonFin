"""uploads: tracks one screenshot through the extraction workflow

Revision ID: 0003_uploads
Revises: 0002_users_email_not_unique
Create Date: 2026-11-08

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa

# revision identifiers, used by Alembic.
revision: str = "0003_uploads"
down_revision: Union[str, Sequence[str], None] = "0002_users_email_not_unique"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    """Upgrade schema."""
    op.create_table(
        "uploads",
        sa.Column("id", sa.Integer(), primary_key=True),
        sa.Column("user_id", sa.Integer(), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("image_path", sa.String(), nullable=True),
        sa.Column("mime_type", sa.String(), nullable=False),
        sa.Column("status", sa.String(), nullable=False),
        sa.Column("extracted_payload", sa.JSON(), nullable=True),
        sa.Column("extraction_error", sa.String(), nullable=True),
        sa.Column(
            "suggested_account_id",
            sa.Integer(),
            sa.ForeignKey("accounts.id", ondelete="SET NULL"),
            nullable=True,
        ),
        sa.Column(
            "matched_account_id",
            sa.Integer(),
            sa.ForeignKey("accounts.id", ondelete="CASCADE"),
            nullable=True,
        ),
        sa.Column(
            "snapshot_id", sa.Integer(), sa.ForeignKey("snapshots.id", ondelete="CASCADE"), nullable=True
        ),
        sa.Column("created_at", sa.DateTime(), server_default=sa.func.now(), nullable=False),
        sa.Column("updated_at", sa.DateTime(), server_default=sa.func.now(), nullable=False),
    )
    op.create_index("ix_uploads_user_id", "uploads", ["user_id"])
    op.create_index("ix_uploads_suggested_account_id", "uploads", ["suggested_account_id"])
    op.create_index("ix_uploads_matched_account_id", "uploads", ["matched_account_id"])
    op.create_index("ix_uploads_snapshot_id", "uploads", ["snapshot_id"])


def downgrade() -> None:
    """Downgrade schema."""
    op.drop_table("uploads")
