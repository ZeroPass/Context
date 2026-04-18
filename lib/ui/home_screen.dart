import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../app/app_state.dart';
import '../app/models.dart';

enum _DeleteGroupMode { groupOnly, groupAndCards }

class _InlineRun {
  const _InlineRun.text(this.text)
    : copyText = null,
      openTarget = null;

  const _InlineRun.copy({
    required this.text,
    required this.copyText,
    this.openTarget,
  });

  final String text;
  final String? copyText;
  final String? openTarget;

  bool get isCopyable => copyText != null;

  bool get isOpenable => openTarget != null;
}

class _PassiveTooltip extends StatefulWidget {
  const _PassiveTooltip({
    required this.message,
    required this.child,
  });

  final String message;
  final Widget child;

  @override
  State<_PassiveTooltip> createState() => _PassiveTooltipState();
}

class _PassiveTooltipState extends State<_PassiveTooltip> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final hasMessage = widget.message.trim().isNotEmpty;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          widget.child,
          if (_hovered && hasMessage)
            Positioned(
              top: -34,
              left: -48,
              right: -48,
              child: IgnorePointer(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 240),
                    child: Material(
                      color: Colors.transparent,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: scheme.inverseSurface.withValues(alpha: 0.96),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: scheme.outlineVariant.withValues(alpha: 0.55),
                            width: 0.7,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.14),
                              blurRadius: 8,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: Text(
                          widget.message,
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onInverseSurface,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  Widget _tooltip(String message, Widget child) {
    return _PassiveTooltip(
      message: message,
      child: child,
    );
  }

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

  Future<void> _createExampleMarkdown(
    BuildContext context,
    AppState state,
  ) async {
    try {
      final path = await state.createExampleMarkdownFile();
      if (!context.mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Example file created at $path')));
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
    ).showSnackBar(SnackBar(content: Text('$label copied.')));
  }

  Future<void> _openReference(
    BuildContext context,
    String target,
    String label,
  ) async {
    try {
      await context.read<AppState>().openReference(target);
    } catch (error) {
      if (!context.mounted) {
        return;
      }
      await _showError(context, error);
      return;
    }

    if (!context.mounted) {
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('$label opened.')));
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

  Future<void> _addSession(
    BuildContext context,
    AppState state, {
    String? initialSessionInput,
    String? initialName,
  }) async {
    final commandController = TextEditingController(
      text: initialSessionInput ?? '',
    );
    final nameController = TextEditingController(text: initialName ?? '');

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
                  controller: nameController,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: 'Name',
                    hintText: 'Optional display name',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: commandController,
                  decoration: const InputDecoration(
                    labelText: 'Session id or codex command',
                    hintText: 'codex resume <id>',
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

  Future<void> _saveRecentContext(
    BuildContext context,
    AppState state,
    RecentContext item,
  ) async {
    final prefilledName = _prefilledRecentContextName(state, item);
    await _addSession(
      context,
      state,
      initialSessionInput: item.id,
      initialName: prefilledName,
    );
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

  void _deleteSession(AppState state, int index) {
    state.deleteSession(index);
  }

  String _configuredSessionTitle(
    AppState state,
    String sessionId,
    String fallback,
  ) {
    final normalized = sessionId.trim().toLowerCase();
    for (final item in state.items) {
      if (!item.isSession) {
        continue;
      }
      if (item.commandId.trim().toLowerCase() != normalized) {
        continue;
      }
      final configured = item.displayName.trim();
      if (configured.isNotEmpty) {
        return configured;
      }
      break;
    }

    final trimmedFallback = fallback.trim();
    return trimmedFallback.isEmpty ? sessionId.trim() : trimmedFallback;
  }

  String _prefilledRecentContextName(AppState state, RecentContext item) {
    final parentId = item.forkedFromId?.trim() ?? '';
    if (parentId.isNotEmpty) {
      final parentTitle = _configuredSessionTitle(state, parentId, '');
      final normalizedParent = parentTitle.trim();
      if (normalizedParent.isNotEmpty && normalizedParent != parentId) {
        return '$normalizedParent fork';
      }
    }

    return _configuredSessionTitle(state, item.id, item.displayTitle);
  }

  Widget _buildFastToggle(
    BuildContext context,
    AppState state,
    ConfigItem item,
    int index,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final active = item.fast;

    return _tooltip(
      active ? 'Fast session on' : 'Fast session off',
      Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: () => state.toggleSessionFast(index),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOutCubic,
            width: 42,
            height: 24,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: active
                  ? scheme.primaryContainer.withValues(alpha: 0.96)
                  : scheme.surfaceContainerHighest.withValues(alpha: 0.82),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(
                color: active
                    ? scheme.primary.withValues(alpha: 0.65)
                    : scheme.outlineVariant,
                width: active ? 1.1 : 0.8,
              ),
              boxShadow: active
                  ? [
                      BoxShadow(
                        color: scheme.primary.withValues(alpha: 0.24),
                        blurRadius: 10,
                        spreadRadius: 0.2,
                      ),
                    ]
                  : const [],
            ),
            child: Icon(
              active ? Icons.bolt_rounded : Icons.bolt_outlined,
              size: 15,
              color: active
                  ? scheme.onPrimaryContainer
                  : scheme.onSurfaceVariant.withValues(alpha: 0.75),
            ),
          ),
        ),
      ),
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
    final prefixController = TextEditingController(text: state.answerPathPrefix);
    try {
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
                          prefixController.text = state.answerPathPrefix;
                          prefixController.selection =
                              TextSelection.collapsed(
                                offset: prefixController.text.length,
                              );
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
                      OutlinedButton.icon(
                        onPressed: state.busy
                            ? null
                            : () async {
                                await _createExampleMarkdown(context, state);
                                prefixController.text = state.answerPathPrefix;
                                prefixController.selection =
                                    TextSelection.collapsed(
                                      offset: prefixController.text.length,
                                    );
                                setState(() {});
                              },
                        icon: const Icon(Icons.auto_awesome_outlined, size: 18),
                        label: const Text('Create Example File'),
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
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Expand Last Answer paths',
                          style: Theme.of(context).textTheme.labelLarge
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                      ),
                      Switch(
                        value: state.augmentAnswerPathsEnabled,
                        onChanged: (value) {
                          state.setAugmentAnswerPathsEnabled(value);
                          setState(() {});
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  TextField(
                    controller: prefixController,
                    onChanged: (value) {
                      state.setAnswerPathPrefix(value);
                      setState(() {});
                    },
                    decoration: const InputDecoration(
                      labelText: 'Workspace path prefix',
                      hintText:
                          r'\\wsl.localhost\Ubuntu-24.04\home\user\codex-out',
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Best effort expansion for relative repo paths shown in Last Answer.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
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
                        value: ThemeAppearance.sepia,
                        label: Text('Sepia'),
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
                          return _tooltip(
                            '#${value.toRadixString(16).substring(2).toUpperCase()}',
                            InkWell(
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
    } finally {
      prefixController.dispose();
    }
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

  Widget _buildSearchField(BuildContext context, AppState state) {
    final scheme = Theme.of(context).colorScheme;
    return TextField(
      onChanged: state.setFilterQuery,
      decoration: InputDecoration(
        isDense: true,
        hintText: 'Filter contexts',
        prefixIcon: const Icon(Icons.search_rounded, size: 18),
        filled: true,
        fillColor: scheme.surfaceContainerLowest.withValues(alpha: 0.7),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 10,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: scheme.outlineVariant, width: 0.7),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: scheme.outlineVariant, width: 0.7),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: scheme.primary, width: 0.9),
        ),
      ),
    );
  }

  Widget _buildLoadedLine(BuildContext context, AppState state) {
    final scheme = Theme.of(context).colorScheme;
    final message =
        (state.status ?? '').trim().isNotEmpty
        ? state.status!.trim()
        : state.sessionsMarkdownPath.trim().isEmpty
        ? 'No markdown file selected.'
        : 'Loaded ${state.items.length} item(s).';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          message,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
            fontWeight: FontWeight.w500,
            letterSpacing: 0.1,
          ),
        ),
        if (state.busy) ...[
          const SizedBox(height: 8),
          const LinearProgressIndicator(minHeight: 2),
        ],
      ],
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SingleChildScrollView(
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
                if (state.hasFilter) ...[
                  const SizedBox(width: 8),
                  _buildCounterChip(
                    context,
                    label: 'Shown',
                    value: '${state.filteredSessionIndices.length}',
                  ),
                ],
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
          const SizedBox(height: 10),
          _buildLoadedLine(context, state),
          const SizedBox(height: 10),
          _buildSearchField(context, state),
        ],
      ),
    );
  }

  Widget _buildRecentContexts(BuildContext context, AppState state) {
    if (state.recentContexts.isEmpty) {
      return const SizedBox.shrink();
    }

    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: scheme.outlineVariant, width: 0.7),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Recent',
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 10),
          ...state.recentContexts.map((item) {
            final alreadySaved = state.hasSessionId(item.id);
            final displayTitle = _configuredSessionTitle(
              state,
              item.id,
              item.displayTitle,
            );
            return Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerLowest.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: scheme.outlineVariant,
                  width: 0.6,
                ),
              ),
              child: Row(
                children: [
                  Container(
                    constraints: const BoxConstraints(minWidth: 64),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerHigh.withValues(alpha: 0.75),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      item.shortId,
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      displayTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  FilledButton.tonalIcon(
                    onPressed: alreadySaved || state.busy
                        ? null
                        : () => _saveRecentContext(context, state, item),
                    icon: Icon(
                      alreadySaved
                          ? Icons.check_rounded
                          : Icons.add_link_rounded,
                      size: 16,
                    ),
                    label: Text(alreadySaved ? 'Saved' : 'Save'),
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _buildContextPanel(BuildContext context, AppState state) {
    final scheme = Theme.of(context).colorScheme;
    final filteredSessionIndices = state.filteredSessionIndices;

    return Container(
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
                if (state.hasFilter && filteredSessionIndices.isEmpty)
                  const SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(12, 0, 12, 12),
                      child: Text('No matching contexts.'),
                    ),
                  )
                else if (state.items.isEmpty)
                  const SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(12, 0, 12, 12),
                      child: Text(
                        'No items yet. Add a session entry or a group, then drag rows into place and save.',
                      ),
                    ),
                  )
                else if (state.hasFilter)
                  SliverList(
                    delegate: SliverChildBuilderDelegate((
                      context,
                      filteredIndex,
                    ) {
                      final actualIndex = filteredSessionIndices[filteredIndex];
                      return _buildSessionCard(
                        context,
                        state,
                        state.items[actualIndex],
                        actualIndex,
                        forceUngrouped: true,
                        showDragHandle: false,
                      );
                    }, childCount: filteredSessionIndices.length),
                  )
                else
                  SliverReorderableList(
                    itemCount: state.items.length,
                    onReorder: state.busy ? (_, _) {} : state.reorderItems,
                    itemBuilder: (context, index) =>
                        _buildItem(context, state, state.items[index], index),
                  ),
                if (!state.hasFilter)
                  SliverToBoxAdapter(child: _buildRecentContexts(context, state)),
                const SliverToBoxAdapter(child: SizedBox(height: 16)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildViewTabs(BuildContext context, AppState state) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
      child: TabBar(
        isScrollable: true,
        onTap: (index) {
          if (index == 1) {
            state.refreshLastAnswers(queueIfBusy: true);
          }
        },
        tabs: const [
          Tab(text: 'Contexts'),
          Tab(text: 'Last Answer'),
        ],
      ),
    );
  }

  Widget _buildLastAnswersHeader(BuildContext context, AppState state) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: scheme.outlineVariant, width: 0.7),
        ),
      ),
      child: Row(
        children: [
          _buildCounterChip(
            context,
            label: 'Answers',
            value: '${state.lastAnswers.length}',
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Latest assistant output from recent Codex sessions',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          const SizedBox(width: 8),
          _tooltip(
            'Refresh Last Answer',
            IconButton(
              onPressed: state.lastAnswersBusy
                  ? null
                  : () => state.refreshLastAnswers(queueIfBusy: true),
              icon: const Icon(Icons.refresh_rounded, size: 18),
            ),
          ),
        ],
      ),
    );
  }

  List<_InlineRun> _parseInlineRuns(String text) {
    final pattern = RegExp(
      r'\[([^\]]+)\]\(([^)\n]+)\)|`([^`\n]+)`|(https?://[^\s)<>\]]+)|(\\\\wsl(?:\.localhost|\$)\\[^\s`]+)|((?:/|\.\.?/)[^\s`)<>\]]+)|((?:[A-Za-z0-9_.-]+/){1,}[A-Za-z0-9_.:-]+)',
    );
    final runs = <_InlineRun>[];
    var cursor = 0;

    for (final match in pattern.allMatches(text)) {
      if (match.start > cursor) {
        runs.add(_InlineRun.text(text.substring(cursor, match.start)));
      }

      if (match.group(1) != null && match.group(2) != null) {
        final value = match.group(2)!;
        runs.add(
          _InlineRun.copy(
            text: value,
            copyText: value,
            openTarget: value,
          ),
        );
      } else {
        final copied =
            match.group(3) ??
            match.group(4) ??
            match.group(5) ??
            match.group(6) ??
            match.group(7) ??
            '';
        runs.add(
          _InlineRun.copy(
            text: copied,
            copyText: copied,
            openTarget: copied,
          ),
        );
      }

      cursor = match.end;
    }

    if (cursor < text.length) {
      runs.add(_InlineRun.text(text.substring(cursor)));
    }

    return runs;
  }

  bool _isAbsoluteReference(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      return false;
    }
    return trimmed.startsWith('http://') ||
        trimmed.startsWith('https://') ||
        trimmed.startsWith(r'\\') ||
        trimmed.startsWith('/') ||
        RegExp(r'^[A-Za-z]:[\\/]').hasMatch(trimmed);
  }

  bool _isWebReference(String value) {
    final trimmed = value.trim();
    return trimmed.startsWith('http://') || trimmed.startsWith('https://');
  }

  bool _looksLikeRelativeWorkspacePath(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty || _isAbsoluteReference(trimmed)) {
      return false;
    }

    final normalized = trimmed.replaceAll('\\', '/');
    return normalized.contains('/');
  }

  String _stripPathDecorators(String value) {
    var out = value.trim();
    final hashIndex = out.indexOf('#');
    if (hashIndex != -1) {
      out = out.substring(0, hashIndex);
    }
    final lineSuffix = RegExp(r'^(.*?)(:\d+(?::\d+)?)$').firstMatch(out);
    if (lineSuffix != null) {
      out = lineSuffix.group(1) ?? out;
    }
    return out.trim();
  }

  String _joinPathPrefix(String prefix, String relativePath) {
    final separator = prefix.endsWith('/') || prefix.endsWith('\\')
        ? ''
        : prefix.contains('\\')
        ? '\\'
        : '/';
    final normalizedRelative = relativePath.replaceFirst(
      RegExp(r'^[.][/]'),
      '',
    );
    final cleanedRelative = normalizedRelative.replaceFirst(
      RegExp(r'^[\\/]+'),
      '',
    );
    return '$prefix$separator$cleanedRelative';
  }

  bool _pathExists(String value) {
    if (value.trim().isEmpty) {
      return false;
    }
    try {
      return FileSystemEntity.typeSync(value) != FileSystemEntityType.notFound;
    } catch (_) {
      return false;
    }
  }

  String _augmentReferenceText(AppState state, String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty ||
        !state.augmentAnswerPathsEnabled ||
        state.answerPathPrefix.trim().isEmpty ||
        !_looksLikeRelativeWorkspacePath(trimmed)) {
      return trimmed;
    }

    final prefix = state.answerPathPrefix.trim();
    final candidate = _joinPathPrefix(prefix, trimmed);
    final probe = _joinPathPrefix(prefix, _stripPathDecorators(trimmed));
    if (!_pathExists(probe)) {
      return trimmed;
    }
    return candidate;
  }

  String? _resolveOpenTarget(AppState state, String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      return null;
    }

    final resolved = _augmentReferenceText(state, trimmed).trim();
    if (resolved.isEmpty) {
      return null;
    }

    if (_isWebReference(resolved)) {
      return resolved;
    }

    final sanitized = _stripPathDecorators(resolved);
    if (sanitized.isEmpty || !_isAbsoluteReference(sanitized)) {
      return null;
    }
    return sanitized;
  }

  Widget _buildInlineOpenButton(
    BuildContext context,
    String target, {
    required bool isWeb,
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Padding(
      padding: const EdgeInsets.only(left: 3, right: 1),
      child: _tooltip(
        isWeb ? 'Open link' : 'Open path',
        InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: () => _openReference(
            context,
            target,
            isWeb ? 'Link' : 'Path',
          ),
          child: Container(
            padding: const EdgeInsets.all(1.5),
            decoration: BoxDecoration(
              color: scheme.primaryContainer.withValues(alpha: 0.36),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Icon(
              isWeb ? Icons.open_in_new_rounded : Icons.launch_rounded,
              size: 12,
              color: scheme.primary,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildInlineText(
    BuildContext context,
    String text, {
    TextStyle? style,
  }) {
    final state = context.read<AppState>();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final baseStyle =
        style ??
        theme.textTheme.bodyMedium?.copyWith(height: 1.4) ??
        const TextStyle(height: 1.4);
    final spans = <InlineSpan>[];

    for (final run in _parseInlineRuns(text)) {
      if (!run.isCopyable) {
        spans.add(TextSpan(text: run.text, style: baseStyle));
        continue;
      }

      final resolved = _augmentReferenceText(state, run.copyText!);
      final openTarget = run.isOpenable
          ? _resolveOpenTarget(state, run.openTarget!)
          : null;
      spans.add(
        TextSpan(
          text: resolved,
          style: baseStyle.copyWith(
            color: scheme.primary,
            fontWeight: FontWeight.w600,
            fontFamily: 'monospace',
            backgroundColor: scheme.primaryContainer.withValues(alpha: 0.38),
            decoration: TextDecoration.underline,
            decorationColor: scheme.primary.withValues(alpha: 0.72),
          ),
          recognizer: TapGestureRecognizer()
            ..onTap = () => _copyCommand(
              context,
              resolved,
              'Reference',
            ),
        ),
      );
      if (openTarget != null) {
        spans.add(
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: _buildInlineOpenButton(
              context,
              openTarget,
              isWeb: _isWebReference(openTarget),
            ),
          ),
        );
      }
    }

    return Text.rich(TextSpan(children: spans, style: baseStyle));
  }

  List<Widget> _buildAnswerBlocks(BuildContext context, String text) {
    final theme = Theme.of(context);
    final blocks = text
        .trim()
        .split(RegExp(r'\n\s*\n'))
        .where((block) => block.trim().isNotEmpty)
        .toList(growable: false);

    if (blocks.isEmpty) {
      return [
        _buildInlineText(
          context,
          'No assistant answer captured yet.',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ];
    }

    final widgets = <Widget>[];
    for (final block in blocks) {
      final trimmed = block.trim();
      if (trimmed.startsWith('```') && trimmed.endsWith('```')) {
        final code = trimmed
            .replaceFirst(RegExp(r'^```[^\n]*\n?'), '')
            .replaceFirst(RegExp(r'\n?```$'), '');
        widgets.add(
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest.withValues(
                alpha: 0.42,
              ),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: theme.colorScheme.outlineVariant,
                width: 0.55,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: code.split('\n').map((line) {
                final style = theme.textTheme.bodySmall?.copyWith(
                  fontFamily: 'monospace',
                  height: 1.35,
                );
                if (line.isEmpty) {
                  return const SizedBox(height: 8);
                }
                return Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: _buildInlineText(
                    context,
                    line,
                    style: style,
                  ),
                );
              }).toList(growable: false),
            ),
          ),
        );
        continue;
      }

      final lines = trimmed.split('\n');
      final isBulletBlock = lines.every(
        (line) => line.trim().startsWith('- ') || line.trim().startsWith('* '),
      );
      if (isBulletBlock) {
        widgets.add(
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: lines.map((line) {
              final content = line.trim().replaceFirst(RegExp(r'^[-*]\s+'), '');
              return Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: Icon(
                        Icons.circle,
                        size: 6,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _buildInlineText(
                        context,
                        content,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          height: 1.35,
                        ),
                      ),
                    ),
                  ],
                ),
              );
            }).toList(growable: false),
          ),
        );
        continue;
      }

      final headingMatch = RegExp(r'^\*\*(.+?)\*\*$').firstMatch(trimmed);
      if (headingMatch != null) {
        widgets.add(
          Text(
            headingMatch.group(1) ?? trimmed,
            style: theme.textTheme.labelLarge?.copyWith(
              fontWeight: FontWeight.w700,
              letterSpacing: 0.15,
            ),
          ),
        );
        continue;
      }

      widgets.add(
        _buildInlineText(
          context,
          trimmed,
          style: theme.textTheme.bodyMedium?.copyWith(height: 1.4),
        ),
      );
    }

    return widgets;
  }

  Widget _buildLastAnswerCard(
    BuildContext context,
    AppState state,
    LastAnswer item,
    double width,
  ) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final blocks = _buildAnswerBlocks(context, item.answerText);
    final displayTitle = _configuredSessionTitle(
      state,
      item.id,
      item.displayTitle,
    );

    return Container(
      width: width,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest.withValues(alpha: 0.48),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.outlineVariant, width: 0.65),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                constraints: const BoxConstraints(minWidth: 68),
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: scheme.primaryContainer.withValues(alpha: 0.45),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  item.shortId,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.2,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  displayTitle,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.1,
                  ),
                ),
              ),
              _tooltip(
                'Copy answer',
                IconButton(
                  onPressed: () => _copyCommand(
                    context,
                    item.answerText,
                    'Answer',
                  ),
                  icon: const Icon(Icons.content_copy_rounded, size: 17),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ...blocks
              .map(
                (widget) => Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: widget,
                ),
              )
              .toList(growable: false),
          TextButton.icon(
            onPressed: () =>
                _copyCommand(context, item.sessionPath, 'Session file'),
            icon: const Icon(Icons.description_outlined, size: 16),
            label: const Text('Copy Session File'),
          ),
        ],
      ),
    );
  }

  Widget _buildLastAnswerPanel(BuildContext context, AppState state) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      decoration: BoxDecoration(
        border: Border.all(color: scheme.outlineVariant, width: 0.7),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildLastAnswersHeader(context, state),
          if (state.lastAnswersBusy)
            const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                if (!state.lastAnswersLoaded && !state.lastAnswersBusy) {
                  return Padding(
                    padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
                    child: Text(
                      state.lastAnswersStatus?.trim().isNotEmpty == true
                          ? state.lastAnswersStatus!
                          : 'Loading last answers in background...',
                    ),
                  );
                }

                if (state.lastAnswersBusy && state.lastAnswers.isEmpty) {
                  return Padding(
                    padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
                    child: Text(
                      state.lastAnswersStatus?.trim().isNotEmpty == true
                          ? state.lastAnswersStatus!
                          : 'Loading last answers...',
                    ),
                  );
                }

                if (state.lastAnswers.isEmpty) {
                  return Padding(
                    padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
                    child: Text(
                      state.lastAnswersStatus?.trim().isNotEmpty == true
                          ? state.lastAnswersStatus!
                          : 'No recent assistant answers found.',
                    ),
                  );
                }

                final cardWidth = constraints.maxWidth - 28;

                return SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(14, 14, 14, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: state.lastAnswers
                        .map(
                          (item) => Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: _buildLastAnswerCard(
                              context,
                              state,
                              item,
                              cardWidth,
                            ),
                          ),
                        )
                        .toList(growable: false),
                  ),
                );
              },
            ),
          ),
        ],
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
                  _tooltip(
                    'Edit group',
                    IconButton(
                      onPressed: () =>
                          _renameItem(context, state, item, index),
                      icon: const Icon(Icons.palette_outlined, size: 17),
                    ),
                  ),
                  _tooltip(
                    'Delete group',
                    IconButton(
                      onPressed: () =>
                          _deleteGroup(context, state, item, index),
                      icon: const Icon(Icons.delete_outline_rounded, size: 17),
                    ),
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
    int index, {
    bool forceUngrouped = false,
    bool showDragHandle = true,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final group = forceUngrouped ? null : state.groupForItem(index);
    final isGrouped = item.isSession && group != null;
    final groupColor = isGrouped ? _colorFromHex(group.colorHex) : null;
    final resolvedGroupColor = groupColor ?? scheme.outlineVariant;
    final isFirstInGroup = forceUngrouped ? true : state.isFirstSessionInGroup(index);
    final isLastInGroup = forceUngrouped ? true : state.isLastSessionInGroup(index);
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
                    _copyCommand(
                      context,
                      item.resumeCommand,
                      'Resume',
                    );
                  },
                  child: Row(
                    children: [
                      SizedBox(width: isGrouped ? 16 : 8),
                      Container(
                        constraints: const BoxConstraints(minWidth: 72),
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
                      _buildFastToggle(context, state, item, index),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: _buildNameArea(context, state, item, index),
                        ),
                      ),
                      _tooltip(
                        'Copy resume command',
                        IconButton(
                          onPressed: () => _copyCommand(
                            context,
                            item.resumeCommand,
                            'Resume',
                          ),
                          icon: const Icon(Icons.content_copy_rounded, size: 17),
                        ),
                      ),
                      _tooltip(
                        'Copy fork command',
                        IconButton(
                          onPressed: () => _copyCommand(
                            context,
                            item.forkCommand,
                            'Fork',
                          ),
                          icon: const Icon(Icons.call_split_rounded, size: 17),
                        ),
                      ),
                      _tooltip(
                        'Delete session',
                        IconButton(
                          onPressed: () => _deleteSession(state, index),
                          icon: const Icon(
                            Icons.delete_outline_rounded,
                            size: 17,
                          ),
                        ),
                      ),
                      if (showDragHandle) ...[
                        _buildDragHandle(context, index),
                        const SizedBox(width: 4),
                      ] else
                        const SizedBox(width: 8),
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

    return DefaultTabController(
      length: 2,
      child: Scaffold(
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
            _tooltip(
              'Settings',
              IconButton(
                onPressed: () => _showSettingsDialog(context, state),
                icon: const Icon(Icons.settings_outlined),
              ),
            ),
            const SizedBox(width: 4),
          ],
        ),
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildWarnings(context, state),
            _buildViewTabs(context, state),
            Expanded(
              child: TabBarView(
                physics: const NeverScrollableScrollPhysics(),
                children: [
                  _buildContextPanel(context, state),
                  _buildLastAnswerPanel(context, state),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Color _colorFromHex(String hex) {
    final normalized = hex.replaceAll('#', '').trim();
    final value = int.tryParse(normalized, radix: 16) ?? 0x83A598;
    return Color(0xFF000000 | value);
  }
}
