import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:torbridge/services/download_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
            'total': 3,
            'downloaded': 3,
          };
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
