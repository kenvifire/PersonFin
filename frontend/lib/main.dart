import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api/api_client.dart';
import 'api/auth_api.dart';
import 'auth/auth_service.dart';
import 'auth/google_auth_service.dart';
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

  runApp(MyApp(authService: authService, googleAuthService: googleAuthService));
}

class MyApp extends StatelessWidget {
  final AuthService authService;
  final GoogleAuthService googleAuthService;

  const MyApp({
    super.key,
    required this.authService,
    required this.googleAuthService,
  });

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<AuthService>.value(value: authService),
        Provider<GoogleAuthService>.value(value: googleAuthService),
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
