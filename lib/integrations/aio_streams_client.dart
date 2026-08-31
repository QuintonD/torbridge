import 'package:dio/dio.dart';

import '../domain/media_models.dart';
import '../domain/stream_parser.dart';

class AioStreamsClient {
  AioStreamsClient({Dio? dio}) : _dio = dio ?? Dio();

  final Dio _dio;
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
