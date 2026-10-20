import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';

import '../../app/file_references.dart';
import '../../app/preview_actions.dart';
import 'file_location_button.dart';
import 'passive_tooltip.dart';
import 'preview_context_menu.dart';
import 'video_preview.dart';

enum WhiteboardPreviewKind { markdown, image, video }

class WhiteboardPreviewController extends ChangeNotifier {
  WhiteboardPreviewController({
    required this.resolverFor,
    this.videoFactory = NativePreviewVideoSession.new,
  });

  final FileReferenceResolver Function(String path) resolverFor;
  final PreviewVideoSession Function() videoFactory;
  String? path;
  WhiteboardPreviewKind? kind;
  String? markdown;
  String? error;
  FileReferenceResolver? resolver;
  PreviewVideoSession? video;
  bool loading = false;
  List<String> _gallery = const [];
  List<String> get gallery => _gallery;
  bool _samePath(String a, String b) => Platform.isWindows
      ? a.replaceAll('/', '\\').toLowerCase() ==
            b.replaceAll('/', '\\').toLowerCase()
      : a == b;
  int get galleryIndex =>
      path == null ? -1 : _gallery.indexWhere((file) => _samePath(file, path!));
  bool get hasPrevious => galleryIndex > 0;
  bool get hasNext => galleryIndex >= 0 && galleryIndex + 1 < _gallery.length;

  void setGallery(List<String> files) {
    _gallery = List.unmodifiable({
      ...files,
      if (path != null && !files.any((file) => _samePath(file, path!))) path!,
    });
    _changed();
  }

  void navigate(int delta) {
    final index = galleryIndex + delta;
    if (galleryIndex < 0 || index < 0 || index >= _gallery.length) return;
    unawaited(open(_gallery[index]));
  }

  int _generation = 0;
  bool _disposed = false;
  static const maxMarkdownBytes = 8 * 1024 * 1024;

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  void _releaseVideo() {
    video?.removeListener(_changed);
    video?.dispose();
    video = null;
  }

  Future<void> open(String file) async {
    final generation = ++_generation;
    _releaseVideo();
    path = file;
    kind = isPreviewMarkdown(file)
        ? WhiteboardPreviewKind.markdown
        : isPreviewVideo(file)
        ? WhiteboardPreviewKind.video
        : WhiteboardPreviewKind.image;
    markdown = null;
    error = null;
    resolver = resolverFor(file);
    loading = kind != WhiteboardPreviewKind.image;
    _changed();
    try {
      if (kind == WhiteboardPreviewKind.markdown) {
        final bytes = <int>[];
        // Bound even a changing file; do not read arbitrarily large logs as text.
        await for (final chunk in File(
          file,
        ).openRead(0, maxMarkdownBytes + 1)) {
          if (_disposed || generation != _generation) return;
          bytes.addAll(chunk);
        }
        if (bytes.length > maxMarkdownBytes) {
          throw StateError(
            'Markdown is too large to preview. Open it externally.',
          );
        }
        if (_disposed || generation != _generation) return;
        markdown = utf8.decode(bytes, allowMalformed: true);
      } else if (kind == WhiteboardPreviewKind.video) {
        final session = videoFactory();
        video = session;
        session.addListener(_changed);
        await session.open(file);
      }
    } catch (exception) {
      if (_disposed || generation != _generation) return;
      error = '$exception';
    } finally {
      if (!_disposed && generation == _generation) {
        loading = false;
        _changed();
      }
    }
  }

  void close() {
    _generation++;
    _releaseVideo();
    path = null;
    kind = null;
    resolver = null;
    markdown = null;
    error = null;
    loading = false;
    _gallery = const [];
    _changed();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _releaseVideo();
    super.dispose();
  }
}

class WhiteboardFilePreview extends StatefulWidget {
  const WhiteboardFilePreview({
    super.key,
    required this.controller,
    required this.markdownBuilder,
    required this.onClose,
    required this.onOpenExternal,
    required this.onReveal,
    this.embedded = false,
    this.actions,
  });
  final WhiteboardPreviewController controller;
  final Widget Function(String, FileReferenceResolver) markdownBuilder;
  final VoidCallback onClose;
  final VoidCallback onOpenExternal;
  final VoidCallback onReveal;
  final bool embedded;
  final PreviewActions? actions;

  @override
  State<WhiteboardFilePreview> createState() => _WhiteboardFilePreviewState();
}

class _WhiteboardFilePreviewState extends State<WhiteboardFilePreview>
    with WidgetsBindingObserver {
  final _imageTransform = TransformationController();
  final _markdownScroll = ScrollController();
  final _viewerFocus = FocusNode(debugLabel: 'Whiteboard attachment viewer');
  final _selection = ValueNotifier(false);
  bool get _selected => _selection.value;
  bool _expanded = false;
  double? _embeddedHeight;
  String? _lastPath;
  WhiteboardPreviewController get _controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _lastPath = _controller.path;
    _controller.addListener(_pathChanged);
    WidgetsBinding.instance.addObserver(this);
  }

  void _pathChanged() {
    if (_lastPath == _controller.path) return;
    _lastPath = _controller.path;
    _imageTransform.value = Matrix4.identity();
    if (_markdownScroll.hasClients) _markdownScroll.jumpTo(0);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      unawaited(_controller.video?.pause().catchError((Object _) {}));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.removeListener(_pathChanged);
    _imageTransform.dispose();
    _markdownScroll.dispose();
    _viewerFocus.dispose();
    _selection.dispose();
    super.dispose();
  }

  Widget _button(String tip, IconData icon, VoidCallback? action) =>
      PassiveTooltip(
        message: tip,
        preferBelow: true,
        child: IconButton(
          onPressed: action,
          visualDensity: VisualDensity.compact,
          constraints: const BoxConstraints.tightFor(width: 28, height: 32),
          padding: const EdgeInsets.all(4),
          icon: Icon(icon, size: 17),
        ),
      );

  void _selectViewer() {
    _selection.value = true;
    _viewerFocus.requestFocus();
  }

  void _deselectViewer() {
    _selection.value = false;
    _viewerFocus.unfocus();
  }

  KeyEventResult _keyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isControlPressed ||
        keyboard.isMetaPressed ||
        keyboard.isAltPressed ||
        keyboard.isShiftPressed) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      _controller.navigate(-1);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      _controller.navigate(1);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape && !_expanded) {
      _deselectViewer();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _navigate(int delta) {
    _viewerFocus.requestFocus();
    _controller.navigate(delta);
  }

  Future<void> _expand() async {
    if (_expanded) return;
    _selection.value = true;
    _embeddedHeight = context.size?.height;
    setState(() => _expanded = true);
    // One surface owns the video texture/scroll controllers at a time.
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    try {
      await showDialog<void>(
        context: context,
        useSafeArea: false,
        builder: (dialogContext) => Dialog.fullscreen(
          key: const ValueKey('whiteboard-app-preview'),
          child: CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.escape): () =>
                  Navigator.of(dialogContext).pop(),
            },
            child: Material(
              color: Theme.of(context).colorScheme.surfaceContainerLow,
              child: SafeArea(
                child: _layout(
                  expanded: true,
                  exit: () => Navigator.of(dialogContext).pop(),
                ),
              ),
            ),
          ),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _expanded = false);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _selected) _viewerFocus.requestFocus();
        });
      }
    }
  }

  Widget _layout({
    required bool expanded,
    VoidCallback? exit,
  }) => ListenableBuilder(
    listenable: Listenable.merge([_controller, _selection]),
    builder: (context, _) => TapRegion(
      onTapOutside: (_) => _deselectViewer(),
      child: Focus(
        focusNode: _viewerFocus,
        autofocus: expanded,
        onKeyEvent: _keyEvent,
        child: ColoredBox(
          key: const ValueKey('whiteboard-preview-background'),
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          child: Column(
            mainAxisSize: widget.embedded && !expanded
                ? MainAxisSize.min
                : MainAxisSize.max,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 6, 4, 4),
                child: Row(
                  children: [
                    _button(
                      'Previous attachment (Left arrow)',
                      Icons.chevron_left_rounded,
                      _controller.hasPrevious ? () => _navigate(-1) : null,
                    ),
                    Text(
                      '${_controller.galleryIndex < 0 ? 1 : _controller.galleryIndex + 1}/${_controller.gallery.isEmpty ? 1 : _controller.gallery.length}',
                      key: const ValueKey('whiteboard-preview-counter'),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    _button(
                      'Next attachment (Right arrow)',
                      Icons.chevron_right_rounded,
                      _controller.hasNext ? () => _navigate(1) : null,
                    ),
                    Expanded(
                      child: Text(
                        (_controller.path ?? '').split(RegExp(r'[/\\]')).last,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                    _button(
                      expanded ? 'Exit expanded view' : 'Expand to app',
                      expanded
                          ? Icons.fullscreen_exit_rounded
                          : Icons.fullscreen_rounded,
                      expanded ? exit : _expand,
                    ),
                    if (_controller.kind == WhiteboardPreviewKind.image)
                      ListenableBuilder(
                        listenable: _imageTransform,
                        builder: (context, _) => PassiveTooltip(
                          message: 'Reset zoom to 100%',
                          preferBelow: true,
                          child: TextButton(
                            key: const ValueKey('whiteboard-image-zoom'),
                            style: TextButton.styleFrom(
                              minimumSize: const Size(40, 36),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                              ),
                              textStyle: Theme.of(context).textTheme.bodySmall,
                            ),
                            onPressed: () =>
                                _imageTransform.value = Matrix4.identity(),
                            child: Text(
                              '${(_imageTransform.value.getMaxScaleOnAxis() * 100).round()}%',
                            ),
                          ),
                        ),
                      ),
                    FileLocationButton(
                      onReveal: widget.onReveal,
                      onOpenExternal: widget.onOpenExternal,
                    ),
                    if (!expanded)
                      _button(
                        'Close preview',
                        Icons.close_rounded,
                        widget.onClose,
                      ),
                  ],
                ),
              ),
              SizedBox(
                height: 2,
                child: _controller.loading
                    ? const LinearProgressIndicator(minHeight: 2)
                    : null,
              ),
              if (widget.embedded && !expanded)
                Flexible(fit: FlexFit.loose, child: _content(embedded: true))
              else
                Expanded(child: _content()),
              if (_controller.video != null) _videoControls(_controller.video!),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _content({bool embedded = false}) {
    final error = _controller.error ?? _controller.video?.error;
    if (error != null) {
      return Center(
        child: Padding(padding: const EdgeInsets.all(14), child: Text(error)),
      );
    }
    final content = switch (_controller.kind) {
      WhiteboardPreviewKind.markdown => Scrollbar(
        controller: _markdownScroll,
        child: SingleChildScrollView(
          controller: _markdownScroll,
          padding: const EdgeInsets.all(14),
          child: widget.markdownBuilder(
            _controller.markdown ?? '',
            _controller.resolver!,
          ),
        ),
      ),
      WhiteboardPreviewKind.image => Listener(
        onPointerSignal: (event) {
          if (_selected && event is PointerScrollEvent) {
            // InteractiveViewer zooms directly; prevent the ancestor also scrolling.
            GestureBinding.instance.pointerSignalResolver.register(
              event,
              (_) {},
            );
          }
        },
        child: DecoratedBox(
          key: const ValueKey('whiteboard-image-selection'),
          position: DecorationPosition.foreground,
          decoration: BoxDecoration(
            border: Border.all(
              color: _selected
                  ? Theme.of(
                      context,
                    ).colorScheme.primary.withValues(alpha: 0.35)
                  : Colors.transparent,
            ),
          ),
          child: IgnorePointer(
            ignoring: !_selected,
            child: InteractiveViewer(
              transformationController: _imageTransform,
              maxScale: 8,
              child: Image.file(
                File(_controller.path!),
                width: double.infinity,
                height: embedded ? null : double.infinity,
                fit: BoxFit.contain,
                errorBuilder: (_, _, _) => const Text(
                  'Image preview unavailable. Open it externally.',
                ),
              ),
            ),
          ),
        ),
      ),
      WhiteboardPreviewKind.video =>
        embedded
            ? AspectRatio(
                aspectRatio: 16 / 9,
                child: _controller.video?.buildVideo() ?? const SizedBox(),
              )
            : _controller.video?.buildVideo() ?? const SizedBox.expand(),
      null => const SizedBox.expand(),
    };
    final path = _controller.path;
    if (path == null) return content;
    return PreviewContextMenu(
      key: const ValueKey('whiteboard-preview-menu'),
      path: path,
      markdown: _controller.markdown,
      snapshot: _controller.video?.snapshot,
      actions: widget.actions,
      child: Listener(
        onPointerDown: (event) {
          if (event.buttons == kPrimaryButton) _selectViewer();
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _selectViewer,
          onDoubleTap: _expanded ? null : _expand,
          child: content,
        ),
      ),
    );
  }

  void _videoAction(Future<void> Function() action) {
    unawaited(
      action().catchError((Object error) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('$error')));
        }
      }),
    );
  }

  String _time(Duration value) =>
      '${value.inMinutes}:${(value.inSeconds % 60).toString().padLeft(2, '0')}';

  Widget _videoControls(PreviewVideoSession video) => LayoutBuilder(
    builder: (context, constraints) => Padding(
      padding: const EdgeInsets.fromLTRB(6, 0, 8, 6),
      child: Row(
        children: [
          _button(
            video.playing ? 'Pause video' : 'Play video',
            video.playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
            () => _videoAction(video.togglePlayback),
          ),
          Expanded(
            child: Slider(
              key: const ValueKey('whiteboard-video-seek'),
              value: video.position.inMilliseconds.toDouble().clamp(
                0,
                video.duration.inMilliseconds.toDouble().clamp(
                  1,
                  double.infinity,
                ),
              ),
              max: video.duration.inMilliseconds.toDouble().clamp(
                1,
                double.infinity,
              ),
              onChanged: video.duration == Duration.zero
                  ? null
                  : (value) => _videoAction(
                      () => video.seek(Duration(milliseconds: value.round())),
                    ),
            ),
          ),
          if (constraints.maxWidth >= 360)
            Text(
              '${_time(video.position)} / ${_time(video.duration)}',
              style: Theme.of(context).textTheme.labelSmall,
            ),
          _button(
            video.volume == 0 ? 'Unmute video' : 'Mute video',
            video.volume == 0
                ? Icons.volume_off_rounded
                : Icons.volume_up_rounded,
            () => _videoAction(
              () => video.setVolume(video.volume == 0 ? 100 : 0),
            ),
          ),
          if (constraints.maxWidth >= 480)
            SizedBox(
              width: 90,
              child: Slider(
                key: const ValueKey('whiteboard-video-volume'),
                value: video.volume.clamp(0, 100),
                max: 100,
                onChanged: (value) =>
                    _videoAction(() => video.setVolume(value)),
              ),
            ),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    if (!_expanded) return _layout(expanded: false);
    return widget.embedded
        ? SizedBox(height: _embeddedHeight)
        : const SizedBox.expand();
  }
}
