import 'package:flutter/material.dart';

import '../../app/models.dart';
import 'passive_tooltip.dart';

String formatRecentAge(int timestampMs) {
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

class RecentProviderTab extends StatelessWidget {
  const RecentProviderTab({
    super.key,
    required this.provider,
    required this.count,
    required this.selected,
    required this.color,
    required this.onTap,
    this.highlighted = false,
  });
  final SessionProvider provider;
  final int count;
  final bool selected;
  final bool highlighted;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: () => onTap(),
      borderRadius: BorderRadius.circular(9),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: selected
              ? color.withValues(alpha: 0.16)
              : highlighted
              ? color.withValues(alpha: 0.08)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(9),
          border: Border.all(
            color: selected
                ? color.withValues(alpha: 0.55)
                : highlighted
                ? color.withValues(alpha: 0.45)
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
                SessionProvider.muse => Icons.bolt_rounded,
                SessionProvider.zcode => Icons.smart_toy_outlined,
              },
              size: 15,
              color: selected ? color : scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 7),
            Flexible(
              child: Text(
                provider.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: selected ? scheme.onSurface : scheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 6),
            Container(
              constraints: const BoxConstraints(minWidth: 20),
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: selected
                    ? color.withValues(alpha: 0.22)
                    : scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                '$count',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: selected ? scheme.onSurface : scheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class RecentSectionHeader extends StatelessWidget {
  const RecentSectionHeader({
    super.key,
    required this.color,
    required this.subtitle,
    required this.busy,
    required this.onRefresh,
    this.refreshTip = 'Refresh recent sessions',
    this.title = 'Recent sessions',
    this.action,
  });
  final Color color;
  final String subtitle;
  final bool busy;
  final VoidCallback onRefresh;
  final String refreshTip;
  final String title;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 8),
      child: Row(
        children: [
          Container(
            width: 7,
            height: 22,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(999),
            ),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (subtitle.isNotEmpty)
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                      fontSize: 11,
                    ),
                  ),
              ],
            ),
          ),
          ?action,
          PassiveTooltip(
            message: refreshTip,
            child: IconButton(
              onPressed: busy ? null : onRefresh,
              icon: busy
                  ? SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: color,
                      ),
                    )
                  : const Icon(Icons.refresh_rounded, size: 18),
            ),
          ),
        ],
      ),
    );
  }
}

class RecentSessionCard extends StatelessWidget {
  const RecentSessionCard({
    super.key,
    required this.session,
    required this.title,
    required this.color,
    required this.onTap,
    required this.tip,
    this.trailing,
    this.selected = false,
    this.badgeLabel,
  });
  final RecentContext session;
  final String title;
  final Color color;
  final VoidCallback onTap;
  final String tip;
  final Widget? trailing;
  final bool selected;
  final String? badgeLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.fromLTRB(9, 7, 6, 7),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest.withValues(alpha: 0.62),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: selected
              ? color.withValues(alpha: 0.55)
              : scheme.outlineVariant.withValues(alpha: 0.8),
          width: 0.55,
        ),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 40),
        child: Row(
          children: [
            Expanded(
              child: PassiveTooltip(
                message: tip,
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: onTap,
                    child: Row(
                      children: [
                        Container(
                          constraints: const BoxConstraints(minWidth: 72),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            color: color.withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            badgeLabel ?? session.shortId,
                            textAlign: TextAlign.center,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: scheme.onSurface,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        const SizedBox(width: 9),
                        Expanded(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Flexible(
                                    child: Text(
                                      title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: theme.textTheme.bodyMedium
                                          ?.copyWith(
                                            fontWeight: FontWeight.w500,
                                          ),
                                    ),
                                  ),
                                  if (session.isForked) ...[
                                    const SizedBox(width: 5),
                                    PassiveTooltip(
                                      message: 'Forked session',
                                      child: Icon(
                                        Icons.call_split_rounded,
                                        size: 13,
                                        color: color,
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                              Text(
                                [
                                  formatRecentAge(session.updatedAt),
                                  if (session.workDir?.trim().isNotEmpty ==
                                      true)
                                    session.workDir!.trim(),
                                ].join('  ·  '),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: scheme.onSurfaceVariant,
                                  fontSize: 10.5,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            if (trailing != null) ...[const SizedBox(width: 7), trailing!],
          ],
        ),
      ),
    );
  }
}
