import 'dashboard.dart';
import 'drift_flag.dart';

/// One suggested action for a drifted asset class, as returned within
/// `GET /insights`. Mirrors `app.schemas.insights.ActionItem`.
class ActionItem {
  final String assetClass;
  final String suggestion;

  ActionItem({required this.assetClass, required this.suggestion});

  factory ActionItem.fromJson(Map<String, dynamic> json) => ActionItem(
        assetClass: json['asset_class'] as String,
        suggestion: json['suggestion'] as String,
      );
}

/// The DeepSeek-generated narrative over a dashboard/drift snapshot, or a
/// degraded placeholder when narrative generation failed. Mirrors
/// `app.schemas.insights.InsightsNarrative`.
class InsightsNarrative {
  final String summary;
  final List<ActionItem> actionItems;

  InsightsNarrative({required this.summary, required this.actionItems});

  factory InsightsNarrative.fromJson(Map<String, dynamic> json) => InsightsNarrative(
        summary: json['summary'] as String,
        actionItems: (json['action_items'] as List)
            .map((entry) => ActionItem.fromJson(entry as Map<String, dynamic>))
            .toList(),
      );
}

/// The full `GET /insights` response: the dashboard and drift it was
/// computed from, plus the narrative built on top of them. Mirrors
/// `app.schemas.insights.InsightsOut`.
class InsightsData {
  final DashboardData dashboard;
  final List<DriftFlag> drift;
  final InsightsNarrative narrative;
  final bool narrativeUnavailable;

  InsightsData({
    required this.dashboard,
    required this.drift,
    required this.narrative,
    required this.narrativeUnavailable,
  });

  factory InsightsData.fromJson(Map<String, dynamic> json) => InsightsData(
        dashboard: DashboardData.fromJson(json['dashboard'] as Map<String, dynamic>),
        drift: (json['drift'] as List)
            .map((entry) => DriftFlag.fromJson(entry as Map<String, dynamic>))
            .toList(),
        narrative: InsightsNarrative.fromJson(json['narrative'] as Map<String, dynamic>),
        narrativeUnavailable: json['narrative_unavailable'] as bool,
      );
}
