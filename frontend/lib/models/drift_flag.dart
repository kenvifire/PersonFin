/// How far one asset class's actual allocation has drifted from its target,
/// as returned by `GET /targets/drift`.
class DriftFlag {
  final String assetClass;
  final double targetPct;
  final double actualPct;
  final double deltaPct;

  DriftFlag({
    required this.assetClass,
    required this.targetPct,
    required this.actualPct,
    required this.deltaPct,
  });

  factory DriftFlag.fromJson(Map<String, dynamic> json) => DriftFlag(
        assetClass: json['asset_class'] as String,
        targetPct: (json['target_pct'] as num).toDouble(),
        actualPct: (json['actual_pct'] as num).toDouble(),
        deltaPct: (json['delta_pct'] as num).toDouble(),
      );
}
