import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/app_state.dart';
import '../common/page_header.dart';

class DiagnosticsScreen extends ConsumerWidget {
  const DiagnosticsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(torBridgeControllerProvider);
    final checks = state.diagnosticChecks;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageHeader(
            title: 'Diagnostics',
            subtitle: 'Check local playback, downloaded files, and connected services.',
            trailing: FilledButton.tonalIcon(
              key: const Key('run-diagnostics'),
              onPressed: () => unawaited(
                ref.read(torBridgeControllerProvider.notifier).runDiagnostics(),
              ),
              icon: const Icon(Icons.health_and_safety_outlined),
              label: const Text('Run checks'),
            ),
          ),
          const SizedBox(height: 22),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(bottom: 24),
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          'System checks',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        const SizedBox(height: 12),
                        if (checks.isEmpty)
                          const Text(
                            'Choose “Run checks” to test the local addon, files and integrations.',
                          )
                        else
                          for (final check in checks.entries)
                            _CheckRow(name: check.key, detail: check.value),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          'Stremio handoff',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        const SizedBox(height: 10),
                        const SelectableText(
                          'Addon: http://127.0.0.1:11471/manifest.json\n'
                          'Movies: tt…\nEpisodes: tt…:season:episode',
                        ),
                        const SizedBox(height: 10),
                        Text(
                          'Keep TorBridge running while Stremio plays a local file. Direct playback may not sync Trakt history. Use Play in TorBridge for embedded playback tracking.',
                          style: TextStyle(
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'Download records',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 10),
                if (state.downloads.isEmpty)
                  const Card(
                    child: Padding(
                      padding: EdgeInsets.all(20),
                      child: Text('No download records to inspect.'),
                    ),
                  )
                else
                  for (final job in state.downloads)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Card(
                        child: ExpansionTile(
                          title: Text(job.title),
                          subtitle: Text('${job.status.name} · ${job.videoId}'),
                          childrenPadding: const EdgeInsets.fromLTRB(
                            16,
                            0,
                            16,
                            16,
                          ),
                          children: [
                            _RecordLine(
                              label: 'Media type',
                              value: job.mediaTitle.type,
                            ),
                            _RecordLine(label: 'Video ID', value: job.videoId),
                            _RecordLine(
                              label: 'Source',
                              value: job.source.addonName,
                            ),
                            _RecordLine(
                              label: 'Tags',
                              value: job.tags.join(', '),
                            ),
                            _RecordLine(label: 'Audio', value: job.audioLabel),
                            _RecordLine(
                              label: 'Subtitles',
                              value: job.subtitleLabel,
                            ),
                            _RecordLine(
                              label: 'Local path',
                              value: job.localPath ?? 'Not complete',
                            ),
                            _RecordLine(
                              label: 'Platform job',
                              value: job.platformId ?? 'None',
                            ),
                            _RecordLine(
                              label: 'Watched detected',
                              value:
                                  job.watchedAt?.toLocal().toString() ?? 'No',
                            ),
                            if (job.error != null)
                              _RecordLine(label: 'Error', value: job.error!),
                          ],
                        ),
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

class _CheckRow extends StatelessWidget {
  const _CheckRow({required this.name, required this.detail});

  final String name;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final lower = detail.toLowerCase();
    final problem =
        lower.startsWith('failed') ||
        RegExp(r'^\d+ of \d+ files are missing').hasMatch(lower) ||
        lower.contains('not responding');
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        problem ? Icons.error_outline : Icons.check_circle_outline,
        color: problem
            ? Theme.of(context).colorScheme.error
            : const Color(0xFF75D6A4),
      ),
      title: Text(name),
      subtitle: Text(detail),
    );
  }
}

class _RecordLine extends StatelessWidget {
  const _RecordLine({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 130,
          child: Text(label, style: Theme.of(context).textTheme.labelMedium),
        ),
        Expanded(child: SelectableText(value)),
      ],
    ),
  );
}
