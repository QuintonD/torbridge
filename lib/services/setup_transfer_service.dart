import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../domain/media_models.dart';
import 'credential_store.dart';

const setupTransferScheme = 'torbridge';
const setupTransferVersion = 1;

class SetupTransferBundle {
  const SetupTransferBundle({
    required this.connections,
    required this.preferences,
  });

  final StoredConnections connections;
  final DownloadPreferences preferences;

  Map<String, dynamic> toJson() => {
    'version': setupTransferVersion,
    'createdAt': DateTime.now().toUtc().toIso8601String(),
    'connections': {
      'aioManifestUrl': connections.aioManifestUrl,
      'torBoxToken': connections.torBoxToken,
      'traktClientId': connections.traktClientId,
      'traktClientSecret': connections.traktClientSecret,
      'traktAccessToken': connections.traktAccessToken,
      'traktRefreshToken': connections.traktRefreshToken,
    },
    'preferences': _preferencesToJson(preferences),
  };

  factory SetupTransferBundle.fromJson(Map<String, dynamic> json) {
    if (json['version'] != setupTransferVersion) {
      throw const FormatException('Unsupported TorBridge transfer version.');
    }
    final connectionJson = Map<String, dynamic>.from(
      json['connections'] as Map? ?? const {},
    );
    final preferenceJson = Map<String, dynamic>.from(
      json['preferences'] as Map? ?? const {},
    );
    return SetupTransferBundle(
      connections: StoredConnections(
        aioManifestUrl: connectionJson['aioManifestUrl'] as String?,
        torBoxToken: connectionJson['torBoxToken'] as String?,
        traktClientId: connectionJson['traktClientId'] as String?,
        traktClientSecret: connectionJson['traktClientSecret'] as String?,
        traktAccessToken: connectionJson['traktAccessToken'] as String?,
        traktRefreshToken: connectionJson['traktRefreshToken'] as String?,
      ),
      preferences: _preferencesFromJson(preferenceJson),
    );
  }

  List<String> get includedItems => [
    if (connections.hasTorBox) 'TorBox',
    if (connections.hasAioStreams) 'AIOStreams',
    if (connections.hasTraktApp) 'Trakt',
    'download rules',
  ];
}

class SetupTransferOffer {
  const SetupTransferOffer({
    required this.uri,
    required this.verificationCode,
    required this.expiresAt,
    required this.includedItems,
  });

  final Uri uri;
  final String verificationCode;
  final DateTime expiresAt;
  final List<String> includedItems;
}

class ReceivedSetupTransfer {
  const ReceivedSetupTransfer({
    required this.bundle,
    required this.verificationCode,
  });

  final SetupTransferBundle bundle;
  final String verificationCode;
}

class SetupTransferException implements Exception {
  const SetupTransferException(this.message);

  final String message;

  @override
  String toString() => message;
}

class SetupTransferService {
  SetupTransferService({
    this.offerLifetime = const Duration(minutes: 5),
    Future<InternetAddress> Function()? addressResolver,
  }) : _addressResolver = addressResolver ?? _findLanAddress;

  final Duration offerLifetime;
  final Future<InternetAddress> Function() _addressResolver;
  final AesGcm _cipher = AesGcm.with256bits();
  final Random _random = Random.secure();

  ServerSocket? _server;
  StreamSubscription<Socket>? _subscription;
  Timer? _expiryTimer;
  String? _token;
  Uint8List? _key;
  SetupTransferBundle? _bundle;
  DateTime? _expiresAt;
  bool _claimed = false;
  int _generation = 0;

  Future<SetupTransferOffer> startOffer(SetupTransferBundle bundle) async {
    final generation = ++_generation;
    await _closeOffer();
    final address = await _addressResolver();
    if (generation != _generation) {
      throw const SetupTransferException('The pairing session was cancelled.');
    }
    final server = await ServerSocket.bind(address, 0, shared: false);
    if (generation != _generation) {
      await server.close();
      throw const SetupTransferException('The pairing session was cancelled.');
    }
    final token = _randomBytes(24);
    final key = _randomBytes(32);
    final tokenText = _base64Url(token);
    final keyText = _base64Url(key);
    final expiresAt = DateTime.now().toUtc().add(offerLifetime);

    _server = server;
    _token = tokenText;
    _key = key;
    _bundle = bundle;
    _expiresAt = expiresAt;
    _claimed = false;
    _subscription = server.listen(_handleClient);
    _expiryTimer = Timer(offerLifetime, () => unawaited(stopOffer()));

    return SetupTransferOffer(
      uri: Uri(
        scheme: setupTransferScheme,
        host: 'pair',
        queryParameters: {
          'v': '$setupTransferVersion',
          'host': address.address,
          'port': '${server.port}',
          'token': tokenText,
          'key': keyText,
        },
      ),
      verificationCode: _verificationCode(token, key),
      expiresAt: expiresAt,
      includedItems: bundle.includedItems,
    );
  }

  Future<ReceivedSetupTransfer> redeem(String rawUri) async {
    final uri = Uri.tryParse(rawUri);
    if (uri == null ||
        uri.scheme != setupTransferScheme ||
        uri.host != 'pair') {
      throw const SetupTransferException(
        'This is not a TorBridge setup QR code.',
      );
    }
    if (uri.queryParameters['v'] != '$setupTransferVersion') {
      throw const SetupTransferException(
        'This QR code uses an unsupported version.',
      );
    }
    final host = uri.queryParameters['host'];
    final port = int.tryParse(uri.queryParameters['port'] ?? '');
    final token = uri.queryParameters['token'];
    final keyText = uri.queryParameters['key'];
    if (host == null || port == null || token == null || keyText == null) {
      throw const SetupTransferException('This setup QR code is incomplete.');
    }
    final address = InternetAddress.tryParse(host);
    if (address == null ||
        address.type != InternetAddressType.IPv4 ||
        (!_isPrivateIpv4(address) && !address.isLoopback) ||
        port <= 0 ||
        port > 65535) {
      throw const SetupTransferException(
        'The setup QR code does not point to a private local network.',
      );
    }

    final key = _decodeBase64Url(keyText);
    if (key.length != 32) {
      throw const SetupTransferException(
        'This setup QR code has an invalid key.',
      );
    }

    Socket? socket;
    try {
      socket = await Socket.connect(
        address,
        port,
        timeout: const Duration(seconds: 8),
      );
      socket.write(
        '${jsonEncode({'version': setupTransferVersion, 'token': token})}\n',
      );
      await socket.flush();
      final line = await utf8.decoder
          .bind(socket)
          .transform(const LineSplitter())
          .first
          .timeout(const Duration(seconds: 8));
      final response = Map<String, dynamic>.from(jsonDecode(line) as Map);
      if (response['ok'] != true) {
        throw SetupTransferException(
          response['error'] as String? ??
              'The sending device rejected this transfer.',
        );
      }
      final box = SecretBox(
        _decodeBase64Url(response['ciphertext'] as String),
        nonce: _decodeBase64Url(response['nonce'] as String),
        mac: Mac(_decodeBase64Url(response['mac'] as String)),
      );
      final clearText = await _cipher.decrypt(
        box,
        secretKey: SecretKey(key),
        aad: utf8.encode('torbridge-setup-v1:$token'),
      );
      final bundle = SetupTransferBundle.fromJson(
        Map<String, dynamic>.from(jsonDecode(utf8.decode(clearText)) as Map),
      );
      return ReceivedSetupTransfer(
        bundle: bundle,
        verificationCode: _verificationCode(
          _decodeBase64Url(token),
          Uint8List.fromList(key),
        ),
      );
    } on SetupTransferException {
      rethrow;
    } on SecretBoxAuthenticationError {
      throw const SetupTransferException(
        'The encrypted transfer could not be verified.',
      );
    } on TimeoutException {
      throw const SetupTransferException(
        'The sending device did not respond. Keep its QR screen open and both devices unlocked on the same Wi-Fi.',
      );
    } on SocketException {
      throw const SetupTransferException(
        'Could not reach the sending device. Keep its QR screen open and both devices on the same Wi-Fi. Guest Wi-Fi or a VPN may block local connections. For a desktop sender, check its firewall. If the QR was used or expired, create a new one.',
      );
    } on StateError {
      throw const SetupTransferException(
        'This QR code has already been used or the pairing session ended.',
      );
    } on FormatException catch (error) {
      throw SetupTransferException(error.message);
    } finally {
      await socket?.close();
    }
  }

  Future<void> stopOffer() async {
    _generation++;
    await _closeOffer();
  }

  Future<void> _closeOffer() async {
    _expiryTimer?.cancel();
    _expiryTimer = null;
    await _subscription?.cancel();
    _subscription = null;
    await _server?.close();
    _server = null;
    _token = null;
    _key = null;
    _bundle = null;
    _expiresAt = null;
    _claimed = false;
  }

  Future<void> _handleClient(Socket socket) async {
    final generation = _generation;
    try {
      final line = await utf8.decoder
          .bind(socket)
          .transform(const LineSplitter())
          .first
          .timeout(const Duration(seconds: 5));
      final request = Map<String, dynamic>.from(jsonDecode(line) as Map);
      if (generation != _generation) {
        await _send(socket, {'ok': false, 'error': 'Pairing session ended.'});
        return;
      }
      final expired =
          _expiresAt == null || DateTime.now().toUtc().isAfter(_expiresAt!);
      if (expired) {
        await _send(socket, {
          'ok': false,
          'error': 'This QR code has expired.',
        });
        return;
      }
      if (_claimed) {
        await _send(socket, {
          'ok': false,
          'error': 'This QR code has already been used.',
        });
        return;
      }
      if (request['version'] != setupTransferVersion ||
          request['token'] != _token) {
        await _send(socket, {'ok': false, 'error': 'Pairing code rejected.'});
        return;
      }

      final bundle = _bundle;
      final key = _key;
      final token = _token;
      if (bundle == null || key == null || token == null) {
        await _send(socket, {'ok': false, 'error': 'Pairing session ended.'});
        return;
      }
      _claimed = true;
      final box = await _cipher.encrypt(
        utf8.encode(jsonEncode(bundle.toJson())),
        secretKey: SecretKey(key),
        aad: utf8.encode('torbridge-setup-v1:$token'),
      );
      await _send(socket, {
        'ok': true,
        'ciphertext': _base64Url(box.cipherText),
        'nonce': _base64Url(box.nonce),
        'mac': _base64Url(box.mac.bytes),
      });
      // A receiver can finish and open another offer before this flush returns.
      // An old client's cleanup must never cancel the new pairing session.
      if (generation == _generation) unawaited(stopOffer());
    } on Object {
      try {
        await _send(socket, {'ok': false, 'error': 'Invalid pairing request.'});
      } on Object {
        // The peer may have disconnected before the error could be returned.
      }
    } finally {
      await socket.close();
    }
  }

  Future<void> _send(Socket socket, Map<String, dynamic> response) async {
    socket.write('${jsonEncode(response)}\n');
    await socket.flush();
  }

  Uint8List _randomBytes(int length) => Uint8List.fromList(
    List<int>.generate(length, (_) => _random.nextInt(256)),
  );

  static Future<InternetAddress> _findLanAddress() async {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
      includeLinkLocal: false,
    );
    final candidates = <(int, InternetAddress)>[];
    for (final interface in interfaces) {
      for (final address in interface.addresses.where(_isPrivateIpv4)) {
        final name = interface.name.toLowerCase();
        final priority =
            name.contains('wi-fi') ||
                name.contains('wifi') ||
                name.contains('wlan')
            ? 0
            : name.contains('ethernet') && !name.contains('virtual')
            ? 1
            : 2;
        candidates.add((priority, address));
      }
    }
    candidates.sort((left, right) => left.$1.compareTo(right.$1));
    if (candidates.isEmpty) {
      throw const SetupTransferException(
        'No local network was found. Connect both devices to the same Wi-Fi or Ethernet network.',
      );
    }
    return candidates.first.$2;
  }

  static bool _isPrivateIpv4(InternetAddress address) {
    final parts = address.address.split('.').map(int.tryParse).toList();
    if (parts.length != 4 || parts.any((part) => part == null)) return false;
    return parts[0] == 10 ||
        (parts[0] == 172 && parts[1]! >= 16 && parts[1]! <= 31) ||
        (parts[0] == 192 && parts[1] == 168);
  }
}

String _base64Url(List<int> value) =>
    base64UrlEncode(value).replaceAll('=', '');

Uint8List _decodeBase64Url(String value) {
  final padding = '=' * ((4 - value.length % 4) % 4);
  return Uint8List.fromList(base64Url.decode('$value$padding'));
}

String _verificationCode(List<int> token, List<int> key) {
  var value = 0;
  for (final byte in [...token, ...key]) {
    value = ((value * 257) + byte) % 1000000;
  }
  return value.toString().padLeft(6, '0');
}

Map<String, dynamic> _preferencesToJson(DownloadPreferences value) => {
  'audioLanguageOrder': value.audioLanguageOrder,
  'subtitleLanguageOrder': value.subtitleLanguageOrder,
  'preferredResolution': value.preferredResolution.name,
  'minimumResolution': value.minimumResolution.name,
  'maximumResolution': value.maximumResolution.name,
  'codecOrder': value.codecOrder.map((codec) => codec.name).toList(),
  'preferHdr': value.preferHdr,
  'cachedOnly': value.cachedOnly,
  'requirePreferredAudio': value.requirePreferredAudio,
  'allowUnknownAudio': value.allowUnknownAudio,
  'maximumSizeBytes': value.maximumSizeBytes,
  'blockedReleaseTags': value.blockedReleaseTags.toList(),
  'deleteWatchedAfterDays': value.deleteWatchedAfterDays,
};

DownloadPreferences _preferencesFromJson(Map<String, dynamic> json) {
  const defaults = DownloadPreferences(
    subtitleLanguageOrder: ['Dutch', 'English'],
  );
  return DownloadPreferences(
    audioLanguageOrder: _stringList(
      json['audioLanguageOrder'],
      defaults.audioLanguageOrder,
    ),
    subtitleLanguageOrder: _stringList(
      json['subtitleLanguageOrder'],
      defaults.subtitleLanguageOrder,
    ),
    preferredResolution: _enumValue(
      VideoResolution.values,
      json['preferredResolution'],
      defaults.preferredResolution,
    ),
    minimumResolution: _enumValue(
      VideoResolution.values,
      json['minimumResolution'],
      defaults.minimumResolution,
    ),
    maximumResolution: _enumValue(
      VideoResolution.values,
      json['maximumResolution'],
      defaults.maximumResolution,
    ),
    codecOrder: _enumValues(
      VideoCodec.values,
      json['codecOrder'],
      defaults.codecOrder,
    ),
    preferHdr: json['preferHdr'] as bool? ?? defaults.preferHdr,
    cachedOnly: json['cachedOnly'] as bool? ?? defaults.cachedOnly,
    requirePreferredAudio:
        json['requirePreferredAudio'] as bool? ??
        defaults.requirePreferredAudio,
    allowUnknownAudio:
        json['allowUnknownAudio'] as bool? ?? defaults.allowUnknownAudio,
    maximumSizeBytes:
        (json['maximumSizeBytes'] as num?)?.toInt() ??
        defaults.maximumSizeBytes,
    blockedReleaseTags: _stringList(
      json['blockedReleaseTags'],
      defaults.blockedReleaseTags.toList(),
    ).toSet(),
    deleteWatchedAfterDays: json.containsKey('deleteWatchedAfterDays')
        ? (json['deleteWatchedAfterDays'] as num?)?.toInt()
        : defaults.deleteWatchedAfterDays,
  );
}

List<String> _stringList(Object? value, List<String> fallback) {
  if (value is! List) return fallback;
  final values = value.whereType<String>().toList(growable: false);
  return values.isEmpty ? fallback : values;
}

T _enumValue<T extends Enum>(List<T> values, Object? name, T fallback) {
  return values.where((value) => value.name == name).firstOrNull ?? fallback;
}

List<T> _enumValues<T extends Enum>(
  List<T> values,
  Object? names,
  List<T> fallback,
) {
  if (names is! List) return fallback;
  final result = [
    for (final name in names) ...values.where((value) => value.name == name),
  ];
  return result.isEmpty ? fallback : result;
}
