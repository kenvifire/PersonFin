import '../models/allocation_target.dart';
import '../models/drift_flag.dart';
import 'api_client.dart';

abstract class TargetsApiBase {
  Future<List<DriftFlag>> getDrift(String currency);
  Future<List<AllocationTarget>> listTargets();
  Future<AllocationTarget> updateTarget(String assetClass, double targetPct);
}

/// Wraps the backend's `/targets` endpoints.
class TargetsApi implements TargetsApiBase {
  final ApiClient _client;

  TargetsApi(this._client);

  @override
  Future<List<DriftFlag>> getDrift(String currency) async {
    final body = await _client.get('/targets/drift', query: {'currency': currency});
    return (body as List)
        .map((entry) => DriftFlag.fromJson(entry as Map<String, dynamic>))
        .toList();
  }

  @override
  Future<List<AllocationTarget>> listTargets() async {
    final body = await _client.get('/targets');
    return (body as List)
        .map((entry) => AllocationTarget.fromJson(entry as Map<String, dynamic>))
        .toList();
  }

  @override
  Future<AllocationTarget> updateTarget(String assetClass, double targetPct) async {
    final body = await _client.put('/targets/$assetClass', body: {'target_pct': targetPct});
    return AllocationTarget.fromJson(body as Map<String, dynamic>);
  }
}
