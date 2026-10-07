import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

typedef ClipboardTextWriter = Future<void> Function(String text);
typedef ClipboardTextReader = Future<String?> Function();

const _windowsClipboard = MethodChannel('context/clipboard');

Future<void> _writeText(String text) async {
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
    await _windowsClipboard.invokeMethod<void>('writeText', text);
  } else {
    await Clipboard.setData(ClipboardData(text: text));
  }
}

Future<String?> _readText() async =>
    (await Clipboard.getData(Clipboard.kTextPlain))?.text;

class ClipboardCopyException implements Exception {
  const ClipboardCopyException();

  @override
  String toString() => 'Clipboard could not be updated. Please try again.';
}

class ClipboardWriter {
  ClipboardWriter({
    ClipboardTextWriter? write,
    ClipboardTextReader? read,
    Future<void> Function(Duration)? delay,
  }) : _write = write ?? _writeText,
       _read = read ?? _readText,
       _delay = delay ?? Future<void>.delayed;

  final ClipboardTextWriter _write;
  final ClipboardTextReader _read;
  final Future<void> Function(Duration) _delay;
  ({int request, String text, Completer<bool> completion})? _queued;
  bool _running = false;
  int _latest = 0;

  // Serialize writes and skip superseded clicks, including their retries.
  Future<bool> copy(String text) {
    final request = ++_latest;
    final completion = Completer<bool>();
    _queued?.completion.complete(false);
    _queued = (request: request, text: text, completion: completion);
    if (!_running) unawaited(_drain());
    return completion.future;
  }

  Future<void> _drain() async {
    _running = true;
    while (_queued != null) {
      final pending = _queued!;
      _queued = null;
      try {
        pending.completion.complete(await _copy(pending.request, pending.text));
      } catch (error, stack) {
        pending.completion.completeError(error, stack);
      }
    }
    _running = false;
  }

  Future<bool> _copy(int request, String text) async {
    if (request != _latest) return false;
    if (text.contains('\u0000')) throw const ClipboardCopyException();
    const waits = [
      Duration(milliseconds: 20),
      Duration(milliseconds: 60),
      Duration(milliseconds: 120),
    ];
    for (var attempt = 0; attempt <= waits.length; attempt++) {
      if (request != _latest) return false;
      try {
        await _write(text);
        if (request != _latest) return false;
        final actual = await _read();
        if (request != _latest) return false;
        if (actual == text) return true;
      } catch (_) {
        if (request != _latest) return false;
      }
      if (attempt < waits.length) await _delay(waits[attempt]);
    }
    throw const ClipboardCopyException();
  }
}

final clipboardWriter = ClipboardWriter();
