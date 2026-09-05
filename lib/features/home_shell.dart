import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/app_state.dart';
import 'discover/discover_screen.dart';
import 'downloads/downloads_screen.dart';
import 'diagnostics/diagnostics_screen.dart';
import 'library/library_screen.dart';
import 'settings/settings_screen.dart';

class HomeShell extends ConsumerWidget {
  const HomeShell({super.key});

  static const _destinations = <NavigationDestination>[
    NavigationDestination(
      icon: Icon(Icons.explore_outlined),
      label: 'Discover',
    ),
    NavigationDestination(
      icon: Icon(Icons.download_outlined),
      label: 'Downloads',
    ),
    NavigationDestination(
      icon: Icon(Icons.video_library_outlined),
      label: 'Library',
    ),
    NavigationDestination(icon: Icon(Icons.tune_outlined), label: 'Settings'),
    NavigationDestination(
      icon: Icon(Icons.health_and_safety_outlined),
      label: 'Diagnostics',
    ),
  ];

  static const _screens = <Widget>[
    DiscoverScreen(),
    DownloadsScreen(),
    LibraryScreen(),
    SettingsScreen(),
    DiagnosticsScreen(),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final index = ref.watch(
      torBridgeControllerProvider.select((state) => state.navigationIndex),
    );
    final controller = ref.read(torBridgeControllerProvider.notifier);
    final wide = MediaQuery.sizeOf(context).width >= 760;

    if (!wide) {
      return Scaffold(
        body: SafeArea(
          child: IndexedStack(index: index, children: _screens),
        ),
        bottomNavigationBar: NavigationBar(
          // Keep large accessibility text from breaking five labels into
          // unreadable fragments. Destination semantics and tooltips remain.
          labelBehavior:
              MediaQuery.sizeOf(context).width < 400 &&
                  MediaQuery.textScalerOf(context).scale(12) > 15
              ? NavigationDestinationLabelBehavior.alwaysHide
              : NavigationDestinationLabelBehavior.alwaysShow,
          selectedIndex: index,
          onDestinationSelected: controller.navigate,
          destinations: _destinations,
        ),
      );
    }

    return Scaffold(
      body: Row(
        children: [
          NavigationRail(
            selectedIndex: index,
            onDestinationSelected: controller.navigate,
            labelType: NavigationRailLabelType.all,
            leading: const Padding(
              padding: EdgeInsets.only(top: 12, bottom: 24),
              child: _BrandMark(),
            ),
            destinations: [
              for (final destination in _destinations)
                NavigationRailDestination(
                  icon: destination.icon,
                  label: Text(destination.label),
                ),
            ],
          ),
          const VerticalDivider(width: 1),
          Expanded(
            child: IndexedStack(index: index, children: _screens),
          ),
        ],
      ),
    );
  }
}

class _BrandMark extends StatelessWidget {
  const _BrandMark();

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'TorBridge',
      image: true,
      child: Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xFF9B8CFF), Color(0xFF6856DA)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(13),
        ),
        child: const Icon(Icons.bolt_rounded, color: Colors.white),
      ),
    );
  }
}
