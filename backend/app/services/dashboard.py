"""Dashboard aggregation service.

Net worth and the asset-class/country breakdowns only count each
account's *latest* snapshot (by `taken_at`, tie-broken by `created_at`
and then `id`) — an account's current state is its latest snapshot,
never a sum across snapshots (the "current state is a merge" rule
from the spec: a later snapshot supersedes, it doesn't add to, an
earlier one).

`trend` applies that same rule at every point in time: for each
distinct `taken_at` across all of the user's snapshots, the point's
value is the sum, over every account, of that account's latest snapshot
with `taken_at <= that date` (same tie-break). An account's value
carries forward until it's superseded; an account with no snapshot yet
as of a date contributes 0 to that point. Multiple snapshots for the
same account on the same date never double-count — only the latest one
counts.

All aggregation happens in USD (via each holding's locked `value_usd`)
and is converted to `display_currency` with a single USD->display rate
fetched once per `build_dashboard` call, never re-deriving a holding's
USD value from a current rate.
"""

from collections import defaultdict
from datetime import date as Date

from sqlalchemy.orm import Session, joinedload

from app.models import Account, Snapshot
from app.schemas.dashboard import AccountSummary, DashboardOut, TrendPoint
from app.services import fx
from app.services.fx import FXRateProvider

USD = "USD"


def _snapshot_order_key(snapshot: Snapshot) -> tuple:
    # `created_at` only has second resolution on SQLite, so `id` is the
    # final, always-unique tie-breaker.
    return (snapshot.taken_at, snapshot.created_at, snapshot.id)


def _latest_snapshot(account: Account) -> Snapshot | None:
    if not account.snapshots:
        return None
    return max(account.snapshots, key=_snapshot_order_key)


def _snapshot_total_usd(snapshot: Snapshot) -> float:
    return sum(h.value_usd for h in snapshot.holdings)


def _build_trend_usd(accounts: list[Account]) -> list[tuple[Date, float]]:
    """Per-date net worth in USD, carrying each account's latest value
    forward (see module docstring)."""
    # For each account, the total of its latest snapshot *on* each date
    # it has snapshots for. Iterating in ascending order means the last
    # write per date wins, i.e. the latest snapshot on that date.
    per_account_by_date: list[dict[Date, float]] = []
    all_dates: set[Date] = set()
    for account in accounts:
        by_date: dict[Date, float] = {}
        for snapshot in sorted(account.snapshots, key=_snapshot_order_key):
            by_date[snapshot.taken_at] = _snapshot_total_usd(snapshot)
        per_account_by_date.append(by_date)
        all_dates.update(by_date)

    # Sweep dates in order; each account's "current" value is its value
    # on the most recent date <= the sweep date (0 before its first).
    current = [0.0] * len(per_account_by_date)
    trend: list[tuple[Date, float]] = []
    for day in sorted(all_dates):
        for index, by_date in enumerate(per_account_by_date):
            if day in by_date:
                current[index] = by_date[day]
        trend.append((day, sum(current)))
    return trend


def build_dashboard(
    db: Session,
    user_id: int,
    display_currency: str,
    fx_provider: FXRateProvider,
) -> DashboardOut:
    accounts = (
        db.query(Account)
        .options(joinedload(Account.snapshots).joinedload(Snapshot.holdings))
        .filter(Account.user_id == user_id)
        .all()
    )

    # One rate lookup per call, reused for every bucket below.
    usd_to_display = fx.convert(1.0, USD, display_currency, fx_provider)

    def to_display(amount_usd: float) -> float:
        return amount_usd * usd_to_display

    net_worth_usd = 0.0
    by_asset_class_usd: dict[str, float] = defaultdict(float)
    by_country_usd: dict[str, float] = defaultdict(float)
    account_summaries: list[AccountSummary] = []

    for account in accounts:
        latest = _latest_snapshot(account)
        if latest is None:
            account_summaries.append(
                AccountSummary(account_id=account.id, name=account.name, as_of=None, value=0.0)
            )
            continue

        account_total_usd = _snapshot_total_usd(latest)
        net_worth_usd += account_total_usd
        for holding in latest.holdings:
            by_asset_class_usd[holding.asset_class] += holding.value_usd
            by_country_usd[holding.country] += holding.value_usd
        account_summaries.append(
            AccountSummary(
                account_id=account.id,
                name=account.name,
                as_of=latest.taken_at,
                value=to_display(account_total_usd),
            )
        )

    trend = [
        TrendPoint(taken_at=taken_at, net_worth=to_display(total_usd))
        for taken_at, total_usd in _build_trend_usd(accounts)
    ]

    return DashboardOut(
        net_worth=to_display(net_worth_usd),
        currency=display_currency,
        by_asset_class={
            asset_class: to_display(total_usd)
            for asset_class, total_usd in by_asset_class_usd.items()
        },
        by_country={
            country: to_display(total_usd)
            for country, total_usd in by_country_usd.items()
        },
        accounts=account_summaries,
        trend=trend,
    )
