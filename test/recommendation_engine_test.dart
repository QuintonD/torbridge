import 'package:flutter_test/flutter_test.dart';
import 'package:torbridge/data/demo_catalog.dart';
import 'package:torbridge/domain/media_models.dart';
import 'package:torbridge/domain/recommendation_engine.dart';
import 'package:torbridge/domain/stream_parser.dart';

void main() {
  test('AIOStreams metadata is normalised', () {
    final candidate = const StreamParser()
        .parseResponse(demoAioStreamsResponse)
        .first;

    expect(candidate.resolution, VideoResolution.fullHd1080);
    expect(candidate.codec, VideoCodec.hevc);
    expect(candidate.cacheStatus, CacheStatus.cached);
    expect(candidate.audioLanguages, contains('English'));
    expect(candidate.subtitleLanguages, containsAll(['English', 'Dutch']));
    expect(candidate.sizeBytes, 6800000000);
    expect(candidate.releaseTags, contains('webdl'));
  });

  test('recommended source respects quality and language preferences', () {
    final result = const RecommendationEngine().rank(
      demoCandidates(),
      const DownloadPreferences(
        audioLanguageOrder: ['English'],
        subtitleLanguageOrder: ['Dutch', 'English'],
        preferredResolution: VideoResolution.fullHd1080,
        maximumSizeBytes: 12000000000,
      ),
    );

    expect(result.best, isNotNull);
    expect(result.best!.candidate.resolution, VideoResolution.fullHd1080);
    expect(result.best!.candidate.codec, VideoCodec.hevc);
    expect(result.best!.candidate.sizeBytes, 6800000000);
    expect(result.best!.reasons, contains('Dutch subtitles detected'));
  });

  test('uncached, oversized and camera releases are rejected with reasons', () {
    final result = const RecommendationEngine().rank(
      demoCandidates(),
      const DownloadPreferences(maximumSizeBytes: 12000000000),
    );

    expect(result.rejected, hasLength(3));
    expect(
      result.rejected.expand((item) => item.rejections),
      containsAll([
        contains('Not confirmed as instantly cached'),
        contains('Over size limit'),
        contains('Blocked release type'),
      ]),
    );
  });

  test('tie breaking is deterministic', () {
    const base = StreamCandidate(
      id: 'b',
      addonName: 'AIOStreams',
      displayName: 'B',
      description: '',
      resolution: VideoResolution.fullHd1080,
      codec: VideoCodec.hevc,
      hdr: HdrFormat.sdr,
      cacheStatus: CacheStatus.cached,
      audioLanguages: {'English'},
      subtitleLanguages: {'English'},
      sizeBytes: 1000000000,
      releaseTags: {},
    );
    const first = StreamCandidate(
      id: 'a',
      addonName: 'AIOStreams',
      displayName: 'A',
      description: '',
      resolution: VideoResolution.fullHd1080,
      codec: VideoCodec.hevc,
      hdr: HdrFormat.sdr,
      cacheStatus: CacheStatus.cached,
      audioLanguages: {'English'},
      subtitleLanguages: {'English'},
      sizeBytes: 1000000000,
      releaseTags: {},
    );

    final result = const RecommendationEngine().rank([
      base,
      first,
    ], const DownloadPreferences());
    expect(result.best!.candidate.id, 'a');
  });
}
