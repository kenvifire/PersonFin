import 'package:flutter/material.dart';
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
import 'providers/upload_flow_provider.dart';
import 'router.dart';
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

class MyApp extends StatelessWidget {
  final AuthService authService;
  final GoogleAuthService googleAuthService;
  final DashboardApiBase dashboardApi;
  final TargetsApiBase targetsApi;
  final InsightsApiBase insightsApi;
  final TodosApiBase todosApi;
  final UploadsApiBase uploadsApi;
  final AccountsApiBase accountsApi;

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
  });

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<AuthService>.value(value: authService),
        Provider<GoogleAuthService>.value(value: googleAuthService),
        ChangeNotifierProvider<DashboardProvider>(
          create: (_) => DashboardProvider(
            dashboardApi: dashboardApi,
            targetsApi: targetsApi,
          )..load(),
        ),
        ChangeNotifierProvider<InsightsProvider>(
          create: (_) => InsightsProvider(
            insightsApi: insightsApi,
            targetsApi: targetsApi,
          )..load(),
        ),
        ChangeNotifierProvider<TodosProvider>(
          create: (_) => TodosProvider(todosApi: todosApi)..load(),
        ),
        ChangeNotifierProvider<UploadFlowProvider>(
          create: (_) => UploadFlowProvider(
            uploadsApi: uploadsApi,
            accountsApi: accountsApi,
          ),
        ),
      ],
      child: MaterialApp.router(
        title: 'PersonFin',
        themeMode: ThemeMode.system,
        theme: buildAppTheme(Brightness.light),
        darkTheme: buildAppTheme(Brightness.dark),
        routerConfig: buildRouter(authService),
      ),
    );
  }
}
