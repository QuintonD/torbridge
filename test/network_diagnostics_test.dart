import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:torbridge/services/network_diagnostics.dart';

void main() {
  test('DNS failure identifies the actual API host without URL, token or response body', () {
    final failure = ServiceFailure.from(
      DioException(
        requestOptions: RequestOptions(
          path: 'https://api.torbox.app/v1/requestdl?token=fixture-secret',
        ),
        type: DioExceptionType.connectionError,
        error: const SocketException(
          "Failed host lookup: 'api.torbox.app'",
          osError: OSError('No address associated with hostname', 7),
        ),
        message: 'fixture-secret',
      ),
      stage: 'TorBox recovery',
    );
    expect(failure.kind, NetworkFailureKind.dns);
    expect(failure.canWaitForNetwork, isTrue);
    expect(failure.toString(), contains('api.torbox.app'));
    expect(failure.toString(), isNot(contains('fixture-secret')));
    expect(failure.toString(), isNot(contains('DioException')));
  });

  test('authorization and TLS failures are not classified as transient DNS failures', () {
    final options = RequestOptions(
      path: 'https://api.example/private/configuration',
    );
    final auth = ServiceFailure.from(
      DioException(
        requestOptions: options,
        type: DioExceptionType.badResponse,
        response: Response(
          requestOptions: options,
          statusCode: 401,
          data: 'secret',
        ),
      ),
      stage: 'service check',
    );
    expect(auth.kind, NetworkFailureKind.authorization);
    expect(auth.canWaitForNetwork, isFalse);
    expect(auth.toString(), isNot(contains('secret')));
    expect(
      ServiceFailure.from(
        const HandshakeException('private detail'),
        stage: 'TLS',
      ).kind,
      NetworkFailureKind.tls,
    );
  });

  test('DNS lookup timeout is bounded and reports address families without addresses', () async {
    final diagnostics = NetworkDiagnostics(
      lookup: (_) async => [
        InternetAddress('127.0.0.1'),
        InternetAddress('::1'),
      ],
    );
    final report = await diagnostics.resolve('fixture.example');
    expect(report, contains('1 IPv4, 1 IPv6'));
    expect(report, isNot(contains('127.0.0.1')));
    final stalled = NetworkDiagnostics(
      lookup: (_) => Completer<List<InternetAddress>>().future,
      timeout: const Duration(milliseconds: 10),
    );
    await expectLater(
      stalled.resolve('fixture.example'),
      throwsA(
        isA<ServiceFailure>().having(
          (e) => e.kind,
          'kind',
          NetworkFailureKind.timeout,
        ),
      ),
    );
  });

  test('saved Pixel exception is reduced to a safe DNS diagnosis', () {
    final error = ServiceFailure.fromSavedMessage(
      "Android cannot resume; DioException Failed host lookup: 'api.torbox.app' token=fixture-secret from wrong.example",
    );
    expect(error?.kind, NetworkFailureKind.dns);
    expect(error.toString(), contains('api.torbox.app'));
    expect(error.toString(), isNot(contains('wrong.example')));
    expect(error.toString(), isNot(contains('fixture-secret')));
  });
}
