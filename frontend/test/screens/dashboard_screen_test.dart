import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import 'package:personfin/api/api_client.dart';
import 'package:personfin/models/dashboard.dart';
import 'package:personfin/models/drift_flag.dart';
import 'package:personfin/providers/dashboard_provider.dart';
import 'package:personfin/screens/dashboard_screen.dart';
import 'package:personfin/services/image_picker_service.dart';
import 'package:personfin/widgets/drift_alert_banner.dart';
import 'package:personfin/widgets/net_worth_hero.dart';
import 'package:personfin/widgets/trend_sparkline.dart';

import '../fakes.dart';

/// Wraps [DashboardScreen] in the provider it reads and a minimal GoRouter
/// so taps that call `context.go`/`context.push` (the drift banner, the
/// FAB) resolve against real routes instead of crashing with "no
/// GoRouter found". The `/upload` placeholder renders whatever `extra` the
/// FAB passed it, so tests can assert the exact picked image was forwarded.
({Widget widget, GoRouter router}) buildSubject(
  DashboardProvider provider, {
  ImagePickerService? imagePickerService,
}) {
  final router = GoRouter(
    initialLocation: '/dashboard',
    routes: [
      GoRoute(
        path: '/dashboard',
        builder: (c, s) => DashboardScreen(imagePickerService: imagePickerService),
      ),
      GoRoute(
        path: '/insights',
        builder: (c, s) => const Scaffold(body: Text('Insights Screen')),
      ),
      GoRoute(
        path: '/upload',
        builder: (c, s) {
          final extra = s.extra as ({List<int> bytes, String filename, String mimeType})?;
          return Scaffold(body: Text('Upload Screen: ${extra?.filename}'));
        },
      ),
    ],
  );
  final widget = ChangeNotifierProvider.value(
    value: provider,
    child: MaterialApp.router(routerConfig: router),
  );
  return (widget: widget, router: router);
}

String currentLocation(GoRouter router) =>
    router.routerDelegate.currentConfiguration.uri.toString();

void main() {
  group('DashboardScreen', () {
    testWidgets('shows a spinner while state is loading', (tester) async {
      final provider = DashboardProvider(
        dashboardApi: FakeDashboardApi(),
        targetsApi: FakeTargetsApi(),
      );

      await tester.pumpWidget(buildSubject(provider).widget);

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets(
        'shows the error message and a Retry button when state is error, '
        'and tapping Retry calls provider.load() again', (tester) async {
      final dashboardApi = FakeDashboardApi(
        error: ApiException(503, 'Dashboard temporarily unavailable'),
      );
      final targetsApi = FakeTargetsApi();
      final provider = DashboardProvider(dashboardApi: dashboardApi, targetsApi: targetsApi);
      await provider.load();

      await tester.pumpWidget(buildSubject(provider).widget);

      expect(find.text('Dashboard temporarily unavailable'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      expect(dashboardApi.callCount, 1);

      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();

      expect(dashboardApi.callCount, 2);
    });

    // Review Focus: zero net worth / no holdings yet must render a
    // deliberate empty state, not a zero-filled chart or blank screen.
    testWidgets(
        'shows the empty-state message when loaded with netWorth == 0 and '
        'renders no hero/sparkline/banner', (tester) async {
      final dashboardApi = FakeDashboardApi(
        fixedData: DashboardData(
          netWorth: 0,
          currency: 'CAD',
          byAssetClass: {},
          byCountry: {},
          accounts: [],
          trend: [],
        ),
      );
      final targetsApi = FakeTargetsApi(fixedDrift: []);
      final provider = DashboardProvider(dashboardApi: dashboardApi, targetsApi: targetsApi);
      await provider.load();

      await tester.pumpWidget(buildSubject(provider).widget);

      expect(
        find.text('No accounts yet — tap the camera button to add your first screenshot'),
        findsOneWidget,
      );
      expect(find.byType(NetWorthHero), findsNothing);
      expect(find.byType(TrendSparkline), findsNothing);
      expect(find.byType(DriftAlertBanner), findsNothing);
    });

    testWidgets(
        'shows the formatted net worth, account list with asOf dates, and '
        'no drift banner when drift is empty', (tester) async {
      final dashboardData = DashboardData(
        netWorth: 1234.56,
        currency: 'CAD',
        byAssetClass: {'Equity': 1000.0, 'Cash': 234.56},
        byCountry: {'Canada': 1234.56},
        accounts: [
          AccountSummary(
            accountId: 1,
            name: 'Checking',
            asOf: DateTime(2026, 1, 5),
            value: 1000.0,
          ),
          AccountSummary(accountId: 2, name: 'Savings', asOf: null, value: 234.56),
        ],
        trend: [
          TrendPoint(takenAt: DateTime(2026, 1, 1), netWorth: 1200.0),
          TrendPoint(takenAt: DateTime(2026, 1, 5), netWorth: 1234.56),
        ],
      );
      final dashboardApi = FakeDashboardApi(fixedData: dashboardData);
      final targetsApi = FakeTargetsApi(fixedDrift: []);
      final provider = DashboardProvider(dashboardApi: dashboardApi, targetsApi: targetsApi);
      await provider.load();

      await tester.pumpWidget(buildSubject(provider).widget);

      final expectedNetWorth = NumberFormat.currency(name: 'CAD').format(1234.56);
      expect(find.text(expectedNetWorth), findsOneWidget);
      expect(find.text('Checking'), findsOneWidget);
      expect(find.text('Savings'), findsOneWidget);
      expect(find.textContaining('updated'), findsOneWidget);
      expect(find.textContaining('no data yet'), findsOneWidget);
      expect(find.byType(DriftAlertBanner), findsNothing);
    });

    testWidgets(
        'shows the drift banner when drift is non-empty, and tapping it '
        'navigates toward /insights', (tester) async {
      final dashboardApi = FakeDashboardApi();
      final targetsApi = FakeTargetsApi(
        fixedDrift: [
          DriftFlag(assetClass: 'Equity', targetPct: 60.0, actualPct: 65.0, deltaPct: 5.0),
        ],
      );
      final provider = DashboardProvider(dashboardApi: dashboardApi, targetsApi: targetsApi);
      await provider.load();

      final subject = buildSubject(provider);
      await tester.pumpWidget(subject.widget);

      expect(find.byType(DriftAlertBanner), findsOneWidget);
      expect(find.text('Equity is 5% above target'), findsOneWidget);

      await tester.tap(find.byType(DriftAlertBanner));
      await tester.pumpAndSettle();

      expect(currentLocation(subject.router), '/insights');
      expect(find.text('Insights Screen'), findsOneWidget);
    });

    testWidgets('tapping the currency switcher and selecting a new currency calls '
        'provider.setCurrency', (tester) async {
      final dashboardApi = FakeDashboardApi();
      final targetsApi = FakeTargetsApi();
      final provider = DashboardProvider(dashboardApi: dashboardApi, targetsApi: targetsApi);
      await provider.load();
      expect(provider.currency, 'CAD');

      await tester.pumpWidget(buildSubject(provider).widget);

      await tester.tap(find.byType(DropdownButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('USD').last);
      await tester.pumpAndSettle();

      expect(provider.currency, 'USD');
      expect(dashboardApi.lastRequestedCurrency, 'USD');
      expect(targetsApi.lastRequestedCurrency, 'USD');
    });

    // The picker must run directly from the FAB's onPressed — not from a
    // screen reached via navigation — so the platform's file/camera dialog
    // is invoked within the original tap's user-gesture context. Calling it
    // one hop later (e.g. from the pushed /upload screen's initState, as a
    // previous version of this flow did) means the browser's synthetic
    // `element.click()` for that dialog can be silently ignored (seen in
    // production on iOS Chrome/Safari: no dialog ever opens, and the
    // picker's returned future then never resolves), leaving the app stuck
    // on a spinner forever.
    testWidgets('tapping the camera FAB picks an image and navigates to /upload with it',
        (tester) async {
      final dashboardApi = FakeDashboardApi();
      final targetsApi = FakeTargetsApi();
      final provider = DashboardProvider(dashboardApi: dashboardApi, targetsApi: targetsApi);
      await provider.load();
      final imagePickerService = FakeImagePickerService(
        result: (bytes: [1, 2, 3], filename: 'shot.png', mimeType: 'image/png'),
      );

      final subject = buildSubject(provider, imagePickerService: imagePickerService);
      await tester.pumpWidget(subject.widget);

      await tester.tap(find.byIcon(Icons.camera_alt));
      await tester.pumpAndSettle();

      expect(imagePickerService.callCount, 1);
      // Not currentLocation(subject.router): go_router's currentConfiguration.uri
      // reflects the base route, not a pushed one — the rendered content is the
      // reliable signal that the push (with the picked image) landed.
      expect(find.text('Upload Screen: shot.png'), findsOneWidget);
    });

    testWidgets(
        'tapping the camera FAB when the picker returns null (the user cancelled) stays on '
        '/dashboard', (tester) async {
      final dashboardApi = FakeDashboardApi();
      final targetsApi = FakeTargetsApi();
      final provider = DashboardProvider(dashboardApi: dashboardApi, targetsApi: targetsApi);
      await provider.load();
      final imagePickerService = FakeImagePickerService(result: null);

      final subject = buildSubject(provider, imagePickerService: imagePickerService);
      await tester.pumpWidget(subject.widget);

      await tester.tap(find.byIcon(Icons.camera_alt));
      await tester.pumpAndSettle();

      expect(imagePickerService.callCount, 1);
      expect(currentLocation(subject.router), '/dashboard');
    });
  });
}
