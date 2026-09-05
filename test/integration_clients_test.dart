import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';
import 'package:torbridge/domain/catalog_title.dart';
import 'package:torbridge/domain/media_models.dart';
import 'package:torbridge/integrations/aio_streams_client.dart';
import 'package:torbridge/integrations/cinemeta_client.dart';
import 'package:torbridge/integrations/torbox_client.dart';
import 'package:torbridge/integrations/trakt_client.dart';

void main() {
  test('Cinemeta details expose exact season and episode metadata', () async {
    final dio = Dio(BaseOptions(baseUrl: 'https://v3-cinemeta.strem.io'));
    final adapter = DioAdapter(dio: dio);
    adapter.onGet(
      '/meta/series/tt0108778.json',
      (server) => server.reply(200, {
        'meta': {
          'id': 'tt0108778',
          'type': 'series',
          'name': 'Friends',
          'releaseInfo': '1994–2004',
          'description': 'Six friends in Manhattan.',
          'genres': ['Comedy'],
          'poster': 'https://images.example/friends.jpg',
          'videos': [
            {
              'id': 'tt0108778:1:1',
              'title': 'Pilot',
              'season': 1,
              'episode': 1,
              'released': '1994-09-22T18:00:00.000Z',
              'thumbnail': 'https://images.example/pilot.jpg',
              'overview': 'Rachel arrives.',
            },
          ],
        },
      }),
    );

    final details = await CinemetaClient(dio: dio).getDetails(
      const CatalogTitle(
        id: 'tt0108778',
        type: 'series',
        name: 'Friends',
        year: 1994,
        summary: '',
        genre: 'Comedy',
        color: 0xFF000000,
      ),
    );

    expect(details.videos.single.id, 'tt0108778:1:1');
    expect(details.videos.single.code, 'S01E01');
    expect(details.videos.single.thumbnailUrl?.host, 'images.example');
  });

  test(
    'AIOStreams client preserves configured path and requests stream resource',
    () async {
      final dio = Dio();
      final adapter = DioAdapter(dio: dio);
      adapter.onGet(
        'https://addon.example/user-config/stream/movie/tt1254207.json',
        (server) => server.reply(200, {
          'streams': [
            {
              'name': '[TB] AIOStreams',
              'title': 'Movie.1080p.HEVC',
              'description': 'Cached English audio 4 GB',
              'url': 'https://cdn.example/movie.mp4',
            },
          ],
        }),
      );

      final result = await AioStreamsClient(dio: dio).getStreams(
        manifestUrl: Uri.parse(
          'stremio://addon.example/user-config/manifest.json',
        ),
        type: 'movie',
        videoId: 'tt1254207',
      );

      expect(result, hasLength(1));
      expect(result.first.cacheStatus, CacheStatus.cached);
      expect(
        result.first.streamUrl,
        Uri.parse('https://cdn.example/movie.mp4'),
      );
    },
  );

  test('Torrentio metadata fallback returns an exact torrent file', () async {
    final dio = Dio();
    final adapter = DioAdapter(dio: dio);
    adapter.onGet(
      'https://torrentio.example/stream/series/tt14688458%3A2%3A10.json',
      (server) => server.reply(200, {
        'streams': [
          {
            'name': '[Torrentio] 1080p',
            'description': 'Silo.S02E10.1080p.WEB-DL',
            'infoHash': '0123456789abcdef0123456789abcdef01234567',
            'fileIdx': 17,
          },
        ],
      }),
    );

    final result = await AioStreamsClient(
      dio: dio,
      torrentioBaseUrls: [Uri.parse('https://torrentio.example')],
    ).getTorrentioStreams(type: 'series', videoId: 'tt14688458:2:10');

    expect(result.single.infoHash, '0123456789abcdef0123456789abcdef01234567');
    expect(result.single.fileIndex, 17);
    expect(result.single.streamUrl, isNull);
  });

  test(
    'TorBox client selects the largest video and returns an ephemeral link',
    () async {
      final dio = Dio(BaseOptions(baseUrl: 'https://api.torbox.app'));
      final adapter = DioAdapter(dio: dio);
      adapter.onGet(
        '/v1/api/torrents/mylist',
        (server) => server.reply(200, {
          'success': true,
          'data': [
            {
              'id': 42,
              'hash': 'abc123',
              'name': 'Example',
              'files': [
                {'id': 8, 'short_name': 'sample.mkv', 'size': 100},
                {'id': 9, 'short_name': 'movie.mkv', 'size': 1000},
              ],
            },
          ],
        }),
        queryParameters: {'bypass_cache': false, 'limit': 1000},
      );
      adapter.onGet(
        '/v1/api/torrents/requestdl',
        (server) => server.reply(200, {
          'success': true,
          'data': 'https://cdn.torbox.example/temporary-file',
        }),
        queryParameters: {
          'token': 'secret-token',
          'torrent_id': 42,
          'file_id': 9,
          'zip_link': false,
          'redirect': false,
        },
      );

      final client = TorBoxClient('secret-token', dio: dio);
      final torrent = await client.findTorrentByHash('ABC123');
      expect(torrent, isNotNull);
      expect(torrent!.preferredFile()!.id, 9);
      final link = await client.requestDownloadLink(
        torrentId: torrent.id,
        fileId: torrent.preferredFile()!.id,
      );
      expect(link.host, 'cdn.torbox.example');
    },
  );

  test(
    'TorBox client verifies several cache candidates in one request',
    () async {
      final dio = Dio(BaseOptions(baseUrl: 'https://api.torbox.app'));
      final adapter = DioAdapter(dio: dio);
      adapter.onPost(
        '/v1/api/torrents/checkcached',
        (server) => server.reply(200, {
          'success': true,
          'data': {
            'cached-hash': {'name': 'Cached release'},
          },
        }),
        data: {
          'hashes': ['cached-hash', 'uncached-hash'],
        },
        queryParameters: {'format': 'object', 'list_files': true},
        headers: {
          'Authorization': 'Bearer secret-token',
          'content-type': 'application/json',
        },
      );

      final cached = await TorBoxClient(
        'secret-token',
        dio: dio,
      ).cachedHashes(['CACHED-HASH', 'uncached-hash']);

      expect(cached, {'cached-hash'});
    },
  );

  test('TorBox client selects the exact episode from a season pack', () async {
    final dio = Dio(BaseOptions(baseUrl: 'https://api.torbox.app'));
    final adapter = DioAdapter(dio: dio);
    adapter.onGet(
      '/v1/api/torrents/mylist',
      (server) => server.reply(200, {
        'success': true,
        'data': [
          {
            'id': 77,
            'hash': 'silo-pack',
            'name': 'Silo Season 1 Complete',
            'files': [
              {
                'id': 9,
                'short_name': 'Silo.S01E09.The.Getaway.mkv',
                'size': 900,
              },
              {'id': 10, 'short_name': 'Silo.S01E10.Outside.mkv', 'size': 1000},
            ],
          },
          {
            'id': 88,
            'hash': 'other-pack',
            'name': 'Another Show Season 1',
            'files': [
              {'id': 10, 'short_name': 'Another.Show.S01E10.mkv', 'size': 2000},
            ],
          },
        ],
      }),
      queryParameters: {'bypass_cache': true, 'limit': 1000},
    );

    final match = await TorBoxClient(
      'secret-token',
      dio: dio,
    ).findVideoFile(title: 'Silo', episodeCode: 'S01E10', year: 2023);

    expect(match, isNotNull);
    expect(match!.torrent.id, 77);
    expect(match.file.id, 10);
    expect(match.file.name, contains('S01E10'));
  });

  test(
    'Trakt client sends the standard scrobble envelope and headers',
    () async {
      final apiDio = Dio(BaseOptions(baseUrl: 'https://api.trakt.tv'));
      final apiAdapter = DioAdapter(dio: apiDio);
      apiAdapter.onPost(
        '/scrobble/stop',
        (server) => server.reply(200, {'action': 'scrobble'}),
        data: {
          'movie': {
            'title': 'Big Buck Bunny',
            'year': 2008,
            'ids': {'imdb': 'tt1254207'},
          },
          'progress': 92.5,
        },
        headers: {
          'Authorization': 'Bearer access-token',
          'trakt-api-version': '2',
          'trakt-api-key': 'client-id',
          'content-type': 'application/json',
        },
      );

      await TraktClient(
        clientId: 'client-id',
        clientSecret: 'client-secret',
        apiDio: apiDio,
      ).scrobble(
        accessToken: 'access-token',
        media: const TraktMedia.movie(
          title: 'Big Buck Bunny',
          year: 2008,
          imdbId: 'tt1254207',
        ),
        action: TraktScrobbleAction.stop,
        progress: 92.5,
      );
    },
  );

  test('Trakt episode scrobble carries show and episode identity', () async {
    final apiDio = Dio(BaseOptions(baseUrl: 'https://api.trakt.tv'));
    final adapter = DioAdapter(dio: apiDio);
    adapter.onPost(
      '/scrobble/start',
      (server) => server.reply(200, {'action': 'start'}),
      data: {
        'show': {
          'title': 'Friends',
          'year': 1994,
          'ids': {'imdb': 'tt0108778'},
        },
        'episode': {'season': 1, 'number': 1},
        'progress': 12.0,
      },
    );

    await TraktClient(
      clientId: 'client-id',
      clientSecret: 'client-secret',
      apiDio: apiDio,
    ).scrobble(
      accessToken: 'access-token',
      media: const TraktMedia.episode(
        title: 'Friends',
        year: 1994,
        imdbId: 'tt0108778',
        season: 1,
        episode: 1,
      ),
      action: TraktScrobbleAction.start,
      progress: 12,
    );
  });

  test('Trakt watched sync returns movie and canonical episode IDs', () async {
    final apiDio = Dio(BaseOptions(baseUrl: 'https://api.trakt.tv'));
    final adapter = DioAdapter(dio: apiDio);
    adapter.onGet(
      '/sync/watched/movies',
      (server) => server.reply(200, [
        {
          'movie': {
            'ids': {'imdb': 'tt1254207'},
          },
        },
      ]),
      queryParameters: {'page': 1, 'limit': 100},
    );
    adapter.onGet(
      '/sync/watched/shows',
      (server) => server.reply(200, [
        {
          'show': {
            'ids': {'imdb': 'tt0108778'},
          },
          'seasons': [
            {
              'number': 1,
              'episodes': [
                {'number': 1, 'plays': 2},
                {'number': 2, 'plays': 0},
              ],
            },
          ],
        },
      ]),
      queryParameters: {'extended': 'progress', 'page': 1, 'limit': 100},
    );

    final watched = await TraktClient(
      clientId: 'client-id',
      clientSecret: 'client-secret',
      apiDio: apiDio,
    ).watchedVideoIds('access-token');

    expect(watched, {'tt1254207', 'tt0108778:1:1'});
  });
}
