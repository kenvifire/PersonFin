# Flutter Frontend Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the Flutter web frontend — login, a mobile-first dashboard, the upload→review flow, and a combined insights/to-dos screen — consuming the already-complete backend REST API.

**Architecture:** A single Flutter web app under `frontend/`. A thin `ApiClient` wraps `package:http` and centralizes auth-header injection, 401 handling, and error mapping; one `*Api` class per backend router calls it and parses JSON into typed models; one `ChangeNotifier` provider per screen holds load/error/data state; `go_router` handles navigation and gates every route but `/login` behind an `AuthService` (also a `ChangeNotifier`) that persists the session token via `shared_preferences`. Google Sign-In is wrapped behind a small interface so widget tests never touch the real SDK.

**Tech Stack:** Flutter 3.38 (Dart 3.10) web target; `provider`, `http`, `go_router`, `shared_preferences`, `google_sign_in`, `fl_chart`, `image_picker`, `intl`. Backend: FastAPI (already built, see Spec).

**Spec:** `docs/superpowers/specs/2026-11-08-personal-finance-tracker-design.md` (see especially the "Frontend UX (decided during Plan 4 brainstorming)" section).

## Global Constraints

- Flutter **web** target only — no mobile app packaging in this plan.
- State management is `package:provider` with `ChangeNotifier` view-models. No Bloc/Riverpod.
- All HTTP goes through the single `ApiClient` built in Task 2 — no router/service ever calls `http` directly.
- Every external dependency (`ApiClient`'s own `http.Client`, Google Sign-In) is injected through an abstract interface so unit/widget tests use a fake, never the real network or SDK. This mirrors the backend's injectable-provider pattern (see Spec).
- Backend base URL comes from `const String.fromEnvironment('API_BASE_URL', defaultValue: 'http://localhost:8000')` — never hardcoded elsewhere.
- Currency set mirrors the backend exactly: `SUPPORTED_CURRENCIES = {CAD, USD, CNY, HKD, SGD}` (`app/services/fx.py`), and holdings additionally allow `CRYPTO` (`app/schemas/snapshot.py:ALLOWED_HOLDING_CURRENCIES`). Asset classes mirror `app/services/allocation.py:ASSET_CLASSES = {equity, cash, crypto, bond}`. Define these as Dart constants once (Task 6 for currencies, Task 8 for asset classes) — never re-fetched from the backend, which exposes no such listing endpoint.
- Default display currency is `CAD`, the user's home currency; user-switchable and persisted locally via `shared_preferences` (not sent to or stored by the backend — `GET /dashboard`/`/insights`/`/targets/drift` take `currency` as a plain query param with no server-side preference).
- Material 3, theme follows system light/dark (`ThemeMode.system`) — the dark mockups shown during brainstorming were the mockup tool's own styling, not a decided app-wide dark theme.
- Navigation: `go_router`, with a bottom tab bar (Dashboard / Insights) as the authenticated shell, per the approved design.
- Tests use `flutter_test` plus `package:http/testing.dart`'s `MockClient` for anything that would otherwise hit the network. No test may make a real HTTP call or invoke the real Google SDK.

## Review Focus

- **Expired/invalid session (401 from any endpoint):** the app must log the user out and land on `/login`, never show a raw error screen or loop. (Task 5)
- **FX outage (503 from `/dashboard`, `/targets/drift`, `/insights`):** the dashboard must show a retryable error state, not a blank screen or stale zeros. (Task 6)
- **Upload extraction failure:** `POST /uploads/{id}/extract` returns HTTP 200 with `status: "failed"` and `extraction_error` set — this is not an HTTP error, and the review screen must detect the failed status and present an empty, editable form with the error message, not treat 200 as "extraction succeeded." (Task 8)
- **Confirm/discard racing an already-finalized upload (409):** the review screen must show a clear "already handled" message and return to the dashboard, never crash. (Task 8)
- **Zero net worth / no holdings yet:** `GET /dashboard` with no snapshots returns `net_worth: 0` with empty breakdowns, and `GET /insights` returns its canned "no holdings yet" narrative — both must render as a deliberate empty state, not a zero-filled chart or blank screen. (Task 7)

## File Structure

```
backend/app/main.py                       # +CORS middleware (Task 1)

frontend/
  pubspec.yaml
  web/index.html
  lib/
    main.dart
    theme.dart
    router.dart
    api/
      api_client.dart
      auth_api.dart
      dashboard_api.dart
      targets_api.dart
      insights_api.dart
      todos_api.dart
      uploads_api.dart
      accounts_api.dart
    models/
      user.dart
      dashboard.dart
      drift_flag.dart
      allocation_target.dart
      insights.dart
      todo.dart
      account.dart
      extraction.dart
      upload.dart
      holding.dart
    auth/
      auth_service.dart
      google_auth_service.dart
    providers/
      dashboard_provider.dart
      insights_provider.dart
      todos_provider.dart
      upload_flow_provider.dart
    screens/
      login_screen.dart
      home_shell.dart
      dashboard_screen.dart
      insights_screen.dart
      upload_review_screen.dart
    widgets/
      net_worth_hero.dart
      trend_sparkline.dart
      drift_alert_banner.dart
      account_breakdown_list.dart
      currency_switcher.dart
      allocation_bar.dart
      todo_list_tile.dart
  test/
    api/api_client_test.dart
    api/auth_api_test.dart
    api/dashboard_api_test.dart
    api/targets_api_test.dart
    api/insights_api_test.dart
    api/todos_api_test.dart
    api/uploads_api_test.dart
    api/accounts_api_test.dart
    auth/auth_service_test.dart
    providers/dashboard_provider_test.dart
    providers/insights_provider_test.dart
    providers/todos_provider_test.dart
    providers/upload_flow_provider_test.dart
    screens/login_screen_test.dart
    screens/dashboard_screen_test.dart
    screens/insights_screen_test.dart
    screens/upload_review_screen_test.dart
    router_test.dart
    smoke_test.dart
```

---

### Task 1: Backend CORS for local frontend development

The Flutter web dev server (`flutter run -d chrome`) runs on a different origin than the backend (`localhost:8000`), so the browser blocks every API call unless the backend sends CORS headers. Production (Plan 5) serves both through the same nginx origin and needs no CORS header, but local development needs this now to let later tasks be manually verified against the real backend.

**Files:**
- Modify: `backend/app/main.py`
- Test: `backend/tests/test_cors.py`

**Interfaces:**
- Produces: nothing other services depend on — this only adds response headers.

- [ ] **Step 1: Write the failing test**

```python
def test_cors_allows_localhost_origin(client):
    response = client.get(
        "/health",
        headers={"Origin": "http://localhost:5173"},
    )
    assert response.headers["access-control-allow-origin"] == "http://localhost:5173"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend && pytest tests/test_cors.py -v`
Expected: FAIL (no `access-control-allow-origin` header)

- [ ] **Step 3: Add `CORSMiddleware` in `backend/app/main.py`**

Add, right after `app = FastAPI(...)`:

```python
from fastapi.middleware.cors import CORSMiddleware

app.add_middleware(
    CORSMiddleware,
    allow_origin_regex=r"http://localhost:\d+",
    allow_methods=["*"],
    allow_headers=["*"],
)
```

`allow_origin_regex` (not a fixed origin list) because `flutter run -d chrome` picks a random local port each run.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd backend && pytest tests/test_cors.py -v`
Expected: PASS

- [ ] **Step 5: Run the full backend suite to confirm no regression**

Run: `cd backend && pytest`
Expected: all tests pass (187 + 1 new)

- [ ] **Step 6: Commit**

```bash
git add backend/app/main.py backend/tests/test_cors.py
git commit -m "feat: allow localhost CORS for Flutter web dev server"
```

---

### Task 2: Flutter project scaffold

**Files:**
- Create: `frontend/pubspec.yaml`, `frontend/web/index.html`, `frontend/lib/main.dart`, `frontend/lib/theme.dart`
- Test: `frontend/test/smoke_test.dart`

**Interfaces:**
- Produces: a running Flutter web project every later task adds to. `main.dart`'s `MyApp` widget is replaced in Task 5 once the router exists — this task's `main.dart` just renders a placeholder so the project builds and has one passing test.

- [ ] **Step 1: Create the Flutter project**

```bash
cd /Users/kenvi/code/PersonFin
flutter create --platforms=web --org com.personfin --project-name personfin frontend
```

- [ ] **Step 2: Add dependencies to `frontend/pubspec.yaml`**

```bash
cd frontend
flutter pub add provider http go_router shared_preferences google_sign_in fl_chart image_picker intl
```

- [ ] **Step 3: Write `frontend/lib/theme.dart`**

```dart
ThemeData buildAppTheme(Brightness brightness) {
  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorSchemeSeed: Colors.blue,
  );
}
```

- [ ] **Step 4: Write `frontend/lib/main.dart`** with a minimal `MaterialApp` (`themeMode: ThemeMode.system`, `theme: buildAppTheme(Brightness.light)`, `darkTheme: buildAppTheme(Brightness.dark)`) whose `home` is a `Scaffold` showing the text `"PersonFin"` — a placeholder Task 5 replaces with `MaterialApp.router`.

- [ ] **Step 5: Write the failing smoke test**

```dart
// frontend/test/smoke_test.dart
testWidgets('app builds and shows placeholder text', (tester) async {
  await tester.pumpWidget(const MyApp());
  expect(find.text('PersonFin'), findsOneWidget);
});
```

- [ ] **Step 6: Run test to verify it fails**

Run: `cd frontend && flutter test test/smoke_test.dart`
Expected: FAIL (`MyApp` not defined yet, or text not found)

- [ ] **Step 7: Make `main.dart` match, run test to verify it passes**

Run: `cd frontend && flutter test test/smoke_test.dart`
Expected: PASS

- [ ] **Step 8: Verify the app actually runs in a browser**

Run: `cd frontend && flutter run -d chrome` — confirm the page loads and shows "PersonFin", then stop it.

- [ ] **Step 9: Commit**

```bash
git add frontend/
git commit -m "feat: scaffold Flutter web frontend project"
```

---

### Task 3: API client core

**Files:**
- Create: `frontend/lib/api/api_client.dart`
- Test: `frontend/test/api/api_client_test.dart`

**Interfaces:**
- Produces:
  ```dart
  class ApiException implements Exception {
    final int statusCode; // 0 means no HTTP response at all (network/offline)
    final String message;
    ApiException(this.statusCode, this.message);
  }

  class ApiClient {
    ApiClient({
      required String baseUrl,
      required http.Client httpClient,
      required String? Function() getToken,
      required void Function() onUnauthorized,
    });

    Future<dynamic> get(String path, {Map<String, String>? query});
    Future<dynamic> post(String path, {Object? body});
    Future<dynamic> patch(String path, {Object? body});
    Future<dynamic> delete(String path);
    Future<dynamic> postMultipart(
      String path, {
      required List<int> bytes,
      required String filename,
      required String fieldName, // "file", matching the backend's UploadFile param name
      required String contentType,
    });
  }
  ```
  Every method: builds `Uri.parse(baseUrl + path).replace(queryParameters: query)`; sets header `Authorization: Bearer <token>` when `getToken()` is non-null; for `post`/`patch` with a `body`, encodes it as JSON with `Content-Type: application/json`. On any response with `statusCode == 401`, calls `onUnauthorized()` once, then throws `ApiException(401, ...)`. On any `statusCode >= 400`, parses the JSON body's `detail` field into `message` — `detail` is either a string (most errors) or a list of FastAPI validation-error objects (422s; join their `"msg"` fields with `"; "`) — and throws `ApiException(statusCode, message)`. On success with an empty body (204), returns `null`; otherwise returns `jsonDecode(response.body)`. If `httpClient` itself throws (`http.ClientException`, `SocketException`, etc. — no response at all), catches it and throws `ApiException(0, 'Network error — check your connection')`.
- Consumes: nothing — this is the foundation every later `*Api` class builds on.

- [ ] **Step 1: Write the failing tests** in `frontend/test/api/api_client_test.dart`, using `package:http/testing.dart`'s `MockClient`:

```dart
test('get() returns decoded JSON on 200', ...);
test('get() sends Authorization header when getToken returns a token', ...);
test('get() sends no Authorization header when getToken returns null', ...);
test('post() JSON-encodes the body and sets Content-Type', ...);
test('delete() returns null on 204 with empty body', ...);
test('any 401 response calls onUnauthorized exactly once and throws ApiException(401, ...)', ...);
test('a 422 with a list-shaped detail joins the validation messages into one string', ...);
test('a 503 throws ApiException(503, <detail string>)', ...);
test('a client-level exception (no response) throws ApiException(0, ...)', ...);
test('postMultipart() builds a multipart request with the given field name and content type', ...);
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd frontend && flutter test test/api/api_client_test.dart`
Expected: FAIL (`ApiClient`/`ApiException` not defined)

- [ ] **Step 3: Implement `ApiClient` and `ApiException`** in `frontend/lib/api/api_client.dart` per the Interfaces block above.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd frontend && flutter test test/api/api_client_test.dart`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add frontend/lib/api/api_client.dart frontend/test/api/api_client_test.dart
git commit -m "feat: add ApiClient with centralized auth and error handling"
```

---

### Task 4: Auth models, AuthApi, and AuthService

**Files:**
- Create: `frontend/lib/models/user.dart`, `frontend/lib/api/auth_api.dart`, `frontend/lib/auth/auth_service.dart`
- Test: `frontend/test/api/auth_api_test.dart`, `frontend/test/auth/auth_service_test.dart`

**Interfaces:**
- Consumes: `ApiClient` (Task 3).
- Produces:
  ```dart
  class AppUser {
    final int id;
    final String email;
    AppUser({required this.id, required this.email});
    factory AppUser.fromJson(Map<String, dynamic> json) =>
        AppUser(id: json['id'] as int, email: json['email'] as String);
  }

  abstract class AuthApiBase {
    Future<(String accessToken, AppUser user)> loginWithGoogle(String idToken);
  }

  class AuthApi implements AuthApiBase {
    AuthApi(ApiClient client);
    // POSTs {"id_token": idToken} to /auth/google, returns (body['access_token'], AppUser.fromJson(body['user'])).
  }

  class AuthService extends ChangeNotifier {
    AuthService({required AuthApiBase authApi, required SharedPreferences prefs});
    String? get token;
    AppUser? get user;
    bool get isAuthenticated; // token != null
    Future<void> loginWithGoogle(String idToken); // calls authApi, stores token+user, persists token to prefs under key "session_token", notifyListeners()
    void logout(); // clears token, user, removes "session_token" from prefs, notifyListeners()
  }
  ```
  On construction, `AuthService` reads `prefs.getString('session_token')` to restore an existing session (it does not restore `user`, since the backend has no "get current user" endpoint — `user` stays `null` until the next login; screens needing the user's email, if any, must tolerate `null`).

- [ ] **Step 1: Write the failing `AuthApi` test** (`MockClient`): `test('loginWithGoogle posts id_token and returns the access token and parsed user')`.

- [ ] **Step 2: Run it, confirm it fails, implement `AuthApi`, rerun to confirm it passes.**

Run: `cd frontend && flutter test test/api/auth_api_test.dart`

- [ ] **Step 3: Write the failing `AuthService` tests**, using a hand-written `class FakeAuthApi implements AuthApiBase` and `SharedPreferences.setMockInitialValues({})`:

```dart
test('isAuthenticated is false and token is null before any login', ...);
test('loginWithGoogle stores token and user and notifies listeners', ...);
test('loginWithGoogle persists the token to SharedPreferences', ...);
test('a fresh AuthService restores token from SharedPreferences set by a prior session', ...);
test('logout clears token and user, removes the persisted token, and notifies listeners', ...);
```

- [ ] **Step 4: Run tests to verify they fail**

Run: `cd frontend && flutter test test/auth/auth_service_test.dart`
Expected: FAIL (`AuthService` not defined)

- [ ] **Step 5: Implement `AuthService`**, run tests to verify they pass.

- [ ] **Step 6: Commit**

```bash
git add frontend/lib/models/user.dart frontend/lib/api/auth_api.dart frontend/lib/auth/auth_service.dart frontend/test/api/auth_api_test.dart frontend/test/auth/auth_service_test.dart
git commit -m "feat: add Google-login API and session-persisting AuthService"
```

---

### Task 5: Google Sign-In, login screen, router, and auth-gated shell

This is the task where 401 handling becomes user-visible (Review Focus: expired session), since it's the first place `ApiClient`, `AuthService`, and navigation all exist together.

**Files:**
- Create: `frontend/lib/auth/google_auth_service.dart`, `frontend/lib/screens/login_screen.dart`, `frontend/lib/screens/home_shell.dart`, `frontend/lib/router.dart`
- Modify: `frontend/lib/main.dart` (switch to `MaterialApp.router`, wire up `ApiClient`/`AuthService`/`GoogleAuthService` via `MultiProvider`)
- Test: `frontend/test/screens/login_screen_test.dart`, `frontend/test/router_test.dart`

**Interfaces:**
- Consumes: `AuthService` (Task 4), `ApiClient` (Task 3, for the `onUnauthorized` wiring).
- Produces:
  ```dart
  abstract class GoogleAuthService {
    Future<String?> signIn(); // returns an ID token, or null if the user cancelled
  }

  class RealGoogleAuthService implements GoogleAuthService {
    // Wraps package:google_sign_in. Uses GoogleSignIn(clientId: webClientId)
    // read from const String.fromEnvironment('GOOGLE_CLIENT_ID'); calls
    // .signIn(), then .authentication to get idToken.
  }
  ```
  `LoginScreen` takes `GoogleAuthService` via `Provider`, shows the app name and one "Sign in with Google" button; on tap, calls `googleAuthService.signIn()`, and if it returns a non-null token, calls `context.read<AuthService>().loginWithGoogle(token)`; shows a `SnackBar` with the error message on any thrown `ApiException` or a sign-in failure.

  `router.dart` exports a `GoRouter buildRouter(AuthService authService)`:
  ```dart
  GoRouter buildRouter(AuthService authService) => GoRouter(
    refreshListenable: authService,
    redirect: (context, state) {
      final loggedIn = authService.isAuthenticated;
      final loggingIn = state.matchedLocation == '/login';
      if (!loggedIn && !loggingIn) return '/login';
      if (loggedIn && loggingIn) return '/dashboard';
      return null;
    },
    routes: [
      GoRoute(path: '/login', builder: (c, s) => const LoginScreen()),
      ShellRoute(
        builder: (c, s, child) => HomeShell(child: child),
        routes: [
          GoRoute(path: '/dashboard', builder: (c, s) => const DashboardScreen()),
          GoRoute(path: '/insights', builder: (c, s) => const InsightsScreen()),
        ],
      ),
      GoRoute(path: '/upload', builder: (c, s) => const UploadReviewScreen()),
    ],
  );
  ```
  `DashboardScreen`/`InsightsScreen`/`UploadReviewScreen` don't exist yet (Tasks 7, 11, 9) — this task writes them as trivial placeholder widgets (`Scaffold(body: Text('TODO'))`) that those tasks replace; `router_test.dart`'s tests only need the redirect behavior, not real screen content.

  `HomeShell` is a `Scaffold` with a `BottomNavigationBar` (items: Dashboard, Insights; `onTap` calls `context.go('/dashboard')`/`context.go('/insights')`) and `body: child`.

  In `main.dart`, the `ApiClient` is constructed with `getToken: () => authService.token` and `onUnauthorized: () => authService.logout()` — this closure-based wiring is what makes the 401→logout→redirect chain work without a circular constructor dependency.

- [ ] **Step 1: Write the failing `LoginScreen` widget tests**, using a `FakeGoogleAuthService implements GoogleAuthService` and a `FakeAuthApi`-backed `AuthService`:

```dart
testWidgets('tapping Sign in with Google calls AuthService.loginWithGoogle with the returned token', ...);
testWidgets('shows a SnackBar when GoogleAuthService.signIn returns null (user cancelled) without calling loginWithGoogle', ...);
testWidgets('shows a SnackBar with the error message when loginWithGoogle throws an ApiException', ...);
```

- [ ] **Step 2: Run, confirm failure; implement `LoginScreen` and `GoogleAuthService`/`RealGoogleAuthService`; rerun to confirm pass.**

Run: `cd frontend && flutter test test/screens/login_screen_test.dart`

- [ ] **Step 3: Write the failing router tests** in `router_test.dart`, pumping `MaterialApp.router(routerConfig: buildRouter(authService))` with a real (non-mocked) `AuthService` instance whose `token`/`user` you set directly for the test:

```dart
testWidgets('an unauthenticated user hitting /dashboard directly is redirected to /login', ...);
testWidgets('an authenticated user hitting /login is redirected to /dashboard', ...);
testWidgets('calling authService.logout() while on /dashboard redirects to /login', ...); // Review Focus: session expiry
```

- [ ] **Step 4: Run, confirm failure; implement `router.dart` and `HomeShell`; rerun to confirm pass.**

Run: `cd frontend && flutter test test/router_test.dart`

- [ ] **Step 5: Wire `main.dart`** to construct `http.Client`, `ApiClient`, `AuthApi`, `AuthService`, `RealGoogleAuthService`, and `SharedPreferences.getInstance()` (via a `FutureBuilder` or an async `main()` before `runApp`), provide them all with `MultiProvider`, and use `MaterialApp.router(routerConfig: buildRouter(authService))`.

- [ ] **Step 6: Manually verify** `flutter run -d chrome` shows the login screen (sign-in will fail without a real `GOOGLE_CLIENT_ID` yet — that's expected; just confirm no redirect loop and no crash).

- [ ] **Step 7: Commit**

```bash
git add frontend/lib/auth/google_auth_service.dart frontend/lib/screens/login_screen.dart frontend/lib/screens/home_shell.dart frontend/lib/router.dart frontend/lib/main.dart frontend/test/screens/login_screen_test.dart frontend/test/router_test.dart
git commit -m "feat: add Google sign-in, login screen, and auth-gated router"
```

---

### Task 6: Dashboard and drift data layer

**Files:**
- Create: `frontend/lib/models/dashboard.dart`, `frontend/lib/models/drift_flag.dart`, `frontend/lib/api/dashboard_api.dart`, `frontend/lib/api/targets_api.dart`, `frontend/lib/providers/dashboard_provider.dart`
- Test: `frontend/test/api/dashboard_api_test.dart`, `frontend/test/api/targets_api_test.dart`, `frontend/test/providers/dashboard_provider_test.dart`

**Interfaces:**
- Consumes: `ApiClient` (Task 3).
- Produces:
  ```dart
  const List<String> supportedCurrencies = ['CAD', 'USD', 'CNY', 'HKD', 'SGD'];

  class AccountSummary {
    final int accountId; final String name; final DateTime? asOf; final double value;
    factory AccountSummary.fromJson(Map<String, dynamic> json);
  }
  class TrendPoint {
    final DateTime takenAt; final double netWorth;
    factory TrendPoint.fromJson(Map<String, dynamic> json);
  }
  class DashboardData {
    final double netWorth; final String currency;
    final Map<String, double> byAssetClass; final Map<String, double> byCountry;
    final List<AccountSummary> accounts; final List<TrendPoint> trend;
    factory DashboardData.fromJson(Map<String, dynamic> json);
  }

  class DriftFlag {
    final String assetClass; final double targetPct; final double actualPct; final double deltaPct;
    factory DriftFlag.fromJson(Map<String, dynamic> json);
  }

  abstract class DashboardApiBase { Future<DashboardData> getDashboard(String currency); }
  class DashboardApi implements DashboardApiBase {
    DashboardApi(ApiClient client);
    // GET /dashboard?currency=<currency>
  }

  abstract class TargetsApiBase {
    Future<List<DriftFlag>> getDrift(String currency);
    Future<List<AllocationTarget>> listTargets(); // added to the interface now; implemented in Task 10
    Future<AllocationTarget> updateTarget(String assetClass, double targetPct); // added to the interface now; implemented in Task 10
  }
  class TargetsApi implements TargetsApiBase {
    TargetsApi(ApiClient client);
    // getDrift: GET /targets/drift?currency=<currency>
    // listTargets: GET /targets — implement this method body in Task 10, not here.
    // updateTarget: PUT /targets/{assetClass} with body {"target_pct": targetPct} — implement in Task 10.
    // this task only needs getDrift, but declares the full interface now so
    // Task 10 extends the same class rather than redesigning it.
  }

  enum LoadState { loading, loaded, error }

  class DashboardProvider extends ChangeNotifier {
    DashboardProvider({required DashboardApiBase dashboardApi, required TargetsApiBase targetsApi});
    LoadState state; // starts at LoadState.loading
    DashboardData? data;
    List<DriftFlag> drift; // starts []
    String? errorMessage;
    String currency; // starts 'CAD'
    Future<void> load(); // fetches dashboard + drift concurrently (Future.wait) for `currency`;
                          // on success sets data/drift and state=loaded; on any thrown
                          // ApiException sets errorMessage=e.message and state=error; always notifyListeners()
    Future<void> setCurrency(String newCurrency); // sets currency, then calls load()
  }
  ```
  `AllocationTarget` (referenced in `TargetsApiBase.listTargets`'s return type) is defined in Task 10 — this task only declares the method signature in the interface; do not implement its body or add the model file here. `TargetsApi.listTargets` can be a one-line `throw UnimplementedError()` placeholder for this task.

- [ ] **Step 1: Write the failing `DashboardApi` test** (`MockClient`): parses a full `GET /dashboard` JSON response (include at least one account, one trend point, and non-empty `by_asset_class`/`by_country`) into `DashboardData`; a second test asserts a 503 response surfaces as `ApiException(503, ...)` (not swallowed).

- [ ] **Step 2: Run, confirm failure; implement; rerun to confirm pass.**

Run: `cd frontend && flutter test test/api/dashboard_api_test.dart`

- [ ] **Step 3: Write the failing `TargetsApi.getDrift` test** (`MockClient`): parses a `GET /targets/drift` list response into `List<DriftFlag>`, including the case where the list is empty.

- [ ] **Step 4: Run, confirm failure; implement `getDrift` (leave `listTargets` as `throw UnimplementedError()`); rerun to confirm pass.**

Run: `cd frontend && flutter test test/api/targets_api_test.dart`

- [ ] **Step 5: Write the failing `DashboardProvider` tests**, using hand-written `FakeDashboardApi implements DashboardApiBase` / `FakeTargetsApi implements TargetsApiBase`:

```dart
test('load() sets state to loaded with data and drift on success', ...);
test('load() sets state to error with the ApiException message on a thrown ApiException', ...); // Review Focus: FX 503 — fake dashboardApi.getDashboard throws ApiException(503, 'Exchange rate temporarily unavailable, try again shortly')
test('setCurrency updates currency and reloads data for the new currency', ...);
```

- [ ] **Step 6: Run, confirm failure; implement `DashboardProvider`; rerun to confirm pass.**

Run: `cd frontend && flutter test test/providers/dashboard_provider_test.dart`

- [ ] **Step 7: Commit**

```bash
git add frontend/lib/models/dashboard.dart frontend/lib/models/drift_flag.dart frontend/lib/api/dashboard_api.dart frontend/lib/api/targets_api.dart frontend/lib/providers/dashboard_provider.dart frontend/test/api/dashboard_api_test.dart frontend/test/api/targets_api_test.dart frontend/test/providers/dashboard_provider_test.dart
git commit -m "feat: add dashboard and drift data layer"
```

---

### Task 7: Dashboard screen UI

**Files:**
- Create: `frontend/lib/widgets/net_worth_hero.dart`, `frontend/lib/widgets/trend_sparkline.dart`, `frontend/lib/widgets/drift_alert_banner.dart`, `frontend/lib/widgets/account_breakdown_list.dart`, `frontend/lib/widgets/currency_switcher.dart`, `frontend/lib/screens/dashboard_screen.dart` (replaces the Task 5 placeholder)
- Test: `frontend/test/screens/dashboard_screen_test.dart`

**Interfaces:**
- Consumes: `DashboardProvider` (Task 6), via `Provider`/`Consumer`.
- Produces: `DashboardScreen` — no other task depends on its internals, only on the `/dashboard` route existing (already true from Task 5).

Per the approved design and mockup: hero net-worth number (formatted with `intl`'s `NumberFormat.currency(name: provider.currency)`), a trend sparkline (`fl_chart` `LineChart`, built from `data.trend`, no axis labels — matches the mockup's plain sparkline), a `DriftAlertBanner` shown only when `drift.isNotEmpty` (text: `"${drift.length} ${drift.length == 1 ? 'account' : 'accounts'} off target"` is too vague — use `"${drift.first.assetClass} is ${drift.first.delta.abs().round()}% ${drift.first.deltaPct > 0 ? 'above' : 'below'} target"` when there's exactly one flag, or `"${drift.length} asset classes are off target"` when there's more than one; tapping it calls `context.go('/insights')`), a `CurrencySwitcher` dropdown in the `AppBar` listing `supportedCurrencies` calling `provider.setCurrency`, and an `AccountBreakdownList` grouping `data.accounts` by looking up each account's country from `data.byCountry`'s keys is not possible (byCountry only holds totals, not a per-account country) — **do not** attempt to group by country from `DashboardData` alone; instead render `data.accounts` as a flat list (name, formatted value, and `asOf` rendered as `"updated <date>"` or `"no data yet"` if null), which is what actually satisfies the spec's per-account staleness-visibility requirement (Key Decisions, "Snapshot timing/freshness") — the mockup's country grouping was a simplification that the real `DashboardOut` shape doesn't support without an account→country field the backend doesn't expose; show `byCountry` and `byAssetClass` as two small summary rows above the account list instead (e.g. `"Canada $210,400 · Hong Kong $142,100"`), not as the primary breakdown.

A `FloatingActionButton` with a camera icon, `onPressed: () => context.push('/upload')`.

The screen's body switches on `provider.state`: `loading` → `CircularProgressIndicator`; `error` → centered text showing `provider.errorMessage` plus a `"Retry"` button calling `provider.load()`; `loaded` with `data!.netWorth == 0` → an empty-state widget (text: `"No accounts yet — tap the camera button to add your first screenshot"`, no hero/sparkline/banner); `loaded` with non-zero net worth → the full layout described above.

- [ ] **Step 1: Write the failing widget tests**, pumping `DashboardScreen` wrapped in a `ChangeNotifierProvider.value` for a `DashboardProvider` built with fakes (reuse `FakeDashboardApi`/`FakeTargetsApi` from Task 6's test file, or redeclare if not exported — prefer moving them to a shared `test/fakes.dart` if reused):

```dart
testWidgets('shows a spinner while state is loading', ...);
testWidgets('shows the error message and a Retry button when state is error, and tapping Retry calls provider.load() again', ...);
testWidgets('shows the empty-state message when loaded with netWorth == 0 and renders no hero/sparkline/banner', ...); // Review Focus: zero net worth
testWidgets('shows the formatted net worth, account list with asOf dates, and no drift banner when drift is empty', ...);
testWidgets('shows the drift banner when drift is non-empty, and tapping it navigates toward /insights', ...);
testWidgets('tapping the currency switcher and selecting a new currency calls provider.setCurrency', ...);
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd frontend && flutter test test/screens/dashboard_screen_test.dart`
Expected: FAIL

- [ ] **Step 3: Implement the widgets and `DashboardScreen`** per the Interfaces block above.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd frontend && flutter test test/screens/dashboard_screen_test.dart`

- [ ] **Step 5: Manually verify** `flutter run -d chrome` (with a locally running backend that has at least one confirmed snapshot) renders a sensible dashboard. Resize the browser window narrow (~390px) to confirm the mobile-first layout holds up.

- [ ] **Step 6: Commit**

```bash
git add frontend/lib/widgets/ frontend/lib/screens/dashboard_screen.dart frontend/test/screens/dashboard_screen_test.dart
git commit -m "feat: build dashboard screen UI"
```

---

### Task 8: Upload data layer and flow state machine

**Files:**
- Create: `frontend/lib/models/extraction.dart`, `frontend/lib/models/upload.dart`, `frontend/lib/models/holding.dart`, `frontend/lib/models/account.dart`, `frontend/lib/api/uploads_api.dart`, `frontend/lib/api/accounts_api.dart`, `frontend/lib/providers/upload_flow_provider.dart`
- Test: `frontend/test/api/uploads_api_test.dart`, `frontend/test/api/accounts_api_test.dart`, `frontend/test/providers/upload_flow_provider_test.dart`

**Interfaces:**
- Consumes: `ApiClient` (Task 3).
- Produces:
  ```dart
  const List<String> holdingCurrencies = [...supportedCurrencies, 'CRYPTO'];
  const List<String> assetClasses = ['equity', 'cash', 'crypto', 'bond'];

  class DraftHolding { // mirrors app.schemas.extraction.DraftHolding — read-only, the extraction's raw guess
    final String label; final String? assetClassGuess; final double? quantity;
    final double? value; final String? currencyGuess; final String? countryGuess;
    factory DraftHolding.fromJson(Map<String, dynamic> json);
  }
  class ExtractionResult { // mirrors app.schemas.extraction.ExtractionResult
    final String? institution; final String? accountLabel; final String? accountTypeGuess;
    final DateTime? takenAtGuess; final List<DraftHolding> holdings;
    factory ExtractionResult.fromJson(Map<String, dynamic> json);
  }

  class EditableHolding { // the review screen's mutable row — seeded from a DraftHolding or created blank
    String label; String? assetClass; double? quantity; double? value; String? currency; String country;
    EditableHolding({this.label = '', this.assetClass, this.quantity, this.value, this.currency, this.country = ''});
    factory EditableHolding.fromDraft(DraftHolding draft);
    bool get isComplete; // label.isNotEmpty && assetClass != null && value != null && value! >= 0 && currency != null && country.isNotEmpty
    HoldingIn toHoldingIn(); // throws StateError if !isComplete
  }
  class HoldingIn { // mirrors app.schemas.snapshot.HoldingIn — the strict, backend-ready shape
    final String label; final String assetClass; final double? quantity; final double value; final String currency; final String country;
    Map<String, dynamic> toJson();
  }

  class UploadRecord { // mirrors the fields of UploadOut/UploadExtractOut/UploadDetailOut this app actually uses
    final int id; final String status; // "pending" | "extracted" | "failed" | "confirming" | "confirmed" | "discarded"
    final ExtractionResult? extractedPayload; final String? extractionError; final int? suggestedAccountId;
    factory UploadRecord.fromJson(Map<String, dynamic> json);
  }

  class AccountSummaryLite { // mirrors app.schemas.account.AccountOut
    final int id; final String name; final String institution; final String accountType;
    factory AccountSummaryLite.fromJson(Map<String, dynamic> json);
  }

  abstract class UploadsApiBase {
    Future<int> createUpload({required List<int> bytes, required String filename, required String mimeType}); // -> UploadOut.id
    Future<UploadRecord> extractUpload(int uploadId); // POST /uploads/{id}/extract -> UploadExtractOut
    Future<void> confirmUpload({
      required int uploadId,
      required int? accountId,
      required ({String name, String institution, String accountType})? newAccount,
      required DateTime takenAt,
      required List<HoldingIn> holdings,
    }); // POST /uploads/{id}/confirm — exactly one of accountId/newAccount must be non-null
    Future<void> discardUpload(int uploadId); // POST /uploads/{id}/discard
  }
  class UploadsApi implements UploadsApiBase { UploadsApi(ApiClient client); }

  abstract class AccountsApiBase { Future<List<AccountSummaryLite>> listAccounts(); }
  class AccountsApi implements AccountsApiBase { AccountsApi(ApiClient client); }

  enum UploadFlowState { picking, uploading, extracting, failed, ready, confirming, confirmed, alreadyFinalized, error }

  class UploadFlowProvider extends ChangeNotifier {
    UploadFlowProvider({required UploadsApiBase uploadsApi, required AccountsApiBase accountsApi});
    UploadFlowState state; // starts at UploadFlowState.picking
    List<EditableHolding> holdings; // starts []; mutable by the screen
    String institution; String accountLabel; DateTime takenAt; // editable form fields, seeded on successful extraction
    int? suggestedAccountId;
    List<AccountSummaryLite> accounts; // starts [], loaded by loadAccounts()
    String? errorMessage;
    int? _uploadId;

    Future<void> loadAccounts(); // calls accountsApi.listAccounts(), fills `accounts`
    Future<void> startUpload({required List<int> bytes, required String filename, required String mimeType});
      // state=uploading -> createUpload -> state=extracting -> extractUpload ->
      // if record.status == 'extracted': seed holdings/institution/takenAt/suggestedAccountId from extractedPayload, state=ready
      // if record.status == 'failed': holdings=[], errorMessage=record.extractionError, state=failed (still shows the editable form, per Review Focus)
      // on ApiException: errorMessage=e.message, state=error
    Future<void> confirm({required int? accountId, required ({String name, String institution, String accountType})? newAccount});
      // state=confirming -> uploadsApi.confirmUpload(...) -> state=confirmed
      // on ApiException(409, ...): state=alreadyFinalized, errorMessage=e.message  // Review Focus: confirm/discard race
      // on other ApiException: errorMessage=e.message, state=error
    Future<void> discard();
      // uploadsApi.discardUpload(_uploadId) -> state=confirmed (reuse as "done, leave screen")
      // on ApiException(409, ...): state=alreadyFinalized, errorMessage=e.message
  }
  ```

- [ ] **Step 1: Write the failing `UploadsApi` tests** (`MockClient`): `createUpload` posts multipart and returns the new id; `extractUpload` parses a `status: "extracted"` response into `UploadRecord` with a populated `extractedPayload`; a second case parses a `status: "failed"` response with `extractedPayload: null` and `extractionError` set — confirms the 200-with-failed-status shape is read correctly, not mistaken for an HTTP error; `confirmUpload` posts the exact JSON shape (`account_id` xor `new_account`, `taken_at` as an ISO date string, `holdings` as a list of `HoldingIn.toJson()`); `discardUpload` posts with no body and tolerates a 204 empty response.

- [ ] **Step 2: Run, confirm failure; implement `UploadsApi`, `UploadRecord`, `ExtractionResult`, `DraftHolding`, `HoldingIn`; rerun to confirm pass.**

Run: `cd frontend && flutter test test/api/uploads_api_test.dart`

- [ ] **Step 3: Write the failing `AccountsApi` test**: parses a `GET /accounts` list response into `List<AccountSummaryLite>`.

- [ ] **Step 4: Run, confirm failure; implement; rerun to confirm pass.**

Run: `cd frontend && flutter test test/api/accounts_api_test.dart`

- [ ] **Step 5: Write the failing `EditableHolding` and `UploadFlowProvider` tests**, using `FakeUploadsApi implements UploadsApiBase` / `FakeAccountsApi implements AccountsApiBase`:

```dart
test('EditableHolding.isComplete is false when any required field is missing, true when all are set', ...);
test('EditableHolding.fromDraft seeds fields from a DraftHolding, leaving assetClass/currency null when the guess was null', ...);
test('startUpload on a successful extraction seeds holdings/institution/takenAt/suggestedAccountId and sets state to ready', ...);
test('startUpload on a failed extraction sets state to failed, holdings stays empty, and errorMessage is the extraction_error', ...); // Review Focus: extraction failure
test('startUpload surfaces a thrown ApiException as state=error with errorMessage', ...);
test('confirm with an accountId calls confirmUpload with that accountId and newAccount null, and sets state to confirmed on success', ...);
test('confirm surfaces a 409 ApiException as state=alreadyFinalized, not state=error', ...); // Review Focus: confirm race
test('discard calls discardUpload and sets state to confirmed on success', ...);
test('discard surfaces a 409 ApiException as state=alreadyFinalized', ...); // Review Focus: discard race
```

- [ ] **Step 6: Run tests to verify they fail**

Run: `cd frontend && flutter test test/providers/upload_flow_provider_test.dart`
Expected: FAIL

- [ ] **Step 7: Implement `EditableHolding` and `UploadFlowProvider`**, run tests to verify they pass.

- [ ] **Step 8: Commit**

```bash
git add frontend/lib/models/extraction.dart frontend/lib/models/upload.dart frontend/lib/models/holding.dart frontend/lib/models/account.dart frontend/lib/api/uploads_api.dart frontend/lib/api/accounts_api.dart frontend/lib/providers/upload_flow_provider.dart frontend/test/api/uploads_api_test.dart frontend/test/api/accounts_api_test.dart frontend/test/providers/upload_flow_provider_test.dart
git commit -m "feat: add upload data layer and upload-flow state machine"
```

---

### Task 9: Upload review screen UI

**Files:**
- Create: `frontend/lib/screens/upload_review_screen.dart` (replaces the Task 5 placeholder)
- Test: `frontend/test/screens/upload_review_screen_test.dart`

**Interfaces:**
- Consumes: `UploadFlowProvider` (Task 8), `image_picker`'s `ImagePicker` (wrapped behind a constructor parameter so tests can fake it — define `abstract class ImagePickerService { Future<({List<int> bytes, String filename, String mimeType})?> pickImage(); }` here, with a `RealImagePickerService` using `ImagePicker().pickImage(source: ImageSource.camera)` — `ImageSource.camera` adds the browser's `capture` attribute, which mobile browsers honor (opens the camera directly, matching "snap a screenshot") and desktop browsers ignore (falls back to a normal file dialog), so one source works for both).
- Produces: `UploadReviewScreen` — no other task depends on its internals.

On `initState`, if `provider.state == UploadFlowState.picking`, calls `imagePickerService.pickImage()`; if it returns `null` (user cancelled), pops back to `/dashboard`; otherwise calls `provider.startUpload(bytes: ..., filename: ..., mimeType: ...)`.

Body switches on `provider.state`: `uploading`/`extracting` → the "reading account details" spinner view from the mockup; `ready` or `failed` → the editable confirm form (holdings list with label/value/currency/asset-class/country fields per `EditableHolding`, each with a "Remove" action, plus an "+ Add holding" button appending a blank `EditableHolding`; a date field for `takenAt`; an account section — a dropdown of `provider.accounts` pre-selected to `provider.suggestedAccountId` when non-null, plus a "+ New account" option that reveals name/institution/account-type text fields instead of the dropdown selection); `failed` additionally shows `provider.errorMessage` above the (empty) form; `confirming` → spinner; `confirmed` → pops back to `/dashboard` (triggering `DashboardProvider.load()` again — read the `DashboardProvider` via `context.read` and call `.load()` before popping, since there's no shared cache invalidation mechanism in this plan); `alreadyFinalized` → a dialog/snackbar with `provider.errorMessage` (e.g. "Upload is already finalized") and then pops back to `/dashboard`; `error` → an error view with `provider.errorMessage` and a "Discard" button (no retry — the upload id already exists server-side; simplest safe recovery is discarding and letting the user re-snap).

The screen calls `provider.loadAccounts()` once (e.g. in `initState`, alongside the pick-and-extract sequence) so the account dropdown has data by the time `ready` is reached.

A "Confirm" button is enabled only when every holding in `provider.holdings` has `isComplete == true`, `provider.holdings.isNotEmpty`, and exactly one of (an account selected) or (new-account fields all non-empty) — tapping it calls `provider.confirm(...)` with the appropriate arguments. A "Discard" button is always enabled and calls `provider.discard()`.

- [ ] **Step 1: Write the failing widget tests**, pumping `UploadReviewScreen` with a `ChangeNotifierProvider.value` for a `UploadFlowProvider` built from fakes, and a `FakeImagePickerService`:

```dart
testWidgets('shows the extracting spinner while state is uploading or extracting', ...);
testWidgets('shows a pre-filled editable form when state is ready, with the suggested account pre-selected', ...);
testWidgets('shows an empty editable form with the error message when state is failed', ...); // Review Focus: extraction failure
testWidgets('Confirm button is disabled until every holding is complete and an account is chosen', ...);
testWidgets('tapping Confirm calls provider.confirm with the selected account id', ...);
testWidgets('tapping + Add holding appends a blank editable row', ...);
testWidgets('when state becomes alreadyFinalized, shows the message and navigates back toward /dashboard', ...); // Review Focus: confirm/discard race
testWidgets('when the image picker returns null, the screen navigates back to /dashboard without calling startUpload', ...);
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd frontend && flutter test test/screens/upload_review_screen_test.dart`
Expected: FAIL

- [ ] **Step 3: Implement `UploadReviewScreen`, `ImagePickerService`, `RealImagePickerService`** per the Interfaces block above.

- [ ] **Step 4: Run tests to verify they pass.**

- [ ] **Step 5: Manually verify** against a running backend: tap the dashboard's camera FAB, pick a real account-screenshot image, confirm the extracted/editable fields appear, and that Confirm creates a real snapshot visible back on the dashboard.

- [ ] **Step 6: Commit**

```bash
git add frontend/lib/screens/upload_review_screen.dart frontend/test/screens/upload_review_screen_test.dart
git commit -m "feat: build upload review screen UI"
```

---

### Task 10: Insights and to-dos data layer

**Files:**
- Create: `frontend/lib/models/allocation_target.dart`, `frontend/lib/models/insights.dart`, `frontend/lib/models/todo.dart`, `frontend/lib/api/insights_api.dart`, `frontend/lib/api/todos_api.dart`, `frontend/lib/providers/insights_provider.dart`, `frontend/lib/providers/todos_provider.dart`
- Modify: `frontend/lib/api/targets_api.dart` (implement the `listTargets` method left as `UnimplementedError` in Task 6)
- Test: `frontend/test/api/insights_api_test.dart`, `frontend/test/api/todos_api_test.dart`, `frontend/test/api/targets_api_test.dart` (add the `listTargets` case), `frontend/test/providers/insights_provider_test.dart`, `frontend/test/providers/todos_provider_test.dart`

**Interfaces:**
- Consumes: `ApiClient` (Task 3), `DashboardData`/`DriftFlag` (Task 6).
- Produces:
  ```dart
  class AllocationTarget { // mirrors app.schemas.target.TargetOut
    final int id; final String assetClass; final double targetPct; final bool isUserSet;
    factory AllocationTarget.fromJson(Map<String, dynamic> json);
  }

  class ActionItem { final String assetClass; final String suggestion; factory ActionItem.fromJson(...); }
  class InsightsNarrative {
    final String summary; final List<ActionItem> actionItems;
    factory InsightsNarrative.fromJson(Map<String, dynamic> json);
  }
  class InsightsData {
    final DashboardData dashboard; final List<DriftFlag> drift;
    final InsightsNarrative narrative; final bool narrativeUnavailable;
    factory InsightsData.fromJson(Map<String, dynamic> json);
  }

  abstract class InsightsApiBase { Future<InsightsData> getInsights(String currency); }
  class InsightsApi implements InsightsApiBase { InsightsApi(ApiClient client); } // GET /insights?currency=

  class TodoItem { // mirrors app.schemas.todo.TodoOut
    final int id; final String description; final bool done; final String? relatedAssetClass;
    factory TodoItem.fromJson(Map<String, dynamic> json);
  }
  abstract class TodosApiBase {
    Future<List<TodoItem>> listTodos();
    Future<TodoItem> createTodo({required String description, String? relatedAssetClass});
    Future<TodoItem> setDone(int id, bool done);
    Future<void> deleteTodo(int id);
  }
  class TodosApi implements TodosApiBase { TodosApi(ApiClient client); }

  class InsightsProvider extends ChangeNotifier {
    InsightsProvider({required InsightsApiBase insightsApi, required TargetsApiBase targetsApi});
    LoadState state; InsightsData? data; List<AllocationTarget> targets; String? errorMessage; String currency;
    Future<void> load(); // Future.wait([insightsApi.getInsights(currency), targetsApi.listTargets()]); same error handling shape as DashboardProvider.load
    Future<void> updateTarget(String assetClass, double targetPct);
      // calls targetsApi.updateTarget, replaces the matching entry in `targets` on success
      // (optimistic-free: just await and update — a target edit is infrequent and the
      // round trip is small), sets errorMessage on ApiException without changing `state`
      // (a failed edit shouldn't blank out an already-loaded screen).
  }

  class TodosProvider extends ChangeNotifier {
    TodosProvider({required TodosApiBase todosApi});
    LoadState state; List<TodoItem> todos; String? errorMessage;
    Future<void> load();
    Future<void> add(String description, {String? relatedAssetClass}); // optimistic: appends locally, calls createTodo, replaces with server copy, rolls back + sets errorMessage on failure
    Future<void> toggle(TodoItem item); // calls setDone(item.id, !item.done), updates the local list on success
    Future<void> remove(int id); // calls deleteTodo, removes locally on success
  }
  ```

- [ ] **Step 1: Write the failing `InsightsApi` test**: parses a full `GET /insights` response (including `narrative_unavailable: true` and `narrative_unavailable: false` cases) into `InsightsData`.

- [ ] **Step 2: Run, confirm failure; implement `InsightsApi`, `InsightsData`, `InsightsNarrative`, `ActionItem`; rerun to confirm pass.**

- [ ] **Step 3: Write the failing `TargetsApi.listTargets` and `updateTarget` tests**: `listTargets` parses a `GET /targets` list response into `List<AllocationTarget>`; `updateTarget` PUTs `{"target_pct": targetPct}` to `/targets/{assetClass}` and parses the returned `AllocationTarget`.

- [ ] **Step 4: Run, confirm failure; implement `listTargets`, `updateTarget`, `AllocationTarget`; rerun to confirm pass.**

Run: `cd frontend && flutter test test/api/targets_api_test.dart`

- [ ] **Step 5: Write the failing `TodosApi` tests**: `listTodos` parses a list; `createTodo` posts `{description, related_asset_class}` and parses the created `TodoItem`; `setDone` PATCHes `{done}` to `/todos/{id}`; `deleteTodo` sends `DELETE` and tolerates a 204.

- [ ] **Step 6: Run, confirm failure; implement `TodosApi`, `TodoItem`; rerun to confirm pass.**

- [ ] **Step 7: Write the failing `InsightsProvider` tests**, using `FakeInsightsApi`/`FakeTargetsApi`:

```dart
test('load() sets state to loaded with insights data and targets on success', ...);
test('load() sets state to error with the ApiException message on failure', ...);
test('updateTarget replaces the matching target in `targets` on success without changing `state`', ...);
test('updateTarget sets errorMessage on a thrown ApiException without changing `state` or `targets`', ...);
```

- [ ] **Step 8: Run, confirm failure; implement; rerun to confirm pass.**

- [ ] **Step 9: Write the failing `TodosProvider` tests**, using `FakeTodosApi`:

```dart
test('load() populates todos on success', ...);
test('add() appends the new todo on success', ...);
test('add() rolls back the optimistic entry and sets errorMessage on failure', ...);
test('toggle() updates the item\'s done flag on success', ...);
test('remove() removes the item on success', ...);
```

- [ ] **Step 10: Run, confirm failure; implement; rerun to confirm pass.**

- [ ] **Step 11: Commit**

```bash
git add frontend/lib/models/allocation_target.dart frontend/lib/models/insights.dart frontend/lib/models/todo.dart frontend/lib/api/insights_api.dart frontend/lib/api/todos_api.dart frontend/lib/api/targets_api.dart frontend/lib/providers/insights_provider.dart frontend/lib/providers/todos_provider.dart frontend/test/api/insights_api_test.dart frontend/test/api/todos_api_test.dart frontend/test/api/targets_api_test.dart frontend/test/providers/insights_provider_test.dart frontend/test/providers/todos_provider_test.dart
git commit -m "feat: add insights and to-dos data layer"
```

---

### Task 11: Insights and to-dos screen UI

**Files:**
- Create: `frontend/lib/widgets/allocation_bar.dart`, `frontend/lib/widgets/todo_list_tile.dart`, `frontend/lib/screens/insights_screen.dart` (replaces the Task 5 placeholder)
- Test: `frontend/test/screens/insights_screen_test.dart`

**Interfaces:**
- Consumes: `InsightsProvider`, `TodosProvider` (Task 10).
- Produces: `InsightsScreen` — terminal; nothing depends on it.

Per the approved mockup: for each `AllocationTarget` in `provider.targets`, compute `actualPct = (data.dashboard.byAssetClass[target.assetClass] ?? 0) / data.dashboard.netWorth * 100` (guard `netWorth == 0` → `actualPct = 0`, matching the backend's own zero-net-worth handling), and render an `AllocationBar` (a labeled horizontal bar — asset class display name, a tick mark at `target.targetPct`, the bar filled to `actualPct`, colored amber when the asset class appears in `data.drift` and green otherwise, matching the mockup). Display names: `equity → "Equities"`, `cash → "Cash"`, `bond → "Fixed income"`, `crypto → "Crypto"`.

The mockup only showed these bars read-only, but the design spec's Key Decisions require targets to be user-editable ("system proposes defaults, user edits them") — the brainstorming session settled the bars' visual shape but never surfaced this already-approved requirement as a UI affordance, so it's added here rather than re-opening the mockup conversation. Each `AllocationBar` is tappable; tapping opens a small dialog (a `Slider` or number field, 0–100, pre-filled with the current `target.targetPct`) and on submit calls `InsightsProvider.updateTarget(target.assetClass, newValue)`. A target with `isUserSet == false` additionally shows a small "suggested" label so the user can tell a system default from one they've already adjusted.

Below the bars, the narrative card shows `data.narrative.summary` (and, when `data.narrative.actionItems` is non-empty, lists them); when `narrativeUnavailable` is true, the summary text is still shown as-is (it's already the friendly "temporarily unavailable" message from the backend — Review Focus: the UI must not additionally show an error banner on top of it).

Below that, the to-do list: each `TodoItem` as a `TodoListTile` (checkbox bound to `done`, calling `TodosProvider.toggle`; a delete action calling `TodosProvider.remove`; strikethrough text when `done`), and an "+ Add to-do" control (a text field + submit, calling `TodosProvider.add`).

The screen's body switches on `InsightsProvider.state` the same way `DashboardScreen` does (`loading`/`error`/`loaded`), and separately renders the to-do section once `TodosProvider.state == LoadState.loaded` regardless of the insights state (to-dos and insights are independent data; one failing shouldn't hide the other). When `data.dashboard.netWorth == 0`, show the same kind of empty-state treatment as the dashboard for the allocation/narrative section (text: `"No holdings yet — once you add some accounts, insights will appear here"`, which is in fact exactly the backend's `NO_HOLDINGS_NARRATIVE.summary`, so simply rendering `data.narrative.summary` as-is already satisfies this — no special-casing needed beyond what the narrative card already does) but always show the to-do list regardless of net worth.

- [ ] **Step 1: Write the failing widget tests**, pumping `InsightsScreen` with `ChangeNotifierProvider.value`s for both providers built from fakes:

```dart
testWidgets('shows a spinner while insights state is loading', ...);
testWidgets('shows the error message and Retry button when insights state is error', ...);
testWidgets('renders an allocation bar per target with correct actual-vs-target fill', ...);
testWidgets('colors a drifted asset class bar differently from a non-drifted one', ...);
testWidgets('shows a "suggested" label on a target that is not user-set', ...);
testWidgets('tapping an allocation bar opens the edit dialog pre-filled with its current target, and submitting a new value calls InsightsProvider.updateTarget', ...);
testWidgets('shows the narrative summary as-is when narrativeUnavailable is true, with no extra error banner', ...); // Review Focus
testWidgets('shows the zero-net-worth narrative text and still renders the to-do list', ...); // Review Focus: zero net worth
testWidgets('renders one TodoListTile per todo, and tapping its checkbox calls TodosProvider.toggle', ...);
testWidgets('submitting the add-todo field calls TodosProvider.add and clears the field', ...);
testWidgets('tapping a todo\'s delete action calls TodosProvider.remove', ...);
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd frontend && flutter test test/screens/insights_screen_test.dart`
Expected: FAIL

- [ ] **Step 3: Implement `AllocationBar`, `TodoListTile`, `InsightsScreen`** per the Interfaces block above.

- [ ] **Step 4: Run tests to verify they pass.**

- [ ] **Step 5: Manually verify** against a running backend with at least one drifted asset class: confirm the allocation bars, narrative, and to-do list all render and behave as in the mockup, at both desktop and ~390px-wide browser sizes.

- [ ] **Step 6: Commit**

```bash
git add frontend/lib/widgets/allocation_bar.dart frontend/lib/widgets/todo_list_tile.dart frontend/lib/screens/insights_screen.dart frontend/test/screens/insights_screen_test.dart
git commit -m "feat: build insights and to-dos screen UI"
```

---

### Task 12: Wire providers into the app and final manual walkthrough

The last task: every provider built in Tasks 4–10 needs to be constructed once in `main.dart` and handed to the widget tree — individual tasks tested each provider/screen in isolation, but nothing yet exercises them wired together as the real app does.

**Files:**
- Modify: `frontend/lib/main.dart`

**Interfaces:**
- Consumes: everything built in Tasks 2–11.
- Produces: the complete, runnable app. Nothing downstream depends on this task.

- [ ] **Step 1:** In `main.dart`, construct one `http.Client`, one `ApiClient`, and one instance each of `AuthApi`, `DashboardApi`, `TargetsApi`, `InsightsApi`, `TodosApi`, `UploadsApi`, `AccountsApi`, `AuthService`, `GoogleAuthService`. Provide `DashboardProvider`, `InsightsProvider`, `TodosProvider`, and `UploadFlowProvider` as `ChangeNotifierProvider`s (not `.value`, so they're constructed once via the provider tree and call `.load()`/`.loadAccounts()` in their constructors or via each screen's `initState`— pick whichever `provider`'s own idiom the implementer already used in Tasks 6/8/10's tests, for consistency). Provide `AuthService` and `GoogleAuthService` via plain `Provider`/`ChangeNotifierProvider` as in Task 5.

- [ ] **Step 2: Run the full test suite**

Run: `cd frontend && flutter test`
Expected: every test from Tasks 2–11 still passes.

- [ ] **Step 3: Manual end-to-end walkthrough** against a locally running backend (`cd backend && uvicorn app.main:app --reload`) and `flutter run -d chrome --dart-define=API_BASE_URL=http://localhost:8000 --dart-define=GOOGLE_CLIENT_ID=<a real client id>`:
  1. Sign in with Google.
  2. Confirm the dashboard loads (empty state if no data yet).
  3. Tap the camera FAB, upload a real account-screenshot image, confirm the extracted fields, submit.
  4. Confirm the new snapshot appears on the dashboard.
  5. Visit the Insights tab, confirm allocation bars and narrative render; add, toggle, and delete a to-do.
  6. Resize the browser to ~390px wide and repeat steps 2–5, confirming the mobile-first layout holds up.
  7. Sign out (or clear the stored token) and confirm the app returns to `/login`.

- [ ] **Step 4: Commit**

```bash
git add frontend/lib/main.dart
git commit -m "feat: wire all providers into the running app"
```
