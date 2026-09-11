import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/app_state.dart';
import '../../services/trakt_device_poller.dart';
import '../../domain/media_models.dart';
import '../../integrations/trakt_client.dart';
import '../../services/credential_store.dart';
import '../../services/setup_transfer_service.dart';
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
    const deviceTransferCard = _DeviceTransferCard();

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
                const Expanded(
                  flex: 4,
                  child: Column(
                    children: [
                      connectionCard,
                      SizedBox(height: 16),
                      deviceTransferCard,
                    ],
                  ),
                ),
              ],
            )
          else ...[
            preferenceCard,
            const SizedBox(height: 16),
            connectionCard,
            const SizedBox(height: 16),
            deviceTransferCard,
          ],
        ],
      ),
    );
  }
}

class _DeviceTransferCard extends ConsumerWidget {
  const _DeviceTransferCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(torBridgeControllerProvider);
    final isDesktop = defaultTargetPlatform == TargetPlatform.windows;
    final isAndroid = defaultTargetPlatform == TargetPlatform.android;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Transfer setup',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 6),
            Text(
              isDesktop
                  ? 'Copy connections and download rules to a phone with an encrypted QR transfer.'
                  : 'Copy setup to another phone, or scan a setup QR from a phone or desktop.',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            if (isDesktop || isAndroid)
              FilledButton.tonalIcon(
                key: const Key('show-setup-qr'),
                onPressed: () => showDialog<void>(
                  context: context,
                  barrierDismissible: false,
                  builder: (_) => _SetupQrDialog(
                    bundle: SetupTransferBundle(
                      connections: state.connections,
                      preferences: state.preferences,
                    ),
                  ),
                ),
                icon: const Icon(Icons.qr_code_2),
                label: const Text('Show setup QR'),
              ),
            if (isAndroid) ...[
              const SizedBox(height: 8),
              FilledButton.tonalIcon(
                key: const Key('scan-setup-qr'),
                onPressed: () => showDialog<void>(
                  context: context,
                  barrierDismissible: false,
                  builder: (_) => const _SetupScannerDialog(),
                ),
                icon: const Icon(Icons.qr_code_scanner),
                label: const Text('Scan setup QR'),
              ),
            ],
            if (!isDesktop && !isAndroid)
              const Text('QR import is available on Android.'),
            const SizedBox(height: 10),
            Text(
              'Single-use • expires after 5 minutes • same network required',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _SetupQrDialog extends ConsumerStatefulWidget {
  const _SetupQrDialog({required this.bundle});

  final SetupTransferBundle bundle;

  @override
  ConsumerState<_SetupQrDialog> createState() => _SetupQrDialogState();
}

class _SetupQrDialogState extends ConsumerState<_SetupQrDialog> {
  late final Future<SetupTransferOffer> _offer;
  late final SetupTransferService _transferService;

  @override
  void initState() {
    super.initState();
    _transferService = ref.read(setupTransferServiceProvider);
    _offer = _transferService.startOffer(widget.bundle);
  }

  @override
  void dispose() {
    unawaited(_transferService.stopOffer());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      scrollable: true,
      title: const Text('Scan with TorBridge Mobile'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: FutureBuilder<SetupTransferOffer>(
          future: _offer,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return Text(
                '${snapshot.error}',
                key: const Key('setup-qr-error'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              );
            }
            final offer = snapshot.data;
            if (offer == null) {
              return const SizedBox(
                height: 280,
                child: Center(child: CircularProgressIndicator()),
              );
            }
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: SizedBox.square(
                        dimension: 250,
                        child: QrImageView(
                          key: const Key('setup-qr-code'),
                          data: offer.uri.toString(),
                          backgroundColor: Colors.white,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'Verification code',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.labelLarge,
                ),
                Text(
                  offer.verificationCode,
                  key: const Key('setup-verification-code'),
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: 10),
                Text(
                  'Includes ${offer.includedItems.join(', ')}. Keep this screen open, both devices unlocked and on the same Wi-Fi. On the receiving phone, open Settings > Transfer setup > Scan setup QR.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  'Only scan with your receiving phone: this QR grants access to your setup. The encrypted transfer can be claimed once and expires after 5 minutes. Close and reopen to create a new QR.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                if (defaultTargetPlatform == TargetPlatform.windows) ...[
                  const SizedBox(height: 6),
                  Text(
                    'If Windows asks, allow TorBridge on Private networks only.',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ],
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

class _SetupScannerDialog extends ConsumerStatefulWidget {
  const _SetupScannerDialog();

  @override
  ConsumerState<_SetupScannerDialog> createState() =>
      _SetupScannerDialogState();
}

class _SetupScannerDialogState extends ConsumerState<_SetupScannerDialog> {
  final MobileScannerController _scanner = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
    detectionSpeed: DetectionSpeed.noDuplicates,
  );
  ReceivedSetupTransfer? _received;
  bool _processing = false;
  bool _importing = false;
  String? _error;

  @override
  void dispose() {
    unawaited(_scanner.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final received = _received;
    return AlertDialog(
      scrollable: true,
      title: Text(received == null ? 'Scan setup QR' : 'Confirm setup import'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: received == null
            ? _scannerContent(context)
            : _preview(context, received),
      ),
      actions: [
        TextButton(
          onPressed: _importing ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        if (received != null)
          FilledButton(
            key: const Key('confirm-setup-import'),
            onPressed: _importing ? null : _import,
            child: Text(_importing ? 'Importing…' : 'Import setup'),
          ),
      ],
    );
  }

  Widget _scannerContent(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: SizedBox(
            height: 320,
            child: MobileScanner(
              key: const Key('setup-qr-scanner'),
              controller: _scanner,
              onDetect: _onDetect,
            ),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          _processing ? 'Connecting securely to the sending device…' : 'Point the camera at the setup QR in TorBridge on the other phone or desktop.',
          textAlign: TextAlign.center,
        ),
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(
            _error!,
            key: const Key('setup-scan-error'),
            textAlign: TextAlign.center,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],
      ],
    );
  }

  Widget _preview(BuildContext context, ReceivedSetupTransfer received) {
    final bundle = received.bundle;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Icon(
          Icons.verified_user_outlined,
          size: 48,
          color: Theme.of(context).colorScheme.primary,
        ),
        const SizedBox(height: 8),
        Text(
          received.verificationCode,
          key: const Key('received-verification-code'),
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.headlineMedium,
        ),
        const SizedBox(height: 6),
        const Text(
          'Confirm this matches the code on the sending device.',
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 18),
        for (final item in bundle.includedItems)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.check_circle_outline),
            title: Text(item),
          ),
        const SizedBox(height: 6),
        Text(
          'Existing connections and download rules on this device will be replaced. Downloads and local files are not transferred.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],
      ],
    );
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_processing || _received != null) return;
    String? raw;
    for (final barcode in capture.barcodes) {
      if (barcode.rawValue != null) {
        raw = barcode.rawValue;
        break;
      }
    }
    if (raw == null) return;
    setState(() {
      _processing = true;
      _error = null;
    });
    await _scanner.stop();
    try {
      final received = await ref.read(setupTransferServiceProvider).redeem(raw);
      if (!mounted) return;
      setState(() {
        _received = received;
        _processing = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = '$error';
        _processing = false;
      });
      await _scanner.start();
    }
  }

  Future<void> _import() async {
    final received = _received;
    if (received == null) return;
    setState(() {
      _importing = true;
      _error = null;
    });
    final error = await ref
        .read(torBridgeControllerProvider.notifier)
        .importSetupTransfer(received.bundle);
    if (!mounted) return;
    if (error == null) {
      Navigator.pop(context);
    } else {
      setState(() {
        _importing = false;
        _error = error;
      });
    }
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
            const SizedBox(height: 8),
            DropdownButtonFormField<int>(
              key: const Key('watched-cleanup-delay'),
              isExpanded: true,
              initialValue: preferences.deleteWatchedAfterDays ?? -1,
              decoration: const InputDecoration(
                labelText: 'Remove watched downloads',
                prefixIcon: Icon(Icons.auto_delete_outlined),
                helperText: 'The delay starts when TorBridge learns the watched state from Trakt.',
              ),
              items: const [
                DropdownMenuItem(value: -1, child: Text('Never')),
                DropdownMenuItem(value: 0, child: Text('At next sync')),
                DropdownMenuItem(value: 1, child: Text('After 1 day')),
                DropdownMenuItem(value: 7, child: Text('After 7 days')),
                DropdownMenuItem(value: 30, child: Text('After 30 days')),
              ],
              onChanged: (value) => onChanged(
                preferences.copyWith(
                  deleteWatchedAfterDays: value == -1 ? null : value,
                ),
              ),
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
            const Divider(height: 26),
            _ServiceStatus(
              icon: Icons.ondemand_video_outlined,
              name: 'Stremio bridge',
              status: switch (state.bridgePhase) {
                BridgePhase.ready => 'Local addon ready',
                BridgePhase.starting => 'Starting local addon…',
                BridgePhase.error => 'Local addon needs attention',
                BridgePhase.stopped => 'Starts when connected or first used',
              },
              connected: state.bridgePhase == BridgePhase.ready,
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
            if (connections.hasTraktSession) ...[
              const SizedBox(height: 8),
              OutlinedButton.icon(
                key: const Key('sync-trakt-watched'),
                onPressed: () => unawaited(
                  ref
                      .read(torBridgeControllerProvider.notifier)
                      .syncTraktWatched(),
                ),
                icon: const Icon(Icons.sync),
                label: const Text('Refresh watched state'),
              ),
            ],
            const SizedBox(height: 8),
            OutlinedButton.icon(
              key: const Key('install-stremio-addon-settings'),
              onPressed: () => unawaited(
                ref
                    .read(torBridgeControllerProvider.notifier)
                    .installStremioAddon(),
              ),
              icon: const Icon(Icons.extension_outlined),
              label: const Text('Copy addon URL and open Stremio'),
            ),
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
  TraktDevicePoller? _poller;
  bool _requesting = true;
  String _status = 'Requesting a device code…';

  @override
  void initState() {
    super.initState();
    unawaited(_begin());
  }

  @override
  void dispose() {
    _poller?.stop();
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
            if (_requesting) ...[
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
        _requesting = false;
        _status = 'Waiting for approval at ${code.verificationUrl.host}';
      });
      _poller = TraktDevicePoller(
        code: code,
        poll: ref
            .read(torBridgeControllerProvider.notifier)
            .pollTraktDeviceCode,
        onResult: _onPollResult,
        onError: (error) {
          if (mounted) {
            setState(() => _status = 'Authorization check failed: $error');
          }
        },
      )..start();
    } catch (error) {
      if (mounted) {
        setState(() {
          _requesting = false;
          _status = 'Could not start authorization: $error';
        });
      }
    }
  }

  void _onPollResult(TraktDevicePollResult result) {
    if (!mounted) return;
    switch (result.status) {
      case TraktDeviceStatus.approved:
        _poller?.stop();
        Navigator.pop(context);
        return;
      case TraktDeviceStatus.pending:
        setState(() => _status = 'Waiting for approval…');
        return;
      case TraktDeviceStatus.slowDown:
        setState(() => _status = 'Trakt asked us to wait a little longer…');
        return;
      case TraktDeviceStatus.expired:
        _poller?.stop();
        setState(() => _status = 'This code expired. Close and try again.');
        return;
      case TraktDeviceStatus.denied:
        _poller?.stop();
        setState(() => _status = 'Authorization was denied.');
        return;
      case TraktDeviceStatus.invalid:
        _poller?.stop();
        setState(() => _status = 'This code is no longer valid.');
        return;
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
