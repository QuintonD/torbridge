import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:torbridge/integrations/trakt_client.dart';
import 'package:torbridge/services/trakt_device_poller.dart';

void main() {
  final code = TraktDeviceCode(
    deviceCode: 'fixture',
    userCode: 'TEST',
    verificationUrl: Uri.parse('https://trakt.tv/activate'),
    expiresIn: 120,
    interval: 5,
  );

  testWidgets(
    'authorization waits for each request and increases delay on slowdown',
    (tester) async {
      final first = Completer<TraktDevicePollResult>();
      var calls = 0;
      final results = <TraktDeviceStatus>[];
      final poller = TraktDevicePoller(
        code: code,
        poll: (_) {
          calls++;
          return calls == 1
              ? first.future
              : Future.value(
                  const TraktDevicePollResult(TraktDeviceStatus.approved),
                );
        },
        onResult: (result) => results.add(result.status),
        onError: (error) => fail('$error'),
      )..start();
      addTearDown(poller.stop);
      await tester.pump(const Duration(seconds: 5));
      expect(calls, 1);
      await tester.pump(const Duration(seconds: 20));
      expect(calls, 1);
      first.complete(const TraktDevicePollResult(TraktDeviceStatus.slowDown));
      await tester.pump();
      await tester.pump(const Duration(seconds: 9));
      expect(calls, 1);
      await tester.pump(const Duration(seconds: 1));
      expect(calls, 2);
      expect(results, [TraktDeviceStatus.slowDown, TraktDeviceStatus.approved]);
      await tester.pump(const Duration(seconds: 30));
      expect(calls, 2);
    },
  );

  testWidgets('expiry stops a pending request and ignores its late approval', (
    tester,
  ) async {
    final pending = Completer<TraktDevicePollResult>();
    final results = <TraktDeviceStatus>[];
    final poller = TraktDevicePoller(
      code: code,
      poll: (_) => pending.future,
      onResult: (result) => results.add(result.status),
      onError: (error) => fail('$error'),
    )..start();
    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(seconds: 115));
    expect(results, [TraktDeviceStatus.expired]);
    pending.complete(const TraktDevicePollResult(TraktDeviceStatus.approved));
    await tester.pump();
    expect(results, [TraktDeviceStatus.expired]);
    poller.stop();
  });
}
