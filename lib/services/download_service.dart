import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'file_integrity.dart';

typedef DownloadProgressCallback = void Function(int received, int total);
typedef DownloadEnqueuedCallback = void Function(String platformId);

class DownloadFailureException implements Exception {
  const DownloadFailureException(
    this.reason, {
    this.host,
    this.receivedBytes = 0,
  });

  final int reason;
  final String? host;
  final int receivedBytes;

  // A new DownloadManager job cannot resume the old job's bytes. In particular,
  // 1008 can follow a partial transfer even when the final byte counter is zero.
  bool get allowsAutomaticSourceRecovery =>
      isRetryableSourceFailure && reason != 1008 && receivedBytes == 0;

  bool get isRetryableSourceFailure =>
      reason == 400 ||
      reason == 401 ||
      reason == 403 ||
      reason == 404 ||
      reason == 408 ||
      reason == 410 ||
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
    1006 => 'Android reported insufficient storage. Check free space or choose a smaller file, then retry',
    1007 => 'the target device was unavailable',
    1008 => 'Android could not resume the interrupted download',
    1009 => 'the file already exists',
    _ => 'Android error $reason',
  };

  @override
  String toString() => description;

  static String _httpLabel(int status) => switch (status) {
    400 => ' (Request rejected by Android or the server)',
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

  int get maxConcurrentDownloads => 0x7fffffff;

  Future<int?> availableBytes() async => null;

  Future<void> checkAvailableSpace(int? expectedBytes) async {}

  Future<Map<String, dynamic>> storageSnapshot(List<String> paths) async =>
      const {'roots': <String>[]};
  Future<FileInspection> inspectFile(
    String path, {
    String? platformId,
    int? expectedBytes,
  }) => inspectMediaFile(path, expectedBytes: expectedBytes);
  Future<FileInspection> validateCompleted(
    String path, {
    String? platformId,
    int? expectedBytes,
  }) async {
    final inspection = await inspectFile(
      path,
      platformId: platformId,
      expectedBytes: expectedBytes,
    );
    if (inspection.invalid) throw DownloadIntegrityException(path, inspection);
    return inspection;
  }

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
  final Map<String, String> _integrityWarnings = {};
  final Map<String, String> _downloadStatuses = {};

  @override
  int get maxConcurrentDownloads => 1;

  @override
  Future<Map<String, dynamic>> storageSnapshot(List<String> paths) async =>
      await _channel.invokeMapMethod<String, dynamic>('storageSnapshot', {
        'paths': paths,
      }) ??
      const {};

  @override
  Future<FileInspection> inspectFile(
    String path, {
    String? platformId,
    int? expectedBytes,
  }) async {
    final probe = await _channel.invokeMapMethod<String, dynamic>(
      'inspectFile',
      {'path': path, 'id': int.tryParse(platformId ?? '')},
    );
    if (probe == null || probe['changed'] == true) {
      return const FileInspection(
        'unverified',
        'File check was unavailable or the file changed during inspection.',
      );
    }
    if (probe['missing'] == true) {
      return const FileInspection('missing', 'File is missing or unreadable.');
    }
    final bytes = (probe['bytes'] as num?)?.toInt() ?? -1;
    if (bytes < 0) {
      return const FileInspection(
        'unverified',
        'Content length is unavailable; integrity is unverified.',
      );
    }
    final expected = expectedBytes ?? (probe['expected'] as num?)?.toInt();
    return inspectMediaHeader(
      (probe['header'] as List? ?? []).cast<int>(),
      bytes,
      expectedBytes: expected != null && expected > 0 ? expected : null,
    );
  }

  @override
  Future<int?> availableBytes() => _channel.invokeMethod<int>('availableBytes');

  @override
  Future<void> checkAvailableSpace(int? expectedBytes) async {
    final available = await availableBytes();
    if (available == null) {
      throw StateError(
        'Could not check download storage. Run Diagnostics and retry.',
      );
    }
    // Metadata is an estimate; leave headroom for Android and other apps.
    const reserve = 512 * 1024 * 1024;
    final expected = expectedBytes != null && expectedBytes > 0
        ? expectedBytes
        : 0;
    if (available < expected + reserve) {
      throw DownloadStorageException(available, expected);
    }
  }

  @override
  String? downloadStatus(String jobId) => _downloadStatuses[jobId];

  @override
  String? localFileWarning(String path) =>
      _retentionWarnings[path] ?? _integrityWarnings[path];

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
      'jobId': jobId,
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
    var mostReceived = 0;
    var lastTotal = -1;
    await Future<void>.delayed(const Duration(seconds: 1));
    while (true) {
      final status = await _channel.invokeMapMethod<String, dynamic>('status', {
        'id': id,
      });
      if (status == null) throw StateError('Android lost the download record.');
      var received = (status['downloaded'] as num?)?.toInt() ?? 0;
      var total = (status['total'] as num?)?.toInt() ?? -1;
      if (received > mostReceived) mostReceived = received;
      if (total > 0) lastTotal = total;
      // Failed platform records can lose their counters. Keep the observed
      // progress as evidence, without implying those bytes are still readable.
      if (status['state'] == 'failed') {
        received = mostReceived;
        if (total <= 0) total = lastTotal;
      }
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
          final inspection = await validateCompleted(
            localPath,
            platformId: '$id',
            expectedBytes: total > 0 ? total : null,
          );
          _integrityWarnings[localPath] = inspection.detail;
          return localPath;
        case 'failed':
          final reason = (status['reason'] as num?)?.toInt() ?? 1000;
          throw DownloadFailureException(
            reason,
            host: status['host'] as String?,
            receivedBytes: mostReceived,
          );
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

class DownloadStorageException implements Exception {
  const DownloadStorageException(this.available, this.expected);

  final int available;
  final int expected;

  @override
  String toString() =>
      'Not enough space for this download: ${(available / 1e9).toStringAsFixed(1)} GB available'
      '${expected > 0 ? ', about ${(expected / 1e9).toStringAsFixed(1)} GB needed' : ''}'
      ', plus 0.5 GB reserved for Android. Free space or choose a smaller file, then retry.';
}

class DioDownloadService extends DownloadService {
  DioDownloadService({Dio? dio}) : _dio = dio ?? Dio();

  final Dio _dio;
  final Map<String, CancelToken> _cancelTokens = {};
  final Map<String, String> _warnings = {};
  @override
  String? localFileWarning(String path) => _warnings[path];
  @override
  int get maxConcurrentDownloads => 2;
  @override
  Future<Map<String, dynamic>> storageSnapshot(List<String> paths) async => {
    'roots': [(await _downloadsDirectory()).path],
  };

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
      final response = await _dio.downloadUri(
        url,
        path,
        onReceiveProgress: onProgress,
        cancelToken: cancelToken,
        deleteOnError: true,
        options: Options(headers: requestHeaders),
      );
      final total = int.tryParse(
        response.headers.value(HttpHeaders.contentLengthHeader) ?? '',
      );
      final inspection = await validateCompleted(path, expectedBytes: total);
      _warnings[path] = inspection.detail;
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
