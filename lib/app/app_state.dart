import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';

import '../data/demo_catalog.dart';
import '../domain/catalog_title.dart';
import '../domain/watched_entry.dart';
import '../domain/media_models.dart';
import '../domain/recommendation_engine.dart';
import '../integrations/aio_streams_client.dart';
import '../integrations/cinemeta_client.dart';
import '../integrations/torbox_client.dart';
import '../integrations/trakt_client.dart';
import '../services/credential_store.dart';
import '../services/download_service.dart';
import '../services/local_state_store.dart';
import '../services/setup_transfer_service.dart';
import '../services/stremio_bridge_service.dart';
import '../services/playback_launcher.dart';

enum DownloadStatus { queued, downloading, complete, failed, unavailable }

enum DiagnosticSeverity { success, warning, error, info }

class DiagnosticCheck {
  const DiagnosticCheck(this.detail, this.severity);
  final String detail;
  final DiagnosticSeverity severity;
}

enum ConnectionPhase { idle, checking, ready, error }

enum BridgePhase { stopped, starting, ready, error }

class BulkDownloadResult {
  const BulkDownloadResult({
    required this.queued,
    required this.alreadyAdded,
    required this.noEligibleSource,
  });

  final int queued;
  final int alreadyAdded;
  final int noEligibleSource;

  String get message {
    final parts = <String>[
      'Queued $queued ${queued == 1 ? 'episode' : 'episodes'}',
      if (alreadyAdded > 0) '$alreadyAdded already downloaded or queued',
      if (noEligibleSource > 0) '$noEligibleSource without an eligible source',
    ];
    return '${parts.join(' · ')}.';
  }
}

class DownloadJob {
  const DownloadJob({
    required this.id,
    required this.title,
    required this.mediaTitle,
    required this.source,
    required this.status,
    this.mediaVideo,
    this.progress = 0,
    this.localPath,
    this.platformId,
    this.error,
    this.createdAt,
    this.completedAt,
    this.watchedAt,
  });

  final String id;
  final String title;
  final CatalogTitle mediaTitle;
  final CatalogVideo? mediaVideo;
  final StreamCandidate source;
  final DownloadStatus status;
  final double progress;
  final String? localPath;
  final String? platformId;
  final String? error;
  final DateTime? createdAt;
  final DateTime? completedAt;
  final DateTime? watchedAt;

  bool get needsAttention =>
      status == DownloadStatus.failed || status == DownloadStatus.unavailable;

  String get videoId => mediaVideo?.id ?? mediaTitle.id;

  String get episodeLabel => mediaVideo?.code ?? 'Movie';

  List<String> get tags => [
    source.resolution?.label ?? 'Quality unknown',
    source.codec.label,
    if (source.hdr != HdrFormat.unknown) source.hdr.label,
    ...source.releaseTags.map(_displayTag),
  ];

  String get audioLabel => source.audioLanguages.isEmpty
      ? 'Audio unknown'
      : 'Audio: ${_sorted(source.audioLanguages)}';

  String get subtitleLabel => source.subtitleLanguages.isEmpty
      ? 'No subtitles listed'
      : 'Subs: ${_sorted(source.subtitleLanguages)}';

  DownloadJob copyWith({
    StreamCandidate? source,
    DownloadStatus? status,
    double? progress,
    Object? localPath = _unchanged,
    Object? platformId = _unchanged,
    Object? error = _unchanged,
    Object? completedAt = _unchanged,
    Object? watchedAt = _unchanged,
  }) {
    return DownloadJob(
      id: id,
      title: title,
      mediaTitle: mediaTitle,
      mediaVideo: mediaVideo,
      source: source ?? this.source,
      status: status ?? this.status,
      progress: progress ?? this.progress,
      localPath: identical(localPath, _unchanged)
          ? this.localPath
          : localPath as String?,
      platformId: identical(platformId, _unchanged)
          ? this.platformId
          : platformId as String?,
      error: identical(error, _unchanged) ? this.error : error as String?,
      createdAt: createdAt,
      completedAt: identical(completedAt, _unchanged)
          ? this.completedAt
          : completedAt as DateTime?,
      watchedAt: identical(watchedAt, _unchanged)
          ? this.watchedAt
          : watchedAt as DateTime?,
    );
  }

  static String _displayTag(String value) => switch (value) {
    'webdl' => 'WEB-DL',
    'webrip' => 'WEBRip',
    'bluray' => 'Blu-ray',
    'remux' => 'REMUX',
    _ => value.toUpperCase(),
  };

  static String _sorted(Set<String> values) {
    final sorted = values.toList()..sort();
    return sorted.join(', ');
  }
}

const Object _unchanged = Object();

class TorBridgeState {
  const TorBridgeState({
    this.navigationIndex = 0,
    this.selectedTitle = demoFeaturedTitle,
    this.selectedVideo,
    this.catalogTitles = demoTitles,
    this.sourceCandidates = const [],
    this.preferences = const DownloadPreferences(
      subtitleLanguageOrder: ['Dutch', 'English'],
    ),
    this.downloads = const [],
    this.watchedTitleIds = const {},
    this.watchedHistory = const {},
    this.connections = const StoredConnections(),
    this.demoMode = true,
    this.busy = false,
    this.connectionPhase = ConnectionPhase.idle,
    this.bridgePhase = BridgePhase.stopped,
    this.diagnosticChecks = const {},
    this.lastTraktSyncAt,
    this.stremioAvailable,
    this.notice,
  });

  final int navigationIndex;
  final CatalogTitle selectedTitle;
  final CatalogVideo? selectedVideo;
  final List<CatalogTitle> catalogTitles;
  final List<StreamCandidate> sourceCandidates;
  final DownloadPreferences preferences;
  final List<DownloadJob> downloads;
  final Set<String> watchedTitleIds;
  final Map<String, WatchedEntry> watchedHistory;
  final StoredConnections connections;
  final bool demoMode;
  final bool busy;
  final ConnectionPhase connectionPhase;
  final BridgePhase bridgePhase;
  final Map<String, DiagnosticCheck> diagnosticChecks;
  final DateTime? lastTraktSyncAt;
  final bool? stremioAvailable;
  final String? notice;

  String get selectedVideoId => selectedVideo?.id ?? selectedTitle.id;

  bool get selectedWatched => watchedTitleIds.contains(selectedVideoId);

  RecommendationResult get recommendation => const RecommendationEngine().rank(
    demoMode ? demoCandidates() : sourceCandidates,
    preferences,
  );

  TorBridgeState copyWith({
    int? navigationIndex,
    CatalogTitle? selectedTitle,
    Object? selectedVideo = _unchanged,
    List<CatalogTitle>? catalogTitles,
    List<StreamCandidate>? sourceCandidates,
    DownloadPreferences? preferences,
    List<DownloadJob>? downloads,
    Set<String>? watchedTitleIds,
    Map<String, WatchedEntry>? watchedHistory,
    StoredConnections? connections,
    bool? demoMode,
    bool? busy,
    ConnectionPhase? connectionPhase,
    BridgePhase? bridgePhase,
    Map<String, DiagnosticCheck>? diagnosticChecks,
    Object? lastTraktSyncAt = _unchanged,
    Object? stremioAvailable = _unchanged,
    String? notice,
    bool clearNotice = false,
  }) {
    return TorBridgeState(
      navigationIndex: navigationIndex ?? this.navigationIndex,
      selectedTitle: selectedTitle ?? this.selectedTitle,
      selectedVideo: identical(selectedVideo, _unchanged)
          ? this.selectedVideo
          : selectedVideo as CatalogVideo?,
      catalogTitles: catalogTitles ?? this.catalogTitles,
      sourceCandidates: sourceCandidates ?? this.sourceCandidates,
      preferences: preferences ?? this.preferences,
      downloads: downloads ?? this.downloads,
      watchedTitleIds: watchedTitleIds ?? this.watchedTitleIds,
      watchedHistory: watchedHistory ?? this.watchedHistory,
      connections: connections ?? this.connections,
      demoMode: demoMode ?? this.demoMode,
      busy: busy ?? this.busy,
      connectionPhase: connectionPhase ?? this.connectionPhase,
      bridgePhase: bridgePhase ?? this.bridgePhase,
      diagnosticChecks: diagnosticChecks ?? this.diagnosticChecks,
      lastTraktSyncAt: identical(lastTraktSyncAt, _unchanged)
          ? this.lastTraktSyncAt
          : lastTraktSyncAt as DateTime?,
      stremioAvailable: identical(stremioAvailable, _unchanged)
          ? this.stremioAvailable
          : stremioAvailable as bool?,
      notice: clearNotice ? null : notice ?? this.notice,
    );
  }
}

final downloadServiceProvider = Provider<DownloadService>(
  (ref) => Platform.isAndroid
      ? AndroidSystemDownloadService()
      : DioDownloadService(),
);

final stremioBridgeProvider = Provider<StremioBridgeService>(
  (ref) => Platform.isAndroid
      ? AndroidStremioBridgeService()
      : DartStremioBridgeService(),
);

final credentialStoreProvider = Provider<CredentialStore>(
  (ref) => PlatformCredentialStore(),
);

final cinemetaClientProvider = Provider<CinemetaClient>(
  (ref) => CinemetaClient(),
);

final aioStreamsClientProvider = Provider<AioStreamsClient>(
  (ref) => AioStreamsClient(),
);

final localStateStoreProvider = Provider<LocalStateStore>(
  (ref) => SharedPreferencesLocalStateStore(),
);

final setupTransferServiceProvider = Provider<SetupTransferService>((ref) {
  final service = SetupTransferService();
  ref.onDispose(() => unawaited(service.stopOffer()));
  return service;
});

final torBridgeControllerProvider =
    StateNotifierProvider<TorBridgeController, TorBridgeState>((ref) {
      final controller = TorBridgeController(
        ref.read(downloadServiceProvider),
        ref.read(stremioBridgeProvider),
        ref.read(credentialStoreProvider),
        ref.read(cinemetaClientProvider),
        ref.read(aioStreamsClientProvider),
        ref.read(localStateStoreProvider),
      );
      unawaited(controller.initialize());
      return controller;
    });

class TorBridgeController extends StateNotifier<TorBridgeState> {
  TorBridgeController(
    this._downloadService,
    this._stremioBridge,
    this._credentialStore,
    this._cinemetaClient,
    this._aioStreamsClient,
    this._localStateStore, [
    TorBoxClient Function(String token)? torBoxClientFactory,
    TraktClient Function(String clientId, String clientSecret)?
    traktClientFactory,
  ]) : _torBoxClientFactory = torBoxClientFactory ?? TorBoxClient.new,
       _traktClientFactory =
           traktClientFactory ??
           ((id, secret) => TraktClient(clientId: id, clientSecret: secret)),
       super(const TorBridgeState());

  final DownloadService _downloadService;
  final StremioBridgeService _stremioBridge;
  final CredentialStore _credentialStore;
  final CinemetaClient _cinemetaClient;
  final AioStreamsClient _aioStreamsClient;
  final LocalStateStore _localStateStore;
  final TorBoxClient Function(String token) _torBoxClientFactory;
  final TraktClient Function(String, String) _traktClientFactory;
  final Map<String, Future<void>> _pendingEnqueues = {};
  final Uuid _uuid = const Uuid();
  Timer? _maintenanceTimer;
  Future<void> _downloadSaveTail = Future<void>.value();
  Future<void> _torBoxProvisionTail = Future<void>.value();
  final Set<String> _retryingDownloadIds = {};
  final Set<String> _removingDownloadIds = {};
  final Set<String> _activeDownloads = {};
  final Map<String, (Future<void> Function(), Completer<void>)> _downloadQueue =
      {};
  final List<Map<String, dynamic>> _unreadDownloadRecords = [];
  bool _downloadsReadable = true;
  int _searchGeneration = 0;
  Future<void> _historySaveTail = Future<void>.value();
  Future<void> _traktHistoryTail = Future<void>.value();

  Future<void> initialize() async {
    _downloadsReadable = false;
    try {
      final local = await _localStateStore.read();
      _downloadsReadable = local.downloadsReadable;
      final jobs = _jobsFromRecords(local.downloadRecords);
      final history = <String, WatchedEntry>{};
      for (final record in local.historyRecords) {
        try {
          final entry = WatchedEntry(
            _titleFromJson(Map<String, dynamic>.from(record['title'] as Map)),
            video: record['video'] is Map
                ? _videoFromJson(
                    Map<String, dynamic>.from(record['video'] as Map),
                  )
                : null,
            localWatched: record['localWatched'] as bool?,
          );
          history[entry.id] = entry;
        } catch (_) {
          /* Legacy IDs remain visible through placeholders. */
        }
      }
      for (final job in jobs) {
        if (local.watchedTitleIds.contains(job.videoId)) {
          history.putIfAbsent(
            job.videoId,
            () => WatchedEntry(
              job.mediaTitle,
              video: job.mediaVideo,
              localWatched: true,
            ),
          );
        }
      }
      for (final id in local.watchedTitleIds) {
        history.putIfAbsent(id, () {
          final entry = WatchedEntry.placeholder(id);
          return WatchedEntry(
            entry.title,
            video: entry.video,
            localWatched: true,
          );
        });
      }
      final watched = {...local.watchedTitleIds};
      for (final entry in history.values) {
        if (entry.localWatched == true) watched.add(entry.id);
        if (entry.localWatched == false) watched.remove(entry.id);
      }
      state = state.copyWith(
        preferences: local.preferences,
        watchedTitleIds: watched,
        watchedHistory: history,
        notice: local.recoveryWarnings.isEmpty
            ? null
            : local.recoveryWarnings.join(" "),
        downloads: jobs,
      );
      await checkDownloadedFiles();
      if (state.downloads.any((job) => job.status == DownloadStatus.complete)) {
        await _ensureBridge();
      }
    } catch (error) {
      state = state.copyWith(
        notice: 'Local preferences could not be opened: $error',
      );
    }
    try {
      final connections = await _credentialStore.read();
      final live = connections.hasAioStreams && connections.hasTorBox;
      state = state.copyWith(
        connections: connections,
        demoMode: !live,
        connectionPhase: live ? ConnectionPhase.ready : ConnectionPhase.idle,
      );
      if (live) await _loadSources(state.selectedTitle, null);
      if (connections.hasTraktSession) {
        unawaited(syncTraktWatched(silent: true));
      }
    } catch (error) {
      state = state.copyWith(
        connectionPhase: ConnectionPhase.error,
        notice: 'Secure storage could not be opened: $error',
      );
    }
    // Recovery needs the saved credentials, not the initial empty connection state.
    _resumeInterruptedDownloads();
    _maintenanceTimer = Timer.periodic(const Duration(minutes: 30), (_) {
      if (state.connections.hasTraktSession) {
        unawaited(syncTraktWatched(silent: true));
      } else {
        unawaited(removeExpiredWatchedDownloads());
      }
    });
  }

  @override
  void dispose() {
    _maintenanceTimer?.cancel();
    for (final entry in _downloadQueue.values) {
      entry.$2.complete();
    }
    _downloadQueue.clear();
    super.dispose();
  }

  void navigate(int index) {
    state = state.copyWith(navigationIndex: index);
  }

  void selectTitle(CatalogTitle title) {
    state = state.copyWith(
      selectedTitle: title,
      selectedVideo: null,
      sourceCandidates: const [],
      clearNotice: true,
    );
    unawaited(_loadTitle(title));
  }

  Future<void> _loadTitle(CatalogTitle preview) async {
    if (!preview.isSeries) {
      if (!state.demoMode) await _loadSources(preview, null);
      return;
    }
    state = state.copyWith(busy: true);
    try {
      final details = preview.videos.isNotEmpty
          ? preview
          : await _cinemetaClient.getDetails(preview);
      if (!mounted || state.selectedTitle.id != preview.id) return;
      final video = _nextUnwatched(details.videos);
      state = state.copyWith(
        selectedTitle: details,
        selectedVideo: video,
        busy: false,
        notice: video == null
            ? 'No episodes are available for this series.'
            : null,
        clearNotice: video != null,
      );
      if (!state.demoMode && video != null) await _loadSources(details, video);
    } catch (error) {
      if (mounted) {
        state = state.copyWith(
          busy: false,
          notice: 'Episode metadata could not be loaded: $error',
        );
      }
    }
  }

  CatalogVideo? _nextUnwatched(List<CatalogVideo> videos) {
    for (final video in videos) {
      if (!state.watchedTitleIds.contains(video.id)) return video;
    }
    return videos.isEmpty ? null : videos.first;
  }

  void selectVideo(CatalogVideo video) {
    state = state.copyWith(
      selectedVideo: video,
      sourceCandidates: const [],
      clearNotice: true,
    );
    if (!state.demoMode) unawaited(_loadSources(state.selectedTitle, video));
  }

  Future<void> searchCatalog(String query) async {
    final generation = ++_searchGeneration;
    if (query.trim().isEmpty) {
      state = state.copyWith(
        catalogTitles: demoTitles,
        busy: false,
        clearNotice: true,
      );
      return;
    }
    state = state.copyWith(busy: true, clearNotice: true);
    try {
      final results = await _cinemetaClient.search(query);
      if (!mounted || generation != _searchGeneration) return;
      state = state.copyWith(
        busy: false,
        catalogTitles: results,
        notice: results.isEmpty ? 'No titles matched “${query.trim()}”.' : null,
        clearNotice: results.isNotEmpty,
      );
      if (results.isNotEmpty) selectTitle(results.first);
    } catch (error) {
      if (!mounted || generation != _searchGeneration) return;
      state = state.copyWith(
        busy: false,
        notice: 'Catalogue search failed: $error',
      );
    }
  }

  void useDemoMode(bool enabled) {
    state = state.copyWith(
      demoMode: enabled,
      catalogTitles: enabled ? demoTitles : state.catalogTitles,
      sourceCandidates: enabled ? const [] : state.sourceCandidates,
      clearNotice: true,
    );
    if (!enabled) {
      unawaited(_loadSources(state.selectedTitle, state.selectedVideo));
    }
  }

  void updatePreferences(DownloadPreferences preferences) {
    state = state.copyWith(preferences: preferences);
    unawaited(_localStateStore.savePreferences(preferences));
    unawaited(removeExpiredWatchedDownloads());
  }

  WatchedEntry _historyTarget(String videoId) {
    final job = state.downloads
        .where((job) => job.videoId == videoId)
        .firstOrNull;
    if (job != null) return WatchedEntry(job.mediaTitle, video: job.mediaVideo);
    if (videoId == state.selectedVideoId) {
      return WatchedEntry(state.selectedTitle, video: state.selectedVideo);
    }
    final saved = state.watchedHistory[videoId];
    if (saved != null) return saved;
    for (final title in [...state.catalogTitles, ...demoTitles]) {
      if (title.id == videoId) return WatchedEntry(title);
      final video = title.videos
          .where((item) => item.id == videoId)
          .firstOrNull;
      if (video != null) return WatchedEntry(title, video: video);
    }
    return WatchedEntry.placeholder(videoId);
  }

  Future<void> _setLocalWatched(WatchedEntry entry, bool adding) {
    final watched = {...state.watchedTitleIds};
    adding ? watched.add(entry.id) : watched.remove(entry.id);
    state = state.copyWith(
      watchedTitleIds: watched,
      watchedHistory: {
        ...state.watchedHistory,
        entry.id: WatchedEntry(
          entry.title,
          video: entry.video,
          localWatched: adding,
        ),
      },
      downloads: _downloadsWithWatchedState(watched),
    );
    return _saveHistory();
  }

  Future<void> _saveHistory() {
    final watched = {...state.watchedTitleIds};
    final records = [
      for (final entry in state.watchedHistory.values)
        {
          'title': _titleToJson(entry.title),
          if (entry.video != null) 'video': _videoToJson(entry.video!),
          'localWatched': entry.localWatched,
        },
    ];
    final operation = _historySaveTail
        .then((_) async {
          await _localStateStore.saveHistory(records);
          await _localStateStore.saveWatched(watched);
          await _saveDownloads();
        })
        .catchError((Object error) {
          if (mounted) {
            state = state.copyWith(
              notice: 'Could not save viewing history: $error',
            );
          }
        });
    return _historySaveTail = operation;
  }

  void toggleWatched(String videoId) {
    final entry = _historyTarget(videoId);
    final adding = !state.watchedTitleIds.contains(videoId);
    unawaited(_setLocalWatched(entry, adding));
    _traktHistoryTail = _traktHistoryTail.then(
      (_) => _syncWatchedEntry(entry, adding),
    );
    unawaited(removeExpiredWatchedDownloads());
  }

  Future<void> scrobble({
    required CatalogTitle title,
    CatalogVideo? video,
    required TraktScrobbleAction action,
    required double progress,
  }) async {
    if (action == TraktScrobbleAction.stop && progress >= 80) {
      await _setLocalWatched(WatchedEntry(title, video: video), true);
      await removeExpiredWatchedDownloads();
    }
    if (!mounted ||
        !state.connections.hasTraktSession ||
        !title.id.startsWith('tt')) {
      return;
    }
    try {
      await _withTraktSession(
        (client, token) => client.scrobble(
          accessToken: token,
          media: _traktMedia(title, video),
          action: action,
          progress: progress,
        ),
      );
    } catch (error) {
      if (mounted) {
        state = state.copyWith(notice: 'Trakt scrobble failed: $error');
      }
    }
  }

  Future<String?> saveConnections({
    required String aioManifestUrl,
    required String torBoxToken,
    required String traktClientId,
    required String traktClientSecret,
  }) async {
    state = state.copyWith(
      connectionPhase: ConnectionPhase.checking,
      clearNotice: true,
    );
    try {
      final aioText = aioManifestUrl.trim();
      final torText = torBoxToken.trim();
      if (aioText.isNotEmpty) {
        await _aioStreamsClient.getManifest(Uri.parse(aioText));
      }
      if (torText.isNotEmpty) {
        await _torBoxClientFactory(torText).validateToken();
      }
      await _credentialStore.save(
        aioManifestUrl: aioText,
        torBoxToken: torText,
        traktClientId: traktClientId,
        traktClientSecret: traktClientSecret,
      );
      final connections = await _credentialStore.read();
      final live = connections.hasAioStreams && connections.hasTorBox;
      state = state.copyWith(
        connections: connections,
        demoMode: !live,
        connectionPhase: live ? ConnectionPhase.ready : ConnectionPhase.idle,
        notice: live ? 'AIOStreams and TorBox are connected.' : null,
        clearNotice: !live,
      );
      if (live) await _loadSources(state.selectedTitle, state.selectedVideo);
      return null;
    } catch (error) {
      final message = 'Connection check failed: $error';
      state = state.copyWith(
        connectionPhase: ConnectionPhase.error,
        notice: message,
      );
      return message;
    }
  }

  Future<void> clearConnections() async {
    await _credentialStore.clear();
    state = state.copyWith(
      connections: const StoredConnections(),
      demoMode: true,
      sourceCandidates: const [],
      catalogTitles: demoTitles,
      connectionPhase: ConnectionPhase.idle,
      clearNotice: true,
    );
  }

  Future<String?> importSetupTransfer(SetupTransferBundle bundle) async {
    state = state.copyWith(
      connectionPhase: ConnectionPhase.checking,
      clearNotice: true,
    );
    try {
      await _credentialStore.saveAll(bundle.connections);
      await _localStateStore.savePreferences(bundle.preferences);
      final connections = await _credentialStore.read();
      final live = connections.hasAioStreams && connections.hasTorBox;
      state = state.copyWith(
        connections: connections,
        preferences: bundle.preferences,
        demoMode: !live,
        connectionPhase: live ? ConnectionPhase.ready : ConnectionPhase.idle,
        notice: 'Desktop setup imported securely.',
      );
      if (live) {
        unawaited(_loadSources(state.selectedTitle, state.selectedVideo));
      }
      if (connections.hasTraktSession) {
        unawaited(syncTraktWatched(silent: true));
      }
      return null;
    } catch (error) {
      final message = 'Setup import failed: $error';
      state = state.copyWith(
        connectionPhase: ConnectionPhase.error,
        notice: message,
      );
      return message;
    }
  }

  Future<TraktDeviceCode> requestTraktDeviceCode() async {
    final connections = state.connections;
    if (!connections.hasTraktApp) {
      throw StateError('Add a Trakt client ID and secret first.');
    }
    return _traktClientFactory(
      connections.traktClientId!,
      connections.traktClientSecret!,
    ).requestDeviceCode();
  }

  Future<TraktDevicePollResult> pollTraktDeviceCode(String deviceCode) async {
    final connections = state.connections;
    if (!connections.hasTraktApp) {
      return const TraktDevicePollResult(TraktDeviceStatus.invalid);
    }
    final client = _traktClientFactory(
      connections.traktClientId!,
      connections.traktClientSecret!,
    );
    final result = await client.pollDeviceToken(deviceCode);
    final tokens = result.tokens;
    if (result.status == TraktDeviceStatus.approved && tokens != null) {
      await _credentialStore.saveTraktTokens(
        accessToken: tokens.accessToken,
        refreshToken: tokens.refreshToken,
      );
      state = state.copyWith(
        connections: await _credentialStore.read(),
        notice: 'Trakt is connected.',
      );
      unawaited(syncTraktWatched());
    }
    return result;
  }

  Future<void> downloadRecommended() async {
    final best = state.recommendation.best;
    if (best != null) await downloadCandidate(best.candidate);
  }

  Future<void> downloadCandidate(StreamCandidate source) async {
    if (!_downloadsReadable) {
      state = state.copyWith(
        notice: 'Cannot add downloads while saved records are unreadable. The original records remain protected.',
      );
      return;
    }
    final videoId = state.selectedVideoId;
    final existing = state.downloads.where(
      (item) =>
          item.videoId == videoId &&
          item.source.id == source.id &&
          !item.needsAttention,
    );
    if (existing.isNotEmpty) {
      navigate(1);
      return;
    }
    final video = state.selectedVideo;
    final job = DownloadJob(
      id: _uuid.v4(),
      title: video == null
          ? state.selectedTitle.name
          : '${state.selectedTitle.name} ${video.code} · ${video.title}',
      mediaTitle: state.selectedTitle,
      mediaVideo: video,
      source: source,
      status: DownloadStatus.queued,
      createdAt: DateTime.now().toUtc(),
      watchedAt: state.watchedTitleIds.contains(videoId)
          ? DateTime.now().toUtc()
          : null,
    );
    state = state.copyWith(
      downloads: [job, ...state.downloads],
      navigationIndex: 1,
    );
    await _saveDownloads();
    await _runDownload(job);
  }

  Future<BulkDownloadResult> downloadEpisodes(
    CatalogTitle title,
    Iterable<CatalogVideo> selectedEpisodes,
  ) async {
    if (!_downloadsReadable) {
      state = state.copyWith(
        notice: 'Cannot add downloads while saved records are unreadable. The original records remain protected.',
      );
      return const BulkDownloadResult(
        queued: 0,
        alreadyAdded: 0,
        noEligibleSource: 0,
      );
    }
    final requested =
        <String, CatalogVideo>{
          for (final video in selectedEpisodes)
            if (video.season > 0 &&
                title.videos.any((item) => item.id == video.id))
              video.id: video,
        }.values.toList()..sort((a, b) {
          final season = a.season.compareTo(b.season);
          return season != 0 ? season : a.episode.compareTo(b.episode);
        });
    if (requested.isEmpty) {
      return const BulkDownloadResult(
        queued: 0,
        alreadyAdded: 0,
        noEligibleSource: 0,
      );
    }

    var alreadyAdded = 0;
    var noEligibleSource = 0;
    final jobs = <DownloadJob>[];
    state = state.copyWith(
      busy: true,
      notice: 'Finding the best sources for ${requested.length} episodes…',
    );
    for (final video in requested) {
      final exists = state.downloads.any(
        (job) => job.videoId == video.id && !job.needsAttention,
      );
      if (exists) {
        alreadyAdded++;
        continue;
      }
      final candidates = await _fetchSources(title, video);
      final best = const RecommendationEngine()
          .rank(candidates, state.preferences)
          .best;
      if (best == null) {
        noEligibleSource++;
        continue;
      }
      jobs.add(_newDownloadJob(title, video, best.candidate));
    }

    if (!mounted) {
      return BulkDownloadResult(
        queued: jobs.length,
        alreadyAdded: alreadyAdded,
        noEligibleSource: noEligibleSource,
      );
    }
    final result = BulkDownloadResult(
      queued: jobs.length,
      alreadyAdded: alreadyAdded,
      noEligibleSource: noEligibleSource,
    );
    state = state.copyWith(
      downloads: [...jobs.reversed, ...state.downloads],
      busy: false,
      notice: result.message,
    );
    if (jobs.isNotEmpty) {
      await _saveDownloads();
      for (final job in jobs) {
        unawaited(_runDownload(job, refreshSource: true));
      }
    }
    return result;
  }

  DownloadJob _newDownloadJob(
    CatalogTitle title,
    CatalogVideo video,
    StreamCandidate source,
  ) {
    return DownloadJob(
      id: _uuid.v4(),
      title: '${title.name} ${video.code} · ${video.title}',
      mediaTitle: title,
      mediaVideo: video,
      source: source,
      status: DownloadStatus.queued,
      createdAt: DateTime.now().toUtc(),
      watchedAt: state.watchedTitleIds.contains(video.id)
          ? DateTime.now().toUtc()
          : null,
    );
  }

  Future<void> _runDownload(
    DownloadJob original, {
    bool refreshSource = false,
  }) {
    final existing = _downloadQueue[original.id];
    if (existing != null) return existing.$2.future;
    if (_activeDownloads.contains(original.id)) return Future<void>.value();
    final completion = Completer<void>();
    final waited =
        _activeDownloads.length >= _downloadService.maxConcurrentDownloads;
    _downloadQueue[original.id] = (
      () =>
          _runDownloadNow(original.id, refreshSource: refreshSource || waited),
      completion,
    );
    if (waited) {
      _replaceJob(
        original.copyWith(
          error: 'Queued — waiting for the current download. Reopen TorBridge if Android closes it.',
        ),
      );
    }
    _pumpDownloadQueue();
    return completion.future;
  }

  void _pumpDownloadQueue() {
    if (!mounted) return;
    while (_downloadQueue.isNotEmpty &&
        _activeDownloads.length < _downloadService.maxConcurrentDownloads) {
      final id = _downloadQueue.keys.first;
      final entry = _downloadQueue.remove(id)!;
      _activeDownloads.add(id);
      unawaited(_executeDownload(id, entry.$1, entry.$2));
    }
  }

  Future<void> _executeDownload(
    String id,
    Future<void> Function() operation,
    Completer<void> completion,
  ) async {
    try {
      await operation();
    } finally {
      _activeDownloads.remove(id);
      completion.complete();
      _pumpDownloadQueue();
    }
  }

  Future<void> _runDownloadNow(
    String id, {
    required bool refreshSource,
    DownloadFailureException? recoveryError,
  }) async {
    if (!mounted || _removingDownloadIds.contains(id)) return;
    final original = state.downloads.where((job) => job.id == id).firstOrNull;
    if (original == null || original.status != DownloadStatus.queued) return;
    var job = original.copyWith(
      status: DownloadStatus.downloading,
      error: null,
      progress: 0,
    );
    _replaceJob(job);
    try {
      if (refreshSource) {
        job = job.copyWith(source: await _refreshSource(job) ?? job.source);
        _replaceJob(job);
      }
      String localPath;
      try {
        if (recoveryError != null) throw recoveryError;
        final url = await _downloadUrl(job).timeout(
          const Duration(seconds: 60),
          onTimeout: () => throw StateError(
            'Getting the download link timed out. Retry the download.',
          ),
        );
        localPath = await _downloadFromUrl(
          job,
          url,
          (updated) => job = updated,
        );
      } on DownloadFailureException catch (error) {
        localPath = await _recoverRetryableDownload(
          job,
          error,
          (updated) => job = updated,
        );
      }
      _replaceJob(
        job.copyWith(
          status: DownloadStatus.complete,
          progress: 1,
          localPath: localPath,
          completedAt: DateTime.now().toUtc(),
          error: _downloadService.localFileWarning(localPath),
        ),
      );
      await _ensureBridge();
      await removeExpiredWatchedDownloads();
    } catch (error) {
      _replaceJob(
        job.copyWith(
          status: DownloadStatus.failed,
          error: _errorMessage(error, job.source),
        ),
      );
    }
  }

  String _errorMessage(Object error, StreamCandidate source) {
    final message = error is DownloadFailureException
        ? error.description
        : error.toString().replaceFirst(
            RegExp(r'^(Bad state|Exception):\s*'),
            '',
          );
    final origin = error is DownloadFailureException
        ? error.host ?? source.streamUrl?.host
        : source.streamUrl?.host;
    if (error is DownloadStorageException ||
        error is DownloadFailureException && error.reason >= 1000) {
      return message;
    }
    return origin == null || origin.isEmpty ? message : '$message from $origin';
  }

  Future<String> _downloadFromUrl(
    DownloadJob job,
    Uri url,
    void Function(DownloadJob updated) onJobChanged, {
    Map<String, String>? requestHeaders,
  }) async {
    await _downloadService.checkAvailableSpace(job.source.sizeBytes);
    if (!mounted ||
        _removingDownloadIds.contains(job.id) ||
        !state.downloads.any((item) => item.id == job.id)) {
      throw StateError('Download cancelled.');
    }
    var current = job;
    final enqueued = Completer<void>();
    _pendingEnqueues[job.id] = enqueued.future;
    try {
      return await _downloadService.download(
        jobId: job.id,
        url: url,
        suggestedName: _downloadFilename(job),
        requestHeaders:
            requestHeaders ??
            (job.source.streamUrl == null
                ? const {}
                : job.source.requestHeaders),
        onEnqueued: (platformId) {
          if (!mounted || !state.downloads.any((item) => item.id == job.id)) {
            unawaited(
              _downloadService.cancel(jobId: job.id, platformId: platformId),
            );
            return;
          }
          current = current.copyWith(platformId: platformId);
          onJobChanged(current);
          _replaceJob(current);
          if (!enqueued.isCompleted) enqueued.complete();
        },
        onProgress: (received, total) {
          final progress = total > 0 ? received / total : 0.0;
          current = current.copyWith(
            progress: progress.clamp(0, 1),
            error: _downloadService.downloadStatus(job.id),
          );
          onJobChanged(current);
          _replaceJob(current, persist: false);
        },
      );
    } finally {
      if (!enqueued.isCompleted) enqueued.complete();
      if (identical(_pendingEnqueues[job.id], enqueued.future)) {
        _pendingEnqueues.remove(job.id);
      }
    }
  }

  Future<String> _recoverRetryableDownload(
    DownloadJob job,
    DownloadFailureException originalError,
    void Function(DownloadJob updated) onJobChanged,
  ) async {
    if (!originalError.isRetryableSourceFailure) throw originalError;
    if (!mounted ||
        _removingDownloadIds.contains(job.id) ||
        !state.downloads.any((item) => item.id == job.id)) {
      throw StateError('Download cancelled.');
    }
    var current = job;
    await _downloadService.cancel(
      jobId: current.id,
      platformId: current.platformId,
    );
    current = current.copyWith(platformId: null, progress: 0);
    onJobChanged(current);
    _replaceJob(current);

    var latestError = originalError;
    final candidates = await _fetchSourcesForJob(current);
    final refreshed = _matchingSource(current.source, candidates);
    if (refreshed?.streamUrl != null) {
      current = current.copyWith(source: refreshed);
      onJobChanged(current);
      _replaceJob(current);
      try {
        return await _downloadFromUrl(current, refreshed!.streamUrl!, (
          updated,
        ) {
          current = updated;
          onJobChanged(updated);
        });
      } on DownloadFailureException catch (error) {
        if (!error.isRetryableSourceFailure) rethrow;
        latestError = error;
        await _downloadService.cancel(
          jobId: current.id,
          platformId: current.platformId,
        );
        current = current.copyWith(platformId: null, progress: 0);
        onJobChanged(current);
        _replaceJob(current);
      } on DownloadStorageException {
        rethrow;
      } catch (error) {
        throw StateError(
          '${originalError.description}; refreshed source also failed: $error',
        );
      }
    }

    final migratedUrl = _migratedTorrentioUrl(refreshed?.streamUrl);
    if (migratedUrl != null) {
      try {
        return await _downloadFromUrl(current, migratedUrl, (updated) {
          current = updated;
          onJobChanged(updated);
        });
      } on DownloadFailureException catch (error) {
        if (!error.isRetryableSourceFailure) rethrow;
        latestError = error;
        await _downloadService.cancel(
          jobId: current.id,
          platformId: current.platformId,
        );
        current = current.copyWith(platformId: null, progress: 0);
        onJobChanged(current);
        _replaceJob(current);
      }
    }

    var recoverySource = refreshed ?? current.source;
    final alternative = _bestAlternative(candidates, recoverySource);
    if (alternative != null) {
      current = current.copyWith(source: alternative);
      onJobChanged(current);
      _replaceJob(current);
      try {
        final alternativeUrl = await _downloadUrl(
          current.copyWith(source: alternative),
        ).timeout(const Duration(seconds: 60));
        return await _downloadFromUrl(current, alternativeUrl, (updated) {
          current = updated;
          onJobChanged(updated);
        });
      } on DownloadFailureException catch (error) {
        if (!error.isRetryableSourceFailure) rethrow;
        latestError = error;
        recoverySource = alternative;
        await _downloadService.cancel(
          jobId: current.id,
          platformId: current.platformId,
        );
        current = current.copyWith(platformId: null, progress: 0);
        onJobChanged(current);
        _replaceJob(current);
      }
    }

    if (!_canRetryThroughTorBox(latestError)) {
      throw latestError;
    }
    try {
      recoverySource =
          _bestTorBoxRecoverySource(candidates, recoverySource) ??
          recoverySource;
      current = current.copyWith(source: recoverySource);
      onJobChanged(current);
      _replaceJob(current);
      final fallbackUrl = await _directTorBoxDownloadUrl(current)
          .timeout(const Duration(seconds: 60));
      return await _downloadFromUrl(current, fallbackUrl, (updated) {
        current = updated;
        onJobChanged(updated);
      }, requestHeaders: const {});
    } on DownloadFailureException {
      rethrow;
    } on DownloadStorageException {
      rethrow;
    } catch (fallbackError) {
      throw StateError(
        '${latestError.description}; TorBox fallback also failed: $fallbackError',
      );
    }
  }

  bool _canRetryThroughTorBox(DownloadFailureException error) {
    final token = state.connections.torBoxToken;
    return error.isRetryableSourceFailure && token != null && token.isNotEmpty;
  }

  Future<void> retryDownload(DownloadJob job) async {
    if (!_retryingDownloadIds.add(job.id)) return;
    try {
      final current = state.downloads
          .where((item) => item.id == job.id)
          .firstOrNull;
      if (current == null || !current.needsAttention) return;
      // Storage may have become available again since the last check.
      if (current.status == DownloadStatus.unavailable &&
          await localPlaybackSource(current) != null) {
        return;
      }
      _replaceJob(current.copyWith(status: DownloadStatus.queued, error: null));
      // Retire the previous Android job before losing its ID. A retry starts
      // from zero, including when Android cannot resume a partial transfer.
      if (current.platformId != null) {
        await _downloadService.cancel(
          jobId: current.id,
          platformId: current.platformId,
        );
      }
      if (!mounted ||
          _removingDownloadIds.contains(job.id) ||
          !state.downloads.any((item) => item.id == job.id)) {
        return;
      }
      final refreshed = await _refreshSource(current);
      final latest = state.downloads
          .where((item) => item.id == job.id)
          .firstOrNull;
      // A cancellation while sources were being refreshed must stay cancelled.
      if (latest == null || latest.status != DownloadStatus.queued) return;
      final replacement = latest.copyWith(
        source: refreshed ?? latest.source,
        progress: 0,
        localPath: null,
        platformId: null,
        completedAt: null,
        error: null,
      );
      _replaceJob(replacement);
      await _runDownload(replacement);
    } catch (error) {
      final current = state.downloads
          .where((item) => item.id == job.id)
          .firstOrNull;
      if (current != null && current.status == DownloadStatus.queued) {
        _replaceJob(
          current.copyWith(
            status: DownloadStatus.failed,
            error: _errorMessage(error, current.source),
          ),
        );
      }
    } finally {
      _retryingDownloadIds.remove(job.id);
    }
  }

  Future<void> cancelDownload(DownloadJob job) =>
      _removeDownload(job, deleteFile: false);

  Future<void> deleteDownload(DownloadJob job, {bool automatic = false}) =>
      _removeDownload(job, deleteFile: true, automatic: automatic);

  Future<void> _removeDownload(
    DownloadJob snapshot, {
    required bool deleteFile,
    bool automatic = false,
  }) async {
    if (!_removingDownloadIds.add(snapshot.id)) return;
    final job = state.downloads
        .where((item) => item.id == snapshot.id)
        .firstOrNull;
    if (job == null) {
      _removingDownloadIds.remove(snapshot.id);
      return;
    }
    try {
      await _downloadService.cancel(jobId: job.id, platformId: job.platformId);
      await _pendingEnqueues[job.id]?.timeout(const Duration(seconds: 30));
      final latest =
          state.downloads.where((item) => item.id == job.id).firstOrNull ?? job;
      if (latest.platformId != job.platformId && latest.platformId != null) {
        await _downloadService.cancel(
          jobId: latest.id,
          platformId: latest.platformId,
        );
      }
      final path = latest.localPath;
      if (deleteFile && path != null && path.isNotEmpty) {
        await _downloadService.delete(path);
      }
      if (!mounted) return;
      state = state.copyWith(
        downloads: state.downloads.where((item) => item.id != job.id).toList(),
        notice: deleteFile
            ? (automatic
                  ? 'Removed watched download: ${job.title}'
                  : 'Deleted ${job.title}.')
            : null,
      );
      _downloadQueue.remove(job.id)?.$2.complete();
      await _saveDownloads();
      await _updateBridge();
    } catch (error) {
      if (mounted) {
        state = state.copyWith(
          notice:
              'Could not ${deleteFile ? "delete" : "cancel"} ${job.title}: $error',
        );
      }
    } finally {
      _removingDownloadIds.remove(snapshot.id);
    }
  }

  void prepareAnotherVersion(DownloadJob job) {
    state = state.copyWith(
      navigationIndex: 0,
      selectedTitle: job.mediaTitle,
      selectedVideo: job.mediaVideo,
      sourceCandidates: const [],
      notice: 'Adjust quality rules or choose another suitable source.',
    );
    if (!state.demoMode) {
      unawaited(_loadSources(job.mediaTitle, job.mediaVideo));
    }
  }

  Future<void> installStremioAddon() async {
    await _ensureBridge();
    final manifestUrl = _stremioBridge.manifestUrl;
    await Clipboard.setData(ClipboardData(text: manifestUrl.toString()));
    final installUrl = manifestUrl.replace(scheme: 'stremio');
    final opened = await launchUrl(
      installUrl,
      mode: LaunchMode.externalApplication,
    );
    state = state.copyWith(
      stremioAvailable: opened,
      notice: opened
          ? 'Stremio opened. Confirm installation of “TorBridge Offline”.'
          : 'Could not open Stremio. The addon URL was copied for manual installation.',
    );
  }

  Future<void> openInStremio(DownloadJob job) async {
    try {
      final media = await _localPlaybackUrl(job);
      final opened = await launchUrl(
        stremioPlaybackUri(media, job.title),
        mode: LaunchMode.externalApplication,
      );
      if (!mounted) return;
      state = state.copyWith(
        stremioAvailable: opened,
        notice: opened
            ? 'Local video sent to Stremio. Direct playback may not sync title history.'
            : 'Stremio could not be opened. Use Play in TorBridge or an external player.',
      );
    } catch (_) {
      if (mounted) {
        state = state.copyWith(
          notice: 'Local playback could not start. Check Diagnostics; unavailable files can be retried from Downloads → Needs attention.',
        );
      }
    }
  }

  Future<Uri> _localPlaybackUrl(DownloadJob job) async {
    final path = await localPlaybackSource(job);
    if (path == null) throw StateError('Downloaded file is unavailable.');
    await _ensureBridge();
    if (!await _stremioBridge.ping()) {
      throw StateError('Local bridge is unavailable.');
    }
    return Uri.parse(
      'http://127.0.0.1:$stremioBridgePort/media/${Uri.encodeComponent(job.id)}',
    );
  }

  Future<void> openInExternalPlayer(DownloadJob job) async {
    try {
      final source = Platform.isAndroid
          ? (await _localPlaybackUrl(job)).toString()
          : await localPlaybackSource(job);
      if (source == null) throw StateError('Downloaded file is missing.');
      final opened = await PlaybackLauncher().openExternal(
        source,
        title: job.title,
      );
      if (mounted) {
        state = state.copyWith(
          notice: opened
              ? 'Choose a video player. External playback does not sync watched progress.'
              : 'No video player could be opened. Install a player such as VLC.',
        );
      }
    } catch (_) {
      if (mounted) {
        state = state.copyWith(
          notice: 'Could not open the local video. Check Diagnostics; unavailable files can be retried from Downloads → Needs attention.',
        );
      }
    }
  }

  Future<void> syncTraktWatched({bool silent = false}) async {
    if (!state.connections.hasTraktSession) return;
    try {
      final remote = await _withTraktSession(
        (client, accessToken) => client.watchedHistory(accessToken),
      );
      if (!mounted || remote == null) return;
      final history = {...state.watchedHistory, ...remote};
      for (final entry in state.watchedHistory.values) {
        if (entry.localWatched != null) history[entry.id] = entry;
      }
      final watched = <String>{
        ...remote.keys.where((id) => history[id]?.localWatched != false),
        for (final entry in history.values)
          if (entry.localWatched == true) entry.id,
      };
      state = state.copyWith(
        watchedTitleIds: watched,
        downloads: _downloadsWithWatchedState(watched),
        watchedHistory: history,
        lastTraktSyncAt: DateTime.now().toUtc(),
        notice: silent ? null : 'Watched state refreshed from Trakt.',
        clearNotice: silent,
      );
      await _saveHistory();
      await removeExpiredWatchedDownloads();
    } catch (error) {
      if (mounted && !silent) {
        state = state.copyWith(
          notice: 'Trakt watched-state refresh failed: $error',
        );
      }
    }
  }

  Future<void> removeExpiredWatchedDownloads() async {
    final days = state.preferences.deleteWatchedAfterDays;
    if (days == null) return;
    final cutoff = DateTime.now().toUtc().subtract(Duration(days: days));
    final expired = state.downloads
        .where(
          (job) =>
              job.status == DownloadStatus.complete &&
              job.watchedAt != null &&
              !job.watchedAt!.isAfter(cutoff),
        )
        .toList(growable: false);
    for (final job in expired) {
      await deleteDownload(job, automatic: true);
    }
  }

  /// Reconcile and retain saved files without discarding videos or downloading.
  Future<void> checkDownloadedFiles() async {
    for (final job in List<DownloadJob>.of(state.downloads)) {
      if (job.status == DownloadStatus.complete ||
          job.status == DownloadStatus.unavailable) {
        await localPlaybackSource(job, showNotice: false);
      }
    }
  }

  Future<String?> localPlaybackSource(
    DownloadJob job, {
    bool showNotice = true,
  }) async {
    if (job.status != DownloadStatus.complete &&
        job.status != DownloadStatus.unavailable) {
      return null;
    }
    String? path;
    try {
      path = await _downloadService.resolveLocalPath(
        localPath: job.localPath,
        platformId: job.platformId,
      );
    } catch (_) {
      // A platform/storage failure must not discard the original record.
    }
    if (!mounted) return null;
    // Do not overwrite a retry, deletion, or watched update while checking I/O.
    final current = state.downloads
        .where((item) => item.id == job.id)
        .firstOrNull;
    if (!identical(current, job)) return null;
    const unavailableMessage =
        'The video file is missing or cannot be read. Retry the download while online.';
    final status = path == null
        ? DownloadStatus.unavailable
        : DownloadStatus.complete;
    final error = path == null
        ? unavailableMessage
        : _downloadService.localFileWarning(path);
    if (job.status != status ||
        (path != null && path != job.localPath) ||
        job.error != error) {
      _replaceJob(
        job.copyWith(
          status: status,
          localPath: path ?? job.localPath,
          error: error,
        ),
        persist: false,
      );
      await _saveDownloads();
    }
    if (path == null && showNotice && mounted) {
      state = state.copyWith(notice: unavailableMessage);
    }
    return path;
  }

  Future<void> runDiagnostics() async {
    final checks = <String, DiagnosticCheck>{};
    await checkDownloadedFiles();
    try {
      final available = await _downloadService.availableBytes();
      if (available != null) {
        final queued = state.downloads.where(
          (job) => job.status == DownloadStatus.queued,
        );
        final estimated = queued.fold<int>(
          0,
          (total, job) => total + (job.source.sizeBytes ?? 0),
        );
        checks['Download storage'] = DiagnosticCheck(
          '${(available / 1e9).toStringAsFixed(1)} GB available in download storage; '
          '${(estimated / 1e9).toStringAsFixed(1)} GB estimated for ${queued.length} queued files. '
          'Sizes can be unknown or approximate. Space is checked again before each transfer.',
          estimated > available
              ? DiagnosticSeverity.warning
              : DiagnosticSeverity.info,
        );
      }
    } catch (_) {
      checks['Download storage'] = const DiagnosticCheck(
        'Could not check free download storage. Try again.',
        DiagnosticSeverity.warning,
      );
    }
    try {
      await _ensureBridge();
      final responding = await _stremioBridge.ping();
      checks['Local Stremio addon'] = DiagnosticCheck(
        responding
            ? 'Ready on ${_stremioBridge.manifestUrl}'
            : 'Not responding on localhost',
        responding ? DiagnosticSeverity.success : DiagnosticSeverity.error,
      );
    } catch (error) {
      checks['Local Stremio addon'] = DiagnosticCheck(
        'Failed: $error',
        DiagnosticSeverity.error,
      );
    }
    final complete = state.downloads.where(
      (job) =>
          job.status == DownloadStatus.complete ||
          job.status == DownloadStatus.unavailable,
    );
    final missing = complete
        .where((job) => job.status == DownloadStatus.unavailable)
        .length;
    checks['Downloaded files'] = DiagnosticCheck(
      missing == 0
          ? '${complete.length} readable files available'
          : '$missing of ${complete.length} files are unavailable. Open Downloads to retry. Saved records do not contain the video files.',
      missing > 0
          ? DiagnosticSeverity.error
          : complete.isEmpty
          ? DiagnosticSeverity.info
          : DiagnosticSeverity.success,
    );
    final protectionFailures = complete
        .where(
          (job) => job.status == DownloadStatus.complete && job.error != null,
        )
        .length;
    checks['Offline storage protection'] = DiagnosticCheck(
      protectionFailures == 0
          ? 'No storage protection errors detected'
          : 'Failed to protect $protectionFailures videos from Android cleanup. Original files remain playable; run checks again.',
      protectionFailures == 0
          ? DiagnosticSeverity.success
          : DiagnosticSeverity.warning,
    );
    final exact = state.downloads.every(
      (job) => !job.mediaTitle.isSeries || job.mediaVideo != null,
    );
    checks['Episode identity'] = DiagnosticCheck(
      exact
          ? 'Every series download has an exact episode ID'
          : 'One or more legacy downloads lack an episode ID',
      exact ? DiagnosticSeverity.success : DiagnosticSeverity.warning,
    );
    checks['AIOStreams'] = DiagnosticCheck(
      state.connections.hasAioStreams
          ? 'Manifest configured'
          : 'Not configured (demo mode available)',
      DiagnosticSeverity.info,
    );
    checks['TorBox'] = DiagnosticCheck(
      state.connections.hasTorBox
          ? 'API token configured'
          : 'Not configured (demo mode available)',
      DiagnosticSeverity.info,
    );
    checks['Trakt'] = DiagnosticCheck(
      state.connections.hasTraktSession
          ? 'Connected; TorBridge playback syncs watched history. Direct Stremio playback may not sync.'
          : 'Not connected; local watched history is available',
      DiagnosticSeverity.info,
    );
    bool available = false;
    try {
      available = await canLaunchUrl(Uri.parse('stremio:///board'));
    } catch (_) {
      /* No handler. */
    }
    checks['Stremio application'] = DiagnosticCheck(
      available
          ? 'Registered for stremio:// links'
          : 'Could not verify a stremio:// handler',
      available ? DiagnosticSeverity.success : DiagnosticSeverity.warning,
    );
    if (mounted) {
      state = state.copyWith(
        diagnosticChecks: checks,
        stremioAvailable: available,
      );
    }
  }

  Future<void> _loadSources(CatalogTitle title, CatalogVideo? video) async {
    final manifestText = state.connections.aioManifestUrl;
    if (manifestText == null || manifestText.isEmpty) return;
    if (title.isSeries && video == null) return;
    final videoId = video?.id ?? title.id;
    state = state.copyWith(busy: true, sourceCandidates: const []);
    try {
      final candidates = await _fetchSources(title, video);
      if (!mounted ||
          state.selectedTitle.id != title.id ||
          state.selectedVideoId != videoId) {
        return;
      }
      state = state.copyWith(
        busy: false,
        sourceCandidates: candidates,
        notice: candidates.isEmpty ? 'AIOStreams returned no sources.' : null,
        clearNotice: candidates.isNotEmpty,
      );
    } catch (error) {
      if (!mounted) return;
      state = state.copyWith(
        busy: false,
        notice: 'AIOStreams search failed: $error',
      );
    }
  }

  Future<StreamCandidate?> _refreshSource(DownloadJob job) async {
    final candidates = await _fetchSourcesForJob(job);
    final usable = candidates.where(_hasDownloadReference).toList();
    final matching = _matchingSource(job.source, usable);
    if (matching != null) return matching;
    return const RecommendationEngine()
        .rank(usable, state.preferences)
        .best
        ?.candidate;
  }

  Future<List<StreamCandidate>> _fetchSourcesForJob(DownloadJob job) async {
    // A slow addon must not indefinitely block retrying a saved source or
    // requesting a fresh TorBox link. Late results cannot start a transfer.
    return _fetchSources(job.mediaTitle, job.mediaVideo).timeout(
      const Duration(seconds: 30),
      onTimeout: () => const <StreamCandidate>[],
    );
  }

  Future<List<StreamCandidate>> _fetchSources(
    CatalogTitle title,
    CatalogVideo? video,
  ) async {
    final manifestText = state.connections.aioManifestUrl;
    if (manifestText == null || manifestText.isEmpty || state.demoMode) {
      return const [];
    }
    var candidates = const <StreamCandidate>[];
    try {
      candidates = await _aioStreamsClient.getStreams(
        manifestUrl: Uri.parse(manifestText),
        type: title.type,
        videoId: video?.id ?? title.id,
      );
    } catch (_) {
      // A direct Torrentio metadata request below can still recover the
      // torrent reference when the configured aggregator is unavailable.
    }
    if (!candidates.any(
      (candidate) => candidate.infoHash?.isNotEmpty == true,
    )) {
      try {
        final torrentCandidates = await _aioStreamsClient.getTorrentioStreams(
          type: title.type,
          videoId: video?.id ?? title.id,
        );
        final knownIds = candidates.map((candidate) => candidate.id).toSet();
        candidates = [
          ...candidates,
          ...torrentCandidates.where((candidate) => knownIds.add(candidate.id)),
        ];
      } catch (_) {
        // Preserve any configured-addon candidates if both Torrentio hosts fail.
      }
    }
    return _confirmCacheStatuses(candidates);
  }

  StreamCandidate? _matchingSource(
    StreamCandidate original,
    List<StreamCandidate> candidates,
  ) {
    StreamCandidate? best;
    var bestScore = 0;
    for (final candidate in candidates) {
      var score = 0;
      if (original.infoHash != null &&
          candidate.infoHash?.toLowerCase() ==
              original.infoHash!.toLowerCase()) {
        score += 20;
      }
      if (original.filename != null &&
          candidate.filename?.toLowerCase() ==
              original.filename!.toLowerCase()) {
        score += 12;
      }
      if (candidate.displayName == original.displayName) score += 8;
      if (candidate.sizeBytes == original.sizeBytes) score += 3;
      if (candidate.resolution == original.resolution) score += 2;
      if (candidate.codec == original.codec) score += 2;
      if (score > bestScore) {
        best = candidate;
        bestScore = score;
      }
    }
    return bestScore >= 8 ? best : null;
  }

  StreamCandidate? _bestAlternative(
    List<StreamCandidate> candidates,
    StreamCandidate failed,
  ) {
    final ranked = const RecommendationEngine().rank(
      candidates,
      state.preferences,
    );
    StreamCandidate? sameOriginFallback;
    for (final item in ranked.ranked) {
      if (!item.isEligible || _sameRelease(item.candidate, failed)) continue;
      if (_differentOrigin(item.candidate, failed)) return item.candidate;
      sameOriginFallback ??= item.candidate;
    }
    return sameOriginFallback;
  }

  StreamCandidate? _bestTorBoxRecoverySource(
    List<StreamCandidate> candidates,
    StreamCandidate failed,
  ) {
    final torrentSources = candidates
        .where((candidate) => candidate.infoHash?.isNotEmpty == true)
        .toList();
    final matching = _matchingSource(failed, torrentSources);
    if (matching != null) return matching;
    return const RecommendationEngine()
        .rank(torrentSources, state.preferences)
        .best
        ?.candidate;
  }

  bool _hasDownloadReference(StreamCandidate candidate) =>
      candidate.streamUrl != null || candidate.infoHash?.isNotEmpty == true;

  bool _differentOrigin(StreamCandidate candidate, StreamCandidate failed) {
    final candidateHost = candidate.streamUrl?.host.toLowerCase();
    final failedHost = failed.streamUrl?.host.toLowerCase();
    if (candidateHost != null && failedHost != null) {
      return candidateHost != failedHost;
    }
    return candidate.addonName != failed.addonName;
  }

  bool _sameRelease(StreamCandidate left, StreamCandidate right) {
    if (left.infoHash != null && right.infoHash != null) {
      return left.infoHash!.toLowerCase() == right.infoHash!.toLowerCase();
    }
    if (left.filename != null && right.filename != null) {
      return left.filename!.toLowerCase() == right.filename!.toLowerCase();
    }
    return left.displayName == right.displayName &&
        left.sizeBytes == right.sizeBytes;
  }

  Uri? _migratedTorrentioUrl(Uri? source) {
    if (source?.host.toLowerCase() != 'torrentio.stremio.ru') return null;
    return source!.replace(host: 'torrentio.strem.fun');
  }

  Future<List<StreamCandidate>> _confirmCacheStatuses(
    List<StreamCandidate> candidates,
  ) async {
    final token = state.connections.torBoxToken;
    if (token == null || token.isEmpty) return candidates;
    final unknownHashes = candidates
        .where(
          (candidate) =>
              candidate.cacheStatus == CacheStatus.unknown &&
              candidate.infoHash != null,
        )
        .map((candidate) => candidate.infoHash!.toLowerCase())
        .toSet();
    if (unknownHashes.isEmpty) return candidates;
    try {
      final cached = await _torBoxClientFactory(token)
          .cachedHashes(unknownHashes);
      return [
        for (final candidate in candidates)
          if (candidate.cacheStatus == CacheStatus.unknown &&
              candidate.infoHash != null)
            candidate.copyWith(
              cacheStatus: cached.contains(candidate.infoHash!.toLowerCase())
                  ? CacheStatus.cached
                  : CacheStatus.uncached,
            )
          else
            candidate,
      ];
    } catch (_) {
      return candidates;
    }
  }

  Future<Uri> _downloadUrl(DownloadJob job) async {
    final source = job.source;
    if (source.streamUrl != null) return source.streamUrl!;
    return _directTorBoxDownloadUrl(job);
  }

  Future<Uri> _directTorBoxDownloadUrl(
    DownloadJob job,
  ) => _withTorBoxProvisionLock(() async {
    final token = state.connections.torBoxToken;
    if (token == null || token.isEmpty) {
      throw const TorBoxApiException('Connect your TorBox API token first.');
    }
    final torBox = _torBoxClientFactory(token);
    TorBoxFileSelection? selection;
    final hash = job.source.infoHash;
    if (hash != null && hash.isNotEmpty) {
      var torrent = await torBox.ensureTorrent(
        infoHash: hash,
        cachedOnly: state.preferences.cachedOnly,
      );
      torrent = await torBox.waitForFiles(torrent);
      final file = job.mediaVideo == null
          ? torrent.preferredFile(job.source.fileIndex)
          : torrent.episodeFile(job.mediaVideo!.code, job.source.fileIndex);
      if (file != null) {
        selection = TorBoxFileSelection(torrent: torrent, file: file);
      }
    } else {
      selection = await torBox.findVideoFile(
        title: job.mediaTitle.name,
        episodeCode: job.mediaVideo?.code,
        year: job.mediaTitle.year,
      );
    }
    if (selection == null) {
      throw TorBoxApiException(
        job.mediaVideo == null
            ? 'The addon did not provide a torrent reference and no matching file is already in TorBox.'
            : 'The addon did not provide a torrent reference and no exact ${job.mediaVideo!.code} file is already in TorBox.',
      );
    }
    return torBox.requestDownloadLink(
      torrentId: selection.torrent.id,
      fileId: selection.file.id,
    );
  });

  Future<T> _withTorBoxProvisionLock<T>(Future<T> Function() operation) async {
    final previous = _torBoxProvisionTail;
    final release = Completer<void>();
    _torBoxProvisionTail = release.future;
    await previous;
    try {
      return await operation();
    } finally {
      release.complete();
    }
  }

  Future<void> _syncWatchedEntry(WatchedEntry entry, bool watched) async {
    if (!mounted ||
        !state.connections.hasTraktSession ||
        !entry.title.id.startsWith('tt')) {
      return;
    }
    try {
      await _withTraktSession(
        (client, accessToken) => client.markWatched(
          accessToken: accessToken,
          media: _traktMedia(entry.title, entry.video),
          watched: watched,
        ),
      );
    } catch (error) {
      if (mounted) state = state.copyWith(notice: 'Trakt sync failed: $error');
    }
  }

  TraktMedia _traktMedia(CatalogTitle title, CatalogVideo? video) {
    if (video != null) {
      return TraktMedia.episode(
        title: title.name,
        year: title.year,
        imdbId: title.id,
        season: video.season,
        episode: video.episode,
      );
    }
    return TraktMedia.movie(
      title: title.name,
      year: title.year,
      imdbId: title.id,
    );
  }

  Future<T?> _withTraktSession<T>(
    Future<T> Function(TraktClient client, String accessToken) operation,
  ) async {
    final connections = state.connections;
    if (!connections.hasTraktSession) return null;
    final client = _traktClientFactory(
      connections.traktClientId!,
      connections.traktClientSecret!,
    );
    try {
      return await operation(client, connections.traktAccessToken!);
    } on DioException catch (error) {
      final refreshToken = connections.traktRefreshToken;
      if (error.response?.statusCode != 401 ||
          refreshToken == null ||
          refreshToken.isEmpty) {
        rethrow;
      }
      final refreshed = await client.refresh(refreshToken);
      await _credentialStore.saveTraktTokens(
        accessToken: refreshed.accessToken,
        refreshToken: refreshed.refreshToken,
      );
      if (mounted) {
        state = state.copyWith(connections: await _credentialStore.read());
      }
      return operation(client, refreshed.accessToken);
    }
  }

  List<DownloadJob> _downloadsWithWatchedState(Set<String> watched) {
    final now = DateTime.now().toUtc();
    return [
      for (final job in state.downloads)
        if (watched.contains(job.videoId) && job.watchedAt == null)
          job.copyWith(watchedAt: now)
        else if (!watched.contains(job.videoId) && job.watchedAt != null)
          job.copyWith(watchedAt: null)
        else
          job,
    ];
  }

  void _resumeInterruptedDownloads() {
    final pending =
        state.downloads
            .where(
              (item) =>
                  item.status == DownloadStatus.queued ||
                  item.status == DownloadStatus.downloading,
            )
            .toList()
          ..sort(
            (a, b) => a.createdAt == null || b.createdAt == null
                ? 0
                : a.createdAt!.compareTo(b.createdAt!),
          );
    // Adopt all previously enqueued native transfers without discarding their
    // partial files. They occupy slots before any new queued item can start.
    for (final job in pending) {
      if (_downloadService.supportsResume && job.platformId != null) {
        _activeDownloads.add(job.id);
      }
    }
    for (final job in pending) {
      if (_activeDownloads.contains(job.id)) {
        unawaited(
          _executeDownload(
            job.id,
            () => _resumeDownload(job),
            Completer<void>(),
          ),
        );
      } else if (_downloadService.supportsResume &&
          job.status == DownloadStatus.queued) {
        unawaited(_runDownload(job, refreshSource: true));
      } else {
        _replaceJob(
          job.copyWith(
            status: DownloadStatus.failed,
            error: 'The app closed before this download completed. Retry it.',
          ),
        );
      }
    }
  }

  Future<void> _resumeDownload(DownloadJob original) async {
    var job = original.copyWith(status: DownloadStatus.downloading);
    _replaceJob(job);
    try {
      String path;
      try {
        path = await _downloadService.resume(
          jobId: job.id,
          platformId: job.platformId!,
          onProgress: (received, total) {
            job = job.copyWith(
              progress: total > 0 ? (received / total).clamp(0, 1) : 0,
              error: _downloadService.downloadStatus(job.id),
            );
            _replaceJob(job, persist: false);
          },
        );
      } on DownloadFailureException catch (error) {
        if (!error.isRetryableSourceFailure) rethrow;
        if (!mounted ||
            _removingDownloadIds.contains(job.id) ||
            !state.downloads.any((item) => item.id == job.id)) {
          return;
        }
        // An upgraded app may adopt many old system transfers. Queue their
        // recovery attempts instead of launching another concurrent batch.
        _replaceJob(
          job.copyWith(
            status: DownloadStatus.queued,
            error: 'Queued — waiting to recover the interrupted download.',
          ),
        );
        _downloadQueue[job.id] = (
          () => _runDownloadNow(
            job.id,
            refreshSource: false,
            recoveryError: error,
          ),
          Completer<void>(),
        );
        return;
      }
      _replaceJob(
        job.copyWith(
          status: DownloadStatus.complete,
          progress: 1,
          localPath: path,
          completedAt: DateTime.now().toUtc(),
          error: _downloadService.localFileWarning(path),
        ),
      );
      await _ensureBridge();
    } catch (error) {
      _replaceJob(
        job.copyWith(
          status: DownloadStatus.failed,
          error: _errorMessage(error, job.source),
        ),
      );
    }
  }

  void _replaceJob(DownloadJob replacement, {bool persist = true}) {
    if (!mounted) return;
    state = state.copyWith(
      downloads: [
        for (final item in state.downloads)
          if (item.id == replacement.id) replacement else item,
      ],
    );
    if (persist) unawaited(_saveDownloads());
  }

  Future<void> _ensureBridge() async {
    if (state.bridgePhase == BridgePhase.starting) return;
    state = state.copyWith(bridgePhase: BridgePhase.starting);
    try {
      await _stremioBridge.start(_bridgeEntries());
      if (mounted) state = state.copyWith(bridgePhase: BridgePhase.ready);
    } catch (error) {
      if (mounted) {
        state = state.copyWith(
          bridgePhase: BridgePhase.error,
          notice: 'The local Stremio addon could not start: $error',
        );
      }
      rethrow;
    }
  }

  Future<void> _updateBridge() async {
    if (state.bridgePhase == BridgePhase.stopped) return;
    try {
      await _stremioBridge.update(_bridgeEntries());
      if (mounted) state = state.copyWith(bridgePhase: BridgePhase.ready);
    } catch (error) {
      if (mounted) state = state.copyWith(bridgePhase: BridgePhase.error);
    }
  }

  List<StremioBridgeEntry> _bridgeEntries() => [
    for (final job in state.downloads)
      if (job.status == DownloadStatus.complete && job.localPath != null)
        StremioBridgeEntry(
          id: job.id,
          type: job.mediaTitle.type,
          videoId: job.videoId,
          showId: job.mediaTitle.id,
          title: job.title,
          filename: _filenameFromJob(job),
          localPath: job.localPath!,
          description:
              '${job.tags.join(' • ')}\n${job.audioLabel} • ${job.subtitleLabel}',
          sizeBytes: job.source.sizeBytes,
        ),
  ];

  Future<void> _saveDownloads() async {
    if (!_downloadsReadable) {
      if (mounted) {
        state = state.copyWith(
          notice:
              'Saved download records could not be read and remain protected.',
        );
      }
      return;
    }
    final records = [
      ..._unreadDownloadRecords,
      for (final job in state.downloads) _jobToRecord(job),
    ];
    final operation = _downloadSaveTail.then((_) async {
      await _localStateStore.saveDownloadRecords(records);
      await _updateBridge();
    });
    _downloadSaveTail = operation.catchError((Object _) {});
    return operation;
  }

  Map<String, dynamic> _jobToRecord(DownloadJob job) => {
    'schema': 3,
    'id': job.id,
    'title': job.title,
    'status': job.status.name,
    'progress': job.progress,
    'localPath': job.localPath,
    'platformId': job.platformId,
    'error': job.error,
    'createdAt': job.createdAt?.toIso8601String(),
    'completedAt': job.completedAt?.toIso8601String(),
    'watchedAt': job.watchedAt?.toIso8601String(),
    'mediaTitle': _titleToJson(job.mediaTitle),
    if (job.mediaVideo != null) 'mediaVideo': _videoToJson(job.mediaVideo!),
    'source': {
      'id': job.source.id,
      'addonName': job.source.addonName,
      'displayName': job.source.displayName,
      'description': job.source.description,
      'resolution': job.source.resolution?.name,
      'codec': job.source.codec.name,
      'hdr': job.source.hdr.name,
      'cacheStatus': job.source.cacheStatus.name,
      'audioLanguages': job.source.audioLanguages.toList(),
      'subtitleLanguages': job.source.subtitleLanguages.toList(),
      'sizeBytes': job.source.sizeBytes,
      'releaseTags': job.source.releaseTags.toList(),
      'infoHash': job.source.infoHash,
      'fileIndex': job.source.fileIndex,
      'filename': job.source.filename,
    },
  };

  Map<String, dynamic> _titleToJson(CatalogTitle title) => {
    'id': title.id,
    'type': title.type,
    'name': title.name,
    'year': title.year,
    'summary': title.summary,
    'genre': title.genre,
    'color': title.color,
    'posterUrl': title.posterUrl?.toString(),
    'backgroundUrl': title.backgroundUrl?.toString(),
  };

  Map<String, dynamic> _videoToJson(CatalogVideo video) => {
    'id': video.id,
    'title': video.title,
    'season': video.season,
    'episode': video.episode,
    'released': video.released?.toIso8601String(),
    'thumbnailUrl': video.thumbnailUrl?.toString(),
    'overview': video.overview,
  };

  List<DownloadJob> _jobsFromRecords(List<Map<String, dynamic>> records) {
    final jobs = <DownloadJob>[];
    for (final record in records) {
      try {
        final media = Map<String, dynamic>.from(record['mediaTitle'] as Map);
        final source = Map<String, dynamic>.from(record['source'] as Map);
        final id = '${record['id']}';
        final videoValue = record['mediaVideo'];
        jobs.add(
          DownloadJob(
            id: id,
            title: '${record['title']}',
            mediaTitle: _titleFromJson(media),
            mediaVideo: videoValue is Map
                ? _videoFromJson(Map<String, dynamic>.from(videoValue))
                : null,
            source: StreamCandidate(
              id: '${source['id'] ?? id}',
              addonName: '${source['addonName']}',
              displayName: '${source['displayName']}',
              description: '${source['description']}',
              resolution: _nullableEnumByName(
                VideoResolution.values,
                source['resolution'],
              ),
              codec: _enumByName(
                VideoCodec.values,
                source['codec'],
                VideoCodec.unknown,
              ),
              hdr: _enumByName(
                HdrFormat.values,
                source['hdr'],
                HdrFormat.unknown,
              ),
              cacheStatus: _enumByName(
                CacheStatus.values,
                source['cacheStatus'],
                CacheStatus.unknown,
              ),
              audioLanguages: _stringSet(source['audioLanguages']),
              subtitleLanguages: _stringSet(source['subtitleLanguages']),
              sizeBytes: (source['sizeBytes'] as num?)?.toInt(),
              releaseTags: _stringSet(source['releaseTags']),
              infoHash: source['infoHash'] as String?,
              fileIndex: (source['fileIndex'] as num?)?.toInt(),
              filename: source['filename'] as String?,
            ),
            status: _enumByName(
              DownloadStatus.values,
              record['status'],
              DownloadStatus.complete,
            ),
            progress: (record['progress'] as num?)?.toDouble() ?? 1,
            localPath: record['localPath'] as String?,
            platformId: record['platformId'] as String?,
            // Before 1.2.10 this exact text was emitted for Android 1008.
            // Schema 3 distinguishes newly recorded, genuine 1009 conflicts.
            error:
                ((record['schema'] as num?)?.toInt() ?? 1) < 3 &&
                    record['error'] == 'the file already exists'
                ? const DownloadFailureException(1008).description
                : record['error'] as String?,
            createdAt: _date(record['createdAt']),
            completedAt: _date(record['completedAt']),
            watchedAt: _date(record['watchedAt']),
          ),
        );
      } catch (_) {
        // Keep unread records verbatim when saving valid jobs.
        _unreadDownloadRecords.add(record);
      }
    }
    return jobs;
  }

  CatalogTitle _titleFromJson(Map<String, dynamic> media) => CatalogTitle(
    id: '${media['id']}',
    type: '${media['type']}',
    name: '${media['name']}',
    year: (media['year'] as num?)?.toInt() ?? 0,
    summary: '${media['summary'] ?? ''}',
    genre: '${media['genre'] ?? 'Unknown genre'}',
    color: (media['color'] as num?)?.toInt() ?? 0xFF5141A8,
    posterUrl: Uri.tryParse('${media['posterUrl'] ?? ''}'),
    backgroundUrl: Uri.tryParse('${media['backgroundUrl'] ?? ''}'),
  );

  CatalogVideo _videoFromJson(Map<String, dynamic> value) => CatalogVideo(
    id: '${value['id']}',
    title: '${value['title']}',
    season: (value['season'] as num).toInt(),
    episode: (value['episode'] as num).toInt(),
    released: _date(value['released']),
    thumbnailUrl: Uri.tryParse('${value['thumbnailUrl'] ?? ''}'),
    overview: '${value['overview'] ?? ''}',
  );

  DateTime? _date(Object? value) =>
      value is String ? DateTime.tryParse(value) : null;

  Set<String> _stringSet(Object? value) =>
      value is List ? value.whereType<String>().toSet() : const {};

  T _enumByName<T extends Enum>(List<T> values, Object? name, T fallback) =>
      _nullableEnumByName(values, name) ?? fallback;

  T? _nullableEnumByName<T extends Enum>(List<T> values, Object? name) {
    for (final value in values) {
      if (value.name == name) return value;
    }
    return null;
  }

  String _downloadFilename(DownloadJob job) {
    final title = job.mediaTitle.name.replaceAll(RegExp(r'\s+'), '.');
    final episode = job.mediaVideo == null
        ? '${job.mediaTitle.year}'
        : job.mediaVideo!.code;
    final quality = job.source.resolution?.label ?? 'unknown';
    final codec = job.source.codec.label.replaceAll('.', '');
    final extension = _sourceExtension(job.source);
    return _safeFilename('$title.$episode.$quality.$codec.$extension');
  }

  String _sourceExtension(StreamCandidate source) {
    final filename = source.filename ?? source.displayName;
    final match = RegExp(r'\.([a-zA-Z0-9]{2,5})$').firstMatch(filename);
    final extension = match?.group(1)?.toLowerCase();
    return const {'mkv', 'mp4', 'webm', 'avi'}.contains(extension)
        ? extension!
        : 'mp4';
  }

  String _filenameFromJob(DownloadJob job) {
    final path = job.localPath;
    if (path != null && path.isNotEmpty) {
      final normalized = path.replaceAll('\\', '/');
      final name = normalized.split('/').last;
      if (name.isNotEmpty) return name;
    }
    return _downloadFilename(job);
  }

  String _safeFilename(String value) =>
      value.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');
}
