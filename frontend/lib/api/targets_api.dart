import '../models/drift_flag.dart';
import 'api_client.dart';

/// Placeholder for the allocation-target model, fleshed out (fields,
/// `fromJson`, and a proper home under `lib/models/`) in Task 10. It exists
/// here only so `TargetsApiBase`'s full interface — including the two
/// methods Task 10 implements — compiles today.
class AllocationTarget {}

abstract class TargetsApiBase {
  Future<List<DriftFlag>> getDrift(String currency);
  Future<List<AllocationTarget>> listTargets();
  Future<AllocationTarget> updateTarget(String assetClass, double targetPct);
}

/// Wraps the backend's `/targets` endpoints. This task implements only
/// [getDrift]; [listTargets] and [updateTarget] are implemented in Task 10.
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
  Future<List<AllocationTarget>> listTargets() {
    throw UnimplementedError();
  }

  @override
  Future<AllocationTarget> updateTarget(String assetClass, double targetPct) {
    throw UnimplementedError();
  }
}
