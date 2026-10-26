import 'dart:io';

import 'package:flutter/material.dart';

import '../../app/file_references.dart';
import '../../app/whiteboard_input.dart';
import '../../app/workspace_paths.dart';
import 'file_location_button.dart';
import 'passive_tooltip.dart';

class WhiteboardInputEditor extends StatelessWidget {
  const WhiteboardInputEditor({
    super.key,
    required this.draft,
    required this.onChanged,
    required this.onAdd,
    required this.onCopy,
    required this.onDelete,
    required this.onStore,
    required this.onPreview,
    required this.onReveal,
    required this.onExternal,
    this.busy = false,
    this.status = 'Saved',
  });
  final WhiteboardInputDraft draft;
  final ValueChanged<WhiteboardInputDraft Function(WhiteboardInputDraft)>
  onChanged;
  final VoidCallback onAdd, onCopy, onDelete;
  final ValueChanged<InputAttachment> onStore, onPreview, onReveal, onExternal;
  final bool busy;
  final String status;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context), scheme = theme.colorScheme;
    Widget action(String key, String tip, IconData icon, VoidCallback? onTap) =>
        PassiveTooltip(
          message: tip,
          child: IconButton(
            key: ValueKey(key),
            onPressed: busy ? null : onTap,
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints.tightFor(width: 30, height: 30),
            padding: EdgeInsets.zero,
            icon: Icon(icon, size: 16),
          ),
        );
    return Padding(
      key: ValueKey('whiteboard-input-${draft.folder}'),
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text('Input', style: theme.textTheme.bodyMedium),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  status,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              action(
                'input-add-files',
                'Add files (keep their paths)',
                Icons.add_rounded,
                onAdd,
              ),
              action(
                'input-copy-prompt',
                'Copy prompt for your agent',
                Icons.copy_rounded,
                draft.hasContent ? onCopy : null,
              ),
              action(
                'input-delete',
                'Delete input tab and its stored copies; keep linked originals',
                Icons.close_rounded,
                onDelete,
              ),
            ],
          ),
          const SizedBox(height: 6),
          TextFormField(
            key: ValueKey('input-instructions-${draft.folder}'),
            initialValue: draft.instructions,
            enabled: !busy,
            minLines: 1,
            maxLines: 5,
            style: theme.textTheme.bodySmall,
            decoration: const InputDecoration(
              hintText: 'Instructions (optional)',
              isDense: true,
              contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 9),
            ),
            onChanged: (value) =>
                onChanged((current) => current.copyWith(instructions: value)),
          ),
          if (draft.files.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 26),
              child: Text(
                'Drop files here, paste, or use +.\nDropped files stay at their current paths.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          for (final file in draft.files)
            Container(
              key: ValueKey('input-file-${file.id}'),
              margin: const EdgeInsets.only(top: 9),
              padding: const EdgeInsets.all(9),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: scheme.outlineVariant.withValues(alpha: 0.45),
                  width: 0.7,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      InkWell(
                        onTap: isWhiteboardPreview(file.path) && !busy
                            ? () => onPreview(file)
                            : null,
                        borderRadius: BorderRadius.circular(5),
                        child: SizedBox(
                          width: 58,
                          height: 42,
                          child: isPreviewImage(file.path)
                              ? ClipRRect(
                                  borderRadius: BorderRadius.circular(5),
                                  child: Image.file(
                                    File(file.path),
                                    fit: BoxFit.contain,
                                    cacheWidth: 160,
                                    errorBuilder: (_, _, _) => const Icon(
                                      Icons.broken_image_outlined,
                                      size: 21,
                                    ),
                                  ),
                                )
                              : Icon(
                                  isPreviewVideo(file.path)
                                      ? Icons.video_file_outlined
                                      : Icons.insert_drive_file_outlined,
                                  size: 22,
                                ),
                        ),
                      ),
                      const SizedBox(width: 9),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              contextPaths(file.path).basename(file.path),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall,
                            ),
                            const SizedBox(height: 2),
                            SelectableText(
                              file.path,
                              maxLines: 2,
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                      action(
                        'input-preview-${file.id}',
                        'Preview in Context',
                        Icons.visibility_outlined,
                        isWhiteboardPreview(file.path)
                            ? () => onPreview(file)
                            : null,
                      ),
                      SizedBox(
                        width: 30,
                        child: FileLocationButton(
                          onReveal: () => onReveal(file),
                          onOpenExternal: () => onExternal(file),
                        ),
                      ),
                      action(
                        'input-store-${file.id}',
                        file.owned
                            ? 'Stored in Context; removed when this tab expires'
                            : 'Copy this file into Context; the original stays untouched',
                        file.owned
                            ? Icons.check_rounded
                            : Icons.file_copy_outlined,
                        file.owned ? null : () => onStore(file),
                      ),
                      action(
                        'input-remove-${file.id}',
                        'Remove attachment',
                        Icons.close_rounded,
                        () => onChanged(
                          (current) => current.copyWith(
                            files: current.files
                                .where((v) => v.id != file.id)
                                .toList(),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  TextFormField(
                    key: ValueKey('input-note-${file.id}'),
                    initialValue: file.note,
                    enabled: !busy,
                    minLines: 1,
                    maxLines: 5,
                    style: theme.textTheme.bodySmall,
                    decoration: const InputDecoration(
                      hintText: 'Note for this file',
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 9,
                        vertical: 8,
                      ),
                    ),
                    onChanged: (value) => onChanged(
                      (current) => current.copyWith(
                        files: [
                          for (final f in current.files)
                            f.id == file.id ? f.withNote(value) : f,
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
