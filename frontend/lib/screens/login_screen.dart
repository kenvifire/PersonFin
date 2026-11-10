import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/api_client.dart';
import '../auth/auth_service.dart';
import '../auth/google_auth_service.dart';

/// The only unauthenticated screen in the app. Shows the app name and a
/// single "Sign in with Google" button; [buildRouter] redirects every other
/// route here until [AuthService.isAuthenticated] is true.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  bool _isSigningIn = false;

  Future<void> _handleSignIn() async {
    final googleAuthService = context.read<GoogleAuthService>();
    final authService = context.read<AuthService>();

    setState(() => _isSigningIn = true);
    try {
      final idToken = await googleAuthService.signIn();
      if (idToken == null) {
        _showSnackBar('Sign-in cancelled');
        return;
      }
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

  void _showSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('PersonFin', style: Theme.of(context).textTheme.headlineMedium),
            const SizedBox(height: 32),
            ElevatedButton(
              onPressed: _isSigningIn ? null : _handleSignIn,
              child: const Text('Sign in with Google'),
            ),
          ],
        ),
      ),
    );
  }
}
