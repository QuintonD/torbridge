import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

typedef DownloadProgressCallback = void Function(int received, int total);
typedef DownloadEnqueuedCallback = void Function(String platformId);

class DownloadFailureException implements Exception {
  const DownloadFailureException(this.reason);

  final int reason;

  bool get isRetryableSourceFailure =>
      reason == 401 ||
      reason == 403 ||
      reason == 404 ||
      reason == 408 ||
      reason == 410 ||
      reason == 429 ||
      reason >= 500 && reason <= 599 ||
      reason == 1002 ||
      reason == 1004 ||
      reason == 1008;

  String get description => switch (reason) {
    >= 400 && <= 599 => 'HTTP $reason${_httpLabel(reason)}',
    1000 => 'an unknown Android download error',
    1001 => 'a file error',
    1002 => 'an unhandled HTTP response',
    1004 => 'an HTTP transfer error',
    1005 => 'too many redirects',
    1006 => 'insufficient storage',
    1007 => 'the target device was unavailable',
    1008 => 'Android could not resume the interrupted download',
    1009 => 'the file already exists',
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

  /// Returns a readable local source, or null if the saved file is unavailable.
  /// Android also moves completed app-private files out of DownloadManager's
  /// cleanup path. Never starts a network transfer or discards video data.
  Future<String?> resolveLocalPath({
    String? localPath,
    String? platformId,
  }) async {
    if (localPath == null || localPath.isEmpty) return null;
    try {
      final uri = Uri.tryParse(localPath);
      final file = uri?.scheme == 'file' ? File.fromUri(uri!) : File(localPath);
      final input = await file.open();
      try {
        return await input.length() > 0 ? file.path : null;
      } finally {
        await input.close();
      }
    } on FileSystemException {
      return null;
    }
  }

  String? localFileWarning(String path) => null;

  /// Explains a system-managed wait without treating it as a failed download.
  String? downloadStatus(String jobId) => null;

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
  final Map<String, String> _retentionWarnings = {};
  final Map<String, String> _downloadStatuses = {};

  @override
  String? downloadStatus(String jobId) => _downloadStatuses[jobId];

  @override
  String? localFileWarning(String path) => _retentionWarnings[path];

  @override
  Future<String?> resolveLocalPath({
    String? localPath,
    String? platformId,
  }) async {
    try {
      final resolved = await _channel.invokeMethod<String>('resolve', {
        'path': localPath,
        'id': int.tryParse(platformId ?? ''),
      });
      _retentionWarnings.remove(localPath);
      _retentionWarnings.remove(resolved);
      return resolved;
    } on PlatformException catch (error) {
      if (error.code != 'retention_failed' || error.details is! String) rethrow;
      // Native code verified the original before attempting a safe rename.
      // Keep playback available and report protection failure separately.
      final source = error.details as String;
      _retentionWarnings[source] = error.message ?? 'Could not protect this video from Android cleanup. Run Diagnostics again.';
      return source;
    }
  }

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
    return _waitForDownload(jobId, id, onProgress);
  }

  @override
  Future<String> resume({
    required String jobId,
    required String platformId,
    required DownloadProgressCallback onProgress,
  }) async {
    final id = int.tryParse(platformId);
    if (id == null) throw StateError('Invalid Android download ID.');
    return _waitForDownload(jobId, id, onProgress);
  }

  Future<String> _waitForDownload(
    String jobId,
    int id,
    DownloadProgressCallback onProgress,
  ) async {
    try {
      return await _pollDownload(jobId, id, onProgress);
    } finally {
      _downloadStatuses.remove(jobId);
    }
  }

  Future<String> _pollDownload(
    String jobId,
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
      final message = switch (status['state']) {
        'queued' => 'Waiting for Android to start the download…',
        'paused' => switch (status['reason']) {
          1 => 'Connection interrupted — Android is waiting to retry…',
          2 => 'Waiting for a network connection…',
          3 => 'Waiting for Wi-Fi…',
          _ => 'Download paused by Android…',
        },
        _ => null,
      };
      if (message == null) {
        _downloadStatuses.remove(jobId);
      } else {
        _downloadStatuses[jobId] = message;
      }
      onProgress(received, total);
      switch (status['state']) {
        case 'complete':
          final localPath = await resolveLocalPath(
            localPath: status['localPath'] as String?,
            platformId: '$id',
          );
          if (localPath == null) {
            throw StateError(
              'Android finished the transfer, but the video file is unavailable. Retry the download.',
            );
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
    final deleted = await _channel.invokeMethod<bool>('delete', {
      'path': localPath,
    });
    if (deleted != true) {
      throw StateError(
        'Android could not delete the downloaded file. The record was kept; try again.',
      );
    }
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
    // createTemp atomically reserves a directory for this attempt. Concurrent
    // transfers cannot select or overwrite each other's destination.
    final attempt = await directory.createTemp('transfer-');
    final path = '${attempt.path}${Platform.pathSeparator}$suggestedName';
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
}
