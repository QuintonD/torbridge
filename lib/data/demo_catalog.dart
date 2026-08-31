import '../domain/catalog_title.dart';
import '../domain/media_models.dart';
import '../domain/recommendation_engine.dart';
import '../domain/stream_parser.dart';

const demoFeaturedTitle = CatalogTitle(
  id: 'tt1254207',
  type: 'movie',
  name: 'Big Buck Bunny',
  year: 2008,
  summary: 'An open movie used to verify streaming and downloads safely.',
  genre: 'Animation',
  color: 0xFF27716C,
);

const demoTitles = <CatalogTitle>[
  demoFeaturedTitle,
  CatalogTitle(
    id: 'tt0058700',
    type: 'movie',
    name: 'The Last Signal',
    year: 2024,
    summary: 'A quiet test title for the complete recommendation workflow.',
    genre: 'Science fiction',
    color: 0xFF5141A8,
  ),
  CatalogTitle(
    id: 'sintel',
    type: 'movie',
    name: 'Sintel',
    year: 2010,
    summary: 'An open fantasy short used for cross-platform playback tests.',
    genre: 'Fantasy',
    color: 0xFF8B493C,
  ),
];

const demoAioStreamsResponse = <String, dynamic>{
  'streams': [
    {
      'name': '[TB⚡] AIOStreams',
      'title': 'Big.Buck.Bunny.2008.1080p.WEB-DL.HEVC',
      'description': '1080p • HEVC • English audio • Subs: English, Dutch • 6.8 GB • Cached',
      'url': 'https://interactive-examples.mdn.mozilla.net/media/cc0-videos/flower.mp4',
      'behaviorHints': {'filename': 'Big.Buck.Bunny.1080p.HEVC.mkv'},
    },
    {
      'name': '[TB⚡] AIOStreams',
      'title': 'Big.Buck.Bunny.2008.2160p.BluRay.REMUX.DV.HEVC',
      'description': '4K • HEVC • Dolby Vision • English audio • Subs: English, Dutch • 48.2 GB • Cached',
      'url': 'https://example.invalid/4k-remux',
    },
    {
      'name': '[TB⚡] AIOStreams',
      'title': 'Big.Buck.Bunny.2008.720p.WEBRip.H264',
      'description':
          '720p • H.264 • English audio • Subs: English • 2.1 GB • Cached',
      'url': 'https://interactive-examples.mdn.mozilla.net/media/cc0-videos/flower.mp4',
    },
    {
      'name': '[TB⏳] AIOStreams',
      'title': 'Big.Buck.Bunny.2008.1080p.BluRay.REMUX.HEVC',
      'description':
          '1080p • HEVC • English audio • Subs: Dutch • 10.4 GB • Uncached',
      'infoHash': '0123456789abcdef0123456789abcdef01234567',
      'fileIdx': 0,
    },
    {
      'name': '[TB⚡] AIOStreams',
      'title': 'Big.Buck.Bunny.2008.1080p.HDCAM.H264',
      'description': '1080p • H.264 • English audio • 1.4 GB • Cached',
      'url': 'https://example.invalid/cam',
    },
  ],
};

List<StreamCandidate> demoCandidates() =>
    const StreamParser().parseResponse(demoAioStreamsResponse);

RecommendationResult demoRecommendation(DownloadPreferences preferences) =>
    const RecommendationEngine().rank(demoCandidates(), preferences);
