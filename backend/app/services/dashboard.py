"""Dashboard aggregation service.

Net worth and the asset-class/country breakdowns only count each
account's *latest* snapshot (by `taken_at`, tie-broken by
`created_at`) — an account's current state is its latest snapshot,
never a sum across snapshots (the "current state is a merge" rule
from the spec: a later snapshot supersedes, it doesn't add to, an
earlier one).

`trend`, by contrast, is built from every distinct `taken_at` across
*all* of the user's snapshots (not just the latest per account), each
point summing the holdings reported in snapshots taken on that date.

All aggregation happens in USD (via each holding's locked `value_usd`)
and is converted to `display_currency` once at the end of each bucket,
via `fx.convert`, never re-deriving a holding's USD value from a
current rate.
"""

from collections import defaultdict
from datetime import date as Date

from sqlalchemy.orm import Session, joinedload

from app.models import Account, Snapshot
from app.schemas.dashboard import AccountSummary, DashboardOut, TrendPoint
from app.services import fx
from app.services.fx import FXRateProvider

USD = "USD"


def _latest_snapshot(account: Account) -> Snapshot | None:
    if not account.snapshots:
        return None
    return max(account.snapshots, key=lambda s: (s.taken_at, s.created_at))


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

    net_worth_usd = 0.0
    by_asset_class_usd: dict[str, float] = defaultdict(float)
    by_country_usd: dict[str, float] = defaultdict(float)
    by_date_usd: dict[Date, float] = defaultdict(float)
    account_summaries: list[AccountSummary] = []

    for account in accounts:
        latest = _latest_snapshot(account)
        if latest is None:
            account_summaries.append(
                AccountSummary(account_id=account.id, name=account.name, as_of=None, value=0.0)
            )
        else:
            account_total_usd = sum(h.value_usd for h in latest.holdings)
            net_worth_usd += account_total_usd
            for holding in latest.holdings:
                by_asset_class_usd[holding.asset_class] += holding.value_usd
                by_country_usd[holding.country] += holding.value_usd
            account_summaries.append(
                AccountSummary(
                    account_id=account.id,
                    name=account.name,
                    as_of=latest.taken_at,
                    value=fx.convert(account_total_usd, USD, display_currency, fx_provider),
                )
            )

        # Trend uses every snapshot, not just the latest per account.
        for snapshot in account.snapshots:
            snapshot_total_usd = sum(h.value_usd for h in snapshot.holdings)
            by_date_usd[snapshot.taken_at] += snapshot_total_usd

    trend = [
        TrendPoint(
            taken_at=taken_at,
            net_worth=fx.convert(total_usd, USD, display_currency, fx_provider),
        )
        for taken_at, total_usd in sorted(by_date_usd.items())
    ]

    return DashboardOut(
        net_worth=fx.convert(net_worth_usd, USD, display_currency, fx_provider),
        currency=display_currency,
        by_asset_class={
            asset_class: fx.convert(total_usd, USD, display_currency, fx_provider)
            for asset_class, total_usd in by_asset_class_usd.items()
        },
        by_country={
            country: fx.convert(total_usd, USD, display_currency, fx_provider)
            for country, total_usd in by_country_usd.items()
        },
        accounts=account_summaries,
        trend=trend,
    )
