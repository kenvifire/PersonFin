import 'package:google_sign_in/google_sign_in.dart';

/// Abstracts Google sign-in so [LoginScreen] (and its tests) don't depend
/// directly on `package:google_sign_in` or trigger any real network/SDK
/// calls.
abstract class GoogleAuthService {
  /// Starts an interactive Google sign-in flow.
  ///
  /// Returns the Google ID token on success, or `null` if the user
  /// cancelled the flow.
  Future<String?> signIn();
}

/// Wraps `package:google_sign_in`'s `GoogleSignIn.instance` to implement
/// [GoogleAuthService].
///
/// The OAuth web client ID is read from the `GOOGLE_CLIENT_ID` build-time
/// environment variable (pass `--dart-define=GOOGLE_CLIENT_ID=...` when
/// running/building), never hardcoded.
class RealGoogleAuthService implements GoogleAuthService {
  static const String _webClientId = String.fromEnvironment('GOOGLE_CLIENT_ID');

  Future<void>? _initialization;

  Future<void> _ensureInitialized() {
    // GoogleSignIn.instance.initialize must be called exactly once before
    // any other method; cache the future so concurrent/duplicate calls to
    // signIn() don't call initialize() more than once.
    return _initialization ??= GoogleSignIn.instance.initialize(
      clientId: _webClientId.isEmpty ? null : _webClientId,
    );
  }

  @override
  Future<String?> signIn() async {
    await _ensureInitialized();
    try {
      final account = await GoogleSignIn.instance.authenticate();
      return account.authentication.idToken;
    } on GoogleSignInException catch (e) {
      if (e.code == GoogleSignInExceptionCode.canceled) {
        return null;
      }
      rethrow;
    }
  }
}
