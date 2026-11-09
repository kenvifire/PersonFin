import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:personfin/api/auth_api.dart';
import 'package:personfin/auth/auth_service.dart';
import 'package:personfin/models/user.dart';

class FakeAuthApi implements AuthApiBase {
  String? lastIdToken;
  (String, AppUser) Function(String idToken)? onLoginWithGoogle;

  @override
  Future<(String accessToken, AppUser user)> loginWithGoogle(
      String idToken) async {
    lastIdToken = idToken;
    final handler = onLoginWithGoogle;
    if (handler != null) {
      return handler(idToken);
    }
    return ('fake-token', AppUser(id: 1, email: 'test@example.com'));
  }
}

void main() {
  group('AuthService', () {
    test('isAuthenticated is false and token is null before any login',
        () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final service = AuthService(authApi: FakeAuthApi(), prefs: prefs);

      expect(service.token, isNull);
      expect(service.user, isNull);
      expect(service.isAuthenticated, isFalse);
    });

    test('loginWithGoogle stores token and user and notifies listeners',
        () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final fakeAuthApi = FakeAuthApi();
      final service = AuthService(authApi: fakeAuthApi, prefs: prefs);
      var notifyCount = 0;
      service.addListener(() => notifyCount++);

      await service.loginWithGoogle('id-token-xyz');

      expect(fakeAuthApi.lastIdToken, 'id-token-xyz');
      expect(service.token, 'fake-token');
      expect(service.user?.id, 1);
      expect(service.user?.email, 'test@example.com');
      expect(service.isAuthenticated, isTrue);
      expect(notifyCount, greaterThanOrEqualTo(1));
    });

    test('loginWithGoogle persists the token to SharedPreferences', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final service = AuthService(authApi: FakeAuthApi(), prefs: prefs);

      await service.loginWithGoogle('id-token-xyz');

      expect(prefs.getString('session_token'), 'fake-token');
    });

    test(
        'a fresh AuthService restores token from SharedPreferences set by a prior session',
        () async {
      SharedPreferences.setMockInitialValues({'session_token': 'old-token'});
      final prefs = await SharedPreferences.getInstance();
      final service = AuthService(authApi: FakeAuthApi(), prefs: prefs);

      expect(service.token, 'old-token');
      expect(service.isAuthenticated, isTrue);
      expect(service.user, isNull);
    });

    test(
        'logout clears token and user, removes the persisted token, and notifies listeners',
        () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final service = AuthService(authApi: FakeAuthApi(), prefs: prefs);
      await service.loginWithGoogle('id-token-xyz');
      var notifyCount = 0;
      service.addListener(() => notifyCount++);

      service.logout();

      expect(service.token, isNull);
      expect(service.user, isNull);
      expect(service.isAuthenticated, isFalse);
      expect(prefs.getString('session_token'), isNull);
      expect(notifyCount, greaterThanOrEqualTo(1));
    });
  });
}
