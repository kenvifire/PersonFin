from typing import TYPE_CHECKING

from sqlalchemy import Float, ForeignKey, String
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.db import Base

if TYPE_CHECKING:
    from app.models.snapshot import Snapshot


class Holding(Base):
    __tablename__ = "holdings"

    id: Mapped[int] = mapped_column(primary_key=True)
    snapshot_id: Mapped[int] = mapped_column(ForeignKey("snapshots.id", ondelete="CASCADE"), nullable=False, index=True)
    label: Mapped[str] = mapped_column(String, nullable=False)
    asset_class: Mapped[str] = mapped_column(String, nullable=False)
    quantity: Mapped[float | None] = mapped_column(Float, nullable=True)
    # `value`/`currency` is the as-reported amount; `value_usd`/
    # `fx_rate_to_usd` is the locked reference-currency conversion from the
    # time of creation.
    value: Mapped[float] = mapped_column(Float, nullable=False)
    currency: Mapped[str] = mapped_column(String, nullable=False)
    country: Mapped[str] = mapped_column(String, nullable=False)
    value_usd: Mapped[float] = mapped_column(Float, nullable=False)
    fx_rate_to_usd: Mapped[float] = mapped_column(Float, nullable=False)

    snapshot: Mapped["Snapshot"] = relationship(back_populates="holdings")
