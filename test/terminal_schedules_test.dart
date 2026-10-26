import 'dart:convert';

import 'package:context/app/terminal_schedules.dart';
import 'package:context/app/terminal_tabs.dart';
import 'package:context/app/codex_downgrade.dart';
import 'package:context/ui/widgets/terminal_tabs_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'terminal_tabs_test.dart' show groupPath, windowSnapshot;

void main() {
  testWidgets('deadline fires without foreground discovery or manual refresh', (
    tester,
  ) async {
    var now = DateTime(2026, 10, 26, 12);
    final tabs = TerminalTabs(
      reader: (_) async => windowSnapshot([1]),
      now: () => now,
    );
    tabs.follow(groupPath, active: true);
    await tester.pump();
    tabs.follow(groupPath, active: false);
    var requests = 0;
    final schedules = TerminalSchedules(
      monitor: () => tabs,
      now: () => now,
      request: (_, _) async {
        requests++;
        return {'sessions': []};
      },
    );
    schedules.follow(groupPath);
    await schedules.setEnabled(tabs.groups.single, true);
    now = now.add(TerminalSchedules.interval);
    await tester.pump(TerminalSchedules.interval);
    await tester.pump();
    expect(requests, 1);
    expect(schedules.checking, false);
    schedules.dispose();
    tabs.dispose();
  });

  testWidgets('multiple windows never restore into an ambiguous MRU window', (
    tester,
  ) async {
    var now = DateTime(2026, 10, 26, 12);
    var data = windowSnapshot([1, 2]);
    final tabs = TerminalTabs(reader: (_) async => data, now: () => now);
    tabs.follow(groupPath, active: true);
    await tester.pump();
    final group = tabs.groups.single;
    final schedules = TerminalSchedules(
      monitor: () => tabs,
      now: () => now,
      request: (_, _) async => {'sessions': []},
      launch: (_, _, _) async => throw StateError('must not launch'),
    );
    schedules.follow(groupPath);
    await schedules.setEnabled(group, true);
    data = {
      ...windowSnapshot([1]),
      'windows': [
        ...(windowSnapshot([1])['windows'] as List),
        ...(windowSnapshot([3], window: 2)['windows'] as List),
      ],
      'sessions': [
        ...(windowSnapshot([1])['sessions'] as List),
        ...(windowSnapshot([3], window: 2)['sessions'] as List),
      ],
    };
    now = now.add(TerminalSchedules.interval);
    await schedules.checkDue();
    expect(
      schedules.jobFor(group.id)!.status,
      contains('Restore missing tabs manually'),
    );
    schedules.dispose();
    tabs.dispose();
  });

  testWidgets('Keep Alive is whole-group only; inactive downgrade is hidden', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final tabs = TerminalTabs(reader: (_) async => windowSnapshot([1]));
    tabs.follow(groupPath, active: true);
    await tester.pump();
    final group = tabs.groups.single;
    final policy = CodexResetDowngrade(request: (_, _) async => {'models': []})
      ..restore(prefs);
    policy.follow(groupPath);
    var toggles = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TerminalTabsCard(
            monitor: tabs,
            saved: const [],
            providerColor: (_) => Colors.amber,
            downgrade: policy,
            path: groupPath,
            onKeepAlive: (_, _) => toggles++,
          ),
        ),
      ),
    );
    await tester.tapAt(
      tester.getBottomRight(
            find.byKey(ValueKey('terminal-group-${group.id}')),
          ) -
          const Offset(3, 3),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Downgrade ·'), findsNothing);
    await tester.tap(find.byKey(ValueKey('terminal-keep-alive-${group.id}')));
    expect(toggles, 1);
    final model = CodexModelChoice.fromJson({
      'id': 'gpt-6.1-sol',
      'name': 'Sol',
      'efforts': ['high'],
      'default_effort': 'high',
    });
    await policy.arm(
      groupPath,
      model,
      'high',
      const [],
      trigger: CodexDowngradeTrigger.hours,
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Downgrade ·'), findsOneWidget);
    expect(find.textContaining('All Codex tabs ·'), findsOneWidget);
    await tester.tap(find.text('Codex on-1'));
    await tester.pumpAndSettle();
    expect(find.text('Keep Alive'), findsNothing);
    expect(find.textContaining('Downgrade ·'), findsOneWidget);
    await policy.disarm();
    await tester.pumpAndSettle();
    expect(find.textContaining('Downgrade ·'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    policy.dispose();
    tabs.dispose();
  });
  testWidgets(
    'off by default; checks once after 15 min, persists and stops on close',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      var now = DateTime(2026, 10, 26, 12);
      var data = windowSnapshot([1]);
      final tabs = TerminalTabs(reader: (_) async => data, now: () => now);
      tabs.follow(groupPath, active: true);
      await tester.pump();
      var requests = 0;
      final schedules = TerminalSchedules(
        monitor: () => tabs,
        now: () => now,
        request: (_, payload) async {
          requests++;
          return {
            'sessions': [
              {'id': 'session-1', 'state': 'untouched'},
            ],
          };
        },
      );
      schedules.restore(prefs);
      schedules.follow(groupPath);
      expect(schedules.jobFor(tabs.groups.single.id), isNull);
      await schedules.setEnabled(tabs.groups.single, true);
      now = now.add(const Duration(minutes: 14));
      await schedules.checkDue();
      expect(requests, 0);
      now = now.add(const Duration(minutes: 1));
      await schedules.checkDue();
      expect(requests, 1);
      expect(
        schedules.jobFor(tabs.groups.single.id)!.nextCheck,
        now.add(TerminalSchedules.interval),
      );
      expect(
        jsonDecode(prefs.getString(TerminalSchedules.preferenceKey)!)['jobs'],
        hasLength(1),
      );
      data = windowSnapshot([], present: false);
      now = now.add(TerminalSchedules.interval);
      await schedules.checkDue();
      expect(schedules.jobFor(tabs.groups.single.id)!.enabled, false);
      expect(requests, 1);
      schedules.dispose();
      tabs.dispose();
    },
  );

  testWidgets(
    'missing members survive live shrink and restore into checked existing window',
    (tester) async {
      var now = DateTime(2026, 10, 26, 12);
      var data = windowSnapshot([1, 2]);
      final tabs = TerminalTabs(reader: (_) async => data, now: () => now);
      tabs.follow(groupPath, active: true);
      await tester.pump();
      final group = tabs.groups.single;
      final launches = <String>[];
      final schedules = TerminalSchedules(
        monitor: () => tabs,
        now: () => now,
        launch: (session, window, path) async {
          expect(window.key, group.window.key);
          expect(path, groupPath);
          launches.add(session.id);
          return true;
        },
        request: (_, _) async => {'sessions': []},
      );
      schedules.follow(groupPath);
      await schedules.setEnabled(group, true);
      data = windowSnapshot([1]);
      await tabs.refresh(force: true);
      now = now.add(const Duration(seconds: 3));
      await tabs.refresh(force: true);
      expect(tabs.groups.single.members, hasLength(1));
      now = now.add(TerminalSchedules.interval);
      await schedules.checkDue();
      expect(launches, ['session-2']);
      expect(schedules.jobFor(group.id)!.group.members, hasLength(2));
      schedules.dispose();
      tabs.dispose();
    },
  );

  testWidgets(
    'retry is claimed before dispatch and never replayed after uncertain result',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      var now = DateTime(2026, 10, 26, 12);
      final tabs = TerminalTabs(
        reader: (_) async => windowSnapshot([1]),
        now: () => now,
      );
      tabs.follow(groupPath, active: true);
      await tester.pump();
      var recovered = 0;
      Future<Map<String, dynamic>> request(
        String _,
        Map<String, dynamic> payload,
      ) async {
        if (payload['action'] == 'status') {
          return {
            'sessions': [
              {'id': 'session-1', 'state': 'retryable', 'turn_id': 'failed-1'},
            ],
          };
        }
        recovered++;
        expect(
          jsonDecode(
            prefs.getString(TerminalSchedules.preferenceKey)!,
          )['claims'],
          hasLength(1),
        );
        throw StateError('reply lost');
      }

      var schedules = TerminalSchedules(
        monitor: () => tabs,
        now: () => now,
        request: request,
      );
      schedules.restore(prefs);
      schedules.follow(groupPath);
      await schedules.setEnabled(tabs.groups.single, true);
      now = now.add(TerminalSchedules.interval);
      await schedules.checkDue();
      expect(recovered, 1);
      schedules.dispose();
      schedules = TerminalSchedules(
        monitor: () => tabs,
        now: () => now,
        request: request,
      );
      schedules.restore(prefs);
      schedules.follow(groupPath);
      now = now.add(TerminalSchedules.interval);
      await schedules.checkDue();
      expect(recovered, 1);
      await schedules.stop(tabs.groups.single.id);
      now = now.add(TerminalSchedules.interval);
      await schedules.checkDue();
      expect(recovered, 1);
      schedules.dispose();
      tabs.dispose();
    },
  );

  testWidgets(
    'incomplete discovery, other workspace and usage wait send no recovery',
    (tester) async {
      var now = DateTime(2026, 10, 26, 12);
      var data = windowSnapshot([1]);
      final tabs = TerminalTabs(reader: (_) async => data, now: () => now);
      tabs.follow(groupPath, active: true);
      await tester.pump();
      final actions = <String>[];
      final schedules = TerminalSchedules(
        monitor: () => tabs,
        now: () => now,
        request: (_, p) async {
          actions.add(p['action'] as String);
          return {
            'sessions': [
              {'id': 'session-1', 'state': 'waiting_usage'},
            ],
          };
        },
        launch: (_, _, _) async => throw StateError('must not launch'),
      );
      schedules.follow(groupPath);
      await schedules.setEnabled(tabs.groups.single, true);
      schedules.follow('another-workspace');
      now = now.add(TerminalSchedules.interval);
      await schedules.checkDue();
      expect(actions, isEmpty);
      schedules.follow(groupPath);
      await schedules.checkDue();
      expect(actions, ['status']);
      expect(
        schedules.jobFor(tabs.groups.single.id)!.status,
        contains('waiting for usage'),
      );
      data = {
        ...windowSnapshot([1]),
        'warnings': ['Window inventory is incomplete.'],
        'windows_complete': false,
      };
      now = now.add(TerminalSchedules.interval);
      await schedules.checkDue();
      expect(actions, ['status']);
      schedules.dispose();
      tabs.dispose();
    },
  );
}
