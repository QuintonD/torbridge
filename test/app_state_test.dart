import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:torbridge/app/app_state.dart';
import 'package:torbridge/data/demo_catalog.dart';
import 'package:torbridge/domain/catalog_title.dart';
import 'package:torbridge/domain/media_models.dart';
import 'package:torbridge/integrations/aio_streams_client.dart';
import 'package:torbridge/integrations/cinemeta_client.dart';
import 'package:torbridge/integrations/torbox_client.dart';
import 'package:torbridge/services/credential_store.dart';
import 'package:torbridge/services/download_service.dart';
import 'package:torbridge/services/local_state_store.dart';
import 'package:torbridge/services/setup_transfer_service.dart';
import 'package:torbridge/services/stremio_bridge_service.dart';

void main() {
  test('local destination errors do not blame the host and double retry starts one transfer', () async {
    final service = _DestinationConflictService();
    final controller = TorBridgeController(
      service,
      _FakeBridge(),
      _EmptyCredentials(),
      CinemetaClient(),
      AioStreamsClient(),
      _MemoryStateStore(),
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.downloadCandidate(_fallbackCandidate);
    final failed = controller.state.downloads.single;
    expect(failed.status, DownloadStatus.failed);
    expect(failed.error, 'the file already exists');
    final firstRetry = controller.retryDownload(failed);
    final secondRetry = controller.retryDownload(failed);
    await service.retryStarted.future;
    expect(service.calls, 2); // One original failure and exactly one retry.
    service.release.complete();
    await Future.wait([firstRetry, secondRetry]);
    expect(controller.state.downloads.single.status, DownloadStatus.complete);
    await controller.retryDownload(failed); // Ignore a stale button callback.
    expect(service.calls, 2);
  });
  for (final recovered in [
    null,
    '/current/movie.mp4',
    'content://downloads/my_downloads/1986',
  ]) {
    test('startup reconciles saved downloads with source $recovered', () async {
      final store = _MemoryStateStore()
        ..value = StoredLocalState(
          downloadRecords: [
            {
              'id': 'saved',
              'title': 'Saved movie',
              'status': 'complete',
              'localPath': '/old/movie.mp4',
              'platformId': '1986',
              'mediaTitle': {
                'id': 'tt0263757',
                'type': 'movie',
                'name': 'Saved movie',
              },
              'source': {
                'addonName': 'Test',
                'displayName': 'movie.mp4',
                'description': '',
              },
            },
          ],
        );
      final service = _ResolvingDownloadService(recovered);
      final bridge = _FakeBridge();
      final controller = TorBridgeController(
        service,
        bridge,
        _EmptyCredentials(),
        CinemetaClient(),
        AioStreamsClient(),
        store,
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      final job = controller.state.downloads.single;
      expect(
        job.status,
        recovered == null
            ? DownloadStatus.unavailable
            : DownloadStatus.complete,
      );
      expect(job.localPath, recovered ?? '/old/movie.mp4');
      expect(job.platformId, '1986');
      expect(service.checkedIds, ['1986']);
      expect(service.deleted, isEmpty);
      expect(store.value.downloadRecords.single['status'], job.status.name);
      expect(bridge.lastEntries, recovered == null ? isEmpty : hasLength(1));
      if (recovered == null) {
        expect(await controller.localPlaybackSource(job), isNull);
        expect(controller.state.notice, contains('Retry the download'));
        // Remount/relink without downloading or dropping the record.
        service.path = '/restored/movie.mp4';
        await controller.retryDownload(controller.state.downloads.single);
        expect(
          controller.state.downloads.single.status,
          DownloadStatus.complete,
        );
        expect(
          controller.state.downloads.single.localPath,
          '/restored/movie.mp4',
        );
      } else {
        expect(bridge.lastEntries.single.localPath, recovered);
        // A file can disappear after startup, before the user presses Play.
        service.path = null;
        expect(await controller.localPlaybackSource(job), isNull);
        expect(
          controller.state.downloads.single.status,
          DownloadStatus.unavailable,
        );
        expect(bridge.lastEntries, isEmpty);
        // A failed protective move does not make a readable video unavailable.
        service.path = recovered;
        service.warning = 'Original kept. Run Diagnostics again.';
        await controller.checkDownloadedFiles();
        expect(
          controller.state.downloads.single.status,
          DownloadStatus.complete,
        );
        expect(controller.state.downloads.single.error, service.warning);
        service.warning = null;
        await controller.checkDownloadedFiles();
        expect(controller.state.downloads.single.error, isNull);
      }
    });
  }

  test(
    'watched cleanup removes a completed file after the configured delay',
    () async {
      final downloads = _RecordingDownloadService();
      final controller = TorBridgeController(
        downloads,
        _FakeBridge(),
        _EmptyCredentials(),
        CinemetaClient(),
        AioStreamsClient(),
        _MemoryStateStore(),
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      await controller.downloadCandidate(demoCandidates().first);
      expect(controller.state.downloads, hasLength(1));

      controller.updatePreferences(
        controller.state.preferences.copyWith(deleteWatchedAfterDays: 0),
      );
      controller.toggleWatched('tt1254207');
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(controller.state.downloads, isEmpty);
      expect(downloads.deleted, ['C:\\TorBridge\\episode.mp4']);
    },
  );

  test('setup import replaces connections and preferences only', () async {
    final credentials = _MemoryCredentials();
    final localState = _MemoryStateStore();
    final controller = TorBridgeController(
      _RecordingDownloadService(),
      _FakeBridge(),
      credentials,
      CinemetaClient(),
      AioStreamsClient(),
      localState,
    );
    addTearDown(controller.dispose);
    await controller.initialize();

    const bundle = SetupTransferBundle(
      connections: StoredConnections(
        torBoxToken: 'token',
        traktClientId: 'client',
        traktClientSecret: 'secret',
        traktAccessToken: 'access',
        traktRefreshToken: 'refresh',
      ),
      preferences: DownloadPreferences(
        preferredResolution: VideoResolution.ultraHd2160,
        deleteWatchedAfterDays: 7,
      ),
    );

    final error = await controller.importSetupTransfer(bundle);

    expect(error, isNull);
    expect(credentials.value.torBoxToken, 'token');
    expect(credentials.value.traktAccessToken, 'access');
    expect(
      localState.value.preferences.preferredResolution,
      VideoResolution.ultraHd2160,
    );
    expect(controller.state.downloads, isEmpty);
  });

  test('HTTP 502 direct source retries with a fresh TorBox link', () async {
    final downloads = _RetryingDownloadService();
    final credentials = _MemoryCredentials()
      ..value = const StoredConnections(torBoxToken: 'token');
    final torBox = _FakeTorBoxClient();
    final controller = TorBridgeController(
      downloads,
      _FakeBridge(),
      credentials,
      CinemetaClient(),
      AioStreamsClient(),
      _MemoryStateStore(),
      (_) => torBox,
    );
    addTearDown(controller.dispose);
    await controller.initialize();

    await controller.downloadCandidate(_fallbackCandidate);

    expect(downloads.urls, [
      Uri.parse('https://streams.example/stale'),
      Uri.parse('https://torbox.example/fresh'),
    ]);
    expect(downloads.cancelledPlatformIds, ['direct-id']);
    expect(downloads.headers, [
      {'Referer': 'https://source.example/'},
      isEmpty,
    ]);
    expect(controller.state.downloads.single.status, DownloadStatus.complete);
    expect(controller.state.downloads.single.platformId, 'fallback-id');
    expect(torBox.requestedTorrentId, 42);
    expect(torBox.requestedFileId, 7);
  });

  test('Android HTTP reason is rendered as a useful error', () {
    const error = DownloadFailureException(502);

    expect(error.isRetryableHttpFailure, isTrue);
    expect(error.toString(), 'HTTP 502 (Bad Gateway)');
  });

  test(
    'HTTP 502 re-queries AIOStreams and retries its refreshed URL',
    () async {
      final downloads = _RetryingDownloadService();
      final credentials = _MemoryCredentials()
        ..value = const StoredConnections(
          aioManifestUrl: 'https://aio.example/manifest.json',
          torBoxToken: 'token',
        );
      final controller = TorBridgeController(
        downloads,
        _FakeBridge(),
        credentials,
        CinemetaClient(),
        _RefreshingAioStreamsClient(),
        _MemoryStateStore(),
        (_) => _FakeTorBoxClient(),
      );
      addTearDown(controller.dispose);
      await controller.initialize();

      await controller.downloadCandidate(_fallbackCandidate);

      expect(downloads.urls, [
        Uri.parse('https://streams.example/stale'),
        Uri.parse('https://streams.example/refreshed'),
      ]);
      expect(downloads.cancelledPlatformIds, ['direct-id']);
      expect(controller.state.downloads.single.status, DownloadStatus.complete);
    },
  );

  test(
    'two HTTP 502 responses fail over to a different eligible release',
    () async {
      final downloads = _FailTwiceDownloadService();
      final credentials = _MemoryCredentials()
        ..value = const StoredConnections(
          aioManifestUrl: 'https://aio.example/manifest.json',
          torBoxToken: 'token',
        );
      final controller = TorBridgeController(
        downloads,
        _FakeBridge(),
        credentials,
        CinemetaClient(),
        _AlternativeAioStreamsClient(),
        _MemoryStateStore(),
        (_) => _FakeTorBoxClient(),
      );
      addTearDown(controller.dispose);
      await controller.initialize();

      await controller.downloadCandidate(_fallbackCandidate);

      expect(downloads.urls, [
        Uri.parse('https://streams.example/stale'),
        Uri.parse('https://streams.example/refreshed'),
        Uri.parse('https://alternative.example/video'),
      ]);
      expect(controller.state.downloads.single.status, DownloadStatus.complete);
      expect(
        controller.state.downloads.single.source.filename,
        'alternative.mkv',
      );
    },
  );

  test('legacy Torrentio 502 retries through the current gateway', () async {
    final downloads = _FailTwiceDownloadService();
    final credentials = _MemoryCredentials()
      ..value = const StoredConnections(
        aioManifestUrl: 'https://aio.example/manifest.json',
        torBoxToken: 'token',
      );
    final controller = TorBridgeController(
      downloads,
      _FakeBridge(),
      credentials,
      CinemetaClient(),
      _LegacyTorrentioAioStreamsClient(),
      _MemoryStateStore(),
      (_) => _FakeTorBoxClient(),
    );
    addTearDown(controller.dispose);
    await controller.initialize();

    await controller.downloadCandidate(_fallbackCandidate);

    expect(downloads.urls, [
      Uri.parse('https://streams.example/stale'),
      Uri.parse('https://torrentio.stremio.ru/playback/file'),
      Uri.parse('https://torrentio.strem.fun/playback/file'),
    ]);
    expect(controller.state.downloads.single.status, DownloadStatus.complete);
  });

  test('HTTP 502 automatically finds the exact TorBox episode without an info hash', () async {
    final downloads = _RetryingDownloadService();
    final credentials = _MemoryCredentials()
      ..value = const StoredConnections(torBoxToken: 'token');
    final torBox = _FakeTorBoxClient();
    final controller = TorBridgeController(
      downloads,
      _FakeBridge(),
      credentials,
      CinemetaClient(),
      AioStreamsClient(),
      _MemoryStateStore(),
      (_) => torBox,
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    controller.selectTitle(_seriesTitle);
    controller.selectVideo(_seriesEpisodes[2]);

    await controller.downloadCandidate(_urlOnlyCandidate);

    expect(torBox.searchedTitle, 'Test Series');
    expect(torBox.searchedEpisodeCode, 'S01E03');
    expect(torBox.requestedTorrentId, 99);
    expect(torBox.requestedFileId, 3);
    expect(downloads.urls, [
      Uri.parse('https://torrentio.example/broken'),
      Uri.parse('https://torbox.example/fresh'),
    ]);
    expect(controller.state.downloads.single.status, DownloadStatus.complete);
  });

  test('season batch queues each selected episode once', () async {
    final downloads = _RecordingDownloadService();
    final credentials = _MemoryCredentials()
      ..value = const StoredConnections(
        aioManifestUrl: 'https://aio.example/manifest.json',
        torBoxToken: 'token',
      );
    final controller = TorBridgeController(
      downloads,
      _FakeBridge(),
      credentials,
      CinemetaClient(),
      _BulkAioStreamsClient(),
      _MemoryStateStore(),
    );
    addTearDown(controller.dispose);
    await controller.initialize();

    final result = await controller.downloadEpisodes(_seriesTitle, [
      _seriesEpisodes[1],
      _seriesEpisodes[0],
      _seriesEpisodes[1],
    ]);
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(result.queued, 2);
    expect(result.alreadyAdded, 0);
    expect(result.noEligibleSource, 0);
    expect(controller.state.downloads.map((job) => job.videoId).toSet(), {
      'tt-series:1:1',
      'tt-series:1:2',
    });

    final repeated = await controller.downloadEpisodes(_seriesTitle, [
      _seriesEpisodes.first,
    ]);
    expect(repeated.queued, 0);
    expect(repeated.alreadyAdded, 1);
  });

  test(
    'season batch automatically falls back to direct TorBox files',
    () async {
      final downloads = _BatchFallbackDownloadService();
      final credentials = _MemoryCredentials()
        ..value = const StoredConnections(
          aioManifestUrl: 'https://aio.example/manifest.json',
          torBoxToken: 'token',
        );
      final torBox = _ProvisioningTorBoxClient();
      final controller = TorBridgeController(
        downloads,
        _FakeBridge(),
        credentials,
        CinemetaClient(),
        _BulkAioStreamsClient(),
        _MemoryStateStore(),
        (_) => torBox,
      );
      addTearDown(controller.dispose);
      await controller.initialize();

      final result = await controller.downloadEpisodes(_seriesTitle, [
        _seriesEpisodes[0],
        _seriesEpisodes[1],
      ]);
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(result.queued, 2);
      expect(controller.state.downloads, hasLength(2));
      expect(
        controller.state.downloads.map((job) => job.status),
        everyElement(DownloadStatus.complete),
      );
      expect(torBox.searchedEpisodeCodes, isEmpty);
      expect(torBox.ensureCalls, 2);
      expect(torBox.addCalls, 1);
      expect(
        downloads.urls
            .where((url) => url.host == 'torbox.example')
            .map((url) => url.path)
            .toSet(),
        {'/fresh-1', '/fresh-2'},
      );
    },
  );
}

const _seriesEpisodes = <CatalogVideo>[
  CatalogVideo(id: 'tt-series:1:1', title: 'Pilot', season: 1, episode: 1),
  CatalogVideo(id: 'tt-series:1:2', title: 'Second', season: 1, episode: 2),
  CatalogVideo(id: 'tt-series:1:3', title: 'Third', season: 1, episode: 3),
];

const _seriesTitle = CatalogTitle(
  id: 'tt-series',
  type: 'series',
  name: 'Test Series',
  year: 2026,
  summary: 'A test series.',
  genre: 'Drama',
  color: 0xFF000000,
  videos: _seriesEpisodes,
);

final _fallbackCandidate = StreamCandidate(
  id: 'fallback-source',
  addonName: 'AIOStreams',
  displayName: 'Episode.1080p.HEVC',
  description: '',
  resolution: VideoResolution.fullHd1080,
  codec: VideoCodec.hevc,
  hdr: HdrFormat.sdr,
  cacheStatus: CacheStatus.cached,
  audioLanguages: {'English'},
  subtitleLanguages: {},
  sizeBytes: 500000000,
  releaseTags: {'bluray'},
  streamUrl: Uri.parse('https://streams.example/stale'),
  infoHash: '0123456789abcdef0123456789abcdef01234567',
  fileIndex: 0,
  requestHeaders: {'Referer': 'https://source.example/'},
);

final _urlOnlyCandidate = StreamCandidate(
  id: 'url-only-source',
  addonName: 'Torrentio TB',
  displayName: 'Test.Series.S01E03.1080p.HEVC',
  description: '',
  resolution: VideoResolution.fullHd1080,
  codec: VideoCodec.hevc,
  hdr: HdrFormat.sdr,
  cacheStatus: CacheStatus.cached,
  audioLanguages: {'English'},
  subtitleLanguages: {},
  sizeBytes: 500000000,
  releaseTags: {'webdl'},
  streamUrl: Uri.parse('https://torrentio.example/broken'),
);

class _DestinationConflictService extends DownloadService {
  int calls = 0;
  final retryStarted = Completer<void>();
  final release = Completer<void>();

  @override
  Future<String> download({
    required String jobId,
    required Uri url,
    required String suggestedName,
    required DownloadProgressCallback onProgress,
    DownloadEnqueuedCallback? onEnqueued,
    Map<String, String> requestHeaders = const {},
  }) async {
    calls++;
    if (calls == 1) throw const DownloadFailureException(1008);
    retryStarted.complete();
    await release.future;
    return 'C:/TorBridge/retained.mp4';
  }
}

class _RecordingDownloadService extends DownloadService {
  final List<String> deleted = [];
  final List<Uri> urls = [];

  @override
  Future<String> download({
    required String jobId,
    required Uri url,
    required String suggestedName,
    required DownloadProgressCallback onProgress,
    DownloadEnqueuedCallback? onEnqueued,
    Map<String, String> requestHeaders = const {},
  }) async {
    urls.add(url);
    onEnqueued?.call(jobId);
    onProgress(1, 1);
    return 'C:\\TorBridge\\episode.mp4';
  }

  @override
  Future<void> delete(String localPath) async => deleted.add(localPath);
}

class _RetryingDownloadService extends DownloadService {
  final List<Uri> urls = [];
  final List<String?> cancelledPlatformIds = [];
  final List<Map<String, String>> headers = [];

  @override
  Future<String> download({
    required String jobId,
    required Uri url,
    required String suggestedName,
    required DownloadProgressCallback onProgress,
    DownloadEnqueuedCallback? onEnqueued,
    Map<String, String> requestHeaders = const {},
  }) async {
    urls.add(url);
    headers.add(requestHeaders);
    if (urls.length == 1) {
      onEnqueued?.call('direct-id');
      throw const DownloadFailureException(502);
    }
    onEnqueued?.call('fallback-id');
    onProgress(1, 1);
    return 'C:\\TorBridge\\episode.mkv';
  }

  @override
  Future<void> cancel({required String jobId, String? platformId}) async {
    cancelledPlatformIds.add(platformId);
  }
}

class _FakeTorBoxClient extends TorBoxClient {
  _FakeTorBoxClient() : super('token');

  int? requestedTorrentId;
  int? requestedFileId;
  String? searchedTitle;
  String? searchedEpisodeCode;
  final List<String> searchedEpisodeCodes = [];

  @override
  Future<TorBoxTorrent> ensureTorrent({
    required String infoHash,
    bool cachedOnly = true,
  }) async => const TorBoxTorrent(
    id: 42,
    hash: '0123456789abcdef0123456789abcdef01234567',
    name: 'Episode',
    files: [TorBoxFile(id: 7, name: 'episode.mkv', size: 500000000)],
  );

  @override
  Future<TorBoxFileSelection?> findVideoFile({
    required String title,
    String? episodeCode,
    int? year,
  }) async {
    searchedTitle = title;
    searchedEpisodeCode = episodeCode;
    if (episodeCode != null) searchedEpisodeCodes.add(episodeCode);
    final episode =
        int.tryParse(
          RegExp(
                r'e(\d+)',
                caseSensitive: false,
              ).firstMatch(episodeCode ?? '')?.group(1) ??
              '',
        ) ??
        1;
    final filename = 'Test.Series.${episodeCode ?? 'S01E01'}.mkv';
    return TorBoxFileSelection(
      torrent: TorBoxTorrent(
        id: 99,
        hash: 'season-pack',
        name: 'Test Series Season 1',
        files: [TorBoxFile(id: episode, name: filename, size: 500000000)],
      ),
      file: TorBoxFile(id: episode, name: filename, size: 500000000),
    );
  }

  @override
  Future<Uri> requestDownloadLink({
    required int torrentId,
    required int fileId,
  }) async {
    requestedTorrentId = torrentId;
    requestedFileId = fileId;
    return Uri.parse('https://torbox.example/fresh');
  }
}

class _ProvisioningTorBoxClient extends TorBoxClient {
  _ProvisioningTorBoxClient() : super('token');

  bool added = false;
  int ensureCalls = 0;
  int addCalls = 0;
  final List<String> searchedEpisodeCodes = [];

  TorBoxTorrent get _seasonPack => const TorBoxTorrent(
    id: 501,
    hash: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    name: 'Test Series Season 1 Complete',
    files: [
      TorBoxFile(id: 1, name: 'Test.Series.S01E01.mkv', size: 500000000),
      TorBoxFile(id: 2, name: 'Test.Series.S01E02.mkv', size: 500000000),
      TorBoxFile(id: 3, name: 'Test.Series.S01E03.mkv', size: 500000000),
    ],
  );

  @override
  Future<TorBoxFileSelection?> findVideoFile({
    required String title,
    String? episodeCode,
    int? year,
  }) async {
    if (episodeCode != null) searchedEpisodeCodes.add(episodeCode);
    if (!added || episodeCode == null) return null;
    final file = _seasonPack.episodeFile(episodeCode);
    return file == null
        ? null
        : TorBoxFileSelection(torrent: _seasonPack, file: file);
  }

  @override
  Future<TorBoxTorrent> ensureTorrent({
    required String infoHash,
    bool cachedOnly = true,
  }) async {
    ensureCalls++;
    if (!added) addCalls++;
    added = true;
    return _seasonPack;
  }

  @override
  Future<TorBoxTorrent> waitForFiles(
    TorBoxTorrent torrent, {
    int attempts = 12,
    Duration interval = const Duration(seconds: 1),
  }) async => torrent;

  @override
  Future<Uri> requestDownloadLink({
    required int torrentId,
    required int fileId,
  }) async => Uri.parse('https://torbox.example/fresh-$fileId');
}

class _FailTwiceDownloadService extends DownloadService {
  final List<Uri> urls = [];

  @override
  Future<String> download({
    required String jobId,
    required Uri url,
    required String suggestedName,
    required DownloadProgressCallback onProgress,
    DownloadEnqueuedCallback? onEnqueued,
    Map<String, String> requestHeaders = const {},
  }) async {
    urls.add(url);
    onEnqueued?.call('attempt-${urls.length}');
    if (urls.length <= 2) throw const DownloadFailureException(502);
    onProgress(1, 1);
    return 'C:\\TorBridge\\alternative.mkv';
  }
}

class _BatchFallbackDownloadService extends DownloadService {
  final List<Uri> urls = [];

  @override
  Future<String> download({
    required String jobId,
    required Uri url,
    required String suggestedName,
    required DownloadProgressCallback onProgress,
    DownloadEnqueuedCallback? onEnqueued,
    Map<String, String> requestHeaders = const {},
  }) async {
    urls.add(url);
    onEnqueued?.call('$jobId-${urls.length}');
    if (url.host == 'streams.example') {
      throw const DownloadFailureException(502);
    }
    onProgress(1, 1);
    return 'C:\\TorBridge\\$suggestedName';
  }

  @override
  Future<void> cancel({required String jobId, String? platformId}) async {}
}

class _RefreshingAioStreamsClient extends AioStreamsClient {
  @override
  Future<List<StreamCandidate>> getStreams({
    required Uri manifestUrl,
    required String type,
    required String videoId,
  }) async => [
    StreamCandidate(
      id: 'refreshed-source',
      addonName: _fallbackCandidate.addonName,
      displayName: _fallbackCandidate.displayName,
      description: _fallbackCandidate.description,
      resolution: _fallbackCandidate.resolution,
      codec: _fallbackCandidate.codec,
      hdr: _fallbackCandidate.hdr,
      cacheStatus: _fallbackCandidate.cacheStatus,
      audioLanguages: _fallbackCandidate.audioLanguages,
      subtitleLanguages: _fallbackCandidate.subtitleLanguages,
      sizeBytes: _fallbackCandidate.sizeBytes,
      releaseTags: _fallbackCandidate.releaseTags,
      streamUrl: Uri.parse('https://streams.example/refreshed'),
      requestHeaders: const {'User-Agent': 'Stremio'},
    ),
  ];
}

class _AlternativeAioStreamsClient extends AioStreamsClient {
  @override
  Future<List<StreamCandidate>> getStreams({
    required Uri manifestUrl,
    required String type,
    required String videoId,
  }) async => [
    ...(await _RefreshingAioStreamsClient().getStreams(
      manifestUrl: manifestUrl,
      type: type,
      videoId: videoId,
    )),
    StreamCandidate(
      id: 'alternative-source',
      addonName: 'Alternative',
      displayName: 'Alternative.1080p.HEVC',
      description: '',
      resolution: VideoResolution.fullHd1080,
      codec: VideoCodec.hevc,
      hdr: HdrFormat.sdr,
      cacheStatus: CacheStatus.cached,
      audioLanguages: {'English'},
      subtitleLanguages: {},
      sizeBytes: 400000000,
      releaseTags: {'bluray'},
      streamUrl: Uri.parse('https://alternative.example/video'),
      filename: 'alternative.mkv',
    ),
  ];
}

class _LegacyTorrentioAioStreamsClient extends AioStreamsClient {
  @override
  Future<List<StreamCandidate>> getStreams({
    required Uri manifestUrl,
    required String type,
    required String videoId,
  }) async => [
    StreamCandidate(
      id: 'legacy-torrentio-source',
      addonName: _fallbackCandidate.addonName,
      displayName: _fallbackCandidate.displayName,
      description: _fallbackCandidate.description,
      resolution: _fallbackCandidate.resolution,
      codec: _fallbackCandidate.codec,
      hdr: _fallbackCandidate.hdr,
      cacheStatus: _fallbackCandidate.cacheStatus,
      audioLanguages: _fallbackCandidate.audioLanguages,
      subtitleLanguages: _fallbackCandidate.subtitleLanguages,
      sizeBytes: _fallbackCandidate.sizeBytes,
      releaseTags: _fallbackCandidate.releaseTags,
      streamUrl: Uri.parse('https://torrentio.stremio.ru/playback/file'),
      filename: _fallbackCandidate.filename,
    ),
  ];
}

class _BulkAioStreamsClient extends AioStreamsClient {
  @override
  Future<List<StreamCandidate>> getStreams({
    required Uri manifestUrl,
    required String type,
    required String videoId,
  }) async => [
    StreamCandidate(
      id: 'source-$videoId',
      addonName: 'Test source',
      displayName: '$videoId.1080p.HEVC',
      description: '1080p HEVC English Cached',
      resolution: VideoResolution.fullHd1080,
      codec: VideoCodec.hevc,
      hdr: HdrFormat.sdr,
      cacheStatus: CacheStatus.cached,
      audioLanguages: const {'English'},
      subtitleLanguages: const {'English'},
      sizeBytes: 500000000,
      releaseTags: const {'webdl'},
      streamUrl: Uri.parse('https://streams.example/$videoId'),
      infoHash: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      fileIndex: int.parse(videoId.split(':').last) - 1,
      filename: '$videoId.mkv',
    ),
  ];
}

class _FakeBridge extends StremioBridgeService {
  List<StremioBridgeEntry> lastEntries = [];
  @override
  Future<bool> ping() async => true;

  @override
  Future<void> start(List<StremioBridgeEntry> entries) async {
    lastEntries = entries;
  }

  @override
  Future<void> stop() async {}

  @override
  Future<void> update(List<StremioBridgeEntry> entries) async {
    lastEntries = entries;
  }
}

class _ResolvingDownloadService extends _RecordingDownloadService {
  _ResolvingDownloadService(this.path);
  String? path;
  String? warning;
  @override
  String? localFileWarning(String path) => warning;
  final checkedIds = <String?>[];

  @override
  Future<String?> resolveLocalPath({
    String? localPath,
    String? platformId,
  }) async {
    checkedIds.add(platformId);
    return path;
  }
}

class _EmptyCredentials implements CredentialStore {
  @override
  Future<void> clear() async {}

  @override
  Future<StoredConnections> read() async => const StoredConnections();

  @override
  Future<void> save({
    required String aioManifestUrl,
    required String torBoxToken,
    required String traktClientId,
    required String traktClientSecret,
  }) async {}

  @override
  Future<void> saveTraktTokens({
    required String accessToken,
    required String refreshToken,
  }) async {}

  @override
  Future<void> saveAll(StoredConnections connections) async {}
}

class _MemoryCredentials implements CredentialStore {
  StoredConnections value = const StoredConnections();

  @override
  Future<void> clear() async => value = const StoredConnections();

  @override
  Future<StoredConnections> read() async => value;

  @override
  Future<void> save({
    required String aioManifestUrl,
    required String torBoxToken,
    required String traktClientId,
    required String traktClientSecret,
  }) async {}

  @override
  Future<void> saveAll(StoredConnections connections) async {
    value = connections;
  }

  @override
  Future<void> saveTraktTokens({
    required String accessToken,
    required String refreshToken,
  }) async {}
}

class _MemoryStateStore implements LocalStateStore {
  StoredLocalState value = const StoredLocalState();

  @override
  Future<StoredLocalState> read() async => value;

  @override
  Future<void> saveDownloadRecords(List<Map<String, dynamic>> records) async {
    value = StoredLocalState(
      preferences: value.preferences,
      watchedTitleIds: value.watchedTitleIds,
      downloadRecords: records,
    );
  }

  @override
  Future<void> savePreferences(DownloadPreferences preferences) async {
    value = StoredLocalState(
      preferences: preferences,
      watchedTitleIds: value.watchedTitleIds,
      downloadRecords: value.downloadRecords,
    );
  }

  @override
  Future<void> saveWatched(Set<String> titleIds) async {
    value = StoredLocalState(
      preferences: value.preferences,
      watchedTitleIds: titleIds,
      downloadRecords: value.downloadRecords,
    );
  }
}
