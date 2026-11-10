import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:personfin/api/api_client.dart';
import 'package:personfin/api/targets_api.dart';

void main() {
  group('TargetsApi', () {
    test('getDrift parses a list of drift flags', () async {
      http.Request? capturedRequest;
      final mockClient = MockClient((request) async {
        capturedRequest = request;
        return http.Response(
          jsonEncode([
            {
              'asset_class': 'Equity',
              'target_pct': 60.0,
              'actual_pct': 72.0,
              'delta_pct': 12.0,
            },
          ]),
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
      final targetsApi = TargetsApi(apiClient);

      final drift = await targetsApi.getDrift('CAD');

      expect(capturedRequest!.url.path, '/targets/drift');
      expect(capturedRequest!.url.queryParameters['currency'], 'CAD');
      expect(drift, hasLength(1));
      expect(drift.first.assetClass, 'Equity');
      expect(drift.first.targetPct, 60.0);
      expect(drift.first.actualPct, 72.0);
      expect(drift.first.deltaPct, 12.0);
    });

    test('getDrift parses an empty list', () async {
      final mockClient = MockClient((request) async {
        return http.Response(
          jsonEncode([]),
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
      final targetsApi = TargetsApi(apiClient);

      final drift = await targetsApi.getDrift('CAD');

      expect(drift, isEmpty);
    });
  });
}
