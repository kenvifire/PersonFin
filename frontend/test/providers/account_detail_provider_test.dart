import 'package:flutter_test/flutter_test.dart';

import 'package:personfin/api/accounts_api.dart';
import 'package:personfin/api/api_client.dart';
import 'package:personfin/models/account.dart';
import 'package:personfin/models/snapshot.dart';
import 'package:personfin/providers/account_detail_provider.dart';

/// Hand-written fake for `AccountsApiBase`. Each method either returns a
/// fixed result or throws the matching `*Error`, set independently so a
/// test can make exactly the call it's exercising fail.
class FakeAccountsApi implements AccountsApiBase {
  AccountSummaryLite? getAccountResult;
  Object? getAccountError;
  List<SnapshotOut> listSnapshotsResult;
  Object? listSnapshotsError;
  Object? updateAccountError;
  Object? deleteAccountError;

  ({int id, String? name, String? institution, String? accountType})? capturedUpdate;
  int? capturedDeleteId;

  FakeAccountsApi({
    this.getAccountResult,
    this.getAccountError,
    this.listSnapshotsResult = const [],
    this.listSnapshotsError,
    this.updateAccountError,
    this.deleteAccountError,
  });

  @override
  Future<List<AccountSummaryLite>> listAccounts() => throw UnimplementedError();

  @override
  Future<AccountSummaryLite> getAccount(int id) async {
    if (getAccountError != null) throw getAccountError!;
    return getAccountResult!;
  }

  @override
  Future<void> updateAccount({
    required int id,
    String? name,
    String? institution,
    String? accountType,
  }) async {
    capturedUpdate = (id: id, name: name, institution: institution, accountType: accountType);
    if (updateAccountError != null) throw updateAccountError!;
  }

  @override
  Future<void> deleteAccount(int id) async {
    capturedDeleteId = id;
    if (deleteAccountError != null) throw deleteAccountError!;
  }

  @override
  Future<List<SnapshotOut>> listSnapshots(int accountId) async {
    if (listSnapshotsError != null) throw listSnapshotsError!;
    return listSnapshotsResult;
  }
}

AccountSummaryLite _account({int id = 5}) =>
    AccountSummaryLite(id: id, name: 'Brokerage', institution: 'Big Bank', accountType: 'brokerage');

SnapshotOut _snapshot({DateTime? takenAt}) => SnapshotOut(
      id: 1,
      takenAt: takenAt ?? DateTime(2026, 11, 8),
      createdAt: DateTime(2026, 11, 8, 12),
      holdings: [
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

void main() {
  group('AccountDetailProvider', () {
    test('load() fetches the account and its snapshots and sets state to loaded', () async {
      final api = FakeAccountsApi(getAccountResult: _account(), listSnapshotsResult: [_snapshot()]);
      final provider = AccountDetailProvider(accountsApi: api);

      await provider.load(5);

      expect(provider.state, AccountDetailState.loaded);
      expect(provider.accountId, 5);
      expect(provider.account!.name, 'Brokerage');
      expect(provider.snapshots, hasLength(1));
      expect(provider.snapshots.first.holdings.first.label, 'VFV');
    });

    test('load() sets state to error with the message on a thrown ApiException', () async {
      final api = FakeAccountsApi(getAccountError: ApiException(404, 'Not found'));
      final provider = AccountDetailProvider(accountsApi: api);

      await provider.load(5);

      expect(provider.state, AccountDetailState.error);
      expect(provider.errorMessage, 'Not found');
      // The id is still recorded, so the screen's Retry button can call
      // load(provider.accountId!) even though account was never fetched.
      expect(provider.accountId, 5);
    });

    test('rename() updates account locally and returns true on success', () async {
      final api = FakeAccountsApi(getAccountResult: _account(), listSnapshotsResult: []);
      final provider = AccountDetailProvider(accountsApi: api);
      await provider.load(5);

      final ok = await provider.rename(name: 'New Name', institution: 'New Bank', accountType: 'cash');

      expect(ok, isTrue);
      expect(provider.account!.name, 'New Name');
      expect(provider.account!.institution, 'New Bank');
      expect(provider.account!.accountType, 'cash');
      expect(api.capturedUpdate, (id: 5, name: 'New Name', institution: 'New Bank', accountType: 'cash'));
    });

    test('rename() leaves account untouched, sets errorMessage, and returns false on failure', () async {
      final api = FakeAccountsApi(
        getAccountResult: _account(),
        listSnapshotsResult: [],
        updateAccountError: ApiException(422, 'Invalid institution'),
      );
      final provider = AccountDetailProvider(accountsApi: api);
      await provider.load(5);

      final ok = await provider.rename(name: 'New Name', institution: '', accountType: 'cash');

      expect(ok, isFalse);
      expect(provider.account!.name, 'Brokerage'); // unchanged
      expect(provider.errorMessage, 'Invalid institution');
    });

    test('delete() sets deleted to true on success', () async {
      final api = FakeAccountsApi(getAccountResult: _account(), listSnapshotsResult: []);
      final provider = AccountDetailProvider(accountsApi: api);
      await provider.load(5);

      await provider.delete();

      expect(provider.deleted, isTrue);
      expect(api.capturedDeleteId, 5);
    });

    test('delete() surfaces a 409 as a clear message without setting deleted', () async {
      final api = FakeAccountsApi(
        getAccountResult: _account(),
        listSnapshotsResult: [_snapshot()],
        deleteAccountError: ApiException(409, 'Account has snapshot history and cannot be deleted'),
      );
      final provider = AccountDetailProvider(accountsApi: api);
      await provider.load(5);

      await provider.delete();

      expect(provider.deleted, isFalse);
      expect(provider.errorMessage, contains("can't be deleted"));
    });
  });
}
