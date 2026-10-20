import 'dart:async';
import 'dart:convert';

import '../src/bindings/bindings.dart';
import 'whiteboard.dart';

typedef WslPathLookup =
    Future<Map<String, String>> Function(String distro, List<String> paths);

class WslPathResolver {
  WslPathResolver({WslPathLookup? lookup}) : _lookup = lookup ?? _nativeLookup;
  final WslPathLookup _lookup;
  final _pending = <String, Map<String, Completer<String?>>>{};
  final _cache = <String, Future<String?>>{};
  bool _running = false;

  Future<String?> resolve(String unc) {
    final parts = unc.replaceAll('/', '\\').split('\\');
    if (parts.length < 5 ||
        parts[0].isNotEmpty ||
        parts[1].isNotEmpty ||
        !{'wsl.localhost', r'wsl$'}.contains(parts[2].toLowerCase())) {
      return Future.value(null);
    }
    final path = '/${parts.skip(4).join('/')}';
    final key = '${parts[3]}\u0000$path';
    if (utf8.encode(path).length > 4096 ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(path) ||
        _cache.length >= 128 && !_cache.containsKey(key)) {
      return Future.value(null);
    }
    return _cache.putIfAbsent(key, () {
      final completer = Completer<String?>();
      _pending.putIfAbsent(parts[3], () => {})[path] = completer;
      if (!_running) {
        _running = true;
        // Collect links created together by the Markdown builder into one request.
        Timer(const Duration(milliseconds: 5), _flush);
      }
      return completer.future;
    });
  }

  Future<void> _flush() async {
    while (_pending.isNotEmpty) {
      final distro = _pending.keys.first;
      final pending = _pending[distro]!;
      final batch = <String, Completer<String?>>{};
      var bytes = 0;
      for (final entry in pending.entries) {
        final size = utf8.encode(entry.key).length;
        if (batch.length >= 16 || bytes + size > 12 * 1024) break;
        batch[entry.key] = entry.value;
        bytes += size;
      }
      for (final path in batch.keys) {
        pending.remove(path);
      }
      if (pending.isEmpty) _pending.remove(distro);
      try {
        final targets = await _lookup(distro, batch.keys.toList());
        for (final entry in batch.entries) {
          final target = targets[entry.key];
          entry.value.complete(target?.startsWith('/') == true ? target : null);
        }
      } on Object {
        for (final completer in batch.values) {
          completer.complete(null);
        }
      }
    }
    _running = false;
  }

  static Future<Map<String, String>> _nativeLookup(
    String distro,
    List<String> paths,
  ) async {
    final id = nextWhiteboardRequestId();
    final completer = Completer<Map<String, String>>();
    final subscription = WhiteboardResult.rustSignalStream.listen((pack) {
      final message = pack.message;
      if (message.requestId != id || completer.isCompleted) return;
      if (message.error != null) {
        completer.completeError(StateError(message.error!));
      } else {
        try {
          completer.complete((jsonDecode(message.payloadJson) as Map).cast());
        } on Object catch (error) {
          completer.completeError(error);
        }
      }
    });
    try {
      ResolveWhiteboardPaths(
        requestId: id,
        distro: distro,
        pathsJson: jsonEncode(paths),
      ).sendSignalToRust();
      return await completer.future.timeout(const Duration(seconds: 6));
    } finally {
      await subscription.cancel();
    }
  }
}
