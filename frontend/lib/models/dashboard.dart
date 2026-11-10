/// Currency codes the backend can convert dashboard/drift figures into.
/// Mirrors `fx.SUPPORTED_CURRENCIES` on the backend exactly; this list is
/// fixed at build time and never re-fetched.
const List<String> supportedCurrencies = ['CAD', 'USD', 'CNY', 'HKD', 'SGD'];

/// One account's contribution to the dashboard, as returned by
/// `GET /dashboard`.
class AccountSummary {
  final int accountId;
  final String name;
  final DateTime? asOf;
  final double value;

  AccountSummary({
    required this.accountId,
    required this.name,
    required this.asOf,
    required this.value,
  });

  factory AccountSummary.fromJson(Map<String, dynamic> json) => AccountSummary(
        accountId: json['account_id'] as int,
        name: json['name'] as String,
        asOf: json['as_of'] == null ? null : DateTime.parse(json['as_of'] as String),
        value: (json['value'] as num).toDouble(),
      );
}

/// One point on the net-worth-over-time trend line.
class TrendPoint {
  final DateTime takenAt;
  final double netWorth;

  TrendPoint({required this.takenAt, required this.netWorth});

  factory TrendPoint.fromJson(Map<String, dynamic> json) => TrendPoint(
        takenAt: DateTime.parse(json['taken_at'] as String),
        netWorth: (json['net_worth'] as num).toDouble(),
      );
}

/// The full `GET /dashboard` response: net worth, its breakdowns, and the
/// trend line, all expressed in the requested display currency.
class DashboardData {
  final double netWorth;
  final String currency;
  final Map<String, double> byAssetClass;
  final Map<String, double> byCountry;
  final List<AccountSummary> accounts;
  final List<TrendPoint> trend;

  DashboardData({
    required this.netWorth,
    required this.currency,
    required this.byAssetClass,
    required this.byCountry,
    required this.accounts,
    required this.trend,
  });

  factory DashboardData.fromJson(Map<String, dynamic> json) => DashboardData(
        netWorth: (json['net_worth'] as num).toDouble(),
        currency: json['currency'] as String,
        byAssetClass: (json['by_asset_class'] as Map<String, dynamic>)
            .map((key, value) => MapEntry(key, (value as num).toDouble())),
        byCountry: (json['by_country'] as Map<String, dynamic>)
            .map((key, value) => MapEntry(key, (value as num).toDouble())),
        accounts: (json['accounts'] as List)
            .map((entry) => AccountSummary.fromJson(entry as Map<String, dynamic>))
            .toList(),
        trend: (json['trend'] as List)
            .map((entry) => TrendPoint.fromJson(entry as Map<String, dynamic>))
            .toList(),
      );
}
