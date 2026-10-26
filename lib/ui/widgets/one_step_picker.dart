import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

class OneStepPickerItem extends StatelessWidget {
  const OneStepPickerItem({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final picker = context.findAncestorStateOfType<_OneStepPickerState>();
    return Listener(
      onPointerSignal: picker?._handlePointerSignal,
      child: child,
    );
  }
}

/// Keep desktop wheel notches to one item, including when pointing at text.
class OneStepPicker extends StatefulWidget {
  const OneStepPicker({
    super.key,
    required this.controller,
    required this.itemCount,
    required this.child,
  }) : assert(itemCount > 0);
  final FixedExtentScrollController controller;
  final int itemCount;
  final Widget child;

  @override
  State<OneStepPicker> createState() => _OneStepPickerState();
}

class _OneStepPickerState extends State<OneStepPicker> {
  int? _pendingWheelTarget;
  PointerSignalEvent? _registeredWheelEvent;

  void _handlePointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent ||
        event.scrollDelta.dy == 0 ||
        !widget.controller.hasClients) {
      return;
    }
    if (identical(_registeredWheelEvent, event)) return;
    final direction = event.scrollDelta.dy.sign.toInt();
    final target = (widget.controller.selectedItem + direction)
        .clamp(0, widget.itemCount - 1)
        .toInt();
    _pendingWheelTarget = target;
    _registeredWheelEvent = event;
    GestureBinding.instance.pointerSignalResolver.register(event, (
      resolvedEvent,
    ) {
      _registeredWheelEvent = null;
      _pendingWheelTarget = null;
      (resolvedEvent as PointerScrollEvent).respond(
        allowPlatformDefault: false,
      );
      if (mounted && widget.controller.hasClients) {
        widget.controller.jumpToItem(target);
      }
    });
  }

  bool _handleScrollNotification(ScrollNotification notification) {
    final target = _pendingWheelTarget;
    if (target == null || notification is! ScrollUpdateNotification) {
      return false;
    }
    _registeredWheelEvent = null;
    _pendingWheelTarget = null;
    if (widget.controller.hasClients) widget.controller.jumpToItem(target);
    return false;
  }

  @override
  Widget build(BuildContext context) =>
      NotificationListener<ScrollNotification>(
        onNotification: _handleScrollNotification,
        child: Listener(
          onPointerSignal: _handlePointerSignal,
          child: widget.child,
        ),
      );
}
