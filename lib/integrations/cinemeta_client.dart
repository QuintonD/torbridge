import 'package:dio/dio.dart';

import '../domain/catalog_title.dart';

class CinemetaClient {
  CinemetaClient({Dio? dio})
    : _dio = dio ?? Dio(BaseOptions(baseUrl: 'https://v3-cinemeta.strem.io'));

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
    );
  }

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
