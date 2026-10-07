import 'package:flutter/material.dart';

import 'passive_tooltip.dart';
import 'preview_context_menu.dart';

class FileLocationButton extends StatelessWidget {
  const FileLocationButton({
    super.key,
    required this.onReveal,
    required this.onOpenExternal,
  });

  final VoidCallback onReveal;
  final VoidCallback onOpenExternal;

  Future<void> _menu(BuildContext context, Offset position) async {
    final overlay =
        Overlay.of(context, rootOverlay: true).context.findRenderObject()!
            as RenderBox;
    final local = overlay.globalToLocal(position);
    final action = await showMenu<bool>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(local.dx, local.dy, 0, 0),
        Offset.zero & overlay.size,
      ),
      items: const [
        PopupMenuItem(value: true, child: Text('Open in default app')),
      ],
    );
    if (action == true && context.mounted) onOpenExternal();
  }

  @override
  Widget build(BuildContext context) => Listener(
    onPointerDown: claimPreviewSecondary,
    child: GestureDetector(
      onSecondaryTapUp: (event) => _menu(context, event.globalPosition),
      child: PassiveTooltip(
        message: 'Open file location (right-click for more)',
        preferBelow: true,
        child: IconButton(
          onPressed: onReveal,
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.folder_open_rounded, size: 17),
        ),
      ),
    ),
  );
}
