import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/app_state.dart';
import '../common/page_header.dart';
import '../player/player_screen.dart';

class DownloadsScreen extends ConsumerWidget {
  const DownloadsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final jobs = ref.watch(
      torBridgeControllerProvider.select((state) => state.downloads),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const PageHeader(
            title: 'Downloads',
            subtitle: 'Offline files stay on this device.',
          ),
          const SizedBox(height: 22),
          if (jobs.isEmpty)
            const Expanded(child: _EmptyDownloads())
          else
            Expanded(
              child: ListView.separated(
                padding: const EdgeInsets.only(bottom: 24),
                itemCount: jobs.length,
                separatorBuilder: (_, _) => const SizedBox(height: 12),
                itemBuilder: (context, index) =>
                    _DownloadTile(job: jobs[index]),
              ),
            ),
        ],
      ),
    );
  }
}

class _EmptyDownloads extends ConsumerWidget {
  const _EmptyDownloads();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 430),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.download_for_offline_outlined,
              size: 64,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(height: 16),
            Text(
              'Nothing offline yet',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 6),
            const Text(
              'Pick a title and use “Download best match”. TorBridge will choose the source and save it here.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 18),
            FilledButton.icon(
              onPressed: () =>
                  ref.read(torBridgeControllerProvider.notifier).navigate(0),
              icon: const Icon(Icons.explore_outlined),
              label: const Text('Browse titles'),
            ),
          ],
        ),
      ),
    );
  }
}

class _DownloadTile extends StatelessWidget {
  const _DownloadTile({required this.job});

  final DownloadJob job;

  @override
  Widget build(BuildContext context) {
    final complete = job.status == DownloadStatus.complete;
    return Card(
      key: Key('download-${job.id}'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Container(
              width: 58,
              height: 74,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF5846B6), Color(0xFF242039)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                complete
                    ? Icons.offline_pin_rounded
                    : Icons.downloading_rounded,
              ),
            ),
            const SizedBox(width: 15),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    job.title,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '${job.source.resolution?.label ?? 'Unknown'} • '
                    '${job.source.codec.label} • ${job.source.sizeLabel}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 9),
                  if (job.status == DownloadStatus.downloading ||
                      job.status == DownloadStatus.queued)
                    LinearProgressIndicator(
                      value: job.progress > 0 ? job.progress : null,
                    )
                  else
                    Text(
                      _statusText(job),
                      style: TextStyle(
                        color: job.status == DownloadStatus.failed
                            ? Theme.of(context).colorScheme.error
                            : const Color(0xFF75D6A4),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Semantics(
              label: complete ? 'Play offline' : 'Download status',
              button: true,
              child: IconButton.filledTonal(
                tooltip: Platform.isWindows
                    ? null
                    : complete
                    ? 'Play offline'
                    : 'Download status',
                onPressed: complete && job.localPath != null
                    ? () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => PlayerScreen(
                            title: job.title,
                            source: _mediaUri(job.localPath!),
                            mediaTitle: job.mediaTitle,
                          ),
                        ),
                      )
                    : null,
                icon: Icon(
                  complete ? Icons.play_arrow_rounded : Icons.more_horiz,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _statusText(DownloadJob job) => switch (job.status) {
    DownloadStatus.queued => 'Preparing download…',
    DownloadStatus.downloading => '${(job.progress * 100).round()}%',
    DownloadStatus.complete => 'Ready offline',
    DownloadStatus.failed =>
      'Download failed — ${job.error ?? 'unknown error'}',
  };

  String _mediaUri(String value) =>
      value.contains('://') ? value : File(value).uri.toString();
}
