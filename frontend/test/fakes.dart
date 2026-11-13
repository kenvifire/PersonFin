// Shared hand-written fakes for `DashboardApiBase`/`TargetsApiBase`/
// `InsightsApiBase`/`TodosApiBase`/`GoogleAuthService`/`ImagePickerService`,
// used by the provider tests and the screen tests across tasks.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:personfin/api/dashboard_api.dart';
import 'package:personfin/api/insights_api.dart';
import 'package:personfin/api/targets_api.dart';
import 'package:personfin/api/todos_api.dart';
import 'package:personfin/auth/google_auth_service.dart';
import 'package:personfin/models/allocation_target.dart';
import 'package:personfin/models/dashboard.dart';
import 'package:personfin/models/drift_flag.dart';
import 'package:personfin/models/insights.dart';
import 'package:personfin/models/todo.dart';
import 'package:personfin/services/image_picker_service.dart';

/// Hand-written fake for [ImagePickerService]. Returns [result] (`null`
/// simulates the user cancelling the picker) and counts calls so tests can
/// assert the real upload flow was/wasn't kicked off.
class FakeImagePickerService implements ImagePickerService {
  final ({List<int> bytes, String filename, String mimeType})? result;
  int callCount = 0;

  FakeImagePickerService({this.result});

  @override
  Future<({List<int> bytes, String filename, String mimeType})?> pickImage() async {
    callCount++;
    return result;
  }
}

DashboardData dashboardFor(String currency) => DashboardData(
      netWorth: 1000.0,
      currency: currency,
      byAssetClass: {'Equity': 1000.0},
      byCountry: {'CA': 1000.0},
      accounts: [],
      trend: [],
    );

List<DriftFlag> driftFor(String currency) => [
      DriftFlag(assetClass: 'Equity', targetPct: 60.0, actualPct: 65.0, deltaPct: 5.0),
    ];

class FakeDashboardApi implements DashboardApiBase {
  final DashboardData? fixedData;
  final Object? error;
  String? lastRequestedCurrency;
  int callCount = 0;

  FakeDashboardApi({this.fixedData, this.error});

  @override
  Future<DashboardData> getDashboard(String currency) async {
    lastRequestedCurrency = currency;
    callCount++;
    if (error != null) {
      throw error!;
    }
    return fixedData ?? dashboardFor(currency);
  }
}

List<AllocationTarget> targetsFor() => [
      AllocationTarget(id: 1, assetClass: 'Equity', targetPct: 60.0, isUserSet: true),
      AllocationTarget(id: 2, assetClass: 'Bond', targetPct: 40.0, isUserSet: false),
    ];

class FakeTargetsApi implements TargetsApiBase {
  final List<DriftFlag>? fixedDrift;
  final Object? error;
  final List<AllocationTarget>? fixedTargets;
  final Object? listTargetsError;
  final Object? updateTargetError;
  String? lastRequestedCurrency;
  int callCount = 0;
  String? lastUpdatedAssetClass;
  double? lastUpdatedTargetPct;

  FakeTargetsApi({
    this.fixedDrift,
    this.error,
    this.fixedTargets,
    this.listTargetsError,
    this.updateTargetError,
  });

  @override
  Future<List<DriftFlag>> getDrift(String currency) async {
    lastRequestedCurrency = currency;
    callCount++;
    if (error != null) {
      throw error!;
    }
    return fixedDrift ?? driftFor(currency);
  }

  @override
  Future<List<AllocationTarget>> listTargets() async {
    if (listTargetsError != null) {
      throw listTargetsError!;
    }
    return fixedTargets ?? targetsFor();
  }

  @override
  Future<AllocationTarget> updateTarget(String assetClass, double targetPct) async {
    lastUpdatedAssetClass = assetClass;
    lastUpdatedTargetPct = targetPct;
    if (updateTargetError != null) {
      throw updateTargetError!;
    }
    return AllocationTarget(id: 1, assetClass: assetClass, targetPct: targetPct, isUserSet: true);
  }
}

InsightsData insightsFor(String currency) => InsightsData(
      dashboard: dashboardFor(currency),
      drift: driftFor(currency),
      narrative: InsightsNarrative(summary: 'Your allocation looks balanced.', actionItems: []),
      narrativeUnavailable: false,
    );

class FakeInsightsApi implements InsightsApiBase {
  final InsightsData? fixedData;
  final Object? error;
  String? lastRequestedCurrency;
  int callCount = 0;

  FakeInsightsApi({this.fixedData, this.error});

  @override
  Future<InsightsData> getInsights(String currency) async {
    lastRequestedCurrency = currency;
    callCount++;
    if (error != null) {
      throw error!;
    }
    return fixedData ?? insightsFor(currency);
  }
}

List<TodoItem> todosFor() => [
      TodoItem(id: 1, description: 'Rebalance equity', done: false, relatedAssetClass: 'Equity'),
    ];

class FakeTodosApi implements TodosApiBase {
  final List<TodoItem>? fixedTodos;
  final Object? listTodosError;
  final TodoItem? createdTodo;
  final Object? createTodoError;
  final TodoItem? updatedTodo;
  final Object? setDoneError;
  final Object? deleteTodoError;
  String? lastCreatedDescription;
  String? lastCreatedRelatedAssetClass;
  int? lastSetDoneId;
  bool? lastSetDoneValue;
  int? lastDeletedId;
  int listTodosCallCount = 0;

  FakeTodosApi({
    this.fixedTodos,
    this.listTodosError,
    this.createdTodo,
    this.createTodoError,
    this.updatedTodo,
    this.setDoneError,
    this.deleteTodoError,
  });

  @override
  Future<List<TodoItem>> listTodos() async {
    listTodosCallCount++;
    if (listTodosError != null) {
      throw listTodosError!;
    }
    return fixedTodos ?? todosFor();
  }

  @override
  Future<TodoItem> createTodo({required String description, String? relatedAssetClass}) async {
    lastCreatedDescription = description;
    lastCreatedRelatedAssetClass = relatedAssetClass;
    if (createTodoError != null) {
      throw createTodoError!;
    }
    return createdTodo ??
        TodoItem(id: 99, description: description, done: false, relatedAssetClass: relatedAssetClass);
  }

  @override
  Future<TodoItem> setDone(int id, bool done) async {
    lastSetDoneId = id;
    lastSetDoneValue = done;
    if (setDoneError != null) {
      throw setDoneError!;
    }
    return updatedTodo ?? TodoItem(id: id, description: 'Todo', done: done, relatedAssetClass: null);
  }

  @override
  Future<void> deleteTodo(int id) async {
    lastDeletedId = id;
    if (deleteTodoError != null) {
      throw deleteTodoError!;
    }
  }
}

/// Fake [GoogleAuthService]: renders a plain "Sign in with Google" button
/// standing in for Google's GIS-rendered one. Tapping it runs [onSignIn]
/// (default: succeed with `'fake-id-token'`) and pushes the outcome onto
/// [idTokens] exactly as the real web flow would — a token on success,
/// `null` on cancel, a stream error if [onSignIn] throws.
class FakeGoogleAuthService implements GoogleAuthService {
  Future<String?> Function()? onSignIn;
  final _controller = StreamController<String?>.broadcast();

  FakeGoogleAuthService({this.onSignIn});

  /// Pushes a sign-in result directly, as if Google's button had completed
  /// a flow on its own.
  void emit(String? idToken) => _controller.add(idToken);

  @override
  Stream<String?> get idTokens => _controller.stream;

  @override
  Widget buildSignInButton() => ElevatedButton(
        onPressed: () async {
          final handler = onSignIn;
          try {
            final token = handler != null ? await handler() : 'fake-id-token';
            _controller.add(token);
          } catch (e, st) {
            _controller.addError(e, st);
          }
        },
        child: const Text('Sign in with Google'),
      );
}

/// [DashboardApiBase] whose `getDashboard` waits on [gate] before
/// returning, so a test can interleave other calls (e.g. a reset) while a
/// load is in flight.
class GatedDashboardApi implements DashboardApiBase {
  final gate = Completer<void>();

  @override
  Future<DashboardData> getDashboard(String currency) async {
    await gate.future;
    return dashboardFor(currency);
  }
}
