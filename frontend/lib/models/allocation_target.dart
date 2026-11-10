/// A user's target allocation percentage for one asset class, as returned
/// by `GET /targets` and `PUT /targets/{assetClass}`. Mirrors
/// `app.schemas.target.TargetOut`.
class AllocationTarget {
  final int id;
  final String assetClass;
  final double targetPct;
  final bool isUserSet;

  AllocationTarget({
    required this.id,
    required this.assetClass,
    required this.targetPct,
    required this.isUserSet,
  });

  factory AllocationTarget.fromJson(Map<String, dynamic> json) => AllocationTarget(
        id: json['id'] as int,
        assetClass: json['asset_class'] as String,
        targetPct: (json['target_pct'] as num).toDouble(),
        isUserSet: json['is_user_set'] as bool,
      );
}
