import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:torbridge/domain/media_models.dart';
import 'package:torbridge/services/local_state_store.dart';

void main() {
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
