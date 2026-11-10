import 'package:flutter/widgets.dart';
import 'package:google_sign_in_platform_interface/google_sign_in_platform_interface.dart';
import 'package:google_sign_in_web/google_sign_in_web.dart';

/// Web implementation: renders Google's own (GIS) sign-in button.
///
/// On web, `GoogleSignIn.instance.authenticate()` is unsupported (it throws
/// `UnimplementedError`); the only interactive sign-in entry point is the
/// GIS-rendered button, which `google_sign_in_web` exposes only on its
/// platform implementation class, not on the generic `GoogleSignIn` facade.
/// A successful sign-in through this button is delivered asynchronously via
/// `GoogleSignIn.instance.authenticationEvents`.
///
/// `GoogleSignIn.instance.initialize()` must have been called (or at least
/// started) before this is built — the rendered button waits on it
/// internally and shows a placeholder until it completes.
Widget renderGoogleSignInButton() {
  final plugin = GoogleSignInPlatform.instance as GoogleSignInPlugin;
  return plugin.renderButton(
    configuration: GSIButtonConfiguration(
      text: GSIButtonText.signinWith,
      size: GSIButtonSize.large,
      shape: GSIButtonShape.pill,
    ),
  );
}
