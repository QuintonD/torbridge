import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/app_state.dart';
import '../../data/demo_catalog.dart';
import '../common/artwork_image.dart';
import '../common/page_header.dart';

class LibraryScreen extends ConsumerWidget {
  const LibraryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(torBridgeControllerProvider);
    final watchedDownloads = state.downloads
        .where((job) => state.watchedTitleIds.contains(job.videoId))
        .toList(growable: false);
    final watchedDemo = demoTitles
        .where(
          (title) =>
              state.watchedTitleIds.contains(title.id) &&
              !watchedDownloads.any((job) => job.videoId == title.id),
        )
        .toList(growable: false);
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
          if (watchedDownloads.isEmpty && watchedDemo.isEmpty)
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
                itemCount: watchedDownloads.length + watchedDemo.length,
                separatorBuilder: (_, _) => const SizedBox(height: 10),
                itemBuilder: (context, index) {
                  if (index >= watchedDownloads.length) {
                    final title = watchedDemo[index - watchedDownloads.length];
                    return Card(
                      child: ListTile(
                        leading: ClipOval(
                          child: SizedBox(
                            width: 42,
                            height: 42,
                            child: ArtworkImage(
                              url: title.posterUrl,
                              fallbackColor: Color(title.color),
                            ),
                          ),
                        ),
                        title: Text(title.name),
                        subtitle: Text('${title.year} • ${title.genre}'),
                        trailing: const Chip(label: Text('Watched')),
                      ),
                    );
                  }
                  final job = watchedDownloads[index];
                  return Card(
                    child: ListTile(
                      leading: ClipRRect(
                        borderRadius: BorderRadius.circular(7),
                        child: SizedBox(
                          width: 58,
                          height: 48,
                          child: ArtworkImage(
                            url:
                                job.mediaVideo?.thumbnailUrl ??
                                job.mediaTitle.posterUrl,
                            fallbackColor: Color(job.mediaTitle.color),
                          ),
                        ),
                      ),
                      title: Text(job.title),
                      subtitle: Text(
                        '${job.episodeLabel} • ${job.tags.join(' • ')}',
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
