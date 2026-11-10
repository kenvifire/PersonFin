import '../models/dashboard.dart';
import 'api_client.dart';

abstract class DashboardApiBase {
  Future<DashboardData> getDashboard(String currency);
}

/// Wraps the backend's `GET /dashboard` endpoint.
class DashboardApi implements DashboardApiBase {
  final ApiClient _client;

  DashboardApi(this._client);

  @override
  Future<DashboardData> getDashboard(String currency) async {
    final body = await _client.get('/dashboard', query: {'currency': currency});
    return DashboardData.fromJson(body as Map<String, dynamic>);
  }
}
