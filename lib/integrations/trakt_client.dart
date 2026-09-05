import 'package:dio/dio.dart';

enum TraktDeviceStatus { pending, approved, expired, denied, slowDown, invalid }

class TraktDeviceCode {
  const TraktDeviceCode({
    required this.deviceCode,
    required this.userCode,
    required this.verificationUrl,
    required this.expiresIn,
    required this.interval,
  });

  final String deviceCode;
  final String userCode;
  final Uri verificationUrl;
  final int expiresIn;
  final int interval;
}

class TraktTokens {
  const TraktTokens({
    required this.accessToken,
    required this.refreshToken,
    required this.createdAt,
    required this.expiresIn,
  });

  final String accessToken;
  final String refreshToken;
  final int createdAt;
  final int expiresIn;
}

class TraktDevicePollResult {
  const TraktDevicePollResult(this.status, [this.tokens]);

  final TraktDeviceStatus status;
  final TraktTokens? tokens;
}

enum TraktScrobbleAction { start, pause, stop }

class TraktMedia {
  const TraktMedia.movie({
    required this.title,
    required this.year,
    required this.imdbId,
  }) : season = null,
       episode = null;

  const TraktMedia.episode({
    required this.title,
    required this.year,
    required this.imdbId,
    required this.season,
    required this.episode,
  });

  final String title;
  final int year;
  final String imdbId;
  final int? season;
  final int? episode;

  bool get isEpisode => season != null && episode != null;

  Map<String, dynamic> toScrobbleJson() {
    if (isEpisode) {
      return {
        'show': {
          'title': title,
          'year': year,
          'ids': {'imdb': imdbId},
        },
        'episode': {'season': season, 'number': episode},
      };
    }
    return {
      'movie': {
        'title': title,
        'year': year,
        'ids': {'imdb': imdbId},
      },
    };
  }
}

class TraktClient {
  TraktClient({
    required this.clientId,
    required this.clientSecret,
    Dio? apiDio,
    Dio? authDio,
  }) : _apiDio = apiDio ?? Dio(BaseOptions(baseUrl: 'https://api.trakt.tv')),
       _authDio = authDio ?? Dio(BaseOptions(baseUrl: 'https://auth.trakt.tv'));

  final String clientId;
  final String clientSecret;
  final Dio _apiDio;
  final Dio _authDio;

  Future<TraktDeviceCode> requestDeviceCode() async {
    final response = await _authDio.post<Map<String, dynamic>>(
      '/oauth/device/code',
      data: {'client_id': clientId},
    );
    final data = response.data ?? const {};
    return TraktDeviceCode(
      deviceCode: '${data['device_code'] ?? ''}',
      userCode: '${data['user_code'] ?? ''}',
      verificationUrl: Uri.parse(
        '${data['verification_url'] ?? 'https://auth.trakt.tv/activate'}',
      ),
      expiresIn: _asInt(data['expires_in']),
      interval: _asInt(data['interval']),
    );
  }

  Future<TraktDevicePollResult> pollDeviceToken(String deviceCode) async {
    try {
      final response = await _authDio.post<Map<String, dynamic>>(
        '/oauth/device/token',
        data: {
          'code': deviceCode,
          'client_id': clientId,
          'client_secret': clientSecret,
        },
      );
      return TraktDevicePollResult(
        TraktDeviceStatus.approved,
        _tokensFrom(response.data ?? const {}),
      );
    } on DioException catch (error) {
      final status = switch (error.response?.statusCode) {
        400 => TraktDeviceStatus.pending,
        404 || 409 => TraktDeviceStatus.invalid,
        410 => TraktDeviceStatus.expired,
        418 => TraktDeviceStatus.denied,
        429 => TraktDeviceStatus.slowDown,
        _ => null,
      };
      if (status == null) rethrow;
      return TraktDevicePollResult(status);
    }
  }

  Future<TraktTokens> refresh(String refreshToken) async {
    final response = await _authDio.post<Map<String, dynamic>>(
      '/oauth/token',
      data: {
        'refresh_token': refreshToken,
        'client_id': clientId,
        'client_secret': clientSecret,
        'redirect_uri': 'urn:ietf:wg:oauth:2.0:oob',
        'grant_type': 'refresh_token',
      },
    );
    return _tokensFrom(response.data ?? const {});
  }

  Future<void> validateAccessToken(String accessToken) async {
    await _apiDio.get<Map<String, dynamic>>(
      '/users/settings',
      options: _apiOptions(accessToken),
    );
  }

  Future<void> scrobble({
    required String accessToken,
    required TraktMedia media,
    required TraktScrobbleAction action,
    required double progress,
  }) async {
    final body = <String, dynamic>{
      ...media.toScrobbleJson(),
      'progress': progress.clamp(0, 100),
    };
    await _apiDio.post<Map<String, dynamic>>(
      '/scrobble/${action.name}',
      data: body,
      options: _apiOptions(accessToken),
    );
  }

  Future<void> markMovieWatched({
    required String accessToken,
    required TraktMedia movie,
    DateTime? watchedAt,
  }) async {
    await _apiDio.post<Map<String, dynamic>>(
      '/sync/history',
      data: {
        'movies': [
          {
            ...(movie.toScrobbleJson()['movie'] as Map<String, dynamic>),
            'watched_at': (watchedAt ?? DateTime.now().toUtc())
                .toIso8601String(),
          },
        ],
      },
      options: _apiOptions(accessToken),
    );
  }

  Future<void> markWatched({
    required String accessToken,
    required TraktMedia media,
    DateTime? watchedAt,
  }) async {
    final timestamp = (watchedAt ?? DateTime.now().toUtc()).toIso8601String();
    final body = media.toScrobbleJson();
    final data = media.isEpisode
        ? {
            'shows': [
              {
                ...(body['show'] as Map<String, dynamic>),
                'seasons': [
                  {
                    'number': media.season,
                    'episodes': [
                      {'number': media.episode, 'watched_at': timestamp},
                    ],
                  },
                ],
              },
            ],
          }
        : {
            'movies': [
              {
                ...(body['movie'] as Map<String, dynamic>),
                'watched_at': timestamp,
              },
            ],
          };
    await _apiDio.post<Map<String, dynamic>>(
      '/sync/history',
      data: data,
      options: _apiOptions(accessToken),
    );
  }

  Future<Set<String>> watchedVideoIds(String accessToken) async {
    final result = <String>{};
    await _readWatchedPages(
      accessToken: accessToken,
      path: '/sync/watched/movies',
      query: const {},
      onItem: (item) {
        final movie = item['movie'];
        if (movie is! Map) return;
        final ids = movie['ids'];
        if (ids is! Map) return;
        final imdb = '${ids['imdb'] ?? ''}';
        if (imdb.startsWith('tt')) result.add(imdb);
      },
    );
    await _readWatchedPages(
      accessToken: accessToken,
      path: '/sync/watched/shows',
      query: const {'extended': 'progress'},
      onItem: (item) {
        final show = item['show'];
        if (show is! Map) return;
        final ids = show['ids'];
        if (ids is! Map) return;
        final imdb = '${ids['imdb'] ?? ''}';
        if (!imdb.startsWith('tt')) return;
        final seasons = item['seasons'];
        if (seasons is! List) return;
        for (final rawSeason in seasons.whereType<Map>()) {
          final season = _asInt(rawSeason['number']);
          final episodes = rawSeason['episodes'];
          if (season <= 0 || episodes is! List) continue;
          for (final rawEpisode in episodes.whereType<Map>()) {
            final episode = _asInt(rawEpisode['number']);
            final plays = _asInt(rawEpisode['plays']);
            if (episode > 0 && plays > 0) result.add('$imdb:$season:$episode');
          }
        }
      },
    );
    return result;
  }

  Future<void> _readWatchedPages({
    required String accessToken,
    required String path,
    required Map<String, dynamic> query,
    required void Function(Map<String, dynamic> item) onItem,
  }) async {
    for (var page = 1; page <= 100; page++) {
      final response = await _apiDio.get<List<dynamic>>(
        path,
        queryParameters: {...query, 'page': page, 'limit': 100},
        options: _apiOptions(accessToken),
      );
      final items = response.data ?? const [];
      for (final raw in items.whereType<Map>()) {
        onItem(Map<String, dynamic>.from(raw));
      }
      if (items.length < 100) break;
    }
  }

  Options _apiOptions(String accessToken) => Options(
    contentType: Headers.jsonContentType,
    headers: {
      'Authorization': 'Bearer $accessToken',
      'trakt-api-version': '2',
      'trakt-api-key': clientId,
    },
  );

  TraktTokens _tokensFrom(Map<String, dynamic> data) => TraktTokens(
    accessToken: '${data['access_token'] ?? ''}',
    refreshToken: '${data['refresh_token'] ?? ''}',
    createdAt: _asInt(data['created_at']),
    expiresIn: _asInt(data['expires_in']),
  );

  int _asInt(Object? value) => switch (value) {
    int number => number,
    num number => number.toInt(),
    String text => int.tryParse(text) ?? 0,
    _ => 0,
  };
}
