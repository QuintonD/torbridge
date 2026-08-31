import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';
import 'package:torbridge/domain/media_models.dart';
import 'package:torbridge/integrations/aio_streams_client.dart';
import 'package:torbridge/integrations/torbox_client.dart';
import 'package:torbridge/integrations/trakt_client.dart';

void main() {
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
}
