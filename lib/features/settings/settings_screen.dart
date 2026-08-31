import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/app_state.dart';
import '../../domain/media_models.dart';
import '../../integrations/trakt_client.dart';
import '../../services/credential_store.dart';
import '../common/page_header.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  static const _languages = <String>[
    'English',
    'Dutch',
    'German',
    'French',
    'Spanish',
    'Italian',
    'Japanese',
    'Korean',
    'Chinese',
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final preferences = ref.watch(
      torBridgeControllerProvider.select((state) => state.preferences),
    );
    final controller = ref.read(torBridgeControllerProvider.notifier);
    final wide = MediaQuery.sizeOf(context).width >= 960;
    final preferenceCard = _PreferenceCard(
      preferences: preferences,
      languages: _languages,
      onChanged: controller.updatePreferences,
    );
    const connectionCard = _ConnectionCard();

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const PageHeader(
            title: 'Settings',
            subtitle:
                'Set the rules once. TorBridge applies them to every search.',
          ),
          const SizedBox(height: 22),
          if (wide)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(flex: 6, child: preferenceCard),
                const SizedBox(width: 16),
                const Expanded(flex: 4, child: connectionCard),
              ],
            )
          else ...[
            preferenceCard,
            const SizedBox(height: 16),
            connectionCard,
          ],
        ],
      ),
    );
  }
}

class _PreferenceCard extends StatelessWidget {
  const _PreferenceCard({
    required this.preferences,
    required this.languages,
    required this.onChanged,
  });

  final DownloadPreferences preferences;
  final List<String> languages;
  final ValueChanged<DownloadPreferences> onChanged;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Best-link rules',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 4),
            Text(
              'Hard rules remove unsuitable files. Preferences decide the winner.',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 20),
            _LanguageSelector(
              key: const Key('audio-language'),
              label: 'Preferred audio',
              icon: Icons.volume_up_outlined,
              languages: languages,
              selected: preferences.audioLanguageOrder.first,
              optionKeyPrefix: 'audio-language',
              onChanged: (value) {
                onChanged(
                  preferences.copyWith(
                    audioLanguageOrder: [
                      value,
                      ...preferences.audioLanguageOrder.where(
                        (language) => language != value,
                      ),
                    ],
                  ),
                );
              },
            ),
            const SizedBox(height: 12),
            _LanguageSelector(
              key: const Key('subtitle-language'),
              label: 'Preferred subtitles',
              icon: Icons.subtitles_outlined,
              languages: languages,
              selected: preferences.subtitleLanguageOrder.first,
              optionKeyPrefix: 'subtitle-language',
              onChanged: (value) {
                onChanged(
                  preferences.copyWith(
                    subtitleLanguageOrder: [
                      value,
                      ...preferences.subtitleLanguageOrder.where(
                        (language) => language != value,
                      ),
                    ],
                  ),
                );
              },
            ),
            const SizedBox(height: 12),
            InputDecorator(
              key: const Key('preferred-quality'),
              decoration: const InputDecoration(
                labelText: 'Preferred quality',
                prefixIcon: Icon(Icons.high_quality_outlined),
              ),
              child: SegmentedButton<VideoResolution>(
                showSelectedIcon: false,
                expandedInsets: EdgeInsets.zero,
                segments: [
                  for (final resolution in VideoResolution.values)
                    ButtonSegment(
                      value: resolution,
                      label: Text(
                        resolution.label,
                        key: Key('quality-${resolution.name}'),
                      ),
                    ),
                ],
                selected: {preferences.preferredResolution},
                onSelectionChanged: (selection) {
                  if (selection.isNotEmpty) {
                    onChanged(
                      preferences.copyWith(
                        preferredResolution: selection.single,
                      ),
                    );
                  }
                },
              ),
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                const Icon(Icons.sd_storage_outlined),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Maximum file size',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                Text(
                  '${(preferences.maximumSizeBytes / 1000000000).round()} GB',
                ),
              ],
            ),
            Slider(
              key: const Key('maximum-size'),
              value: (preferences.maximumSizeBytes / 1000000000).clamp(2, 50),
              min: 2,
              max: 50,
              divisions: 24,
              label:
                  '${(preferences.maximumSizeBytes / 1000000000).round()} GB',
              onChanged: (value) => onChanged(
                preferences.copyWith(
                  maximumSizeBytes: (value * 1000000000).round(),
                ),
              ),
            ),
            SwitchListTile(
              key: const Key('cached-only'),
              contentPadding: EdgeInsets.zero,
              title: const Text('Instant sources only'),
              subtitle: const Text('Reject files TorBox still needs to cache'),
              value: preferences.cachedOnly,
              onChanged: (value) =>
                  onChanged(preferences.copyWith(cachedOnly: value)),
            ),
            SwitchListTile(
              key: const Key('require-audio'),
              contentPadding: EdgeInsets.zero,
              title: const Text('Require preferred audio'),
              subtitle: const Text(
                'Unknown audio can otherwise remain eligible',
              ),
              value: preferences.requirePreferredAudio,
              onChanged: (value) =>
                  onChanged(preferences.copyWith(requirePreferredAudio: value)),
            ),
            SwitchListTile(
              key: const Key('prefer-hdr'),
              contentPadding: EdgeInsets.zero,
              title: const Text('Prefer HDR'),
              subtitle: const Text('Boost Dolby Vision and HDR10 sources'),
              value: preferences.preferHdr,
              onChanged: (value) =>
                  onChanged(preferences.copyWith(preferHdr: value)),
            ),
          ],
        ),
      ),
    );
  }
}

class _LanguageSelector extends StatelessWidget {
  const _LanguageSelector({
    super.key,
    required this.label,
    required this.icon,
    required this.languages,
    required this.selected,
    required this.optionKeyPrefix,
    required this.onChanged,
  });

  final String label;
  final IconData icon;
  final List<String> languages;
  final String selected;
  final String optionKeyPrefix;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return InputDecorator(
      decoration: InputDecoration(labelText: label, prefixIcon: Icon(icon)),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final language in languages)
            ChoiceChip(
              key: Key('$optionKeyPrefix-$language'),
              label: Text(language),
              selected: language == selected,
              showCheckmark: false,
              visualDensity: VisualDensity.compact,
              onSelected: (_) => onChanged(language),
            ),
        ],
      ),
    );
  }
}

class _ConnectionCard extends ConsumerWidget {
  const _ConnectionCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(torBridgeControllerProvider);
    final connections = state.connections;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Connections', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 14),
            _ServiceStatus(
              icon: Icons.cloud_outlined,
              name: 'TorBox',
              status: connections.hasTorBox
                  ? 'API token saved'
                  : 'Not connected',
              connected: connections.hasTorBox,
            ),
            const Divider(height: 26),
            _ServiceStatus(
              icon: Icons.hub_outlined,
              name: 'AIOStreams',
              status: connections.hasAioStreams
                  ? 'Addon URL saved'
                  : 'Not connected',
              connected: connections.hasAioStreams,
            ),
            const Divider(height: 26),
            _ServiceStatus(
              icon: Icons.sync,
              name: 'Trakt',
              status: connections.hasTraktSession
                  ? 'Scrobbling connected'
                  : connections.hasTraktApp
                  ? 'App configured; authorization needed'
                  : 'Local watched state only',
              connected: connections.hasTraktSession,
            ),
            const SizedBox(height: 18),
            FilledButton.tonalIcon(
              key: const Key('configure-services'),
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => _ConnectionDialog(existing: connections),
              ),
              icon: const Icon(Icons.admin_panel_settings_outlined),
              label: Text(
                connections.hasAioStreams || connections.hasTorBox
                    ? 'Edit connections'
                    : 'Connect services',
              ),
            ),
            if (connections.hasTraktApp && !connections.hasTraktSession) ...[
              const SizedBox(height: 8),
              OutlinedButton.icon(
                key: const Key('authorize-trakt'),
                onPressed: () => showDialog<void>(
                  context: context,
                  barrierDismissible: false,
                  builder: (_) => const _TraktDeviceDialog(),
                ),
                icon: const Icon(Icons.open_in_browser),
                label: const Text('Authorize Trakt'),
              ),
            ],
            if (connections.hasAioStreams && connections.hasTorBox) ...[
              const SizedBox(height: 8),
              SwitchListTile(
                key: const Key('demo-mode'),
                contentPadding: EdgeInsets.zero,
                title: const Text('Demo mode'),
                subtitle: const Text('Use safe built-in sources for testing'),
                value: state.demoMode,
                onChanged: ref
                    .read(torBridgeControllerProvider.notifier)
                    .useDemoMode,
              ),
            ],
            const SizedBox(height: 10),
            Text(
              'Tokens will be stored in the operating system credential vault, never in addon URLs or logs.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _ConnectionDialog extends ConsumerStatefulWidget {
  const _ConnectionDialog({required this.existing});

  final StoredConnections existing;

  @override
  ConsumerState<_ConnectionDialog> createState() => _ConnectionDialogState();
}

class _ConnectionDialogState extends ConsumerState<_ConnectionDialog> {
  late final TextEditingController _aio;
  late final TextEditingController _torBox;
  late final TextEditingController _traktId;
  late final TextEditingController _traktSecret;
  bool _showSecrets = false;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _aio = TextEditingController(text: widget.existing.aioManifestUrl ?? '');
    _torBox = TextEditingController(text: widget.existing.torBoxToken ?? '');
    _traktId = TextEditingController(text: widget.existing.traktClientId ?? '');
    _traktSecret = TextEditingController(
      text: widget.existing.traktClientSecret ?? '',
    );
  }

  @override
  void dispose() {
    _aio.dispose();
    _torBox.dispose();
    _traktId.dispose();
    _traktSecret.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Connect services'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Paste the same configured AIOStreams manifest URL used by Stremio. Secrets are saved in this device’s credential vault.',
              ),
              const SizedBox(height: 16),
              TextField(
                key: const Key('aio-url-field'),
                controller: _aio,
                obscureText: !_showSecrets,
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(
                  labelText: 'AIOStreams manifest URL',
                  prefixIcon: Icon(Icons.hub_outlined),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                key: const Key('torbox-token-field'),
                controller: _torBox,
                obscureText: !_showSecrets,
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(
                  labelText: 'TorBox API token',
                  prefixIcon: Icon(Icons.key_outlined),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'Optional Trakt app credentials',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 8),
              TextField(
                key: const Key('trakt-client-field'),
                controller: _traktId,
                obscureText: !_showSecrets,
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(labelText: 'Trakt client ID'),
              ),
              const SizedBox(height: 10),
              TextField(
                key: const Key('trakt-secret-field'),
                controller: _traktSecret,
                obscureText: !_showSecrets,
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(
                  labelText: 'Trakt client secret',
                ),
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Show secrets'),
                value: _showSecrets,
                onChanged: (value) =>
                    setState(() => _showSecrets = value ?? false),
              ),
              if (_error != null)
                Text(
                  _error!,
                  key: const Key('connection-error'),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('save-connections'),
          onPressed: _saving ? null : _save,
          child: Text(_saving ? 'Checking…' : 'Check & save'),
        ),
      ],
    );
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    final error = await ref
        .read(torBridgeControllerProvider.notifier)
        .saveConnections(
          aioManifestUrl: _aio.text,
          torBoxToken: _torBox.text,
          traktClientId: _traktId.text,
          traktClientSecret: _traktSecret.text,
        );
    if (!mounted) return;
    if (error == null) {
      Navigator.pop(context);
    } else {
      setState(() {
        _saving = false;
        _error = error;
      });
    }
  }
}

class _TraktDeviceDialog extends ConsumerStatefulWidget {
  const _TraktDeviceDialog();

  @override
  ConsumerState<_TraktDeviceDialog> createState() => _TraktDeviceDialogState();
}

class _TraktDeviceDialogState extends ConsumerState<_TraktDeviceDialog> {
  TraktDeviceCode? _code;
  Timer? _timer;
  String _status = 'Requesting a device code…';

  @override
  void initState() {
    super.initState();
    unawaited(_begin());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final code = _code;
    return AlertDialog(
      title: const Text('Authorize Trakt'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Open Trakt, sign in, and enter this one-time code. TorBridge will detect approval automatically.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            SelectableText(
              code?.userCode ?? '—',
              key: const Key('trakt-device-code'),
              style: Theme.of(context).textTheme.displaySmall
                  ?.copyWith(fontWeight: FontWeight.w700, letterSpacing: 4),
            ),
            const SizedBox(height: 12),
            Text(_status, textAlign: TextAlign.center),
            if (code == null) ...[
              const SizedBox(height: 14),
              const CircularProgressIndicator(),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          key: const Key('open-trakt-activate'),
          onPressed: code == null
              ? null
              : () => launchUrl(
                  code.verificationUrl,
                  mode: LaunchMode.externalApplication,
                ),
          icon: const Icon(Icons.open_in_new),
          label: const Text('Open Trakt'),
        ),
      ],
    );
  }

  Future<void> _begin() async {
    try {
      final code = await ref
          .read(torBridgeControllerProvider.notifier)
          .requestTraktDeviceCode();
      if (!mounted) return;
      setState(() {
        _code = code;
        _status = 'Waiting for approval at ${code.verificationUrl.host}';
      });
      final interval = Duration(seconds: code.interval.clamp(5, 60));
      _timer = Timer.periodic(interval, (_) => unawaited(_poll()));
    } catch (error) {
      if (mounted) {
        setState(() => _status = 'Could not start authorization: $error');
      }
    }
  }

  Future<void> _poll() async {
    final code = _code;
    if (code == null || !mounted) return;
    try {
      final result = await ref
          .read(torBridgeControllerProvider.notifier)
          .pollTraktDeviceCode(code.deviceCode);
      if (!mounted) return;
      switch (result.status) {
        case TraktDeviceStatus.approved:
          _timer?.cancel();
          Navigator.pop(context);
          return;
        case TraktDeviceStatus.pending:
          setState(() => _status = 'Waiting for approval…');
          return;
        case TraktDeviceStatus.slowDown:
          setState(() => _status = 'Trakt asked us to wait a little longer…');
          return;
        case TraktDeviceStatus.expired:
          _timer?.cancel();
          setState(() => _status = 'This code expired. Close and try again.');
          return;
        case TraktDeviceStatus.denied:
          _timer?.cancel();
          setState(() => _status = 'Authorization was denied.');
          return;
        case TraktDeviceStatus.invalid:
          _timer?.cancel();
          setState(() => _status = 'This code is no longer valid.');
          return;
      }
    } catch (error) {
      if (mounted) {
        setState(() => _status = 'Authorization check failed: $error');
      }
    }
  }
}

class _ServiceStatus extends StatelessWidget {
  const _ServiceStatus({
    required this.icon,
    required this.name,
    required this.status,
    required this.connected,
  });

  final IconData icon;
  final String name;
  final String status;
  final bool connected;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        CircleAvatar(child: Icon(icon)),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(name, style: Theme.of(context).textTheme.titleSmall),
              Text(status, style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
        Icon(
          connected ? Icons.check_circle : Icons.circle_outlined,
          size: 20,
          color: connected
              ? const Color(0xFF75D6A4)
              : Theme.of(context).colorScheme.outline,
        ),
      ],
    );
  }
}
