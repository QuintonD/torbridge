import 'package:dio/dio.dart';

import '../domain/catalog_title.dart';

class CinemetaClient {
  CinemetaClient({Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              baseUrl: 'https://v3-cinemeta.strem.io',
              connectTimeout: const Duration(seconds: 15),
              sendTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 30),
            ),
          );

  final Dio _dio;

  Future<List<CatalogTitle>> search(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return const [];
    final results = await Future.wait([
      _searchType('movie', trimmed),
      _searchType('series', trimmed),
    ]);
    return [...results[0], ...results[1]];
  }

  Future<CatalogTitle> getDetails(CatalogTitle preview) async {
    final response = await _dio.get<Map<String, dynamic>>(
      '/meta/${preview.type}/${Uri.encodeComponent(preview.id)}.json',
    );
    final meta = response.data?['meta'];
    if (meta is! Map) return preview;
    return _parse(Map<String, dynamic>.from(meta), preview.type);
  }

  Future<List<CatalogTitle>> _searchType(String type, String query) async {
    final encodedQuery = Uri.encodeComponent(query);
    final response = await _dio.get<Map<String, dynamic>>(
      '/catalog/$type/top/search=$encodedQuery.json',
    );
    final metas = response.data?['metas'];
    if (metas is! List) return const [];
    return metas
        .whereType<Map>()
        .map((meta) => _parse(Map<String, dynamic>.from(meta), type))
        .where((title) => title.id.isNotEmpty)
        .toList(growable: false);
  }

  CatalogTitle _parse(Map<String, dynamic> meta, String fallbackType) {
    final id = '${meta['id'] ?? ''}';
    final genres = meta['genres'];
    final genre = genres is List && genres.isNotEmpty
        ? genres.take(2).join(' / ')
        : '${meta['genre'] ?? 'Unknown genre'}';
    final releaseInfo = '${meta['releaseInfo'] ?? meta['year'] ?? ''}';
    final year =
        int.tryParse(
          RegExp(r'\d{4}').firstMatch(releaseInfo)?.group(0) ?? '',
        ) ??
        0;
    return CatalogTitle(
      id: id,
      type: '${meta['type'] ?? fallbackType}',
      name: '${meta['name'] ?? 'Untitled'}',
      year: year,
      summary: '${meta['description'] ?? 'No summary available.'}',
      genre: genre,
      color: _colorFrom(id),
      posterUrl: Uri.tryParse('${meta['poster'] ?? ''}'),
      backgroundUrl: Uri.tryParse('${meta['background'] ?? ''}'),
      videos: _parseVideos(meta['videos']),
    );
  }

  List<CatalogVideo> _parseVideos(Object? value) {
    if (value is! List) return const [];
    final videos = <CatalogVideo>[];
    for (final raw in value.whereType<Map>()) {
      final video = Map<String, dynamic>.from(raw);
      final id = '${video['id'] ?? ''}'.trim();
      final season = _asInt(video['season']);
      final episode = _asInt(video['episode']);
      if (id.isEmpty || season == null || episode == null) continue;
      videos.add(
        CatalogVideo(
          id: id,
          title: '${video['title'] ?? 'Episode $episode'}',
          season: season,
          episode: episode,
          released: DateTime.tryParse('${video['released'] ?? ''}'),
          thumbnailUrl: Uri.tryParse('${video['thumbnail'] ?? ''}'),
          overview: '${video['overview'] ?? ''}',
        ),
      );
    }
    videos.sort((a, b) {
      final season = a.season.compareTo(b.season);
      return season != 0 ? season : a.episode.compareTo(b.episode);
    });
    return List.unmodifiable(videos);
  }

  int? _asInt(Object? value) => switch (value) {
    int number => number,
    num number => number.toInt(),
    String text => int.tryParse(text),
    _ => null,
  };

  int _colorFrom(String value) {
    var hash = 0;
    for (final codeUnit in value.codeUnits) {
      hash = ((hash * 31) + codeUnit) & 0xFFFFFF;
    }
    final red = 60 + ((hash >> 16) & 0x7F);
    final green = 45 + ((hash >> 8) & 0x6F);
    final blue = 70 + (hash & 0x7F);
    return 0xFF000000 | (red << 16) | (green << 8) | blue;
  }
}
