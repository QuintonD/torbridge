import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:torbridge/services/download_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'Android cannot-resume and destination-conflict codes stay distinct',
    () {
      const interrupted = DownloadFailureException(1008);
      const conflict = DownloadFailureException(1009);
      expect(interrupted.description, contains('could not resume'));
      expect(interrupted.isRetryableSourceFailure, isTrue);
      expect(conflict.description, 'the file already exists');
      expect(conflict.isRetryableSourceFailure, isFalse);
    },
  );

  test(
    'local file checks open raw and encoded paths, reject missing/empty files',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'torbridge-download-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File(
        '${directory.path}${Platform.pathSeparator}Movie #1.mp4',
      );
      final service = DioDownloadService();
      expect(await service.resolveLocalPath(), isNull);
      expect(await service.resolveLocalPath(localPath: file.path), isNull);
      await file.writeAsBytes([]);
      expect(await service.resolveLocalPath(localPath: file.path), isNull);
      await file.writeAsBytes([1, 2, 3]);
      expect(await service.resolveLocalPath(localPath: file.path), file.path);
      expect(
        await service.resolveLocalPath(localPath: file.uri.toString()),
        file.path,
      );
    },
  );

  const channel = MethodChannel('app.torbridge/downloads');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'Android checks expected size and headroom without deleting anything',
    () async {
      var free = 6000000000;
      final calls = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        return free;
      });
      final service = AndroidSystemDownloadService();
      await service.checkAvailableSpace(4900000000);
      free = 5000000000;
      await expectLater(
        service.checkAvailableSpace(4900000000),
        throwsA(isA<DownloadStorageException>()),
      );
      free = 100000000;
      await expectLater(
        service.checkAvailableSpace(null),
        throwsA(isA<DownloadStorageException>()),
      );
      expect(calls, everyElement('availableBytes'));
    },
  );

  test(
    'Android waiting reasons are visible and clear when transfer progresses',
    () async {
      final states = <Map<String, Object>>[
        {'state': 'queued'},
        {'state': 'paused', 'reason': 1},
        {'state': 'paused', 'reason': 2},
        {'state': 'paused', 'reason': 3},
        {'state': 'downloading', 'downloaded': 1, 'total': 3},
        {'state': 'complete', 'localPath': '/movie.mp4'},
      ];
      messenger.setMockMethodCallHandler(
        channel,
        (call) async => call.method == 'status'
            ? states.removeAt(0)
            : call.method == 'inspectFile'
            ? {'bytes': 64, 'header': List<int>.filled(64, 42)}
            : '/movie.mp4',
      );
      final service = AndroidSystemDownloadService();
      final messages = <String?>[];
      await service.resume(
        jobId: 'movie',
        platformId: '1986',
        onProgress: (_, _) => messages.add(service.downloadStatus('movie')),
      );
      expect(messages, [
        contains('Waiting for Android'),
        contains('waiting to retry'),
        contains('network connection'),
        contains('Wi-Fi'),
        null,
        null,
      ]);
      expect(service.downloadStatus('movie'), isNull);
    },
  );

  test(
    'Android deletion failure is propagated instead of discarding the record',
    () async {
      messenger.setMockMethodCallHandler(channel, (_) async => false);
      await expectLater(
        AndroidSystemDownloadService().delete('/movie.mp4'),
        throwsA(isA<StateError>()),
      );
      messenger.setMockMethodCallHandler(channel, (_) async => true);
      await AndroidSystemDownloadService().delete('/movie.mp4');
    },
  );

  test(
    'retention failure keeps the readable original and reports a warning',
    () async {
      final service = AndroidSystemDownloadService();
      messenger.setMockMethodCallHandler(channel, (_) async {
        throw PlatformException(
          code: 'retention_failed',
          message: 'Original kept. Run Diagnostics again.',
          details: '/original.mp4',
        );
      });
      expect(
        await service.resolveLocalPath(localPath: '/original.mp4'),
        '/original.mp4',
      );
      expect(
        service.localFileWarning('/original.mp4'),
        contains('Original kept'),
      );
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => '/library/original.mp4',
      );
      expect(
        await service.resolveLocalPath(localPath: '/original.mp4'),
        '/library/original.mp4',
      );
      expect(service.localFileWarning('/original.mp4'), isNull);
      expect(service.localFileWarning('/library/original.mp4'), isNull);
    },
  );

  test(
    'Android checks a completed transfer and recovers its current source',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'status') {
          return {
            'state': 'complete',
            'localPath': '/old/movie.mp4',
            'total': 64,
            'downloaded': 64,
          };
        }
        if (call.method == 'inspectFile') {
          return {'bytes': 64, 'header': List<int>.filled(64, 42)};
        }
        expect(call.method, 'resolve');
        expect(call.arguments, {'path': '/old/movie.mp4', 'id': 1986});
        return 'content://downloads/my_downloads/1986';
      });
      expect(
        await AndroidSystemDownloadService().resume(
          jobId: 'movie',
          platformId: '1986',
          onProgress: (_, _) {},
        ),
        'content://downloads/my_downloads/1986',
      );
    },
  );

  test(
    'Android does not report success for an unreadable completed transfer',
    () async {
      messenger.setMockMethodCallHandler(
        channel,
        (call) async => call.method == 'status'
            ? {'state': 'complete', 'localPath': '/missing.mp4'}
            : null,
      );
      await expectLater(
        AndroidSystemDownloadService().resume(
          jobId: 'movie',
          platformId: '1986',
          onProgress: (_, _) {},
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('unavailable'),
          ),
        ),
      );
    },
  );
}
