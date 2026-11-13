import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import 'api/accounts_api.dart';
import 'api/uploads_api.dart';
import 'auth/auth_service.dart';
import 'providers/upload_flow_provider.dart';
import 'screens/dashboard_screen.dart';
import 'screens/home_shell.dart';
import 'screens/insights_screen.dart';
import 'screens/login_screen.dart';
import 'screens/upload_review_screen.dart';
import 'services/image_picker_service.dart';

/// Builds the app's [GoRouter], gating every route except `/login` behind
/// [AuthService.isAuthenticated].
///
/// `refreshListenable: authService` is what makes the gate reactive: any
/// `notifyListeners()` call on [authService] — including the one inside
/// `AuthService.logout()`, which `ApiClient`'s `onUnauthorized` callback
/// triggers on any 401 — causes the router to re-run `redirect` and send an
/// unauthenticated user back to `/login`.
///
/// [imagePickerService] overrides the dashboard's camera-FAB picker; only
/// tests pass it (the real picker needs a browser).
GoRouter buildRouter(
  AuthService authService, {
  ImagePickerService? imagePickerService,
}) =>
    GoRouter(
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
              builder: (c, s) => DashboardScreen(imagePickerService: imagePickerService),
            ),
            GoRoute(
              path: '/insights',
              builder: (c, s) => const InsightsScreen(),
            ),
          ],
        ),
        // A fresh UploadFlowProvider per visit: every push of /upload starts
        // in `picking`, and the provider is disposed when the route pops.
        // The route builder's context sits below MyApp's MultiProvider, so
        // the API dependencies are readable here. `extra` carries the image
        // the dashboard's FAB already picked before pushing this route.
        GoRoute(
          path: '/upload',
          builder: (c, s) => ChangeNotifierProvider<UploadFlowProvider>(
            create: (ctx) => UploadFlowProvider(
              uploadsApi: ctx.read<UploadsApiBase>(),
              accountsApi: ctx.read<AccountsApiBase>(),
            ),
            child: UploadReviewScreen(
              picked: s.extra as ({List<int> bytes, String filename, String mimeType})?,
            ),
          ),
        ),
      ],
    );
