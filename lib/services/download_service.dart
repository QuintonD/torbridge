import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

typedef DownloadProgressCallback = void Function(int received, int total);
typedef DownloadEnqueuedCallback = void Function(String platformId);

class DownloadFailureException implements Exception {
  const DownloadFailureException(this.reason);

  final int reason;

  bool get isRetryableHttpFailure =>
      reason == 401 ||
      reason == 403 ||
      reason == 404 ||
      reason == 408 ||
      reason == 410 ||
      reason == 429 ||
      reason >= 500 && reason <= 599 ||
      reason == 1002 ||
      reason == 1004;

  String get description => switch (reason) {
    >= 400 && <= 599 => 'HTTP $reason${_httpLabel(reason)}',
    1000 => 'an unknown Android download error',
    1001 => 'a file error',
    1002 => 'an unhandled HTTP response',
    1004 => 'an HTTP transfer error',
    1005 => 'too many redirects',
    1006 => 'insufficient storage',
    1007 => 'the target device was unavailable',
    1008 => 'the file already exists',
    _ => 'Android error $reason',
  };

  @override
  String toString() => description;

  static String _httpLabel(int status) => switch (status) {
    401 => ' (Unauthorized)',
    403 => ' (Forbidden or expired link)',
    404 => ' (Not Found)',
    408 => ' (Request Timeout)',
    410 => ' (Expired link)',
    429 => ' (Rate Limited)',
    500 => ' (Server Error)',
    502 => ' (Bad Gateway)',
    503 => ' (Service Unavailable)',
    504 => ' (Gateway Timeout)',
    _ => '',
  };
}

abstract class DownloadService {
  bool get supportsResume => false;

  Future<String> download({
    required String jobId,
    required Uri url,
    required String suggestedName,
    required DownloadProgressCallback onProgress,
    DownloadEnqueuedCallback? onEnqueued,
    Map<String, String> requestHeaders = const {},
  });

  Future<String> resume({
    required String jobId,
    required String platformId,
    required DownloadProgressCallback onProgress,
  }) =>
      Future.error(StateError('Downloads cannot be resumed on this platform.'));

  Future<void> cancel({required String jobId, String? platformId}) async {}

  Future<void> delete(String localPath) async {
    final uri = Uri.tryParse(localPath);
    final file = uri?.scheme == 'file' ? File.fromUri(uri!) : File(localPath);
    if (await file.exists()) await file.delete();
  }
}

class AndroidSystemDownloadService extends DownloadService {
  static const _channel = MethodChannel('app.torbridge/downloads');

  @override
  bool get supportsResume => true;

  @override
  Future<String> download({
    required String jobId,
    required Uri url,
    required String suggestedName,
    required DownloadProgressCallback onProgress,
    DownloadEnqueuedCallback? onEnqueued,
    Map<String, String> requestHeaders = const {},
  }) async {
    final result = await _channel.invokeMapMethod<String, dynamic>('enqueue', {
      'url': url.toString(),
      'filename': suggestedName,
      'headers': requestHeaders,
    });
    final id = (result?['id'] as num?)?.toInt();
    if (id == null) throw StateError('Android did not create the download.');
    onEnqueued?.call('$id');
    return _waitForDownload(id, onProgress);
  }

  @override
  Future<String> resume({
    required String jobId,
    required String platformId,
    required DownloadProgressCallback onProgress,
  }) async {
    final id = int.tryParse(platformId);
    if (id == null) throw StateError('Invalid Android download ID.');
    return _waitForDownload(id, onProgress);
  }

  Future<String> _waitForDownload(
    int id,
    DownloadProgressCallback onProgress,
  ) async {
    await Future<void>.delayed(const Duration(seconds: 1));
    while (true) {
      final status = await _channel.invokeMapMethod<String, dynamic>('status', {
        'id': id,
      });
      if (status == null) throw StateError('Android lost the download record.');
      final received = (status['downloaded'] as num?)?.toInt() ?? 0;
      final total = (status['total'] as num?)?.toInt() ?? -1;
      onProgress(received, total);
      switch (status['state']) {
        case 'complete':
          final localPath = '${status['localPath'] ?? ''}';
          if (localPath.isEmpty) {
            throw StateError('Android completed the download without a path.');
          }
          return localPath;
        case 'failed':
          final reason = (status['reason'] as num?)?.toInt() ?? 1000;
          throw DownloadFailureException(reason);
        case 'missing':
          throw StateError('Android no longer has this download.');
      }
      await Future<void>.delayed(const Duration(seconds: 1));
    }
  }

  @override
  Future<void> cancel({required String jobId, String? platformId}) async {
    final id = int.tryParse(platformId ?? '');
    if (id != null) await _channel.invokeMethod<void>('cancel', {'id': id});
  }

  @override
  Future<void> delete(String localPath) async {
    await _channel.invokeMethod<void>('delete', {'path': localPath});
  }
}

class DioDownloadService extends DownloadService {
  DioDownloadService({Dio? dio}) : _dio = dio ?? Dio();

  final Dio _dio;
  final Map<String, CancelToken> _cancelTokens = {};

  @override
  Future<String> download({
    required String jobId,
    required Uri url,
    required String suggestedName,
    required DownloadProgressCallback onProgress,
    DownloadEnqueuedCallback? onEnqueued,
    Map<String, String> requestHeaders = const {},
  }) async {
    final directory = await _downloadsDirectory();
    await directory.create(recursive: true);
    final path = _uniquePath(directory, suggestedName);
    final cancelToken = CancelToken();
    _cancelTokens[jobId] = cancelToken;
    onEnqueued?.call(jobId);
    try {
      await _dio.downloadUri(
        url,
        path,
        onReceiveProgress: onProgress,
        cancelToken: cancelToken,
        deleteOnError: true,
        options: Options(headers: requestHeaders),
      );
      return path;
    } finally {
      _cancelTokens.remove(jobId);
    }
  }

  @override
  Future<void> cancel({required String jobId, String? platformId}) async {
    _cancelTokens.remove(jobId)?.cancel('Cancelled by user.');
  }

  Future<Directory> _downloadsDirectory() async {
    if (Platform.isWindows) {
      final downloads = await getDownloadsDirectory();
      if (downloads != null) return Directory('${downloads.path}/TorBridge');
    }
    final external = await getExternalStorageDirectory();
    if (external != null) return Directory('${external.path}/TorBridge');
    final documents = await getApplicationDocumentsDirectory();
    return Directory('${documents.path}/TorBridge');
  }

  String _uniquePath(Directory directory, String filename) {
    final dot = filename.lastIndexOf('.');
    final base = dot > 0 ? filename.substring(0, dot) : filename;
    final extension = dot > 0 ? filename.substring(dot) : '';
    var path = '${directory.path}${Platform.pathSeparator}$filename';
    var suffix = 2;
    while (File(path).existsSync()) {
      path =
          '${directory.path}${Platform.pathSeparator}$base ($suffix)$extension';
      suffix++;
    }
    return path;
  }
}
