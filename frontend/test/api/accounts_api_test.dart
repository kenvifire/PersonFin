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
  });
}
