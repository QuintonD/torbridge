import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:torbridge/domain/media_models.dart';
import 'package:torbridge/services/credential_store.dart';
import 'package:torbridge/services/setup_transfer_service.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Android offers encrypted setup on its local network address', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    final sender = SetupTransferService();
    final receiver = SetupTransferService();
    try {
      final offer = await sender.startOffer(
        const SetupTransferBundle(
          connections: StoredConnections(
            aioManifestUrl: 'https://fixture.invalid/manifest.json',
            torBoxToken: 'synthetic-token',
          ),
          preferences: DownloadPreferences(audioLanguageOrder: ['Dutch']),
        ),
      );
      expect(offer.uri.queryParameters['host'], isNot('127.0.0.1'));
      final received = await receiver.redeem(offer.uri.toString());
      expect(received.verificationCode, offer.verificationCode);
      expect(received.bundle.connections.torBoxToken, 'synthetic-token');
      expect(received.bundle.preferences.audioLanguageOrder, ['Dutch']);
      await expectLater(
        receiver.redeem(offer.uri.toString()),
        throwsA(isA<SetupTransferException>()),
      );
    } finally {
      await sender.stopOffer();
      await receiver.stopOffer();
    }
  });
}
