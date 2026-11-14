import 'package:flutter/foundation.dart';

import '../api/accounts_api.dart';
import '../api/api_client.dart';
import '../models/account.dart';
import '../models/snapshot.dart';

enum AccountDetailState { loading, loaded, error }

/// Loads one account's own details plus its full snapshot history, and
/// lets the account detail screen rename or delete it.
///
/// Scoped to a single visit to `/accounts/:id` (see `buildRouter`) — a
/// fresh instance per visit, same pattern as `UploadFlowProvider`.
class AccountDetailProvider extends ChangeNotifier {
  final AccountsApiBase _accountsApi;

  AccountDetailProvider({required AccountsApiBase accountsApi}) : _accountsApi = accountsApi;

  AccountDetailState state = AccountDetailState.loading;

  /// Set as soon as [load] is called, independent of whether it succeeds —
  /// lets the screen retry a failed load without needing a fetched
  /// [account] to read the id back from.
  int? accountId;

  AccountSummaryLite? account;
  List<SnapshotOut> snapshots = [];
  String? errorMessage;

  /// True once [delete] has actually removed the account — the screen
  /// pops on this. A 409 (snapshot history still exists) instead leaves
  /// this false and sets [errorMessage], so the screen stays put.
  bool deleted = false;

  Future<void> load(int id) async {
    accountId = id;
    state = AccountDetailState.loading;
    errorMessage = null;
    notifyListeners();
    try {
      final results = await Future.wait([
        _accountsApi.getAccount(id),
        _accountsApi.listSnapshots(id),
      ]);
      account = results[0] as AccountSummaryLite;
      snapshots = results[1] as List<SnapshotOut>;
      state = AccountDetailState.loaded;
    } on ApiException catch (e) {
      errorMessage = e.message;
      state = AccountDetailState.error;
    }
    notifyListeners();
  }

  /// Renames/re-categorizes the account. On success, updates [account]
  /// locally (the backend returns the same fields `updateAccount` sent)
  /// and returns `true`. On failure, leaves [account] untouched, sets
  /// [errorMessage], and returns `false` so the screen can show it.
  Future<bool> rename({
    required String name,
    required String institution,
    required String accountType,
  }) async {
    try {
      await _accountsApi.updateAccount(
        id: account!.id,
        name: name,
        institution: institution,
        accountType: accountType,
      );
      account = AccountSummaryLite(
        id: account!.id,
        name: name,
        institution: institution,
        accountType: accountType,
      );
      errorMessage = null;
      notifyListeners();
      return true;
    } on ApiException catch (e) {
      errorMessage = e.message;
      notifyListeners();
      return false;
    }
  }

  /// Deletes the account. Succeeds only when it has no snapshot history
  /// (the backend returns 409 otherwise) — on success sets [deleted] for
  /// the screen to pop on; on a 409, sets a clear [errorMessage] instead
  /// of the raw backend detail text.
  Future<void> delete() async {
    try {
      await _accountsApi.deleteAccount(account!.id);
      deleted = true;
      notifyListeners();
    } on ApiException catch (e) {
      errorMessage = e.statusCode == 409
          ? "This account has snapshot history and can't be deleted."
          : e.message;
      notifyListeners();
    }
  }
}
