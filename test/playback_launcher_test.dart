import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:torbridge/services/playback_launcher.dart';

void main() {
  test(
    'Stremio receives a complete local stream without online detail lookup',
    () {
      final media = Uri.parse('http://127.0.0.1:11471/media/episode%20one');
      final uri = stremioPlaybackUri(media, 'Épisode / 1');
      expect(uri.scheme, 'stremio');
      expect(uri.pathSegments.first, 'player');
      expect(uri.pathSegments, hasLength(2));
      final stream = jsonDecode(
        utf8.decode(zlib.decode(base64Decode(uri.pathSegments[1]))),
      );
      expect(stream['url'], media.toString());
      expect(stream['title'], 'Épisode / 1');
      expect(stream['behaviorHints']['notWebReady'], isTrue);
      expect(uri.query, isEmpty);
    },
  );
}
