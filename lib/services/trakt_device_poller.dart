import 'dart:async';

import '../integrations/trakt_client.dart';

/// One request at a time, scheduled after the preceding request completes.
class TraktDevicePoller {
  TraktDevicePoller({
    required this.code,
    required this.poll,
    required this.onResult,
    required this.onError,
  }) : interval = Duration(seconds: code.interval < 5 ? 5 : code.interval);

  final TraktDeviceCode code;
  final Future<TraktDevicePollResult> Function(String code) poll;
  final void Function(TraktDevicePollResult result) onResult;
  final void Function(Object error) onError;
  Duration interval;
  Timer? _timer;
  Timer? _expiry;
  bool _stopped = false;
  bool _started = false;

  void start() {
    if (_started || _stopped) return;
    _started = true;
    _expiry = Timer(Duration(seconds: code.expiresIn), () {
      stop();
      onResult(const TraktDevicePollResult(TraktDeviceStatus.expired));
    });
    _schedule();
  }

  void stop() {
    _stopped = true;
    _timer?.cancel();
    _expiry?.cancel();
  }

  void _schedule() {
    if (!_stopped) _timer = Timer(interval, () => unawaited(_request()));
  }

  Future<void> _request() async {
    try {
      final result = await poll(code.deviceCode);
      if (_stopped) return;
      switch (result.status) {
        case TraktDeviceStatus.pending:
          break;
        case TraktDeviceStatus.slowDown:
          interval += const Duration(seconds: 5);
          break;
        default:
          stop();
      }
      onResult(result);
    } catch (error) {
      if (_stopped) return;
      onError(error);
    }
    _schedule();
  }
}
