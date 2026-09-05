class CatalogTitle {
  const CatalogTitle({
    required this.id,
    required this.type,
    required this.name,
    required this.year,
    required this.summary,
    required this.genre,
    required this.color,
    this.posterUrl,
    this.backgroundUrl,
    this.videos = const [],
  });

  final String id;
  final String type;
  final String name;
  final int year;
  final String summary;
  final String genre;
  final int color;
  final Uri? posterUrl;
  final Uri? backgroundUrl;
  final List<CatalogVideo> videos;

  bool get isSeries => type == 'series';

  CatalogTitle copyWith({
    String? name,
    int? year,
    String? summary,
    String? genre,
    int? color,
    Uri? posterUrl,
    Uri? backgroundUrl,
    List<CatalogVideo>? videos,
  }) {
    return CatalogTitle(
      id: id,
      type: type,
      name: name ?? this.name,
      year: year ?? this.year,
      summary: summary ?? this.summary,
      genre: genre ?? this.genre,
      color: color ?? this.color,
      posterUrl: posterUrl ?? this.posterUrl,
      backgroundUrl: backgroundUrl ?? this.backgroundUrl,
      videos: videos ?? this.videos,
    );
  }
}

class CatalogVideo {
  const CatalogVideo({
    required this.id,
    required this.title,
    required this.season,
    required this.episode,
    this.released,
    this.thumbnailUrl,
    this.overview = '',
  });

  final String id;
  final String title;
  final int season;
  final int episode;
  final DateTime? released;
  final Uri? thumbnailUrl;
  final String overview;

  String get code =>
      'S${season.toString().padLeft(2, '0')}E${episode.toString().padLeft(2, '0')}';

  String get displayTitle => '$code · $title';
}
