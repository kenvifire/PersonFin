import '../models/user.dart';
import 'api_client.dart';

abstract class AuthApiBase {
  Future<(String accessToken, AppUser user)> loginWithGoogle(String idToken);
}

/// Wraps the backend's `POST /auth/google` endpoint, which exchanges a
/// Google ID token for an app session (access token + user record).
class AuthApi implements AuthApiBase {
  final ApiClient _client;

  AuthApi(this._client);

  @override
  Future<(String accessToken, AppUser user)> loginWithGoogle(
      String idToken) async {
    final body = await _client.post('/auth/google', body: {
      'id_token': idToken,
    });
    final accessToken = body['access_token'] as String;
    final user = AppUser.fromJson(body['user'] as Map<String, dynamic>);
    return (accessToken, user);
  }
}
