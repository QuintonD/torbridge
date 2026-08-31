import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'media_models.dart';

class StreamParser {
  const StreamParser();

  List<StreamCandidate> parseResponse(Map<String, dynamic> response) {
    final streams = response['streams'];
    if (streams is! List) return const [];

    return streams
        .whereType<Map>()
        .map((stream) => parseStream(Map<String, dynamic>.from(stream)))
        .toList(growable: false);
  }

  StreamCandidate parseStream(Map<String, dynamic> stream) {
    final behaviorHints = stream['behaviorHints'] is Map
        ? Map<String, dynamic>.from(stream['behaviorHints'] as Map)
        : const <String, dynamic>{};
    final name = _asString(stream['name']);
    final title = _asString(stream['title']);
    final description = _asString(stream['description']);
    final filename = _asString(behaviorHints['filename']);
    final searchable = '$name\n$title\n$description\n$filename';
    final urlText = _asString(stream['url']);
    final infoHash = _asString(stream['infoHash']);
    final fileIndex = _asInt(stream['fileIdx']) ?? _asInt(stream['fileIndex']);
    final sourceIdentity = [
      name,
      title,
      description,
      filename,
      urlText,
      infoHash,
      fileIndex?.toString() ?? '',
    ].join('|');

    return StreamCandidate(
      id: sha256.convert(utf8.encode(sourceIdentity)).toString(),
      addonName: _addonName(name),
      displayName: title.isNotEmpty ? title.split('\n').first : name,
      description: description.isNotEmpty ? description : title,
      resolution: _resolution(searchable),
      codec: _codec(searchable),
      hdr: _hdr(searchable),
      cacheStatus: _cacheStatus(searchable),
      audioLanguages: _audioLanguages(searchable),
      subtitleLanguages: _subtitleLanguages(searchable),
      sizeBytes: _sizeBytes(searchable),
      releaseTags: _releaseTags(searchable),
      streamUrl: Uri.tryParse(urlText),
      infoHash: infoHash.isEmpty ? null : infoHash,
      fileIndex: fileIndex,
    );
  }

  String _addonName(String name) {
    final cleaned = name.replaceAll(RegExp(r'[\[\]⚡⏳]'), ' ').trim();
    final parts = cleaned.split(RegExp(r'[\n|•]'));
    for (final part in parts) {
      if (part.trim().isNotEmpty) return part.trim();
    }
    return 'Unknown source';
  }

  VideoResolution? _resolution(String value) {
    final lower = value.toLowerCase();
    if (RegExp(r'\b(2160p?|4k|uhd)\b').hasMatch(lower)) {
      return VideoResolution.ultraHd2160;
    }
    if (RegExp(r'\b(1080p?|full[ ._-]?hd|fhd)\b').hasMatch(lower)) {
      return VideoResolution.fullHd1080;
    }
    if (RegExp(r'\b720p?\b').hasMatch(lower)) return VideoResolution.hd720;
    if (RegExp(r'\b(480p?|576p?|sd)\b').hasMatch(lower)) {
      return VideoResolution.sd;
    }
    return null;
  }

  VideoCodec _codec(String value) {
    final lower = value.toLowerCase();
    if (RegExp(r'\b(av1|av01)\b').hasMatch(lower)) return VideoCodec.av1;
    if (RegExp(r'\b(hevc|h[ ._-]?265|x265)\b').hasMatch(lower)) {
      return VideoCodec.hevc;
    }
    if (RegExp(r'\b(avc|h[ ._-]?264|x264)\b').hasMatch(lower)) {
      return VideoCodec.h264;
    }
    return VideoCodec.unknown;
  }

  HdrFormat _hdr(String value) {
    final lower = value.toLowerCase();
    if (RegExp(r'\b(dolby[ ._-]?vision|dovi|dv)\b').hasMatch(lower)) {
      return HdrFormat.dolbyVision;
    }
    if (RegExp(r'\bhdr10\+\b').hasMatch(lower)) return HdrFormat.hdr10Plus;
    if (RegExp(r'\b(hdr10|hdr)\b').hasMatch(lower)) return HdrFormat.hdr10;
    if (RegExp(r'\bsdr\b').hasMatch(lower)) return HdrFormat.sdr;
    return HdrFormat.unknown;
  }

  CacheStatus _cacheStatus(String value) {
    final lower = value.toLowerCase();
    if (value.contains('⚡') ||
        lower.contains('cached') && !lower.contains('uncached') ||
        lower.contains('instant')) {
      return CacheStatus.cached;
    }
    if (value.contains('⏳') ||
        lower.contains('uncached') ||
        lower.contains('needs caching')) {
      return CacheStatus.uncached;
    }
    return CacheStatus.unknown;
  }

  Set<String> _audioLanguages(String value) {
    var audioText = value;
    audioText = audioText.replaceAll(
      RegExp(r'(subs?|subtitles?)[^\n]{0,100}', caseSensitive: false),
      '',
    );
    return _languages(audioText);
  }

  Set<String> _subtitleLanguages(String value) {
    final matches = RegExp(
      r'(subs?|subtitles?)[^\n]{0,100}',
      caseSensitive: false,
    ).allMatches(value);
    return _languages(matches.map((match) => match.group(0)).join(' '));
  }

  Set<String> _languages(String value) {
    const aliases = <String, List<String>>{
      'English': ['english', 'eng', 'en'],
      'Dutch': ['dutch', 'nederlands', 'nld', 'dut', 'nl'],
      'German': ['german', 'deutsch', 'ger', 'deu', 'de'],
      'French': ['french', 'français', 'fre', 'fra', 'fr'],
      'Spanish': ['spanish', 'español', 'spa', 'es'],
      'Italian': ['italian', 'italiano', 'ita', 'it'],
      'Japanese': ['japanese', 'jpn', 'ja'],
      'Korean': ['korean', 'kor', 'ko'],
      'Chinese': ['chinese', 'mandarin', 'zho', 'chi', 'zh'],
    };
    final lower = value.toLowerCase();
    final result = <String>{};
    for (final entry in aliases.entries) {
      for (final alias in entry.value) {
        if (RegExp('(?:^|[^a-z])${RegExp.escape(alias)}(?:[^a-z]|\$)')
            .hasMatch(lower)) {
          result.add(entry.key);
          break;
        }
      }
    }
    return result;
  }

  int? _sizeBytes(String value) {
    final matches = RegExp(
      r'(\d+(?:[.,]\d+)?)\s*(TB|GB|GiB|MB|MiB)\b',
      caseSensitive: false,
    ).allMatches(value).toList();
    if (matches.isEmpty) return null;
    final match = matches.last;
    final amount = double.tryParse(match.group(1)!.replaceAll(',', '.'));
    if (amount == null) return null;
    final unit = match.group(2)!.toLowerCase();
    final multiplier = switch (unit) {
      'tb' => 1000000000000,
      'gb' || 'gib' => 1000000000,
      'mb' || 'mib' => 1000000,
      _ => 1,
    };
    return (amount * multiplier).round();
  }

  Set<String> _releaseTags(String value) {
    final lower = value.toLowerCase();
    final result = <String>{};
    const patterns = <String, String>{
      'cam': r'\b(hd[ ._-]?cam|camrip|cam)\b',
      'telesync': r'\b(ts|telesync|telecine)\b',
      'screener': r'\b(dvdscr|screener|scr)\b',
      'remux': r'\bremux\b',
      'bluray': r'\b(bluray|blu[ ._-]?ray|bdrip)\b',
      'webdl': r'\bweb[ ._-]?dl\b',
      'webrip': r'\bweb[ ._-]?rip\b',
    };
    for (final entry in patterns.entries) {
      if (RegExp(entry.value).hasMatch(lower)) result.add(entry.key);
    }
    return result;
  }

  String _asString(Object? value) => value is String ? value : '';

  int? _asInt(Object? value) => switch (value) {
    int number => number,
    String text => int.tryParse(text),
    _ => null,
  };
}
