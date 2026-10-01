import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// Equal gutters keep the resize cue centered between the visible panel frames.
const contextPanelGutterWidth = 13.0;
const contextPanelTopInset = 4.0;

/// Keeps Context mounted while the optional Whiteboard pane opens and closes.
class WhiteboardWorkspace extends StatefulWidget {
  const WhiteboardWorkspace({
    super.key,
    required this.visible,
    required this.contextPane,
    this.whiteboardPane = const SizedBox.expand(),
  });

  final bool visible;
  final Widget contextPane;
  final Widget whiteboardPane;

  @override
  State<WhiteboardWorkspace> createState() => _WhiteboardWorkspaceState();
}

class _WhiteboardWorkspaceState extends State<WhiteboardWorkspace> {
  static const _dividerWidth = 18.0;
  static const _minContextWidth = 400.0;
  static const _minWhiteboardWidth = 260.0;
  final _dividerFocus = FocusNode();
  // Reparent pane subtrees without losing their state when the layout changes.
  final _contextKey = GlobalKey();
  final _whiteboardKey = GlobalKey();
  final _pages = PageController(initialPage: 1, keepPage: false);
  double _contextFraction = 1 / 3;
  int _pageIndex = 1;
  bool _compact = false;
  bool _hovered = false;
  bool _dragging = false;
  bool _focused = false;

  double _clampContextWidth(double width, double available) =>
      width.clamp(_minContextWidth, available - _minWhiteboardWidth);

  double _contextWidth(double available) =>
      _clampContextWidth(available * _contextFraction, available);

  void _resize(double delta, double available) {
    if (available <= 0) return;
    setState(() {
      _contextFraction =
          _clampContextWidth(_contextWidth(available) + delta, available) /
          available;
    });
  }

  @override
  void didUpdateWidget(WhiteboardWorkspace oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.visible && !oldWidget.visible) _pageIndex = 1;
    if (!widget.visible && oldWidget.visible) {
      _dividerFocus.unfocus();
      _hovered = false;
      _dragging = false;
      _focused = false;
    }
  }

  @override
  void dispose() {
    _dividerFocus.dispose();
    _pages.dispose();
    super.dispose();
  }

  Widget _contextPanel(double width) => SizedBox(
    key: const ValueKey('context-pane'),
    width: width,
    child: KeyedSubtree(key: _contextKey, child: widget.contextPane),
  );

  Widget _whiteboardPanel(BuildContext context, {bool compact = false}) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      key: const ValueKey('whiteboard-pane'),
      margin: EdgeInsets.fromLTRB(
        compact ? 12 : contextPanelGutterWidth,
        contextPanelTopInset,
        12,
        12,
      ),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest.withValues(alpha: 0.28),
        border: Border.all(color: scheme.outlineVariant, width: 0.7),
        borderRadius: BorderRadius.circular(14),
      ),
      child: KeyedSubtree(key: _whiteboardKey, child: widget.whiteboardPane),
    );
  }

  void _showPage(int index) {
    if (!_pages.hasClients) return;
    if (MediaQuery.disableAnimationsOf(context)) {
      _pages.jumpToPage(index);
    } else {
      unawaited(
        _pages.animateToPage(
          index,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
        ),
      );
    }
  }

  Widget _pageButton(int index, String label, IconData icon) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      selected: _pageIndex == index,
      child: TextButton.icon(
        key: ValueKey('workspace-page-$index'),
        onPressed: () => _showPage(index),
        style: TextButton.styleFrom(
          foregroundColor: _pageIndex == index
              ? scheme.primary
              : scheme.onSurfaceVariant,
          backgroundColor: _pageIndex == index
              ? scheme.primary.withValues(alpha: 0.07)
              : Colors.transparent,
          minimumSize: const Size(0, 32),
          visualDensity: VisualDensity.compact,
          textStyle: Theme.of(context).textTheme.bodySmall,
        ),
        icon: Icon(icon, size: 16),
        label: Text(label),
      ),
    );
  }

  Widget _compactWorkspace(BuildContext context, double width) => Column(
    children: [
      Expanded(
        child: PageView(
          key: const ValueKey('whiteboard-pages'),
          controller: _pages,
          allowImplicitScrolling: true,
          scrollBehavior: ScrollConfiguration.of(context).copyWith(
            dragDevices: {
              ...ScrollConfiguration.of(context).dragDevices,
              PointerDeviceKind.mouse,
            },
          ),
          onPageChanged: (page) {
            if (_pageIndex != page) setState(() => _pageIndex = page);
          },
          children: [
            _WorkspacePage(
              active: _pageIndex == 0,
              child: _contextPanel(width),
            ),
            _WorkspacePage(
              active: _pageIndex == 1,
              child: _whiteboardPanel(context, compact: true),
            ),
          ],
        ),
      ),
      Padding(
        key: const ValueKey('workspace-page-navigation'),
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _pageButton(0, 'Context', Icons.chevron_left_rounded),
            const SizedBox(width: 8),
            _pageButton(1, 'Whiteboard', Icons.chevron_right_rounded),
          ],
        ),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact =
            widget.visible &&
            constraints.maxWidth <
                _minContextWidth + _minWhiteboardWidth + _dividerWidth;
        if (compact != _compact) {
          _compact = compact;
          if (compact) {
            final page = _pageIndex;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted && _compact && _pages.hasClients) {
                _pages.jumpToPage(page);
              }
            });
          }
        }
        if (compact) return _compactWorkspace(context, constraints.maxWidth);
        final available = math.max(0.0, constraints.maxWidth - _dividerWidth);
        final contextWidth = widget.visible
            ? _contextWidth(available)
            : constraints.maxWidth;
        final highlighted = _hovered || _dragging || _focused;
        String describeWidth(double width) =>
            '${(width / math.max(1.0, available) * 100).round()}% Context';
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _contextPanel(contextWidth),
            if (widget.visible) ...[
              Semantics(
                label: 'Resize Context and Whiteboard',
                slider: true,
                value: describeWidth(contextWidth),
                increasedValue: describeWidth(
                  _clampContextWidth(contextWidth + 24, available),
                ),
                decreasedValue: describeWidth(
                  _clampContextWidth(contextWidth - 24, available),
                ),
                onIncrease: () => _resize(24, available),
                onDecrease: () => _resize(-24, available),
                child: Focus(
                  focusNode: _dividerFocus,
                  onFocusChange: (focused) =>
                      setState(() => _focused = focused),
                  onKeyEvent: (_, event) {
                    if (event is KeyDownEvent || event is KeyRepeatEvent) {
                      if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
                        _resize(-24, available);
                        return KeyEventResult.handled;
                      }
                      if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
                        _resize(24, available);
                        return KeyEventResult.handled;
                      }
                    }
                    return KeyEventResult.ignored;
                  },
                  child: MouseRegion(
                    cursor: SystemMouseCursors.resizeColumn,
                    onEnter: (_) => setState(() => _hovered = true),
                    onExit: (_) => setState(() => _hovered = false),
                    child: GestureDetector(
                      key: const ValueKey('whiteboard-divider'),
                      behavior: HitTestBehavior.opaque,
                      onHorizontalDragStart: (_) {
                        _dividerFocus.requestFocus();
                        setState(() => _dragging = true);
                      },
                      onHorizontalDragUpdate: (details) =>
                          _resize(details.delta.dx, available),
                      onHorizontalDragEnd: (_) =>
                          setState(() => _dragging = false),
                      onHorizontalDragCancel: () =>
                          setState(() => _dragging = false),
                      child: SizedBox(
                        width: _dividerWidth,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 20),
                          child: Stack(
                            clipBehavior: Clip.none,
                            alignment: Alignment.center,
                            children: [
                              Positioned(
                                left: -5,
                                right: -5,
                                child: IgnorePointer(
                                  child: AnimatedOpacity(
                                    opacity: highlighted ? 0.5 : 0,
                                    duration:
                                        MediaQuery.disableAnimationsOf(context)
                                        ? Duration.zero
                                        : const Duration(milliseconds: 120),
                                    child: Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.spaceBetween,
                                      children: [
                                        Icon(
                                          Icons.chevron_left_rounded,
                                          size: 12,
                                          color: scheme.onSurfaceVariant,
                                        ),
                                        Icon(
                                          Icons.chevron_right_rounded,
                                          size: 12,
                                          color: scheme.onSurfaceVariant,
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Expanded(child: _whiteboardPanel(context)),
            ],
          ],
        );
      },
    );
  }
}

class _WorkspacePage extends StatefulWidget {
  const _WorkspacePage({required this.child, required this.active});
  final Widget child;
  final bool active;
  @override
  State<_WorkspacePage> createState() => _WorkspacePageState();
}

class _WorkspacePageState extends State<_WorkspacePage>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;
  @override
  Widget build(BuildContext context) {
    super.build(context);
    return TickerMode(
      enabled: widget.active,
      child: ExcludeFocus(excluding: !widget.active, child: widget.child),
    );
  }
}
