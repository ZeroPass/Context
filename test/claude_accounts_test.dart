import 'dart:async';

import 'package:context/app/app_state.dart';
import 'package:context/app/claude_accounts.dart';
import 'package:context/app/codex_downgrade.dart';
import 'package:context/app/models.dart';
import 'package:context/main.dart';
import 'package:context/ui/widgets/recent_sessions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

final accountA = List.filled(64, 'a').join();
final accountB = List.filled(64, 'b').join();
final sonnet = CodexModelChoice.fromJson({
  'id': 'claude-sonnet-5-5',
  'name': 'Sonnet 5.5',
  'efforts': ['low', 'medium', 'high', 'xhigh'],
  'default_effort': 'high',
});
const path = r'\\wsl.localhost\Ubuntu\home\me\Context\sessions.md';

Map<String, dynamic> reading(
  DateTime now, {
  String? key,
  double used = 25,
  int? reset,
  String? error,
  bool weekly = true,
}) => {
  'accounts': [
    {
      'account_key': key ?? accountA,
      'name': 'reader@example.invalid',
      'tier': 'max',
      'weekly': error != null || !weekly
          ? null
          : {
              'used_percent': used,
              'reset_at':
                  reset ??
                  now.add(const Duration(days: 6)).millisecondsSinceEpoch,
            },
      'five_hour': error != null
          ? null
          : {
              'used_percent': 90,
              'reset_at': now
                  .add(const Duration(hours: 2))
                  .millisecondsSinceEpoch,
            },
      'observed_at': error == null ? now.millisecondsSinceEpoch : null,
      'usage_error': error,
    },
  ],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late DateTime now;
  late SharedPreferences prefs;
  setUp(() async {
    now = DateTime.utc(2026, 10, 27, 12);
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  test(
    'weekly and 5h remain separate; refresh is coalesced and throttled',
    () async {
      var calls = 0;
      final controller = ClaudeAccounts(
        now: () => now,
        request: (_, request) async {
          expect(request['provider'], 'claude');
          calls++;
          return reading(now);
        },
      )..restore(prefs);
      controller.follow(path);
      await controller.refresh();
      expect(controller.current!.weeklyUsed, 25);
      expect(controller.current!.fiveHourUsed, 90);
      expect(controller.pacingAccounts.single.weeklyUsedPercent, 25);
      await controller.refresh(force: true);
      expect(calls, 1);
      now = now.add(const Duration(minutes: 1));
      await controller.refresh(force: true);
      expect(calls, 2);
      now = now.add(const Duration(minutes: 1));
      await controller.refresh();
      expect(calls, 2);
      controller.dispose();
    },
  );

  test(
    'network errors freeze same identity; different login never inherits quota',
    () async {
      var value = reading(now, used: 100);
      final controller = ClaudeAccounts(
        now: () => now,
        request: (_, _) async => value,
      )..restore(prefs);
      controller.follow(path);
      await controller.refresh();
      now = now.add(const Duration(minutes: 6));
      value = reading(now, error: 'Offline');
      await controller.refresh();
      expect(controller.current!.weeklyUsed, 100);
      expect(controller.current!.error, 'Offline');
      now = now.add(const Duration(minutes: 6));
      value = reading(now, key: accountB, error: 'Login rejected');
      await controller.refresh();
      expect(controller.current!.key, accountB);
      expect(controller.current!.weeklyUsed, isNull);
      controller.dispose();
    },
  );

  test(
    'manual reset saves during refresh, survives restart, expires and clears',
    () async {
      Completer<Map<String, dynamic>>? pending;
      final controller = ClaudeAccounts(
        now: () => now,
        request: (_, _) => pending?.future ?? Future.value(reading(now)),
      )..restore(prefs);
      controller.follow(path);
      await controller.refresh();
      now = now.add(const Duration(minutes: 6));
      pending = Completer();
      final refresh = controller.refresh();
      final manual = now.add(const Duration(hours: 4));
      expect(controller.busy, true);
      await controller.setManualReset(manual);
      pending.complete(reading(now));
      await refresh;
      expect(controller.manualResetAt, manual.millisecondsSinceEpoch);
      controller.dispose();
      final restored = ClaudeAccounts(
        now: () => now,
        request: (_, _) async => reading(now),
      )..restore(prefs);
      restored.follow(path);
      expect(restored.manualResetAt, manual.millisecondsSinceEpoch);
      await restored.setManualReset(null);
      expect(restored.manualResetAt, isNull);
      await restored.setManualReset(manual);
      final apiReset = restored.current!.weeklyReset;
      now = manual.add(const Duration(seconds: 1));
      restored.follow(path);
      expect(restored.manualResetAt, isNull);
      expect(restored.current!.weeklyReset, apiReset);
      restored.dispose();
    },
  );

  test(
    'missing weekly reading is not converted into zero or a 5h weekly window',
    () async {
      final controller = ClaudeAccounts(
        request: (_, _) async => reading(now, weekly: false),
      )..restore(prefs);
      controller.follow(path);
      await controller.refresh();
      expect(controller.current!.weeklyUsed, isNull);
      expect(controller.pacingAccounts.single.hasWeeklyUsage, false);
      await expectLater(
        controller.downgrade.arm(
          path,
          sonnet,
          'high',
          controller.pacingAccounts,
        ),
        throwsStateError,
      );
      controller.dispose();
    },
  );

  test(
    'timed downgrade is once, defaults-only, bound to the armed identity',
    () async {
      final calls = <Map<String, dynamic>>[];
      final controller = ClaudeAccounts(
        now: () => now,
        request: (_, request) async {
          calls.add(request);
          if (request['action'] == 'apply') {
            return {
              'defaults_saved': true,
              'commands': [
                '/model claude-sonnet-5-5',
                '/effort high',
                '/fast off',
              ],
            };
          }
          return reading(now);
        },
      )..restore(prefs);
      controller.follow(path);
      await controller.refresh();
      await controller.downgrade.arm(
        path,
        sonnet,
        'high',
        controller.pacingAccounts,
        trigger: CodexDowngradeTrigger.hours,
      );
      now = now.add(const Duration(hours: 2));
      controller.downgrade.checkDeadline();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      final applies = calls.where((r) => r['action'] == 'apply').toList();
      expect(applies, hasLength(1));
      expect(applies.single['account_key'], accountA);
      expect(controller.downgrade.phase, 'done');
      expect(
        controller.downgrade.status,
        contains('Running tabs are unchanged'),
      );
      controller.downgrade.checkDeadline();
      expect(calls.where((r) => r['action'] == 'apply'), hasLength(1));
      expect(prefs.getString(CodexResetDowngrade.preferenceKey), isNull);
      controller.dispose();
    },
  );

  test(
    'five-hour reset and local reset do not trigger weekly downgrade',
    () async {
      var value = reading(now, used: 40);
      var applies = 0;
      final controller = ClaudeAccounts(
        now: () => now,
        request: (_, request) async {
          if (request['action'] == 'apply') {
            applies++;
            return {'defaults_saved': true, 'commands': <String>[]};
          }
          return value;
        },
      )..restore(prefs);
      controller.follow(path);
      await controller.refresh();
      await controller.downgrade.arm(
        path,
        sonnet,
        'high',
        controller.pacingAccounts,
      );
      final weeklyReset = controller.current!.weeklyReset!;
      await controller.setManualReset(now.add(const Duration(hours: 1)));
      now = now.add(const Duration(hours: 3));
      value = reading(now, used: 40, reset: weeklyReset);
      (value['accounts'] as List).single['five_hour'] = {
        'used_percent': 0,
        'reset_at': now.add(const Duration(hours: 5)).millisecondsSinceEpoch,
      };
      await controller.refresh();
      expect(applies, 0);
      now = now.add(const Duration(minutes: 6));
      value = reading(
        now,
        used: 0,
        reset: weeklyReset + const Duration(days: 7).inMilliseconds,
      );
      await controller.refresh();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(applies, 1);
      expect(controller.downgrade.phase, 'done');
      controller.dispose();
    },
  );

  test(
    'empty-window timestamp drift cannot masquerade as a quota reset',
    () async {
      var value = reading(now, used: 0);
      var applies = 0;
      final controller = ClaudeAccounts(
        now: () => now,
        request: (_, request) async {
          if (request['action'] == 'apply') applies++;
          return value;
        },
      )..restore(prefs);
      controller.follow(path);
      await controller.refresh();
      await controller.downgrade.arm(
        path,
        sonnet,
        'high',
        controller.pacingAccounts,
      );
      now = now.add(const Duration(minutes: 6));
      value = reading(now, used: 0);
      await controller.refresh();
      expect(applies, 0);
      expect(controller.downgrade.armed, true);
      controller.dispose();
    },
  );

  test(
    'an armed timer retains the original login rather than targeting a replacement',
    () async {
      var value = reading(now);
      String? attemptedKey;
      final controller = ClaudeAccounts(
        now: () => now,
        request: (_, request) async {
          if (request['action'] == 'apply') {
            attemptedKey = request['account_key'] as String?;
            throw StateError('Claude login changed.');
          }
          return value;
        },
      )..restore(prefs);
      controller.follow(path);
      await controller.refresh();
      await controller.downgrade.arm(
        path,
        sonnet,
        'high',
        controller.pacingAccounts,
        trigger: CodexDowngradeTrigger.hours,
      );
      now = now.add(const Duration(minutes: 6));
      value = reading(now, key: accountB);
      await controller.refresh();
      now = now.add(const Duration(hours: 2));
      controller.downgrade.checkDeadline();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(attemptedKey, accountA);
      expect(controller.downgrade.phase, 'failed');
      controller.dispose();
    },
  );

  test('workspace changes reject outstanding account replies', () async {
    final pending = Completer<Map<String, dynamic>>();
    final controller = ClaudeAccounts(request: (_, _) => pending.future)
      ..restore(prefs);
    controller.follow(path);
    final refresh = controller.refresh();
    controller.follow('/different/home/sessions.md');
    pending.complete(reading(now));
    await refresh;
    expect(controller.current, isNull);
    expect(controller.busy, false);
    controller.dispose();
  });

  testWidgets(
    'Claude tab shows one account, pace, both resets and isolated controls',
    (tester) async {
      final controller = ClaudeAccounts(
        request: (_, _) async => reading(DateTime.now()),
      )..restore(prefs);
      controller.follow(path);
      await controller.refresh();
      final state =
          AppState.forTesting(
              sendRequest: (_) {},
              preferences: prefs,
              claude: controller,
            )
            ..sessionsMarkdownPath = path
            ..recentProvider = SessionProvider.claude;
      tester.view.physicalSize = const Size(1000, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        ChangeNotifierProvider.value(value: state, child: const ContextView()),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('claude-accounts-section')),
      );
      expect(find.text('Claude account'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(RecentProviderTab),
          matching: find.text('Claude'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byType(RecentProviderTab),
          matching: find.text('Claude Code'),
        ),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('claude-account-card')), findsOneWidget);
      expect(find.textContaining('75% left'), findsOneWidget);
      expect(find.textContaining('5h: 10% left'), findsOneWidget);
      expect(find.byKey(const ValueKey('claude-manual-reset')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('claude-reset-downgrade')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('codex-reset-downgrade')), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
    },
  );
}
