import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/api_client.dart';
import '../auth/auth_service.dart';
import '../auth/google_auth_service.dart';

/// The only unauthenticated screen in the app. Shows the app name and a
/// single "Sign in with Google" button; [buildRouter] redirects every other
/// route here until [AuthService.isAuthenticated] is true.
///
/// The button itself comes from [GoogleAuthService.buildSignInButton] (on
/// web, Google's own GIS-rendered button). Sign-in completes asynchronously:
/// this screen listens to [GoogleAuthService.idTokens] and exchanges each
/// ID token for a session via [AuthService.loginWithGoogle].
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  bool _isSigningIn = false;
  StreamSubscription<String?>? _idTokenSubscription;

  @override
  void initState() {
    super.initState();
    _idTokenSubscription = context
        .read<GoogleAuthService>()
        .idTokens
        .listen(_handleIdToken, onError: _handleSignInError);
  }

  @override
  void dispose() {
    _idTokenSubscription?.cancel();
    super.dispose();
  }

  Future<void> _handleIdToken(String? idToken) async {
    if (!mounted) return;
    if (idToken == null) {
      _showSnackBar('Sign-in cancelled');
      return;
    }
    if (_isSigningIn) return;

    final authService = context.read<AuthService>();
    setState(() => _isSigningIn = true);
    try {
      await authService.loginWithGoogle(idToken);
    } on ApiException catch (e) {
      _showSnackBar(e.message);
    } catch (_) {
      _showSnackBar('Sign-in failed. Please try again.');
    } finally {
      if (mounted) {
        setState(() => _isSigningIn = false);
      }
    }
  }

  void _handleSignInError(Object error) {
    debugPrint('Google sign-in failed: $error');
    _showSnackBar('Sign-in failed. Please try again.');
  }

  void _showSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final googleAuthService = context.read<GoogleAuthService>();
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('PersonFin', style: Theme.of(context).textTheme.headlineMedium),
            const SizedBox(height: 32),
            // Kept mounted (just not interactive) while the backend login is
            // in flight, so Google's rendered button isn't torn down and
            // re-rendered on every attempt.
            IgnorePointer(
              ignoring: _isSigningIn,
              child: googleAuthService.buildSignInButton(),
            ),
            if (_isSigningIn) ...[
              const SizedBox(height: 16),
              const CircularProgressIndicator(),
            ],
          ],
        ),
      ),
    );
  }
}
