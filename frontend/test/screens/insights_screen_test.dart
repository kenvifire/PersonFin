import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:personfin/api/api_client.dart';
import 'package:personfin/models/allocation_target.dart';
import 'package:personfin/models/dashboard.dart';
import 'package:personfin/models/drift_flag.dart';
import 'package:personfin/models/insights.dart';
import 'package:personfin/models/todo.dart';
import 'package:personfin/providers/dashboard_provider.dart';
import 'package:personfin/providers/insights_provider.dart';
import 'package:personfin/providers/todos_provider.dart';
import 'package:personfin/screens/insights_screen.dart';
import 'package:personfin/widgets/allocation_bar.dart';
import 'package:personfin/widgets/todo_list_tile.dart';

import '../fakes.dart';

/// Wraps [InsightsScreen] in the two providers it reads. Neither
/// `InsightsProvider` nor `TodosProvider` has `load()` called
/// automatically — each test calls it (or not) explicitly, mirroring how
/// `DashboardScreen`'s tests drive `DashboardProvider`.
Widget buildSubject(
  InsightsProvider insightsProvider,
  TodosProvider todosProvider, {
  DashboardProvider? dashboardProvider,
}) {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<InsightsProvider>.value(value: insightsProvider),
      ChangeNotifierProvider<TodosProvider>.value(value: todosProvider),
      // Read when a target edit succeeds, to refresh the dashboard's drift.
      ChangeNotifierProvider<DashboardProvider>.value(
        value: dashboardProvider ??
            DashboardProvider(dashboardApi: FakeDashboardApi(), targetsApi: FakeTargetsApi()),
      ),
    ],
    child: const MaterialApp(home: InsightsScreen()),
  );
}

void main() {
  group('InsightsScreen', () {
    testWidgets('shows a spinner while insights state is loading', (tester) async {
      final insightsProvider =
          InsightsProvider(insightsApi: FakeInsightsApi(), targetsApi: FakeTargetsApi());
      final todosProvider = TodosProvider(todosApi: FakeTodosApi());

      await tester.pumpWidget(buildSubject(insightsProvider, todosProvider));

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('shows the error message and Retry button when insights state is error',
        (tester) async {
      final insightsApi = FakeInsightsApi(
        error: ApiException(503, 'Insights temporarily unavailable'),
      );
      final insightsProvider =
          InsightsProvider(insightsApi: insightsApi, targetsApi: FakeTargetsApi());
      await insightsProvider.load();
      final todosProvider = TodosProvider(todosApi: FakeTodosApi());

      await tester.pumpWidget(buildSubject(insightsProvider, todosProvider));

      expect(find.text('Insights temporarily unavailable'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      expect(insightsApi.callCount, 1);

      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();

      expect(insightsApi.callCount, 2);
    });

    // Review Focus: to-dos and insights are independent data; one failing
    // shouldn't hide the other. This specifically proves the to-do section
    // renders from TodosProvider.state alone, with InsightsProvider left in
    // a non-loaded (error) state — not just "both happen to be loaded in
    // the same test", which every other to-do-focused test below exercises
    // instead.
    testWidgets(
        'renders the to-do list from TodosProvider.state == loaded even while '
        'InsightsProvider is in a non-loaded (error) state', (tester) async {
      final insightsApi = FakeInsightsApi(
        error: ApiException(503, 'Insights temporarily unavailable'),
      );
      final insightsProvider =
          InsightsProvider(insightsApi: insightsApi, targetsApi: FakeTargetsApi());
      await insightsProvider.load();
      expect(insightsProvider.state, LoadState.error);

      final todosApi = FakeTodosApi(
        fixedTodos: [
          TodoItem(id: 1, description: 'Open a new account', done: false, relatedAssetClass: null),
        ],
      );
      final todosProvider = TodosProvider(todosApi: todosApi);
      await todosProvider.load();
      expect(todosProvider.state, LoadState.loaded);

      // Deliberately not pumpAndSettle(): the insights section's error
      // state here renders no perpetual animation, but a plain pump is
      // enough since both providers are already resolved before the
      // first frame — avoids ever depending on an animation to finish.
      await tester.pumpWidget(buildSubject(insightsProvider, todosProvider));
      await tester.pump();

      // Insights section still shows its own error UI...
      expect(find.text('Insights temporarily unavailable'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      // ...and the to-do list renders anyway.
      expect(find.byType(TodoListTile), findsOneWidget);
      expect(find.text('Open a new account'), findsOneWidget);
    });

    testWidgets('renders an allocation bar per target with correct actual-vs-target fill',
        (tester) async {
      final data = InsightsData(
        dashboard: DashboardData(
          netWorth: 1000.0,
          currency: 'CAD',
          byAssetClass: {'equity': 650.0, 'bond': 350.0},
          byCountry: {},
          accounts: [],
          trend: [],
        ),
        drift: [],
        narrative: InsightsNarrative(summary: 'Looking balanced overall.', actionItems: []),
        narrativeUnavailable: false,
      );
      final targets = [
        AllocationTarget(id: 1, assetClass: 'equity', targetPct: 60.0, isUserSet: true),
        AllocationTarget(id: 2, assetClass: 'bond', targetPct: 40.0, isUserSet: true),
      ];
      final insightsProvider = InsightsProvider(
        insightsApi: FakeInsightsApi(fixedData: data),
        targetsApi: FakeTargetsApi(fixedTargets: targets),
      );
      await insightsProvider.load();
      final todosProvider = TodosProvider(todosApi: FakeTodosApi());

      await tester.pumpWidget(buildSubject(insightsProvider, todosProvider));

      final bars = tester.widgetList<AllocationBar>(find.byType(AllocationBar)).toList();
      expect(bars, hasLength(2));

      final equityBar = bars.firstWhere((b) => b.assetClass == 'equity');
      expect(equityBar.targetPct, 60.0);
      expect(equityBar.actualPct, 65.0);

      final bondBar = bars.firstWhere((b) => b.assetClass == 'bond');
      expect(bondBar.targetPct, 40.0);
      expect(bondBar.actualPct, 35.0);
    });

    testWidgets('colors a drifted asset class bar differently from a non-drifted one',
        (tester) async {
      final data = InsightsData(
        dashboard: DashboardData(
          netWorth: 1000.0,
          currency: 'CAD',
          byAssetClass: {'equity': 650.0, 'bond': 350.0},
          byCountry: {},
          accounts: [],
          trend: [],
        ),
        drift: [
          DriftFlag(assetClass: 'equity', targetPct: 60.0, actualPct: 65.0, deltaPct: 5.0),
        ],
        narrative: InsightsNarrative(summary: 'Equity is a bit high.', actionItems: []),
        narrativeUnavailable: false,
      );
      final targets = [
        AllocationTarget(id: 1, assetClass: 'equity', targetPct: 60.0, isUserSet: true),
        AllocationTarget(id: 2, assetClass: 'bond', targetPct: 40.0, isUserSet: true),
      ];
      final insightsProvider = InsightsProvider(
        insightsApi: FakeInsightsApi(fixedData: data),
        targetsApi: FakeTargetsApi(fixedTargets: targets),
      );
      await insightsProvider.load();
      final todosProvider = TodosProvider(todosApi: FakeTodosApi());

      await tester.pumpWidget(buildSubject(insightsProvider, todosProvider));

      final bars = tester.widgetList<AllocationBar>(find.byType(AllocationBar)).toList();
      final equityBar = bars.firstWhere((b) => b.assetClass == 'equity');
      final bondBar = bars.firstWhere((b) => b.assetClass == 'bond');
      expect(equityBar.isDrifted, isTrue);
      expect(bondBar.isDrifted, isFalse);

      final equityFill =
          tester.widget<Container>(find.byKey(const ValueKey('allocation-fill-equity')));
      final bondFill = tester.widget<Container>(find.byKey(const ValueKey('allocation-fill-bond')));
      expect((equityFill.decoration as BoxDecoration).color, Colors.amber.shade700);
      expect((bondFill.decoration as BoxDecoration).color, Colors.green.shade700);
    });

    testWidgets('shows a "suggested" label on a target that is not user-set', (tester) async {
      final data = InsightsData(
        dashboard: DashboardData(
          netWorth: 1000.0,
          currency: 'CAD',
          byAssetClass: {'equity': 650.0, 'bond': 350.0},
          byCountry: {},
          accounts: [],
          trend: [],
        ),
        drift: [],
        narrative: InsightsNarrative(summary: 'Looking balanced overall.', actionItems: []),
        narrativeUnavailable: false,
      );
      final targets = [
        AllocationTarget(id: 1, assetClass: 'equity', targetPct: 60.0, isUserSet: true),
        AllocationTarget(id: 2, assetClass: 'bond', targetPct: 40.0, isUserSet: false),
      ];
      final insightsProvider = InsightsProvider(
        insightsApi: FakeInsightsApi(fixedData: data),
        targetsApi: FakeTargetsApi(fixedTargets: targets),
      );
      await insightsProvider.load();
      final todosProvider = TodosProvider(todosApi: FakeTodosApi());

      await tester.pumpWidget(buildSubject(insightsProvider, todosProvider));

      expect(find.text('suggested'), findsOneWidget);
    });

    testWidgets(
        'tapping an allocation bar opens the edit dialog pre-filled with its current target, '
        'and submitting a new value calls InsightsProvider.updateTarget', (tester) async {
      final data = InsightsData(
        dashboard: DashboardData(
          netWorth: 1000.0,
          currency: 'CAD',
          byAssetClass: {'equity': 650.0, 'bond': 350.0},
          byCountry: {},
          accounts: [],
          trend: [],
        ),
        drift: [],
        narrative: InsightsNarrative(summary: 'Looking balanced overall.', actionItems: []),
        narrativeUnavailable: false,
      );
      final targets = [
        AllocationTarget(id: 1, assetClass: 'equity', targetPct: 60.0, isUserSet: true),
        AllocationTarget(id: 2, assetClass: 'bond', targetPct: 40.0, isUserSet: true),
      ];
      final targetsApi = FakeTargetsApi(fixedTargets: targets);
      final insightsProvider = InsightsProvider(
        insightsApi: FakeInsightsApi(fixedData: data),
        targetsApi: targetsApi,
      );
      await insightsProvider.load();
      final todosProvider = TodosProvider(todosApi: FakeTodosApi());

      await tester.pumpWidget(buildSubject(insightsProvider, todosProvider));

      await tester.tap(
        find.byWidgetPredicate((w) => w is AllocationBar && w.assetClass == 'bond'),
      );
      await tester.pumpAndSettle();

      final textField = tester.widget<TextField>(find.byType(TextField));
      expect(textField.controller!.text, '40');

      await tester.enterText(find.byType(TextField), '55');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(targetsApi.lastUpdatedAssetClass, 'bond');
      expect(targetsApi.lastUpdatedTargetPct, 55.0);
    });

    // Review Focus
    testWidgets('shows the narrative summary as-is when narrativeUnavailable is true, '
        'with no extra error banner', (tester) async {
      const summary = "Insights are temporarily unavailable, but here's your allocation.";
      final data = InsightsData(
        dashboard: DashboardData(
          netWorth: 1000.0,
          currency: 'CAD',
          byAssetClass: {'equity': 650.0, 'bond': 350.0},
          byCountry: {},
          accounts: [],
          trend: [],
        ),
        drift: [],
        narrative: InsightsNarrative(summary: summary, actionItems: []),
        narrativeUnavailable: true,
      );
      final targets = [
        AllocationTarget(id: 1, assetClass: 'equity', targetPct: 60.0, isUserSet: true),
        AllocationTarget(id: 2, assetClass: 'bond', targetPct: 40.0, isUserSet: true),
      ];
      final insightsProvider = InsightsProvider(
        insightsApi: FakeInsightsApi(fixedData: data),
        targetsApi: FakeTargetsApi(fixedTargets: targets),
      );
      await insightsProvider.load();
      final todosProvider = TodosProvider(todosApi: FakeTodosApi());

      await tester.pumpWidget(buildSubject(insightsProvider, todosProvider));

      expect(find.text(summary), findsOneWidget);
      // No extra error banner on top of the narrative's own friendly text:
      // exactly one Card (the narrative card itself) and no error iconography.
      expect(find.byType(Card), findsOneWidget);
      expect(find.byIcon(Icons.error), findsNothing);
      expect(find.byIcon(Icons.warning_amber), findsNothing);
    });

    // Review Focus: zero net worth
    testWidgets('shows the zero-net-worth narrative text and still renders the to-do list',
        (tester) async {
      const noHoldingsSummary =
          'No holdings yet — once you add some accounts, insights will appear here';
      final data = InsightsData(
        dashboard: DashboardData(
          netWorth: 0,
          currency: 'CAD',
          byAssetClass: {},
          byCountry: {},
          accounts: [],
          trend: [],
        ),
        drift: [],
        narrative: InsightsNarrative(summary: noHoldingsSummary, actionItems: []),
        narrativeUnavailable: false,
      );
      final targets = [
        AllocationTarget(id: 1, assetClass: 'equity', targetPct: 60.0, isUserSet: true),
        AllocationTarget(id: 2, assetClass: 'bond', targetPct: 40.0, isUserSet: true),
      ];
      final insightsProvider = InsightsProvider(
        insightsApi: FakeInsightsApi(fixedData: data),
        targetsApi: FakeTargetsApi(fixedTargets: targets),
      );
      await insightsProvider.load();
      final todosApi = FakeTodosApi(
        fixedTodos: [
          TodoItem(id: 1, description: 'Open a new account', done: false, relatedAssetClass: null),
        ],
      );
      final todosProvider = TodosProvider(todosApi: todosApi);
      await todosProvider.load();

      await tester.pumpWidget(buildSubject(insightsProvider, todosProvider));

      expect(find.text(noHoldingsSummary), findsOneWidget);
      expect(find.byType(TodoListTile), findsOneWidget);

      // The netWorth == 0 guard: actualPct must be 0, not a divide-by-zero.
      final bars = tester.widgetList<AllocationBar>(find.byType(AllocationBar)).toList();
      expect(bars, isNotEmpty);
      for (final bar in bars) {
        expect(bar.actualPct, 0.0);
      }
    });

    testWidgets('renders one TodoListTile per todo, and tapping its checkbox calls '
        'TodosProvider.toggle', (tester) async {
      final todosApi = FakeTodosApi(
        fixedTodos: [
          TodoItem(id: 1, description: 'Rebalance equity', done: false, relatedAssetClass: null),
          TodoItem(id: 2, description: 'Call advisor', done: true, relatedAssetClass: null),
        ],
      );
      final todosProvider = TodosProvider(todosApi: todosApi);
      await todosProvider.load();
      final insightsProvider =
          InsightsProvider(insightsApi: FakeInsightsApi(), targetsApi: FakeTargetsApi());
      await insightsProvider.load();

      await tester.pumpWidget(buildSubject(insightsProvider, todosProvider));

      expect(find.byType(TodoListTile), findsNWidgets(2));

      final doneTile = tester.widget<TodoListTile>(
        find.byWidgetPredicate((w) => w is TodoListTile && w.todo.id == 2),
      );
      expect(doneTile.todo.done, isTrue);

      final notDoneTileFinder =
          find.byWidgetPredicate((w) => w is TodoListTile && w.todo.id == 1);
      final checkbox = find.descendant(of: notDoneTileFinder, matching: find.byType(Checkbox));
      await tester.tap(checkbox);
      await tester.pumpAndSettle();

      expect(todosApi.lastSetDoneId, 1);
      expect(todosApi.lastSetDoneValue, isTrue);
    });

    testWidgets('submitting the add-todo field calls TodosProvider.add and clears the field',
        (tester) async {
      final todosApi = FakeTodosApi(fixedTodos: []);
      final todosProvider = TodosProvider(todosApi: todosApi);
      await todosProvider.load();
      final insightsProvider =
          InsightsProvider(insightsApi: FakeInsightsApi(), targetsApi: FakeTargetsApi());
      await insightsProvider.load();

      await tester.pumpWidget(buildSubject(insightsProvider, todosProvider));

      await tester.enterText(find.byType(TextField), 'Call the bank');
      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();

      expect(todosApi.lastCreatedDescription, 'Call the bank');
      final textField = tester.widget<TextField>(find.byType(TextField));
      expect(textField.controller!.text, '');
    });

    testWidgets("tapping a todo's delete action calls TodosProvider.remove", (tester) async {
      final todosApi = FakeTodosApi(
        fixedTodos: [
          TodoItem(id: 5, description: 'Rebalance equity', done: false, relatedAssetClass: null),
        ],
      );
      final todosProvider = TodosProvider(todosApi: todosApi);
      await todosProvider.load();
      final insightsProvider =
          InsightsProvider(insightsApi: FakeInsightsApi(), targetsApi: FakeTargetsApi());
      await insightsProvider.load();

      await tester.pumpWidget(buildSubject(insightsProvider, todosProvider));

      await tester.tap(find.byIcon(Icons.delete_outline));
      await tester.pumpAndSettle();

      expect(todosApi.lastDeletedId, 5);
    });
  
    testWidgets('shows a SnackBar when updateTarget fails, and again on a repeat failure with the '
        'same message', (tester) async {
      final targetsApi = FakeTargetsApi(
        updateTargetError: ApiException(422, 'target_pct must be between 0 and 100'),
      );
      final insightsProvider =
          InsightsProvider(insightsApi: FakeInsightsApi(), targetsApi: targetsApi);
      await insightsProvider.load();
      final todosProvider = TodosProvider(todosApi: FakeTodosApi());
      await todosProvider.load();

      await tester.pumpWidget(buildSubject(insightsProvider, todosProvider));

      await insightsProvider.updateTarget('Equity', 70.0);
      await tester.pump();
      expect(find.widgetWithText(SnackBar, 'target_pct must be between 0 and 100'), findsOneWidget);
      // Shown once, then consumed — a rebuild doesn't re-show it.
      expect(insightsProvider.errorMessage, isNull);

      ScaffoldMessenger.of(tester.element(find.byType(InsightsScreen))).clearSnackBars();
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsNothing);

      await insightsProvider.updateTarget('Equity', 70.0);
      await tester.pump();
      expect(find.widgetWithText(SnackBar, 'target_pct must be between 0 and 100'), findsOneWidget);
    });

    testWidgets('shows a SnackBar when adding a to-do fails (the optimistic row is rolled back)',
        (tester) async {
      final todosApi = FakeTodosApi(
        fixedTodos: [],
        createTodoError: ApiException(422, 'description must not be blank'),
      );
      final todosProvider = TodosProvider(todosApi: todosApi);
      await todosProvider.load();
      final insightsProvider =
          InsightsProvider(insightsApi: FakeInsightsApi(), targetsApi: FakeTargetsApi());
      await insightsProvider.load();

      await tester.pumpWidget(buildSubject(insightsProvider, todosProvider));

      await tester.enterText(find.byType(TextField), 'Call the bank');
      await tester.tap(find.byIcon(Icons.add));
      await tester.pump();
      await tester.pump();

      expect(find.byType(TodoListTile), findsNothing);
      expect(find.widgetWithText(SnackBar, 'description must not be blank'), findsOneWidget);
    });

    testWidgets('shows a SnackBar when toggling a to-do fails', (tester) async {
      final todosApi = FakeTodosApi(
        fixedTodos: [
          TodoItem(id: 1, description: 'Rebalance equity', done: false, relatedAssetClass: null),
        ],
        setDoneError: ApiException(500, 'Could not update to-do'),
      );
      final todosProvider = TodosProvider(todosApi: todosApi);
      await todosProvider.load();
      final insightsProvider =
          InsightsProvider(insightsApi: FakeInsightsApi(), targetsApi: FakeTargetsApi());
      await insightsProvider.load();

      await tester.pumpWidget(buildSubject(insightsProvider, todosProvider));

      await tester.tap(find.byType(Checkbox));
      await tester.pump();
      await tester.pump();

      expect(find.widgetWithText(SnackBar, 'Could not update to-do'), findsOneWidget);
    });

    testWidgets('shows a SnackBar when deleting a to-do fails', (tester) async {
      final todosApi = FakeTodosApi(
        fixedTodos: [
          TodoItem(id: 5, description: 'Rebalance equity', done: false, relatedAssetClass: null),
        ],
        deleteTodoError: ApiException(500, 'Could not delete to-do'),
      );
      final todosProvider = TodosProvider(todosApi: todosApi);
      await todosProvider.load();
      final insightsProvider =
          InsightsProvider(insightsApi: FakeInsightsApi(), targetsApi: FakeTargetsApi());
      await insightsProvider.load();

      await tester.pumpWidget(buildSubject(insightsProvider, todosProvider));

      await tester.tap(find.byIcon(Icons.delete_outline));
      await tester.pump();
      await tester.pump();

      expect(find.byType(TodoListTile), findsOneWidget);
      expect(find.widgetWithText(SnackBar, 'Could not delete to-do'), findsOneWidget);
    });

    testWidgets('shows an error + Retry row in the to-do section when the to-dos fail to load, '
        'and Retry reloads them', (tester) async {
      final failingTodosApi = FakeTodosApi(listTodosError: ApiException(500, 'Internal server error'));
      final todosProvider = TodosProvider(todosApi: failingTodosApi);
      await todosProvider.load();
      expect(todosProvider.state, LoadState.error);
      final insightsProvider =
          InsightsProvider(insightsApi: FakeInsightsApi(), targetsApi: FakeTargetsApi());
      await insightsProvider.load();

      await tester.pumpWidget(buildSubject(insightsProvider, todosProvider));

      expect(find.text('To-dos'), findsOneWidget);
      expect(find.text('Internal server error'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Retry'), findsOneWidget);
      // A load failure is shown inline, not (also) as a SnackBar.
      expect(find.byType(SnackBar), findsNothing);

      expect(failingTodosApi.listTodosCallCount, 1);
      await tester.tap(find.widgetWithText(TextButton, 'Retry'));
      await tester.pumpAndSettle();
      // Still failing (same fake), but Retry did re-run load().
      expect(failingTodosApi.listTodosCallCount, 2);
      expect(find.text('Internal server error'), findsOneWidget);
      expect(todosProvider.state, LoadState.error);
    });
      testWidgets(
        "a successful target edit refreshes both this screen's drift highlighting and the "
        "dashboard's drift banner", (tester) async {
      final data = InsightsData(
        dashboard: DashboardData(
          netWorth: 1000.0,
          currency: 'CAD',
          byAssetClass: {'equity': 650.0, 'bond': 350.0},
          byCountry: {},
          accounts: [],
          trend: [],
        ),
        drift: [DriftFlag(assetClass: 'equity', targetPct: 60.0, actualPct: 65.0, deltaPct: 5.0)],
        narrative: InsightsNarrative(summary: 'Equity is a bit high.', actionItems: []),
        narrativeUnavailable: false,
      );
      final targets = [
        AllocationTarget(id: 1, assetClass: 'equity', targetPct: 60.0, isUserSet: true),
        AllocationTarget(id: 2, assetClass: 'bond', targetPct: 40.0, isUserSet: true),
      ];
      // After the edit (equity target -> 65%), the server reports no drift.
      final targetsApi = FakeTargetsApi(fixedTargets: targets, fixedDrift: []);
      final insightsProvider = InsightsProvider(
        insightsApi: FakeInsightsApi(fixedData: data),
        targetsApi: targetsApi,
      );
      await insightsProvider.load();
      final dashboardTargetsApi = FakeTargetsApi(fixedDrift: driftFor('CAD'));
      final dashboardProvider =
          DashboardProvider(dashboardApi: FakeDashboardApi(), targetsApi: dashboardTargetsApi);
      await dashboardProvider.load();
      expect(dashboardProvider.drift, isNotEmpty);
      final todosProvider = TodosProvider(todosApi: FakeTodosApi());

      await tester.pumpWidget(buildSubject(insightsProvider, todosProvider,
          dashboardProvider: dashboardProvider));

      AllocationBar equityBar() => tester.widget<AllocationBar>(
          find.byWidgetPredicate((w) => w is AllocationBar && w.assetClass == 'equity'));
      expect(equityBar().isDrifted, isTrue);

      await tester.tap(find.byWidgetPredicate((w) => w is AllocationBar && w.assetClass == 'equity'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, '65');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(targetsApi.lastUpdatedTargetPct, 65.0);
      expect(equityBar().isDrifted, isFalse, reason: 'insights drift re-fetched after the edit');
      expect(dashboardTargetsApi.callCount, 2,
          reason: "dashboard's drift re-fetched after the edit");
    });
  });
}
