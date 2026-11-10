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
      test('reset() clears data/drift/errorMessage and returns state to loading', () async {
      final provider =
          DashboardProvider(dashboardApi: FakeDashboardApi(), targetsApi: FakeTargetsApi());
      await provider.load();
      expect(provider.state, LoadState.loaded);
      var notified = 0;
      provider.addListener(() => notified++);

      provider.reset();

      expect(provider.state, LoadState.loading);
      expect(provider.data, isNull);
      expect(provider.drift, isEmpty);
      expect(provider.errorMessage, isNull);
      expect(notified, 1);
    });

    test('reset() clears a stale error state (e.g. the 401 that caused the sign-out)', () async {
      final provider = DashboardProvider(
        dashboardApi: FakeDashboardApi(error: ApiException(401, 'Not authenticated')),
        targetsApi: FakeTargetsApi(),
      );
      await provider.load();
      expect(provider.state, LoadState.error);

      provider.reset();

      expect(provider.state, LoadState.loading);
      expect(provider.errorMessage, isNull);
    });

    test('a load() still in flight when reset() is called does not write its result afterwards',
        () async {
      final dashboardApi = GatedDashboardApi();
      final provider = DashboardProvider(dashboardApi: dashboardApi, targetsApi: FakeTargetsApi());

      final pending = provider.load();
      provider.reset();
      dashboardApi.gate.complete();
      await pending;

      expect(provider.state, LoadState.loading);
      expect(provider.data, isNull);
    });

    test('a successful load() clears an errorMessage left by an earlier failure', () async {
      final provider =
          DashboardProvider(dashboardApi: FakeDashboardApi(), targetsApi: FakeTargetsApi())
            ..errorMessage = 'FX down';

      await provider.load();

      expect(provider.state, LoadState.loaded);
      expect(provider.errorMessage, isNull);
    });
  });
}
