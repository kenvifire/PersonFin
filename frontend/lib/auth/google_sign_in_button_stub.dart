import 'package:flutter/widgets.dart';

/// Non-web fallback for [renderGoogleSignInButton].
///
/// This app targets Flutter web only, but `package:google_sign_in_web`
/// imports `dart:js_interop`/`dart:ui_web`, which don't exist on the Dart
/// VM — so importing it unconditionally would stop the VM-based
/// `flutter test` suite from compiling at all. This stub is what the VM
/// sees instead; tests use a fake `GoogleAuthService` and never reach it.
Widget renderGoogleSignInButton() =>
    const Text('Google Sign-In is only available in the web build.');
