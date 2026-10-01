import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

abstract class PreviewVideoSession extends ChangeNotifier {
  Duration get position;
  Duration get duration;
  bool get playing;
  bool get buffering;
  double get volume;
  String? get error;
  Widget buildVideo();
  Future<void> open(String path);
  Future<void> togglePlayback();
  Future<void> pause();
  Future<void> seek(Duration position);
  Future<void> setVolume(double volume);
}

class NativePreviewVideoSession extends PreviewVideoSession {
  NativePreviewVideoSession() {
    MediaKit.ensureInitialized();
    _player = Player();
    _controller = VideoController(_player);
    _subscriptions.addAll([
      _player.stream.position.listen((_) => _changed()),
      _player.stream.duration.listen((_) => _changed()),
      _player.stream.playing.listen((_) => _changed()),
      _player.stream.buffering.listen((_) => _changed()),
      _player.stream.volume.listen((_) => _changed()),
      _player.stream.error.listen((message) {
        _error = message;
        _changed();
      }),
    ]);
  }

  late final Player _player;
  late final VideoController _controller;
  final _subscriptions = <StreamSubscription<dynamic>>[];
  bool _disposed = false;
  String? _error;

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  @override
  Duration get position => _player.state.position;
  @override
  Duration get duration => _player.state.duration;
  @override
  bool get playing => _player.state.playing;
  @override
  bool get buffering => _player.state.buffering;
  @override
  double get volume => _player.state.volume;
  @override
  String? get error => _error;
  @override
  Widget buildVideo() => Video(
    controller: _controller,
    fit: BoxFit.contain,
    controls: NoVideoControls,
  );
  @override
  Future<void> open(String path) => _player.open(Media(path), play: false);
  @override
  Future<void> togglePlayback() => _player.playOrPause();
  @override
  Future<void> pause() => _player.pause();
  @override
  Future<void> seek(Duration position) => _player.seek(position);
  @override
  Future<void> setVolume(double volume) => _player.setVolume(volume);

  @override
  void dispose() {
    _disposed = true;
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    unawaited(_player.dispose().catchError((Object _) {}));
    super.dispose();
  }
}
