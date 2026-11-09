import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:personfin/api/api_client.dart';
import 'package:personfin/api/auth_api.dart';

void main() {
  group('AuthApi', () {
    test(
        'loginWithGoogle posts id_token and returns the access token and parsed user',
        () async {
      http.Request? capturedRequest;
      final mockClient = MockClient((request) async {
        capturedRequest = request;
        return http.Response(
          jsonEncode({
            'access_token': 'abc123',
            'user': {'id': 1, 'email': 'test@example.com'},
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
      final authApi = AuthApi(apiClient);

      final (accessToken, user) = await authApi.loginWithGoogle('id-token-xyz');

      expect(capturedRequest!.url.path, '/auth/google');
      expect(
        jsonDecode(capturedRequest!.body),
        {'id_token': 'id-token-xyz'},
      );
      expect(accessToken, 'abc123');
      expect(user.id, 1);
      expect(user.email, 'test@example.com');
    });
  });
}
