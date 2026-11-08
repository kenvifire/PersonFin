"""Import every model module so they register their tables on
`Base.metadata` as soon as `app.models` (or anything that imports it) is
imported — Alembic's `target_metadata = Base.metadata` and
`Base.metadata.create_all()` in tests both rely on that registration
having already happened, not on some other module having imported the
individual model files first."""

from app.models.account import Account
from app.models.holding import Holding
from app.models.snapshot import Snapshot
from app.models.target import AllocationTarget
from app.models.todo import Todo
from app.models.user import User

__all__ = [
    "Account",
    "AllocationTarget",
    "Holding",
    "Snapshot",
    "Todo",
    "User",
]
