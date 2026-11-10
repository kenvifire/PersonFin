import 'package:flutter/foundation.dart';

import '../api/api_client.dart';
import '../api/insights_api.dart';
import '../api/targets_api.dart';
import '../models/allocation_target.dart';
import '../models/insights.dart';
import 'dashboard_provider.dart' show LoadState;

/// Loads the insights narrative and the user's allocation targets
/// together, in the currently selected display currency, and exposes
/// them to the insights/to-dos screen.
class InsightsProvider extends ChangeNotifier {
  final InsightsApiBase _insightsApi;
  final TargetsApiBase _targetsApi;

  InsightsProvider({
    required InsightsApiBase insightsApi,
    required TargetsApiBase targetsApi,
  })  : _insightsApi = insightsApi,
        _targetsApi = targetsApi;

  LoadState state = LoadState.loading;
  InsightsData? data;
  List<AllocationTarget> targets = [];
  String? errorMessage;
  String currency = 'CAD';

  /// Bumped by [reset]; see `DashboardProvider._generation`.
  int _generation = 0;

  /// Fetches the insights narrative and allocation targets concurrently
  /// for [currency]. On success, updates [data]/[targets] and sets
  /// [state] to [LoadState.loaded]. If either request throws an
  /// [ApiException], sets [errorMessage] to its message and [state] to
  /// [LoadState.error]. Either way, listeners are notified once at the
  /// end.
  Future<void> load() async {
    final generation = _generation;
    try {
      final results = await Future.wait([
        _insightsApi.getInsights(currency),
        _targetsApi.listTargets(),
      ]);
      if (generation != _generation) return;
      data = results[0] as InsightsData;
      targets = results[1] as List<AllocationTarget>;
      errorMessage = null;
      state = LoadState.loaded;
    } on ApiException catch (e) {
      if (generation != _generation) return;
      errorMessage = e.message;
      state = LoadState.error;
    }
    notifyListeners();
  }

  /// Returns to the initial, empty `loading` state when the session ends
  /// (see `DashboardProvider.reset`).
  void reset() {
    _generation++;
    state = LoadState.loading;
    data = null;
    targets = [];
    errorMessage = null;
    notifyListeners();
  }

  /// Updates the target percentage for [assetClass]. On success, replaces
  /// the matching entry in [targets] with the server's copy. A failed
  /// edit only sets [errorMessage] — [state] (and the rest of [targets])
  /// is left alone, since a failed edit shouldn't blank out an
  /// already-loaded screen.
  Future<void> updateTarget(String assetClass, double targetPct) async {
    final generation = _generation;
    try {
      final updated = await _targetsApi.updateTarget(assetClass, targetPct);
      if (generation != _generation) return;
      targets = [
        for (final target in targets)
          if (target.assetClass == assetClass) updated else target,
      ];
      errorMessage = null;
    } on ApiException catch (e) {
      if (generation != _generation) return;
      errorMessage = e.message;
    }
    notifyListeners();
  }

  /// Marks a failed edit's [errorMessage] as shown, without notifying —
  /// called by the screen right after it surfaces the message, so the same
  /// failure isn't shown again on a later rebuild while a *repeat* failure
  /// (even with an identical message) still is.
  void clearErrorMessage() {
    errorMessage = null;
  }
}
