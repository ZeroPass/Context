import 'dart:convert';

import 'package:context/app/codex_downgrade.dart';
import 'package:context/app/models.dart';
import 'package:context/ui/widgets/codex_downgrade_button.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const path = r'\\wsl.localhost\Ubuntu-24.04\home\user\Context\context.md';
const epoch = 1800000000000;
final sol = CodexModelChoice.fromJson({
  'id': 'gpt-6.1-sol',
  'name': 'GPT-6.1 Sol',
  'efforts': ['low', 'high'],
  'default_effort': 'low',
});
const account = CodexAccount(
  slot: '1',
  name: 'one',
  weeklyUsedPercent: 40,
  weeklyResetAt: epoch + 604800000,
  usageObservedAt: epoch - 1,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late DateTime now;
  late SharedPreferences prefs;
  late List<Map<String, dynamic>> requests;
  late CodexResetDowngrade policy;

  Future<Map<String, dynamic>> request(
    String _,
    Map<String, dynamic> payload,
  ) async {
    requests.add(payload);
    if (payload['action'] == 'models') {
      return {
        'models': [
          {
            'id': 'gpt-6.1-sol',
            'name': 'GPT-6.1 Sol',
            'efforts': ['low', 'high'],
            'default_effort': 'low',
          },
        ],
      };
    }
    return {
      'updated': ['a', 'b'],
      'skipped': [],
      'failed': [],
    };
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    now = DateTime.fromMillisecondsSinceEpoch(epoch);
    requests = [];
    policy = CodexResetDowngrade(request: request, now: () => now)
      ..restore(prefs);
  });
  tearDown(() => policy.dispose());

  Future<void> arm({int hours = 2}) => policy.arm(
    path,
    sol,
    'high',
    [account],
    trigger: CodexDowngradeTrigger.hours,
    hours: hours,
  );
  Future<void> flush() async {
    for (var i = 0; i < 12; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  int getApplies() =>
      requests.where((value) => value['action'] == 'apply').length;

  test(
    'defaults preserve Reset, Sol 6.1, High and a two-hour delay choice',
    () {
      expect(policy.trigger, CodexDowngradeTrigger.reset);
      expect(policy.hours, 2);
      expect(policy.model, 'gpt-6.1-sol');
      expect(policy.effort, 'high');
      expect(policy.scheduledAt, isNull);
      expect(policy.armed, isFalse);
    },
  );

  testWidgets(
    'single deadline timer fires at two hours without an API refresh',
    (tester) async {
      policy.dispose();
      policy = CodexResetDowngrade(request: request, now: () => now)
        ..restore(prefs);
      await arm();
      expect(policy.scheduledAt!.millisecondsSinceEpoch, epoch + 7200000);
      now = now.add(const Duration(hours: 1, minutes: 59, seconds: 59));
      await tester.pump(const Duration(hours: 1, minutes: 59, seconds: 59));
      expect(getApplies(), 0);
      now = now.add(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(getApplies(), 1);
      expect(policy.phase, 'done');
      expect(requests.single, {
        'action': 'apply',
        'model': 'gpt-6.1-sol',
        'effort': 'high',
      });
      now = now.add(const Duration(days: 1));
      policy.checkDeadline();
      await tester.pump(const Duration(days: 1));
      expect(getApplies(), 1);
      policy.dispose();
    },
  );

  test('Hours ignores the reset trigger before its deadline', () async {
    await arm();
    policy.observe(path, [
      const CodexAccount(
        slot: '1',
        name: 'one',
        weeklyUsedPercent: 0,
        weeklyResetAt: epoch + 604800000,
        usageObservedAt: epoch + 1,
      ),
    ], '1');
    await flush();
    expect(policy.armed, isTrue);
    expect(getApplies(), 0);
  });

  test(
    'remaining delay survives restart without starting another two hours',
    () async {
      await arm();
      policy.dispose();
      now = now.add(const Duration(hours: 1));
      policy = CodexResetDowngrade(request: request, now: () => now)
        ..restore(prefs);
      policy.follow(path);
      expect(policy.scheduledAt!.millisecondsSinceEpoch, epoch + 7200000);
      expect(policy.trigger, CodexDowngradeTrigger.hours);
      expect(policy.armed, isTrue);
      now = now.add(const Duration(hours: 1));
      policy.checkDeadline();
      await flush();
      expect(getApplies(), 1);
    },
  );

  test(
    'overdue restored timer waits for the matching workspace then fires once',
    () async {
      await arm();
      policy.dispose();
      now = now.add(const Duration(hours: 3));
      policy = CodexResetDowngrade(request: request, now: () => now)
        ..restore(prefs);
      await flush();
      expect(getApplies(), 0);
      policy.follow('other.md');
      await flush();
      expect(getApplies(), 0);
      policy.follow(path);
      policy.follow(path);
      await flush();
      expect(getApplies(), 1);
      expect(policy.phase, 'done');
    },
  );

  test('consumed timed action cannot replay after restart', () async {
    await arm();
    now = now.add(const Duration(hours: 2));
    policy.checkDeadline();
    await flush();
    policy.dispose();
    policy = CodexResetDowngrade(request: request, now: () => now)
      ..restore(prefs);
    policy.follow(path);
    await flush();
    expect(getApplies(), 1);
    expect(policy.armed, isFalse);
  });

  test('disarm cancels the pending timer and persists', () async {
    await arm();
    await policy.disarm();
    now = now.add(const Duration(hours: 4));
    policy.checkDeadline();
    await flush();
    expect(getApplies(), 0);
    policy.dispose();
    policy = CodexResetDowngrade(request: request, now: () => now)
      ..restore(prefs);
    policy.follow(path);
    expect(policy.armed, isFalse);
  });

  test('re-arming uses the chosen delay from confirmation time', () async {
    await arm();
    now = now.add(const Duration(hours: 1));
    await arm(hours: 3);
    expect(policy.scheduledAt!.millisecondsSinceEpoch, epoch + 14400000);
    now = now.add(const Duration(hours: 1));
    policy.checkDeadline();
    await flush();
    expect(getApplies(), 0);
    now = now.add(const Duration(hours: 2));
    policy.checkDeadline();
    await flush();
    expect(getApplies(), 1);
  });

  test(
    'switching back to Reset cancels time mode and retains reset detection',
    () async {
      await arm();
      await policy.arm(path, sol, 'high', [account]);
      expect(policy.scheduledAt, isNull);
      now = now.add(const Duration(hours: 3));
      policy.checkDeadline();
      expect(getApplies(), 0);
      policy.observe(path, [
        CodexAccount(
          slot: '1',
          name: 'one',
          weeklyUsedPercent: 0,
          weeklyResetAt: epoch + 604800000,
          usageObservedAt: now.millisecondsSinceEpoch,
        ),
      ], '1');
      await flush();
      expect(getApplies(), 1);
    },
  );

  testWidgets('backward clock change reschedules rather than firing early', (
    tester,
  ) async {
    policy.dispose();
    policy = CodexResetDowngrade(request: request, now: () => now)
      ..restore(prefs);
    await arm();
    now = now.add(const Duration(hours: 1));
    await tester.pump(const Duration(hours: 2));
    expect(getApplies(), 0);
    now = now.add(const Duration(hours: 1));
    await tester.pump(const Duration(hours: 1));
    await tester.pump();
    expect(getApplies(), 1);
    policy.dispose();
  });

  test('invalid hours cannot replace an existing arm', () async {
    await arm();
    final deadline = policy.scheduledAt;
    for (final hours in [0, CodexResetDowngrade.maxHours + 1]) {
      await expectLater(arm(hours: hours), throwsArgumentError);
    }
    expect(policy.scheduledAt, deadline);
    expect(policy.armed, isTrue);
  });

  test(
    'old reset-only preferences migrate without changing their trigger',
    () async {
      await policy.arm(path, sol, 'high', [account]);
      final data =
          jsonDecode(prefs.getString(CodexResetDowngrade.preferenceKey)!)
              as Map<String, dynamic>;
      data.remove('trigger');
      data.remove('delay_hours');
      data.remove('due_at');
      await prefs.setString(
        CodexResetDowngrade.preferenceKey,
        jsonEncode(data),
      );
      policy.dispose();
      policy = CodexResetDowngrade(request: request, now: () => now)
        ..restore(prefs);
      expect(policy.trigger, CodexDowngradeTrigger.reset);
      expect(policy.hours, 2);
      expect(policy.armed, isTrue);
      expect(policy.scheduledAt, isNull);
    },
  );

  test(
    'corrupt timed deadline fails closed instead of firing immediately',
    () async {
      await arm();
      final data =
          jsonDecode(prefs.getString(CodexResetDowngrade.preferenceKey)!)
              as Map<String, dynamic>;
      data.remove('due_at');
      await prefs.setString(
        CodexResetDowngrade.preferenceKey,
        jsonEncode(data),
      );
      policy.dispose();
      policy = CodexResetDowngrade(request: request, now: () => now)
        ..restore(prefs);
      policy.follow(path);
      await flush();
      expect(policy.armed, isFalse);
      expect(getApplies(), 0);
    },
  );

  testWidgets(
    'Hours wheel defaults to two, moves one notch, and arms selected hours',
    (tester) async {
      policy.dispose();
      policy = CodexResetDowngrade(request: request, now: () => now)
        ..restore(prefs);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CodexDowngradeButton(
              controller: policy,
              path: path,
              accounts: const [account],
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('codex-reset-downgrade')));
      await tester.pumpAndSettle();
      expect(find.text('Reset'), findsOneWidget);
      expect(find.text('Fast off'), findsOneWidget);
      await tester.tap(find.text('Hours'));
      await tester.pumpAndSettle();
      final wheel = tester.widget<CupertinoPicker>(
        find.byType(CupertinoPicker),
      );
      expect(wheel.scrollController!.selectedItem, 1);
      expect(find.text('GPT-6.1 Sol'), findsOneWidget);
      expect(find.text('High'), findsOneWidget);
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: tester.getCenter(find.text('2 h')),
          scrollDelta: const Offset(0, 120),
        ),
      );
      await tester.pumpAndSettle();
      expect(wheel.scrollController!.selectedItem, 2);
      await tester.tap(find.text('Arm once'));
      await tester.pumpAndSettle();
      expect(policy.trigger, CodexDowngradeTrigger.hours);
      expect(policy.hours, 3);
      expect(policy.scheduledAt!.millisecondsSinceEpoch, epoch + 10800000);
      expect(getApplies(), 0);
      await tester.tap(find.byKey(const ValueKey('codex-reset-downgrade')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Armed for'), findsOneWidget);
      await tester.tap(find.text('Disarm'));
      await tester.pumpAndSettle();
      expect(policy.armed, isFalse);
      await tester.pumpWidget(const SizedBox());
      policy.dispose();
    },
  );

  testWidgets(
    'changing trigger then cancelling leaves the saved arm untouched',
    (tester) async {
      policy.dispose();
      policy = CodexResetDowngrade(request: request, now: () => now)
        ..restore(prefs);
      await policy.arm(path, sol, 'high', [account]);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CodexDowngradeButton(
              controller: policy,
              path: path,
              accounts: const [account],
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('codex-reset-downgrade')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Hours'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(policy.trigger, CodexDowngradeTrigger.reset);
      expect(policy.armed, isTrue);
      expect(policy.scheduledAt, isNull);
      await tester.pumpWidget(const SizedBox());
      policy.dispose();
    },
  );
}
