import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import 'api/accounts_api.dart';
import 'api/uploads_api.dart';
import 'auth/auth_service.dart';
import 'providers/account_detail_provider.dart';
import 'providers/upload_flow_provider.dart';
import 'screens/account_detail_screen.dart';
import 'screens/dashboard_screen.dart';
import 'screens/home_shell.dart';
import 'screens/insights_screen.dart';
import 'screens/login_screen.dart';
import 'screens/upload_review_screen.dart';
import 'services/document_picker_service.dart';
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
/// [imagePickerService]/[documentPickerService] override the dashboard's
/// camera-FAB/import-statement pickers; only tests pass them (the real
/// pickers need a browser).
GoRouter buildRouter(
  AuthService authService, {
  ImagePickerService? imagePickerService,
  DocumentPickerService? documentPickerService,
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
              builder: (c, s) => DashboardScreen(
                imagePickerService: imagePickerService,
                documentPickerService: documentPickerService,
              ),
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
        // A fresh AccountDetailProvider per visit, loaded for whichever
        // account id is in the path — same per-visit pattern as /upload.
        GoRoute(
          path: '/accounts/:id',
          builder: (c, s) => ChangeNotifierProvider<AccountDetailProvider>(
            create: (ctx) => AccountDetailProvider(accountsApi: ctx.read<AccountsApiBase>())
              ..load(int.parse(s.pathParameters['id']!)),
            child: const AccountDetailScreen(),
          ),
        ),
      ],
    );
