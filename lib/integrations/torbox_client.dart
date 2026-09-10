import 'package:dio/dio.dart';

import '../domain/episode_identity.dart';

class TorBoxApiException implements Exception {
  const TorBoxApiException(this.message);

  final String message;

  @override
  String toString() => 'TorBox: $message';
}

class TorBoxFile {
  const TorBoxFile({required this.id, required this.name, required this.size});

  final int id;
  final String name;
  final int size;

  bool get isVideo => RegExp(
    r'\.(mkv|mp4|avi|mov|m4v|webm|ts)$',
    caseSensitive: false,
  ).hasMatch(name);
}

class TorBoxTorrent {
  const TorBoxTorrent({
    required this.id,
    required this.hash,
    required this.name,
    required this.files,
  });

  final int id;
  final String hash;
  final String name;
  final List<TorBoxFile> files;

  TorBoxFile? preferredFile([int? sourceFileIndex]) {
    if (sourceFileIndex != null && sourceFileIndex >= 0) {
      if (sourceFileIndex < files.length && files[sourceFileIndex].isVideo) {
        return files[sourceFileIndex];
      }
      for (final file in files) {
        if (file.id == sourceFileIndex && file.isVideo) return file;
      }
    }
    final videoFiles = files.where((file) => file.isVideo).toList()
      ..sort((a, b) => b.size.compareTo(a.size));
    if (videoFiles.isNotEmpty) return videoFiles.first;
    return null;
  }

  TorBoxFile? episodeFile(String episodeCode, [int? sourceFileIndex]) {
    if (sourceFileIndex != null) {
      final indexed = preferredFile(sourceFileIndex);
      if (indexed != null && matchesEpisode(indexed.name, episodeCode)) {
        return indexed;
      }
    }
    for (final file in files.where((item) => item.isVideo)) {
      if (matchesEpisode(file.name, episodeCode)) return file;
    }
    return null;
  }
}

class TorBoxFileSelection {
  const TorBoxFileSelection({required this.torrent, required this.file});

  final TorBoxTorrent torrent;
  final TorBoxFile file;
}

class TorBoxClient {
  TorBoxClient(this._apiToken, {Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              baseUrl: 'https://api.torbox.app',
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 30),
              sendTimeout: const Duration(seconds: 15),
            ),
          );

  final String _apiToken;
  final Dio _dio;

  Options get _authorized => Options(
    headers: {'Authorization': 'Bearer $_apiToken'},
    contentType: Headers.jsonContentType,
  );

  Future<void> validateToken() async {
    final response = await _dio.get<Map<String, dynamic>>(
      '/v1/api/user/me',
      options: _authorized,
    );
    _requireSuccess(response.data);
  }

  Future<bool> isCached(String infoHash) async {
    final cached = await cachedHashes([infoHash]);
    return cached.contains(infoHash.toLowerCase());
  }

  Future<Set<String>> cachedHashes(Iterable<String> infoHashes) async {
    final hashes = infoHashes
        .map((hash) => hash.trim().toLowerCase())
        .where((hash) => hash.isNotEmpty)
        .toSet();
    if (hashes.isEmpty) return const {};

    final response = await _dio.post<Map<String, dynamic>>(
      '/v1/api/torrents/checkcached',
      data: {'hashes': hashes.toList(growable: false)},
      queryParameters: const {'format': 'object', 'list_files': true},
      options: _authorized,
    );
    final data = _data(response.data);
    final cached = <String>{};
    if (data is Map) {
      for (final entry in data.entries) {
        final hash = '${entry.key}'.toLowerCase();
        if (!hashes.contains(hash)) continue;
        final value = entry.value;
        if (value == true || value is Map && value.isNotEmpty) {
          cached.add(hash);
        }
      }
    } else if (data is List) {
      for (final value in data) {
        if (value is String && hashes.contains(value.toLowerCase())) {
          cached.add(value.toLowerCase());
        } else if (value is Map) {
          final hash = '${value['hash'] ?? value['torrent_hash'] ?? ''}'
              .toLowerCase();
          if (hashes.contains(hash)) cached.add(hash);
        }
      }
    }
    return cached;
  }

  Future<TorBoxTorrent> ensureTorrent({
    required String infoHash,
    bool cachedOnly = true,
  }) async {
    final existing = await findTorrentByHash(infoHash);
    if (existing != null) return existing;

    return _createTorrent(
      magnet: 'magnet:?xt=urn:btih:${infoHash.toLowerCase()}',
      infoHash: infoHash,
      cachedOnly: cachedOnly,
    );
  }

  Future<TorBoxTorrent> ensureTorrentFromMagnet({
    required String magnet,
    bool cachedOnly = true,
  }) async {
    final infoHash = _magnetHash(magnet);
    if (infoHash.isEmpty) {
      throw const TorBoxApiException('The search result has no valid magnet.');
    }
    final existing = await findTorrentByHash(infoHash);
    if (existing != null) return existing;
    return _createTorrent(
      magnet: magnet,
      infoHash: infoHash,
      cachedOnly: cachedOnly,
    );
  }

  Future<TorBoxTorrent> _createTorrent({
    required String magnet,
    required String infoHash,
    required bool cachedOnly,
  }) async {
    final response = await _dio.post<Map<String, dynamic>>(
      '/v1/api/torrents/createtorrent',
      data: FormData.fromMap({
        'magnet': magnet,
        'add_only_if_cached': cachedOnly,
        'allow_zip': false,
      }),
      options: Options(headers: {'Authorization': 'Bearer $_apiToken'}),
    );
    _requireSuccess(response.data);
    final created = _data(response.data);
    final torrentId = _intFrom(created, const ['torrent_id', 'id']);
    if (torrentId != null) {
      final torrent = await getTorrent(torrentId, bypassCache: true);
      if (torrent != null) return torrent;
    }
    final found = await findTorrentByHash(infoHash, bypassCache: true);
    if (found == null) {
      throw const TorBoxApiException(
        'Torrent was added but its files are not available yet.',
      );
    }
    return found;
  }

  Future<TorBoxTorrent> waitForFiles(
    TorBoxTorrent torrent, {
    int attempts = 12,
    Duration interval = const Duration(seconds: 1),
  }) async {
    var current = torrent;
    for (var attempt = 0; attempt < attempts; attempt++) {
      if (current.files.isNotEmpty) return current;
      if (attempt > 0) await Future<void>.delayed(interval);
      current = await getTorrent(current.id, bypassCache: true) ?? current;
    }
    throw const TorBoxApiException(
      'TorBox is still preparing the torrent files. Retry shortly.',
    );
  }

  Future<TorBoxTorrent?> getTorrent(int id, {bool bypassCache = false}) async {
    final response = await _dio.get<Map<String, dynamic>>(
      '/v1/api/torrents/mylist',
      queryParameters: {'id': id, 'bypass_cache': bypassCache},
      options: _authorized,
    );
    _requireSuccess(response.data);
    final value = _data(response.data);
    if (value is Map) return _parseTorrent(Map<String, dynamic>.from(value));
    if (value is List && value.isNotEmpty && value.first is Map) {
      return _parseTorrent(Map<String, dynamic>.from(value.first as Map));
    }
    return null;
  }

  Future<TorBoxTorrent?> findTorrentByHash(
    String infoHash, {
    bool bypassCache = false,
  }) async {
    final torrents = await listTorrents(bypassCache: bypassCache);
    for (final torrent in torrents) {
      if (torrent.hash.toLowerCase() == infoHash.toLowerCase()) return torrent;
    }
    return null;
  }

  Future<List<TorBoxTorrent>> listTorrents({bool bypassCache = false}) async {
    final response = await _dio.get<Map<String, dynamic>>(
      '/v1/api/torrents/mylist',
      queryParameters: {'bypass_cache': bypassCache, 'limit': 1000},
      options: _authorized,
    );
    _requireSuccess(response.data);
    final value = _data(response.data);
    final items = value is List ? value : [value];
    final torrents = <TorBoxTorrent>[];
    for (final item in items) {
      if (item is! Map) continue;
      torrents.add(_parseTorrent(Map<String, dynamic>.from(item)));
    }
    return List.unmodifiable(torrents);
  }

  Future<TorBoxFileSelection?> findVideoFile({
    required String title,
    String? episodeCode,
    int? year,
  }) async {
    final torrents = await listTorrents(bypassCache: true);
    final titleTokens = _searchTokens(title);
    final requiredTitleMatches = titleTokens.length > 1 ? 2 : 1;
    TorBoxFileSelection? best;
    var bestScore = -1;

    for (final torrent in torrents) {
      for (final file in torrent.files.where((item) => item.isVideo)) {
        final haystack = _normalized('${torrent.name} ${file.name}');
        if (episodeCode != null && !matchesEpisode(file.name, episodeCode)) {
          continue;
        }
        final titleMatches = titleTokens.where(haystack.contains).length;
        if (titleTokens.isNotEmpty && titleMatches < requiredTitleMatches) {
          continue;
        }
        var score = titleMatches * 20;
        if (episodeCode != null) score += 100;
        if (year != null && haystack.contains('$year')) score += 5;
        if (file.size > 0) score += 1;
        if (score > bestScore ||
            score == bestScore && file.size > (best?.file.size ?? -1)) {
          bestScore = score;
          best = TorBoxFileSelection(torrent: torrent, file: file);
        }
      }
    }
    return best;
  }

  Future<Uri> requestDownloadLink({
    required int torrentId,
    required int fileId,
  }) async {
    // TorBox documents the token query parameter as required for this endpoint.
    // The resulting short-lived CDN URL is returned to the caller but never
    // persisted by this client.
    final response = await _dio.get<Map<String, dynamic>>(
      '/v1/api/torrents/requestdl',
      queryParameters: {
        'token': _apiToken,
        'torrent_id': torrentId,
        'file_id': fileId,
        'zip_link': false,
        'redirect': false,
      },
      options: Options(contentType: Headers.jsonContentType),
    );
    _requireSuccess(response.data);
    final data = _data(response.data);
    final text = switch (data) {
      String value => value,
      Map value => '${value['url'] ?? value['download_url'] ?? ''}',
      _ => '',
    };
    final uri = Uri.tryParse(text);
    if (uri == null || !uri.hasScheme) {
      throw const TorBoxApiException('No download link was returned.');
    }
    return uri;
  }

  TorBoxTorrent _parseTorrent(Map<String, dynamic> value) {
    final filesValue = value['files'];
    final files = <TorBoxFile>[];
    if (filesValue is List) {
      for (var index = 0; index < filesValue.length; index++) {
        final item = filesValue[index];
        if (item is! Map) continue;
        final map = Map<String, dynamic>.from(item);
        files.add(
          TorBoxFile(
            id: _intFrom(map, const ['id', 'file_id']) ?? index,
            name:
                '${map['short_name'] ?? map['name'] ?? map['path'] ?? 'File ${index + 1}'}',
            size: _intFrom(map, const ['size', 'bytes']) ?? 0,
          ),
        );
      }
    }
    return TorBoxTorrent(
      id: _intFrom(value, const ['id', 'torrent_id']) ?? -1,
      hash: '${value['hash'] ?? value['torrent_hash'] ?? ''}',
      name: '${value['name'] ?? 'Torrent'}',
      files: List.unmodifiable(files),
    );
  }

  Object? _data(Map<String, dynamic>? response) {
    _requireSuccess(response);
    return response?['data'];
  }

  void _requireSuccess(Map<String, dynamic>? response) {
    if (response == null) {
      throw const TorBoxApiException('Empty response.');
    }
    if (response['success'] == false) {
      throw TorBoxApiException(
        '${response['detail'] ?? response['error'] ?? 'Request failed'}',
      );
    }
  }

  int? _intFrom(Object? value, List<String> keys) {
    if (value is! Map) return null;
    for (final key in keys) {
      final candidate = value[key];
      if (candidate is int) return candidate;
      if (candidate is num) return candidate.toInt();
      if (candidate is String) {
        final parsed = int.tryParse(candidate);
        if (parsed != null) return parsed;
      }
    }
    return null;
  }

  Set<String> _searchTokens(String value) => _normalized(value)
      .split(' ')
      .where(
        (token) => token.length >= 3 && !_ignoredTitleTokens.contains(token),
      )
      .toSet();

  String _normalized(String value) =>
      value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();

  String _magnetHash(String magnet) {
    final uri = Uri.tryParse(magnet);
    final values = uri?.queryParametersAll['xt'];
    final xt = values == null || values.isEmpty ? null : values.first;
    if (xt == null) return '';
    final hash = xt.split(':').last.trim().toLowerCase();
    return RegExp(r'^[a-z0-9]{32,40}$').hasMatch(hash) ? hash : '';
  }
}

const _ignoredTitleTokens = {'the', 'and', 'for', 'with', 'season', 'complete'};
