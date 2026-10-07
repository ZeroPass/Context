import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../app/preview_actions.dart';

enum PreviewMenuAction { copy, snapshot, saveAs }

final _claimed = Expando<bool>();

bool claimPreviewSecondary(PointerDownEvent event) {
  final original = event.original ?? event;
  if (event.buttons != kSecondaryMouseButton || _claimed[original] == true) {
    return false;
  }
  _claimed[original] = true;
  return true;
}

class PreviewContextMenu extends StatelessWidget {
  const PreviewContextMenu({
    super.key,
    required this.path,
    required this.child,
    this.markdown,
    this.snapshot,
    this.actions,
  });

  final String path;
  final String? markdown;
  final Widget child;
  final Future<Uint8List> Function()? snapshot;
  final PreviewActions? actions;

  Future<void> _menu(BuildContext context, Offset position) async {
    final overlay =
        Overlay.of(context, rootOverlay: true).context.findRenderObject()!
            as RenderBox;
    final local = overlay.globalToLocal(position);
    final selected = await showMenu<PreviewMenuAction>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(local.dx, local.dy, 0, 0),
        Offset.zero & overlay.size,
      ),
      items: [
        const PopupMenuItem(value: PreviewMenuAction.copy, child: Text('Copy')),
        if (snapshot != null)
          const PopupMenuItem(
            value: PreviewMenuAction.snapshot,
            child: Text('Copy snapshot'),
          ),
        const PopupMenuItem(
          value: PreviewMenuAction.saveAs,
          child: Text('Save as...'),
        ),
      ],
    );
    if (selected == null || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final service = actions ?? previewActions;
    try {
      final success = await switch (selected) {
        PreviewMenuAction.copy => service.copy(path, markdown: markdown),
        PreviewMenuAction.snapshot => service.copyImage(snapshot!),
        PreviewMenuAction.saveAs => service.saveAs(path),
      };
      if (!success || !messenger.mounted) return;
      messenger
        ..removeCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(switch (selected) {
              PreviewMenuAction.copy => 'Copied.',
              PreviewMenuAction.snapshot => 'Snapshot copied.',
              PreviewMenuAction.saveAs => 'File saved.',
            }),
          ),
        );
    } catch (error) {
      if (messenger.mounted) {
        messenger.showSnackBar(SnackBar(content: Text('$error')));
      }
    }
  }

  @override
  Widget build(BuildContext context) => Listener(
    behavior: HitTestBehavior.translucent,
    onPointerDown: (event) {
      if (!claimPreviewSecondary(event)) return;
      // Hit testing visits inner media first: its menu wins over the enclosing
      // Markdown document menu, without swallowing normal selection/zoom input.
      unawaited(_menu(context, event.position));
    },
    child: child,
  );
}
