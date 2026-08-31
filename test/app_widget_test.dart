import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:torbridge/app/app_state.dart';
import 'package:torbridge/app/torbridge_app.dart';
import 'package:torbridge/domain/media_models.dart';
import 'package:torbridge/services/credential_store.dart';
import 'package:torbridge/services/download_service.dart';
import 'package:torbridge/services/local_state_store.dart';

void main() {
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
  });
}

class _FakeDownloadService implements DownloadService {
  @override
  Future<String> download({
    required Uri url,
    required String suggestedName,
    required void Function(int received, int total) onProgress,
  }) async {
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
