import 'package:flutter_test/flutter_test.dart';
import 'package:personfin/api/api_client.dart';
import 'package:personfin/api/dashboard_api.dart';
import 'package:personfin/api/targets_api.dart';
import 'package:personfin/models/dashboard.dart';
import 'package:personfin/models/drift_flag.dart';
import 'package:personfin/providers/dashboard_provider.dart';

DashboardData _dashboardFor(String currency) => DashboardData(
      netWorth: 1000.0,
      currency: currency,
      byAssetClass: {'Equity': 1000.0},
      byCountry: {'CA': 1000.0},
      accounts: [],
      trend: [],
    );

List<DriftFlag> _driftFor(String currency) => [
      DriftFlag(assetClass: 'Equity', targetPct: 60.0, actualPct: 65.0, deltaPct: 5.0),
    ];

class FakeDashboardApi implements DashboardApiBase {
  final DashboardData? fixedData;
  final Object? error;
  String? lastRequestedCurrency;

  FakeDashboardApi({this.fixedData, this.error});

  @override
  Future<DashboardData> getDashboard(String currency) async {
    lastRequestedCurrency = currency;
    if (error != null) {
      throw error!;
    }
    return fixedData ?? _dashboardFor(currency);
  }
}

class FakeTargetsApi implements TargetsApiBase {
  final List<DriftFlag>? fixedDrift;
  final Object? error;
  String? lastRequestedCurrency;

  FakeTargetsApi({this.fixedDrift, this.error});

  @override
  Future<List<DriftFlag>> getDrift(String currency) async {
    lastRequestedCurrency = currency;
    if (error != null) {
      throw error!;
    }
    return fixedDrift ?? _driftFor(currency);
  }

  @override
  Future<List<AllocationTarget>> listTargets() => throw UnimplementedError();

  @override
  Future<AllocationTarget> updateTarget(String assetClass, double targetPct) =>
      throw UnimplementedError();
}

void main() {
  group('DashboardProvider', () {
    test('load() sets state to loaded with data and drift on success', () async {
      final dashboardApi = FakeDashboardApi();
      final targetsApi = FakeTargetsApi();
      final provider = DashboardProvider(dashboardApi: dashboardApi, targetsApi: targetsApi);

      await provider.load();

      expect(provider.state, LoadState.loaded);
      expect(provider.data, isNotNull);
      expect(provider.data!.netWorth, 1000.0);
      expect(provider.drift, hasLength(1));
      expect(provider.drift.first.assetClass, 'Equity');
      expect(provider.errorMessage, isNull);
    });

    // Review Focus: FX 503 — dashboardApi.getDashboard throws an
    // ApiException (e.g. the FX rate provider is down) and the provider
    // must surface that message, not swallow it or crash.
    test('load() sets state to error with the ApiException message on a thrown ApiException',
        () async {
      final dashboardApi = FakeDashboardApi(
        error: ApiException(503, 'Exchange rate temporarily unavailable, try again shortly'),
      );
      final targetsApi = FakeTargetsApi();
      final provider = DashboardProvider(dashboardApi: dashboardApi, targetsApi: targetsApi);

      await provider.load();

      expect(provider.state, LoadState.error);
      expect(provider.errorMessage, 'Exchange rate temporarily unavailable, try again shortly');
    });

    test('setCurrency updates currency and reloads data for the new currency', () async {
      final dashboardApi = FakeDashboardApi();
      final targetsApi = FakeTargetsApi();
      final provider = DashboardProvider(dashboardApi: dashboardApi, targetsApi: targetsApi);
      await provider.load();
      expect(provider.currency, 'CAD');

      await provider.setCurrency('USD');

      expect(provider.currency, 'USD');
      expect(dashboardApi.lastRequestedCurrency, 'USD');
      expect(targetsApi.lastRequestedCurrency, 'USD');
      expect(provider.state, LoadState.loaded);
      expect(provider.data!.currency, 'USD');
    });
  });
}
