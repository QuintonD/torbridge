import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/app_state.dart';
import '../../data/demo_catalog.dart';
import '../../domain/watched_entry.dart';
import '../common/artwork_image.dart';
import '../common/page_header.dart';

class LibraryScreen extends ConsumerWidget {
  const LibraryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(torBridgeControllerProvider);
    final entries = state.watchedTitleIds.map((id) {
      final saved = state.watchedHistory[id];
      if (saved != null && saved.title.name != saved.title.id) return saved;
      final job = state.downloads.where((job) => job.videoId == id).firstOrNull;
      if (job != null) {
        return WatchedEntry(job.mediaTitle, video: job.mediaVideo);
      }
      final title = [
        ...state.catalogTitles,
        ...demoTitles,
      ].where((title) => title.id == id).firstOrNull;
      return title == null
          ? saved ?? WatchedEntry.placeholder(id)
          : WatchedEntry(title);
    }).toList();
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageHeader(
            title: 'Library',
            subtitle: 'Your watched movies and episodes, all in one place.',
            trailing: state.connections.hasTraktSession
                ? OutlinedButton.icon(
                    onPressed: () => unawaited(
                      ref
                          .read(torBridgeControllerProvider.notifier)
                          .syncTraktWatched(),
                    ),
                    icon: const Icon(Icons.sync),
                    label: const Text('Refresh Trakt'),
                  )
                : null,
          ),
          const SizedBox(height: 22),
          if (entries.isEmpty)
            const Expanded(
              child: SingleChildScrollView(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.video_library_outlined, size: 52),
                      SizedBox(height: 16),
                      Text(
                        'Your viewing history starts here',
                        textAlign: TextAlign.center,
                      ),
                      SizedBox(height: 8),
                      Text(
                        'Finish a movie or mark an episode watched to add it to your library.',
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              ),
            )
          else
            Expanded(
              child: ListView.separated(
                itemCount: entries.length,
                separatorBuilder: (_, _) => const SizedBox(height: 10),
                itemBuilder: (context, index) {
                  final entry = entries[index];
                  return Card(
                    child: ListTile(
                      leading: ClipRRect(
                        borderRadius: BorderRadius.circular(7),
                        child: SizedBox(
                          width: 58,
                          height: 48,
                          child: ArtworkImage(
                            url:
                                entry.video?.thumbnailUrl ??
                                entry.title.posterUrl,
                            fallbackColor: Color(entry.title.color),
                          ),
                        ),
                      ),
                      title: Text(entry.label),
                      subtitle: Text(
                        [
                          if (entry.title.year > 0) '${entry.title.year}',
                          if (entry.video != null) entry.video!.code,
                          'Watched',
                        ].join(' \u00b7 '),
                      ),
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
