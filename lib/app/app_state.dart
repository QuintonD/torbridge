import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/demo_catalog.dart';
import '../domain/catalog_title.dart';
import '../domain/media_models.dart';
import '../domain/recommendation_engine.dart';
import '../integrations/aio_streams_client.dart';
import '../integrations/cinemeta_client.dart';
import '../integrations/torbox_client.dart';
import '../integrations/trakt_client.dart';
import '../services/credential_store.dart';
import '../services/download_service.dart';
import '../services/local_state_store.dart';

enum DownloadStatus { queued, downloading, complete, failed }

enum ConnectionPhase { idle, checking, ready, error }

class DownloadJob {
  const DownloadJob({
    required this.id,
    required this.title,
    required this.mediaTitle,
    required this.source,
    required this.status,
    this.progress = 0,
    this.localPath,
    this.error,
  });

  final String id;
  final String title;
  final CatalogTitle mediaTitle;
  final StreamCandidate source;
  final DownloadStatus status;
  final double progress;
  final String? localPath;
  final String? error;

  DownloadJob copyWith({
    DownloadStatus? status,
    double? progress,
    String? localPath,
    String? error,
  }) {
    return DownloadJob(
      id: id,
      title: title,
      mediaTitle: mediaTitle,
      source: source,
      status: status ?? this.status,
      progress: progress ?? this.progress,
      localPath: localPath ?? this.localPath,
      error: error,
    );
  }
}

class TorBridgeState {
  const TorBridgeState({
    this.navigationIndex = 0,
    this.selectedTitle = demoFeaturedTitle,
    this.catalogTitles = demoTitles,
    this.sourceCandidates = const [],
    this.preferences = const DownloadPreferences(
      subtitleLanguageOrder: ['Dutch', 'English'],
    ),
    this.downloads = const [],
    this.watchedTitleIds = const {},
    this.connections = const StoredConnections(),
    this.demoMode = true,
    this.busy = false,
    this.connectionPhase = ConnectionPhase.idle,
    this.notice,
  });

  final int navigationIndex;
  final CatalogTitle selectedTitle;
  final List<CatalogTitle> catalogTitles;
  final List<StreamCandidate> sourceCandidates;
  final DownloadPreferences preferences;
  final List<DownloadJob> downloads;
  final Set<String> watchedTitleIds;
  final StoredConnections connections;
  final bool demoMode;
  final bool busy;
  final ConnectionPhase connectionPhase;
  final String? notice;

  RecommendationResult get recommendation => const RecommendationEngine().rank(
    demoMode ? demoCandidates() : sourceCandidates,
    preferences,
  );

  TorBridgeState copyWith({
    int? navigationIndex,
    CatalogTitle? selectedTitle,
    List<CatalogTitle>? catalogTitles,
    List<StreamCandidate>? sourceCandidates,
    DownloadPreferences? preferences,
    List<DownloadJob>? downloads,
    Set<String>? watchedTitleIds,
    StoredConnections? connections,
    bool? demoMode,
    bool? busy,
    ConnectionPhase? connectionPhase,
    String? notice,
    bool clearNotice = false,
  }) {
    return TorBridgeState(
      navigationIndex: navigationIndex ?? this.navigationIndex,
      selectedTitle: selectedTitle ?? this.selectedTitle,
      catalogTitles: catalogTitles ?? this.catalogTitles,
      sourceCandidates: sourceCandidates ?? this.sourceCandidates,
      preferences: preferences ?? this.preferences,
      downloads: downloads ?? this.downloads,
      watchedTitleIds: watchedTitleIds ?? this.watchedTitleIds,
      connections: connections ?? this.connections,
      demoMode: demoMode ?? this.demoMode,
      busy: busy ?? this.busy,
      connectionPhase: connectionPhase ?? this.connectionPhase,
      notice: clearNotice ? null : notice ?? this.notice,
    );
  }
}

final downloadServiceProvider = Provider<DownloadService>(
  (ref) => Platform.isAndroid
      ? AndroidSystemDownloadService()
      : DioDownloadService(),
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

final torBridgeControllerProvider =
    StateNotifierProvider<TorBridgeController, TorBridgeState>((ref) {
      final controller = TorBridgeController(
        ref.read(downloadServiceProvider),
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
    this._credentialStore,
    this._cinemetaClient,
    this._aioStreamsClient,
    this._localStateStore,
  ) : super(const TorBridgeState());

  final DownloadService _downloadService;
  final CredentialStore _credentialStore;
  final CinemetaClient _cinemetaClient;
  final AioStreamsClient _aioStreamsClient;
  final LocalStateStore _localStateStore;

  Future<void> initialize() async {
    try {
      final local = await _localStateStore.read();
      state = state.copyWith(
        preferences: local.preferences,
        watchedTitleIds: local.watchedTitleIds,
        downloads: _jobsFromRecords(local.downloadRecords),
      );
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
      if (live) await _loadSources(state.selectedTitle);
    } catch (error) {
      state = state.copyWith(
        connectionPhase: ConnectionPhase.error,
        notice: 'Secure storage could not be opened: $error',
      );
    }
  }

  void navigate(int index) {
    state = state.copyWith(navigationIndex: index);
  }

  void selectTitle(CatalogTitle title) {
    state = state.copyWith(
      selectedTitle: title,
      sourceCandidates: state.demoMode ? null : const [],
      clearNotice: true,
    );
    if (!state.demoMode) unawaited(_loadSources(title));
  }

  Future<void> searchCatalog(String query) async {
    if (query.trim().isEmpty) {
      state = state.copyWith(catalogTitles: demoTitles, clearNotice: true);
      return;
    }
    state = state.copyWith(busy: true, clearNotice: true);
    try {
      final results = await _cinemetaClient.search(query);
      state = state.copyWith(
        busy: false,
        catalogTitles: results,
        notice: results.isEmpty ? 'No titles matched “${query.trim()}”.' : null,
        clearNotice: results.isNotEmpty,
      );
      if (results.isNotEmpty) selectTitle(results.first);
    } catch (error) {
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
    if (!enabled) unawaited(_loadSources(state.selectedTitle));
  }

  void updatePreferences(DownloadPreferences preferences) {
    state = state.copyWith(preferences: preferences);
    unawaited(_localStateStore.savePreferences(preferences));
  }

  void toggleWatched(String titleId) {
    final watched = {...state.watchedTitleIds};
    final adding = !watched.contains(titleId);
    adding ? watched.add(titleId) : watched.remove(titleId);
    state = state.copyWith(watchedTitleIds: watched);
    unawaited(_localStateStore.saveWatched(watched));
    if (adding && state.connections.hasTraktSession) {
      unawaited(_markSelectedMovieWatched());
    }
  }

  Future<void> scrobble({
    required CatalogTitle title,
    required TraktScrobbleAction action,
    required double progress,
  }) async {
    final connections = state.connections;
    if (!connections.hasTraktSession || !title.id.startsWith('tt')) return;
    try {
      await _withTraktSession(
        (client, accessToken) => client.scrobble(
          accessToken: accessToken,
          media: TraktMedia.movie(
            title: title.name,
            year: title.year,
            imdbId: title.id,
          ),
          action: action,
          progress: progress,
        ),
      );
      if (action == TraktScrobbleAction.stop && progress >= 80 && mounted) {
        state = state.copyWith(
          watchedTitleIds: {...state.watchedTitleIds, title.id},
        );
      }
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
        await TorBoxClient(torText).validateToken();
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
      if (live) await _loadSources(state.selectedTitle);
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

  Future<TraktDeviceCode> requestTraktDeviceCode() async {
    final connections = state.connections;
    if (!connections.hasTraktApp) {
      throw StateError('Add a Trakt client ID and secret first.');
    }
    final client = TraktClient(
      clientId: connections.traktClientId!,
      clientSecret: connections.traktClientSecret!,
    );
    return client.requestDeviceCode();
  }

  Future<TraktDevicePollResult> pollTraktDeviceCode(String deviceCode) async {
    final connections = state.connections;
    if (!connections.hasTraktApp) {
      return const TraktDevicePollResult(TraktDeviceStatus.invalid);
    }
    final client = TraktClient(
      clientId: connections.traktClientId!,
      clientSecret: connections.traktClientSecret!,
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
    }
    return result;
  }

  Future<void> downloadRecommended() async {
    final best = state.recommendation.best;
    if (best == null) return;
    final source = best.candidate;
    final existing = state.downloads.where((item) => item.id == source.id);
    if (existing.isNotEmpty && existing.first.status != DownloadStatus.failed) {
      navigate(1);
      return;
    }

    final job = DownloadJob(
      id: source.id,
      title: state.selectedTitle.name,
      mediaTitle: state.selectedTitle,
      source: source,
      status: DownloadStatus.queued,
    );
    state = state.copyWith(
      downloads: [job, ...state.downloads],
      navigationIndex: 1,
    );

    try {
      _replaceJob(job.copyWith(status: DownloadStatus.downloading));
      final url = await _downloadUrl(source);
      final localPath = await _downloadService.download(
        url: url,
        suggestedName: _safeFilename(
          '${job.title}-${DateTime.now().millisecondsSinceEpoch}.mp4',
        ),
        onProgress: (received, total) {
          final progress = total > 0 ? received / total : 0.0;
          _replaceJob(
            job.copyWith(
              status: DownloadStatus.downloading,
              progress: progress.clamp(0, 1),
            ),
          );
        },
      );
      _replaceJob(
        job.copyWith(
          status: DownloadStatus.complete,
          progress: 1,
          localPath: localPath,
        ),
      );
    } catch (error) {
      _replaceJob(
        job.copyWith(status: DownloadStatus.failed, error: error.toString()),
      );
    }
  }

  Future<void> _loadSources(CatalogTitle title) async {
    final manifestText = state.connections.aioManifestUrl;
    if (manifestText == null || manifestText.isEmpty) return;
    state = state.copyWith(busy: true, sourceCandidates: const []);
    try {
      final discovered = await _aioStreamsClient.getStreams(
        manifestUrl: Uri.parse(manifestText),
        type: title.type,
        videoId: title.id,
      );
      final candidates = await _confirmCacheStatuses(discovered);
      if (!mounted || state.selectedTitle.id != title.id) return;
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
      final cached = await TorBoxClient(token).cachedHashes(unknownHashes);
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
      // Ranking can still use AIOStreams metadata if the cache-status probe is
      // temporarily unavailable. Download creation remains authoritative.
      return candidates;
    }
  }

  Future<Uri> _downloadUrl(StreamCandidate source) async {
    if (source.streamUrl != null) return source.streamUrl!;
    final hash = source.infoHash;
    final token = state.connections.torBoxToken;
    if (hash == null || token == null || token.isEmpty) {
      throw const TorBoxApiException(
        'This source needs a TorBox torrent reference and connected API token.',
      );
    }
    final torBox = TorBoxClient(token);
    final torrent = await torBox.ensureTorrent(
      infoHash: hash,
      cachedOnly: state.preferences.cachedOnly,
    );
    final file = torrent.preferredFile(source.fileIndex);
    if (file == null) {
      throw const TorBoxApiException('No downloadable video file was found.');
    }
    return torBox.requestDownloadLink(torrentId: torrent.id, fileId: file.id);
  }

  Future<void> _markSelectedMovieWatched() async {
    final connections = state.connections;
    final title = state.selectedTitle;
    if (!connections.hasTraktSession || !title.id.startsWith('tt')) return;
    try {
      await _withTraktSession(
        (client, accessToken) => client.markMovieWatched(
          accessToken: accessToken,
          movie: TraktMedia.movie(
            title: title.name,
            year: title.year,
            imdbId: title.id,
          ),
        ),
      );
    } catch (error) {
      if (mounted) state = state.copyWith(notice: 'Trakt sync failed: $error');
    }
  }

  Future<void> _withTraktSession(
    Future<void> Function(TraktClient client, String accessToken) operation,
  ) async {
    final connections = state.connections;
    if (!connections.hasTraktSession) return;
    final client = TraktClient(
      clientId: connections.traktClientId!,
      clientSecret: connections.traktClientSecret!,
    );
    try {
      await operation(client, connections.traktAccessToken!);
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
      await operation(client, refreshed.accessToken);
    }
  }

  void _replaceJob(DownloadJob replacement) {
    if (!mounted) return;
    state = state.copyWith(
      downloads: [
        for (final item in state.downloads)
          if (item.id == replacement.id) replacement else item,
      ],
    );
    if (replacement.status == DownloadStatus.complete) {
      unawaited(_saveCompletedDownloads());
    }
  }

  Future<void> _saveCompletedDownloads() =>
      _localStateStore.saveDownloadRecords([
        for (final job in state.downloads)
          if (job.status == DownloadStatus.complete) _jobToRecord(job),
      ]);

  Map<String, dynamic> _jobToRecord(DownloadJob job) => {
    'id': job.id,
    'title': job.title,
    'localPath': job.localPath,
    'mediaTitle': {
      'id': job.mediaTitle.id,
      'type': job.mediaTitle.type,
      'name': job.mediaTitle.name,
      'year': job.mediaTitle.year,
      'summary': job.mediaTitle.summary,
      'genre': job.mediaTitle.genre,
      'color': job.mediaTitle.color,
    },
    'source': {
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
    },
  };

  List<DownloadJob> _jobsFromRecords(List<Map<String, dynamic>> records) {
    final jobs = <DownloadJob>[];
    for (final record in records) {
      try {
        final media = Map<String, dynamic>.from(record['mediaTitle'] as Map);
        final source = Map<String, dynamic>.from(record['source'] as Map);
        final id = '${record['id']}';
        jobs.add(
          DownloadJob(
            id: id,
            title: '${record['title']}',
            mediaTitle: CatalogTitle(
              id: '${media['id']}',
              type: '${media['type']}',
              name: '${media['name']}',
              year: (media['year'] as num).toInt(),
              summary: '${media['summary']}',
              genre: '${media['genre']}',
              color: (media['color'] as num).toInt(),
            ),
            source: StreamCandidate(
              id: id,
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
            ),
            status: DownloadStatus.complete,
            progress: 1,
            localPath: record['localPath'] as String?,
          ),
        );
      } catch (_) {
        // Ignore a single malformed legacy record and retain the rest.
      }
    }
    return jobs;
  }

  Set<String> _stringSet(Object? value) =>
      value is List ? value.whereType<String>().toSet() : const {};

  T _enumByName<T extends Enum>(List<T> values, Object? name, T fallback) {
    return _nullableEnumByName(values, name) ?? fallback;
  }

  T? _nullableEnumByName<T extends Enum>(List<T> values, Object? name) {
    for (final value in values) {
      if (value.name == name) return value;
    }
    return null;
  }

  String _safeFilename(String value) =>
      value.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');
}
