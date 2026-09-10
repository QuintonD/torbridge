/// Match numeric episode identity in the filename, never a prefix or directory.
bool matchesEpisode(String filename, String episodeCode) {
  final requested = RegExp(
    r'^s(\d+)e(\d+)$',
    caseSensitive: false,
  ).firstMatch(episodeCode);
  if (requested == null) return false;
  final season = int.parse(requested.group(1)!);
  final episode = int.parse(requested.group(2)!);
  final name = filename.replaceAll('\\', '/').split('/').last;
  final tokens = RegExp(
    r'(?:^|[^a-z0-9])(?:s(\d{1,3})[ ._-]*e(\d{1,4})|(\d{1,3})x(\d{1,4}))(?!\d)',
    caseSensitive: false,
  ).allMatches(name);
  return tokens.any(
    (token) =>
        int.parse(token.group(1) ?? token.group(3)!) == season &&
        int.parse(token.group(2) ?? token.group(4)!) == episode,
  );
}
