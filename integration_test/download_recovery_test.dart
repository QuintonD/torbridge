import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:torbridge/services/download_service.dart';
import 'package:torbridge/services/stremio_bridge_service.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'Android resolves saved downloads and serves file/content ranges',
    (tester) async {
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      final bytes = List<int>.generate(1024, (i) => i % 256);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final subscription = server.listen((request) async {
        request.response.headers.contentType = ContentType('video', 'mp4');
        request.response.contentLength = bytes.length;
        request.response.add(bytes);
        await request.response.close();
      });
      final downloads = AndroidSystemDownloadService();
      final bridge = AndroidStremioBridgeService();
      String? platformId;
      final client = HttpClient();
      try {
        final path = await downloads
            .download(
              jobId: 'recovery-fixture',
              url: Uri.parse('http://127.0.0.1:${server.port}/fixture.mp4'),
              suggestedName:
                  'recovery-${DateTime.now().microsecondsSinceEpoch}.mp4',
              onProgress: (_, _) {},
              onEnqueued: (id) => platformId = id,
            )
            .timeout(const Duration(seconds: 45));
        expect(
          await downloads.resolveLocalPath(localPath: '$path.missing'),
          isNull,
        );
        expect(
          await downloads.resolveLocalPath(
            localPath: '$path.missing',
            platformId: platformId,
          ),
          path,
        );
        expect(await downloads.resolveLocalPath(platformId: platformId), path);
        final content = 'content://downloads/my_downloads/$platformId';
        expect(await downloads.resolveLocalPath(localPath: content), content);

        for (final source in [path, File(path).uri.toString(), content]) {
          await bridge.start([
            StremioBridgeEntry(
              id: 'fixture',
              type: 'movie',
              videoId: 'fixture',
              showId: 'fixture',
              title: 'Fixture',
              filename: 'fixture.mp4',
              localPath: source,
              description: '',
              sizeBytes: bytes.length,
            ),
          ]);
          expect(await bridge.ping(), isTrue);
          final uri = Uri.parse(
            'http://127.0.0.1:$stremioBridgePort/media/fixture',
          );
          for (final range in [null, 'bytes=123-345', 'bytes=-10']) {
            final request = await client.getUrl(uri);
            if (range != null) {
              request.headers.set(HttpHeaders.rangeHeader, range);
            }
            final response = await request.close();
            expect(response.statusCode, range == null ? 200 : 206);
            final body = await response.fold<List<int>>(
              [],
              (all, part) => all..addAll(part),
            );
            expect(
              body,
              range == null
                  ? bytes
                  : range == 'bytes=-10'
                  ? bytes.sublist(1014)
                  : bytes.sublist(123, 346),
            );
          }
          final head = await (await client.headUrl(uri)).close();
          expect(head.contentLength, bytes.length);
          await head.drain<void>();
          final invalid = await client.getUrl(uri);
          invalid.headers.set(HttpHeaders.rangeHeader, 'bytes=2000-');
          final response = await invalid.close();
          expect(response.statusCode, 416);
          await response.drain<void>();
        }
        await downloads.cancel(
          jobId: 'recovery-fixture',
          platformId: platformId,
        );
        expect(
          await downloads.resolveLocalPath(
            localPath: path,
            platformId: platformId,
          ),
          isNull,
        );
        expect(await downloads.resolveLocalPath(localPath: content), isNull);
      } finally {
        client.close(force: true);
        await bridge.stop();
        if (platformId != null) {
          await downloads.cancel(
            jobId: 'recovery-fixture',
            platformId: platformId,
          );
        }
        await subscription.cancel();
        await server.close(force: true);
      }
    },
  );
}
