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
}
