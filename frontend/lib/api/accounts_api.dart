import '../models/account.dart';
import '../models/snapshot.dart';
import 'api_client.dart';

abstract class AccountsApiBase {
  Future<List<AccountSummaryLite>> listAccounts();

  /// Fetches one account's own details (not its holdings).
  Future<AccountSummaryLite> getAccount(int id);

  /// Partial update: only the fields passed are changed, mirroring the
  /// backend's `PATCH /accounts/{id}` semantics.
  Future<void> updateAccount({
    required int id,
    String? name,
    String? institution,
    String? accountType,
  });

  /// Throws `ApiException(409, ...)` if the account still has snapshot
  /// history — the backend keeps that history immutable rather than
  /// cascading the delete into it.
  Future<void> deleteAccount(int id);

  /// Every snapshot ever confirmed for this account, most recent first.
  Future<List<SnapshotOut>> listSnapshots(int accountId);
}

/// Wraps the backend's `/accounts` and `/accounts/{id}/snapshots` endpoints.
class AccountsApi implements AccountsApiBase {
  final ApiClient _client;

  AccountsApi(this._client);

  @override
  Future<List<AccountSummaryLite>> listAccounts() async {
    final body = await _client.get('/accounts');
    return (body as List)
        .map((entry) => AccountSummaryLite.fromJson(entry as Map<String, dynamic>))
        .toList();
  }

  @override
  Future<AccountSummaryLite> getAccount(int id) async {
    final body = await _client.get('/accounts/$id');
    return AccountSummaryLite.fromJson(body as Map<String, dynamic>);
  }

  @override
  Future<void> updateAccount({
    required int id,
    String? name,
    String? institution,
    String? accountType,
  }) async {
    await _client.patch('/accounts/$id', body: {
      'name': ?name,
      'institution': ?institution,
      'account_type': ?accountType,
    });
  }

  @override
  Future<void> deleteAccount(int id) async {
    await _client.delete('/accounts/$id');
  }

  @override
  Future<List<SnapshotOut>> listSnapshots(int accountId) async {
    final body = await _client.get('/accounts/$accountId/snapshots');
    return (body as List)
        .map((entry) => SnapshotOut.fromJson(entry as Map<String, dynamic>))
        .toList();
  }
}
