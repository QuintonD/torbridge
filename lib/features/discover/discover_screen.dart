import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/app_state.dart';
import '../../domain/catalog_title.dart';
import '../../domain/media_models.dart';
import '../common/page_header.dart';
import '../common/artwork_image.dart';
import '../player/player_screen.dart';

class DiscoverScreen extends ConsumerWidget {
  const DiscoverScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(torBridgeControllerProvider);
    final recommendation = state.recommendation;
    final best = recommendation.best;
    final wide = MediaQuery.sizeOf(context).width >= 980;

    return CustomScrollView(
      key: const Key('discover-scroll'),
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 14),
          sliver: SliverToBoxAdapter(
            child: PageHeader(
              title: 'Discover',
              subtitle: 'Choose a title. TorBridge chooses the file.',
              trailing: _ConnectionBadge(demoMode: state.demoMode),
            ),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          sliver: SliverToBoxAdapter(child: const _CatalogSearch()),
        ),
        if (state.busy)
          const SliverPadding(
            padding: EdgeInsets.fromLTRB(24, 10, 24, 0),
            sliver: SliverToBoxAdapter(child: LinearProgressIndicator()),
          ),
        if (state.notice != null)
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(24, 10, 24, 0),
            sliver: SliverToBoxAdapter(
              child: Text(
                state.notice!,
                key: const Key('status-notice'),
                style: TextStyle(color: Theme.of(context).colorScheme.tertiary),
              ),
            ),
          ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(24, 22, 24, 10),
          sliver: SliverToBoxAdapter(
            child: Text(
              'Continue exploring',
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: SizedBox(
            height: 212,
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              scrollDirection: Axis.horizontal,
              itemCount: state.catalogTitles.length,
              separatorBuilder: (_, _) => const SizedBox(width: 12),
              itemBuilder: (context, index) {
                final title = state.catalogTitles[index];
                return _TitleCard(
                  title: title,
                  selected: title.id == state.selectedTitle.id,
                  onTap: () => ref
                      .read(torBridgeControllerProvider.notifier)
                      .selectTitle(title),
                );
              },
            ),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(24, 18, 24, 32),
          sliver: SliverToBoxAdapter(
            child: wide
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        flex: 4,
                        child: _TitleDetails(title: state.selectedTitle),
                      ),
                      const SizedBox(width: 18),
                      Expanded(
                        flex: 5,
                        child: _RecommendationCard(
                          best: best,
                          alternatives: recommendation.alternatives,
                          rejected: recommendation.rejected,
                          loading: state.busy,
                        ),
                      ),
                    ],
                  )
                : Column(
                    children: [
                      _TitleDetails(title: state.selectedTitle),
                      const SizedBox(height: 16),
                      _RecommendationCard(
                        best: best,
                        alternatives: recommendation.alternatives,
                        rejected: recommendation.rejected,
                        loading: state.busy,
                      ),
                    ],
                  ),
          ),
        ),
      ],
    );
  }
}

class _CatalogSearch extends ConsumerStatefulWidget {
  const _CatalogSearch();
  @override
  ConsumerState<_CatalogSearch> createState() => _CatalogSearchState();
}

class _CatalogSearchState extends ConsumerState<_CatalogSearch> {
  final _text = TextEditingController();
  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _search() {
    FocusScope.of(context).unfocus();
    unawaited(
      ref.read(torBridgeControllerProvider.notifier).searchCatalog(_text.text),
    );
  }

  @override
  Widget build(BuildContext context) => TextField(
    key: const Key('catalog-search'),
    controller: _text,
    textInputAction: TextInputAction.search,
    onChanged: (_) => setState(() {}),
    onSubmitted: (_) => _search(),
    decoration: InputDecoration(
      hintText: 'Search movies and series',
      prefixIcon: const Icon(Icons.search),
      suffixIcon: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_text.text.isNotEmpty)
            IconButton(
              tooltip: 'Clear search',
              icon: const Icon(Icons.close),
              onPressed: () {
                _text.clear();
                setState(() {});
                _search();
              },
            ),
          IconButton(
            tooltip: 'Search titles',
            icon: const Icon(Icons.arrow_forward),
            onPressed: _search,
          ),
        ],
      ),
    ),
  );
}

class _ConnectionBadge extends StatelessWidget {
  const _ConnectionBadge({required this.demoMode});

  final bool demoMode;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: demoMode ? 'Demo mode is active' : 'Live services are connected',
      child: Chip(
        avatar: Icon(
          demoMode ? Icons.science_outlined : Icons.cloud_done_outlined,
          size: 18,
        ),
        label: Text(demoMode ? 'Demo mode' : 'Live'),
        backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
      ),
    );
  }
}

class _TitleCard extends StatelessWidget {
  const _TitleCard({
    required this.title,
    required this.selected,
    required this.onTap,
  });

  final CatalogTitle title;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = Color(title.color);
    return Semantics(
      button: true,
      selected: selected,
      label: '${title.name}, ${title.year}',
      child: InkWell(
        key: Key('title-${title.id}'),
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          width: 132,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: selected
                  ? Theme.of(context).colorScheme.primary
                  : Colors.white.withValues(alpha: 0.08),
              width: selected ? 2 : 1,
            ),
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              ArtworkImage(url: title.posterUrl, fallbackColor: color),
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.transparent, Colors.black87],
                    stops: [0.42, 1],
                  ),
                ),
              ),
              Positioned(
                left: 10,
                right: 10,
                bottom: 9,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      '${title.year} · ${title.type == 'series' ? 'Series' : 'Movie'}',
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TitleDetails extends ConsumerWidget {
  const _TitleDetails({required this.title});

  final CatalogTitle title;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(torBridgeControllerProvider);
    final video = state.selectedVideo;
    final watched = state.watchedTitleIds.contains(video?.id ?? title.id);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 150,
            child: Stack(
              fit: StackFit.expand,
              children: [
                ArtworkImage(
                  url: title.backgroundUrl ?? title.posterUrl,
                  fallbackColor: Color(title.color),
                ),
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Colors.transparent, Color(0xFF17151F)],
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title.name,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 6),
                Text('${title.year}  •  ${title.genre}'),
                const SizedBox(height: 14),
                Text(
                  video?.overview.isNotEmpty == true
                      ? video!.overview
                      : title.summary,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    height: 1.45,
                  ),
                ),
                if (title.isSeries && title.videos.isNotEmpty) ...[
                  const SizedBox(height: 18),
                  _EpisodePicker(title: title, selected: video),
                ],
                const SizedBox(height: 18),
                OutlinedButton.icon(
                  key: const Key('toggle-watched'),
                  onPressed: title.isSeries && video == null
                      ? null
                      : () => ref
                            .read(torBridgeControllerProvider.notifier)
                            .toggleWatched(video?.id ?? title.id),
                  icon: Icon(
                    watched ? Icons.check_circle : Icons.check_circle_outline,
                  ),
                  label: Text(
                    watched
                        ? video == null
                              ? 'Watched'
                              : '${video.code} watched'
                        : 'Mark ${video?.code ?? 'movie'} watched',
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _EpisodePicker extends ConsumerWidget {
  const _EpisodePicker({required this.title, required this.selected});

  final CatalogTitle title;
  final CatalogVideo? selected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final seasons = title.videos.map((video) => video.season).toSet().toList()
      ..sort();
    final selectedSeason = selected?.season ?? seasons.first;
    final episodes = title.videos
        .where((video) => video.season == selectedSeason)
        .toList();
    final watched = ref.watch(
      torBridgeControllerProvider.select((state) => state.watchedTitleIds),
    );
    final alreadyAdded = ref.watch(
      torBridgeControllerProvider.select(
        (state) => state.downloads
            .where((job) => !job.needsAttention)
            .map((job) => job.videoId)
            .toSet(),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Episodes',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            DropdownButton<int>(
              key: const Key('season-selector'),
              value: selectedSeason,
              items: [
                for (final season in seasons)
                  DropdownMenuItem(
                    value: season,
                    child: Text('Season $season'),
                  ),
              ],
              onChanged: (season) {
                if (season == null) return;
                final first = title.videos.firstWhere(
                  (video) => video.season == season,
                );
                ref
                    .read(torBridgeControllerProvider.notifier)
                    .selectVideo(first);
              },
            ),
          ],
        ),
        const SizedBox(height: 8),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 250),
          child: ListView.separated(
            shrinkWrap: true,
            itemCount: episodes.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final episode = episodes[index];
              final active = episode.id == selected?.id;
              return ListTile(
                key: Key('episode-${episode.id}'),
                selected: active,
                contentPadding: EdgeInsets.zero,
                leading: SizedBox(
                  width: 68,
                  height: 42,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(7),
                    child: ArtworkImage(
                      url: episode.thumbnailUrl,
                      fallbackColor: Color(title.color),
                      icon: Icons.tv,
                    ),
                  ),
                ),
                title: Text('${episode.code} · ${episode.title}'),
                subtitle: episode.released == null
                    ? null
                    : Text(
                        '${episode.released!.year}-${episode.released!.month.toString().padLeft(2, '0')}-${episode.released!.day.toString().padLeft(2, '0')}',
                      ),
                trailing: watched.contains(episode.id)
                    ? const Icon(Icons.check_circle, color: Color(0xFF75D6A4))
                    : null,
                onTap: () => ref
                    .read(torBridgeControllerProvider.notifier)
                    .selectVideo(episode),
              );
            },
          ),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          key: Key('download-season-$selectedSeason'),
          onPressed: () => _chooseEpisodeDownloads(
            context,
            ref,
            season: selectedSeason,
            episodes: episodes,
            alreadyAdded: alreadyAdded,
          ),
          icon: const Icon(Icons.download_for_offline_outlined),
          label: const Text('Download episodes'),
        ),
      ],
    );
  }

  Future<void> _chooseEpisodeDownloads(
    BuildContext context,
    WidgetRef ref, {
    required int season,
    required List<CatalogVideo> episodes,
    required Set<String> alreadyAdded,
  }) async {
    final selected = await showDialog<List<CatalogVideo>>(
      context: context,
      builder: (dialogContext) {
        final selectedIds = <String>{};
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final available = episodes
                .where((episode) => !alreadyAdded.contains(episode.id))
                .toList(growable: false);
            return AlertDialog(
              title: Text('Download Season $season'),
              content: SizedBox(
                width: 520,
                height: (episodes.length * 64 + 72).clamp(180, 520).toDouble(),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Wrap(
                      alignment: WrapAlignment.spaceBetween,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        TextButton(
                          key: const Key('select-all-episodes'),
                          onPressed: available.isEmpty
                              ? null
                              : () => setDialogState(() {
                                  selectedIds
                                    ..clear()
                                    ..addAll(available.map((item) => item.id));
                                }),
                          child: const Text('Select all'),
                        ),
                        TextButton(
                          onPressed: selectedIds.isEmpty
                              ? null
                              : () => setDialogState(selectedIds.clear),
                          child: const Text('Clear'),
                        ),
                        Text('${selectedIds.length} selected'),
                      ],
                    ),
                    const Divider(height: 1),
                    Flexible(
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: episodes.length,
                        itemBuilder: (context, index) {
                          final episode = episodes[index];
                          final unavailable = alreadyAdded.contains(episode.id);
                          return CheckboxListTile(
                            key: Key('bulk-episode-${episode.id}'),
                            value: selectedIds.contains(episode.id),
                            dense: true,
                            controlAffinity: ListTileControlAffinity.leading,
                            title: Text('${episode.code} · ${episode.title}'),
                            subtitle: unavailable
                                ? const Text('Already downloaded or queued')
                                : null,
                            onChanged: unavailable
                                ? null
                                : (checked) => setDialogState(() {
                                    if (checked == true) {
                                      selectedIds.add(episode.id);
                                    } else {
                                      selectedIds.remove(episode.id);
                                    }
                                  }),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('Cancel'),
                ),
                FilledButton.icon(
                  key: const Key('queue-selected-episodes'),
                  onPressed: selectedIds.isEmpty
                      ? null
                      : () => Navigator.pop(
                          dialogContext,
                          episodes
                              .where(
                                (episode) => selectedIds.contains(episode.id),
                              )
                              .toList(growable: false),
                        ),
                  icon: const Icon(Icons.download_rounded),
                  label: Text(
                    selectedIds.length == 1
                        ? 'Download episode'
                        : 'Download ${selectedIds.length} episodes',
                  ),
                ),
              ],
            );
          },
        );
      },
    );
    if (selected == null || selected.isEmpty || !context.mounted) return;
    final result = await ref
        .read(torBridgeControllerProvider.notifier)
        .downloadEpisodes(title, selected);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(result.message)));
    if (result.queued > 0) {
      ref.read(torBridgeControllerProvider.notifier).navigate(1);
    }
  }
}

class _RecommendationCard extends ConsumerWidget {
  const _RecommendationCard({
    required this.best,
    required this.alternatives,
    required this.rejected,
    required this.loading,
  });

  final RankedCandidate? best;
  final List<RankedCandidate> alternatives;
  final List<RankedCandidate> rejected;
  final bool loading;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final candidate = best?.candidate;
    final mediaTitle = ref.watch(
      torBridgeControllerProvider.select((state) => state.selectedTitle),
    );
    final mediaVideo = ref.watch(
      torBridgeControllerProvider.select((state) => state.selectedVideo),
    );
    return Card(
      key: const Key('recommendation-card'),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  Icons.auto_awesome,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Recommended download',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                if (best != null)
                  Text(
                    '${best!.score} pts',
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
              ],
            ),
            const SizedBox(height: 16),
            if (candidate == null)
              _NoEligibleSources(rejected: rejected, loading: loading)
            else ...[
              Text(
                candidate.displayName,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _FactChip(
                    icon: Icons.high_quality_outlined,
                    label: candidate.resolution?.label ?? 'Quality unknown',
                  ),
                  _FactChip(icon: Icons.memory, label: candidate.codec.label),
                  _FactChip(
                    icon: Icons.bolt,
                    label: candidate.cacheStatus.label,
                  ),
                  _FactChip(icon: Icons.sd_storage, label: candidate.sizeLabel),
                  _FactChip(
                    icon: Icons.volume_up_outlined,
                    label: candidate.audioLanguages.isEmpty
                        ? 'Audio unknown'
                        : 'Audio: ${candidate.audioLanguages.join(', ')}',
                  ),
                  _FactChip(
                    icon: Icons.subtitles_outlined,
                    label: candidate.subtitleLanguages.isEmpty
                        ? 'No subtitles listed'
                        : 'Subs: ${candidate.subtitleLanguages.join(', ')}',
                  ),
                ],
              ),
              const SizedBox(height: 14),
              for (final reason in best!.reasons.take(4))
                Padding(
                  padding: const EdgeInsets.only(bottom: 5),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(
                        Icons.check,
                        size: 17,
                        color: Color(0xFF75D6A4),
                      ),
                      const SizedBox(width: 8),
                      Expanded(child: Text(reason)),
                    ],
                  ),
                ),
              const SizedBox(height: 14),
              FilledButton.icon(
                key: const Key('download-best'),
                onPressed: () => unawaited(
                  ref
                      .read(torBridgeControllerProvider.notifier)
                      .downloadRecommended(),
                ),
                icon: const Icon(Icons.download_rounded),
                label: const Text('Download best match'),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                key: const Key('play-best'),
                onPressed: candidate.streamUrl == null
                    ? null
                    : () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => PlayerScreen(
                            title: candidate.displayName,
                            source: candidate.streamUrl.toString(),
                            mediaTitle: mediaTitle,
                            mediaVideo: mediaVideo,
                          ),
                        ),
                      ),
                icon: const Icon(Icons.play_arrow_rounded),
                label: const Text('Play now'),
              ),
              if (alternatives.isNotEmpty) ...[
                const SizedBox(height: 6),
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  title: Text('${alternatives.length} suitable alternatives'),
                  children: [
                    for (final alternative in alternatives)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        title: Text(alternative.candidate.displayName),
                        subtitle: Text(
                          '${alternative.candidate.resolution?.label ?? 'Unknown'} • '
                          '${alternative.candidate.codec.label} • '
                          '${alternative.candidate.sizeLabel}',
                        ),
                        trailing: IconButton(
                          tooltip: 'Download this version',
                          onPressed: () => unawaited(
                            ref
                                .read(torBridgeControllerProvider.notifier)
                                .downloadCandidate(alternative.candidate),
                          ),
                          icon: const Icon(Icons.download_outlined),
                        ),
                      ),
                  ],
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

class _NoEligibleSources extends ConsumerWidget {
  const _NoEligibleSources({required this.rejected, required this.loading});

  final List<RankedCandidate> rejected;
  final bool loading;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (loading) return const Text('Searching for sources…');
    if (rejected.isEmpty) {
      return const Text('AIOStreams returned no sources for this selection.');
    }

    final counts = <String, int>{};
    for (final ranked in rejected) {
      for (final reason in ranked.rejections) {
        counts.update(reason, (count) => count + 1, ifAbsent: () => 1);
      }
    }
    final summary = counts.entries.toList()
      ..sort((a, b) {
        final byCount = b.value.compareTo(a.value);
        return byCount != 0 ? byCount : a.key.compareTo(b.key);
      });

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '${rejected.length} ${rejected.length == 1 ? 'source was' : 'sources were'} found, but rejected by your rules.',
        ),
        const SizedBox(height: 10),
        for (final entry in summary.take(5))
          Padding(
            padding: const EdgeInsets.only(bottom: 5),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.block_outlined,
                  size: 17,
                  color: Theme.of(context).colorScheme.error,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    entry.value == 1
                        ? entry.key
                        : '${entry.key} (${entry.value} sources)',
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          key: const Key('review-download-rules'),
          onPressed: () =>
              ref.read(torBridgeControllerProvider.notifier).navigate(3),
          icon: const Icon(Icons.tune),
          label: const Text('Review download rules'),
        ),
      ],
    );
  }
}

class _FactChip extends StatelessWidget {
  const _FactChip({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Chip(
      avatar: Icon(icon, size: 17),
      label: Text(label),
      visualDensity: VisualDensity.compact,
    );
  }
}
