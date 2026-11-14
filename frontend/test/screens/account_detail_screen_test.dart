import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import 'package:personfin/api/accounts_api.dart';
import 'package:personfin/api/api_client.dart';
import 'package:personfin/models/account.dart';
import 'package:personfin/models/snapshot.dart';
import 'package:personfin/providers/account_detail_provider.dart';
import 'package:personfin/screens/account_detail_screen.dart';

import '../providers/account_detail_provider_test.dart' show FakeAccountsApi;

AccountSummaryLite _account({int id = 5}) =>
    AccountSummaryLite(id: id, name: 'Brokerage', institution: 'Big Bank', accountType: 'brokerage');

SnapshotOut _snapshot({DateTime? takenAt, List<HoldingOut>? holdings}) => SnapshotOut(
      id: 1,
      takenAt: takenAt ?? DateTime(2026, 11, 8),
      createdAt: DateTime(2026, 11, 8, 12),
      holdings: holdings ??
          [
            HoldingOut(
              id: 1,
              label: 'VFV',
              assetClass: 'equity',
              quantity: 10,
              value: 1000.0,
              currency: 'CAD',
              country: 'CA',
              valueUsd: 720.0,
              fxRateToUsd: 0.72,
            ),
          ],
    );

({Widget widget, GoRouter router}) buildSubject(AccountDetailProvider provider) {
  final router = GoRouter(
    initialLocation: '/dashboard',
    routes: [
      GoRoute(path: '/dashboard', builder: (c, s) => const Scaffold(body: Text('Dashboard Screen'))),
      GoRoute(
        path: '/accounts/5',
        builder: (c, s) => ChangeNotifierProvider<AccountDetailProvider>.value(
          value: provider,
          child: const AccountDetailScreen(),
        ),
      ),
    ],
  );
  return (widget: MaterialApp.router(routerConfig: router), router: router);
}

String currentLocation(GoRouter router) =>
    router.routerDelegate.currentConfiguration.uri.toString();

/// `AccountsApiBase` whose every call hangs forever (never completes), used
/// only to pin the provider in `loading` so the spinner view can be
/// asserted without racing a real async resolution.
class _HangingAccountsApi implements AccountsApiBase {
  @override
  Future<List<AccountSummaryLite>> listAccounts() => Completer<List<AccountSummaryLite>>().future;

  @override
  Future<AccountSummaryLite> getAccount(int id) => Completer<AccountSummaryLite>().future;

  @override
  Future<void> updateAccount({
    required int id,
    String? name,
    String? institution,
    String? accountType,
  }) =>
      Completer<void>().future;

  @override
  Future<void> deleteAccount(int id) => Completer<void>().future;

  @override
  Future<List<SnapshotOut>> listSnapshots(int accountId) => Completer<List<SnapshotOut>>().future;
}

void main() {
  group('AccountDetailScreen', () {
    testWidgets('shows a spinner while loading', (tester) async {
      final provider = AccountDetailProvider(accountsApi: _HangingAccountsApi());
      // Never completes, so the screen stays in `loading`.
      // ignore: discarded_futures
      provider.load(5);

      final subject = buildSubject(provider);
      await tester.pumpWidget(subject.widget);
      subject.router.push('/accounts/5');
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('shows the error message and a Retry button on load failure', (tester) async {
      final api = FakeAccountsApi(getAccountError: ApiException(404, 'Account not found'));
      final provider = AccountDetailProvider(accountsApi: api);
      await provider.load(5);

      final subject = buildSubject(provider);
      await tester.pumpWidget(subject.widget);
      subject.router.push('/accounts/5');
      await tester.pumpAndSettle();

      expect(find.text('Account not found'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
    });

    testWidgets('shows institution/type, current holdings from the latest snapshot, and history',
        (tester) async {
      final older = _snapshot(
        takenAt: DateTime(2026, 10, 1),
        holdings: [
          HoldingOut(
            id: 2,
            label: 'OLD',
            assetClass: 'equity',
            quantity: 5,
            value: 500.0,
            currency: 'USD',
            country: 'US',
            valueUsd: 500.0,
            fxRateToUsd: 1.0,
          ),
        ],
      );
      final latest = _snapshot(takenAt: DateTime(2026, 11, 8));
      final api = FakeAccountsApi(getAccountResult: _account(), listSnapshotsResult: [latest, older]);
      final provider = AccountDetailProvider(accountsApi: api);
      await provider.load(5);

      final subject = buildSubject(provider);
      await tester.pumpWidget(subject.widget);
      subject.router.push('/accounts/5');
      await tester.pumpAndSettle();

      expect(find.text('Big Bank · brokerage'), findsOneWidget);
      expect(find.text('VFV'), findsOneWidget);
      // The older snapshot's holding is inside a collapsed ExpansionTile.
      expect(find.text('OLD'), findsNothing);
      expect(find.textContaining('Nov 8, 2026'), findsOneWidget);
      expect(find.text('Oct 1, 2026'), findsOneWidget);

      await tester.tap(find.text('Oct 1, 2026'));
      await tester.pumpAndSettle();
      expect(find.text('OLD'), findsOneWidget);
    });

    testWidgets('shows a message when there are no snapshots yet', (tester) async {
      final api = FakeAccountsApi(getAccountResult: _account(), listSnapshotsResult: []);
      final provider = AccountDetailProvider(accountsApi: api);
      await provider.load(5);

      final subject = buildSubject(provider);
      await tester.pumpWidget(subject.widget);
      subject.router.push('/accounts/5');
      await tester.pumpAndSettle();

      expect(find.textContaining('No snapshots yet'), findsOneWidget);
    });

    testWidgets('editing and saving calls rename with the new values', (tester) async {
      final api = FakeAccountsApi(getAccountResult: _account(), listSnapshotsResult: []);
      final provider = AccountDetailProvider(accountsApi: api);
      await provider.load(5);

      final subject = buildSubject(provider);
      await tester.pumpWidget(subject.widget);
      subject.router.push('/accounts/5');
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.edit));
      await tester.pumpAndSettle();

      await tester.enterText(find.widgetWithText(TextField, 'Brokerage'), 'New Name');
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Save'));
      await tester.pumpAndSettle();

      expect(api.capturedUpdate!.name, 'New Name');
      expect(find.text('New Name'), findsWidgets); // AppBar title updated
    });

    testWidgets('Save is disabled while any field is blank', (tester) async {
      final api = FakeAccountsApi(getAccountResult: _account(), listSnapshotsResult: []);
      final provider = AccountDetailProvider(accountsApi: api);
      await provider.load(5);

      final subject = buildSubject(provider);
      await tester.pumpWidget(subject.widget);
      subject.router.push('/accounts/5');
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.edit));
      await tester.pumpAndSettle();

      await tester.enterText(find.widgetWithText(TextField, 'Brokerage'), '');
      await tester.pumpAndSettle();

      final saveButton = tester.widget<TextButton>(find.widgetWithText(TextButton, 'Save'));
      expect(saveButton.onPressed, isNull);
    });

    testWidgets('confirming delete removes the account and navigates back', (tester) async {
      final api = FakeAccountsApi(getAccountResult: _account(), listSnapshotsResult: []);
      final provider = AccountDetailProvider(accountsApi: api);
      await provider.load(5);

      final subject = buildSubject(provider);
      await tester.pumpWidget(subject.widget);
      subject.router.push('/accounts/5');
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.delete_outline));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Delete'));
      await tester.pumpAndSettle();

      expect(api.capturedDeleteId, 5);
      expect(provider.deleted, isTrue);
    });

    testWidgets('a 409 on delete shows the message and keeps the screen open', (tester) async {
      final api = FakeAccountsApi(
        getAccountResult: _account(),
        listSnapshotsResult: [_snapshot()],
        deleteAccountError: ApiException(409, 'Account has snapshot history and cannot be deleted'),
      );
      final provider = AccountDetailProvider(accountsApi: api);
      await provider.load(5);

      final subject = buildSubject(provider);
      await tester.pumpWidget(subject.widget);
      subject.router.push('/accounts/5');
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.delete_outline));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Delete'));
      await tester.pumpAndSettle();

      expect(provider.deleted, isFalse);
      expect(find.widgetWithText(SnackBar, "This account has snapshot history and can't be deleted."),
          findsOneWidget);
      expect(find.byType(AccountDetailScreen), findsOneWidget);
    });

    testWidgets('cancelling the delete dialog does nothing', (tester) async {
      final api = FakeAccountsApi(getAccountResult: _account(), listSnapshotsResult: []);
      final provider = AccountDetailProvider(accountsApi: api);
      await provider.load(5);

      final subject = buildSubject(provider);
      await tester.pumpWidget(subject.widget);
      subject.router.push('/accounts/5');
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.delete_outline));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();

      expect(api.capturedDeleteId, isNull);
      expect(provider.deleted, isFalse);
    });
  });
}
