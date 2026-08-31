import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

abstract class DownloadService {
  Future<String> download({
    required Uri url,
    required String suggestedName,
    required void Function(int received, int total) onProgress,
  });
}

class AndroidSystemDownloadService implements DownloadService {
  static const _channel = MethodChannel('app.torbridge/downloads');

  @override
  Future<String> download({
    required Uri url,
    required String suggestedName,
    required void Function(int received, int total) onProgress,
  }) async {
    final id = await _channel.invokeMethod<int>('enqueue', {
      'url': url.toString(),
      'filename': suggestedName,
    });
    if (id == null) throw StateError('Android did not create the download.');

    while (true) {
      await Future<void>.delayed(const Duration(seconds: 1));
      final status = await _channel.invokeMapMethod<String, dynamic>('status', {
        'id': id,
      });
      if (status == null) throw StateError('Android lost the download record.');
      final received = (status['downloaded'] as num?)?.toInt() ?? 0;
      final total = (status['total'] as num?)?.toInt() ?? -1;
      onProgress(received, total);
      switch (status['state']) {
        case 'complete':
          final localUri = '${status['localUri'] ?? ''}';
          if (localUri.isEmpty) {
            throw StateError('Android completed the download without a URI.');
          }
          return localUri;
        case 'failed':
          throw StateError('Android download failed (${status['reason']}).');
      }
    }
  }
}

class DioDownloadService implements DownloadService {
  DioDownloadService({Dio? dio}) : _dio = dio ?? Dio();

  final Dio _dio;

  @override
  Future<String> download({
    required Uri url,
    required String suggestedName,
    required void Function(int received, int total) onProgress,
  }) async {
    final directory = await _downloadsDirectory();
    await directory.create(recursive: true);
    final path = _uniquePath(directory, suggestedName);
    await _dio.downloadUri(url, path, onReceiveProgress: onProgress);
    return path;
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
