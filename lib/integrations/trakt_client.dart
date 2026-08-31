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
        'episode': {
          'season': season,
          'number': episode,
          'ids': {'imdb': imdbId},
        },
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
