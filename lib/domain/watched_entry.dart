import 'catalog_title.dart';

/// History metadata survives removing a downloaded file. Local changes take
/// precedence over remote snapshots, including an explicit mark-unwatched.
class WatchedEntry {
  const WatchedEntry(this.title, {this.video, this.localWatched});

  final CatalogTitle title;
  final CatalogVideo? video;
  final bool? localWatched;
  String get id => video?.id ?? title.id;
  String get label =>
      video == null ? title.name : '${title.name} · ${video!.displayTitle}';

  factory WatchedEntry.placeholder(String id) {
    final parts = id.split(':');
    final season = parts.length == 3 ? int.tryParse(parts[1]) : null;
    final episode = parts.length == 3 ? int.tryParse(parts[2]) : null;
    final episodic = season != null && episode != null;
    return WatchedEntry(
      CatalogTitle(
        id: parts.first,
        type: episodic ? 'series' : 'movie',
        name: parts.first,
        year: 0,
        summary: '',
        genre: '',
        color: 0xFF5141A8,
      ),
      video: episodic
          ? CatalogVideo(
              id: id,
              title: 'Episode $episode',
              season: season,
              episode: episode,
            )
          : null,
    );
  }
}
