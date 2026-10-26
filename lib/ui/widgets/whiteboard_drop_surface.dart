import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../../app/whiteboard_drop.dart';

const whiteboardInputChannel = MethodChannel('context/whiteboard-input');

class WhiteboardDropSurface extends StatefulWidget {
  const WhiteboardDropSurface({
    super.key,
    required this.child,
    required this.path,
    required this.enabled,
    required this.onPublished,
    this.publisher,
    this.onInput,
  });
  final Widget child;
  final String path;
  final bool enabled;
  final VoidCallback onPublished;
  final WhiteboardDrop? publisher;
  final Future<void> Function(
    Map<Object?, Object?> data, {
    required bool paste,
  })?
  onInput;
  @override
  State<WhiteboardDropSurface> createState() => WhiteboardDropSurfaceState();
}

class WhiteboardDropSurfaceState extends State<WhiteboardDropSurface> {
  bool _hover = false;
  bool _busy = false;
  Rect? _lastBounds;
  bool _measuring = false;
  final _area = GlobalKey();
  bool get _enabled =>
      widget.enabled && !_busy && ModalRoute.of(context)?.isCurrent != false;

  @override
  void initState() {
    super.initState();
    whiteboardInputChannel.setMethodCallHandler((call) async {
      if (!mounted) return;
      if (call.method == 'hover') {
        setState(() => _hover = call.arguments == true && _enabled);
      } else if (call.method == 'drop' && _enabled) {
        await _accept(
          (call.arguments as Map).cast<Object?, Object?>(),
          paste: false,
        );
      }
    });
  }

  Future<void> paste() async {
    if (!_enabled) return;
    try {
      final data = await whiteboardInputChannel
          .invokeMapMethod<Object?, Object?>('paste');
      if (mounted && _enabled && data != null) await _accept(data, paste: true);
    } on Object catch (error) {
      _error(error);
    }
  }

  void _error(Object error) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('$error')));
  }

  Future<void> _accept(
    Map<Object?, Object?> data, {
    required bool paste,
  }) async {
    if (!_enabled) return;
    setState(() {
      _busy = true;
      _hover = false;
    });
    try {
      if (widget.onInput != null) {
        await widget.onInput!(data, paste: paste);
      } else {
        await (widget.publisher ?? WhiteboardDrop()).publish(widget.path, data);
        if (mounted) widget.onPublished();
      }
    } on Object catch (error) {
      _error(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _bounds(Rect bounds) async {
    if (_lastBounds == bounds) return;
    _lastBounds = bounds;
    try {
      await whiteboardInputChannel.invokeMethod<void>(
        'bounds',
        Float64List.fromList([
          bounds.left,
          bounds.top,
          bounds.right,
          bounds.bottom,
        ]),
      );
    } on MissingPluginException {
      // Widget tests and non-Windows development do not install the Windows bridge.
    } on PlatformException catch (error) {
      _error(error.message ?? error.code);
    }
  }

  @override
  void dispose() {
    whiteboardInputChannel.setMethodCallHandler(null);
    unawaited(_bounds(Rect.zero));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final enabled = _enabled;
    MediaQuery.devicePixelRatioOf(context);
    _measureBounds();
    final scheme = Theme.of(context).colorScheme;
    return _TrackDropBounds(
      onPaint: _measureBounds,
      child: Stack(
        key: _area,
        fit: StackFit.expand,
        children: [
          widget.child,
          if ((_hover && enabled) || _busy)
            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  key: const ValueKey('whiteboard-drop-overlay'),
                  margin: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: scheme.surface.withValues(alpha: 0.94),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: scheme.primary.withValues(alpha: 0.55),
                      width: 1.5,
                    ),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        _busy
                            ? Icons.hourglass_top_rounded
                            : Icons.file_download_outlined,
                        size: 32,
                        color: scheme.primary,
                      ),
                      const SizedBox(height: 10),
                      Text(
                        _busy ? 'Preparing drop...' : 'Drop here',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        'For your agent',
                        style: TextStyle(fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  // Observe real layout/paint changes, including a retained pane moving during
  // a swipe. No timer or extra frames: unchanged rectangles never cross the bridge.
  void _measureBounds() {
    if (_measuring) return;
    _measuring = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _measuring = false;
      if (!mounted) return;
      final scale = MediaQuery.devicePixelRatioOf(context);
      final box = _area.currentContext?.findRenderObject() as RenderBox?;
      final bounds = _enabled && box != null && box.hasSize
          ? box.localToGlobal(Offset.zero) & box.size
          : Rect.zero;
      unawaited(
        _bounds(
          Rect.fromLTRB(
            bounds.left * scale,
            bounds.top * scale,
            bounds.right * scale,
            bounds.bottom * scale,
          ),
        ),
      );
    });
  }
}

class _TrackDropBounds extends SingleChildRenderObjectWidget {
  const _TrackDropBounds({required this.onPaint, required super.child});
  final VoidCallback onPaint;
  @override
  RenderObject createRenderObject(BuildContext context) =>
      _DropBoundsRenderer(onPaint);
  @override
  void updateRenderObject(
    BuildContext context,
    _DropBoundsRenderer renderObject,
  ) {
    renderObject.onPaint = onPaint;
  }
}

class _DropBoundsRenderer extends RenderProxyBox {
  _DropBoundsRenderer(this.onPaint);
  VoidCallback onPaint;
  @override
  void paint(PaintingContext context, Offset offset) {
    super.paint(context, offset);
    onPaint();
  }
}
