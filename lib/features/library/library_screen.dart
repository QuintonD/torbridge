import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/app_state.dart';
import '../../data/demo_catalog.dart';
import '../common/page_header.dart';

class LibraryScreen extends ConsumerWidget {
  const LibraryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final watched = ref.watch(
      torBridgeControllerProvider.select((state) => state.watchedTitleIds),
    );
    final items = demoTitles
        .where((title) => watched.contains(title.id))
        .toList();
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const PageHeader(
            title: 'Library',
            subtitle: 'Your watched state, ready to sync with Trakt.',
          ),
          const SizedBox(height: 22),
          if (items.isEmpty)
            const Expanded(
              child: Center(
                child: Text('Titles you finish or mark watched appear here.'),
              ),
            )
          else
            Expanded(
              child: ListView.separated(
                itemCount: items.length,
                separatorBuilder: (_, _) => const SizedBox(height: 10),
                itemBuilder: (context, index) {
                  final title = items[index];
                  return Card(
                    child: ListTile(
                      leading: const CircleAvatar(child: Icon(Icons.check)),
                      title: Text(title.name),
                      subtitle: Text('${title.year} • ${title.genre}'),
                      trailing: const Chip(label: Text('Watched')),
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}
