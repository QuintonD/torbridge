import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/app_state.dart';
import '../common/artwork_image.dart';
import '../common/page_header.dart';
import '../player/player_screen.dart';

enum _DownloadFilter { all, ready, active, failed }

class DownloadsScreen extends ConsumerStatefulWidget {
  const DownloadsScreen({super.key});

  @override
  ConsumerState<DownloadsScreen> createState() => _DownloadsScreenState();
}

class _DownloadsScreenState extends ConsumerState<DownloadsScreen> {
  _DownloadFilter _filter = _DownloadFilter.all;
  @override
  Widget build(BuildContext context) {
    final state = ref.watch(torBridgeControllerProvider);
    final jobs = state.downloads
        .where(
          (job) => switch (_filter) {
            _DownloadFilter.all => true,
            _DownloadFilter.ready => job.status == DownloadStatus.complete,
            _DownloadFilter.active =>
              job.status == DownloadStatus.queued ||
                  job.status == DownloadStatus.downloading,
            _DownloadFilter.failed => job.needsAttention,
          },
        )
        .toList();
    final controller = ref.read(torBridgeControllerProvider.notifier);
    return CustomScrollView(
      key: const Key('downloads-scroll'),
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.all(24),
          sliver: SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                PageHeader(
                  title: 'Downloads',
                  subtitle: 'Your offline collection.',
                  trailing: OutlinedButton.icon(
                    key: const Key('install-stremio-addon'),
                    onPressed: () =>
                        unawaited(controller.installStremioAddon()),
                    icon: const Icon(Icons.extension_outlined),
                    label: const Text('Set up Stremio'),
                  ),
                ),
                const SizedBox(height: 22),
                if (state.notice != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      state.notice!,
                      key: const Key('download-notice'),
                    ),
                  ),
                if (state.downloads.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final filter in _DownloadFilter.values)
                          ChoiceChip(
                            key: Key('download-filter-${filter.name}'),
                            label: Text(switch (filter) {
                              _DownloadFilter.all =>
                                'All (${state.downloads.length})',
                              _DownloadFilter.ready => 'Ready',
                              _DownloadFilter.active => 'Downloading',
                              _DownloadFilter.failed => 'Needs attention',
                            }),
                            selected: _filter == filter,
                            onSelected: (_) => setState(() => _filter = filter),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
        if (state.downloads.isEmpty)
          const SliverFillRemaining(
            hasScrollBody: false,
            child: Padding(
              padding: EdgeInsets.all(24),
              child: _EmptyDownloads(),
            ),
          )
        else if (jobs.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.filter_list_off, size: 40),
                  const SizedBox(height: 12),
                  const Text('No downloads in this view'),
                  TextButton(
                    onPressed: () =>
                        setState(() => _filter = _DownloadFilter.all),
                    child: const Text('Show all downloads'),
                  ),
                ],
              ),
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
            sliver: SliverList.separated(
              itemCount: jobs.length,
              separatorBuilder: (_, _) => const SizedBox(height: 14),
              itemBuilder: (_, index) => _DownloadTile(job: jobs[index]),
            ),
          ),
      ],
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
              'Pick a movie or exact episode and use “Download best match”.',
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

class _DownloadTile extends ConsumerWidget {
  const _DownloadTile({required this.job});

  final DownloadJob job;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final complete = job.status == DownloadStatus.complete;
    final controller = ref.read(torBridgeControllerProvider.notifier);
    final artwork = job.mediaVideo?.thumbnailUrl ?? job.mediaTitle.posterUrl;
    return Card(
      key: Key('download-${job.id}'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: SizedBox(
                    width: 64,
                    height: 92,
                    child: ArtworkImage(
                      url: artwork,
                      fallbackColor: Color(job.mediaTitle.color),
                    ),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        job.title,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        job.episodeLabel,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(height: 10),
                      Text(
                        _statusText(job),
                        style: TextStyle(
                          color: job.needsAttention
                              ? Theme.of(context).colorScheme.error
                              : complete
                              ? const Color(0xFF75D6A4)
                              : Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                      if (job.watchedAt != null) const Text('Watched'),
                    ],
                  ),
                ),
                PopupMenuButton<_DownloadAction>(
                  tooltip: 'Download actions',
                  onSelected: (action) => _runAction(context, ref, action),
                  itemBuilder: (_) => [
                    if (complete || job.needsAttention)
                      const PopupMenuItem(
                        value: _DownloadAction.changeVersion,
                        child: ListTile(
                          leading: Icon(Icons.tune),
                          title: Text('Find another version'),
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                    if (complete || job.needsAttention)
                      const PopupMenuItem(
                        value: _DownloadAction.changeRules,
                        child: ListTile(
                          leading: Icon(Icons.high_quality_outlined),
                          title: Text('Change download rules'),
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                    if (complete && job.localPath != null)
                      const PopupMenuItem(
                        value: _DownloadAction.playFallback,
                        child: ListTile(
                          leading: Icon(Icons.play_circle_outline),
                          title: Text('Play in TorBridge'),
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                    if (complete && job.localPath != null)
                      const PopupMenuItem(
                        value: _DownloadAction.playExternal,
                        child: ListTile(
                          leading: Icon(Icons.open_in_new),
                          title: Text('Play in external player'),
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                    const PopupMenuItem(
                      value: _DownloadAction.delete,
                      child: ListTile(
                        leading: Icon(Icons.delete_outline),
                        title: Text('Delete'),
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                  ],
                ),
              ],
            ),
            if (job.status == DownloadStatus.downloading ||
                job.status == DownloadStatus.queued) ...[
              const SizedBox(height: 16),
              LinearProgressIndicator(
                value: job.progress > 0 ? job.progress.clamp(0, 1) : null,
                minHeight: 5,
                borderRadius: BorderRadius.circular(4),
              ),
            ],
            const SizedBox(height: 16),
            Wrap(
              spacing: 10,
              runSpacing: 8,
              children: [
                if (complete) ...[
                  FilledButton.icon(
                    key: Key('play-torbridge-${job.id}'),
                    onPressed: job.localPath == null
                        ? null
                        : () => _runAction(
                            context,
                            ref,
                            _DownloadAction.playFallback,
                          ),
                    icon: const Icon(Icons.play_arrow_rounded),
                    label: const Text('Play'),
                  ),
                  OutlinedButton.icon(
                    key: Key('play-stremio-${job.id}'),
                    onPressed: () => unawaited(controller.openInStremio(job)),
                    icon: const Icon(Icons.ondemand_video_rounded),
                    label: const Text('Stremio'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () =>
                        unawaited(controller.openInExternalPlayer(job)),
                    icon: const Icon(Icons.open_in_new),
                    label: const Text('External player'),
                  ),
                ] else if (job.needsAttention)
                  FilledButton.tonalIcon(
                    onPressed: () => unawaited(controller.retryDownload(job)),
                    icon: const Icon(Icons.refresh),
                    label: const Text('Retry download'),
                  )
                else
                  TextButton.icon(
                    onPressed: () => unawaited(controller.cancelDownload(job)),
                    icon: const Icon(Icons.close),
                    label: const Text('Cancel download'),
                  ),
              ],
            ),
            const Divider(height: 28),
            Wrap(
              spacing: 12,
              runSpacing: 6,
              children: [
                for (final tag in job.tags)
                  Text(tag, style: Theme.of(context).textTheme.bodySmall),
                Text(
                  job.source.sizeLabel,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(job.audioLabel, style: Theme.of(context).textTheme.bodySmall),
            Text(
              job.subtitleLabel,
              key: Key('subtitle-info-${job.id}'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _runAction(
    BuildContext context,
    WidgetRef ref,
    _DownloadAction action,
  ) async {
    final controller = ref.read(torBridgeControllerProvider.notifier);
    switch (action) {
      case _DownloadAction.changeVersion:
        controller.prepareAnotherVersion(job);
      case _DownloadAction.changeRules:
        controller.prepareAnotherVersion(job);
        controller.navigate(3);
      case _DownloadAction.playFallback:
        final path = await controller.localPlaybackSource(job);
        if (path == null || !context.mounted) return;
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => PlayerScreen(
              title: job.title,
              source: _mediaUri(path),
              mediaTitle: job.mediaTitle,
              mediaVideo: job.mediaVideo,
            ),
          ),
        );
      case _DownloadAction.playExternal:
        await controller.openInExternalPlayer(job);
      case _DownloadAction.delete:
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('Delete download?'),
            content: Text('This removes “${job.title}” from this device.'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('Delete'),
              ),
            ],
          ),
        );
        if (confirmed == true) await controller.deleteDownload(job);
    }
  }

  String _statusText(DownloadJob job) => switch (job.status) {
    DownloadStatus.queued => 'Preparing download…',
    DownloadStatus.downloading =>
      'Downloading ? ${(job.progress * 100).round()}%',
    DownloadStatus.complete => 'Ready offline',
    DownloadStatus.unavailable =>
      'File unavailable — ${job.error ?? 'Retry the download while online.'}',
    DownloadStatus.failed =>
      'Download failed — ${job.error ?? 'unknown error'}',
  };

  String _mediaUri(String value) =>
      value.contains('://') ? value : File(value).uri.toString();
}

enum _DownloadAction {
  changeVersion,
  changeRules,
  playFallback,
  playExternal,
  delete,
}
