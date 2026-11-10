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

  /// Fetches the dashboard and drift data concurrently for [currency]. On
  /// success, updates [data]/[drift] and sets [state] to
  /// [LoadState.loaded]. If either request throws an [ApiException], sets
  /// [errorMessage] to its message and [state] to [LoadState.error].
  /// Either way, listeners are notified once at the end.
  Future<void> load() async {
    try {
      final results = await Future.wait([
        _dashboardApi.getDashboard(currency),
        _targetsApi.getDrift(currency),
      ]);
      data = results[0] as DashboardData;
      drift = results[1] as List<DriftFlag>;
      state = LoadState.loaded;
    } on ApiException catch (e) {
      errorMessage = e.message;
      state = LoadState.error;
    }
    notifyListeners();
  }

  /// Switches the display currency and reloads data for it.
  Future<void> setCurrency(String newCurrency) async {
    currency = newCurrency;
    await load();
  }
}
