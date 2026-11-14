import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:personfin/api/accounts_api.dart';
import 'package:personfin/api/auth_api.dart';
import 'package:personfin/api/dashboard_api.dart';
import 'package:personfin/api/insights_api.dart';
import 'package:personfin/api/targets_api.dart';
import 'package:personfin/api/todos_api.dart';
import 'package:personfin/api/uploads_api.dart';
import 'package:personfin/auth/auth_service.dart';
import 'package:personfin/main.dart';
import 'package:personfin/models/account.dart';
import 'package:personfin/models/allocation_target.dart';
import 'package:personfin/models/dashboard.dart';
import 'package:personfin/models/drift_flag.dart';
import 'package:personfin/models/holding.dart';
import 'package:personfin/models/insights.dart';
import 'package:personfin/models/snapshot.dart';
import 'package:personfin/models/todo.dart';
import 'package:personfin/models/upload.dart';
import 'package:personfin/models/user.dart';

import 'fakes.dart' show FakeGoogleAuthService;

class FakeAuthApi implements AuthApiBase {
  @override
  Future<(String accessToken, AppUser user)> loginWithGoogle(
      String idToken) async {
    return ('fake-token', AppUser(id: 1, email: 'test@example.com'));
  }
}

// Not exercised by this test (the login screen never touches these
// providers, and ChangeNotifierProvider.create is lazy) — just enough to
// satisfy MyApp's constructor.
class FakeDashboardApi implements DashboardApiBase {
  @override
  Future<DashboardData> getDashboard(String currency) =>
      throw UnimplementedError();
}

class FakeTargetsApi implements TargetsApiBase {
  @override
  Future<List<DriftFlag>> getDrift(String currency) =>
      throw UnimplementedError();

  @override
  Future<List<AllocationTarget>> listTargets() => throw UnimplementedError();

  @override
  Future<AllocationTarget> updateTarget(String assetClass, double targetPct) =>
      throw UnimplementedError();
}

class FakeInsightsApi implements InsightsApiBase {
  @override
  Future<InsightsData> getInsights(String currency) =>
      throw UnimplementedError();
}

class FakeTodosApi implements TodosApiBase {
  @override
  Future<List<TodoItem>> listTodos() => throw UnimplementedError();

  @override
  Future<TodoItem> createTodo({required String description, String? relatedAssetClass}) =>
      throw UnimplementedError();

  @override
  Future<TodoItem> setDone(int id, bool done) => throw UnimplementedError();

  @override
  Future<void> deleteTodo(int id) => throw UnimplementedError();
}

class FakeUploadsApi implements UploadsApiBase {
  @override
  Future<int> createUpload({required List<int> bytes, required String filename, required String mimeType}) =>
      throw UnimplementedError();

  @override
  Future<UploadRecord> extractUpload(int uploadId) => throw UnimplementedError();

  @override
  Future<void> confirmUpload({
    required int uploadId,
    required int? accountId,
    required ({String name, String institution, String accountType})? newAccount,
    required DateTime takenAt,
    required List<HoldingIn> holdings,
  }) =>
      throw UnimplementedError();

  @override
  Future<void> discardUpload(int uploadId) => throw UnimplementedError();
}

class FakeAccountsApi implements AccountsApiBase {
  @override
  Future<List<AccountSummaryLite>> listAccounts() => throw UnimplementedError();

  @override
  Future<AccountSummaryLite> getAccount(int id) => throw UnimplementedError();

  @override
  Future<void> updateAccount({
    required int id,
    String? name,
    String? institution,
    String? accountType,
  }) =>
      throw UnimplementedError();

  @override
  Future<void> deleteAccount(int id) => throw UnimplementedError();

  @override
  Future<List<SnapshotOut>> listSnapshots(int accountId) => throw UnimplementedError();
}

void main() {
  testWidgets(
      'app builds and shows the login screen when no session is persisted',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final authService = AuthService(authApi: FakeAuthApi(), prefs: prefs);

    await tester.pumpWidget(MyApp(
      authService: authService,
      googleAuthService: FakeGoogleAuthService(),
      dashboardApi: FakeDashboardApi(),
      targetsApi: FakeTargetsApi(),
      insightsApi: FakeInsightsApi(),
      todosApi: FakeTodosApi(),
      uploadsApi: FakeUploadsApi(),
      accountsApi: FakeAccountsApi(),
    ));
    await tester.pumpAndSettle();

    expect(find.text('PersonFin'), findsOneWidget);
    expect(find.text('Sign in with Google'), findsOneWidget);
  });
}
