import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:personfin/api/api_client.dart';
import 'package:personfin/api/insights_api.dart';

Map<String, dynamic> _dashboardJson() => {
      'net_worth': 125000.50,
      'currency': 'CAD',
      'by_asset_class': {'Equity': 90000.0, 'Bond': 35000.50},
      'by_country': {'CA': 100000.0, 'US': 25000.50},
      'accounts': [
        {
          'account_id': 1,
          'name': 'Checking',
          'as_of': '2026-11-01',
          'value': 5000.0,
        },
      ],
      'trend': [
        {'taken_at': '2026-10-01', 'net_worth': 120000.0},
      ],
    };

List<Map<String, dynamic>> _driftJson() => [
      {
        'asset_class': 'Equity',
        'target_pct': 60.0,
        'actual_pct': 72.0,
        'delta_pct': 12.0,
      },
    ];

void main() {
  group('InsightsApi', () {
    test('getInsights parses a full response with narrative_unavailable: false', () async {
      http.Request? capturedRequest;
      final mockClient = MockClient((request) async {
        capturedRequest = request;
        return http.Response(
          jsonEncode({
            'dashboard': _dashboardJson(),
            'drift': _driftJson(),
            'narrative': {
              'summary': 'Your equity allocation has drifted above target.',
              'action_items': [
                {'asset_class': 'Equity', 'suggestion': 'Consider trimming equity exposure.'},
              ],
            },
            'narrative_unavailable': false,
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final apiClient = ApiClient(
        baseUrl: 'https://api.example.com',
        httpClient: mockClient,
        getToken: () => null,
        onUnauthorized: () {},
      );
      final insightsApi = InsightsApi(apiClient);

      final insights = await insightsApi.getInsights('CAD');

      expect(capturedRequest!.url.path, '/insights');
      expect(capturedRequest!.url.queryParameters['currency'], 'CAD');
      expect(insights.dashboard.netWorth, 125000.50);
      expect(insights.dashboard.currency, 'CAD');
      expect(insights.drift, hasLength(1));
      expect(insights.drift.first.assetClass, 'Equity');
      expect(insights.narrative.summary, 'Your equity allocation has drifted above target.');
      expect(insights.narrative.actionItems, hasLength(1));
      expect(insights.narrative.actionItems.first.assetClass, 'Equity');
      expect(insights.narrative.actionItems.first.suggestion, 'Consider trimming equity exposure.');
      expect(insights.narrativeUnavailable, isFalse);
    });

    test('getInsights parses a response with narrative_unavailable: true and empty action items',
        () async {
      final mockClient = MockClient((request) async {
        return http.Response(
          jsonEncode({
            'dashboard': _dashboardJson(),
            'drift': _driftJson(),
            'narrative': {
              'summary':
                  'Insight commentary is temporarily unavailable — your numbers above are still accurate.',
              'action_items': [],
            },
            'narrative_unavailable': true,
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final apiClient = ApiClient(
        baseUrl: 'https://api.example.com',
        httpClient: mockClient,
        getToken: () => null,
        onUnauthorized: () {},
      );
      final insightsApi = InsightsApi(apiClient);

      final insights = await insightsApi.getInsights('CAD');

      expect(insights.narrativeUnavailable, isTrue);
      expect(insights.narrative.actionItems, isEmpty);
    });
  });
}
