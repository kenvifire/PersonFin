import '../models/insights.dart';
import 'api_client.dart';

abstract class InsightsApiBase {
  Future<InsightsData> getInsights(String currency);
}

/// Wraps the backend's `GET /insights` endpoint.
class InsightsApi implements InsightsApiBase {
  final ApiClient _client;

  InsightsApi(this._client);

  @override
  Future<InsightsData> getInsights(String currency) async {
    final body = await _client.get('/insights', query: {'currency': currency});
    return InsightsData.fromJson(body as Map<String, dynamic>);
  }
}
