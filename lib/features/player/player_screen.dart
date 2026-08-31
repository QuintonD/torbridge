import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:video_player/video_player.dart' as android_video;

import '../../app/app_state.dart';
import '../../domain/catalog_title.dart';
import '../../integrations/trakt_client.dart';

class PlayerScreen extends ConsumerStatefulWidget {
  const PlayerScreen({
    super.key,
    required this.title,
    required this.source,
    this.mediaTitle,
    this.onCompleted,
  });

  final String title;
  final String source;
  final CatalogTitle? mediaTitle;
  final VoidCallback? onCompleted;

  @override
  ConsumerState<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends ConsumerState<PlayerScreen> {
  Player? _player;
  VideoController? _controller;
  android_video.VideoPlayerController? _androidPlayer;
  late final TorBridgeController _appController;
  StreamSubscription<bool>? _completedSubscription;
  StreamSubscription<bool>? _playingSubscription;
  StreamSubscription<String>? _errorSubscription;
  Timer? _controlsTimer;
  bool _started = false;
  bool _completed = false;
  bool _controlsVisible = true;
  String? _playbackError;

  @override
  void initState() {
    super.initState();
    _appController = ref.read(torBridgeControllerProvider.notifier);
    if (Platform.isAndroid) {
      unawaited(_initializeAndroidPlayer());
    } else {
      _initializeMediaKitPlayer();
    }
  }

  void _initializeMediaKitPlayer() {
    final player = Player();
    _player = player;
    _controller = VideoController(player);
    _completedSubscription = player.stream.completed.listen((completed) {
      if (completed) {
        _completed = true;
        _sendScrobble(TraktScrobbleAction.stop, overrideProgress: 100);
        widget.onCompleted?.call();
      }
    });
    _playingSubscription = player.stream.playing.listen((playing) {
      if (playing) {
        _started = true;
        _sendScrobble(TraktScrobbleAction.start);
      } else if (_started && !_completed && _progress >= 1) {
        _sendScrobble(TraktScrobbleAction.pause);
      }
    });
    _errorSubscription = player.stream.error.listen((error) {
      if (mounted) setState(() => _playbackError = error);
    });
    unawaited(player.open(Media(widget.source)));
  }

  Future<void> _initializeAndroidPlayer() async {
    try {
      final uri = Uri.parse(widget.source);
      final controller = switch (uri.scheme) {
        'content' => android_video.VideoPlayerController.contentUri(uri),
        'http' || 'https' => android_video.VideoPlayerController.networkUrl(uri),
        'file' => android_video.VideoPlayerController.file(File.fromUri(uri)),
        _ => android_video.VideoPlayerController.file(File(widget.source)),
      };
      _androidPlayer = controller;
      controller.addListener(_onAndroidPlayerChanged);
      await controller.initialize();
      if (!mounted) return;
      await controller.play();
      _scheduleControlsHide();
      setState(() {});
    } catch (error) {
      if (mounted) setState(() => _playbackError = '$error');
    }
  }

  void _onAndroidPlayerChanged() {
    final controller = _androidPlayer;
    if (!mounted || controller == null) return;
    final value = controller.value;
    if (value.hasError) {
      setState(
        () => _playbackError = value.errorDescription ?? 'Playback failed.',
      );
      return;
    }
    if (value.isPlaying && !_started) {
      _started = true;
      _sendScrobble(TraktScrobbleAction.start);
    }
    final finished =
        value.isInitialized &&
        value.duration > Duration.zero &&
        value.position >= value.duration &&
        !value.isPlaying;
    if (finished && !_completed) {
      _completed = true;
      _sendScrobble(TraktScrobbleAction.stop, overrideProgress: 100);
      widget.onCompleted?.call();
    }
    if (_controlsVisible) setState(() {});
  }

  void _scheduleControlsHide() {
    _controlsTimer?.cancel();
    _controlsTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && (_androidPlayer?.value.isPlaying ?? false)) {
        setState(() => _controlsVisible = false);
      }
    });
  }

  void _toggleControls() {
    setState(() => _controlsVisible = !_controlsVisible);
    if (_controlsVisible) _scheduleControlsHide();
  }

  Future<void> _toggleAndroidPlayback() async {
    final controller = _androidPlayer;
    if (controller == null) return;
    if (controller.value.isPlaying) {
      await controller.pause();
      _sendScrobble(TraktScrobbleAction.pause);
      if (mounted) setState(() => _controlsVisible = true);
    } else {
      await controller.play();
      if (mounted) {
        setState(() => _controlsVisible = true);
        _scheduleControlsHide();
      }
    }
  }

  @override
  void dispose() {
    if (_started && !_completed && _progress >= 1) {
      _sendScrobble(TraktScrobbleAction.stop);
    }
    unawaited(_completedSubscription?.cancel());
    unawaited(_playingSubscription?.cancel());
    unawaited(_errorSubscription?.cancel());
    _controlsTimer?.cancel();
    final androidPlayer = _androidPlayer;
    if (androidPlayer != null) {
      androidPlayer.removeListener(_onAndroidPlayerChanged);
      unawaited(androidPlayer.dispose());
    }
    final player = _player;
    if (player != null) unawaited(player.dispose());
    super.dispose();
  }

  double get _progress {
    final androidValue = _androidPlayer?.value;
    if (androidValue != null) {
      final duration = androidValue.duration.inMilliseconds;
      if (duration <= 0) return 0;
      return (androidValue.position.inMilliseconds / duration * 100).clamp(
        0,
        100,
      );
    }
    final duration = _player?.state.duration.inMilliseconds ?? 0;
    if (duration <= 0) return 0;
    return ((_player?.state.position.inMilliseconds ?? 0) / duration * 100).clamp(
      0,
      100,
    );
  }

  void _sendScrobble(TraktScrobbleAction action, {double? overrideProgress}) {
    final mediaTitle = widget.mediaTitle;
    if (mediaTitle == null) return;
    unawaited(
      _appController.scrobble(
        title: mediaTitle,
        action: action,
        progress: overrideProgress ?? _progress,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      body: Center(child: _buildPlayer()),
    );
  }

  Widget _buildPlayer() {
    final error = _playbackError;
    if (error != null) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          key: const Key('playback-error'),
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 44),
            const SizedBox(height: 12),
            const Text('This video could not be played.'),
            const SizedBox(height: 8),
            Text(error, textAlign: TextAlign.center),
          ],
        ),
      );
    }

    if (Platform.isAndroid) return _buildAndroidPlayer();
    final controller = _controller;
    if (controller == null) return const CircularProgressIndicator();
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: Video(controller: controller, controls: AdaptiveVideoControls),
    );
  }

  Widget _buildAndroidPlayer() {
    final controller = _androidPlayer;
    if (controller == null || !controller.value.isInitialized) {
      return const CircularProgressIndicator(key: Key('playback-loading'));
    }
    final value = controller.value;
    final aspectRatio = value.aspectRatio > 0 ? value.aspectRatio : 16 / 9;
    return Semantics(
      key: const Key('video-playback-ready'),
      label: value.isPlaying ? 'Playing video' : 'Video paused',
      child: AspectRatio(
        aspectRatio: aspectRatio,
        child: Stack(
          fit: StackFit.expand,
          children: [
            android_video.VideoPlayer(controller),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _toggleControls,
              child: const SizedBox.expand(),
            ),
            if (_controlsVisible)
              Align(
                alignment: Alignment.bottomCenter,
                child: Container(
                  padding: const EdgeInsets.fromLTRB(8, 16, 12, 8),
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Colors.transparent, Colors.black87],
                    ),
                  ),
                  child: Row(
                    children: [
                      IconButton(
                        key: const Key('toggle-playback'),
                        tooltip: value.isPlaying ? 'Pause' : 'Play',
                        onPressed: _toggleAndroidPlayback,
                        icon: Icon(
                          value.isPlaying ? Icons.pause : Icons.play_arrow,
                        ),
                      ),
                      Expanded(
                        child: android_video.VideoProgressIndicator(
                          controller,
                          allowScrubbing: true,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(_formatDuration(value.position)),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  String _formatDuration(Duration value) {
    final minutes = value.inMinutes;
    final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }
}
