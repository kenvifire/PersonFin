import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:personfin/api/api_client.dart';
import 'package:personfin/api/dashboard_api.dart';

void main() {
  group('DashboardApi', () {
    test('getDashboard parses a full dashboard response', () async {
      http.Request? capturedRequest;
      final mockClient = MockClient((request) async {
        capturedRequest = request;
        return http.Response(
          jsonEncode({
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
      final dashboardApi = DashboardApi(apiClient);

      final data = await dashboardApi.getDashboard('CAD');

      expect(capturedRequest!.url.path, '/dashboard');
      expect(capturedRequest!.url.queryParameters['currency'], 'CAD');
      expect(data.netWorth, 125000.50);
      expect(data.currency, 'CAD');
      expect(data.byAssetClass, {'Equity': 90000.0, 'Bond': 35000.50});
      expect(data.byCountry, {'CA': 100000.0, 'US': 25000.50});
      expect(data.accounts, hasLength(1));
      expect(data.accounts.first.accountId, 1);
      expect(data.accounts.first.name, 'Checking');
      expect(data.accounts.first.asOf, DateTime(2026, 11, 1));
      expect(data.accounts.first.value, 5000.0);
      expect(data.trend, hasLength(1));
      expect(data.trend.first.takenAt, DateTime(2026, 10, 1));
      expect(data.trend.first.netWorth, 120000.0);
    });

    test('getDashboard surfaces a 503 as ApiException', () async {
      final mockClient = MockClient((request) async {
        return http.Response(
          jsonEncode({'detail': 'Exchange rate temporarily unavailable, try again shortly'}),
          503,
          headers: {'content-type': 'application/json'},
        );
      });
      final apiClient = ApiClient(
        baseUrl: 'https://api.example.com',
        httpClient: mockClient,
        getToken: () => null,
        onUnauthorized: () {},
      );
      final dashboardApi = DashboardApi(apiClient);

      expect(
        () => dashboardApi.getDashboard('CAD'),
        throwsA(isA<ApiException>()
            .having((e) => e.statusCode, 'statusCode', 503)
            .having((e) => e.message, 'message',
                'Exchange rate temporarily unavailable, try again shortly')),
      );
    });
  });
}
