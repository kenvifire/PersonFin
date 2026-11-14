import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:personfin/api/accounts_api.dart';
import 'package:personfin/api/api_client.dart';

void main() {
  group('AccountsApi', () {
    test('listAccounts parses a GET /accounts list response', () async {
      http.Request? capturedRequest;
      final mockClient = MockClient((request) async {
        capturedRequest = request;
        return http.Response(
          jsonEncode([
            {
              'id': 1,
              'name': 'Checking',
              'institution': 'Big Bank',
              'account_type': 'bank',
              'created_at': '2026-01-01T00:00:00',
            },
            {
              'id': 2,
              'name': 'Brokerage',
              'institution': 'Big Bank',
              'account_type': 'brokerage',
              'created_at': '2026-02-01T00:00:00',
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
      final accountsApi = AccountsApi(apiClient);

      final accounts = await accountsApi.listAccounts();

      expect(capturedRequest!.url.path, '/accounts');
      expect(accounts, hasLength(2));
      expect(accounts.first.id, 1);
      expect(accounts.first.name, 'Checking');
      expect(accounts.first.institution, 'Big Bank');
      expect(accounts.first.accountType, 'bank');
      expect(accounts[1].id, 2);
      expect(accounts[1].accountType, 'brokerage');
    });

    test('getAccount parses a GET /accounts/{id} response', () async {
      http.Request? capturedRequest;
      final mockClient = MockClient((request) async {
        capturedRequest = request;
        return http.Response(
          jsonEncode({
            'id': 5,
            'name': 'Brokerage',
            'institution': 'Big Bank',
            'account_type': 'brokerage',
            'created_at': '2026-02-01T00:00:00',
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
      final accountsApi = AccountsApi(apiClient);

      final account = await accountsApi.getAccount(5);

      expect(capturedRequest!.url.path, '/accounts/5');
      expect(account.id, 5);
      expect(account.name, 'Brokerage');
    });

    test('updateAccount sends only the fields that were passed', () async {
      http.Request? capturedRequest;
      final mockClient = MockClient((request) async {
        capturedRequest = request;
        return http.Response('{}', 200, headers: {'content-type': 'application/json'});
      });
      final apiClient = ApiClient(
        baseUrl: 'https://api.example.com',
        httpClient: mockClient,
        getToken: () => null,
        onUnauthorized: () {},
      );
      final accountsApi = AccountsApi(apiClient);

      await accountsApi.updateAccount(id: 5, name: 'New Name');

      expect(capturedRequest!.method, 'PATCH');
      expect(capturedRequest!.url.path, '/accounts/5');
      final body = jsonDecode(capturedRequest!.body) as Map<String, dynamic>;
      expect(body, {'name': 'New Name'});
    });

    test('deleteAccount sends a DELETE to /accounts/{id}', () async {
      http.Request? capturedRequest;
      final mockClient = MockClient((request) async {
        capturedRequest = request;
        return http.Response('', 204);
      });
      final apiClient = ApiClient(
        baseUrl: 'https://api.example.com',
        httpClient: mockClient,
        getToken: () => null,
        onUnauthorized: () {},
      );
      final accountsApi = AccountsApi(apiClient);

      await accountsApi.deleteAccount(5);

      expect(capturedRequest!.method, 'DELETE');
      expect(capturedRequest!.url.path, '/accounts/5');
    });

    test('listSnapshots parses a GET /accounts/{id}/snapshots response', () async {
      http.Request? capturedRequest;
      final mockClient = MockClient((request) async {
        capturedRequest = request;
        return http.Response(
          jsonEncode([
            {
              'id': 1,
              'taken_at': '2026-11-08',
              'created_at': '2026-11-08T12:00:00',
              'holdings': [
                {
                  'id': 1,
                  'label': 'VFV',
                  'asset_class': 'equity',
                  'quantity': 10.0,
                  'value': 1000.0,
                  'currency': 'CAD',
                  'country': 'CA',
                  'value_usd': 720.0,
                  'fx_rate_to_usd': 0.72,
                },
              ],
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
      final accountsApi = AccountsApi(apiClient);

      final snapshots = await accountsApi.listSnapshots(5);

      expect(capturedRequest!.url.path, '/accounts/5/snapshots');
      expect(snapshots, hasLength(1));
      expect(snapshots.first.holdings.first.label, 'VFV');
      expect(snapshots.first.holdings.first.valueUsd, 720.0);
    });
  });
}
