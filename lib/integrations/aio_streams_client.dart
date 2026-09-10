import 'package:dio/dio.dart';

import '../domain/media_models.dart';
import '../domain/stream_parser.dart';

class AioStreamsClient {
  AioStreamsClient({Dio? dio, List<Uri>? torrentioBaseUrls})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 30),
              sendTimeout: const Duration(seconds: 15),
            ),
          ),
      _torrentioBaseUrls =
          torrentioBaseUrls ??
          [
            Uri.parse('https://torrentio.strem.fun'),
            Uri.parse('https://torrentio.stremio.ru'),
          ];

  final Dio _dio;
  final List<Uri> _torrentioBaseUrls;
  final StreamParser _parser = const StreamParser();

  Future<Map<String, dynamic>> getManifest(Uri manifestUrl) async {
    final uri = normalizeManifestUrl(manifestUrl);
    final response = await _dio.getUri<Map<String, dynamic>>(uri);
    return response.data ?? const {};
  }

  Future<List<StreamCandidate>> getStreams({
    required Uri manifestUrl,
    required String type,
    required String videoId,
  }) async {
    if (!RegExp(r'^[a-z][a-z0-9_-]*$').hasMatch(type)) {
      throw const FormatException('Unsupported Stremio media type.');
    }
    if (videoId.trim().isEmpty || videoId.contains('/')) {
      throw const FormatException('Invalid Stremio video identifier.');
    }
    final manifest = normalizeManifestUrl(manifestUrl);
    final resourceUrl = manifest.resolve(
      './stream/$type/${Uri.encodeComponent(videoId)}.json',
    );
    final response = await _dio.getUri<Map<String, dynamic>>(resourceUrl);
    return _parser.parseResponse(response.data ?? const {});
  }

  Future<List<StreamCandidate>> getTorrentioStreams({
    required String type,
    required String videoId,
  }) async {
    if ((type != 'movie' && type != 'series') ||
        !RegExp(r'^tt\d+(?::\d+:\d+)?$').hasMatch(videoId)) {
      return const [];
    }
    Object? lastError;
    for (final base in _torrentioBaseUrls) {
      final uri = base.resolve(
        '/stream/$type/${Uri.encodeComponent(videoId)}.json',
      );
      try {
        final response = await _dio.getUri<Map<String, dynamic>>(uri);
        final candidates = _parser.parseResponse(response.data ?? const {});
        if (candidates.isNotEmpty) return candidates;
      } catch (error) {
        lastError = error;
      }
    }
    if (lastError != null) throw lastError;
    return const [];
  }

  static Uri normalizeManifestUrl(Uri input) {
    final uri = input.scheme == 'stremio'
        ? input.replace(scheme: 'https')
        : input;
    if (uri.scheme != 'https' &&
        !(uri.scheme == 'http' &&
            (uri.host == 'localhost' || uri.host == '127.0.0.1'))) {
      throw const FormatException(
        'The addon URL must use HTTPS (HTTP is allowed only for localhost).',
      );
    }
    if (uri.host.isEmpty) throw const FormatException('Invalid addon URL.');
    if (!uri.path.endsWith('/manifest.json')) {
      final path = uri.path.endsWith('/') ? uri.path : '${uri.path}/';
      return uri.replace(path: '${path}manifest.json');
    }
    return uri;
  }
}
