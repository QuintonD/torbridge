import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:torbridge/services/stremio_bridge_service.dart';

void main() {
  test(
    'local Stremio addon maps an exact episode and supports byte ranges',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'torbridge-server-test-',
      );
      final file = File(
        '${directory.path}${Platform.pathSeparator}Show.S01E02.mkv',
      );
      await file.writeAsBytes(List<int>.generate(32, (index) => index));
      final service = DartStremioBridgeService();
      addTearDown(() async {
        await service.stop();
        await directory.delete(recursive: true);
      });
      await service.start([
        StremioBridgeEntry(
          id: 'bridge-entry',
          type: 'series',
          videoId: 'tt0108778:1:2',
          showId: 'tt0108778',
          title: 'Show S01E02',
          filename: 'Show.S01E02.mkv',
          localPath: file.path,
          description: '4K • HEVC • Subs: Dutch, English',
          sizeBytes: 32,
        ),
      ]);

      final manifest = await _get(
        Uri.parse('http://127.0.0.1:11471/manifest.json'),
      );
      expect(manifest.status, HttpStatus.ok);
      final manifestJson = jsonDecode(utf8.decode(manifest.body));
      expect(manifestJson['id'], 'app.torbridge.offline');
      expect(manifestJson['catalogs'], isEmpty);

      final streams = await _get(
        Uri.parse(
          'http://127.0.0.1:11471/stream/series/'
          '${Uri.encodeComponent('tt0108778:1:2')}.json',
        ),
      );
      final payload =
          jsonDecode(utf8.decode(streams.body)) as Map<String, dynamic>;
      final stream =
          (payload['streams'] as List).single as Map<String, dynamic>;
      expect(stream['name'], 'TorBridge Offline');
      expect(stream['description'], contains('Subs: Dutch, English'));
      expect(
        (stream['behaviorHints'] as Map)['bingeGroup'],
        'torbridge-offline-tt0108778',
      );

      final range = await _get(
        Uri.parse('http://127.0.0.1:11471/media/bridge-entry'),
        range: 'bytes=2-5',
      );
      expect(range.status, HttpStatus.partialContent);
      expect(range.body, [2, 3, 4, 5]);
      for (final invalid in [
        'bytes=32-',
        'bytes=8-2',
        'bytes=-0',
        'bytes=0-nope',
      ]) {
        final response = await _get(
          Uri.parse('http://127.0.0.1:11471/media/bridge-entry'),
          range: invalid,
        );
        expect(
          response.status,
          HttpStatus.requestedRangeNotSatisfiable,
          reason: invalid,
        );
      }
      final suffix = await _get(
        Uri.parse('http://127.0.0.1:11471/media/bridge-entry'),
        range: 'bytes=-3',
      );
      expect(suffix.body, [29, 30, 31]);
      final openEnded = await _get(
        Uri.parse('http://127.0.0.1:11471/media/bridge-entry'),
        range: 'bytes=30-',
      );
      expect(openEnded.body, [30, 31]);
      await file.writeAsBytes([]);
      final empty = await _get(
        Uri.parse('http://127.0.0.1:11471/media/bridge-entry'),
      );
      expect(empty.status, HttpStatus.ok);
      expect(empty.body, isEmpty);
    },
  );
}

Future<({int status, List<int> body})> _get(Uri uri, {String? range}) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(uri);
    if (range != null) request.headers.set(HttpHeaders.rangeHeader, range);
    final response = await request.close();
    final body = await response.fold<List<int>>(
      <int>[],
      (bytes, chunk) => bytes..addAll(chunk),
    );
    return (status: response.statusCode, body: body);
  } finally {
    client.close(force: true);
  }
}
