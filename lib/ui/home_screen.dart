import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../app/app_state.dart';
import '../app/models.dart';

enum _DeleteGroupMode { groupOnly, groupAndCards }

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  Future<void> _showError(BuildContext context, Object error) async {
    if (!context.mounted) {
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(error.toString())));
  }

  void _showRenameHint(BuildContext context) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(
          duration: Duration(milliseconds: 1200),
          content: Text('Double-click the name to rename it.'),
        ),
      );
  }

  Future<void> _pickMarkdownFile(BuildContext context, AppState state) async {
    try {
      final result = await FilePicker.platform.pickFiles(
        dialogTitle: 'Select codex sessions.md',
        type: FileType.custom,
        allowedExtensions: const <String>['md'],
      );
      final path = result?.files.single.path;
      if (path == null || path.trim().isEmpty) {
        return;
      }
      await state.loadConfig(markdownPath: path);
    } catch (error) {
      if (!context.mounted) {
        return;
      }
      await _showError(context, error);
    }
  }

  Future<void> _reload(BuildContext context, AppState state) async {
    try {
      await state.loadConfig();
    } catch (error) {
      if (!context.mounted) {
        return;
      }
      await _showError(context, error);
    }
  }

  Future<void> _save(BuildContext context, AppState state) async {
    try {
      await state.saveConfig();
      if (!context.mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Config saved.')));
    } catch (error) {
      if (!context.mounted) {
        return;
      }
      await _showError(context, error);
    }
  }

  Future<void> _copyCommand(
    BuildContext context,
    String command,
    String label,
  ) async {
    await Clipboard.setData(ClipboardData(text: command));
    if (!context.mounted) {
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('$label command copied.')));
  }

  Future<void> _renameItem(
    BuildContext context,
    AppState state,
    ConfigItem item,
    int index,
  ) async {
    if (item.isGroup) {
      final updated = await _showGroupDialog(
        context,
        initialName: item.name,
        initialColorHex: item.colorHex,
        title: 'Edit Group',
        confirmLabel: 'Save',
      );
      if (updated == null) {
        return;
      }
      state.updateGroup(index, name: updated.$1, colorHex: updated.$2);
      return;
    }

    final controller = TextEditingController(text: item.name);
    final nextTitle = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Rename Session'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Session name',
            hintText: 'Type a new name',
          ),
          onSubmitted: (value) => Navigator.of(dialogContext).pop(value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();

    if (nextTitle == null) {
      return;
    }
    state.renameItem(index, nextTitle);
  }

  Future<void> _addSession(BuildContext context, AppState state) async {
    final commandController = TextEditingController();
    final nameController = TextEditingController();

    try {
      final accepted = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Add Session'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: commandController,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: 'Session id or codex command',
                    hintText: 'codex resume <id>',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: nameController,
                  decoration: const InputDecoration(
                    labelText: 'Name',
                    hintText: 'Optional display name',
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Add'),
            ),
          ],
        ),
      );

      if (accepted != true) {
        return;
      }

      state.addSession(
        sessionInput: commandController.text,
        title: nameController.text,
      );
    } catch (error) {
      if (!context.mounted) {
        return;
      }
      await _showError(context, error);
    } finally {
      commandController.dispose();
      nameController.dispose();
    }
  }

  Future<void> _addGroup(BuildContext context, AppState state) async {
    final created = await _showGroupDialog(
      context,
      initialName: '',
      initialColorHex: AppState.groupPalette.first,
      title: 'Add Group',
      confirmLabel: 'Add',
    );
    if (created == null) {
      return;
    }
    state.addGroup(name: created.$1, colorHex: created.$2);
  }

  Future<void> _deleteGroup(
    BuildContext context,
    AppState state,
    ConfigItem item,
    int index,
  ) async {
    final choice = await showDialog<_DeleteGroupMode>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete Group'),
        content: Text(
          'Delete "${item.displayName}" only, or delete the group and all cards inside it?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          OutlinedButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(_DeleteGroupMode.groupOnly),
            child: const Text('Delete Group Only'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(_DeleteGroupMode.groupAndCards),
            child: const Text('Delete Group + Cards'),
          ),
        ],
      ),
    );

    if (choice == null) {
      return;
    }

    state.deleteGroup(
      index,
      deleteMembers: choice == _DeleteGroupMode.groupAndCards,
    );
  }

  Future<(String, String)?> _showGroupDialog(
    BuildContext context, {
    required String initialName,
    required String initialColorHex,
    required String title,
    required String confirmLabel,
  }) async {
    final controller = TextEditingController(text: initialName);
    var selectedColor = initialColorHex.toUpperCase();

    final result = await showDialog<(String, String)>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setState) => AlertDialog(
            title: Text(title),
            content: SizedBox(
              width: 420,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: controller,
                    autofocus: true,
                    decoration: const InputDecoration(
                      labelText: 'Group name',
                      hintText: 'Group',
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text('Color'),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: AppState.groupPalette
                        .map((colorHex) {
                          final selected = colorHex == selectedColor;
                          final color = _colorFromHex(colorHex);
                          return InkWell(
                            onTap: () =>
                                setState(() => selectedColor = colorHex),
                            borderRadius: BorderRadius.circular(999),
                            child: Container(
                              width: 28,
                              height: 28,
                              decoration: BoxDecoration(
                                color: color,
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: selected
                                      ? Theme.of(context).colorScheme.onSurface
                                      : Theme.of(
                                          context,
                                        ).colorScheme.outlineVariant,
                                  width: selected ? 2 : 0.8,
                                ),
                              ),
                            ),
                          );
                        })
                        .toList(growable: false),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(
                  dialogContext,
                ).pop((controller.text, selectedColor)),
                child: Text(confirmLabel),
              ),
            ],
          ),
        );
      },
    );

    controller.dispose();
    return result;
  }

  Future<void> _showSettingsDialog(BuildContext context, AppState state) async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setState) => AlertDialog(
            title: const Text('Settings'),
            content: SizedBox(
              width: 420,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Markdown file',
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.2,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: Theme.of(context).colorScheme.outlineVariant,
                        width: 0.7,
                      ),
                    ),
                    child: SelectableText(
                      state.sessionsMarkdownPath.trim().isEmpty
                          ? 'No markdown file selected.'
                          : state.sessionsMarkdownPath,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      OutlinedButton.icon(
                        onPressed: () async {
                          await _pickMarkdownFile(context, state);
                          setState(() {});
                        },
                        icon: const Icon(Icons.description_outlined, size: 18),
                        label: const Text('Pick Markdown File'),
                      ),
                      OutlinedButton.icon(
                        onPressed: state.busy
                            ? null
                            : () => _reload(context, state),
                        icon: const Icon(Icons.refresh_rounded, size: 18),
                        label: const Text('Reload'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Autosave',
                          style: Theme.of(context).textTheme.labelLarge
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                      ),
                      Switch(
                        value: state.autosaveEnabled,
                        onChanged: state.busy
                            ? null
                            : (value) {
                                state.setAutosaveEnabled(value);
                                setState(() {});
                              },
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Theme mode',
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.2,
                    ),
                  ),
                  const SizedBox(height: 10),
                  SegmentedButton<ThemeAppearance>(
                    showSelectedIcon: false,
                    segments: const <ButtonSegment<ThemeAppearance>>[
                      ButtonSegment<ThemeAppearance>(
                        value: ThemeAppearance.light,
                        label: Text('Light'),
                      ),
                      ButtonSegment<ThemeAppearance>(
                        value: ThemeAppearance.dim,
                        label: Text('Dusk'),
                      ),
                      ButtonSegment<ThemeAppearance>(
                        value: ThemeAppearance.dark,
                        label: Text('Dark'),
                      ),
                    ],
                    selected: <ThemeAppearance>{state.themeAppearance},
                    onSelectionChanged: (selection) {
                      final appearance = selection.first;
                      state.setThemeAppearance(appearance);
                      setState(() {});
                    },
                  ),
                  const SizedBox(height: 20),
                  Text(
                    'Theme color',
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.2,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: AppState.themeSeedColors
                        .map((value) {
                          final selected = value == state.themeSeedColorValue;
                          final color = Color(value);
                          return Tooltip(
                            message:
                                '#${value.toRadixString(16).substring(2).toUpperCase()}',
                            child: InkWell(
                              onTap: () {
                                state.setThemeSeedColor(value);
                                setState(() {});
                              },
                              borderRadius: BorderRadius.circular(999),
                              child: Container(
                                width: 32,
                                height: 32,
                                decoration: BoxDecoration(
                                  color: color,
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: selected
                                        ? Theme.of(
                                            context,
                                          ).colorScheme.onSurface
                                        : Theme.of(
                                            context,
                                          ).colorScheme.outlineVariant,
                                    width: selected ? 2.4 : 0.8,
                                  ),
                                ),
                                child: selected
                                    ? Icon(
                                        Icons.check_rounded,
                                        size: 16,
                                        color:
                                            ThemeData.estimateBrightnessForColor(
                                                  color,
                                                ) ==
                                                Brightness.dark
                                            ? Colors.white
                                            : Colors.black,
                                      )
                                    : null,
                              ),
                            ),
                          );
                        })
                        .toList(growable: false),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('Close'),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildCounterChip(
    BuildContext context, {
    required String label,
    required String value,
  }) {
    final scheme = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: scheme.outlineVariant, width: 0.65),
      ),
      child: Text(
        '$label $value',
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
          fontWeight: FontWeight.w700,
          color: scheme.onSurface,
        ),
      ),
    );
  }

  Widget _buildPanelHeader(BuildContext context, AppState state) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: scheme.outlineVariant, width: 0.7),
        ),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            _buildCounterChip(
              context,
              label: 'Sessions',
              value: '${state.sessionCount}',
            ),
            const SizedBox(width: 8),
            _buildCounterChip(
              context,
              label: 'Groups',
              value: '${state.groupCount}',
            ),
            const SizedBox(width: 12),
            Text(
              state.dirty ? 'Unsaved' : 'Saved',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              onPressed: state.busy || !state.dirty
                  ? null
                  : () => _save(context, state),
              icon: const Icon(Icons.save_outlined, size: 18),
              label: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatus(BuildContext context, AppState state) {
    final scheme = Theme.of(context).colorScheme;
    if ((state.status == null || state.status!.trim().isEmpty) && !state.busy) {
      return const SizedBox.shrink();
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (state.status != null && state.status!.trim().isNotEmpty)
            Text(
              state.status!,
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          if (state.busy) ...[
            if (state.status != null && state.status!.trim().isNotEmpty)
              const SizedBox(height: 8),
            const LinearProgressIndicator(minHeight: 2),
          ],
        ],
      ),
    );
  }

  Widget _buildPanel(BuildContext context, AppState state) {
    final scheme = Theme.of(context).colorScheme;

    return Expanded(
      child: Container(
        margin: const EdgeInsets.fromLTRB(12, 12, 12, 12),
        decoration: BoxDecoration(
          border: Border.all(color: scheme.outlineVariant, width: 0.7),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: CustomScrollView(
                slivers: [
                  SliverToBoxAdapter(child: _buildPanelHeader(context, state)),
                  SliverToBoxAdapter(child: _buildStatus(context, state)),
                  if (state.items.isEmpty)
                    const SliverToBoxAdapter(
                      child: Padding(
                        padding: EdgeInsets.fromLTRB(12, 0, 12, 12),
                        child: Text(
                          'No items yet. Add a session entry or a group, then drag rows into place and save.',
                        ),
                      ),
                    )
                  else
                    SliverReorderableList(
                      itemCount: state.items.length,
                      onReorder: state.busy ? (_, _) {} : state.reorderItems,
                      itemBuilder: (context, index) =>
                          _buildItem(context, state, state.items[index], index),
                    ),
                  const SliverToBoxAdapter(child: SizedBox(height: 16)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildWarnings(BuildContext context, AppState state) {
    if (state.lastError == null && state.warnings.isEmpty) {
      return const SizedBox.shrink();
    }

    final scheme = Theme.of(context).colorScheme;
    final messages = <String>[
      if (state.lastError != null) state.lastError!,
      ...state.warnings,
    ];

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 0),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        border: Border.all(color: const Color(0xFFFB4934), width: 0.7),
        borderRadius: BorderRadius.circular(14),
        color: const Color(0xFFFB4934).withValues(alpha: 0.08),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Warnings',
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              fontWeight: FontWeight.w700,
              letterSpacing: 0.2,
            ),
          ),
          const SizedBox(height: 6),
          ...messages.map(
            (message) => Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(message, style: TextStyle(color: scheme.onSurface)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDragHandle(BuildContext context, int index) {
    return ReorderableDragStartListener(
      index: index,
      child: const Padding(
        padding: EdgeInsets.symmetric(horizontal: 2),
        child: Icon(Icons.drag_indicator_rounded, size: 18),
      ),
    );
  }

  Widget _buildNameArea(
    BuildContext context,
    AppState state,
    ConfigItem item,
    int index,
  ) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => _showRenameHint(context),
        onDoubleTap: () => _renameItem(context, state, item, index),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 1),
          child: Text(
            item.displayName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w500,
              letterSpacing: 0.1,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildGroupCard(
    BuildContext context,
    AppState state,
    ConfigItem item,
    int index,
  ) {
    final color = _colorFromHex(item.colorHex);
    final scheme = Theme.of(context).colorScheme;
    final hasMembers = state.groupHasMembers(index);
    final hasTail = state.groupEndIndexForGroup(index) != null;
    final connectBottom = hasMembers || hasTail;

    return Container(
      key: ValueKey('group-${item.id}'),
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 0),
      child: Row(
        children: [
          Container(
            width: 10,
            height: 36,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.only(
                topLeft: const Radius.circular(11),
                bottomLeft: Radius.circular(connectBottom ? 0 : 11),
              ),
            ),
          ),
          Expanded(
            child: Container(
              height: 36,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.only(
                  topRight: const Radius.circular(11),
                  bottomRight: Radius.circular(connectBottom ? 0 : 11),
                ),
                border: Border.all(color: scheme.outlineVariant, width: 0.55),
                color: color.withValues(alpha: 0.12),
              ),
              child: Row(
                children: [
                  const SizedBox(width: 8),
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: _buildNameArea(context, state, item, index),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Edit group',
                    onPressed: () => _renameItem(context, state, item, index),
                    icon: const Icon(Icons.palette_outlined, size: 17),
                  ),
                  IconButton(
                    tooltip: 'Delete group',
                    onPressed: () => _deleteGroup(context, state, item, index),
                    icon: const Icon(Icons.delete_outline_rounded, size: 17),
                  ),
                  _buildDragHandle(context, index),
                  const SizedBox(width: 4),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSessionCard(
    BuildContext context,
    AppState state,
    ConfigItem item,
    int index,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final group = state.groupForItem(index);
    final isGrouped = item.isSession && group != null;
    final groupColor = isGrouped ? _colorFromHex(group.colorHex) : null;
    final resolvedGroupColor = groupColor ?? scheme.outlineVariant;
    final isFirstInGroup = state.isFirstSessionInGroup(index);
    final isLastInGroup = state.isLastSessionInGroup(index);
    final bottomSpacing = isGrouped ? 0.0 : 6.0;
    final borderRadius = isGrouped
        ? BorderRadius.vertical(
            top: Radius.circular(isFirstInGroup ? 0 : 0),
            bottom: Radius.circular(isLastInGroup ? 0 : 0),
          )
        : BorderRadius.circular(11);

    return Container(
      key: ValueKey('session-${item.commandId}'),
      margin: EdgeInsets.fromLTRB(12, 0, 12, bottomSpacing),
      child: Row(
        children: [
          if (isGrouped)
            Container(width: 10, height: 38, color: resolvedGroupColor),
          Expanded(
            child: Container(
              height: 38,
              decoration: BoxDecoration(
                border: Border.all(
                  color: isGrouped
                      ? resolvedGroupColor.withValues(alpha: 0.35)
                      : scheme.outlineVariant,
                  width: 0.55,
                ),
                borderRadius: borderRadius,
                color: isGrouped
                    ? resolvedGroupColor.withValues(alpha: 0.10)
                    : null,
              ),
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: borderRadius,
                  onTap: () {
                    _copyCommand(context, item.resumeCommand, 'Resume');
                  },
                  child: Row(
                    children: [
                      SizedBox(width: isGrouped ? 16 : 8),
                      Container(
                        width: 72,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          color: isGrouped
                              ? resolvedGroupColor.withValues(alpha: 0.18)
                              : scheme.primaryContainer.withValues(alpha: 0.45),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          item.shortId,
                          textAlign: TextAlign.center,
                          maxLines: 1,
                          softWrap: false,
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 12,
                            letterSpacing: 0.2,
                            color: scheme.onSurface,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: _buildNameArea(context, state, item, index),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Copy resume command',
                        onPressed: () =>
                            _copyCommand(context, item.resumeCommand, 'Resume'),
                        icon: const Icon(Icons.content_copy_rounded, size: 17),
                      ),
                      IconButton(
                        tooltip: 'Copy fork command',
                        onPressed: () =>
                            _copyCommand(context, item.forkCommand, 'Fork'),
                        icon: const Icon(Icons.call_split_rounded, size: 17),
                      ),
                      _buildDragHandle(context, index),
                      const SizedBox(width: 4),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGroupEndCard(
    BuildContext context,
    AppState state,
    ConfigItem item,
    int index,
  ) {
    final group = state.groupForItem(index);
    if (group == null) {
      return Container(
        key: ValueKey('group-end-${item.id}'),
        margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
        height: 6,
      );
    }

    final color = _colorFromHex(group.colorHex);
    return Container(
      key: ValueKey('group-end-${item.id}'),
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: color,
              borderRadius: const BorderRadius.only(
                bottomLeft: Radius.circular(11),
              ),
            ),
          ),
          Expanded(
            child: Container(
              height: 10,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.10),
                border: Border.all(
                  color: color.withValues(alpha: 0.35),
                  width: 0.55,
                ),
                borderRadius: const BorderRadius.only(
                  bottomRight: Radius.circular(11),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildItem(
    BuildContext context,
    AppState state,
    ConfigItem item,
    int index,
  ) {
    if (item.isGroup) {
      return _buildGroupCard(context, state, item, index);
    }
    if (item.isGroupEnd) {
      return _buildGroupEndCard(context, state, item, index);
    }
    return _buildSessionCard(context, state, item, index);
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();

    return Scaffold(
      appBar: AppBar(
        centerTitle: false,
        title: const Text('Context'),
        actions: [
          TextButton.icon(
            onPressed: state.busy ? null : () => _addSession(context, state),
            icon: const Icon(Icons.add_link_rounded, size: 18),
            label: const Text('Add Entry'),
          ),
          TextButton.icon(
            onPressed: state.busy ? null : () => _addGroup(context, state),
            icon: const Icon(Icons.create_new_folder_outlined, size: 18),
            label: const Text('Add Group'),
          ),
          IconButton(
            tooltip: 'Settings',
            onPressed: () => _showSettingsDialog(context, state),
            icon: const Icon(Icons.settings_outlined),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [_buildWarnings(context, state), _buildPanel(context, state)],
      ),
    );
  }

  Color _colorFromHex(String hex) {
    final normalized = hex.replaceAll('#', '').trim();
    final value = int.tryParse(normalized, radix: 16) ?? 0x83A598;
    return Color(0xFF000000 | value);
  }
}
