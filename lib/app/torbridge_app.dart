import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../features/home_shell.dart';

class TorBridgeApp extends StatelessWidget {
  const TorBridgeApp({super.key});

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF8B7CFF);
    final scheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: Brightness.dark,
      surface: const Color(0xFF111018),
    );
    return MaterialApp(
      title: 'TorBridge',
      debugShowCheckedModeBanner: false,
      builder: (context, child) {
        if (defaultTargetPlatform != TargetPlatform.windows) {
          return child ?? const SizedBox.shrink();
        }

        // Flutter's Windows embedder can currently disconnect when an
        // accessibility client observes a semantics tree that changes during
        // navigation. Keep one stable root node on Windows until the engine
        // regression is fixed; Android retains the full semantics tree.
        return Semantics(
          label: 'TorBridge application',
          container: true,
          explicitChildNodes: true,
          child: ExcludeSemantics(child: child ?? const SizedBox.shrink()),
        );
      },
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: scheme,
        scaffoldBackgroundColor: const Color(0xFF0C0B12),
        cardTheme: const CardThemeData(
          color: Color(0xFF17151F),
          elevation: 0,
          margin: EdgeInsets.zero,
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFF17151F),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide.none,
          ),
        ),
        navigationRailTheme: const NavigationRailThemeData(
          backgroundColor: Color(0xFF111018),
          indicatorColor: Color(0xFF302A55),
          useIndicator: true,
        ),
        navigationBarTheme: const NavigationBarThemeData(
          backgroundColor: Color(0xFF111018),
          indicatorColor: Color(0xFF302A55),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            minimumSize: const Size(0, 48),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
          ),
        ),
        chipTheme: ChipThemeData(
          side: BorderSide(color: scheme.outlineVariant),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      ),
      home: const HomeShell(),
    );
  }
}
