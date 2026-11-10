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

    test('listTargets parses a GET /targets list response', () async {
      http.Request? capturedRequest;
      final mockClient = MockClient((request) async {
        capturedRequest = request;
        return http.Response(
          jsonEncode([
            {
              'id': 1,
              'asset_class': 'Equity',
              'target_pct': 60.0,
              'is_user_set': true,
              'updated_at': '2026-01-01T00:00:00',
            },
            {
              'id': 2,
              'asset_class': 'Bond',
              'target_pct': 40.0,
              'is_user_set': false,
              'updated_at': '2026-01-01T00:00:00',
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

      final targets = await targetsApi.listTargets();

      expect(capturedRequest!.url.path, '/targets');
      expect(targets, hasLength(2));
      expect(targets.first.id, 1);
      expect(targets.first.assetClass, 'Equity');
      expect(targets.first.targetPct, 60.0);
      expect(targets.first.isUserSet, isTrue);
      expect(targets[1].assetClass, 'Bond');
      expect(targets[1].isUserSet, isFalse);
    });

    test('updateTarget PUTs target_pct and parses the returned AllocationTarget', () async {
      http.Request? capturedRequest;
      Map<String, dynamic>? capturedBody;
      final mockClient = MockClient((request) async {
        capturedRequest = request;
        capturedBody = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode({
            'id': 1,
            'asset_class': 'Equity',
            'target_pct': 65.0,
            'is_user_set': true,
            'updated_at': '2026-01-01T00:00:00',
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
      final targetsApi = TargetsApi(apiClient);

      final target = await targetsApi.updateTarget('Equity', 65.0);

      expect(capturedRequest!.method, 'PUT');
      expect(capturedRequest!.url.path, '/targets/Equity');
      expect(capturedBody, {'target_pct': 65.0});
      expect(target.id, 1);
      expect(target.assetClass, 'Equity');
      expect(target.targetPct, 65.0);
      expect(target.isUserSet, isTrue);
    });
  });
}
