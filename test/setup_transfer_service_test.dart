import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:torbridge/domain/media_models.dart';
import 'package:torbridge/services/credential_store.dart';
import 'package:torbridge/services/setup_transfer_service.dart';

void main() {
  late SetupTransferService desktop;
  late SetupTransferService mobile;

  setUp(() {
    desktop = SetupTransferService(
      addressResolver: () async => InternetAddress.loopbackIPv4,
    );
    mobile = SetupTransferService();
  });

  tearDown(() async {
    await desktop.stopOffer();
    await mobile.stopOffer();
  });

  test(
    'QR contains no credentials and encrypted setup round-trips once',
    () async {
      const bundle = SetupTransferBundle(
        connections: StoredConnections(
          aioManifestUrl: 'https://aio.example/private/manifest.json',
          torBoxToken: 'torbox-secret-token',
          traktClientId: 'trakt-client',
          traktClientSecret: 'trakt-secret',
          traktAccessToken: 'trakt-access',
          traktRefreshToken: 'trakt-refresh',
        ),
        preferences: DownloadPreferences(
          audioLanguageOrder: ['Dutch', 'English'],
          subtitleLanguageOrder: ['English', 'Dutch'],
          preferredResolution: VideoResolution.ultraHd2160,
          preferHdr: true,
          cachedOnly: false,
          maximumSizeBytes: 42000000000,
          deleteWatchedAfterDays: 7,
        ),
      );

      final offer = await desktop.startOffer(bundle);
      final qr = offer.uri.toString();
      expect(qr, startsWith('torbridge://pair?'));
      expect(qr, isNot(contains('torbox-secret-token')));
      expect(qr, isNot(contains('trakt-secret')));
      expect(qr, isNot(contains('aio.example')));

      final received = await mobile.redeem(qr);
      expect(received.verificationCode, offer.verificationCode);
      expect(received.bundle.connections.torBoxToken, 'torbox-secret-token');
      expect(received.bundle.connections.traktRefreshToken, 'trakt-refresh');
      expect(
        received.bundle.preferences.preferredResolution,
        VideoResolution.ultraHd2160,
      );
      expect(received.bundle.preferences.audioLanguageOrder.first, 'Dutch');
      expect(received.bundle.preferences.preferHdr, isTrue);
      expect(received.bundle.preferences.cachedOnly, isFalse);
      expect(received.bundle.preferences.deleteWatchedAfterDays, 7);

      await expectLater(
        mobile.redeem(qr),
        throwsA(isA<SetupTransferException>()),
      );
    },
  );

  test('tampered encryption key is rejected', () async {
    const bundle = SetupTransferBundle(
      connections: StoredConnections(torBoxToken: 'secret'),
      preferences: DownloadPreferences(),
    );
    final offer = await desktop.startOffer(bundle);
    final values = Map<String, String>.from(offer.uri.queryParameters);
    values['key'] = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
    final tampered = offer.uri.replace(queryParameters: values).toString();

    await expectLater(
      mobile.redeem(tampered),
      throwsA(isA<SetupTransferException>()),
    );
  });

  test('non-TorBridge QR is rejected before opening a socket', () async {
    await expectLater(
      mobile.redeem('https://example.com/manifest.json'),
      throwsA(
        isA<SetupTransferException>().having(
          (error) => error.message,
          'message',
          contains('not a TorBridge'),
        ),
      ),
    );
  });
}
