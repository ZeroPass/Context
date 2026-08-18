import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../app/app_state.dart';
import '../app/models.dart';

enum _DeleteGroupMode { groupOnly, groupAndCards }

class _CodexWeeklyUsage {
  const _CodexWeeklyUsage({
    required this.actualPercent,
    required this.expectedPercent,
    required this.remainingPercent,
    required this.resetAt,
    required this.usesManualReset,
    required this.effectivePaceWindowSeconds,
  });

  final double actualPercent;
  final double expectedPercent;
  final double remainingPercent;
  final DateTime resetAt;
  final bool usesManualReset;
  final int effectivePaceWindowSeconds;

  double get paceDeltaPercent => actualPercent - expectedPercent;
  double get targetLeftPercent => 100 - expectedPercent;
}

class _OneStepCupertinoPickerItem extends StatelessWidget {
  const _OneStepCupertinoPickerItem({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final pickerState = context
        .findAncestorStateOfType<_OneStepCupertinoPickerState>();
    return Listener(
      onPointerSignal: pickerState?._handlePointerSignal,
      child: child,
    );
  }
}

class _OneStepCupertinoPicker extends StatefulWidget {
  const _OneStepCupertinoPicker({
    required this.controller,
    required this.itemCount,
    required this.child,
  }) : assert(itemCount > 0);

  final FixedExtentScrollController controller;
  final int itemCount;
  final Widget child;

  @override
  State<_OneStepCupertinoPicker> createState() =>
      _OneStepCupertinoPickerState();
}

class _OneStepCupertinoPickerState extends State<_OneStepCupertinoPicker> {
  int? _pendingWheelTarget;
  PointerSignalEvent? _registeredWheelEvent;

  void _handlePointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent ||
        event.scrollDelta.dy == 0 ||
        !widget.controller.hasClients) {
      return;
    }
    if (identical(_registeredWheelEvent, event)) {
      return;
    }

    final currentItem = widget.controller.selectedItem;
    final direction = event.scrollDelta.dy.sign.toInt();
    final targetItem = (currentItem + direction)
        .clamp(0, widget.itemCount - 1)
        .toInt();
    _pendingWheelTarget = targetItem;
    _registeredWheelEvent = event;

    GestureBinding.instance.pointerSignalResolver.register(
      event,
      (resolvedEvent) {
        _registeredWheelEvent = null;
        _pendingWheelTarget = null;
        (resolvedEvent as PointerScrollEvent).respond(
          allowPlatformDefault: false,
        );
        if (mounted && widget.controller.hasClients) {
          widget.controller.jumpToItem(targetItem);
        }
      },
    );
  }

  bool _handleScrollNotification(ScrollNotification notification) {
    final targetItem = _pendingWheelTarget;
    if (targetItem == null || notification is! ScrollUpdateNotification) {
      return false;
    }

    _registeredWheelEvent = null;
    _pendingWheelTarget = null;
    if (widget.controller.hasClients) {
      widget.controller.jumpToItem(targetItem);
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollNotification>(
      onNotification: _handleScrollNotification,
      child: Listener(
        onPointerSignal: _handlePointerSignal,
        child: widget.child,
      ),
    );
  }
}

class _CodexWeeklyUsageBackgroundPainter extends CustomPainter {
  const _CodexWeeklyUsageBackgroundPainter({
    required this.actualPercent,
    required this.expectedPercent,
    required this.usedColor,
    required this.underTargetColor,
    required this.overTargetColor,
    required this.remainingColor,
    required this.targetMarkerColor,
    required this.actualEdgeColor,
  });

  final double actualPercent;
  final double expectedPercent;
  final Color usedColor;
  final Color underTargetColor;
  final Color overTargetColor;
  final Color remainingColor;
  final Color targetMarkerColor;
  final Color actualEdgeColor;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) {
      return;
    }

    final actual = actualPercent.clamp(0, 100).toDouble() / 100;
    final target = expectedPercent.clamp(0, 100).toDouble() / 100;
    final onPace = (actualPercent - expectedPercent).abs() <= 1;
    final visualActual = onPace ? target : actual;

    final cardRect = Offset.zero & size;
    final cardClip = RRect.fromRectAndRadius(
      cardRect,
      const Radius.circular(8.2),
    );

    void drawSection(double start, double end, Color color) {
      if (end <= start) {
        return;
      }
      final section = Rect.fromLTRB(
        size.width * start,
        0,
        size.width * end,
        size.height,
      );
      final paint = Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            color.withValues(alpha: color.opacity * 0.72),
            color,
            color.withValues(alpha: color.opacity * 0.88),
          ],
          stops: const [0, 0.52, 1],
        ).createShader(section);
      canvas.drawRect(section, paint);
    }

    canvas.save();
    canvas.clipRRect(cardClip);

    if (visualActual <= target) {
      drawSection(0, visualActual, usedColor);
      drawSection(visualActual, target, underTargetColor);
    } else {
      drawSection(0, target, usedColor);
      drawSection(target, visualActual, overTargetColor);
    }
    final coloredThrough = visualActual > target ? visualActual : target;
    drawSection(coloredThrough, 1, remainingColor);

    final highlightPaint = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0x09000000), Color(0x00000000)],
      ).createShader(cardRect);
    canvas.drawRect(cardRect, highlightPaint);

    final targetPaint = Paint()
      ..color = targetMarkerColor
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 1;
    final targetX = size.width * target;
    canvas.drawLine(
      Offset(targetX, 1.5),
      Offset(targetX, size.height - 1.5),
      targetPaint,
    );

    if (!onPace && (actual - target).abs() > 0.001) {
      final actualPaint = Paint()
        ..color = actualEdgeColor
        ..strokeCap = StrokeCap.round
        ..strokeWidth = 1;
      final actualX = size.width * actual;
      canvas.drawLine(
        Offset(actualX, 2.5),
        Offset(actualX, size.height - 2.5),
        actualPaint,
      );
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(
    covariant _CodexWeeklyUsageBackgroundPainter oldDelegate,
  ) {
    return actualPercent != oldDelegate.actualPercent ||
        expectedPercent != oldDelegate.expectedPercent ||
        usedColor != oldDelegate.usedColor ||
        underTargetColor != oldDelegate.underTargetColor ||
        overTargetColor != oldDelegate.overTargetColor ||
        remainingColor != oldDelegate.remainingColor ||
        targetMarkerColor != oldDelegate.targetMarkerColor ||
        actualEdgeColor != oldDelegate.actualEdgeColor;
  }
}

class _PassiveTooltip extends StatefulWidget {
  const _PassiveTooltip({required this.message, required this.child});

  final String message;
  final Widget child;

  @override
  State<_PassiveTooltip> createState() => _PassiveTooltipState();
}

class _PassiveTooltipState extends State<_PassiveTooltip> {
  bool _hovered = false;
  Timer? _showTimer;

  void _handleEnter() {
    _showTimer?.cancel();
    _showTimer = Timer(const Duration(milliseconds: 120), () {
      if (!mounted) {
        return;
      }
      setState(() => _hovered = true);
    });
  }

  void _handleExit() {
    _showTimer?.cancel();
    if (!_hovered) {
      return;
    }
    setState(() => _hovered = false);
  }

  @override
  void dispose() {
    _showTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hasMessage = widget.message.trim().isNotEmpty;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return MouseRegion(
      onEnter: (_) => _handleEnter(),
      onExit: (_) => _handleExit(),
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          widget.child,
          if (_hovered && hasMessage)
            Positioned(
              top: -46,
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
                          color: scheme.surfaceContainerHigh.withValues(
                            alpha: 0.88,
                          ),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: scheme.outlineVariant.withValues(
                              alpha: 0.38,
                            ),
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
    return _PassiveTooltip(message: message, child: child);
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
    SessionProvider initialProvider = SessionProvider.codex,
  }) async {
    final commandController = TextEditingController(
      text: initialSessionInput ?? '',
    );
    final nameController = TextEditingController(text: initialName ?? '');
    var selectedProvider = initialProvider;

    try {
      final accepted = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            title: const Text('Add Session'),
            content: SizedBox(
              width: 420,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SegmentedButton<SessionProvider>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(
                        value: SessionProvider.codex,
                        icon: Icon(Icons.terminal_rounded, size: 16),
                        label: Text('Codex'),
                      ),
                      ButtonSegment(
                        value: SessionProvider.kimi,
                        icon: Icon(Icons.nights_stay_outlined, size: 16),
                        label: Text('Kimi'),
                      ),
                      ButtonSegment(
                        value: SessionProvider.opencode,
                        icon: Icon(Icons.code_rounded, size: 16),
                        label: Text('OpenCode'),
                      ),
                      ButtonSegment(
                        value: SessionProvider.qwen,
                        icon: Icon(Icons.auto_awesome_rounded, size: 16),
                        label: Text('Qwen'),
                      ),
                    ],
                    selected: <SessionProvider>{selectedProvider},
                    onSelectionChanged: (selection) => setDialogState(
                      () => selectedProvider = selection.first,
                    ),
                  ),
                  const SizedBox(height: 14),
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
                    decoration: InputDecoration(
                      labelText: 'Session id or resume command',
                      hintText: switch (selectedProvider) {
                        SessionProvider.codex => 'codex resume <id>',
                        SessionProvider.kimi => 'kimi --session <id>',
                        SessionProvider.opencode => 'opencode --session <id>',
                        SessionProvider.qwen => 'qwen --resume <id>',
                      },
                    ),
                    onChanged: (value) {
                      try {
                        final parsed = state.parseSessionInput(
                          value,
                          fallback: selectedProvider,
                        );
                        final lower = value.toLowerCase();
                        if ((lower.contains('codex ') ||
                                lower.contains('kimi ') ||
                                lower.contains('opencode ') ||
                                lower.contains('qwen ')) &&
                            parsed.provider != selectedProvider) {
                          setDialogState(
                            () => selectedProvider = parsed.provider,
                          );
                        }
                      } on FormatException {
                        // Incomplete commands are expected while typing.
                      }
                    },
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
        ),
      );

      if (accepted != true) {
        return;
      }

      state.addSession(
        sessionInput: commandController.text,
        title: nameController.text,
        provider: selectedProvider,
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
      initialProvider: item.provider,
    );
  }

  Future<void> _saveCodexAccount(BuildContext context, AppState state) async {
    final account = await _showCodexAccountSaveDialog(
      context,
      initialSlot: _nextCodexAccountSlot(state),
    );
    if (account == null) {
      return;
    }
    final (slot, displayName) = account;

    final exists = state.codexAccounts.any(
      (account) => account.identityKey == slot.trim().toLowerCase(),
    );
    if (exists) {
      final overwrite = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text('Overwrite account $slot?'),
          content: const Text(
            'The current Codex credentials will replace the saved account in this slot.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Overwrite'),
            ),
          ],
        ),
      );
      if (overwrite != true) {
        return;
      }
    }

    try {
      await state.saveCodexAccount(slot, displayName);
    } catch (error) {
      if (!context.mounted) {
        return;
      }
      await _showError(context, error);
    }
  }

  Future<void> _switchCodexAccount(
    BuildContext context,
    AppState state,
    String slot,
  ) async {
    try {
      await state.switchCodexAccount(slot);
    } catch (error) {
      if (!context.mounted) {
        return;
      }
      await _showError(context, error);
    }
  }

  Future<void> _renameCodexAccount(
    BuildContext context,
    AppState state,
    CodexAccount account,
  ) async {
    final displayName = await _showCodexAccountDisplayNameDialog(
      context,
      title: 'Rename Codex account',
      initialName: account.displayName,
    );
    if (displayName == null) {
      return;
    }

    try {
      await state.renameCodexAccount(account.slot, displayName);
    } catch (error) {
      if (!context.mounted) {
        return;
      }
      await _showError(context, error);
    }
  }

  Future<void> _deleteCodexAccount(
    BuildContext context,
    AppState state,
    CodexAccount account,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Delete ${account.displayName}?'),
        content: Text(
          'Remove the saved Codex account in slot ${account.slot}. '
          'This does not delete the live auth.json file.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Delete saved account'),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      return;
    }

    try {
      await state.deleteCodexAccount(account.slot);
    } catch (error) {
      if (!context.mounted) {
        return;
      }
      await _showError(context, error);
    }
  }

  Future<void> _setCodexManualReset(
    BuildContext context,
    AppState state,
  ) async {
    final apiResetAt = _latestCodexApiResetAt(state);
    if (apiResetAt == null) {
      await _showError(
        context,
        StateError('No weekly reset is available yet.'),
      );
      return;
    }

    final configuredManualResetAt = _configuredCodexManualResetAt(state);
    final manualResetAt = await _showCodexManualResetDialog(
      context,
      apiResetAt: apiResetAt,
      configuredManualResetAt: configuredManualResetAt,
    );
    if (manualResetAt == null) {
      return;
    }
    if (!manualResetAt.isAfter(DateTime.now())) {
      if (!context.mounted) {
        return;
      }
      await _showError(
        context,
        StateError('Choose a future Codex reset time.'),
      );
      return;
    }

    try {
      await state.setCodexManualReset(manualResetAt);
    } catch (error) {
      if (!context.mounted) {
        return;
      }
      await _showError(context, error);
    }
  }

  Future<void> _clearCodexManualReset(
    BuildContext context,
    AppState state,
  ) async {
    try {
      await state.clearCodexManualReset();
    } catch (error) {
      if (!context.mounted) {
        return;
      }
      await _showError(context, error);
    }
  }

  Future<DateTime?> _showCodexManualResetDialog(
    BuildContext context, {
    required DateTime apiResetAt,
    required DateTime? configuredManualResetAt,
  }) async {
    final initialOffsets = _codexManualResetPickerOffsets(
      apiResetAt,
      configuredManualResetAt,
    );
    var dayOffset = initialOffsets.day;
    var hourOffset = initialOffsets.hour;
    String? validationError;
    final dayOffsets = List<int>.generate(7, (index) => index - 6);
    final hourOffsets = List<int>.generate(24, (index) => index - 23);
    final dayController = FixedExtentScrollController(
      initialItem: dayOffsets.indexOf(dayOffset),
    );
    final hourController = FixedExtentScrollController(
      initialItem: hourOffsets.indexOf(hourOffset),
    );

    Widget buildOffsetPicker({
      required String label,
      required String unit,
      required List<int> values,
      required FixedExtentScrollController controller,
      required int selectedValue,
      required ValueChanged<int> onChanged,
    }) {
      final theme = Theme.of(context);
      final scheme = theme.colorScheme;
      return Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              label,
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 3),
            DecoratedBox(
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest.withValues(alpha: 0.42),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: scheme.outlineVariant.withValues(alpha: 0.28),
                  width: 0.6,
                ),
              ),
              child: SizedBox(
                height: 108,
                child: _OneStepCupertinoPicker(
                  controller: controller,
                  itemCount: values.length,
                  child: CupertinoPicker(
                    backgroundColor: Colors.transparent,
                    diameterRatio: 1.25,
                    itemExtent: 30,
                    magnification: 1.06,
                    onSelectedItemChanged: (index) {
                      if (index < 0 || index >= values.length) {
                        return;
                      }
                      final value = values[index];
                      if (value == selectedValue) {
                        return;
                      }
                      onChanged(value);
                    },
                    scrollController: controller,
                    squeeze: 1.15,
                    useMagnifier: true,
                    children: [
                      for (final value in values)
                        _OneStepCupertinoPickerItem(
                          child: Center(
                            child: Text(
                              '$value $unit',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: scheme.onSurface,
                                fontWeight: value == selectedValue
                                    ? FontWeight.w700
                                    : FontWeight.w500,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }

    try {
      return await showDialog<DateTime?>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (context, setDialogState) {
            final preview = apiResetAt.add(
              Duration(days: dayOffset, hours: hourOffset),
            );
            final previewIsFuture = preview.isAfter(DateTime.now());
            final previewError = validationError ??
                (previewIsFuture ? null : 'Choose a future reset time.');

            void submit() {
              if (!preview.isAfter(DateTime.now())) {
                setDialogState(
                  () => validationError = 'Choose a future reset time.',
                );
                return;
              }
              Navigator.of(dialogContext).pop(preview);
            }

            return AlertDialog(
              title: Text(
                configuredManualResetAt == null
                    ? 'Set manual Codex reset'
                    : 'Edit manual Codex reset',
              ),
              content: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 360),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        buildOffsetPicker(
                          label: 'Day offset',
                          unit: 'days',
                          values: dayOffsets,
                          controller: dayController,
                          selectedValue: dayOffset,
                          onChanged: (value) {
                            setDialogState(() {
                              dayOffset = value;
                              validationError = null;
                            });
                          },
                        ),
                        const SizedBox(width: 8),
                        buildOffsetPicker(
                          label: 'Hour offset',
                          unit: 'hours',
                          values: hourOffsets,
                          controller: hourController,
                          selectedValue: hourOffset,
                          onChanged: (value) {
                            setDialogState(() {
                              hourOffset = value;
                              validationError = null;
                            });
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: Theme.of(context)
                            .colorScheme
                            .surfaceContainerHighest
                            .withValues(alpha: 0.42),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            'Resulting reset',
                            style: Theme.of(context)
                                .textTheme
                                .labelSmall
                                ?.copyWith(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                                ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            _formatCodexResetPreview(preview),
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(fontWeight: FontWeight.w600),
                          ),
                        ],
                      ),
                    ),
                    if (previewError != null) ...[
                      const SizedBox(height: 7),
                      Text(
                        previewError,
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: previewIsFuture ? submit : null,
                  child: Text(
                    configuredManualResetAt == null ? 'Set' : 'Save',
                  ),
                ),
              ],
            );
          },
        ),
      );
    } finally {
      dayController.dispose();
      hourController.dispose();
    }
  }

  Future<(String, String)?> _showCodexAccountSaveDialog(
    BuildContext context, {
    required String initialSlot,
  }) async {
    final slotController = TextEditingController(text: initialSlot);
    final nameController = TextEditingController(text: initialSlot);
    String? slotError;
    String? nameError;

    try {
      return await showDialog<(String, String)?>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (context, setDialogState) {
            final slot = slotController.text.trim();
            final displayName = nameController.text.trim();
            final slotValid = RegExp(r'^[1-9][0-9]*$').hasMatch(slot);
            final nameValid = displayName.isNotEmpty;

            void submit() {
              if (!slotValid || !nameValid) {
                setDialogState(() {
                  slotError = slotValid
                      ? null
                      : 'Use a positive number, for example 1 or 2.';
                  nameError = nameValid ? null : 'Enter a display name.';
                });
                return;
              }
              Navigator.of(dialogContext).pop((slot, displayName));
            }

            return AlertDialog(
              title: const Text('Save Codex account'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: slotController,
                    autofocus: true,
                    keyboardType: TextInputType.number,
                    textInputAction: TextInputAction.next,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: InputDecoration(
                      labelText: 'Account slot',
                      hintText: '1 or 2',
                      errorText: slotError,
                    ),
                    onChanged: (_) => setDialogState(() => slotError = null),
                    onSubmitted: (_) => submit(),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: nameController,
                    textInputAction: TextInputAction.done,
                    decoration: InputDecoration(
                      labelText: 'Display name',
                      hintText: 'name@example.com or a label',
                      errorText: nameError,
                    ),
                    onChanged: (_) => setDialogState(() => nameError = null),
                    onSubmitted: (_) => submit(),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('Cancel'),
                ),
                FilledButton(onPressed: submit, child: const Text('Save')),
              ],
            );
          },
        ),
      );
    } finally {
      slotController.dispose();
      nameController.dispose();
    }
  }

  Future<String?> _showCodexAccountDisplayNameDialog(
    BuildContext context, {
    required String title,
    required String initialName,
  }) async {
    final controller = TextEditingController(text: initialName);
    String? validationError;

    try {
      return await showDialog<String>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (context, setDialogState) {
            void submit() {
              final value = controller.text.trim();
              if (value.isEmpty) {
                setDialogState(() => validationError = 'Enter a display name.');
                return;
              }
              Navigator.of(dialogContext).pop(value);
            }

            return AlertDialog(
              title: Text(title),
              content: TextField(
                controller: controller,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: 'Display name',
                  hintText: 'name@example.com or a label',
                  errorText: validationError,
                ),
                onChanged: (_) => setDialogState(() => validationError = null),
                onSubmitted: (_) => submit(),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('Cancel'),
                ),
                FilledButton(onPressed: submit, child: const Text('Save')),
              ],
            );
          },
        ),
      );
    } finally {
      controller.dispose();
    }
  }

  String _nextCodexAccountSlot(AppState state) {
    var candidate = 1;
    final used = state.codexAccounts
        .map((account) => account.slot.trim().toLowerCase())
        .toSet();
    while (used.contains('$candidate')) {
      candidate += 1;
    }
    return '$candidate';
  }

  DateTime? _latestCodexApiResetAt(AppState state) {
    int? latestTimestamp;
    for (final account in state.codexAccounts) {
      final timestamp = account.weeklyResetAt;
      if (timestamp == null ||
          (latestTimestamp != null && timestamp <= latestTimestamp)) {
        continue;
      }
      latestTimestamp = timestamp;
    }
    return latestTimestamp == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(latestTimestamp);
  }

  DateTime? _configuredCodexManualResetAt(AppState state) {
    var latestManualResetAt = state.codexActiveManualResetAt;
    for (final account in state.codexAccounts) {
      final timestamp = account.manualResetAt;
      if (timestamp == null) {
        continue;
      }
      final manualResetAt = DateTime.fromMillisecondsSinceEpoch(timestamp);
      if (latestManualResetAt == null ||
          manualResetAt.isAfter(latestManualResetAt)) {
        latestManualResetAt = manualResetAt;
      }
    }
    return latestManualResetAt;
  }

  ({int day, int hour}) _codexManualResetPickerOffsets(
    DateTime apiResetAt,
    DateTime? configuredManualResetAt,
  ) {
    if (configuredManualResetAt == null) {
      return (day: 0, hour: 0);
    }

    final offset = configuredManualResetAt.difference(apiResetAt);
    const minimumOffset = Duration(days: -6, hours: -23);
    final clampedOffset = Duration(
      microseconds: offset.inMicroseconds
          .clamp(minimumOffset.inMicroseconds, 0)
          .toInt(),
    );
    final dayOffset = clampedOffset.inDays;
    return (
      day: dayOffset,
      hour: clampedOffset.inHours - dayOffset * 24,
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
    SessionProvider provider,
    String sessionId,
    String fallback,
  ) {
    final normalized = sessionId.trim().toLowerCase();
    for (final item in state.items) {
      if (!item.isSession) {
        continue;
      }
      if (item.provider != provider ||
          item.commandId.trim().toLowerCase() != normalized) {
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
      final parentTitle = _configuredSessionTitle(
        state,
        item.provider,
        parentId,
        '',
      );
      final normalizedParent = parentTitle.trim();
      if (normalizedParent.isNotEmpty && normalizedParent != parentId) {
        return '$normalizedParent fork';
      }
    }

    return _configuredSessionTitle(
      state,
      item.provider,
      item.id,
      item.displayTitle,
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
          builder: (context, setDialogState) => AlertDialog(
            title: const Text('Settings'),
            content: SizedBox(
              width: 460,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Markdown file',
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Theme.of(context)
                            .colorScheme
                            .surfaceContainerLowest
                            .withValues(alpha: 0.55),
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
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        OutlinedButton.icon(
                          onPressed: state.busy
                              ? null
                              : () async {
                                  await _pickMarkdownFile(context, state);
                                  if (dialogContext.mounted) {
                                    setDialogState(() {});
                                  }
                                },
                          icon: const Icon(
                            Icons.description_outlined,
                            size: 17,
                          ),
                          label: const Text('Pick file'),
                        ),
                        OutlinedButton.icon(
                          onPressed: state.busy
                              ? null
                              : () async {
                                  await _reload(context, state);
                                  if (dialogContext.mounted) {
                                    setDialogState(() {});
                                  }
                                },
                          icon: const Icon(Icons.refresh_rounded, size: 17),
                          label: const Text('Reload'),
                        ),
                        OutlinedButton.icon(
                          onPressed: state.busy
                              ? null
                              : () async {
                                  await _createExampleMarkdown(context, state);
                                  if (dialogContext.mounted) {
                                    setDialogState(() {});
                                  }
                                },
                          icon: const Icon(
                            Icons.auto_awesome_outlined,
                            size: 17,
                          ),
                          label: const Text('Create example'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Autosave'),
                      subtitle: const Text(
                        'Save changes shortly after editing or reordering.',
                      ),
                      value: state.autosaveEnabled,
                      onChanged: state.busy
                          ? null
                          : (value) {
                              state.setAutosaveEnabled(value);
                              setDialogState(() {});
                            },
                    ),
                    const Divider(height: 28),
                    Text(
                      'Appearance',
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 10),
                    SegmentedButton<ThemeAppearance>(
                      showSelectedIcon: false,
                      segments: const <ButtonSegment<ThemeAppearance>>[
                        ButtonSegment(
                          value: ThemeAppearance.light,
                          label: Text('Light'),
                        ),
                        ButtonSegment(
                          value: ThemeAppearance.sepia,
                          label: Text('Sepia'),
                        ),
                        ButtonSegment(
                          value: ThemeAppearance.dim,
                          label: Text('Dusk'),
                        ),
                        ButtonSegment(
                          value: ThemeAppearance.dark,
                          label: Text('Dark'),
                        ),
                      ],
                      selected: <ThemeAppearance>{state.themeAppearance},
                      onSelectionChanged: (selection) {
                        state.setThemeAppearance(selection.first);
                        setDialogState(() {});
                      },
                    ),
                    const SizedBox(height: 18),
                    Text(
                      'Accent',
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
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
                            final colorLabel =
                                '#${value.toRadixString(16).substring(2).toUpperCase()}';
                            return _tooltip(
                              colorLabel,
                              InkWell(
                                onTap: () {
                                  state.setThemeSeedColor(value);
                                  setDialogState(() {});
                                },
                                borderRadius: BorderRadius.circular(999),
                                child: AnimatedContainer(
                                  duration: const Duration(milliseconds: 140),
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
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          fontWeight: FontWeight.w600,
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
    final message = (state.status ?? '').trim().isNotEmpty
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
        gradient: LinearGradient(
          colors: [
            scheme.primaryContainer.withValues(alpha: 0.10),
            Colors.transparent,
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
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
                    fontWeight: FontWeight.w600,
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

  String _formatRecentAge(int timestampMs) {
    if (timestampMs <= 0) {
      return 'recent';
    }
    final updated = DateTime.fromMillisecondsSinceEpoch(timestampMs);
    final elapsed = DateTime.now().difference(updated);
    if (elapsed.isNegative || elapsed.inMinutes < 1) {
      return 'now';
    }
    if (elapsed.inHours < 1) {
      return '${elapsed.inMinutes}m';
    }
    if (elapsed.inDays < 1) {
      return '${elapsed.inHours}h';
    }
    if (elapsed.inDays < 7) {
      return '${elapsed.inDays}d';
    }
    return '${updated.day}.${updated.month}.';
  }

  Widget _buildRecentProviderTab(
    BuildContext context,
    AppState state,
    SessionProvider provider,
    int count,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final selected = state.recentProvider == provider;
    final providerColor = _providerColor(scheme, provider);

    return Expanded(
      child: InkWell(
        onTap: () => state.setRecentProvider(provider),
        borderRadius: BorderRadius.circular(9),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            color: selected
                ? providerColor.withValues(alpha: 0.16)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(9),
            border: Border.all(
              color: selected
                  ? providerColor.withValues(alpha: 0.55)
                  : Colors.transparent,
              width: 0.8,
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                switch (provider) {
                  SessionProvider.codex => Icons.terminal_rounded,
                  SessionProvider.kimi => Icons.nights_stay_outlined,
                  SessionProvider.opencode => Icons.code_rounded,
                  SessionProvider.qwen => Icons.auto_awesome_rounded,
                },
                size: 15,
                color: selected ? providerColor : scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 7),
              Text(
                provider.label,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: selected ? scheme.onSurface : scheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 6),
              Container(
                constraints: const BoxConstraints(minWidth: 20),
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: selected
                      ? providerColor.withValues(alpha: 0.22)
                      : scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  '$count',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: selected
                        ? scheme.onSurface
                        : scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCodexAccountSection(BuildContext context, AppState state) {
    final scheme = Theme.of(context).colorScheme;
    final providerColor = _providerColor(scheme, SessionProvider.codex);
    final accountSectionSurfaceColor = scheme.surfaceContainerLowest
        .withValues(alpha: 0.38);
    final neutralAccountOutlineColor = HSLColor.fromColor(
      scheme.outlineVariant,
    ).withSaturation(0).toColor();
    final activeSlot = state.codexActiveAccount?.trim();
    final accountBusy = state.codexAccountBusy;
    final accountError = state.codexAccountError;
    final accountStatus = state.codexAccountStatus;
    final hasAccountError = accountError?.trim().isNotEmpty ?? false;
    final hasAccountStatus = accountStatus?.trim().isNotEmpty ?? false;
    final now = DateTime.now();
    final configuredManualResetAt = _configuredCodexManualResetAt(state);
    final manualResetAt = configuredManualResetAt?.isAfter(now) == true
        ? configuredManualResetAt
        : null;
    final apiResetAt = _latestCodexApiResetAt(state);
    final hasConfiguredManualReset = configuredManualResetAt != null;

    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 0),
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
        decoration: BoxDecoration(
          color: accountSectionSurfaceColor,
          borderRadius: BorderRadius.circular(11),
          border: Border.all(
            color: neutralAccountOutlineColor.withValues(alpha: 0.25),
            width: 0.65,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  Icons.account_circle_outlined,
                  size: 17,
                  color: providerColor,
                ),
                const SizedBox(width: 7),
                Text(
                  'Codex account',
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    activeSlot == null
                        ? 'Current slot: not saved'
                        : 'Current slot: $activeSlot',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                _tooltip(
                  'Refresh saved Codex accounts',
                  IconButton(
                    onPressed: state.busy || accountBusy
                        ? null
                        : () => unawaited(state.loadCodexAccounts()),
                    icon: const Icon(Icons.refresh_rounded, size: 17),
                    visualDensity: VisualDensity.compact,
                  ),
                ),
                _tooltip(
                  'Save current Codex account',
                  IconButton(
                    onPressed: state.busy || accountBusy
                        ? null
                        : () => _saveCodexAccount(context, state),
                    icon: const Icon(Icons.add_rounded, size: 18),
                    visualDensity: VisualDensity.compact,
                  ),
                ),
                Tooltip(
                  message: hasConfiguredManualReset
                      ? 'Edit manual reset'
                      : 'Set manual reset',
                  child: IconButton(
                    onPressed: state.busy || accountBusy || apiResetAt == null
                        ? null
                        : () => unawaited(
                            _setCodexManualReset(context, state),
                          ),
                    icon: Icon(
                      hasConfiguredManualReset
                          ? Icons.edit_calendar_outlined
                          : Icons.add_alarm_outlined,
                      size: 16,
                    ),
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 30,
                      minHeight: 30,
                    ),
                  ),
                ),
                if (hasConfiguredManualReset)
                  Tooltip(
                    message: 'Remove manual reset',
                    child: IconButton(
                      onPressed: state.busy || accountBusy
                          ? null
                          : () => unawaited(
                              _clearCodexManualReset(context, state),
                            ),
                      icon: const Icon(Icons.close_rounded, size: 16),
                      color: scheme.error,
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 30,
                        minHeight: 30,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 7),
            if (state.codexAccounts.isEmpty)
              Row(
                children: [
                  Icon(
                    Icons.info_outline_rounded,
                    size: 15,
                    color: scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'No saved accounts yet. Save the current one with a slot and display name.',
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              )
            else
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: state.codexAccounts
                    .map(
                      (account) => _buildCodexAccountRow(
                        context,
                        state,
                        account,
                        activeSlot: activeSlot,
                        now: now,
                        manualResetAt: manualResetAt,
                      ),
                    )
                    .toList(growable: false),
              ),
            SizedBox(
              height: 9,
              child: accountBusy
                  ? Align(
                      alignment: Alignment.bottomCenter,
                      child: SizedBox(
                        width: double.infinity,
                        height: 2,
                        child: LinearProgressIndicator(
                          minHeight: 2,
                          color: neutralAccountOutlineColor,
                          backgroundColor: neutralAccountOutlineColor.withValues(
                            alpha: 0.12,
                          ),
                        ),
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
            ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 22),
              child: hasAccountError
                  ? Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        accountError!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(
                          context,
                        ).textTheme.labelSmall?.copyWith(color: scheme.error),
                      ),
                    )
                  : hasAccountStatus
                  ? Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        accountStatus!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCodexAccountRow(
    BuildContext context,
    AppState state,
    CodexAccount account, {
    required String? activeSlot,
    required DateTime now,
    required DateTime? manualResetAt,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final selected = activeSlot?.trim().toLowerCase() == account.identityKey;
    final enabled = !state.busy && !state.codexAccountBusy;
    final usage = _weeklyUsageFor(
      account,
      now,
      manualResetAt: manualResetAt,
    );
    final underTargetColor = scheme.brightness == Brightness.dark
        ? const Color(0xFF6AD697)
        : const Color(0xFF138A4B);
    final overTargetColor = scheme.brightness == Brightness.dark
        ? const Color(0xFFFF7070)
        : const Color(0xFFC62828);
    final accountCardSurfaceColor = scheme.surfaceContainerLowest.withValues(
      alpha: 0.62,
    );
    final neutralQuotaOutlineColor = HSLColor.fromColor(
      scheme.outlineVariant,
    ).withSaturation(0).toColor();
    final quotaTooltipMessage = usage == null
        ? ''
        : 'Spent ${_formatCodexPercent(usage.actualPercent)}% last recorded.\n'
              'Fair target by now: ${_formatCodexPercent(usage.expectedPercent)}% used '
              '(${_formatCodexPercent(usage.targetLeftPercent)}% target left).';
    final quotaSemanticsLabel = usage == null
        ? null
        : 'Weekly usage ${_formatCodexPercent(usage.actualPercent)} percent used, '
              'last recorded.\n'
              'Fair target by now ${_formatCodexPercent(usage.expectedPercent)} percent '
              'used, or ${_formatCodexPercent(usage.targetLeftPercent)} percent target left.';

    return Container(
      margin: const EdgeInsets.only(bottom: 5),
      padding: EdgeInsets.zero,
      decoration: BoxDecoration(
        color: accountCardSurfaceColor,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(
          color: selected
              ? underTargetColor.withValues(alpha: 0.44)
              : neutralQuotaOutlineColor.withValues(alpha: 0.28),
          width: selected ? 0.9 : 0.65,
        ),
      ),
      child: _tooltip(
        quotaTooltipMessage,
        ClipRRect(
          borderRadius: BorderRadius.circular(8.2),
          child: Stack(
            children: [
              if (usage != null)
                Positioned.fill(
                  child: Semantics(
                    container: true,
                    label: quotaSemanticsLabel,
                    child: IgnorePointer(
                      child: CustomPaint(
                        painter: _CodexWeeklyUsageBackgroundPainter(
                          actualPercent: usage.actualPercent,
                          expectedPercent: usage.expectedPercent,
                          usedColor: underTargetColor.withValues(alpha: 0.32),
                          underTargetColor: underTargetColor.withValues(
                            alpha: 0.20,
                          ),
                          overTargetColor: overTargetColor.withValues(
                            alpha: 0.17,
                          ),
                          remainingColor: accountCardSurfaceColor,
                          targetMarkerColor: scheme.onSurface.withValues(
                            alpha: 0.23,
                          ),
                          actualEdgeColor: scheme.onSurface.withValues(
                            alpha: 0.16,
                          ),
                        ),
                        child: const SizedBox.expand(),
                      ),
                    ),
                  ),
                ),
              SizedBox(
                width: double.infinity,
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(8.2),
                    onTap: enabled && !selected
                        ? () => unawaited(
                            _switchCodexAccount(
                              context,
                              state,
                              account.slot,
                            ),
                          )
                        : null,
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
                                        account.displayName,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall
                                            ?.copyWith(
                                              fontWeight: selected
                                                  ? FontWeight.w700
                                                  : FontWeight.w600,
                                            ),
                                      ),
                                      Text(
                                        'Slot ${account.slot}${selected ? ' · active' : ''}',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: Theme.of(context)
                                            .textTheme
                                            .labelSmall
                                            ?.copyWith(
                                              color: selected
                                                  ? underTargetColor
                                                  : scheme.onSurfaceVariant,
                                            ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              const SizedBox(width: 60, height: 30),
                            ],
                          ),
                          _buildCodexWeeklyUsage(context, account, usage),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              Positioned(
                top: 5,
                right: 4,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      onPressed: enabled
                          ? () => unawaited(
                              _renameCodexAccount(context, state, account),
                            )
                          : null,
                      tooltip: 'Rename account',
                      icon: const Icon(Icons.edit_outlined, size: 16),
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 30,
                        minHeight: 30,
                      ),
                    ),
                    IconButton(
                      onPressed: enabled
                          ? () => unawaited(
                              _deleteCodexAccount(context, state, account),
                            )
                          : null,
                      tooltip: 'Delete saved account',
                      icon: const Icon(
                        Icons.delete_outline_rounded,
                        size: 16,
                      ),
                      color: scheme.error,
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 30,
                        minHeight: 30,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCodexWeeklyUsage(
    BuildContext context,
    CodexAccount account,
    _CodexWeeklyUsage? usage,
  ) {
    final scheme = Theme.of(context).colorScheme;
    if (usage == null) {
      final error = account.weeklyError?.trim();
      return Padding(
        padding: const EdgeInsets.only(top: 3, left: 3),
        child: Row(
          children: [
            Icon(
              Icons.query_stats_rounded,
              size: 14,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                error == null || error.isEmpty
                    ? 'Usage unavailable'
                    : 'Usage unavailable · $error',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      );
    }

    final delta = usage.paceDeltaPercent;
    final underPace = delta < -1;
    final overPace = delta > 1;
    final paceText = underPace
        ? '${_formatPaceDifference(delta.abs(), usage.effectivePaceWindowSeconds)} too slow'
        : overPace
        ? '${_formatPaceDifference(delta.abs(), usage.effectivePaceWindowSeconds)} too fast'
        : 'on pace';
    final paceColor = underPace
        ? (scheme.brightness == Brightness.dark
              ? const Color(0xFF65C18C)
              : const Color(0xFF267A4B))
        : overPace
        ? scheme.error
        : scheme.onSurfaceVariant;

    return Padding(
      padding: const EdgeInsets.only(top: 4, left: 3, right: 3),
      child: Row(
        children: [
          Icon(
            Icons.schedule_outlined,
            size: 13,
            color: scheme.onSurfaceVariant,
          ),
          const SizedBox(width: 5),
          Expanded(
            child: Text(
              '${_formatCodexPercent(usage.remainingPercent)}% left'
                  '${usage.usesManualReset ? ' (resets ${_formatCodexReset(usage.resetAt)})' : ''}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(width: 7),
          Icon(Icons.speed_outlined, size: 13, color: paceColor),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              'Pace: $paceText',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: paceColor,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  _CodexWeeklyUsage? _weeklyUsageFor(
    CodexAccount account,
    DateTime now, {
    DateTime? manualResetAt,
  }) {
    if (account.weeklyError != null || account.weeklyUsedPercent == null) {
      return null;
    }

    final apiWindow = Duration(seconds: account.effectiveWeeklyWindowSeconds);
    if (apiWindow.inMilliseconds <= 0) {
      return null;
    }
    final apiResetAt = account.weeklyResetAt == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(account.weeklyResetAt!);
    final usesManualReset = manualResetAt?.isAfter(now) == true;
    final resetAt = usesManualReset
        ? manualResetAt
        : apiResetAt;
    if (resetAt == null) {
      return null;
    }
    if (apiResetAt == null) {
      return null;
    }
    final cycleStart = apiResetAt.subtract(apiWindow);
    final effectivePaceWindow = resetAt.difference(cycleStart);
    if (effectivePaceWindow.inMilliseconds <= 0 ||
        effectivePaceWindow.inSeconds <= 0) {
      return null;
    }
    final elapsedMilliseconds = now.difference(cycleStart).inMilliseconds;
    final expectedPercent =
        (elapsedMilliseconds / effectivePaceWindow.inMilliseconds * 100)
        .clamp(0, 100)
        .toDouble();
    final actualPercent = account.weeklyUsedPercent!.clamp(0, 100).toDouble();

    return _CodexWeeklyUsage(
      actualPercent: actualPercent,
      expectedPercent: expectedPercent,
      remainingPercent: 100 - actualPercent,
      resetAt: resetAt,
      usesManualReset: usesManualReset,
      effectivePaceWindowSeconds: effectivePaceWindow.inSeconds,
    );
  }

  String _formatPaceDifference(double deltaPercent, int windowSeconds) {
    final seconds = (deltaPercent / 100 * windowSeconds).round();
    final minutes = Duration(seconds: seconds).inMinutes;
    if (minutes < 60) {
      return '<1h';
    }
    final days = minutes ~/ (24 * 60);
    final remainingHours = (minutes % (24 * 60)) ~/ 60;
    if (days > 0) {
      return remainingHours == 0 ? '${days}d' : '${days}d ${remainingHours}h';
    }
    return '${minutes ~/ 60}h';
  }

  String _formatCodexPercent(double value) =>
      value.round().clamp(0, 100).toString();

  String _formatCodexReset(DateTime value) {
    const months = <String>[
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    final hour = value.hour.toString().padLeft(2, '0');
    final minute = value.minute.toString().padLeft(2, '0');
    return '$hour:$minute on ${value.day} ${months[value.month - 1]}';
  }

  String _formatCodexResetPreview(DateTime value) {
    const weekdays = <String>[
      'Mon',
      'Tue',
      'Wed',
      'Thu',
      'Fri',
      'Sat',
      'Sun',
    ];
    const months = <String>[
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    final hour = value.hour.toString().padLeft(2, '0');
    final minute = value.minute.toString().padLeft(2, '0');
    return '${weekdays[value.weekday - 1]}, ${value.day} '
        '${months[value.month - 1]} ${value.year} at $hour:$minute';
  }

  Widget _buildRecentSectionHeader(BuildContext context, AppState state) {
    final scheme = Theme.of(context).colorScheme;
    final providerColor = _providerColor(scheme, state.recentProvider);
    final recentSubtitle = _recentSubtitle(state);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 8, 8),
          child: Row(
            children: [
              Container(
                width: 7,
                height: 22,
                decoration: BoxDecoration(
                  color: providerColor,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Recent sessions',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (recentSubtitle.isNotEmpty)
                      Text(
                        recentSubtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                          fontSize: 11,
                        ),
                      ),
                  ],
                ),
              ),
              _tooltip(
                'Refresh recent sessions',
                IconButton(
                  onPressed: state.recentBusy
                      ? null
                      : () => state.refreshRecent(queueIfBusy: true),
                  icon: state.recentBusy
                      ? SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: providerColor,
                          ),
                        )
                      : const Icon(Icons.refresh_rounded, size: 18),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  String _recentSubtitle(AppState state) {
    if (state.recentBusy) {
      return 'Refreshing...';
    }

    final status = state.recentStatus?.trim().toLowerCase() ?? '';
    if (status.contains('failed') ||
        status.contains('error') ||
        status.contains('unavailable')) {
      return 'Refresh unavailable';
    }

    return '${state.visibleRecent.length} loaded';
  }

  Widget _buildRecentContexts(BuildContext context, AppState state) {
    final scheme = Theme.of(context).colorScheme;
    final providerColor = _providerColor(scheme, state.recentProvider);
    final recent = state.visibleRecent;

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            providerColor.withValues(alpha: 0.10),
            scheme.surfaceContainerLowest.withValues(alpha: 0.38),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(13),
        border: Border.all(
          color: providerColor.withValues(alpha: 0.30),
          width: 0.7,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 6, 10, 0),
            child: Container(
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHigh.withValues(alpha: 0.45),
                borderRadius: BorderRadius.circular(11),
              ),
              child: Row(
                children: [
                  _buildRecentProviderTab(
                    context,
                    state,
                    SessionProvider.codex,
                    state.recentCodex.length,
                  ),
                  _buildRecentProviderTab(
                    context,
                    state,
                    SessionProvider.kimi,
                    state.recentKimi.length,
                  ),
                  _buildRecentProviderTab(
                    context,
                    state,
                    SessionProvider.opencode,
                    state.recentOpencode.length,
                  ),
                  _buildRecentProviderTab(
                    context,
                    state,
                    SessionProvider.qwen,
                    state.recentQwen.length,
                  ),
                ],
              ),
            ),
          ),
          if (state.recentProvider == SessionProvider.codex)
            _buildCodexAccountSection(context, state),
          _buildRecentSectionHeader(context, state),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 9, 10, 10),
            child: recent.isEmpty
                ? Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 14,
                    ),
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerLowest.withValues(
                        alpha: 0.42,
                      ),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      state.recentBusy
                          ? 'Reading recent sessions...'
                          : 'No recent sessions found.',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  )
                : Column(
                    children: recent
                        .map((item) {
                          final alreadySaved = state.hasSession(
                            item.provider,
                            item.id,
                          );
                          final displayTitle = _configuredSessionTitle(
                            state,
                            item.provider,
                            item.id,
                            item.displayTitle,
                          );
                          final itemColor = _providerColor(
                            scheme,
                            item.provider,
                          );
                          return Container(
                            margin: const EdgeInsets.only(bottom: 6),
                            padding: const EdgeInsets.fromLTRB(9, 7, 6, 7),
                            decoration: BoxDecoration(
                              color: scheme.surfaceContainerLowest.withValues(
                                alpha: 0.62,
                              ),
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(
                                color: scheme.outlineVariant.withValues(
                                  alpha: 0.8,
                                ),
                                width: 0.55,
                              ),
                            ),
                            child: Row(
                              children: [
                                Container(
                                  constraints: const BoxConstraints(
                                    minWidth: 72,
                                  ),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 5,
                                  ),
                                  decoration: BoxDecoration(
                                    color: itemColor.withValues(alpha: 0.14),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Text(
                                    item.shortId,
                                    textAlign: TextAlign.center,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context)
                                        .textTheme
                                        .labelSmall
                                        ?.copyWith(
                                          color: scheme.onSurface,
                                          fontWeight: FontWeight.w600,
                                        ),
                                  ),
                                ),
                                const SizedBox(width: 9),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Flexible(
                                            child: Text(
                                              displayTitle,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .bodyMedium
                                                  ?.copyWith(
                                                    fontWeight: FontWeight.w500,
                                                  ),
                                            ),
                                          ),
                                          if (item.isForked) ...[
                                            const SizedBox(width: 5),
                                            _tooltip(
                                              'Forked session',
                                              Icon(
                                                Icons.call_split_rounded,
                                                size: 13,
                                                color: itemColor,
                                              ),
                                            ),
                                          ],
                                        ],
                                      ),
                                      Text(
                                        [
                                          _formatRecentAge(item.updatedAt),
                                          if (item.workDir?.trim().isNotEmpty ==
                                              true)
                                            item.workDir!.trim(),
                                        ].join('  ·  '),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall
                                            ?.copyWith(
                                              color: scheme.onSurfaceVariant,
                                              fontSize: 10.5,
                                            ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 7),
                                _tooltip(
                                  alreadySaved
                                      ? 'Already saved'
                                      : 'Add to Context',
                                  IconButton.filledTonal(
                                    visualDensity: VisualDensity.compact,
                                    onPressed: alreadySaved || state.busy
                                        ? null
                                        : () => _saveRecentContext(
                                            context,
                                            state,
                                            item,
                                          ),
                                    icon: Icon(
                                      alreadySaved
                                          ? Icons.check_rounded
                                          : Icons.add_rounded,
                                      size: 17,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          );
                        })
                        .toList(growable: false),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildContextPanel(BuildContext context, AppState state) {
    final scheme = Theme.of(context).colorScheme;
    final filteredSessionIndices = state.filteredSessionIndices;

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest.withValues(alpha: 0.28),
        border: Border.all(color: scheme.outlineVariant, width: 0.7),
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.035),
            blurRadius: 18,
            offset: const Offset(0, 5),
          ),
        ],
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
                    onReorderItem: state.busy
                        ? (_, _) {}
                        : (oldIndex, adjustedIndex) {
                            final legacyIndex = adjustedIndex >= oldIndex
                                ? adjustedIndex + 1
                                : adjustedIndex;
                            state.reorderItems(oldIndex, legacyIndex);
                          },
                    itemBuilder: (context, index) =>
                        _buildItem(context, state, state.items[index], index),
                  ),
                SliverToBoxAdapter(child: _buildRecentContexts(context, state)),
                const SliverToBoxAdapter(child: SizedBox(height: 16)),
              ],
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
                      onPressed: () => _renameItem(context, state, item, index),
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
    final providerColor = _providerColor(scheme, item.provider);
    final forkCommand = item.forkCommand;
    final group = forceUngrouped ? null : state.groupForItem(index);
    final isGrouped = item.isSession && group != null;
    final groupColor = isGrouped ? _colorFromHex(group.colorHex) : null;
    final resolvedGroupColor = groupColor ?? scheme.outlineVariant;
    final isFirstInGroup = forceUngrouped
        ? true
        : state.isFirstSessionInGroup(index);
    final isLastInGroup = forceUngrouped
        ? true
        : state.isLastSessionInGroup(index);
    final bottomSpacing = isGrouped ? 0.0 : 6.0;
    final borderRadius = isGrouped
        ? BorderRadius.vertical(
            top: Radius.circular(isFirstInGroup ? 0 : 0),
            bottom: Radius.circular(isLastInGroup ? 0 : 0),
          )
        : BorderRadius.circular(11);

    return Container(
      key: ValueKey('session-${item.provider.key}-${item.commandId}'),
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
                      Expanded(
                        child: _tooltip(
                          'Click card to copy resume command',
                          Row(
                            children: [
                              SizedBox(width: isGrouped ? 16 : 8),
                              Container(
                                constraints: const BoxConstraints(
                                  minWidth: 108,
                                ),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 5,
                                ),
                                decoration: BoxDecoration(
                                  color: isGrouped
                                      ? resolvedGroupColor.withValues(
                                          alpha: 0.18,
                                        )
                                      : scheme.primaryContainer.withValues(
                                          alpha: 0.45,
                                        ),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Text(
                                      item.provider.label.toUpperCase(),
                                      style: TextStyle(
                                        color: providerColor,
                                        fontWeight: FontWeight.w800,
                                        fontSize: 9,
                                        letterSpacing: 0.5,
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    Flexible(
                                      child: Text(
                                        item.shortId,
                                        textAlign: TextAlign.center,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        softWrap: false,
                                        style: TextStyle(
                                          fontWeight: FontWeight.w600,
                                          fontSize: 12,
                                          letterSpacing: 0.15,
                                          color: scheme.onSurface,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Align(
                                  alignment: Alignment.centerLeft,
                                  child: _buildNameArea(
                                    context,
                                    state,
                                    item,
                                    index,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      _tooltip(
                        item.supportsFork
                            ? 'Copy fork command'
                            : switch (item.provider) {
                                SessionProvider.kimi =>
                                  'Use /fork command inside Kimi.',
                                SessionProvider.qwen =>
                                  'Use /fork command inside Qwen Code.',
                                _ => 'Fork command unavailable.',
                              },
                        AnimatedOpacity(
                          opacity: item.supportsFork ? 1 : 0.34,
                          duration: const Duration(milliseconds: 120),
                          child: IconButton(
                            onPressed: forkCommand == null
                                ? null
                                : () => _copyCommand(
                                    context,
                                    forkCommand,
                                    'Fork',
                                  ),
                            icon: const Icon(
                              Icons.call_split_rounded,
                              size: 17,
                            ),
                          ),
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
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        centerTitle: false,
        surfaceTintColor: Colors.transparent,
        flexibleSpace: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                scheme.surface,
                scheme.primaryContainer.withValues(alpha: 0.18),
              ],
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
            ),
          ),
        ),
        title: Text(
          'Context',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w600,
            letterSpacing: 0.3,
          ),
        ),
        actions: [
          FilledButton.tonalIcon(
            onPressed: state.busy ? null : () => _addSession(context, state),
            icon: const Icon(Icons.add_link_rounded, size: 17),
            label: const Text('Add Entry'),
          ),
          const SizedBox(width: 6),
          TextButton.icon(
            onPressed: state.busy ? null : () => _addGroup(context, state),
            icon: const Icon(Icons.create_new_folder_outlined, size: 17),
            label: const Text('Add Group'),
          ),
          _tooltip(
            'Settings',
            IconButton(
              onPressed: () => _showSettingsDialog(context, state),
              icon: const Icon(Icons.settings_outlined, size: 20),
            ),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [scheme.surface, scheme.primary.withValues(alpha: 0.025)],
            begin: Alignment.topCenter,
            end: Alignment.bottomRight,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildWarnings(context, state),
            Expanded(child: _buildContextPanel(context, state)),
          ],
        ),
      ),
    );
  }

  Color _providerColor(ColorScheme scheme, SessionProvider provider) {
    if (provider == SessionProvider.codex) {
      return scheme.primary;
    }
    if (provider == SessionProvider.kimi) {
      return scheme.brightness == Brightness.dark
          ? const Color(0xFF76D4DD)
          : const Color(0xFF177F8B);
    }
    if (provider == SessionProvider.opencode) {
      return scheme.brightness == Brightness.dark
          ? const Color(0xFFD7A8FF)
          : const Color(0xFF7A3EAA);
    }
    return scheme.brightness == Brightness.dark
        ? const Color(0xFFFFB15C)
        : const Color(0xFFB85C00);
  }

  Color _colorFromHex(String hex) {
    final normalized = hex.replaceAll('#', '').trim();
    final value = int.tryParse(normalized, radix: 16) ?? 0x83A598;
    return Color(0xFF000000 | value);
  }
}
