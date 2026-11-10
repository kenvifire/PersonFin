import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:personfin/api/auth_api.dart';
import 'package:personfin/auth/auth_service.dart';
import 'package:personfin/models/user.dart';
import 'package:personfin/router.dart';

class FakeAuthApi implements AuthApiBase {
  @override
  Future<(String accessToken, AppUser user)> loginWithGoogle(
      String idToken) async {
    return ('fake-token', AppUser(id: 1, email: 'test@example.com'));
  }
}

Future<AuthService> buildAuthService() async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  return AuthService(authApi: FakeAuthApi(), prefs: prefs);
}

String currentLocation(GoRouter router) =>
    router.routerDelegate.currentConfiguration.uri.toString();

void main() {
  group('buildRouter', () {
    testWidgets(
        'an unauthenticated user hitting /dashboard directly is redirected to /login',
        (tester) async {
      final authService = await buildAuthService();
      final router = buildRouter(authService);

      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await tester.pumpAndSettle();

      router.go('/dashboard');
      await tester.pumpAndSettle();

      expect(currentLocation(router), '/login');
      expect(find.text('Sign in with Google'), findsOneWidget);
    });

    testWidgets('an authenticated user hitting /login is redirected to /dashboard',
        (tester) async {
      final authService = await buildAuthService();
      await authService.loginWithGoogle('id-token-xyz');
      final router = buildRouter(authService);

      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await tester.pumpAndSettle();

      router.go('/login');
      await tester.pumpAndSettle();

      expect(currentLocation(router), '/dashboard');
      expect(find.text('Sign in with Google'), findsNothing);
    });

    testWidgets(
        'an authenticated user whose initial location is / lands on /dashboard',
        (tester) async {
      // Regression: go_router's default initial location is `/` (no route
      // defines it — only /login, /dashboard, /insights, /upload exist),
      // which is exactly what a normal return visit to the app's domain
      // loads. Before the `atRoot` branch, an authenticated user landing at
      // `/` hit neither `redirect` branch, so no redirect happened and
      // go_router failed to match `/` against any route — an error page
      // instead of the dashboard.
      final authService = await buildAuthService();
      await authService.loginWithGoogle('id-token-xyz');
      final router = buildRouter(authService);

      // The app's default initial location (no explicit path given) is
      // already `/` — assert that lands correctly...
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await tester.pumpAndSettle();
      expect(currentLocation(router), '/dashboard');
      expect(find.text('Sign in with Google'), findsNothing);

      // ...and assert the same explicitly, independent of platform default
      // route behavior, by navigating to `/` directly.
      router.go('/');
      await tester.pumpAndSettle();
      expect(currentLocation(router), '/dashboard');
    });

    testWidgets(
        'calling authService.logout() while on /dashboard redirects to /login',
        (tester) async {
      // Review Focus: a 401 anywhere in the app triggers AuthService.logout()
      // via ApiClient's onUnauthorized callback; the router must react to
      // that by redirecting to /login, not leave the user stranded on an
      // authenticated-only screen.
      final authService = await buildAuthService();
      await authService.loginWithGoogle('id-token-xyz');
      final router = buildRouter(authService);

      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await tester.pumpAndSettle();
      router.go('/dashboard');
      await tester.pumpAndSettle();
      expect(currentLocation(router), '/dashboard');

      authService.logout();
      await tester.pumpAndSettle();

      expect(currentLocation(router), '/login');
      expect(find.text('Sign in with Google'), findsOneWidget);
    });
  });
}
