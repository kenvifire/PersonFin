import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/auth_api.dart';
import '../models/user.dart';

const _sessionTokenKey = 'session_token';

/// Holds the current session (access token + user) and persists the token
/// across restarts via [SharedPreferences].
///
/// The backend has no "get current user" endpoint, so a restored session
/// (one found in [SharedPreferences] on construction) has a [token] but no
/// [user] — [user] stays `null` until the next [loginWithGoogle] call.
/// Screens that display the user's email must tolerate it being `null`.
class AuthService extends ChangeNotifier {
  final AuthApiBase _authApi;
  final SharedPreferences _prefs;

  String? _token;
  AppUser? _user;

  AuthService({required AuthApiBase authApi, required SharedPreferences prefs})
      : _authApi = authApi,
        _prefs = prefs {
    _token = _prefs.getString(_sessionTokenKey);
  }

  String? get token => _token;
  AppUser? get user => _user;
  bool get isAuthenticated => _token != null;

  Future<void> loginWithGoogle(String idToken) async {
    final (accessToken, user) = await _authApi.loginWithGoogle(idToken);
    _token = accessToken;
    _user = user;
    await _prefs.setString(_sessionTokenKey, accessToken);
    notifyListeners();
  }

  void logout() {
    _token = null;
    _user = null;
    _prefs.remove(_sessionTokenKey);
    notifyListeners();
  }
}
