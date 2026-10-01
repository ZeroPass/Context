import 'dart:async';

import 'package:flutter/material.dart';

class PassiveTooltip extends StatefulWidget {
  const PassiveTooltip({
    super.key,
    required this.message,
    required this.child,
    this.preferBelow = false,
  });

  final String message;
  final Widget child;
  final bool preferBelow;

  @override
  State<PassiveTooltip> createState() => _PassiveTooltipState();
}

class _PassiveTooltipState extends State<PassiveTooltip> {
  final _portal = OverlayPortalController();
  final _anchor = GlobalKey();
  Timer? _showTimer;

  void _handleEnter() {
    _showTimer?.cancel();
    _showTimer = Timer(const Duration(milliseconds: 120), () {
      if (!mounted) {
        return;
      }
      if (widget.message.trim().isNotEmpty) _portal.show();
    });
  }

  void _handleExit() {
    _showTimer?.cancel();
    _portal.hide();
  }

  @override
  void dispose() {
    _showTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return OverlayPortal(
      controller: _portal,
      overlayLocation: OverlayChildLocation.rootOverlay,
      overlayChildBuilder: (context) {
        final target = _anchor.currentContext!.findRenderObject()! as RenderBox;
        final overlay =
            Overlay.of(context, rootOverlay: true).context.findRenderObject()!
                as RenderBox;
        final anchor =
            target.localToGlobal(Offset.zero, ancestor: overlay) & target.size;
        // Root overlay avoids clipping by pane scroll views or the app header.
        return Positioned.fill(
          child: IgnorePointer(
            child: CustomSingleChildLayout(
              delegate: _TooltipPosition(anchor, widget.preferBelow),
              child: Material(
                color: Colors.transparent,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHigh.withValues(alpha: 0.88),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: scheme.outlineVariant.withValues(alpha: 0.38),
                      width: 0.7,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.08),
                        blurRadius: 6,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Text(
                    widget.message,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurface.withValues(alpha: 0.86),
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
      child: MouseRegion(
        key: _anchor,
        onEnter: (_) => _handleEnter(),
        onExit: (_) => _handleExit(),
        child: widget.child,
      ),
    );
  }
}

class _TooltipPosition extends SingleChildLayoutDelegate {
  _TooltipPosition(this.anchor, this.preferBelow);
  final Rect anchor;
  final bool preferBelow;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints(
        maxWidth: (constraints.maxWidth - 16).clamp(0, 240),
        maxHeight: (constraints.maxHeight - 16).clamp(0, double.infinity),
      );

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    const gap = 8.0;
    final above = anchor.top - childSize.height - gap;
    final below = anchor.bottom + gap;
    final fitsBelow = below + childSize.height <= size.height - gap;
    final y = preferBelow
        ? fitsBelow || above < gap
              ? below
              : above
        : above >= gap || !fitsBelow
        ? above
        : below;
    return Offset(
      (anchor.center.dx - childSize.width / 2).clamp(
        gap,
        (size.width - childSize.width - gap).clamp(gap, double.infinity),
      ),
      y.clamp(
        gap,
        (size.height - childSize.height - gap).clamp(gap, double.infinity),
      ),
    );
  }

  @override
  bool shouldRelayout(_TooltipPosition oldDelegate) =>
      anchor != oldDelegate.anchor || preferBelow != oldDelegate.preferBelow;
}
