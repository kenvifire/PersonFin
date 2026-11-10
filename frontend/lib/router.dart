import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'auth/auth_service.dart';
import 'screens/dashboard_screen.dart';
import 'screens/home_shell.dart';
import 'screens/login_screen.dart';

// Trivial placeholders. Replaced wholesale by Task 9 (UploadReviewScreen)
// and Task 11 (InsightsScreen) at lib/screens/upload_review_screen.dart and
// lib/screens/insights_screen.dart respectively.
class InsightsScreen extends StatelessWidget {
  const InsightsScreen({super.key});

  @override
  Widget build(BuildContext context) => const Scaffold(body: Text('TODO'));
}

class UploadReviewScreen extends StatelessWidget {
  const UploadReviewScreen({super.key});

  @override
  Widget build(BuildContext context) => const Scaffold(body: Text('TODO'));
}

/// Builds the app's [GoRouter], gating every route except `/login` behind
/// [AuthService.isAuthenticated].
///
/// `refreshListenable: authService` is what makes the gate reactive: any
/// `notifyListeners()` call on [authService] — including the one inside
/// `AuthService.logout()`, which `ApiClient`'s `onUnauthorized` callback
/// triggers on any 401 — causes the router to re-run `redirect` and send an
/// unauthenticated user back to `/login`.
GoRouter buildRouter(AuthService authService) => GoRouter(
      refreshListenable: authService,
      redirect: (context, state) {
        final loggedIn = authService.isAuthenticated;
        final loggingIn = state.matchedLocation == '/login';
        // go_router's default initial location is `/` (no route defines
        // it), which is exactly what a normal return visit to the app's
        // domain loads. Without this, an authenticated user landing there
        // hits neither branch below, redirect() returns null, and go_router
        // fails to match `/` against any route — an error page instead of
        // the dashboard.
        final atRoot = state.matchedLocation == '/';
        if (!loggedIn && !loggingIn) return '/login';
        if (loggedIn && (loggingIn || atRoot)) return '/dashboard';
        return null;
      },
      routes: [
        GoRoute(path: '/login', builder: (c, s) => const LoginScreen()),
        ShellRoute(
          builder: (c, s, child) => HomeShell(child: child),
          routes: [
            GoRoute(
              path: '/dashboard',
              builder: (c, s) => const DashboardScreen(),
            ),
            GoRoute(
              path: '/insights',
              builder: (c, s) => const InsightsScreen(),
            ),
          ],
        ),
        GoRoute(path: '/upload', builder: (c, s) => const UploadReviewScreen()),
      ],
    );
