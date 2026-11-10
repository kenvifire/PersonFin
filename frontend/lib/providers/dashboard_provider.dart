import 'package:flutter/foundation.dart';

import '../api/api_client.dart';
import '../api/dashboard_api.dart';
import '../api/targets_api.dart';
import '../models/dashboard.dart';
import '../models/drift_flag.dart';

enum LoadState { loading, loaded, error }

/// Loads the dashboard summary and drift flags together, in the currently
/// selected display currency, and exposes them to the dashboard screen.
class DashboardProvider extends ChangeNotifier {
  final DashboardApiBase _dashboardApi;
  final TargetsApiBase _targetsApi;

  DashboardProvider({
    required DashboardApiBase dashboardApi,
    required TargetsApiBase targetsApi,
  })  : _dashboardApi = dashboardApi,
        _targetsApi = targetsApi;

  LoadState state = LoadState.loading;
  DashboardData? data;
  List<DriftFlag> drift = [];
  String? errorMessage;
  String currency = 'CAD';

  /// Bumped by [reset]; an in-flight [load] that started under an older
  /// generation drops its result instead of writing it, so a response that
  /// belongs to a signed-out session can never land after the reset (or
  /// leak into the next user's session).
  int _generation = 0;

  /// Fetches the dashboard and drift data concurrently for [currency]. On
  /// success, updates [data]/[drift] and sets [state] to
  /// [LoadState.loaded]. If either request throws an [ApiException], sets
  /// [errorMessage] to its message and [state] to [LoadState.error].
  /// Either way, listeners are notified once at the end.
  Future<void> load() async {
    final generation = _generation;
    try {
      final results = await Future.wait([
        _dashboardApi.getDashboard(currency),
        _targetsApi.getDrift(currency),
      ]);
      if (generation != _generation) return;
      data = results[0] as DashboardData;
      drift = results[1] as List<DriftFlag>;
      errorMessage = null;
      state = LoadState.loaded;
    } on ApiException catch (e) {
      if (generation != _generation) return;
      errorMessage = e.message;
      state = LoadState.error;
    }
    notifyListeners();
  }

  /// Returns to the initial, empty `loading` state — called when the
  /// session ends, so neither a stale error nor the previous user's data
  /// survives into the next sign-in. [currency] is a device-local display
  /// preference, not user data, so it's kept.
  void reset() {
    _generation++;
    state = LoadState.loading;
    data = null;
    drift = [];
    errorMessage = null;
    notifyListeners();
  }

  /// Re-fetches only the drift flags (e.g. after an allocation target was
  /// edited elsewhere), leaving [data]/[state] alone. Does nothing unless
  /// the dashboard is already loaded; a failure keeps the previous flags,
  /// since a background refresh shouldn't replace a loaded dashboard with
  /// an error screen.
  Future<void> refreshDrift() async {
    if (state != LoadState.loaded) return;
    final generation = _generation;
    try {
      final refreshed = await _targetsApi.getDrift(currency);
      if (generation != _generation) return;
      drift = refreshed;
      notifyListeners();
    } on ApiException {
      // Keep the previous flags; see doc comment.
    }
  }

  /// Switches the display currency and reloads data for it.
  Future<void> setCurrency(String newCurrency) async {
    currency = newCurrency;
    await load();
  }
}
