import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../app/codex_downgrade.dart';
import '../../app/models.dart';
import 'passive_tooltip.dart';
import 'one_step_picker.dart';

class CodexDowngradeButton extends StatelessWidget {
  const CodexDowngradeButton({
    super.key,
    required this.controller,
    required this.path,
    required this.accounts,
  });
  final CodexResetDowngrade controller;
  final String path;
  final List<CodexAccount> accounts;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) => PassiveTooltip(
      message: controller.status ?? 'Downgrade active Codex tabs once',
      child: IconButton(
        key: const ValueKey('codex-reset-downgrade'),
        onPressed: controller.busy
            ? null
            : () => showDialog<void>(
                context: context,
                builder: (_) => _DowngradeDialog(
                  controller: controller,
                  path: path,
                  accounts: accounts,
                ),
              ),
        isSelected: controller.armed,
        color: controller.armed ? Theme.of(context).colorScheme.primary : null,
        icon: controller.running
            ? const SizedBox(
                width: 15,
                height: 15,
                child: CircularProgressIndicator(strokeWidth: 1.5),
              )
            : Icon(
                controller.armed
                    ? Icons.downloading_rounded
                    : Icons.south_east_rounded,
                size: 17,
              ),
        visualDensity: VisualDensity.compact,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
      ),
    ),
  );
}

class _DowngradeDialog extends StatefulWidget {
  const _DowngradeDialog({
    required this.controller,
    required this.path,
    required this.accounts,
  });
  final CodexResetDowngrade controller;
  final String path;
  final List<CodexAccount> accounts;
  @override
  State<_DowngradeDialog> createState() => _DowngradeDialogState();
}

class _DowngradeDialogState extends State<_DowngradeDialog> {
  late Future<List<CodexModelChoice>> _models;
  late String _model, _effort;
  late CodexDowngradeTrigger _trigger;
  late int _hours;
  late FixedExtentScrollController _hoursController;
  String? _error;
  bool _saving = false;
  @override
  void initState() {
    super.initState();
    _model = widget.controller.model;
    _effort = widget.controller.effort;
    _trigger = widget.controller.trigger;
    _hours = widget.controller.hours;
    _hoursController = FixedExtentScrollController(initialItem: _hours - 1);
    _models = widget.controller.models(widget.path);
  }

  @override
  void dispose() {
    _hoursController.dispose();
    super.dispose();
  }

  Future<void> _save(CodexModelChoice? choice, {bool disarm = false}) async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      if (disarm) {
        await widget.controller.disarm();
      } else {
        await widget.controller.arm(
          widget.path,
          choice!,
          _effort,
          widget.accounts,
          trigger: _trigger,
          hours: _hours,
        );
      }
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = error.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) => FutureBuilder<List<CodexModelChoice>>(
      future: _models,
      builder: (context, snapshot) {
        final choices = snapshot.data ?? const <CodexModelChoice>[];
        final choice = choices.where((entry) => entry.id == _model).firstOrNull;
        final valid = choice?.efforts.contains(_effort) == true;
        return AlertDialog(
          title: const Text('Downgrade once'),
          content: SizedBox(
            width: 360,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('All active Codex tabs.'),
                  const SizedBox(height: 12),
                  SegmentedButton<CodexDowngradeTrigger>(
                    key: const ValueKey('downgrade-trigger'),
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(
                        value: CodexDowngradeTrigger.reset,
                        label: Text('Reset'),
                        icon: Icon(Icons.restart_alt_rounded, size: 16),
                      ),
                      ButtonSegment(
                        value: CodexDowngradeTrigger.hours,
                        label: Text('Hours'),
                        icon: Icon(Icons.schedule_rounded, size: 16),
                      ),
                    ],
                    selected: {_trigger},
                    onSelectionChanged: _saving || widget.controller.busy
                        ? null
                        : (values) => setState(() {
                            _trigger = values.single;
                          }),
                  ),
                  const SizedBox(height: 8),
                  if (_trigger == CodexDowngradeTrigger.reset)
                    const Text('When the active account returns to 100% left.')
                  else ...[
                    Text(
                      'After arming',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 4),
                    DecoratedBox(
                      decoration: BoxDecoration(
                        color: Theme.of(context)
                            .colorScheme
                            .surfaceContainerHighest
                            .withValues(alpha: 0.42),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: SizedBox(
                        height: 96,
                        child: OneStepPicker(
                          key: const ValueKey('downgrade-hours'),
                          controller: _hoursController,
                          itemCount: CodexResetDowngrade.maxHours,
                          child: CupertinoPicker(
                            scrollController: _hoursController,
                            itemExtent: 30,
                            diameterRatio: 1.25,
                            squeeze: 1.15,
                            onSelectedItemChanged: (index) {
                              if (!_saving) {
                                setState(() {
                                  _hours = index + 1;
                                });
                              }
                            },
                            children: [
                              for (
                                var hour = 1;
                                hour <= CodexResetDowngrade.maxHours;
                                hour++
                              )
                                OneStepPickerItem(
                                  child: Center(
                                    child: Text(
                                      '$hour h',
                                      style: Theme.of(
                                        context,
                                      ).textTheme.bodyMedium,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  if (snapshot.connectionState != ConnectionState.done)
                    const LinearProgressIndicator(minHeight: 2)
                  else if (snapshot.hasError)
                    Text(
                      'Could not read models from the running Codex daemon. ${snapshot.error}',
                    )
                  else ...[
                    DropdownButtonFormField<String>(
                      key: ValueKey('downgrade-model-$_model'),
                      initialValue: choice?.id,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'Model'),
                      items: choices
                          .map(
                            (entry) => DropdownMenuItem(
                              value: entry.id,
                              child: Text(
                                entry.name,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: _saving
                          ? null
                          : (id) => setState(() {
                              _model = id!;
                              final selected = choices.firstWhere(
                                (entry) => entry.id == id,
                              );
                              if (!selected.efforts.contains(_effort)) {
                                _effort = selected.defaultEffort;
                              }
                            }),
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      key: ValueKey('downgrade-effort-$_model-$_effort'),
                      initialValue: valid ? _effort : null,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'Thinking'),
                      items: (choice?.efforts ?? const <String>[])
                          .map(
                            (value) => DropdownMenuItem(
                              value: value,
                              child: Text(
                                value == 'xhigh'
                                    ? 'Extra high'
                                    : '${value[0].toUpperCase()}${value.substring(1)}',
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: _saving || choice == null
                          ? null
                          : (value) => setState(() {
                              _effort = value!;
                            }),
                    ),
                    const SizedBox(height: 12),
                    const Text('Fast off'),
                  ],
                  if (widget.controller.status != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      widget.controller.armed &&
                              widget.controller.trigger ==
                                  CodexDowngradeTrigger.hours &&
                              widget.controller.scheduledAt != null
                          ? 'Armed for ${MaterialLocalizations.of(context).formatMediumDate(widget.controller.scheduledAt!)} at ${MaterialLocalizations.of(context).formatTimeOfDay(TimeOfDay.fromDateTime(widget.controller.scheduledAt!))}.'
                          : widget.controller.status!,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            if (widget.controller.armed)
              TextButton(
                onPressed: _saving ? null : () => _save(null, disarm: true),
                child: const Text('Disarm'),
              ),
            TextButton(
              onPressed: _saving ? null : () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: valid && !_saving && !widget.controller.busy
                  ? () => _save(choice)
                  : null,
              child: Text(widget.controller.armed ? 'Update once' : 'Arm once'),
            ),
          ],
        );
      },
    ),
  );
}
