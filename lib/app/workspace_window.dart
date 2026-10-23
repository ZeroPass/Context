import 'dart:async';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

const workspaceWindowChannel = MethodChannel('context/window');
const defaultWhiteboardContextFraction = 1 / 3;

double whiteboardContextFraction(Object? value) =>
    value is num && value.isFinite && value > 0 && value < 1
    ? value.toDouble()
    : defaultWhiteboardContextFraction;

class _WindowBounds {
  const _WindowBounds(this.width, this.normal);

  static _WindowBounds? parse(Object? value) {
    if (value is! Map) return null;
    final width = value['width'];
    final normal = value['normal'];
    if (width is! num || !width.isFinite || width <= 0 || normal is! bool) {
      return null;
    }
    return _WindowBounds(width.toDouble(), normal);
  }

  final double width;
  final bool normal;
}

/// Expands from the Context-only width using the chosen divider ratio.
class WorkspaceWindow {
  WorkspaceWindow(
    this.preferences, {
    this.channel = workspaceWindowChannel,
    this.onSplitAdjusted,
  }) {
    _closedWidth = _savedWidth('contextWindowWidth');
    _preferredFraction = whiteboardContextFraction(
      preferences.get('whiteboardSplit'),
    );
  }

  final SharedPreferences preferences;
  final MethodChannel channel;
  final void Function(double)? onSplitAdjusted;
  Future<void> _pending = Future.value();
  double? _closedWidth;
  late double _preferredFraction;
  bool _visible = false;
  bool _available = true;
  bool _disposed = false;

  double? _savedWidth(String key) {
    final value = preferences.get(key);
    return value is num && value.isFinite && value >= 320 && value <= 100000
        ? value.toDouble()
        : null;
  }

  Future<void> _enqueue(Future<void> Function() operation) {
    final result = _pending.then((_) async {
      if (!_disposed) await operation();
    });
    // Keep later toggles usable even if a native call or preference write fails.
    _pending = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<_WindowBounds?> _readBounds() async {
    if (!_available) return null;
    try {
      final bounds = _WindowBounds.parse(await channel.invokeMethod('bounds'));
      if (bounds == null) throw const FormatException('Invalid window bounds.');
      return bounds;
    } on MissingPluginException {
      _available = false;
      return null;
    }
  }

  Future<void> _rememberClosed(_WindowBounds bounds) async {
    if (!bounds.normal || _disposed) return;
    if (_closedWidth == bounds.width) return;
    if (!await preferences.setDouble('contextWindowWidth', bounds.width)) {
      throw StateError('Could not save the window width.');
    }
    _closedWidth = bounds.width;
  }

  void setSplit(double fraction) {
    _preferredFraction = whiteboardContextFraction(fraction);
  }

  void _adjustSplit(_WindowBounds bounds) {
    if (_closedWidth == null || _disposed || !bounds.normal) return;
    // Screen clipping changes the displayed split, not the user's preference.
    onSplitAdjusted?.call((_closedWidth! / bounds.width).clamp(0.01, 0.99));
  }

  Future<void> restore({required bool visible}) {
    channel.setMethodCallHandler((call) async {
      if (call.method != 'resized' || _disposed) return;
      final bounds = _WindowBounds.parse(call.arguments);
      final mode = _visible;
      if (bounds == null) return;
      await _enqueue(() async {
        if (mode) {
          _adjustSplit(bounds);
        } else {
          await _rememberClosed(bounds);
        }
      });
    });
    return _enqueue(() async {
      // Discard the independent expanded-width setting from the previous policy.
      if (preferences.containsKey('whiteboardWindowWidth')) {
        await preferences.remove('whiteboardWindowWidth');
      }
      await _apply(visible, restoring: true);
    });
  }

  Future<void> setVisible(bool visible) =>
      _enqueue(() => _apply(visible, restoring: false));

  Future<void> _apply(bool visible, {required bool restoring}) async {
    if (!restoring && _visible == visible) return;
    final bounds = await _readBounds();
    final previousMode = _visible;
    _visible = visible;
    if (bounds == null || _disposed) return;
    if (!bounds.normal) return;
    if (!restoring && !previousMode) await _rememberClosed(bounds);

    final closed = _closedWidth ?? bounds.width;
    final target = (visible ? closed / _preferredFraction : closed).clamp(
      320.0,
      100000.0,
    );
    if (visible && _closedWidth == null) {
      await _rememberClosed(_WindowBounds(closed, true));
    }
    final resized = _WindowBounds.parse(
      await channel.invokeMethod('setWidth', target),
    );
    if (resized == null) throw const FormatException('Invalid resized bounds.');
    if (visible) {
      _adjustSplit(resized);
    } else {
      await _rememberClosed(resized);
    }
  }

  void dispose() {
    _disposed = true;
    channel.setMethodCallHandler(null);
  }
}
