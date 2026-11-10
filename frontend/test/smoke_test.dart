import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:personfin/api/auth_api.dart';
import 'package:personfin/auth/auth_service.dart';
import 'package:personfin/auth/google_auth_service.dart';
import 'package:personfin/main.dart';
import 'package:personfin/models/user.dart';

class FakeAuthApi implements AuthApiBase {
  @override
  Future<(String accessToken, AppUser user)> loginWithGoogle(
      String idToken) async {
    return ('fake-token', AppUser(id: 1, email: 'test@example.com'));
  }
}

class FakeGoogleAuthService implements GoogleAuthService {
  @override
  Future<String?> signIn() async => null;
}

void main() {
  testWidgets(
      'app builds and shows the login screen when no session is persisted',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final authService = AuthService(authApi: FakeAuthApi(), prefs: prefs);

    await tester.pumpWidget(MyApp(
      authService: authService,
      googleAuthService: FakeGoogleAuthService(),
    ));
    await tester.pumpAndSettle();

    expect(find.text('PersonFin'), findsOneWidget);
    expect(find.text('Sign in with Google'), findsOneWidget);
  });
}
