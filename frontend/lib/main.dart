import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api/accounts_api.dart';
import 'api/api_client.dart';
import 'api/auth_api.dart';
import 'api/dashboard_api.dart';
import 'api/insights_api.dart';
import 'api/targets_api.dart';
import 'api/todos_api.dart';
import 'api/uploads_api.dart';
import 'auth/auth_service.dart';
import 'auth/google_auth_service.dart';
import 'providers/dashboard_provider.dart';
import 'providers/insights_provider.dart';
import 'providers/todos_provider.dart';
import 'router.dart';
import 'services/document_picker_service.dart' show DocumentPickerService;
import 'services/image_picker_service.dart' show ImagePickerService;
import 'theme.dart';

/// Never hardcode the backend URL elsewhere — pass
/// `--dart-define=API_BASE_URL=...` when running/building.
const _apiBaseUrl = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: 'http://localhost:8000',
);

Future<void> main() async {
  final prefs = await SharedPreferences.getInstance();

  // `authService` is assigned below, but the closures below capture the
  // variable itself (not its value at closure-creation time), so ApiClient
  // can reference AuthService's token/logout before AuthService exists —
  // avoiding a circular constructor dependency between ApiClient and
  // AuthService.
  late AuthService authService;
  final apiClient = ApiClient(
    baseUrl: _apiBaseUrl,
    httpClient: http.Client(),
    getToken: () => authService.token,
    onUnauthorized: () => authService.logout(),
  );
  final authApi = AuthApi(apiClient);
  authService = AuthService(authApi: authApi, prefs: prefs);
  final googleAuthService = RealGoogleAuthService();

  final dashboardApi = DashboardApi(apiClient);
  final targetsApi = TargetsApi(apiClient);
  final insightsApi = InsightsApi(apiClient);
  final todosApi = TodosApi(apiClient);
  final uploadsApi = UploadsApi(apiClient);
  final accountsApi = AccountsApi(apiClient);

  runApp(MyApp(
    authService: authService,
    googleAuthService: googleAuthService,
    dashboardApi: dashboardApi,
    targetsApi: targetsApi,
    insightsApi: insightsApi,
    todosApi: todosApi,
    uploadsApi: uploadsApi,
    accountsApi: accountsApi,
  ));
}

class MyApp extends StatefulWidget {
  final AuthService authService;
  final GoogleAuthService googleAuthService;
  final DashboardApiBase dashboardApi;
  final TargetsApiBase targetsApi;
  final InsightsApiBase insightsApi;
  final TodosApiBase todosApi;
  final UploadsApiBase uploadsApi;
  final AccountsApiBase accountsApi;

  /// Overrides the dashboard's camera-FAB image picker; tests only.
  final ImagePickerService? imagePickerService;

  /// Overrides the dashboard's import-statement document picker; tests only.
  final DocumentPickerService? documentPickerService;

  const MyApp({
    super.key,
    required this.authService,
    required this.googleAuthService,
    required this.dashboardApi,
    required this.targetsApi,
    required this.insightsApi,
    required this.todosApi,
    required this.uploadsApi,
    required this.accountsApi,
    this.imagePickerService,
    this.documentPickerService,
  });

  @override
  State<MyApp> createState() => _MyAppState();
}

/// Owns the session-scoped providers and ties their lifecycle to
/// [AuthService]:
///
/// - signed in (at startup with a restored token, or on a fresh login):
///   load all three, so they fetch the *current* user's data;
/// - signed out (explicit sign-out, or a 401 anywhere via ApiClient's
///   `onUnauthorized`): reset all three to an empty `loading` state, so
///   neither a stale error screen nor the previous user's financial data
///   survives into the next sign-in.
///
/// [UploadFlowProvider] is not owned here — it's scoped to each visit to
/// `/upload` (see `buildRouter`).
class _MyAppState extends State<MyApp> {
  late final DashboardProvider _dashboardProvider;
  late final InsightsProvider _insightsProvider;
  late final TodosProvider _todosProvider;
  late final GoRouter _router;
  late bool _wasAuthenticated;

  @override
  void initState() {
    super.initState();
    _dashboardProvider = DashboardProvider(
      dashboardApi: widget.dashboardApi,
      targetsApi: widget.targetsApi,
    );
    _insightsProvider = InsightsProvider(
      insightsApi: widget.insightsApi,
      targetsApi: widget.targetsApi,
    );
    _todosProvider = TodosProvider(todosApi: widget.todosApi);
    _router = buildRouter(
      widget.authService,
      imagePickerService: widget.imagePickerService,
      documentPickerService: widget.documentPickerService,
    );

    // Listen *before* the initial load: with an expired persisted token,
    // that load's 401 calls AuthService.logout(), and this listener must
    // see that transition — otherwise the next sign-in would look like
    // "still authenticated" and never trigger a reload.
    _wasAuthenticated = widget.authService.isAuthenticated;
    widget.authService.addListener(_onAuthChanged);
    if (_wasAuthenticated) _startSession();
  }

  void _onAuthChanged() {
    final isAuthenticated = widget.authService.isAuthenticated;
    if (isAuthenticated == _wasAuthenticated) return;
    _wasAuthenticated = isAuthenticated;
    if (isAuthenticated) {
      _startSession();
    } else {
      _resetSessionData();
    }
  }

  void _resetSessionData() {
    _dashboardProvider.reset();
    _insightsProvider.reset();
    _todosProvider.reset();
  }

  /// Resets first, so anything written while signed out (e.g. a 401 from a
  /// request that started after the sign-out) is cleared and any request
  /// still in flight from before is discarded; then loads the new
  /// session's data.
  void _startSession() {
    _resetSessionData();
    _dashboardProvider.load();
    _insightsProvider.load();
    _todosProvider.load();
  }

  @override
  void dispose() {
    widget.authService.removeListener(_onAuthChanged);
    _router.dispose();
    _dashboardProvider.dispose();
    _insightsProvider.dispose();
    _todosProvider.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<AuthService>.value(value: widget.authService),
        Provider<GoogleAuthService>.value(value: widget.googleAuthService),
        Provider<UploadsApiBase>.value(value: widget.uploadsApi),
        Provider<AccountsApiBase>.value(value: widget.accountsApi),
        ChangeNotifierProvider<DashboardProvider>.value(value: _dashboardProvider),
        ChangeNotifierProvider<InsightsProvider>.value(value: _insightsProvider),
        ChangeNotifierProvider<TodosProvider>.value(value: _todosProvider),
      ],
      child: MaterialApp.router(
        title: 'PersonFin',
        themeMode: ThemeMode.system,
        theme: buildAppTheme(Brightness.light),
        darkTheme: buildAppTheme(Brightness.dark),
        routerConfig: _router,
      ),
    );
  }
}
