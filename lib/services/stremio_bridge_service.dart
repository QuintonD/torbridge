import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';

// Stremio's Android streaming server owns 11470, so the addon bridge must use
// a different loopback port when both apps are running on the same device.
const stremioBridgePort = 11471;

class StremioBridgeEntry {
  const StremioBridgeEntry({
    required this.id,
    required this.type,
    required this.videoId,
    required this.showId,
    required this.title,
    required this.filename,
    required this.localPath,
    required this.description,
    required this.sizeBytes,
  });

  final String id;
  final String type;
  final String videoId;
  final String showId;
  final String title;
  final String filename;
  final String localPath;
  final String description;
  final int? sizeBytes;

  Map<String, dynamic> toJson() => {
    'id': id,
    'type': type,
    'videoId': videoId,
    'showId': showId,
    'title': title,
    'filename': filename,
    'localPath': localPath,
    'description': description,
    'sizeBytes': sizeBytes,
  };
}

abstract class StremioBridgeService {
  Uri get manifestUrl =>
      Uri.parse('http://127.0.0.1:$stremioBridgePort/manifest.json');

  Uri get installUrl => manifestUrl.replace(scheme: 'stremio');

  Future<void> start(List<StremioBridgeEntry> entries);

  Future<void> update(List<StremioBridgeEntry> entries);

  Future<bool> ping();

  Future<void> stop();
}

class AndroidStremioBridgeService extends StremioBridgeService {
  static const _channel = MethodChannel('app.torbridge/bridge');

  @override
  Future<void> start(List<StremioBridgeEntry> entries) async {
    await _channel.invokeMethod<void>('start', {
      'entries': jsonEncode(entries.map((entry) => entry.toJson()).toList()),
    });
  }

  @override
  Future<void> update(List<StremioBridgeEntry> entries) async {
    await _channel.invokeMethod<void>('update', {
      'entries': jsonEncode(entries.map((entry) => entry.toJson()).toList()),
    });
  }

  @override
  Future<bool> ping() async {
    for (var attempt = 0; attempt < 10; attempt++) {
      if (await _channel.invokeMethod<bool>('ping') ?? false) return true;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return false;
  }

  @override
  Future<void> stop() => _channel.invokeMethod<void>('stop');
}

class DartStremioBridgeService extends StremioBridgeService {
  HttpServer? _server;
  Map<String, StremioBridgeEntry> _entries = const {};

  @override
  Future<void> start(List<StremioBridgeEntry> entries) async {
    _entries = {for (final entry in entries) entry.id: entry};
    if (_server != null) return;
    _server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      stremioBridgePort,
      shared: true,
    );
    unawaited(_listen(_server!));
  }

  @override
  Future<void> update(List<StremioBridgeEntry> entries) async {
    _entries = {for (final entry in entries) entry.id: entry};
    if (_server == null) await start(entries);
  }

  @override
  Future<bool> ping() async {
    final client = HttpClient();
    try {
      final request = await client
          .getUrl(Uri.parse('http://127.0.0.1:$stremioBridgePort/health'))
          .timeout(const Duration(seconds: 2));
      final response = await request.close().timeout(
        const Duration(seconds: 2),
      );
      await response.drain<void>();
      return response.statusCode == HttpStatus.ok;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  @override
  Future<void> stop() async {
    final server = _server;
    _server = null;
    await server?.close(force: true);
  }

  Future<void> _listen(HttpServer server) async {
    await for (final request in server) {
      unawaited(_handle(request));
    }
  }

  Future<void> _handle(HttpRequest request) async {
    _cors(request.response);
    if (request.method == 'OPTIONS') {
      request.response.statusCode = HttpStatus.noContent;
      await request.response.close();
      return;
    }
    try {
      final segments = request.uri.pathSegments;
      if (request.uri.path == '/health') {
        await _json(request, {'status': 'ready', 'downloads': _entries.length});
        return;
      }
      if (request.uri.path == '/manifest.json') {
        await _json(request, _manifest);
        return;
      }
      if (segments.length == 3 && segments.first == 'stream') {
        final type = segments[1];
        final videoId = segments[2].replaceFirst(RegExp(r'\.json$'), '');
        final matches = _entries.values
            .where((entry) => entry.type == type && entry.videoId == videoId)
            .toList(growable: false);
        await _json(request, {
          'streams': [for (final entry in matches) _stream(entry)],
        });
        return;
      }
      if (segments.length == 2 && segments.first == 'media') {
        final entry = _entries[segments[1]];
        if (entry == null) {
          await _notFound(request);
          return;
        }
        await _serveFile(request, entry);
        return;
      }
      await _notFound(request);
    } catch (error) {
      try {
        request.response.statusCode = HttpStatus.internalServerError;
        request.response.write('TorBridge server error: $error');
        await request.response.close();
      } catch (_) {}
    }
  }

  Map<String, dynamic> get _manifest => const {
    'id': 'app.torbridge.offline',
    'version': '1.2.6',
    'name': 'TorBridge Offline',
    'description': 'Downloaded movies and episodes available on this device.',
    'resources': ['stream'],
    'types': ['movie', 'series'],
    'catalogs': <Object>[],
    'idPrefixes': ['tt'],
    'behaviorHints': {'configurable': false, 'p2p': false},
  };

  Map<String, dynamic> _stream(StremioBridgeEntry entry) => {
    'name': 'TorBridge Offline',
    'description': entry.description,
    'url':
        'http://127.0.0.1:$stremioBridgePort/media/${Uri.encodeComponent(entry.id)}',
    'behaviorHints': {
      'notWebReady': true,
      'filename': entry.filename,
      if (entry.sizeBytes != null) 'videoSize': entry.sizeBytes,
      'bingeGroup': 'torbridge-offline-${entry.showId}',
    },
  };

  Future<void> _serveFile(HttpRequest request, StremioBridgeEntry entry) async {
    final file = File(entry.localPath);
    if (!await file.exists()) {
      await _notFound(request);
      return;
    }
    final length = await file.length();
    final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
    final range = _range(rangeHeader, length);
    if (rangeHeader != null && range == null) {
      request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
      request.response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes */$length',
      );
      await request.response.close();
      return;
    }
    final start = range?.$1 ?? 0;
    final end = range?.$2 ?? length - 1;
    final response = request.response;
    response.headers
      ..set(HttpHeaders.acceptRangesHeader, 'bytes')
      ..contentType = ContentType('video', _videoSubtype(entry.filename));
    if (range != null) {
      response.statusCode = HttpStatus.partialContent;
      response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $start-$end/$length',
      );
    }
    response.contentLength = max(0, end - start + 1);
    if (request.method != 'HEAD' && length > 0) {
      await response.addStream(file.openRead(start, end + 1));
    }
    await response.close();
  }

  (int, int)? _range(String? header, int length) {
    if (header == null || length <= 0) return null;
    final match = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(header.trim());
    if (match == null) return null;
    final startText = match.group(1)!;
    final endText = match.group(2)!;
    if (startText.isEmpty) {
      final suffix = int.tryParse(endText);
      if (suffix == null || suffix <= 0) return null;
      return (max(0, length - suffix), length - 1);
    }
    final start = int.tryParse(startText);
    if (start == null || start < 0 || start >= length) return null;
    final parsedEnd = endText.isEmpty ? length - 1 : int.tryParse(endText);
    if (parsedEnd == null || parsedEnd < start) return null;
    return (start, min(parsedEnd, length - 1));
  }

  String _videoSubtype(String filename) {
    final extension = filename.split('.').last.toLowerCase();
    return switch (extension) {
      'mkv' => 'x-matroska',
      'webm' => 'webm',
      'avi' => 'x-msvideo',
      _ => 'mp4',
    };
  }

  Future<void> _json(HttpRequest request, Object value) async {
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(value));
    await request.response.close();
  }

  Future<void> _notFound(HttpRequest request) async {
    request.response.statusCode = HttpStatus.notFound;
    request.response.write('Not found');
    await request.response.close();
  }

  void _cors(HttpResponse response) {
    response.headers
      ..set(HttpHeaders.accessControlAllowOriginHeader, '*')
      ..set(HttpHeaders.accessControlAllowMethodsHeader, 'GET, HEAD, OPTIONS')
      ..set(HttpHeaders.accessControlAllowHeadersHeader, 'Range, Content-Type');
  }
}
