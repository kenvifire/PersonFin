import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:personfin/api/api_client.dart';
import 'package:personfin/api/auth_api.dart';
import 'package:personfin/auth/auth_service.dart';
import 'package:personfin/auth/google_auth_service.dart';
import 'package:personfin/models/user.dart';
import 'package:personfin/screens/login_screen.dart';

class FakeGoogleAuthService implements GoogleAuthService {
  Future<String?> Function()? onSignIn;

  @override
  Future<String?> signIn() {
    final handler = onSignIn;
    if (handler != null) return handler();
    return Future.value('fake-id-token');
  }
}

class FakeAuthApi implements AuthApiBase {
  String? lastIdToken;
  Future<(String, AppUser)> Function(String idToken)? onLoginWithGoogle;

  @override
  Future<(String accessToken, AppUser user)> loginWithGoogle(
      String idToken) {
    lastIdToken = idToken;
    final handler = onLoginWithGoogle;
    if (handler != null) return handler(idToken);
    return Future.value(('fake-token', AppUser(id: 1, email: 'test@example.com')));
  }
}

Future<AuthService> buildAuthService(AuthApiBase authApi) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  return AuthService(authApi: authApi, prefs: prefs);
}

Widget buildSubject({
  required GoogleAuthService googleAuthService,
  required AuthService authService,
}) {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<AuthService>.value(value: authService),
      Provider<GoogleAuthService>.value(value: googleAuthService),
    ],
    child: const MaterialApp(home: LoginScreen()),
  );
}

void main() {
  group('LoginScreen', () {
    testWidgets(
        'tapping Sign in with Google calls AuthService.loginWithGoogle with the returned token',
        (tester) async {
      final fakeAuthApi = FakeAuthApi();
      final authService = await buildAuthService(fakeAuthApi);
      final googleAuthService = FakeGoogleAuthService()
        ..onSignIn = () => Future.value('returned-id-token');

      await tester.pumpWidget(buildSubject(
        googleAuthService: googleAuthService,
        authService: authService,
      ));
      await tester.tap(find.text('Sign in with Google'));
      await tester.pumpAndSettle();

      expect(fakeAuthApi.lastIdToken, 'returned-id-token');
      expect(authService.isAuthenticated, isTrue);
    });

    testWidgets(
        'shows a SnackBar when GoogleAuthService.signIn returns null (user cancelled) without calling loginWithGoogle',
        (tester) async {
      final fakeAuthApi = FakeAuthApi();
      final authService = await buildAuthService(fakeAuthApi);
      final googleAuthService = FakeGoogleAuthService()
        ..onSignIn = () => Future.value(null);

      await tester.pumpWidget(buildSubject(
        googleAuthService: googleAuthService,
        authService: authService,
      ));
      await tester.tap(find.text('Sign in with Google'));
      await tester.pumpAndSettle();

      expect(fakeAuthApi.lastIdToken, isNull);
      expect(authService.isAuthenticated, isFalse);
      expect(find.byType(SnackBar), findsOneWidget);
    });

    testWidgets(
        'shows a SnackBar with the error message when loginWithGoogle throws an ApiException',
        (tester) async {
      final fakeAuthApi = FakeAuthApi()
        ..onLoginWithGoogle = (_) async {
          throw ApiException(401, 'Invalid Google token');
        };
      final authService = await buildAuthService(fakeAuthApi);
      final googleAuthService = FakeGoogleAuthService();

      await tester.pumpWidget(buildSubject(
        googleAuthService: googleAuthService,
        authService: authService,
      ));
      await tester.tap(find.text('Sign in with Google'));
      await tester.pumpAndSettle();

      expect(authService.isAuthenticated, isFalse);
      expect(find.text('Invalid Google token'), findsOneWidget);
    });
  });
}
