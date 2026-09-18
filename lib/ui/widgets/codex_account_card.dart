import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Keeps interaction feedback on the card edge, separate from the usage chart.
class CodexAccountCard extends StatefulWidget {
  const CodexAccountCard({
    super.key,
    required this.name,
    required this.slot,
    required this.selected,
    required this.surfaceColor,
    required this.accentColor,
    required this.outlineColor,
    required this.usage,
    required this.actions,
    this.usageBackground,
    this.onActivate,
  });

  final String name;
  final String slot;
  final bool selected;
  final Color surfaceColor;
  final Color accentColor;
  final Color outlineColor;
  final Widget usage;
  final Widget actions;
  final Widget? usageBackground;
  final Future<bool> Function()? onActivate;

  @override
  State<CodexAccountCard> createState() => _CodexAccountCardState();
}

class _CodexAccountCardState extends State<CodexAccountCard>
    with TickerProviderStateMixin {
  late final AnimationController _emphasis = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 130),
    reverseDuration: const Duration(milliseconds: 90),
  );
  late final AnimationController _activation = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 800),
  );
  late final Listenable _motion = Listenable.merge([_emphasis, _activation]);
  bool _hovered = false;
  bool _focused = false;
  bool _pressed = false;
  bool _switching = false;
  bool _confirming = false;
  bool _reduceMotion = false;

  bool get _canActivate =>
      widget.onActivate != null && !widget.selected && !_switching;

  @override
  void initState() {
    super.initState();
    _activation.addStatusListener((status) {
      if (status == AnimationStatus.completed && !_switching && _confirming) {
        setState(() => _confirming = false);
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (reduceMotion != _reduceMotion) {
      _reduceMotion = reduceMotion;
      _updateEmphasis();
      _updateActivation();
    }
  }

  @override
  void didUpdateWidget(CodexAccountCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selected && !widget.selected && _confirming) {
      _confirming = false;
      _updateActivation();
    }
    if (!_canActivate) {
      _pressed = false;
    }
    _updateEmphasis();
  }

  void _updateEmphasis() {
    final target = !_canActivate
        ? 0.0
        : _pressed
        ? 1.0
        : _hovered || _focused
        ? 0.65
        : 0.0;
    if (_reduceMotion) {
      _emphasis.value = target;
    } else {
      _emphasis.animateTo(target, curve: Curves.easeOutCubic);
    }
  }

  void _updateActivation() {
    _activation.stop();
    if (_reduceMotion) _confirming = false;
    if (_reduceMotion || (!_switching && !_confirming)) {
      _activation.value = 0;
    } else if (_switching) {
      _activation.repeat(reverse: true);
    } else {
      _activation.forward(from: 0);
    }
  }

  void _setHover(bool hovered) {
    if (_hovered == hovered) return;
    setState(() => _hovered = hovered);
    _updateEmphasis();
  }

  void _setFocus(bool focused) {
    if (_focused == focused) return;
    setState(() => _focused = focused);
    _updateEmphasis();
  }

  void _setPressed(bool pressed) {
    _pressed = pressed;
    _updateEmphasis();
  }

  Future<void> _activate() async {
    if (!_canActivate) return;
    final activate = widget.onActivate!;
    setState(() {
      _switching = true;
      _confirming = false;
      _pressed = false;
    });
    _updateEmphasis();
    _updateActivation();
    var succeeded = false;
    try {
      succeeded = await activate();
    } finally {
      if (mounted) {
        setState(() {
          _switching = false;
          _confirming = succeeded && !_reduceMotion;
        });
        _updateEmphasis();
        _updateActivation();
      }
    }
  }

  @override
  void dispose() {
    _emphasis.dispose();
    _activation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = _switching
        ? 'switching...'
        : widget.selected
        ? 'active'
        : _canActivate && _hovered
        ? 'click to activate'
        : _canActivate && _focused
        ? 'Enter to activate'
        : null;

    return Stack(
      children: [
        Container(
          // Reserve the same border inset in every interaction state.
          padding: const EdgeInsets.all(0.9),
          decoration: BoxDecoration(
            color: widget.surfaceColor,
            borderRadius: BorderRadius.circular(9),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8.2),
            child: Stack(
              children: [
                if (widget.usageBackground != null)
                  Positioned.fill(child: widget.usageBackground!),
                Material(
                  color: Colors.transparent,
                  child: Semantics(
                    button: true,
                    selected: widget.selected,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(8.2),
                      onTap: _canActivate ? _activate : null,
                      onTapDown: (_) => _setPressed(true),
                      onTapUp: (_) => _setPressed(false),
                      onTapCancel: () => _setPressed(false),
                      onHover: _setHover,
                      onFocusChange: _setFocus,
                      canRequestFocus: _canActivate,
                      mouseCursor: _switching
                          ? SystemMouseCursors.progress
                          : _canActivate
                          ? SystemMouseCursors.click
                          : SystemMouseCursors.basic,
                      splashFactory: NoSplash.splashFactory,
                      overlayColor: const WidgetStatePropertyAll(
                        Colors.transparent,
                      ),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(7, 5, 4, 6),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 3,
                                      vertical: 2,
                                    ),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          widget.name,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: theme.textTheme.bodySmall
                                              ?.copyWith(
                                                fontWeight: widget.selected
                                                    ? FontWeight.w700
                                                    : FontWeight.w600,
                                              ),
                                        ),
                                        Semantics(
                                          liveRegion: _switching,
                                          child: Text(
                                            'Slot ${widget.slot}${hint == null ? '' : ' \u00b7 $hint'}',
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: theme.textTheme.labelSmall
                                                ?.copyWith(
                                                  color:
                                                      widget.selected ||
                                                          _switching ||
                                                          (_canActivate &&
                                                              (_hovered ||
                                                                  _focused))
                                                      ? widget.accentColor
                                                      : theme
                                                            .colorScheme
                                                            .onSurfaceVariant,
                                                ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 60, height: 30),
                              ],
                            ),
                            widget.usage,
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned(top: 5, right: 4, child: widget.actions),
              ],
            ),
          ),
        ),
        Positioned.fill(
          child: IgnorePointer(
            child: RepaintBoundary(
              child: CustomPaint(
                painter: _AccountEdgePainter(
                  motion: _motion,
                  emphasis: _emphasis,
                  activation: _activation,
                  selected: widget.selected,
                  switching: _switching,
                  confirming: _confirming && !_reduceMotion,
                  accent: widget.accentColor,
                  outline: widget.outlineColor,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _AccountEdgePainter extends CustomPainter {
  _AccountEdgePainter({
    required Listenable motion,
    required this.emphasis,
    required this.activation,
    required this.selected,
    required this.switching,
    required this.confirming,
    required this.accent,
    required this.outline,
  }) : super(repaint: motion);

  final Animation<double> emphasis;
  final Animation<double> activation;
  final bool selected;
  final bool switching;
  final bool confirming;
  final Color accent;
  final Color outline;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final edge = RRect.fromRectAndRadius(
      (Offset.zero & size).deflate(0.7),
      const Radius.circular(8.3),
    );
    final pulse = switching ? 0.45 + 0.2 * activation.value : 0.0;
    final strength = math.max(emphasis.value, pulse);
    final base = selected
        ? accent.withValues(alpha: 0.44)
        : outline.withValues(alpha: 0.28);
    final color = Color.lerp(base, accent.withValues(alpha: 0.95), strength)!;
    canvas.drawRRect(
      edge.deflate(1.5),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = accent.withValues(alpha: 0.07 * strength),
    );
    canvas.drawRRect(
      edge,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = (selected ? 0.9 : 0.65) + 0.55 * strength
        ..color = color,
    );
    if (confirming && activation.value > 0 && activation.value < 1) {
      final path = Path()..addRRect(edge);
      final metric = path.computeMetrics().first;
      final t = activation.value;
      final start = (t * 1.2 - 0.2).clamp(0.0, 1.0) * metric.length;
      final end = (t * 1.2).clamp(0.0, 1.0) * metric.length;
      canvas.drawPath(
        metric.extractPath(start, end),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeWidth = 1.6
          ..color = accent.withValues(alpha: math.sin(math.pi * t) * 0.85),
      );
    }
  }

  @override
  bool shouldRepaint(_AccountEdgePainter oldDelegate) =>
      selected != oldDelegate.selected ||
      switching != oldDelegate.switching ||
      confirming != oldDelegate.confirming ||
      accent != oldDelegate.accent ||
      outline != oldDelegate.outline ||
      emphasis != oldDelegate.emphasis ||
      activation != oldDelegate.activation;
}
