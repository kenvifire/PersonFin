import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:personfin/api/auth_api.dart';
import 'package:personfin/auth/auth_service.dart';
import 'package:personfin/models/user.dart';
import 'package:personfin/widgets/sign_out_button.dart';

class _FakeAuthApi implements AuthApiBase {
  @override
  Future<(String, AppUser)> loginWithGoogle(String idToken) async =>
      ('token', AppUser(id: 1, email: 'a@example.com'));
}

void main() {
  testWidgets('tapping Sign out calls AuthService.logout()', (tester) async {
    SharedPreferences.setMockInitialValues({'session_token': 'token'});
    final prefs = await SharedPreferences.getInstance();
    final authService = AuthService(authApi: _FakeAuthApi(), prefs: prefs);
    expect(authService.isAuthenticated, isTrue);
    var notified = 0;
    authService.addListener(() => notified++);

    await tester.pumpWidget(ChangeNotifierProvider<AuthService>.value(
      value: authService,
      child: MaterialApp(
        home: Scaffold(appBar: AppBar(actions: const [SignOutButton()])),
      ),
    ));
    await tester.tap(find.byTooltip('Sign out'));
    await tester.pump();

    expect(authService.isAuthenticated, isFalse);
    expect(prefs.getString('session_token'), isNull);
    expect(notified, 1);
  });
}
