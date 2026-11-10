import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../widgets/sign_out_button.dart';

/// The authenticated-app shell: a bottom tab bar (Dashboard, Insights)
/// wrapping whichever branch screen [child] is. Used as the builder for the
/// `ShellRoute` in [buildRouter].
///
/// Each tab screen owns its `AppBar`; both include a [SignOutButton].
class HomeShell extends StatelessWidget {
  final Widget child;

  const HomeShell({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final location = GoRouterState.of(context).matchedLocation;
    final currentIndex = location == '/insights' ? 1 : 0;

    return Scaffold(
      body: child,
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: currentIndex,
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.dashboard),
            label: 'Dashboard',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.insights),
            label: 'Insights',
          ),
        ],
        onTap: (index) {
          if (index == 0) {
            context.go('/dashboard');
          } else {
            context.go('/insights');
          }
        },
      ),
    );
  }
}
