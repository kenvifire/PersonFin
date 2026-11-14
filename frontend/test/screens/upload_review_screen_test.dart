import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import 'package:personfin/api/api_client.dart';
import 'package:personfin/api/uploads_api.dart';
import 'package:personfin/models/account.dart';
import 'package:personfin/models/extraction.dart';
import 'package:personfin/models/holding.dart';
import 'package:personfin/models/upload.dart';
import 'package:personfin/providers/dashboard_provider.dart';
import 'package:personfin/providers/insights_provider.dart';
import 'package:personfin/providers/upload_flow_provider.dart';
import 'package:personfin/screens/upload_review_screen.dart';

import '../fakes.dart';
import '../providers/upload_flow_provider_test.dart'
    show extractedRecord, failedRecord, FakeUploadsApi, FakeAccountsApi;

/// `UploadsApiBase` whose every call hangs forever (never completes), used
/// only to pin the provider in `uploading` so the spinner view can be
/// asserted without racing a real async resolution.
class _HangingUploadsApi implements UploadsApiBase {
  @override
  Future<int> createUpload({
    required List<int> bytes,
    required String filename,
    required String mimeType,
  }) =>
      Completer<int>().future;

  @override
  Future<UploadRecord> extractUpload(int uploadId) => Completer<UploadRecord>().future;

  @override
  Future<void> confirmUpload({
    required int uploadId,
    required int? accountId,
    required ({String name, String institution, String accountType})? newAccount,
    required DateTime takenAt,
    required List<HoldingIn> holdings,
  }) =>
      Completer<void>().future;

  @override
  Future<void> discardUpload(int uploadId) => Completer<void>().future;
}

({Widget widget, GoRouter router}) buildSubject({
  required UploadFlowProvider uploadProvider,
  DashboardProvider? dashboardProvider,
  InsightsProvider? insightsProvider,
}) {
  final router = GoRouter(
    initialLocation: '/dashboard',
    routes: [
      GoRoute(path: '/dashboard', builder: (c, s) => const Scaffold(body: Text('Dashboard Screen'))),
      GoRoute(
        path: '/upload',
        builder: (c, s) => UploadReviewScreen(
          picked: s.extra as ({List<int> bytes, String filename, String mimeType})?,
        ),
      ),
    ],
  );
  final widget = MultiProvider(
    providers: [
      ChangeNotifierProvider<UploadFlowProvider>.value(value: uploadProvider),
      ChangeNotifierProvider<DashboardProvider>.value(
        value: dashboardProvider ??
            DashboardProvider(dashboardApi: FakeDashboardApi(), targetsApi: FakeTargetsApi()),
      ),
      ChangeNotifierProvider<InsightsProvider>.value(
        value: insightsProvider ??
            InsightsProvider(insightsApi: FakeInsightsApi(), targetsApi: FakeTargetsApi()),
      ),
    ],
    child: MaterialApp.router(routerConfig: router),
  );
  return (widget: widget, router: router);
}

String currentLocation(GoRouter router) =>
    router.routerDelegate.currentConfiguration.uri.toString();

/// The review form is tall (holdings + date + account section); grows the
/// test surface so the Confirm/Discard row and other below-the-fold
/// controls are actually built and tappable, instead of being culled by
/// the viewport's default 800x600 size. Resets itself via [addTearDown].
Future<void> growSurface(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(800, 2400));
  addTearDown(() => tester.binding.setSurfaceSize(null));
}

void main() {
  group('UploadReviewScreen', () {
    testWidgets('shows the extracting spinner while state is uploading or extracting',
        (tester) async {
      final provider =
          UploadFlowProvider(uploadsApi: _HangingUploadsApi(), accountsApi: FakeAccountsApi());

      final subject = buildSubject(uploadProvider: provider);
      await growSurface(tester);
      await tester.pumpWidget(subject.widget);
      subject.router.push(
        '/upload',
        extra: (bytes: [1, 2, 3], filename: 'shot.png', mimeType: 'image/png'),
      );
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(provider.state, UploadFlowState.uploading);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.textContaining('Reading account details'), findsOneWidget);
    });

    testWidgets(
        'shows a pre-filled editable form when state is ready, with the suggested account '
        'pre-selected', (tester) async {
      final accountsApi = FakeAccountsApi(accounts: [
        AccountSummaryLite(id: 5, name: 'Brokerage', institution: 'Big Bank', accountType: 'brokerage'),
      ]);
      final uploadsApi = FakeUploadsApi(extractResult: extractedRecord());
      final provider = UploadFlowProvider(uploadsApi: uploadsApi, accountsApi: accountsApi);
      await provider.startUpload(bytes: [1], filename: 'shot.png', mimeType: 'image/png');
      await provider.loadAccounts();

      final subject = buildSubject(uploadProvider: provider);
      await growSurface(tester);
      await tester.pumpWidget(subject.widget);
      subject.router.push('/upload');
      await tester.pumpAndSettle();

      expect(find.text('AAPL'), findsOneWidget);
      expect(find.text('Brokerage'), findsOneWidget);
    });

    // Review Focus: extraction failure (HTTP 200, status "failed") must
    // show an empty, editable form with the error message, not a crash or
    // an error screen.
    testWidgets('shows an empty editable form with the error message when state is failed',
        (tester) async {
      final uploadsApi = FakeUploadsApi(extractResult: failedRecord());
      final provider = UploadFlowProvider(uploadsApi: uploadsApi, accountsApi: FakeAccountsApi());
      await provider.startUpload(bytes: [1], filename: 'shot.png', mimeType: 'image/png');

      final subject = buildSubject(uploadProvider: provider);
      await growSurface(tester);
      await tester.pumpWidget(subject.widget);
      subject.router.push('/upload');
      await tester.pumpAndSettle();

      expect(find.text('Vision service could not read the image'), findsOneWidget);
      expect(find.text('+ Add holding'), findsOneWidget);
      expect(find.text('AAPL'), findsNothing);
      final confirmButton =
          tester.widget<ElevatedButton>(find.widgetWithText(ElevatedButton, 'Confirm'));
      expect(confirmButton.onPressed, isNull);
    });

    testWidgets(
        'renders the form (no dropdown assertion) when the vision guesses are outside the fixed '
        'asset-class/currency lists, leaving those dropdowns unselected and Confirm disabled',
        (tester) async {
      final record = UploadRecord(
        id: 1,
        status: 'extracted',
        extractedPayload: ExtractionResult(
          institution: 'Big Bank',
          accountLabel: 'Investing',
          accountTypeGuess: 'brokerage',
          takenAtGuess: DateTime(2026, 11, 1),
          holdings: [
            DraftHolding(
              label: 'VTI',
              assetClassGuess: 'Stocks',
              quantity: 1,
              value: 100.0,
              currencyGuess: 'usd',
              countryGuess: 'US',
            ),
          ],
        ),
        extractionError: null,
        suggestedAccountId: 5,
      );
      final accountsApi = FakeAccountsApi(accounts: [
        AccountSummaryLite(id: 5, name: 'Brokerage', institution: 'Big Bank', accountType: 'brokerage'),
      ]);
      final provider = UploadFlowProvider(
        uploadsApi: FakeUploadsApi(extractResult: record),
        accountsApi: accountsApi,
      );
      await provider.startUpload(bytes: [1], filename: 'shot.png', mimeType: 'image/png');
      await provider.loadAccounts();

      final subject = buildSubject(uploadProvider: provider);
      await growSurface(tester);
      await tester.pumpWidget(subject.widget);
      subject.router.push('/upload');
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('VTI'), findsOneWidget);
      // 'usd' normalized to a valid, selected 'USD'; 'Stocks' left unselected.
      expect(find.text('USD'), findsOneWidget);
      expect(find.text('Stocks'), findsNothing);
      expect(provider.holdings.single.assetClass, isNull);
      final confirmButton =
          tester.widget<ElevatedButton>(find.widgetWithText(ElevatedButton, 'Confirm'));
      expect(confirmButton.onPressed, isNull);
    });

    testWidgets('Confirm button is disabled until every holding is complete and an account is '
        'chosen', (tester) async {
      final accountsApi = FakeAccountsApi(accounts: [
        AccountSummaryLite(id: 9, name: 'Savings', institution: 'Big Bank', accountType: 'bank'),
      ]);
      final uploadsApi = FakeUploadsApi(extractResult: extractedRecord());
      final provider = UploadFlowProvider(uploadsApi: uploadsApi, accountsApi: accountsApi);
      await provider.startUpload(bytes: [1], filename: 'shot.png', mimeType: 'image/png');
      // Force the "incomplete holding, no suggested account" starting point
      // this test wants, regardless of extractedRecord()'s own fixture
      // values.
      provider.suggestedAccountId = null;
      provider.holdings.first.country = '';
      await provider.loadAccounts();

      final subject = buildSubject(uploadProvider: provider);
      await growSurface(tester);
      await tester.pumpWidget(subject.widget);
      subject.router.push('/upload');
      await tester.pumpAndSettle();

      ElevatedButton confirmButton() =>
          tester.widget<ElevatedButton>(find.widgetWithText(ElevatedButton, 'Confirm'));
      expect(confirmButton().onPressed, isNull);

      // Complete the holding.
      await tester.enterText(find.widgetWithText(TextFormField, 'Country'), 'US');
      await tester.pumpAndSettle();
      expect(confirmButton().onPressed, isNull, reason: 'still missing an account selection');

      // Select the account.
      await tester.tap(find.byType(DropdownButtonFormField<int>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Savings').last);
      await tester.pumpAndSettle();

      expect(confirmButton().onPressed, isNotNull);

      // Isolate the isComplete check: break the holding's completeness
      // again while the account stays selected. Deleting the isComplete
      // check from _isConfirmEnabled wouldn't change any outcome above
      // (the "no account" cases were already disabled for an unrelated
      // reason) — this is the one case only that check can explain.
      await tester.enterText(find.widgetWithText(TextFormField, 'Country'), '');
      await tester.pumpAndSettle();
      expect(confirmButton().onPressed, isNull,
          reason: 'holding incomplete again even though an account is selected');
    });

    testWidgets('Confirm button stays disabled when holdings becomes empty, even with an '
        'account selected', (tester) async {
      final accountsApi = FakeAccountsApi(accounts: [
        AccountSummaryLite(id: 9, name: 'Savings', institution: 'Big Bank', accountType: 'bank'),
      ]);
      final uploadsApi = FakeUploadsApi(extractResult: extractedRecord());
      final provider = UploadFlowProvider(uploadsApi: uploadsApi, accountsApi: accountsApi);
      await provider.startUpload(bytes: [1], filename: 'shot.png', mimeType: 'image/png');
      // extractedRecord()'s single holding is already complete; drop the
      // suggested account so the dropdown starts unselected and this test
      // controls account-selection itself.
      provider.suggestedAccountId = null;
      await provider.loadAccounts();

      final subject = buildSubject(uploadProvider: provider);
      await growSurface(tester);
      await tester.pumpWidget(subject.widget);
      subject.router.push('/upload');
      await tester.pumpAndSettle();

      await tester.tap(find.byType(DropdownButtonFormField<int>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Savings').last);
      await tester.pumpAndSettle();

      ElevatedButton confirmButton() =>
          tester.widget<ElevatedButton>(find.widgetWithText(ElevatedButton, 'Confirm'));
      expect(confirmButton().onPressed, isNotNull);

      // Isolate the holdings.isNotEmpty check: remove the only holding
      // while the account selection is untouched. Only that check can
      // explain the button going back to disabled here.
      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();

      expect(provider.holdings, isEmpty);
      expect(confirmButton().onPressed, isNull,
          reason: 'no holdings left to confirm, even though an account is selected');
    });

    testWidgets('tapping Confirm calls provider.confirm with the selected account id',
        (tester) async {
      final accountsApi = FakeAccountsApi(accounts: [
        AccountSummaryLite(id: 5, name: 'Brokerage', institution: 'Big Bank', accountType: 'brokerage'),
      ]);
      final uploadsApi = FakeUploadsApi(extractResult: extractedRecord());
      final provider = UploadFlowProvider(uploadsApi: uploadsApi, accountsApi: accountsApi);
      await provider.startUpload(bytes: [1], filename: 'shot.png', mimeType: 'image/png');
      await provider.loadAccounts();
      final dashboardApi = FakeDashboardApi();
      final targetsApi = FakeTargetsApi();
      final dashboardProvider = DashboardProvider(dashboardApi: dashboardApi, targetsApi: targetsApi);
      final insightsApi = FakeInsightsApi();
      final insightsProvider =
          InsightsProvider(insightsApi: insightsApi, targetsApi: FakeTargetsApi());

      final subject = buildSubject(
        uploadProvider: provider,
        dashboardProvider: dashboardProvider,
        insightsProvider: insightsProvider,
      );
      await growSurface(tester);
      await tester.pumpWidget(subject.widget);
      subject.router.push('/upload');
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(ElevatedButton, 'Confirm'));
      await tester.pumpAndSettle();

      expect(uploadsApi.capturedAccountId, 5);
      expect(uploadsApi.capturedNewAccount, isNull);
      expect(provider.state, UploadFlowState.confirmed);
      expect(dashboardApi.callCount, 1);
      // Insights (allocation/drift/narrative) is refreshed too, not left stale.
      expect(insightsApi.callCount, 1);
      expect(insightsProvider.state, LoadState.loaded);
      expect(currentLocation(subject.router), '/dashboard');
    });

    testWidgets(
        'tapping Confirm after filling in "+ New account" calls provider.confirm with '
        'newAccount set and accountId null', (tester) async {
      final uploadsApi = FakeUploadsApi(extractResult: extractedRecord());
      final provider = UploadFlowProvider(uploadsApi: uploadsApi, accountsApi: FakeAccountsApi());
      await provider.startUpload(bytes: [1], filename: 'shot.png', mimeType: 'image/png');
      // extractedRecord()'s single holding is already complete; no
      // suggested/existing account exists, so the only path to an enabled
      // Confirm button is through "+ New account".
      provider.suggestedAccountId = null;
      await provider.loadAccounts();

      final subject = buildSubject(uploadProvider: provider);
      await growSurface(tester);
      await tester.pumpWidget(subject.widget);
      subject.router.push('/upload');
      await tester.pumpAndSettle();

      ElevatedButton confirmButton() =>
          tester.widget<ElevatedButton>(find.widgetWithText(ElevatedButton, 'Confirm'));
      expect(confirmButton().onPressed, isNull, reason: 'no account chosen yet');

      // Toggle to "+ New account" (mutually exclusive with the dropdown)
      // and fill in its fields.
      await tester.tap(find.text('+ New account'));
      await tester.pumpAndSettle();
      expect(find.byType(DropdownButtonFormField<int>), findsNothing);

      await tester.enterText(find.widgetWithText(TextFormField, 'Account name'), 'New Brokerage');
      await tester.enterText(find.widgetWithText(TextFormField, 'Institution'), 'New Bank');
      await tester.enterText(find.widgetWithText(TextFormField, 'Account type'), 'brokerage');
      await tester.pumpAndSettle();

      expect(confirmButton().onPressed, isNotNull);

      await tester.tap(find.widgetWithText(ElevatedButton, 'Confirm'));
      await tester.pumpAndSettle();

      expect(uploadsApi.capturedAccountId, isNull);
      expect(
        uploadsApi.capturedNewAccount,
        (name: 'New Brokerage', institution: 'New Bank', accountType: 'brokerage'),
      );
      expect(provider.state, UploadFlowState.confirmed);
    });

    testWidgets(
        'a non-409 confirm failure keeps the filled-in form on screen and shows the error in a '
        'SnackBar; Confirm can be retried', (tester) async {
      final accountsApi = FakeAccountsApi(accounts: [
        AccountSummaryLite(id: 5, name: 'Brokerage', institution: 'Big Bank', accountType: 'brokerage'),
      ]);
      final uploadsApi = FakeUploadsApi(
        extractResult: extractedRecord(),
        confirmError: ApiException(503, 'Exchange rate temporarily unavailable'),
      );
      final provider = UploadFlowProvider(uploadsApi: uploadsApi, accountsApi: accountsApi);
      await provider.startUpload(bytes: [1], filename: 'shot.png', mimeType: 'image/png');
      await provider.loadAccounts();

      final subject = buildSubject(uploadProvider: provider);
      await growSurface(tester);
      await tester.pumpWidget(subject.widget);
      subject.router.push('/upload');
      await tester.pumpAndSettle();

      await tester.enterText(find.widgetWithText(TextFormField, 'Country'), 'CA');
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Confirm'));
      await tester.pumpAndSettle();

      expect(provider.state, UploadFlowState.ready);
      expect(find.widgetWithText(SnackBar, 'Could not save: Exchange rate temporarily unavailable'),
          findsOneWidget);
      // Still on the review screen, with the extracted and hand-edited values intact.
      expect(find.byType(UploadReviewScreen), findsOneWidget);
      expect(find.text('AAPL'), findsOneWidget);
      expect(find.widgetWithText(TextFormField, 'CA'), findsOneWidget);
      expect(find.text('Brokerage'), findsOneWidget);
      expect(find.text('Discard'), findsOneWidget);
      final confirmButton =
          tester.widget<ElevatedButton>(find.widgetWithText(ElevatedButton, 'Confirm'));
      expect(confirmButton.onPressed, isNotNull);

      // Retrying sends the edited holding again.
      await tester.tap(find.widgetWithText(ElevatedButton, 'Confirm'));
      await tester.pumpAndSettle();
      expect(uploadsApi.capturedHoldings!.single.country, 'CA');
      expect(uploadsApi.capturedAccountId, 5);
    });

    testWidgets('tapping + Add holding appends a blank editable row', (tester) async {
      final uploadsApi = FakeUploadsApi(extractResult: extractedRecord());
      final provider = UploadFlowProvider(uploadsApi: uploadsApi, accountsApi: FakeAccountsApi());
      await provider.startUpload(bytes: [1], filename: 'shot.png', mimeType: 'image/png');

      final subject = buildSubject(uploadProvider: provider);
      await growSurface(tester);
      await tester.pumpWidget(subject.widget);
      subject.router.push('/upload');
      await tester.pumpAndSettle();

      expect(provider.holdings, hasLength(1));

      await tester.tap(find.text('+ Add holding'));
      await tester.pumpAndSettle();

      expect(provider.holdings, hasLength(2));
      expect(provider.holdings.last.isComplete, isFalse);
    });

    // Review Focus: a 409 "already finalized" race on confirm must show a
    // clear message and return to the dashboard, never crash.
    testWidgets('when state becomes alreadyFinalized, shows the message and navigates back '
        'toward /dashboard', (tester) async {
      final accountsApi = FakeAccountsApi(accounts: [
        AccountSummaryLite(id: 5, name: 'Brokerage', institution: 'Big Bank', accountType: 'brokerage'),
      ]);
      final uploadsApi = FakeUploadsApi(
        extractResult: extractedRecord(),
        confirmError: ApiException(409, 'Upload is already finalized'),
      );
      final provider = UploadFlowProvider(uploadsApi: uploadsApi, accountsApi: accountsApi);
      await provider.startUpload(bytes: [1], filename: 'shot.png', mimeType: 'image/png');
      await provider.loadAccounts();

      final subject = buildSubject(uploadProvider: provider);
      await growSurface(tester);
      await tester.pumpWidget(subject.widget);
      subject.router.push('/upload');
      await tester.pumpAndSettle();

      // Not pumpAndSettle: the alreadyFinalized state renders a spinner
      // behind the dialog (see UploadReviewScreen._buildBody) that
      // animates indefinitely until this test itself dismisses the
      // dialog below, so pumpAndSettle here would never quiesce.
      await tester.tap(find.widgetWithText(ElevatedButton, 'Confirm'));
      await tester.pump(); // confirm() starts: state -> confirming
      await tester.pump(); // confirmUpload's 409 rejects: state -> alreadyFinalized
      await tester.pump(); // post-frame callback fires: showDialog opens
      await tester.pump(const Duration(milliseconds: 300)); // dialog entrance transition

      expect(find.text('Upload is already finalized'), findsOneWidget);

      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();

      expect(currentLocation(subject.router), '/dashboard');
    });

    // Picker-cancel handling now lives on DashboardScreen (the picker runs
    // before navigating here at all) — see dashboard_screen_test.dart.
    testWidgets('with no picked image (e.g. a direct navigation), stays in the picking state '
        'without calling startUpload', (tester) async {
      final uploadsApi = FakeUploadsApi(extractResult: extractedRecord());
      final provider = UploadFlowProvider(uploadsApi: uploadsApi, accountsApi: FakeAccountsApi());

      final subject = buildSubject(uploadProvider: provider);
      await growSurface(tester);
      await tester.pumpWidget(subject.widget);
      subject.router.push('/upload');
      await tester.pump();

      expect(provider.state, UploadFlowState.picking);
    });

    // --- Many-holdings screenshots (e.g. a multi-position brokerage page) ---

    /// A record with [count] holdings, all complete except for one labeled
    /// `'Incomplete'` (missing its asset class), so tests can assert on
    /// collapsed-vs-expanded behavior without constructing each field.
    UploadRecord manyHoldingsRecord(int count) => UploadRecord(
          id: 1,
          status: 'extracted',
          extractedPayload: ExtractionResult(
            institution: 'Futu HK',
            accountLabel: 'US Stocks',
            accountTypeGuess: 'brokerage',
            takenAtGuess: DateTime(2026, 11, 1),
            holdings: [
              for (var i = 0; i < count - 1; i++)
                DraftHolding(
                  label: 'HOLD$i',
                  assetClassGuess: 'equity',
                  quantity: 10,
                  value: 100.0,
                  currencyGuess: 'USD',
                  countryGuess: 'US',
                ),
              DraftHolding(
                label: 'Incomplete',
                assetClassGuess: null,
                quantity: 5,
                value: 50.0,
                currencyGuess: 'USD',
                countryGuess: 'US',
              ),
            ],
          ),
          extractionError: null,
          suggestedAccountId: null,
        );

    testWidgets(
        'with more than 3 holdings, complete ones start collapsed to a summary and the '
        'incomplete one starts expanded', (tester) async {
      final uploadsApi = FakeUploadsApi(extractResult: manyHoldingsRecord(4));
      final provider = UploadFlowProvider(uploadsApi: uploadsApi, accountsApi: FakeAccountsApi());
      await provider.startUpload(bytes: [1], filename: 'shot.png', mimeType: 'image/png');

      final subject = buildSubject(uploadProvider: provider);
      await growSurface(tester);
      await tester.pumpWidget(subject.widget);
      subject.router.push('/upload');
      await tester.pumpAndSettle();

      // Complete holdings: label shown once (collapsed summary), no editable
      // Label field for them.
      expect(find.text('HOLD0'), findsOneWidget);
      expect(find.text('HOLD1'), findsOneWidget);
      expect(find.text('HOLD2'), findsOneWidget);
      // The incomplete one starts expanded: its Label field carries the
      // text, so it's the only one with a matching TextFormField.
      expect(find.widgetWithText(TextFormField, 'Incomplete'), findsOneWidget);
      expect(find.widgetWithText(TextFormField, 'HOLD0'), findsNothing);
    });

    testWidgets('with 3 or fewer holdings, every row starts expanded regardless of completeness',
        (tester) async {
      final uploadsApi = FakeUploadsApi(extractResult: manyHoldingsRecord(3));
      final provider = UploadFlowProvider(uploadsApi: uploadsApi, accountsApi: FakeAccountsApi());
      await provider.startUpload(bytes: [1], filename: 'shot.png', mimeType: 'image/png');

      final subject = buildSubject(uploadProvider: provider);
      await growSurface(tester);
      await tester.pumpWidget(subject.widget);
      subject.router.push('/upload');
      await tester.pumpAndSettle();

      expect(find.widgetWithText(TextFormField, 'HOLD0'), findsOneWidget);
      expect(find.widgetWithText(TextFormField, 'HOLD1'), findsOneWidget);
      expect(find.widgetWithText(TextFormField, 'Incomplete'), findsOneWidget);
    });

    testWidgets('tapping a collapsed holding expands it, and tapping again collapses it back',
        (tester) async {
      final uploadsApi = FakeUploadsApi(extractResult: manyHoldingsRecord(4));
      final provider = UploadFlowProvider(uploadsApi: uploadsApi, accountsApi: FakeAccountsApi());
      await provider.startUpload(bytes: [1], filename: 'shot.png', mimeType: 'image/png');

      final subject = buildSubject(uploadProvider: provider);
      await growSurface(tester);
      await tester.pumpWidget(subject.widget);
      subject.router.push('/upload');
      await tester.pumpAndSettle();

      expect(find.widgetWithText(TextFormField, 'HOLD0'), findsNothing);

      await tester.tap(find.text('HOLD0'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextFormField, 'HOLD0'), findsOneWidget);

      // Tapping its header row again (now showing only the toggle icon,
      // found via the chevron) collapses it back.
      await tester.tap(find.byIcon(Icons.expand_less).first);
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextFormField, 'HOLD0'), findsNothing);
    });

    testWidgets(
        "the '+ New account' fields are pre-filled from the extraction's institution/account "
        'label/account type guesses', (tester) async {
      final uploadsApi = FakeUploadsApi(extractResult: manyHoldingsRecord(4));
      final provider = UploadFlowProvider(uploadsApi: uploadsApi, accountsApi: FakeAccountsApi());
      await provider.startUpload(bytes: [1], filename: 'shot.png', mimeType: 'image/png');
      await provider.loadAccounts();

      final subject = buildSubject(uploadProvider: provider);
      await growSurface(tester);
      await tester.pumpWidget(subject.widget);
      subject.router.push('/upload');
      await tester.pumpAndSettle();

      await tester.tap(find.text('+ New account'));
      await tester.pumpAndSettle();

      expect(find.widgetWithText(TextFormField, 'US Stocks'), findsOneWidget);
      expect(find.widgetWithText(TextFormField, 'Futu HK'), findsOneWidget);
      expect(find.widgetWithText(TextFormField, 'brokerage'), findsOneWidget);
    });

    testWidgets('shows the institution and account label as context under "Holdings"',
        (tester) async {
      final uploadsApi = FakeUploadsApi(extractResult: manyHoldingsRecord(4));
      final provider = UploadFlowProvider(uploadsApi: uploadsApi, accountsApi: FakeAccountsApi());
      await provider.startUpload(bytes: [1], filename: 'shot.png', mimeType: 'image/png');

      final subject = buildSubject(uploadProvider: provider);
      await growSurface(tester);
      await tester.pumpWidget(subject.widget);
      subject.router.push('/upload');
      await tester.pumpAndSettle();

      expect(find.text('Futu HK · US Stocks'), findsOneWidget);
    });
  });
}
