import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../auth/auth_service.dart';

/// App-bar action that ends the session via [AuthService.logout].
///
/// The router (refreshListenable: authService) then redirects to `/login`,
/// and `MyApp` resets the session-scoped providers so the next user to sign
/// in on this device never sees this user's data. Shown on both tabs of the
/// authenticated shell ([HomeShell]); each tab owns its own `AppBar`, so the
/// action lives there rather than in a second, shell-level app bar.
class SignOutButton extends StatelessWidget {
  const SignOutButton({super.key});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: const Icon(Icons.logout),
      tooltip: 'Sign out',
      onPressed: () => context.read<AuthService>().logout(),
    );
  }
}
