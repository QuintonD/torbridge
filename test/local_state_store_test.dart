import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:torbridge/domain/media_models.dart';
import 'package:torbridge/services/local_state_store.dart';

void main() {
  test('corrupt sections are backed up independently and unread downloads cannot be replaced', () async {
    SharedPreferences.setMockInitialValues({
      'completed_downloads_v1': '{broken',
      'download_preferences_v1': '{also-broken',
      'watched_title_ids_v1': ['tt1234567'],
    });
    final store = SharedPreferencesLocalStateStore();
    final restored = await store.read();
    expect(restored.downloadsReadable, isFalse);
    expect(restored.watchedTitleIds, {'tt1234567'});
    expect(restored.recoveryWarnings, hasLength(2));
    await expectLater(store.saveDownloadRecords([]), throwsStateError);
    final storage = await SharedPreferences.getInstance();
    expect(storage.getString('completed_downloads_v1'), '{broken');
    expect(
      storage.getString('completed_downloads_v1_recovery_backup'),
      '{broken',
    );
    expect(
      storage.getString('download_preferences_v1_recovery_backup'),
      '{also-broken',
    );
    await store.savePreferences(const DownloadPreferences());
    expect((await store.read()).watchedTitleIds, {'tt1234567'});
  });

  test(
    'preferences, watched state, and completed downloads survive reload',
    () async {
      SharedPreferences.setMockInitialValues({});
      final store = SharedPreferencesLocalStateStore();
      const preferences = DownloadPreferences(
        audioLanguageOrder: ['Dutch', 'English'],
        subtitleLanguageOrder: ['English'],
        preferredResolution: VideoResolution.ultraHd2160,
        maximumSizeBytes: 30000000000,
        preferHdr: true,
        deleteWatchedAfterDays: 7,
      );

      await store.savePreferences(preferences);
      await store.saveWatched({'tt1254207'});
      await store.saveDownloadRecords([
        {'id': 'source-1', 'localPath': 'C:/Downloads/movie.mp4'},
      ]);

      final restored = await store.read();
      expect(restored.preferences.audioLanguageOrder.first, 'Dutch');
      expect(
        restored.preferences.preferredResolution,
        VideoResolution.ultraHd2160,
      );
      expect(restored.preferences.maximumSizeBytes, 30000000000);
      expect(restored.preferences.preferHdr, isTrue);
      expect(restored.preferences.deleteWatchedAfterDays, 7);
      expect(restored.watchedTitleIds, {'tt1254207'});
      expect(restored.downloadRecords.single['id'], 'source-1');
    },
  );
}
