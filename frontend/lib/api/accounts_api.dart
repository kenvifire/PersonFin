import '../models/account.dart';
import 'api_client.dart';

abstract class AccountsApiBase {
  Future<List<AccountSummaryLite>> listAccounts();
}

/// Wraps the backend's `GET /accounts` endpoint.
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
}
