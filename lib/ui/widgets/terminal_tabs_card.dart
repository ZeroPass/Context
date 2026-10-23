import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../app/models.dart';
import '../../app/terminal_tabs.dart';
import 'passive_tooltip.dart';

class TerminalTabsCard extends StatelessWidget {
  const TerminalTabsCard({
    super.key,
    required this.monitor,
    required this.saved,
    required this.providerColor,
    this.onOpen,
    this.onClose,
    this.onAlreadyOpen,
  });
  final TerminalTabs? monitor;
  final List<ConfigItem> saved;
  final Color Function(SessionProvider) providerColor;
  final void Function(TerminalTabGroup, TerminalSession?)? onOpen;
  final void Function(TerminalTabGroup)? onClose;
  final VoidCallback? onAlreadyOpen;

  @override
  Widget build(BuildContext context) => monitor == null
      ? _content(context)
      : AnimatedBuilder(
          animation: monitor!,
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
    return Container(
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
          color: scheme.outlineVariant.withValues(alpha: active ? 0.7 : 0.4),
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
                  message: 'Open missing tabs',
                  child: IconButton(
                    key: ValueKey('terminal-open-${group.id}'),
                    constraints: const BoxConstraints.tightFor(
                      width: 28,
                      height: 28,
                    ),
                    padding: EdgeInsets.zero,
                    visualDensity: VisualDensity.compact,
                    onPressed:
                        onOpen == null ||
                            monitor!.opening ||
                            group.members.isEmpty
                        ? null
                        : () => onOpen!(group, null),
                    icon: const Icon(Icons.play_arrow_rounded, size: 17),
                  ),
                ),
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
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
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
        ],
      ),
    );
  }

  Widget _group(BuildContext context, TerminalTabGroup group) =>
      _strip(context, monitor!.orderedSessions(group.members), group: group);

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
                : onOpen == null || monitor!.opening
                ? null
                : () => onOpen!(group, session),
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
