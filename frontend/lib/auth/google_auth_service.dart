import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';

// `package:google_sign_in_web` can only be compiled for the web (it imports
// `dart:js_interop`/`dart:ui_web`), so the VM-based test suite gets a stub.
import 'google_sign_in_button_stub.dart'
    if (dart.library.js_interop) 'google_sign_in_button_web.dart';

/// Abstracts Google sign-in so [LoginScreen] (and its tests) don't depend
/// directly on `package:google_sign_in` or trigger any real network/SDK
/// calls.
///
/// The contract is push-based because that's the only shape Google
/// Sign-In supports on the web: there is no awaitable "sign in" call
/// (`GoogleSignIn.authenticate()` throws `UnimplementedError` on web).
/// Instead, Google renders its own button ([buildSignInButton]), and a
/// completed sign-in arrives later on [idTokens].
abstract class GoogleAuthService {
  /// The widget the user taps to start an interactive Google sign-in.
  Widget buildSignInButton();

  /// Results of sign-in attempts started from [buildSignInButton]:
  ///
  /// - a non-null `String` is the Google ID token of a successful sign-in;
  /// - `null` means the user cancelled/dismissed the flow;
  /// - a stream *error* means the attempt failed for any other reason.
  Stream<String?> get idTokens;
}

/// Wraps `package:google_sign_in` (and, on web, `google_sign_in_web`'s
/// GIS-rendered button) to implement [GoogleAuthService].
///
/// The OAuth web client ID is read from the `GOOGLE_CLIENT_ID` build-time
/// environment variable (pass `--dart-define=GOOGLE_CLIENT_ID=...` when
/// running/building), never hardcoded.
class RealGoogleAuthService implements GoogleAuthService {
  static const String _webClientId = String.fromEnvironment('GOOGLE_CLIENT_ID');

  Future<void>? _initialization;

  Future<void> _ensureInitialized() {
    // GoogleSignIn.instance.initialize must be called exactly once before
    // any other method (the web plugin throws a StateError on a second
    // call); cache the future so every rebuild of the sign-in button, and
    // every LoginScreen visit after a sign-out, reuses the same one.
    return _initialization ??= GoogleSignIn.instance.initialize(
      clientId: _webClientId.isEmpty ? null : _webClientId,
    );
  }

  @override
  Widget buildSignInButton() {
    return FutureBuilder<void>(
      future: _ensureInitialized(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          debugPrint('Google Sign-In failed to initialize: ${snapshot.error}');
          return const Text('Google Sign-In is unavailable right now.');
        }
        if (snapshot.connectionState != ConnectionState.done) {
          return const SizedBox(
            height: 44,
            child: Center(child: CircularProgressIndicator()),
          );
        }
        return renderGoogleSignInButton();
      },
    );
  }

  /// `GoogleSignIn.instance.authenticationEvents` only starts forwarding
  /// platform events once `initialize()` has run, which [buildSignInButton]
  /// guarantees before any button exists to be tapped.
  @override
  Stream<String?> get idTokens =>
      GoogleSignIn.instance.authenticationEvents.transform(
        StreamTransformer<GoogleSignInAuthenticationEvent, String?>.fromHandlers(
          handleData: (event, sink) {
            // Sign-out events aren't sign-in results; ignore them.
            if (event is GoogleSignInAuthenticationEventSignIn) {
              final idToken = event.user.authentication.idToken;
              if (idToken == null) {
                sink.addError(StateError('Google did not return an ID token'));
              } else {
                sink.add(idToken);
              }
            }
          },
          handleError: (error, stackTrace, sink) {
            if (error is GoogleSignInException &&
                error.code == GoogleSignInExceptionCode.canceled) {
              sink.add(null);
            } else {
              sink.addError(error, stackTrace);
            }
          },
        ),
      );
}
