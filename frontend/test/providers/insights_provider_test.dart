import 'package:flutter_test/flutter_test.dart';
import 'package:personfin/api/api_client.dart';
import 'package:personfin/providers/dashboard_provider.dart' show LoadState;
import 'package:personfin/providers/insights_provider.dart';

import '../fakes.dart';

void main() {
  group('InsightsProvider', () {
    test('load() sets state to loaded with insights data and targets on success', () async {
      final insightsApi = FakeInsightsApi();
      final targetsApi = FakeTargetsApi();
      final provider = InsightsProvider(insightsApi: insightsApi, targetsApi: targetsApi);

      await provider.load();

      expect(provider.state, LoadState.loaded);
      expect(provider.data, isNotNull);
      expect(provider.data!.dashboard.netWorth, 1000.0);
      expect(provider.targets, hasLength(2));
      expect(provider.targets.first.assetClass, 'Equity');
      expect(provider.errorMessage, isNull);
    });

    test('load() sets state to error with the ApiException message on failure', () async {
      final insightsApi = FakeInsightsApi(
        error: ApiException(503, 'Exchange rate temporarily unavailable, try again shortly'),
      );
      final targetsApi = FakeTargetsApi();
      final provider = InsightsProvider(insightsApi: insightsApi, targetsApi: targetsApi);

      await provider.load();

      expect(provider.state, LoadState.error);
      expect(provider.errorMessage, 'Exchange rate temporarily unavailable, try again shortly');
    });

    test('updateTarget replaces the matching target in `targets` on success without changing `state`',
        () async {
      final insightsApi = FakeInsightsApi();
      final targetsApi = FakeTargetsApi();
      final provider = InsightsProvider(insightsApi: insightsApi, targetsApi: targetsApi);
      await provider.load();
      expect(provider.state, LoadState.loaded);

      await provider.updateTarget('Equity', 70.0);

      expect(provider.state, LoadState.loaded);
      expect(provider.targets, hasLength(2));
      final updated = provider.targets.firstWhere((t) => t.assetClass == 'Equity');
      expect(updated.targetPct, 70.0);
      expect(provider.errorMessage, isNull);
    });

    test('updateTarget sets errorMessage on a thrown ApiException without changing `state` or `targets`',
        () async {
      final insightsApi = FakeInsightsApi();
      final targetsApi = FakeTargetsApi(
        updateTargetError: ApiException(422, 'target_pct must be between 0 and 100'),
      );
      final provider = InsightsProvider(insightsApi: insightsApi, targetsApi: targetsApi);
      await provider.load();
      final originalTargets = List.of(provider.targets);

      await provider.updateTarget('Equity', 70.0);

      expect(provider.state, LoadState.loaded);
      expect(provider.errorMessage, 'target_pct must be between 0 and 100');
      expect(provider.targets.length, originalTargets.length);
      expect(provider.targets.first.targetPct, originalTargets.first.targetPct);
    });
  });
}
