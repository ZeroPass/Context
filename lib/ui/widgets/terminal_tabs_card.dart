import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../app/models.dart';
import '../../app/terminal_tabs.dart';
import '../../app/terminal_schedules.dart';
import '../../app/codex_downgrade.dart';
import 'passive_tooltip.dart';

class TerminalTabsCard extends StatefulWidget {
  const TerminalTabsCard({
    super.key,
    required this.monitor,
    required this.saved,
    required this.providerColor,
    this.onOpen,
    this.onClose,
    this.onAlreadyOpen,
    this.schedules,
    this.downgrade,
    this.path = '',
    this.onKeepAlive,
    this.onEditDowngrade,
  });
  final TerminalTabs? monitor;
  final List<ConfigItem> saved;
  final Color Function(SessionProvider) providerColor;
  final void Function(TerminalTabGroup, TerminalSession?)? onOpen;
  final void Function(TerminalTabGroup)? onClose;
  final VoidCallback? onAlreadyOpen;
  final TerminalSchedules? schedules;
  final CodexResetDowngrade? downgrade;
  final String path;
  final void Function(TerminalTabGroup, bool)? onKeepAlive;
  final VoidCallback? onEditDowngrade;

  @override
  State<TerminalTabsCard> createState() => _TerminalTabsCardState();
}

class _TerminalTabsCardState extends State<TerminalTabsCard> {
  String? _expanded, _scope;
  TerminalTabs? get monitor => widget.monitor;
  List<ConfigItem> get saved => widget.saved;
  Color Function(SessionProvider) get providerColor => widget.providerColor;
  void Function(TerminalTabGroup, TerminalSession?)? get onOpen =>
      widget.onOpen;
  void Function(TerminalTabGroup)? get onClose => widget.onClose;
  VoidCallback? get onAlreadyOpen => widget.onAlreadyOpen;

  void _select(TerminalTabGroup group, [TerminalSession? session]) {
    setState(() {
      if (_expanded == group.id && _scope == session?.reference) {
        _expanded = null;
        _scope = null;
      } else {
        _expanded = group.id;
        _scope = session?.reference;
      }
    });
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([monitor, widget.schedules, widget.downgrade]),
    builder: (context, _) => _content(context),
  );

  Widget _content(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final sessions = monitor?.sessions ?? const <TerminalSession>[];
    final groups = monitor?.groups ?? const <TerminalTabGroup>[];
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(
                'Terminal tabs',
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(width: 8),
              Text(
                '${sessions.length}',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
              const Spacer(),
              PassiveTooltip(
                message: 'Refresh Terminal tabs',
                child: IconButton(
                  visualDensity: VisualDensity.compact,
                  onPressed: monitor == null || monitor!.busy
                      ? null
                      : () => monitor!.refresh(force: true),
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                ),
              ),
            ],
          ),
          SizedBox(
            height: 5,
            child: monitor?.busy == true || monitor?.opening == true
                ? const Align(
                    alignment: Alignment.topCenter,
                    child: LinearProgressIndicator(minHeight: 2),
                  )
                : null,
          ),
          if (monitor?.error != null || monitor?.groupsError != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 7),
              child: Text(
                monitor!.groupsError ?? monitor!.error!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: scheme.error),
              ),
            ),
          if (widget.schedules?.error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 7),
              child: Text(
                widget.schedules!.error!,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: scheme.error),
              ),
            ),
          if (sessions.isEmpty && groups.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 7),
              child: Text(
                monitor?.busy == true
                    ? 'Reading open sessions...'
                    : 'No running coding sessions found.',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
          for (final group in groups)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: _group(context, group),
            ),
          if (monitor?.ungroupedSessions.isNotEmpty == true)
            _strip(context, monitor!.ungroupedSessions),
        ],
      ),
    );
  }

  Widget _strip(
    BuildContext context,
    List<TerminalSession> sessions, {
    TerminalTabGroup? group,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final active = group == null || monitor!.isActive(group);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(11),
        onTap: group == null ? null : () => _select(group),
        child: Container(
          key: group == null
              ? const ValueKey('terminal-live-strip')
              : ValueKey('terminal-group-${group.id}'),
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest.withValues(
              alpha: active ? 0.14 : 0.06,
            ),
            borderRadius: BorderRadius.circular(11),
            border: Border.all(
              color: scheme.outlineVariant.withValues(
                alpha: active ? 0.7 : 0.4,
              ),
              width: 0.7,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  PassiveTooltip(
                    message: 'Ubuntu',
                    child: CustomPaint(
                      size: const Size(14, 14),
                      painter: _UbuntuMark(scheme.onSurfaceVariant),
                    ),
                  ),
                  const SizedBox(width: 7),
                  Expanded(
                    child: GestureDetector(
                      onDoubleTap: group == null
                          ? null
                          : () => _rename(context, group),
                      child: Text(
                        group?.name ?? 'Open tabs',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ),
                  if (group != null) ...[
                    Text(
                      active ? 'Open' : 'Saved',
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
                      ),
                    ),
                    const SizedBox(width: 3),
                    PassiveTooltip(
                      message: active
                          ? 'Close Terminal window'
                          : 'Delete saved group',
                      child: IconButton(
                        key: ValueKey('terminal-close-${group.id}'),
                        constraints: const BoxConstraints.tightFor(
                          width: 28,
                          height: 28,
                        ),
                        padding: EdgeInsets.zero,
                        visualDensity: VisualDensity.compact,
                        onPressed: onClose == null || monitor!.opening
                            ? null
                            : () => onClose!(group),
                        icon: const Icon(Icons.close_rounded, size: 15),
                      ),
                    ),
                  ] else
                    const SizedBox(height: 28),
                ],
              ),
              if (sessions.isEmpty)
                Text(
                  'No coding sessions in this window.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                )
              else
                LayoutBuilder(
                  builder: (context, constraints) {
                    final width = ((constraints.maxWidth - 18) / 4).clamp(
                      0.0,
                      104.0,
                    );
                    return Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final session in sessions)
                          SizedBox(
                            width: width,
                            child: _item(context, session, group: group),
                          ),
                      ],
                    );
                  },
                ),
              if (group != null)
                AnimatedSize(
                  duration: const Duration(milliseconds: 170),
                  alignment: Alignment.topCenter,
                  child: _expanded == group.id
                      ? _tasks(context, group)
                      : const SizedBox.shrink(),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _group(BuildContext context, TerminalTabGroup group) =>
      _strip(context, monitor!.orderedSessions(group.members), group: group);

  Widget _tasks(BuildContext context, TerminalTabGroup group) {
    final scheme = Theme.of(context).colorScheme;
    final session = group.members
        .where((s) => s.reference == _scope)
        .firstOrNull;
    final all = _scope == null;
    final job = widget.schedules?.jobFor(group.id);
    final downgrade = widget.downgrade;
    final hasDowngrade =
        downgrade?.appliesTo(widget.path) == true &&
        (all
            ? group.members.any((s) => s.provider == SessionProvider.codex)
            : session?.provider == SessionProvider.codex);
    String clock(DateTime d) =>
        '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
    // Own the expanded panel's taps; they must not toggle the parent card.
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {},
      child: Padding(
        key: ValueKey('terminal-tasks-${group.id}'),
        padding: const EdgeInsets.only(top: 9),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Divider(
              height: 1,
              color: scheme.outlineVariant.withValues(alpha: 0.4),
            ),
            const SizedBox(height: 5),
            Row(
              children: [
                Expanded(
                  child: Text(
                    all
                        ? 'All tabs · Tasks'
                        : '${session?.provider.label ?? 'Tab'} ${session?.shortId ?? ''} · Tasks',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                TextButton.icon(
                  key: ValueKey('terminal-restore-${group.id}'),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 7),
                  ),
                  onPressed:
                      onOpen == null ||
                          monitor!.opening ||
                          (!all && session == null)
                      ? null
                      : () => onOpen!(group, all ? null : session),
                  icon: const Icon(Icons.open_in_new_rounded, size: 14),
                  label: Text(all ? 'Restore missing' : 'Open tab'),
                ),
              ],
            ),
            if (all) ...[
              Row(
                children: [
                  const Icon(Icons.favorite_border_rounded, size: 16),
                  const SizedBox(width: 7),
                  Expanded(
                    child: PassiveTooltip(
                      message:
                          'Every 15 min while Context is running. Restores missing tabs; continues confirmed temporary Codex failures. Usage errors wait for available quota. Closing the whole window stops this task.',
                      child: Text(
                        'Keep Alive',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ),
                  Text(
                    '15 min',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(width: 6),
                  SizedBox(
                    height: 29,
                    child: Switch(
                      key: ValueKey('terminal-keep-alive-${group.id}'),
                      value: job?.enabled == true,
                      onChanged:
                          widget.onKeepAlive == null ||
                              (job?.enabled != true &&
                                  !monitor!.isActive(group))
                          ? null
                          : (value) => widget.onKeepAlive!(group, value),
                    ),
                  ),
                ],
              ),
              if (job != null)
                Padding(
                  padding: const EdgeInsets.only(top: 3, bottom: 4),
                  child: Text(
                    '${job.status}${job.enabled ? ' Next ${clock(job.nextCheck)}.' : ''}',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
            ] else if (!hasDowngrade)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  'No tasks scheduled for this tab.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            if (hasDowngrade)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.south_east_rounded, size: 16),
                title: Text(
                  'Downgrade · ${downgrade!.model} · ${downgrade.effort}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                subtitle: Text(
                  'All Codex tabs · ${downgrade.status ?? 'Armed'}',
                  style: Theme.of(context).textTheme.labelSmall,
                ),
                trailing: const Icon(Icons.chevron_right_rounded, size: 16),
                onTap: widget.onEditDowngrade,
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _rename(BuildContext context, TerminalTabGroup group) async {
    var value = group.name;
    final name = await showDialog<String>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Group name'),
        content: TextFormField(
          initialValue: group.name,
          autofocus: true,
          maxLength: 80,
          onChanged: (v) => value = v,
          onFieldSubmitted: (v) => Navigator.pop(dialog, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, value),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (name != null && name.trim().isNotEmpty) {
      await monitor!.renameGroup(group.id, name);
    }
  }

  Widget _item(
    BuildContext context,
    TerminalSession session, {
    TerminalTabGroup? group,
  }) {
    final tab = monitor!.tabFor(session);
    final configured = saved
        .where(
          (s) =>
              s.isSession &&
              session.id.isNotEmpty &&
              s.provider == session.provider &&
              s.commandId == session.id,
        )
        .firstOrNull;
    final compactProvider = switch (session.provider) {
      SessionProvider.claude => 'Claude',
      SessionProvider.qwen => 'Qwen',
      _ => session.provider.label,
    };
    final title =
        configured?.displayName ?? '$compactProvider ${session.shortId}';
    final scheme = Theme.of(context).colorScheme;
    final color = providerColor(session.provider);
    final selected = tab?['selected'] == true;
    final open = monitor!.isOpen(session);
    final label = Text(
      title,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      textAlign: TextAlign.center,
      style: Theme.of(context).textTheme.bodySmall?.copyWith(
        color: selected
            ? scheme.onSurface
            : scheme.onSurfaceVariant.withValues(alpha: open ? 1 : 0.65),
      ),
    );
    return PassiveTooltip(
      key: ValueKey('terminal-session-${session.identity}'),
      message:
          '$compactProvider\n${session.id.isEmpty ? 'Session ID unavailable' : session.id}',
      child: Semantics(
        selected: selected,
        label: '${session.provider.label} ${session.id}',
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: group == null
                ? onAlreadyOpen
                : () => _select(group, session),
            borderRadius: BorderRadius.circular(7),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 7),
              decoration: BoxDecoration(
                color: selected
                    ? color.withValues(alpha: 0.16)
                    : scheme.surfaceContainerHighest.withValues(
                        alpha: open ? 0.3 : 0.1,
                      ),
                borderRadius: BorderRadius.circular(7),
                border: Border.all(
                  color: selected
                      ? color.withValues(alpha: 0.55)
                      : Colors.transparent,
                  width: 0.8,
                ),
              ),
              child: configured != null
                  ? label
                  : FittedBox(fit: BoxFit.scaleDown, child: label),
            ),
          ),
        ),
      ),
    );
  }
}

class _UbuntuMark extends CustomPainter {
  const _UbuntuMark(this.color);
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.shortestSide * 0.29;
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.shortestSide * 0.13;
    final dot = Paint()..color = color;
    for (var i = 0; i < 3; i++) {
      final angle = -math.pi / 2 + i * 2 * math.pi / 3;
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        angle + 0.32,
        2 * math.pi / 3 - 0.64,
        false,
        stroke,
      );
      canvas.drawCircle(
        center +
            Offset(math.cos(angle), math.sin(angle)) * size.shortestSide * 0.4,
        size.shortestSide * 0.1,
        dot,
      );
    }
  }

  @override
  bool shouldRepaint(_UbuntuMark oldDelegate) => color != oldDelegate.color;
}
