"""users.email is no longer unique; google_sub is the identity key

A new Google `sub` whose email already belongs to another user row (or
two rows racing on first login) must not fail with an IntegrityError.
`google_sub` keeps its unique index; `email` keeps a plain index for
lookups.

Revision ID: 0002_users_email_not_unique
Revises: 0001_initial
Create Date: 2026-11-08

"""
from typing import Sequence, Union

from alembic import op

# revision identifiers, used by Alembic.
revision: str = "0002_users_email_not_unique"
down_revision: Union[str, Sequence[str], None] = "0001_initial"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    """Upgrade schema."""
    op.drop_index("ix_users_email", table_name="users")
    op.create_index("ix_users_email", "users", ["email"], unique=False)


def downgrade() -> None:
    """Downgrade schema. Fails if duplicate emails exist by then."""
    op.drop_index("ix_users_email", table_name="users")
    op.create_index("ix_users_email", "users", ["email"], unique=True)
