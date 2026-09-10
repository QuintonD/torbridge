import 'dart:convert';

import 'package:torbridge/domain/watched_entry.dart';

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:torbridge/domain/stream_parser.dart';
import 'package:torbridge/integrations/trakt_client.dart';
import 'package:torbridge/features/library/library_screen.dart';

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
  auditProbes();
  downloadRecoveryRegressions();
  for (final schema in [2, 3]) {
    test(
      'saved error migration distinguishes old and new records: $schema',
      () async {
        final store = _MemoryStateStore()
          ..value = StoredLocalState(
            downloadRecords: [
              {
                'schema': schema,
                'id': 'saved',
                'title': 'Saved movie',
                'status': 'failed',
                'error': 'the file already exists',
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
        final controller = TorBridgeController(
          _RecordingDownloadService(),
          _FakeBridge(),
          _EmptyCredentials(),
          CinemetaClient(),
          AioStreamsClient(),
          store,
        );
        addTearDown(controller.dispose);
        await controller.initialize();
        expect(
          controller.state.downloads.single.error,
          schema == 2
              ? contains('could not resume')
              : 'the file already exists',
        );
        expect(controller.state.downloads.single.platformId, '1986');
      },
    );
  }

  for (final cancel in [false, true]) {
    testWidgets(
      'slow retry lookup is bounded and respects cancellation: $cancel',
      (tester) async {
        final service = _DestinationConflictService();
        final addon = _SlowAioStreamsClient();
        final credentials = _MemoryCredentials()
          ..value = const StoredConnections(
            aioManifestUrl: 'https://aio.example/manifest.json',
            torBoxToken: 'token',
          );
        final controller = TorBridgeController(
          service,
          _FakeBridge(),
          credentials,
          CinemetaClient(),
          addon,
          _MemoryStateStore(),
        );
        await controller.initialize();
        await controller.downloadCandidate(_fallbackCandidate);
        addon.slow = true;
        service.release.complete();
        final retry = controller.retryDownload(
          controller.state.downloads.single,
        );
        await tester.pump();
        expect(controller.state.downloads.single.status, DownloadStatus.queued);
        expect(service.cancelled, ['failed-attempt']);
        if (cancel) {
          await controller.cancelDownload(controller.state.downloads.single);
        }
        await tester.pump(const Duration(seconds: 31));
        await retry;
        expect(service.calls, cancel ? 1 : 2);
        if (cancel) {
          expect(controller.state.downloads, isEmpty);
        } else {
          expect(
            controller.state.downloads.single.status,
            DownloadStatus.complete,
          );
        }
        // A response arriving after timeout must never start another transfer.
        addon.response.complete([]);
        await tester.pump();
        expect(service.calls, cancel ? 1 : 2);
        controller.dispose();
      },
    );
  }

  test('failed file deletion keeps the download record', () async {
    final service = _UndeletableDownloadService();
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
    await controller.deleteDownload(controller.state.downloads.single);
    expect(controller.state.downloads, hasLength(1));
    expect(controller.state.notice, contains('Could not delete'));
  });

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
    expect(service.cancelled, ['failed-attempt']);
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

  for (final reason in [400, 502, 1008]) {
    test('Android failure $reason retries with a fresh TorBox link', () async {
      final downloads = _RetryingDownloadService(reason);
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
  }

  test('Android HTTP reason is rendered as a useful error', () {
    const error = DownloadFailureException(502);

    expect(error.isRetryableSourceFailure, isTrue);
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
  final List<String?> cancelled = [];
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
    if (calls == 1) {
      onEnqueued?.call('failed-attempt');
      throw const DownloadFailureException(1009);
    }
    retryStarted.complete();
    await release.future;
    return 'C:/TorBridge/retained.mp4';
  }

  @override
  Future<void> cancel({required String jobId, String? platformId}) async {
    cancelled.add(platformId);
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

class _UndeletableDownloadService extends _RecordingDownloadService {
  @override
  Future<void> delete(String localPath) async =>
      throw StateError('File is locked.');
}

class _SlowAioStreamsClient extends AioStreamsClient {
  bool slow = false;
  final response = Completer<List<StreamCandidate>>();

  @override
  Future<List<StreamCandidate>> getStreams({
    required Uri manifestUrl,
    required String type,
    required String videoId,
  }) async => slow ? response.future : [_fallbackCandidate];

  @override
  Future<List<StreamCandidate>> getTorrentioStreams({
    required String type,
    required String videoId,
  }) async => [];
}

class _RetryingDownloadService extends DownloadService {
  _RetryingDownloadService([this.reason = 502]);
  final int reason;
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
      throw DownloadFailureException(reason);
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
      historyRecords: value.historyRecords,
      preferences: value.preferences,
      watchedTitleIds: value.watchedTitleIds,
      downloadRecords: records,
    );
  }

  @override
  Future<void> savePreferences(DownloadPreferences preferences) async {
    value = StoredLocalState(
      historyRecords: value.historyRecords,
      preferences: preferences,
      watchedTitleIds: value.watchedTitleIds,
      downloadRecords: value.downloadRecords,
    );
  }

  @override
  Future<void> saveHistory(List<Map<String, dynamic>> records) async {
    value = StoredLocalState(
      preferences: value.preferences,
      watchedTitleIds: value.watchedTitleIds,
      downloadRecords: value.downloadRecords,
      historyRecords: records,
    );
  }

  @override
  Future<void> saveWatched(Set<String> titleIds) async {
    value = StoredLocalState(
      historyRecords: value.historyRecords,
      preferences: value.preferences,
      watchedTitleIds: titleIds,
      downloadRecords: value.downloadRecords,
    );
  }
}

void auditProbes() {
  test('AUDIT initial torrent download validates the requested episode instead of the index', () async {
    final service = _RecordingDownloadService();
    final credentials = _MemoryCredentials()
      ..value = const StoredConnections(torBoxToken: 'fixture');
    final controller = TorBridgeController(
      service,
      _FakeBridge(),
      credentials,
      CinemetaClient(),
      AioStreamsClient(),
      _MemoryStateStore(),
      (_) => _ProvisioningTorBoxClient(),
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    controller.selectTitle(_seriesTitle);
    controller.selectVideo(_seriesEpisodes[1]);
    await controller.downloadCandidate(
      const StreamCandidate(
        id: 'pack',
        addonName: 'Fixture',
        displayName: 'Season pack',
        description: '',
        resolution: VideoResolution.fullHd1080,
        codec: VideoCodec.hevc,
        hdr: HdrFormat.sdr,
        cacheStatus: CacheStatus.cached,
        audioLanguages: {'English'},
        subtitleLanguages: {},
        sizeBytes: 500000000,
        releaseTags: {},
        infoHash: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        fileIndex: 0,
      ),
    );
    expect(service.urls.single.path, '/fresh-2');
    expect(controller.state.downloads.single.mediaVideo?.code, 'S01E02');
  });

  test('AUDIT metadata distinguishes positive labels and binary units', () {
    const parser = StreamParser();
    for (final label in [
      'Not cached',
      'Uncached',
      'Needs caching',
      'Not instantly cached',
    ]) {
      expect(
        parser.parseStream({'title': label}).cacheStatus,
        CacheStatus.uncached,
      );
    }
    for (final label in ['Cached', 'Instant']) {
      expect(
        parser.parseStream({'title': label}).cacheStatus,
        CacheStatus.cached,
      );
    }
    expect(parser.parseStream({'title': '1 MiB'}).sizeBytes, 1048576);
    expect(parser.parseStream({'title': '1 MB'}).sizeBytes, 1000000);
    expect(parser.parseStream({'title': '10 GB'}).sizeBytes, 10000000000);
    expect(parser.parseStream({'title': 'HDR10'}).hdr, HdrFormat.hdr10);
    expect(
      parser.parseStream({'title': 'HDR10+ HEVC'}).hdr,
      HdrFormat.hdr10Plus,
    );
  });

  test(
    'AUDIT cancellation during enqueue retires the eventual native job',
    () async {
      final service = _AuditEnqueueService();
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
      final transfer = controller.downloadCandidate(_fallbackCandidate);
      await service.entered.future;
      final cancelling = controller.cancelDownload(
        controller.state.downloads.single,
      );
      await Future<void>.delayed(Duration.zero);
      service.allowEnqueue.complete();
      await cancelling;
      expect(service.cancelled, contains('native-new'));
      expect(controller.state.downloads, isEmpty);
      service.finish.complete();
      await transfer;
      expect(controller.state.downloads, isEmpty);
    },
  );

  test(
    'AUDIT history metadata survives restart without any download record',
    () async {
      SharedPreferences.setMockInitialValues({});
      final store = SharedPreferencesLocalStateStore();
      final first = TorBridgeController(
        _RecordingDownloadService(),
        _FakeBridge(),
        _EmptyCredentials(),
        CinemetaClient(),
        AioStreamsClient(),
        store,
      );
      await first.initialize();
      final title = _auditTitle('A real catalog title');
      await first.scrobble(
        title: title,
        action: TraktScrobbleAction.stop,
        progress: 100,
      );
      first.dispose();
      final second = TorBridgeController(
        _RecordingDownloadService(),
        _FakeBridge(),
        _EmptyCredentials(),
        CinemetaClient(),
        AioStreamsClient(),
        SharedPreferencesLocalStateStore(),
      );
      addTearDown(second.dispose);
      await second.initialize();
      expect(second.state.downloads, isEmpty);
      expect(second.state.watchedTitleIds, contains(title.id));
      expect(second.state.watchedHistory[title.id]?.title.name, title.name);
    },
  );

  test('AUDIT Trakt failure preserves local completion and toggles target the supplied ID in order', () async {
    final trakt = _AuditTrakt();
    final credentials = _MemoryCredentials()
      ..value = const StoredConnections(
        traktClientId: 'fixture',
        traktClientSecret: 'fixture',
        traktAccessToken: 'fixture',
      );
    final controller = TorBridgeController(
      _RecordingDownloadService(),
      _FakeBridge(),
      credentials,
      CinemetaClient(),
      AioStreamsClient(),
      _MemoryStateStore(),
      null,
      (_, _) => trakt,
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.scrobble(
      title: controller.state.selectedTitle,
      action: TraktScrobbleAction.stop,
      progress: 100,
    );
    expect(
      controller.state.watchedTitleIds,
      contains(controller.state.selectedTitle.id),
    );
    controller.toggleWatched('tt1234567:2:3');
    controller.toggleWatched('tt1234567:2:3');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(trakt.changes, ['tt1234567:2:3:true', 'tt1234567:2:3:false']);
    trakt.remote = {'tt1234567:2:3': WatchedEntry.placeholder('tt1234567:2:3')};
    await controller.syncTraktWatched();
    expect(controller.state.watchedTitleIds, isNot(contains('tt1234567:2:3')));
    expect(
      controller.state.watchedTitleIds,
      contains(controller.state.selectedTitle.id),
    );
  });

  test('AUDIT clearing search invalidates a pending result', () async {
    final catalog = _AuditCatalog();
    final controller = TorBridgeController(
      _RecordingDownloadService(),
      _FakeBridge(),
      _EmptyCredentials(),
      catalog,
      AioStreamsClient(),
      _MemoryStateStore(),
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    final pending = controller.searchCatalog('old');
    await controller.searchCatalog('');
    catalog.oldResult.complete([_auditTitle('Old query')]);
    await pending;
    expect(controller.state.catalogTitles, demoTitles);
    expect(controller.state.busy, isFalse);
  });

  test(
    'AUDIT unreadable individual download records survive later saves',
    () async {
      final store = _MemoryStateStore()
        ..value = const StoredLocalState(
          downloadRecords: [
            {
              'id': 'legacy-unreadable',
              'source': 'bad-shape',
              'localPath': '/precious/video.mp4',
            },
          ],
        );
      final controller = TorBridgeController(
        _RecordingDownloadService(),
        _FakeBridge(),
        _EmptyCredentials(),
        CinemetaClient(),
        AioStreamsClient(),
        store,
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      await controller.downloadCandidate(_fallbackCandidate);
      expect(
        store.value.downloadRecords.any(
          (record) => record['id'] == 'legacy-unreadable',
        ),
        isTrue,
      );
    },
  );

  test('AUDIT episode index must not select a different episode', () {
    const pack = TorBoxTorrent(
      id: 1,
      hash: 'fixture',
      name: 'Series',
      files: [
        TorBoxFile(id: 1, name: 'Series.S01E01.mkv', size: 200),
        TorBoxFile(id: 2, name: 'Series.S01E02.mkv', size: 100),
      ],
    );
    expect(pack.episodeFile('S01E02', 99)?.id, 2);
  });
  test('AUDIT episode names require numeric boundaries', () {
    const pack = TorBoxTorrent(
      id: 1,
      hash: 'fixture',
      name: 'Series',
      files: [TorBoxFile(id: 10, name: 'Series.S01E010.mkv', size: 100)],
    );
    expect(pack.episodeFile('S01E01'), isNull);
  });
  test('AUDIT not cached must not be instantly cached', () {
    final source = const StreamParser().parseStream({
      'name': 'Provider',
      'title': 'Movie 1080p HEVC English Not cached',
    });
    expect(source.cacheStatus, isNot(CacheStatus.cached));
  });
  test('AUDIT binary file units must respect a hard size limit', () {
    final source = const StreamParser().parseStream({'title': 'Movie 10 GiB'});
    expect(source.sizeBytes, 10737418240);
  });
  test('AUDIT HDR10 plus must retain its format', () {
    final source = const StreamParser().parseStream({'title': 'Movie HDR10+'});
    expect(source.hdr, HdrFormat.hdr10Plus);
  });
  test(
    'AUDIT finishing playback without Trakt records local watched state',
    () async {
      final controller = TorBridgeController(
        _RecordingDownloadService(),
        _FakeBridge(),
        _EmptyCredentials(),
        CinemetaClient(),
        AioStreamsClient(),
        _MemoryStateStore(),
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      await controller.scrobble(
        title: controller.state.selectedTitle,
        action: TraktScrobbleAction.stop,
        progress: 100,
      );
      expect(
        controller.state.watchedTitleIds,
        contains(controller.state.selectedTitle.id),
      );
    },
  );
  test(
    'AUDIT late search response must not overwrite the newest search',
    () async {
      final catalog = _AuditCatalog();
      final controller = TorBridgeController(
        _RecordingDownloadService(),
        _FakeBridge(),
        _EmptyCredentials(),
        catalog,
        AioStreamsClient(),
        _MemoryStateStore(),
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      final first = controller.searchCatalog('old');
      final second = controller.searchCatalog('new');
      catalog.newResult.complete([_auditTitle('New query')]);
      await second;
      catalog.oldResult.complete([_auditTitle('Old query')]);
      await first;
      expect(controller.state.catalogTitles.single.name, 'New query');
    },
  );
  test(
    'AUDIT corrupt preferences must not allow old download records to be lost',
    () async {
      SharedPreferences.setMockInitialValues({
        'download_preferences_v1': '{broken',
        'completed_downloads_v1': jsonEncode([
          {
            'id': 'old-record',
            'title': 'Existing video',
            'status': 'failed',
            'mediaTitle': {
              'id': 'tt12345',
              'type': 'movie',
              'name': 'Existing video',
            },
            'source': {
              'addonName': 'Test',
              'displayName': 'Existing video',
              'description': '',
            },
          },
        ]),
      });
      final controller = TorBridgeController(
        _RecordingDownloadService(),
        _FakeBridge(),
        _EmptyCredentials(),
        CinemetaClient(),
        AioStreamsClient(),
        SharedPreferencesLocalStateStore(),
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      await controller.downloadCandidate(_fallbackCandidate);
      final saved = (await SharedPreferences.getInstance()).getString(
        'completed_downloads_v1',
      )!;
      expect(saved, contains('old-record'));
    },
  );
  test('AUDIT cancellation uses the latest platform download ID', () async {
    final service = _AuditEnqueueService();
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
    final transfer = controller.downloadCandidate(_fallbackCandidate);
    await service.entered.future;
    final staleCard = controller.state.downloads.single;
    service.allowEnqueue.complete();
    await service.enqueued.future;
    expect(controller.state.downloads.single.platformId, 'native-new');
    await controller.cancelDownload(staleCard);
    service.finish.complete();
    await transfer;
    expect(service.cancelled, contains('native-new'));
  });
  testWidgets(
    'AUDIT watched library includes non-demo titles without local files',
    (tester) async {
      final controller = TorBridgeController(
        _RecordingDownloadService(),
        _FakeBridge(),
        _EmptyCredentials(),
        CinemetaClient(),
        AioStreamsClient(),
        _MemoryStateStore(),
      );
      await controller.initialize();
      controller.toggleWatched('tt1234567');
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            torBridgeControllerProvider.overrideWith((ref) => controller),
          ],
          child: const MaterialApp(home: Scaffold(body: LibraryScreen())),
        ),
      );
      await tester.pump();
      expect(find.text('Your viewing history starts here'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );
  test('AUDIT concurrent Windows downloads must use distinct files', () async {
    final dir = await Directory.systemTemp.createTemp('torbridge-audit-');
    final oldPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _AuditPaths(dir.path);
    final dio = Dio()..httpClientAdapter = _AuditHttpAdapter();
    final service = DioDownloadService(dio: dio);
    try {
      final paths = await Future.wait([
        for (final id in ['one', 'two'])
          service.download(
            jobId: id,
            url: Uri.parse('https://fixture.invalid/$id'),
            suggestedName: 'same.mp4',
            onProgress: (_, _) {},
          ),
      ]);
      expect(paths.toSet(), hasLength(2));
      expect(await File(paths[0]).readAsString(), '/one');
      expect(await File(paths[1]).readAsString(), '/two');
    } finally {
      PathProviderPlatform.instance = oldPaths;
      dio.close(force: true);
      await dir.delete(recursive: true);
    }
  }, skip: !Platform.isWindows);
}

CatalogTitle _auditTitle(String name) => CatalogTitle(
  id: name,
  type: 'movie',
  name: name,
  year: 2026,
  summary: '',
  genre: '',
  color: 0xFF000000,
);

class _AuditCatalog extends CinemetaClient {
  final oldResult = Completer<List<CatalogTitle>>();
  final newResult = Completer<List<CatalogTitle>>();
  @override
  Future<List<CatalogTitle>> search(String query) =>
      query == 'old' ? oldResult.future : newResult.future;
}

class _AuditEnqueueService extends DownloadService {
  final entered = Completer<void>();
  final allowEnqueue = Completer<void>();
  final enqueued = Completer<void>();
  final finish = Completer<void>();
  final cancelled = <String?>[];
  @override
  Future<String> download({
    required String jobId,
    required Uri url,
    required String suggestedName,
    required DownloadProgressCallback onProgress,
    DownloadEnqueuedCallback? onEnqueued,
    Map<String, String> requestHeaders = const {},
  }) async {
    entered.complete();
    await allowEnqueue.future;
    onEnqueued?.call('native-new');
    enqueued.complete();
    await finish.future;
    return '/fixture/movie.mp4';
  }

  @override
  Future<void> cancel({required String jobId, String? platformId}) async =>
      cancelled.add(platformId);
}

class _AuditPaths extends PathProviderPlatform {
  _AuditPaths(this.path);
  final String path;
  @override
  Future<String?> getDownloadsPath() async => path;
}

class _AuditHttpAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    await Future<void>.delayed(const Duration(milliseconds: 50));
    return ResponseBody.fromString(options.uri.path, 200);
  }

  @override
  void close({bool force = false}) {}
}

Map<String, dynamic> _savedTransfer(String id, {String? platformId}) => {
  'schema': 3,
  'id': id,
  'title': 'Fixture $id',
  'status': platformId == null ? 'queued' : 'downloading',
  'platformId': platformId,
  'progress': 0,
  'mediaTitle': {'id': 'fixture-$id', 'type': 'movie', 'name': 'Fixture $id'},
  'source': {
    'id': id,
    'addonName': 'Fixture',
    'displayName': 'fixture.mp4',
    'description': '',
    'infoHash': '0123456789abcdef0123456789abcdef01234567',
    'sizeBytes': 500000000,
  },
};

class _SerialFixtureDownloads extends _RecordingDownloadService {
  final transfers = <String, Completer<String>>{};
  final restored = <String, Completer<String>>{};
  int? resumeFailure;
  bool hasSpace = true;
  @override
  bool get supportsResume => true;
  @override
  int get maxConcurrentDownloads => 1;
  @override
  Future<void> checkAvailableSpace(int? expectedBytes) async {
    if (!hasSpace) throw DownloadStorageException(100, expectedBytes ?? 0);
  }

  @override
  Future<String> resume({
    required String jobId,
    required String platformId,
    required DownloadProgressCallback onProgress,
  }) async {
    if (resumeFailure != null) throw DownloadFailureException(resumeFailure!);
    return (restored[jobId] = Completer<String>()).future;
  }

  @override
  Future<String> download({
    required String jobId,
    required Uri url,
    required String suggestedName,
    required DownloadProgressCallback onProgress,
    DownloadEnqueuedCallback? onEnqueued,
    Map<String, String> requestHeaders = const {},
  }) {
    urls.add(url);
    onEnqueued?.call('new-$jobId');
    return (transfers[jobId] = Completer<String>()).future;
  }
}

class _StorageDuringRecovery extends _RecordingDownloadService {
  final cancelled = <String?>[];
  int finalFailure = 1006;
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
    throw DownloadFailureException(
      urls.length == 1 ? 400 : finalFailure,
      host: url.host,
    );
  }

  @override
  Future<void> cancel({required String jobId, String? platformId}) async {
    cancelled.add(platformId);
  }
}

void downloadRecoveryRegressions() {
  test('persistent HTTP 400 stops after bounded recovery and names the attempted host', () async {
    final service = _StorageDuringRecovery()..finalFailure = 400;
    final credentials = _MemoryCredentials()
      ..value = const StoredConnections(
        aioManifestUrl: 'https://aio.example/manifest.json',
        torBoxToken: 'token',
      );
    final controller = TorBridgeController(
      service,
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
    expect(service.urls, hasLength(3));
    expect(controller.state.downloads.single.status, DownloadStatus.failed);
    expect(controller.state.downloads.single.error, contains('HTTP 400'));
    expect(
      controller.state.downloads.single.error,
      endsWith('from torbox.example'),
    );
  });

  testWidgets('many failed restored transfers recover one at a time', (
    tester,
  ) async {
    final service = _SerialFixtureDownloads()..resumeFailure = 400;
    final store = _MemoryStateStore()
      ..value = StoredLocalState(
        downloadRecords: [
          _savedTransfer('old1', platformId: '101'),
          _savedTransfer('old2', platformId: '102'),
        ],
      );
    final credentials = _MemoryCredentials()
      ..value = const StoredConnections(torBoxToken: 'token');
    final controller = TorBridgeController(
      service,
      _FakeBridge(),
      credentials,
      CinemetaClient(),
      AioStreamsClient(),
      store,
      (_) => _FakeTorBoxClient(),
    );
    await controller.initialize();
    await tester.pump();
    expect(service.transfers.keys, ['old1']);
    expect(controller.state.downloads.last.status, DownloadStatus.queued);
    service.transfers['old1']!.complete('/old1.mp4');
    await tester.pump();
    expect(service.transfers.keys, ['old1', 'old2']);
    service.transfers['old2']!.complete('/old2.mp4');
    await tester.pump();
    expect(
      controller.state.downloads.every(
        (j) => j.status == DownloadStatus.complete,
      ),
      isTrue,
    );
    controller.dispose();
  });

  for (final reason in [400, 1008]) {
    testWidgets(
      'restored Android failure $reason recovers after credentials load',
      (tester) async {
        final service = _SerialFixtureDownloads()..resumeFailure = reason;
        final store = _MemoryStateStore()
          ..value = StoredLocalState(
            downloadRecords: [_savedTransfer('saved', platformId: 'old-id')],
          );
        final credentials = _MemoryCredentials()
          ..value = const StoredConnections(torBoxToken: 'token');
        final controller = TorBridgeController(
          service,
          _FakeBridge(),
          credentials,
          CinemetaClient(),
          AioStreamsClient(),
          store,
          (_) => _FakeTorBoxClient(),
        );
        await controller.initialize();
        await tester.pump();
        expect(service.urls, [Uri.parse('https://torbox.example/fresh')]);
        service.transfers['saved']!.complete('/fixture.mp4');
        await tester.pump();
        expect(
          controller.state.downloads.single.status,
          DownloadStatus.complete,
        );
        expect(controller.state.downloads.single.platformId, 'new-saved');
        controller.dispose();
      },
    );
  }

  testWidgets(
    'saved Android queue serializes transfers, cancels waiting jobs and rechecks space',
    (tester) async {
      final service = _SerialFixtureDownloads();
      final store = _MemoryStateStore()
        ..value = StoredLocalState(
          downloadRecords: [
            _savedTransfer('first'),
            _savedTransfer('cancelled'),
            _savedTransfer('last'),
          ],
        );
      final credentials = _MemoryCredentials()
        ..value = const StoredConnections(torBoxToken: 'token');
      final controller = TorBridgeController(
        service,
        _FakeBridge(),
        credentials,
        CinemetaClient(),
        AioStreamsClient(),
        store,
        (_) => _FakeTorBoxClient(),
      );
      await controller.initialize();
      await tester.pump();
      expect(service.transfers.keys, ['first']);
      expect(
        controller.state.downloads.where(
          (j) => j.status == DownloadStatus.queued,
        ),
        hasLength(2),
      );
      expect(
        store.value.downloadRecords.where((j) => j['status'] == 'queued'),
        hasLength(2),
      );
      await controller.cancelDownload(controller.state.downloads[1]);
      service.hasSpace = false;
      service.transfers['first']!.complete('/fixture.mp4');
      await tester.pump();
      expect(service.transfers.keys, ['first']);
      expect(controller.state.downloads.last.status, DownloadStatus.failed);
      expect(
        controller.state.downloads.last.error,
        contains('Not enough space'),
      );
      expect(service.deleted, isEmpty);
      controller.dispose();
    },
  );

  testWidgets('restored native transfers occupy queue slots until all finish', (
    tester,
  ) async {
    final service = _SerialFixtureDownloads();
    final store = _MemoryStateStore()
      ..value = StoredLocalState(
        downloadRecords: [
          _savedTransfer('old1', platformId: '101'),
          _savedTransfer('old2', platformId: '102'),
          _savedTransfer('waiting'),
        ],
      );
    final credentials = _MemoryCredentials()
      ..value = const StoredConnections(torBoxToken: 'token');
    final controller = TorBridgeController(
      service,
      _FakeBridge(),
      credentials,
      CinemetaClient(),
      AioStreamsClient(),
      store,
      (_) => _FakeTorBoxClient(),
    );
    await controller.initialize();
    await tester.pump();
    expect(service.restored.keys, ['old1', 'old2']);
    expect(service.transfers, isEmpty);
    service.restored['old1']!.complete('/old1.mp4');
    await tester.pump();
    expect(service.transfers, isEmpty);
    service.restored['old2']!.complete('/old2.mp4');
    await tester.pump();
    expect(service.transfers.keys, ['waiting']);
    service.transfers['waiting']!.complete('/waiting.mp4');
    await tester.pump();
    expect(
      controller.state.downloads.every(
        (j) => j.status == DownloadStatus.complete,
      ),
      isTrue,
    );
    controller.dispose();
  });

  test(
    'recovery stops on storage errors and preserves the failed native ID',
    () async {
      final service = _StorageDuringRecovery();
      final credentials = _MemoryCredentials()
        ..value = const StoredConnections(
          aioManifestUrl: 'https://aio.example/manifest.json',
          torBoxToken: 'token',
        );
      final torBox = _FakeTorBoxClient();
      final controller = TorBridgeController(
        service,
        _FakeBridge(),
        credentials,
        CinemetaClient(),
        _RefreshingAioStreamsClient(),
        _MemoryStateStore(),
        (_) => torBox,
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      await controller.downloadCandidate(_fallbackCandidate);
      expect(service.urls, hasLength(2));
      expect(service.cancelled, ['attempt-1']);
      expect(controller.state.downloads.single.platformId, 'attempt-2');
      expect(
        controller.state.downloads.single.error,
        contains('insufficient storage'),
      );
      expect(
        controller.state.downloads.single.error,
        isNot(contains('from streams')),
      );
      expect(torBox.requestedFileId, isNull);
    },
  );
}

class _AuditTrakt extends TraktClient {
  _AuditTrakt() : super(clientId: 'fixture', clientSecret: 'fixture');
  final changes = <String>[];
  Map<String, WatchedEntry> remote = {};
  @override
  Future<Map<String, WatchedEntry>> watchedHistory(String accessToken) async =>
      remote;
  @override
  Future<void> scrobble({
    required String accessToken,
    required TraktMedia media,
    required TraktScrobbleAction action,
    required double progress,
  }) async => throw StateError('Fixture offline');
  @override
  Future<void> markWatched({
    required String accessToken,
    required TraktMedia media,
    DateTime? watchedAt,
    bool watched = true,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 2));
    changes.add('${media.imdbId}:${media.season}:${media.episode}:$watched');
  }
}
