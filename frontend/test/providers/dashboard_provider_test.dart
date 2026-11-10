import 'package:flutter_test/flutter_test.dart';
import 'package:personfin/api/api_client.dart';
import 'package:personfin/providers/dashboard_provider.dart';

import '../fakes.dart';

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
