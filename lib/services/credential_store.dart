import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class StoredConnections {
  const StoredConnections({
    this.aioManifestUrl,
    this.torBoxToken,
    this.traktClientId,
    this.traktClientSecret,
    this.traktAccessToken,
    this.traktRefreshToken,
  });

  final String? aioManifestUrl;
  final String? torBoxToken;
  final String? traktClientId;
  final String? traktClientSecret;
  final String? traktAccessToken;
  final String? traktRefreshToken;

  bool get hasAioStreams => aioManifestUrl?.isNotEmpty ?? false;
  bool get hasTorBox => torBoxToken?.isNotEmpty ?? false;
  bool get hasTraktApp =>
      (traktClientId?.isNotEmpty ?? false) &&
      (traktClientSecret?.isNotEmpty ?? false);
  bool get hasTraktSession =>
      hasTraktApp && (traktAccessToken?.isNotEmpty ?? false);
}

abstract class CredentialStore {
  Future<StoredConnections> read();

  Future<void> save({
    required String aioManifestUrl,
    required String torBoxToken,
    required String traktClientId,
    required String traktClientSecret,
  });

  Future<void> saveTraktTokens({
    required String accessToken,
    required String refreshToken,
  });

  Future<void> saveAll(StoredConnections connections);

  Future<void> clear();
}

class PlatformCredentialStore implements CredentialStore {
  PlatformCredentialStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  static const _aioManifestUrl = 'aio_manifest_url';
  static const _torBoxToken = 'torbox_api_token';
  static const _traktClientId = 'trakt_client_id';
  static const _traktClientSecret = 'trakt_client_secret';
  static const _traktAccessToken = 'trakt_access_token';
  static const _traktRefreshToken = 'trakt_refresh_token';

  final FlutterSecureStorage _storage;

  @override
  Future<StoredConnections> read() async {
    final values = await _storage.readAll();
    return StoredConnections(
      aioManifestUrl: values[_aioManifestUrl],
      torBoxToken: values[_torBoxToken],
      traktClientId: values[_traktClientId],
      traktClientSecret: values[_traktClientSecret],
      traktAccessToken: values[_traktAccessToken],
      traktRefreshToken: values[_traktRefreshToken],
    );
  }

  @override
  Future<void> save({
    required String aioManifestUrl,
    required String torBoxToken,
    required String traktClientId,
    required String traktClientSecret,
  }) async {
    await Future.wait([
      _writeOrDelete(_aioManifestUrl, aioManifestUrl),
      _writeOrDelete(_torBoxToken, torBoxToken),
      _writeOrDelete(_traktClientId, traktClientId),
      _writeOrDelete(_traktClientSecret, traktClientSecret),
    ]);
  }

  @override
  Future<void> saveTraktTokens({
    required String accessToken,
    required String refreshToken,
  }) async {
    await Future.wait([
      _writeOrDelete(_traktAccessToken, accessToken),
      _writeOrDelete(_traktRefreshToken, refreshToken),
    ]);
  }

  @override
  Future<void> saveAll(StoredConnections connections) async {
    await save(
      aioManifestUrl: connections.aioManifestUrl ?? '',
      torBoxToken: connections.torBoxToken ?? '',
      traktClientId: connections.traktClientId ?? '',
      traktClientSecret: connections.traktClientSecret ?? '',
    );
    await saveTraktTokens(
      accessToken: connections.traktAccessToken ?? '',
      refreshToken: connections.traktRefreshToken ?? '',
    );
  }

  @override
  Future<void> clear() => _storage.deleteAll();

  Future<void> _writeOrDelete(String key, String value) {
    if (value.trim().isEmpty) return _storage.delete(key: key);
    return _storage.write(key: key, value: value.trim());
  }
}
