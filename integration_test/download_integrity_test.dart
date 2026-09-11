import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:torbridge/services/download_service.dart';
import 'package:torbridge/services/file_integrity.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Android rejects and preserves an HTTP 200 HTML error page', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final bytes = '<html>Fixture upstream error</html>'.codeUnits;
    server.listen((request) async {
      request.response.headers.contentType = ContentType.html;
      request.response.contentLength = bytes.length;
      request.response.add(bytes);
      await request.response.close();
    });
    final service = AndroidSystemDownloadService();
    String? id;
    try {
      String? path;
      try {
        await service
            .download(
              jobId: 'audit-html',
              url: Uri.parse('http://127.0.0.1:${server.port}/error.mp4'),
              suggestedName: 'audit-error.mp4',
              onProgress: (_, _) {},
              onEnqueued: (value) => id = value,
            )
            .timeout(const Duration(seconds: 45));
        fail('HTML must not be accepted as a completed video');
      } on DownloadIntegrityException catch (error) {
        path = error.path;
      }
      expect(await File(path).readAsBytes(), bytes);
      expect(path, contains('/Library/'));
    } finally {
      await service.cancel(jobId: 'audit-html', platformId: id);
      await server.close(force: true);
    }
  });

  for (final changedValidator in [false, true]) {
    testWidgets(
      'Android does not append a full response to an interrupted file: changed validator=$changedValidator',
      (tester) async {
        await tester.pumpWidget(const MaterialApp(home: SizedBox()));
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final original = List<int>.generate(4096, (i) => i % 251);
        final replacement = List<int>.filled(4096, 42);
        var requests = 0;
        server.listen((request) async {
          requests++;
          if (requests == 1) {
            final socket = await request.response.detachSocket(
              writeHeaders: false,
            );
            socket.add(
              'HTTP/1.1 200 OK\r\nContent-Length: 4096\r\nETag: "original"\r\nConnection: close\r\n\r\n'
                  .codeUnits,
            );
            socket.add(original.take(1024).toList());
            await socket.flush();
            await socket.close();
          } else {
            request.response.statusCode = 200; // Deliberately ignores Range.
            request.response.headers.set(
              HttpHeaders.etagHeader,
              changedValidator ? '"changed"' : '"original"',
            );
            request.response.contentLength = 4096;
            request.response.add(changedValidator ? replacement : original);
            await request.response.close();
          }
        });
        final service = AndroidSystemDownloadService();
        String? id;
        try {
          try {
            final path = await service
                .download(
                  jobId: 'range-rejection-$changedValidator',
                  url: Uri.parse('http://127.0.0.1:${server.port}/fixture.mp4'),
                  suggestedName: 'fixture.mp4',
                  onProgress: (_, _) {},
                  onEnqueued: (value) => id = value,
                )
                .timeout(const Duration(minutes: 4));
            expect(
              await File(path).readAsBytes(),
              changedValidator ? replacement : original,
            );
          } on DownloadFailureException catch (error) {
            expect(error.reason, 1008);
          }
          expect(requests, greaterThanOrEqualTo(2));
        } finally {
          if (id != null) {
            await service.cancel(
              jobId: 'range-rejection-$changedValidator',
              platformId: id,
            );
          }
          await server.close(force: true);
        }
      },
    );
  }
  testWidgets(
    'Android resumes the same interrupted transfer with Range and ETag',
    (tester) async {
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      final bytes = List<int>.generate(4096, (i) => i % 251);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final ranges = <String?>[];
      final validators = <String?>[];
      server.listen((request) async {
        ranges.add(request.headers.value(HttpHeaders.rangeHeader));
        validators.add(request.headers.value(HttpHeaders.ifMatchHeader));
        if (ranges.length == 1) {
          final socket = await request.response.detachSocket(
            writeHeaders: false,
          );
          socket.add(
            'HTTP/1.1 200 OK\r\nContent-Length: 4096\r\nETag: "fixture-v1"\r\nAccept-Ranges: bytes\r\nConnection: close\r\n\r\n'
                .codeUnits,
          );
          socket.add(bytes.sublist(0, 1024));
          await socket.flush();
          await socket.close();
        } else {
          final start =
              int.tryParse(
                RegExp(r'bytes=(\d+)-')
                        .firstMatch(ranges.last ?? '')
                        ?.group(1) ??
                    '',
              ) ??
              0;
          request.response.statusCode = start == 0 ? 200 : 206;
          request.response.headers.set(HttpHeaders.etagHeader, '"fixture-v1"');
          if (start > 0) {
            request.response.headers.set(
              HttpHeaders.contentRangeHeader,
              'bytes $start-4095/4096',
            );
          }
          request.response.contentLength = bytes.length - start;
          request.response.add(bytes.sublist(start));
          await request.response.close();
        }
      });
      final service = AndroidSystemDownloadService();
      final nativeIds = <String>[];
      final waits = <String>{};
      try {
        final path = await service
            .download(
              jobId: 'audit-resume',
              url: Uri.parse('http://127.0.0.1:${server.port}/resume.mp4'),
              suggestedName: 'audit-resume.mp4',
              onEnqueued: nativeIds.add,
              onProgress: (_, _) {
                final message = service.downloadStatus('audit-resume');
                if (message != null) waits.add(message);
              },
            )
            .timeout(const Duration(minutes: 4));
        expect(await File(path).readAsBytes(), bytes);
        expect(nativeIds, hasLength(1));
        expect(ranges.skip(1), contains('bytes=1024-'));
        expect(validators.skip(1), contains('"fixture-v1"'));
        final snapshot = await service.storageSnapshot([path]);
        expect(
          (snapshot['native'] as List).any((r) => r['jobId'] == 'audit-resume'),
          isTrue,
        );
        await File(path).writeAsBytes(bytes.take(1024).toList());
        final damaged = await service.inspectFile(
          path,
          platformId: nativeIds.single,
        );
        expect(damaged.invalid, isTrue);
        expect(damaged.detail, contains('4096'));
        expect(await File(path).length(), 1024);
        // The same native job survives; this is transfer interruption, not an RF test.
      } finally {
        for (final id in nativeIds) {
          await service.cancel(jobId: 'audit-resume', platformId: id);
        }
        await server.close(force: true);
      }
    },
  );
}
