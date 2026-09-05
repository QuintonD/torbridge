import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

/// Stremio core encodes streams as zlib-compressed JSON in standard base64.
Uri stremioPlaybackUri(Uri media, String title) {
  final stream = {
    'url': media.toString(),
    'title': title,
    'behaviorHints': {'notWebReady': true},
  };
  final encoded = base64Encode(zlib.encode(utf8.encode(jsonEncode(stream))));
  return Uri.parse('stremio:///player/${Uri.encodeComponent(encoded)}');
}

class PlaybackLauncher {
  static const _channel = MethodChannel('app.torbridge/playback');

  Future<bool> openExternal(String source, {required String title}) async {
    if (Platform.isAndroid) {
      return await _channel.invokeMethod<bool>('open', {
            'source': source,
            'title': title,
          }) ??
          false;
    }
    final uri = source.contains('://') ? Uri.parse(source) : File(source).uri;
    if (Platform.isWindows && uri.scheme == 'file') {
      // Argument lists preserve spaces and prevent shell interpretation.
      final result = await Process.run('rundll32.exe', [
        'shell32.dll,OpenAs_RunDLL',
        uri.toFilePath(),
      ]);
      return result.exitCode == 0;
    }
    if (Platform.isWindows) {
      // HTTP URL handlers normally open a browser, not a video player.
      for (final root in [
        Platform.environment['ProgramFiles'],
        Platform.environment['ProgramFiles(x86)'],
      ].whereType<String>()) {
        final executable = File('$root/VideoLAN/VLC/vlc.exe');
        if (await executable.exists()) {
          await Process.start(executable.path, [
            '--',
            uri.toString(),
          ], mode: ProcessStartMode.detached);
          return true;
        }
      }
      return false;
    }
    return launchUrl(uri, mode: LaunchMode.externalApplication);
  }
}
