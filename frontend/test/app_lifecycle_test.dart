// App-level (MyApp) tests for session-scoped state: the providers that
// hold per-user data must be reset on sign-out / 401 and reloaded on
// sign-in, and the upload flow must start fresh on every visit to /upload.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:personfin/api/api_client.dart';
import 'package:personfin/api/auth_api.dart';
import 'package:personfin/api/dashboard_api.dart';
import 'package:personfin/api/insights_api.dart';
import 'package:personfin/api/targets_api.dart';
import 'package:personfin/api/todos_api.dart';
import 'package:personfin/auth/auth_service.dart';
import 'package:personfin/main.dart';
import 'package:personfin/models/allocation_target.dart';
import 'package:personfin/models/dashboard.dart';
import 'package:personfin/models/drift_flag.dart';
import 'package:personfin/models/insights.dart';
import 'package:personfin/models/todo.dart';
import 'package:personfin/models/user.dart';
import 'package:personfin/providers/dashboard_provider.dart';
import 'package:personfin/providers/upload_flow_provider.dart';
import 'package:personfin/screens/dashboard_screen.dart';
import 'package:personfin/screens/insights_screen.dart';
import 'package:personfin/screens/upload_review_screen.dart';
import 'package:personfin/widgets/net_worth_hero.dart';

import 'fakes.dart' show FakeGoogleAuthService, FakeImagePickerService;
import 'providers/upload_flow_provider_test.dart'
    show FakeUploadsApi, FakeAccountsApi, extractedRecord;

/// Stands in for the backend: which user a request belongs to is decided by
/// the session token the app currently holds (exactly as the real backend
/// does via the Authorization header). A token in [expiredTokens] behaves
/// like the real ApiClient on a 401: it calls `onUnauthorized` (i.e.
/// `AuthService.logout()`) and throws.
class FakeBackend {
  late AuthService authService;
  final Set<String> expiredTokens = {};

  /// When set, every data request waits for it — lets a test look at the
  /// frames rendered while a new session's loads are still in flight.
  Completer<void>? gate;

  Future<void> respond() async => await gate?.future;

  /// Google ID token -> backend session token / user.
  static const _sessions = {
    'google-alice': ('token-alice', 1, 'alice@example.com'),
    'google-bob': ('token-bob', 2, 'bob@example.com'),
  };

  /// Session token -> that user's net worth.
  static const netWorths = {'token-alice': 1111.0, 'token-bob': 2222.0};

  String _userToken() {
    final token = authService.token;
    if (token == null || expiredTokens.contains(token)) {
      authService.logout();
      throw ApiException(401, 'Session expired');
    }
    return token;
  }

  DashboardData dashboard(String currency) => DashboardData(
        netWorth: netWorths[_userToken()]!,
        currency: currency,
        byAssetClass: {'equity': netWorths[authService.token]!},
        byCountry: {'CA': netWorths[authService.token]!},
        accounts: [],
        trend: [],
      );
}

class BackendAuthApi implements AuthApiBase {
  @override
  Future<(String, AppUser)> loginWithGoogle(String idToken) async {
    final (token, id, email) = FakeBackend._sessions[idToken]!;
    return (token, AppUser(id: id, email: email));
  }
}

class BackendDashboardApi implements DashboardApiBase {
  final FakeBackend backend;
  BackendDashboardApi(this.backend);

  @override
  Future<DashboardData> getDashboard(String currency) async {
    await backend.respond();
    return backend.dashboard(currency);
  }
}

class BackendTargetsApi implements TargetsApiBase {
  final FakeBackend backend;
  BackendTargetsApi(this.backend);

  @override
  Future<List<DriftFlag>> getDrift(String currency) async {
    await backend.respond();
    backend._userToken();
    return [];
  }

  @override
  Future<List<AllocationTarget>> listTargets() async {
    await backend.respond();
    backend._userToken();
    return [AllocationTarget(id: 1, assetClass: 'equity', targetPct: 100, isUserSet: true)];
  }

  @override
  Future<AllocationTarget> updateTarget(String assetClass, double targetPct) async {
    backend._userToken();
    return AllocationTarget(id: 1, assetClass: assetClass, targetPct: targetPct, isUserSet: true);
  }
}

class BackendInsightsApi implements InsightsApiBase {
  final FakeBackend backend;
  BackendInsightsApi(this.backend);

  @override
  Future<InsightsData> getInsights(String currency) async {
    await backend.respond();
    final token = backend._userToken();
    return InsightsData(
      dashboard: backend.dashboard(currency),
      drift: [],
      narrative: InsightsNarrative(summary: 'Narrative for $token', actionItems: []),
      narrativeUnavailable: false,
    );
  }
}

class BackendTodosApi implements TodosApiBase {
  final FakeBackend backend;
  BackendTodosApi(this.backend);

  @override
  Future<List<TodoItem>> listTodos() async {
    await backend.respond();
    final token = backend._userToken();
    return [TodoItem(id: 1, description: 'Todo for $token', done: false, relatedAssetClass: null)];
  }

  @override
  Future<TodoItem> createTodo({required String description, String? relatedAssetClass}) =>
      throw UnimplementedError();

  @override
  Future<TodoItem> setDone(int id, bool done) => throw UnimplementedError();

  @override
  Future<void> deleteTodo(int id) => throw UnimplementedError();
}

class Harness {
  final FakeBackend backend;
  final AuthService authService;
  final FakeGoogleAuthService google;
  final FakeImagePickerService imagePicker;
  final Widget app;

  Harness._(this.backend, this.authService, this.google, this.imagePicker, this.app);

  static Future<Harness> create({String? persistedToken}) async {
    SharedPreferences.setMockInitialValues(
      persistedToken == null ? {} : {'session_token': persistedToken},
    );
    final prefs = await SharedPreferences.getInstance();
    final backend = FakeBackend();
    final authService = AuthService(authApi: BackendAuthApi(), prefs: prefs);
    backend.authService = authService;
    final google = FakeGoogleAuthService();
    final imagePicker = FakeImagePickerService(
      result: (bytes: [1, 2, 3], filename: 'shot.png', mimeType: 'image/png'),
    );
    final app = MyApp(
      authService: authService,
      googleAuthService: google,
      dashboardApi: BackendDashboardApi(backend),
      targetsApi: BackendTargetsApi(backend),
      insightsApi: BackendInsightsApi(backend),
      todosApi: BackendTodosApi(backend),
      uploadsApi: FakeUploadsApi(extractResult: extractedRecord()),
      accountsApi: FakeAccountsApi(),
      imagePickerService: imagePicker,
    );
    return Harness._(backend, authService, google, imagePicker, app);
  }

  Future<void> signInAs(WidgetTester tester, String googleIdToken) async {
    google.onSignIn = () async => googleIdToken;
    await tester.tap(find.text('Sign in with Google'));
    await tester.pumpAndSettle();
  }
}

void main() {
  testWidgets(
      'an expired persisted session lands on /login with no stale error, and signing in '
      'again shows fresh dashboard data instead of the old 401 error', (tester) async {
    final harness = await Harness.create(persistedToken: 'token-stale');
    harness.backend.expiredTokens.add('token-stale');

    await tester.pumpWidget(harness.app);
    await tester.pumpAndSettle();

    expect(harness.authService.isAuthenticated, isFalse);
    expect(find.text('Sign in with Google'), findsOneWidget);

    await harness.signInAs(tester, 'google-alice');

    expect(find.text('Dashboard'), findsWidgets);
    expect(heroText('1,111'), findsOneWidget);
    expect(find.text('Session expired'), findsNothing);
    expect(find.text('Retry'), findsNothing);

    // Insights/to-dos were reloaded for the new session too.
    await tester.tap(find.text('Insights').last);
    await tester.pumpAndSettle();
    expect(find.text('Narrative for token-alice'), findsOneWidget);
    expect(find.text('Todo for token-alice'), findsOneWidget);
    expect(find.text('Session expired'), findsNothing);
  });

  testWidgets(
      "after a sign-out, a different user signing in never sees the previous user's data",
      (tester) async {
    final harness = await Harness.create();
    await tester.pumpWidget(harness.app);
    await tester.pumpAndSettle();

    await harness.signInAs(tester, 'google-alice');
    expect(heroText('1,111'), findsOneWidget);
    await tester.tap(find.text('Insights').last);
    await tester.pumpAndSettle();
    expect(find.text('Narrative for token-alice'), findsOneWidget);

    // Sign out through the UI (the app-bar action on the Insights tab).
    await tester.tap(find.byTooltip('Sign out'));
    await tester.pumpAndSettle();
    expect(harness.authService.isAuthenticated, isFalse);
    expect(find.text('Sign in with Google'), findsOneWidget);

    // Bob signs in, with the backend holding his responses so the frames
    // rendered while his data is still loading can be inspected: none of
    // them may show Alice's data, on either tab.
    final gate = harness.backend.gate = Completer<void>();
    harness.google.onSignIn = () async => 'google-bob';
    await tester.tap(find.text('Sign in with Google'));
    // Fixed-duration pumps, not pumpAndSettle: the loading spinners
    // animate until the gate opens. 5 x 200ms also covers page transitions.
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.textContaining('1,111'), findsNothing);
    }
    expect(find.byType(DashboardScreen), findsOneWidget);
    expect(find.textContaining('1,111'), findsNothing);
    await tester.tap(find.text('Insights').last);
    // Fixed-duration pumps, not pumpAndSettle: the loading spinners
    // animate until the gate opens. 5 x 200ms also covers page transitions.
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.textContaining('1,111'), findsNothing);
    }
    expect(find.byType(InsightsScreen), findsOneWidget);
    expect(find.text('Narrative for token-alice'), findsNothing);
    expect(find.text('Todo for token-alice'), findsNothing);
    expect(find.textContaining('1,111'), findsNothing);
    await tester.tap(find.text('Dashboard').last);
    await tester.pump();

    gate.complete();
    await tester.pumpAndSettle();

    expect(heroText('2,222'), findsOneWidget);
    await tester.tap(find.text('Insights').last);
    await tester.pumpAndSettle();
    expect(find.text('Narrative for token-bob'), findsOneWidget);
    expect(find.text('Todo for token-bob'), findsOneWidget);
    expect(find.text('Narrative for token-alice'), findsNothing);
    expect(find.text('Todo for token-alice'), findsNothing);
  });

  testWidgets(
      "the dashboard's Sign out action logs out, returns to /login, and clears the "
      "session's data", (tester) async {
    final harness = await Harness.create();
    await tester.pumpWidget(harness.app);
    await tester.pumpAndSettle();
    await harness.signInAs(tester, 'google-alice');
    expect(heroText('1,111'), findsOneWidget);
    final dashboardProvider = Provider.of<DashboardProvider>(
      tester.element(find.byType(DashboardScreen)),
      listen: false,
    );
    expect(dashboardProvider.data, isNotNull);

    await tester.tap(find.byTooltip('Sign out'));
    await tester.pumpAndSettle();

    expect(harness.authService.isAuthenticated, isFalse);
    expect(harness.authService.token, isNull);
    expect(find.text('Sign in with Google'), findsOneWidget);
    expect(find.byType(DashboardScreen), findsNothing);
    expect(dashboardProvider.data, isNull);
    expect(dashboardProvider.state, LoadState.loading);
  });

  testWidgets('a second visit to /upload starts a fresh upload flow', (tester) async {
    final harness = await Harness.create();
    await tester.binding.setSurfaceSize(const Size(800, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(harness.app);
    await tester.pumpAndSettle();
    await harness.signInAs(tester, 'google-alice');

    // First upload: pick -> review form -> discard -> back on the dashboard.
    await tester.tap(find.byIcon(Icons.camera_alt));
    await tester.pumpAndSettle();
    expect(harness.imagePicker.callCount, 1);
    expect(find.text('AAPL'), findsOneWidget);
    final firstProvider = readUploadProvider(tester);
    await tester.tap(find.widgetWithText(OutlinedButton, 'Discard'));
    await tester.pumpAndSettle();
    expect(find.byType(UploadReviewScreen), findsNothing);
    expect(heroText('1,111'), findsOneWidget);

    // Second upload: the picker runs again and the form shows again,
    // rather than the screen replaying the first upload's terminal state.
    await tester.tap(find.byIcon(Icons.camera_alt));
    await tester.pumpAndSettle();
    expect(harness.imagePicker.callCount, 2);
    expect(find.byType(UploadReviewScreen), findsOneWidget);
    expect(find.text('AAPL'), findsOneWidget);
    final secondProvider = readUploadProvider(tester);
    expect(identical(firstProvider, secondProvider), isFalse);
    expect(secondProvider.state, UploadFlowState.ready);
  });
}

/// The dashboard's headline net-worth figure containing [amount].
Finder heroText(String amount) =>
    find.descendant(of: find.byType(NetWorthHero), matching: find.textContaining(amount));

UploadFlowProvider readUploadProvider(WidgetTester tester) => Provider.of<UploadFlowProvider>(
      tester.element(find.byType(UploadReviewScreen)),
      listen: false,
    );
