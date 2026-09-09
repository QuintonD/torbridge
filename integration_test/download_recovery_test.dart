import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
        expect(path, contains('/TorBridge/Library/'));
        final oldContent = 'content://downloads/my_downloads/$platformId';
        expect(await downloads.resolveLocalPath(localPath: oldContent), path);
        final content = Uri(
          scheme: 'content',
          host: 'app.torbridge.torbridge.files',
          pathSegments: [
            'movies',
            ...path.split('/Movies/TorBridge/').last.split('/'),
          ],
        ).toString();
        expect(await downloads.resolveLocalPath(localPath: content), content);

        // Android idle cleanup deletes this system record and its original path.
        // The independent library file must survive that exact deletion.
        await downloads.delete(oldContent);
        expect(await File(path).readAsBytes(), bytes);
        expect(
          await downloads.resume(
            jobId: 'recovery-fixture',
            platformId: platformId!,
            onProgress: (_, _) {},
          ),
          path,
        );

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

  testWidgets('completion receiver retains downloads without Flutter polling', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    const channel = MethodChannel('app.torbridge/downloads');
    final bytes = List<int>.generate(128, (i) => i);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final subscription = server.listen((request) async {
      request.response.contentLength = bytes.length;
      request.response.add(bytes);
      await request.response.close();
    });
    final service = AndroidSystemDownloadService();
    int? id;
    String? secondId;
    String? migratedPath;
    try {
      final created = await channel.invokeMapMethod<String, dynamic>(
        'enqueue',
        {
          'url': 'http://127.0.0.1:${server.port}/fixture.mp4',
          'filename': 'same-title.mp4',
        },
      );
      id = (created!['id'] as num).toInt();
      final original = created['path'] as String;
      String? retained;
      // Deliberately do not call resolve/download/resume; only the receiver can retain it.
      for (var i = 0; i < 100; i++) {
        final status = await channel.invokeMapMethod<String, dynamic>(
          'status',
          {'id': id},
        );
        final location = status?['localPath'] as String?;
        if (status?['state'] == 'complete' &&
            location?.contains('/Library/') == true) {
          retained = location;
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(retained, isNotNull);
      expect(await File(original).exists(), isFalse);
      expect(await File(retained!).readAsBytes(), bytes);
      await service.delete('content://downloads/my_downloads/$id');
      expect(
        await service.resolveLocalPath(localPath: original, platformId: '$id'),
        retained,
      );

      final second = await service.download(
        jobId: 'second-fixture',
        url: Uri.parse('http://127.0.0.1:${server.port}/fixture.mp4'),
        suggestedName: 'same-title.mp4',
        onProgress: (_, _) {},
        onEnqueued: (value) => secondId = value,
      );
      expect(second, isNot(retained));
      expect(await File(retained).readAsBytes(), bytes);
      expect(await File(second).readAsBytes(), bytes);

      // Upgrade migration for older records with no platform ID, and crash recovery
      // when Flutter still holds the old path after the native rename.
      final base = retained.substring(0, retained.indexOf('/Library/'));
      final legacy = File(
        '$base/legacy-${DateTime.now().microsecondsSinceEpoch}.mp4',
      );
      await legacy.writeAsBytes(bytes);
      migratedPath = await service.resolveLocalPath(localPath: legacy.path);
      expect(migratedPath, contains('/Library/'));
      expect(await legacy.exists(), isFalse);
      expect(await File(migratedPath!).readAsBytes(), bytes);
      expect(
        await AndroidSystemDownloadService().resolveLocalPath(
          localPath: legacy.path,
        ),
        migratedPath,
      );
    } finally {
      if (id != null) {
        await service.cancel(jobId: 'receiver-fixture', platformId: '$id');
      }
      if (migratedPath != null) await service.delete(migratedPath);
      if (secondId != null) {
        await service.cancel(jobId: 'second-fixture', platformId: secondId);
      }
      await subscription.cancel();
      await server.close(force: true);
    }
  });
}
