/// Mirrors `app.schemas.snapshot.HoldingOut`: one holding as actually
/// recorded in a snapshot, with its locked USD conversion.
class HoldingOut {
  final int id;
  final String label;
  final String assetClass;
  final double? quantity;
  final double value;
  final String currency;
  final String country;
  final double valueUsd;
  final double fxRateToUsd;

  HoldingOut({
    required this.id,
    required this.label,
    required this.assetClass,
    required this.quantity,
    required this.value,
    required this.currency,
    required this.country,
    required this.valueUsd,
    required this.fxRateToUsd,
  });

  factory HoldingOut.fromJson(Map<String, dynamic> json) => HoldingOut(
        id: json['id'] as int,
        label: json['label'] as String,
        assetClass: json['asset_class'] as String,
        quantity: (json['quantity'] as num?)?.toDouble(),
        value: (json['value'] as num).toDouble(),
        currency: json['currency'] as String,
        country: json['country'] as String,
        valueUsd: (json['value_usd'] as num).toDouble(),
        fxRateToUsd: (json['fx_rate_to_usd'] as num).toDouble(),
      );
}

/// Mirrors `app.schemas.snapshot.SnapshotOut`: one immutable dated
/// snapshot of an account's holdings.
class SnapshotOut {
  final int id;
  final DateTime takenAt;
  final DateTime createdAt;
  final List<HoldingOut> holdings;

  SnapshotOut({
    required this.id,
    required this.takenAt,
    required this.createdAt,
    required this.holdings,
  });

  factory SnapshotOut.fromJson(Map<String, dynamic> json) => SnapshotOut(
        id: json['id'] as int,
        takenAt: DateTime.parse(json['taken_at'] as String),
        createdAt: DateTime.parse(json['created_at'] as String),
        holdings: (json['holdings'] as List)
            .map((entry) => HoldingOut.fromJson(entry as Map<String, dynamic>))
            .toList(),
      );
}
