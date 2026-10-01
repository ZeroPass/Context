import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:media_kit/media_kit.dart';

Future<void> main(List<String> args) async {
  if (args.length != 2) {
    throw ArgumentError('Usage: video_smoke.dart CLIP_PATH LIBMPV_DLL_PATH');
  }
  MediaKit.ensureInitialized(libmpv: args[1]);
  final player = Player(
    configuration: const PlayerConfiguration(vo: 'null', muted: true),
  );
  final errors = <String>[];
  final subscription = player.stream.error.listen(errors.add);
  final native = player.platform as NativePlayer;
  Future<String> property(String name) async {
    try {
      return await native.getProperty(name);
    } catch (error) {
      return 'Unavailable: $error';
    }
  }

  try {
    // The app's VideoController enables decoding; this headless smoke has none.
    await native.setProperty('vid', 'auto');
    await player
        .open(Media(args[0]), play: false)
        .timeout(const Duration(seconds: 20));
    final duration = player.state.duration > Duration.zero
        ? player.state.duration
        : await player.stream.duration
              .firstWhere((value) => value > Duration.zero)
              .timeout(const Duration(seconds: 20));
    if (duration < const Duration(seconds: 3))
      throw StateError('Fixture duration is too short.');
    await player.seek(const Duration(seconds: 1));
    final advanced = player.stream.position.firstWhere(
      (value) => value >= const Duration(milliseconds: 1500),
    );
    await player.play();
    final position = await advanced.timeout(const Duration(seconds: 20));
    await player.pause();
    final config = await property('mpv-configuration');
    if (config.contains('--enable-gpl') || config.contains('-Dgpl=true')) {
      throw StateError('Unexpected GPL-enabled mpv build.');
    }
    if (errors.isNotEmpty) throw StateError('Native playback errors: $errors');
    stdout.writeln(
      jsonEncode({
        'result': 'passed',
        'mode': 'native Windows decode/play/seek/pause; no rendering surface',
        'clip': args[0],
        'library': args[1],
        'duration_ms': duration.inMilliseconds,
        'position_ms': position.inMilliseconds,
        'mpv_version': await property('mpv-version'),
        'ffmpeg_version': await property('ffmpeg-version'),
        'configuration': config,
        'errors': errors,
      }),
    );
  } finally {
    await subscription.cancel();
    await player.dispose().timeout(const Duration(seconds: 10));
  }
}
