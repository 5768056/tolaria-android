import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:git2dart/git2dart.dart' as g;

import 'app.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // git2dart (libgit2 FFI) must initialize platform support on Android/iOS
  // before any repository / remote / credential call. On desktop this throws
  // a MissingPluginException which we safely ignore.
  try {
    await g.PlatformSpecific.initialize();
  } catch (_) {
    // Desktop uses the CLI git backend and does not need this.
  }

  runApp(const ProviderScope(child: TolariaApp()));
}
