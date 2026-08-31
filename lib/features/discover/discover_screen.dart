import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/app_state.dart';
import '../../domain/catalog_title.dart';
import '../../domain/media_models.dart';
import '../common/page_header.dart';
import '../player/player_screen.dart';

class DiscoverScreen extends ConsumerWidget {
  const DiscoverScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(torBridgeControllerProvider);
    final best = state.recommendation.best;
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
          sliver: SliverToBoxAdapter(
            child: TextField(
              key: const Key('catalog-search'),
              decoration: const InputDecoration(
                hintText: 'Search movies and series',
                prefixIcon: Icon(Icons.search),
                suffixIcon: Icon(Icons.auto_awesome_outlined),
              ),
              onSubmitted: (query) => ref
                  .read(torBridgeControllerProvider.notifier)
                  .searchCatalog(query),
            ),
          ),
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
            height: 172,
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
                          alternatives: state.recommendation.alternatives,
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
                        alternatives: state.recommendation.alternatives,
                      ),
                    ],
                  ),
          ),
        ),
      ],
    );
  }
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
          width: 238,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [color, Color.lerp(color, Colors.black, 0.62)!],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: selected
                  ? Theme.of(context).colorScheme.primary
                  : Colors.white.withValues(alpha: 0.08),
              width: selected ? 2 : 1,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Spacer(),
              Text(
                title.genre.toUpperCase(),
                style: Theme.of(context).textTheme.labelSmall
                    ?.copyWith(letterSpacing: 1.1, color: Colors.white70),
              ),
              const SizedBox(height: 4),
              Text(
                title.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                ),
              ),
              Text(
                '${title.year}',
                style: const TextStyle(color: Colors.white70),
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
    final watched = ref.watch(
      torBridgeControllerProvider.select(
        (state) => state.watchedTitleIds.contains(title.id),
      ),
    );
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title.name, style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 6),
            Text('${title.year}  •  ${title.genre}'),
            const SizedBox(height: 14),
            Text(
              title.summary,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                height: 1.45,
              ),
            ),
            const SizedBox(height: 18),
            OutlinedButton.icon(
              key: const Key('toggle-watched'),
              onPressed: () => ref
                  .read(torBridgeControllerProvider.notifier)
                  .toggleWatched(title.id),
              icon: Icon(
                watched ? Icons.check_circle : Icons.check_circle_outline,
              ),
              label: Text(watched ? 'Watched' : 'Mark watched'),
            ),
          ],
        ),
      ),
    );
  }
}

class _RecommendationCard extends ConsumerWidget {
  const _RecommendationCard({required this.best, required this.alternatives});

  final RankedCandidate? best;
  final List<RankedCandidate> alternatives;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final candidate = best?.candidate;
    final mediaTitle = ref.watch(
      torBridgeControllerProvider.select((state) => state.selectedTitle),
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
              const Text('No source satisfies your current rules.')
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
                        trailing: Text('${alternative.score}'),
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
