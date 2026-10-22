import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'providers/vault_provider.dart';
import 'route_observer.dart';
import 'screens/setup_screen.dart';
import 'screens/note_list_screen.dart';
import 'screens/settings_screen.dart';

class TolariaApp extends ConsumerWidget {
  const TolariaApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(vaultProvider);

    return MaterialApp(
      title: 'Tolaria',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF5B8DEF)),
        scaffoldBackgroundColor: const Color(0xFFFBFBFD),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF5B8DEF),
          brightness: Brightness.dark,
        ),
      ),
      themeMode: ThemeMode.system,
      home: state.vaultPath == null
          ? const SetupScreen()
          : const NoteListScreen(),
      routes: {
        '/settings': (context) => const SettingsScreen(),
      },
      navigatorObservers: [routeObserver],
    );
  }
}
