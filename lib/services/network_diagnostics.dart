import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';

enum NetworkFailureKind {
  dns,
  connection,
  timeout,
  tls,
  authorization,
  http,
  other,
}

/// Safe to display and persist: never includes response bodies or request URLs.
class ServiceFailure implements Exception {
  const ServiceFailure(
    this.kind, {
    required this.stage,
    this.host,
    this.status,
    this.retryAfter,
  });
  final NetworkFailureKind kind;
  final String stage;
  final String? host;
  final int? status;
  final Duration? retryAfter;

  bool get canWaitForNetwork => switch (kind) {
    NetworkFailureKind.dns ||
    NetworkFailureKind.connection ||
    NetworkFailureKind.timeout => true,
    _ => status == 429,
  };

  static ServiceFailure from(
    Object error, {
    required String stage,
    Uri? target,
  }) {
    if (error is ServiceFailure) return error;
    final dio = error is DioException ? error : null;
    final inner = dio?.error ?? error;
    final host = target?.host ?? dio?.requestOptions.uri.host;
    final code = dio?.response?.statusCode;
    final kind = switch (inner) {
      SocketException e
          when e.message.toLowerCase().contains('failed host lookup') ||
              e.message.toLowerCase().contains('name or service not known') ||
              e.message.toLowerCase().contains('no address associated') =>
        NetworkFailureKind.dns,
      HandshakeException _ => NetworkFailureKind.tls,
      SocketException _ => NetworkFailureKind.connection,
      TimeoutException _ => NetworkFailureKind.timeout,
      _ => switch (dio?.type) {
        DioExceptionType.connectionTimeout ||
        DioExceptionType.sendTimeout ||
        DioExceptionType.receiveTimeout => NetworkFailureKind.timeout,
        DioExceptionType.connectionError => NetworkFailureKind.connection,
        DioExceptionType.badCertificate => NetworkFailureKind.tls,
        DioExceptionType.badResponse when code == 401 || code == 403 =>
          NetworkFailureKind.authorization,
        DioExceptionType.badResponse => NetworkFailureKind.http,
        _ => NetworkFailureKind.other,
      },
    };
    return ServiceFailure(
      kind,
      stage: stage,
      host: host?.isEmpty == true ? null : host,
      status: code,
      retryAfter: code == 429
          ? _retryAfter(dio?.response?.headers['retry-after']?.firstOrNull)
          : null,
    );
  }

  static Duration _retryAfter(String? value) {
    final seconds = int.tryParse(value ?? '');
    if (seconds != null && seconds >= 0) return Duration(seconds: seconds);
    try {
      final duration = HttpDate.parse(value ?? '')
          .difference(DateTime.now().toUtc());
      if (!duration.isNegative) return duration;
    } catch (_) {}
    return const Duration(minutes: 5);
  }

  static ServiceFailure? fromSavedMessage(String? message) {
    if (message == null || !message.contains('Failed host lookup:')) {
      return null;
    }
    final host = RegExp(r"Failed host lookup: '([a-zA-Z0-9.-]+)'")
        .firstMatch(message)
        ?.group(1);
    return ServiceFailure(
      NetworkFailureKind.dns,
      stage: 'download recovery',
      host: host,
    );
  }

  @override
  String toString() {
    final location = host == null ? '' : ' for $host';
    final reason = switch (kind) {
      NetworkFailureKind.dns => 'DNS lookup failed$location',
      NetworkFailureKind.connection => 'Could not connect$location',
      NetworkFailureKind.timeout => 'Connection timed out$location',
      NetworkFailureKind.tls => 'Secure connection failed$location',
      NetworkFailureKind.authorization =>
        'Service rejected authorization$location (HTTP $status)',
      NetworkFailureKind.http => 'Service returned HTTP $status$location',
      NetworkFailureKind.other => 'Request failed$location',
    };
    return '$reason during $stage. ${canWaitForNetwork ? 'Check the network, VPN or DNS settings; run Diagnostics, then resume waiting downloads.' : 'Run Diagnostics and check the service settings.'}';
  }
}

class NetworkDiagnostics {
  NetworkDiagnostics({
    Future<List<InternetAddress>> Function(String)? lookup,
    this.timeout = const Duration(seconds: 8),
  }) : _lookup = lookup ?? InternetAddress.lookup;
  final Future<List<InternetAddress>> Function(String) _lookup;
  final Duration timeout;

  Future<String> resolve(String host) async {
    try {
      final addresses = await _lookup(host).timeout(timeout);
      if (addresses.isEmpty) {
        throw const SocketException('No address associated with hostname');
      }
      final ipv4 = addresses
          .where((a) => a.type == InternetAddressType.IPv4)
          .length;
      final ipv6 = addresses
          .where((a) => a.type == InternetAddressType.IPv6)
          .length;
      return 'DNS resolved $host ($ipv4 IPv4, $ipv6 IPv6). This alone does not verify service access.';
    } catch (error) {
      throw ServiceFailure.from(
        error,
        stage: 'DNS check',
        target: Uri(host: host),
      );
    }
  }

  Future<Map<String, dynamic>> deviceNetwork() async {
    if (!Platform.isAndroid) return const {};
    return await const MethodChannel('app.torbridge/downloads')
            .invokeMapMethod<String, dynamic>('networkInfo') ??
        const {};
  }
}
