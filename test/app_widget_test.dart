import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:torbridge/app/app_state.dart';
import 'package:torbridge/data/demo_catalog.dart';
import 'package:torbridge/app/torbridge_app.dart';
import 'package:torbridge/domain/catalog_title.dart';
import 'package:torbridge/domain/media_models.dart';
import 'package:torbridge/services/credential_store.dart';
import 'package:torbridge/services/download_service.dart';
import 'package:torbridge/services/local_state_store.dart';
import 'package:torbridge/services/stremio_bridge_service.dart';

void main() {
  setUpAll(() async {
    final fontDirectory = Platform.environment['TORBRIDGE_FONT_DIR'];
    if (Platform.environment['TORBRIDGE_UI_CAPTURE'] == '1' &&
        fontDirectory != null) {
      for (final family in ['Roboto', 'Ahem']) {
        final loader = FontLoader(family)
          ..addFont(
            File('$fontDirectory/roboto-regular.ttf')
                .readAsBytes()
                .then((bytes) => ByteData.sublistView(bytes)),
          );
        await loader.load();
      }
      final icons = FontLoader('MaterialIcons')
        ..addFont(
          File('$fontDirectory/materialicons-regular.otf')
              .readAsBytes()
              .then((bytes) => ByteData.sublistView(bytes)),
        );
      await icons.load();
    }
  });
  for (final size in [
    const Size(360, 640),
    const Size(430, 900),
    const Size(1280, 900),
  ]) {
    testWidgets('downloads filters and actions fit ${size.width.toInt()}px', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      if (size.width == 360) {
        tester.platformDispatcher.textScaleFactorTestValue = 1.4;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      }
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final boundary = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: ProviderScope(
            overrides: [
              credentialStoreProvider.overrideWithValue(
                _MemoryCredentialStore(),
              ),
              downloadServiceProvider.overrideWithValue(_FakeDownloadService()),
              localStateStoreProvider.overrideWithValue(
                _MemoryLocalStateStore(),
              ),
              stremioBridgeProvider.overrideWithValue(_FakeStremioBridge()),
            ],
            child: const TorBridgeApp(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(TorBridgeApp)),
      );
      await container
          .read(torBridgeControllerProvider.notifier)
          .downloadCandidate(demoCandidates().first);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const Key('download-filter-active')));
      await tester.pumpAndSettle();
      expect(find.text('No downloads in this view'), findsOneWidget);
      await tester.ensureVisible(find.text('Show all downloads'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Show all downloads'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('External player'));
      await tester.pumpAndSettle();
      expect(find.text('Play'), findsOneWidget);
      expect(find.text('Stremio'), findsOneWidget);
      expect(tester.takeException(), isNull);
      if (Platform.environment['TORBRIDGE_UI_CAPTURE'] == '1') {
        await tester.runAsync(() async {
          final render =
              boundary.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final image = await render.toImage(pixelRatio: 1);
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          final output = File(
            'docs/ui-pass/downloads-${size.width.toInt()}.png',
          );
          await output.parent.create(recursive: true);
          await output.writeAsBytes(data!.buffer.asUint8List());
          image.dispose();
        });
      }
    });
  }

  testWidgets('desktop journey recommends, downloads, and marks watched', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          credentialStoreProvider.overrideWithValue(_MemoryCredentialStore()),
          downloadServiceProvider.overrideWithValue(_FakeDownloadService()),
          localStateStoreProvider.overrideWithValue(_MemoryLocalStateStore()),
          stremioBridgeProvider.overrideWithValue(_FakeStremioBridge()),
        ],
        child: const TorBridgeApp(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Recommended download'), findsOneWidget);
    expect(find.text('Instantly cached on TorBox'), findsOneWidget);

    await tester.tap(find.byKey(const Key('toggle-watched')));
    await tester.pump();
    expect(find.text('Watched'), findsOneWidget);

    await tester.tap(find.byKey(const Key('download-best')));
    await tester.pumpAndSettle();
    expect(find.text('Downloads'), findsAtLeastNWidgets(1));
    expect(find.text('Ready offline'), findsOneWidget);
    expect(find.text('Subs: Dutch, English'), findsOneWidget);
    expect(find.text('1080p'), findsWidgets);

    await tester.tap(find.text('Library').first);
    await tester.pumpAndSettle();
    expect(find.text('Big Buck Bunny'), findsOneWidget);
    expect(find.text('Watched'), findsOneWidget);
  });

  testWidgets('phone layout exposes preference controls', (tester) async {
    tester.view.physicalSize = const Size(430, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          credentialStoreProvider.overrideWithValue(_MemoryCredentialStore()),
          downloadServiceProvider.overrideWithValue(_FakeDownloadService()),
          localStateStoreProvider.overrideWithValue(_MemoryLocalStateStore()),
          stremioBridgeProvider.overrideWithValue(_FakeStremioBridge()),
        ],
        child: const TorBridgeApp(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('audio-language')), findsOneWidget);
    expect(find.byKey(const Key('subtitle-language')), findsOneWidget);
    expect(find.byKey(const Key('preferred-quality')), findsOneWidget);
    expect(find.byKey(const Key('cached-only')), findsOneWidget);
    expect(find.byKey(const Key('watched-cleanup-delay')), findsOneWidget);

    await tester.tap(find.byKey(const Key('audio-language-Dutch')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('audio-language-Dutch')), findsOneWidget);
    await tester.tap(find.byKey(const Key('audio-language-English')));
    await tester.pumpAndSettle();

    final ultraHd = find.byKey(const Key('quality-ultraHd2160'));
    await tester.ensureVisible(ultraHd);
    await tester.tap(ultraHd);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('preferred-quality')), findsOneWidget);

    await tester.tap(find.text('Discover'));
    await tester.pumpAndSettle();
    expect(find.text('1080p available'), findsOneWidget);
    expect(find.text('Matches preferred 1080p quality'), findsNothing);

    await tester.tap(find.text('Diagnostics'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('run-diagnostics')), findsOneWidget);
  });

  testWidgets('rejected sources explain which hard rules failed', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(430, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final localState = _MemoryLocalStateStore()
      ..value = const StoredLocalState(
        preferences: DownloadPreferences(maximumSizeBytes: 1),
      );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          credentialStoreProvider.overrideWithValue(_MemoryCredentialStore()),
          downloadServiceProvider.overrideWithValue(_FakeDownloadService()),
          localStateStoreProvider.overrideWithValue(localState),
          stremioBridgeProvider.overrideWithValue(_FakeStremioBridge()),
        ],
        child: const TorBridgeApp(),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.textContaining('sources were found, but rejected'),
      findsOneWidget,
    );
    expect(find.textContaining('Over size limit'), findsWidgets);
    expect(find.byKey(const Key('review-download-rules')), findsOneWidget);
  });

  testWidgets('season download dialog supports individual and all episodes', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(430, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final container = ProviderContainer(
      overrides: [
        credentialStoreProvider.overrideWithValue(_MemoryCredentialStore()),
        downloadServiceProvider.overrideWithValue(_FakeDownloadService()),
        localStateStoreProvider.overrideWithValue(_MemoryLocalStateStore()),
        stremioBridgeProvider.overrideWithValue(_FakeStremioBridge()),
      ],
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const TorBridgeApp(),
      ),
    );
    await tester.pumpAndSettle();
    container
        .read(torBridgeControllerProvider.notifier)
        .selectTitle(_widgetSeries);
    await tester.pumpAndSettle();

    final bulkButton = find.byKey(const Key('download-season-1'));
    await tester.drag(
      find.byKey(const Key('discover-scroll')),
      const Offset(0, -600),
    );
    await tester.pumpAndSettle();
    await tester.tap(bulkButton);
    await tester.pumpAndSettle();

    expect(find.text('Download Season 1'), findsOneWidget);
    expect(
      find.byKey(const Key('bulk-episode-widget-series:1:1')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('bulk-episode-widget-series:1:3')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('select-all-episodes')));
    await tester.pump();
    expect(find.text('3 selected'), findsOneWidget);
    expect(find.text('Download 3 episodes'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
    await tester.pump();
  });
}

const _widgetSeries = CatalogTitle(
  id: 'widget-series',
  type: 'series',
  name: 'Widget Series',
  year: 2026,
  summary: 'Series used by the episode picker test.',
  genre: 'Drama',
  color: 0xFF333333,
  videos: [
    CatalogVideo(id: 'widget-series:1:1', title: 'One', season: 1, episode: 1),
    CatalogVideo(id: 'widget-series:1:2', title: 'Two', season: 1, episode: 2),
    CatalogVideo(
      id: 'widget-series:1:3',
      title: 'Three',
      season: 1,
      episode: 3,
    ),
  ],
);

class _FakeDownloadService extends DownloadService {
  @override
  Future<String> download({
    required String jobId,
    required Uri url,
    required String suggestedName,
    required void Function(int received, int total) onProgress,
    DownloadEnqueuedCallback? onEnqueued,
    Map<String, String> requestHeaders = const {},
  }) async {
    onEnqueued?.call(jobId);
    onProgress(5, 10);
    onProgress(10, 10);
    return 'C:\\TorBridge\\$suggestedName';
  }
}

class _MemoryCredentialStore implements CredentialStore {
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
  }) async {
    value = StoredConnections(
      aioManifestUrl: aioManifestUrl,
      torBoxToken: torBoxToken,
      traktClientId: traktClientId,
      traktClientSecret: traktClientSecret,
    );
  }

  @override
  Future<void> saveTraktTokens({
    required String accessToken,
    required String refreshToken,
  }) async {
    value = StoredConnections(
      aioManifestUrl: value.aioManifestUrl,
      torBoxToken: value.torBoxToken,
      traktClientId: value.traktClientId,
      traktClientSecret: value.traktClientSecret,
      traktAccessToken: accessToken,
      traktRefreshToken: refreshToken,
    );
  }

  @override
  Future<void> saveAll(StoredConnections connections) async {
    value = connections;
  }
}

class _MemoryLocalStateStore implements LocalStateStore {
  StoredLocalState value = const StoredLocalState();

  @override
  Future<StoredLocalState> read() async => value;

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

  @override
  Future<void> saveDownloadRecords(List<Map<String, dynamic>> records) async {
    value = StoredLocalState(
      preferences: value.preferences,
      watchedTitleIds: value.watchedTitleIds,
      downloadRecords: records,
    );
  }
}

class _FakeStremioBridge extends StremioBridgeService {
  @override
  Future<bool> ping() async => true;

  @override
  Future<void> start(List<StremioBridgeEntry> entries) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> update(List<StremioBridgeEntry> entries) async {}
}
