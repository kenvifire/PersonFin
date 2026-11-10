// Shared hand-written fakes for `DashboardApiBase`/`TargetsApiBase`, used by
// both the provider tests (Task 6) and the dashboard screen tests (Task 7).
import 'package:personfin/api/dashboard_api.dart';
import 'package:personfin/api/targets_api.dart';
import 'package:personfin/models/dashboard.dart';
import 'package:personfin/models/drift_flag.dart';

DashboardData dashboardFor(String currency) => DashboardData(
      netWorth: 1000.0,
      currency: currency,
      byAssetClass: {'Equity': 1000.0},
      byCountry: {'CA': 1000.0},
      accounts: [],
      trend: [],
    );

List<DriftFlag> driftFor(String currency) => [
      DriftFlag(assetClass: 'Equity', targetPct: 60.0, actualPct: 65.0, deltaPct: 5.0),
    ];

class FakeDashboardApi implements DashboardApiBase {
  final DashboardData? fixedData;
  final Object? error;
  String? lastRequestedCurrency;
  int callCount = 0;

  FakeDashboardApi({this.fixedData, this.error});

  @override
  Future<DashboardData> getDashboard(String currency) async {
    lastRequestedCurrency = currency;
    callCount++;
    if (error != null) {
      throw error!;
    }
    return fixedData ?? dashboardFor(currency);
  }
}

class FakeTargetsApi implements TargetsApiBase {
  final List<DriftFlag>? fixedDrift;
  final Object? error;
  String? lastRequestedCurrency;
  int callCount = 0;

  FakeTargetsApi({this.fixedDrift, this.error});

  @override
  Future<List<DriftFlag>> getDrift(String currency) async {
    lastRequestedCurrency = currency;
    callCount++;
    if (error != null) {
      throw error!;
    }
    return fixedDrift ?? driftFor(currency);
  }

  @override
  Future<List<AllocationTarget>> listTargets() => throw UnimplementedError();

  @override
  Future<AllocationTarget> updateTarget(String assetClass, double targetPct) =>
      throw UnimplementedError();
}
