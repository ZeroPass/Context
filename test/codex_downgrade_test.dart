import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:context/app/app_state.dart';
import 'package:context/app/codex_downgrade.dart';
import 'package:context/app/models.dart';
import 'package:context/src/bindings/bindings.dart';
import 'package:context/ui/widgets/codex_downgrade_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const path = r'\\wsl.localhost\Ubuntu-24.04\home\user\Context\context.md';
const start = 1800000000000;
final choice = CodexModelChoice.fromJson({
  'id': 'gpt-6.1-sol',
  'name': 'GPT-6.1 Sol',
  'efforts': ['low', 'medium', 'high', 'xhigh'],
  'default_effort': 'medium',
});
CodexAccount account({
  String slot = '1',
  double used = 40,
  int observed = start - 1000,
  int reset = start + 100000,
  String? error,
  int window = 604800,
  String? accountKey,
}) => CodexAccount(
  slot: slot,
  name: slot,
  weeklyUsedPercent: used,
  weeklyResetAt: reset,
  usageObservedAt: observed,
  weeklyError: error,
  weeklyWindowSeconds: window,
  usageAccountKey: accountKey,
);

Future<void> flush() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late SharedPreferences prefs;
  late CodexResetDowngrade controller;
  late List<Map<String, dynamic>> calls;
  Future<Map<String, dynamic>> request(
    String _,
    Map<String, dynamic> payload,
  ) async {
    calls.add(payload);
    return {
      'updated': ['one', 'two', 'three', 'four'],
      'skipped': [],
      'failed': [],
    };
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    calls = [];
    controller = CodexResetDowngrade(
      request: request,
      now: () => DateTime.fromMillisecondsSinceEpoch(start),
    );
    controller.restore(prefs);
  });
  tearDown(() => controller.dispose());

  test(
    'defaults are Sol 6.1 high and off; disabled policy sends nothing',
    () async {
      expect(controller.model, 'gpt-6.1-sol');
      expect(controller.effort, 'high');
      expect(controller.armed, isFalse);
      controller.observe(path, [account(used: 0, observed: start + 1)], '1');
      await flush();
      expect(calls, isEmpty);
    },
  );

  for (final reset in [start + 100000, start + 604800000]) {
    test(
      'fresh 100% active report consumes one action, reset=$reset',
      () async {
        await controller.arm(path, choice, 'high', [account()]);
        final reading = [account(used: 0, observed: start + 1, reset: reset)];
        controller.observe(path, reading, '1');
        controller.observe(path, reading, '1');
        expect(controller.running, isTrue);
        await flush();
        expect(calls, [
          {'action': 'apply', 'model': 'gpt-6.1-sol', 'effort': 'high'},
        ]);
        expect(controller.phase, 'done');
        controller.observe(path, [account(used: 0, observed: start + 2)], '1');
        await flush();
        expect(calls.length, 1);
      },
    );
  }

  test(
    'inactive zero, near-zero, errors, stale UI and other workspaces do not trigger',
    () async {
      await controller.arm(path, choice, 'high', [
        account(),
        account(slot: '2'),
      ]);
      controller.observe(path, [
        account(slot: '2', used: 0, observed: start + 1),
      ], '1');
      controller.observe(path, [account(used: 0.1, observed: start + 1)], '1');
      controller.observe(path, [
        account(used: 0, observed: start + 2, error: 'offline'),
      ], '1');
      controller.observe(path, [account(used: 0, observed: start)], '1');
      controller.observe('other.md', [
        account(used: 0, observed: start + 3),
      ], '1');
      controller.observe(path, [
        account(used: 0, observed: start + 3, window: 2592000),
      ], '1');
      controller.observe(path, [account(used: 0, observed: start + 3)], null);
      await flush();
      expect(calls, isEmpty);
      expect(controller.armed, isTrue);
    },
  );

  test(
    'arming at 100% waits for a later reset rather than current zero',
    () async {
      await controller.arm(path, choice, 'high', [account(used: 0)]);
      controller.observe(path, [account(used: 0, observed: start + 1)], '1');
      await flush();
      expect(calls, isEmpty);
      controller.observe(path, [
        account(used: 0, observed: start + 2, reset: start + 604800000),
      ], '1');
      await flush();
      expect(calls.length, 1);
    },
  );

  test('an unknown baseline is learned, never guessed as a reset', () async {
    await controller.arm(path, choice, 'high', []);
    controller.observe(path, [account(used: 0, observed: start + 1)], '1');
    await flush();
    expect(calls, isEmpty);
    controller.observe(path, [account(used: 12, observed: start + 2)], '1');
    controller.observe(path, [account(used: 0, observed: start + 3)], '1');
    await flush();
    expect(calls.length, 1);
  });

  test('armed state and baseline survive restart', () async {
    await controller.arm(path, choice, 'medium', [account()]);
    final resumed = CodexResetDowngrade(request: request)..restore(prefs);
    expect(resumed.armed, isTrue);
    expect(resumed.effort, 'medium');
    resumed.observe(path, [account(used: 0, observed: start + 1000)], '1');
    await flush();
    expect(calls.single['effort'], 'medium');
    resumed.dispose();
  });

  test(
    'durable consumed claim exists before applying; interrupted run never replays',
    () async {
      final completion = Completer<Map<String, dynamic>>();
      String? claimed;
      final pending = CodexResetDowngrade(
        now: () => DateTime.fromMillisecondsSinceEpoch(start),
        request: (_, _) {
          claimed = prefs.getString(CodexResetDowngrade.preferenceKey);
          return completion.future;
        },
      )..restore(prefs);
      await pending.arm(path, choice, 'high', [account()]);
      pending.observe(path, [account(used: 0, observed: start + 1)], '1');
      await flush();
      expect((jsonDecode(claimed!) as Map)['phase'], 'running');
      final restarted = CodexResetDowngrade(request: request)..restore(prefs);
      expect(restarted.phase, 'failed');
      restarted.observe(path, [account(used: 0, observed: start + 2)], '1');
      await flush();
      expect(calls, isEmpty);
      completion.complete({
        'updated': ['x'],
        'skipped': [],
        'failed': [],
      });
      await flush();
      pending.dispose();
      restarted.dispose();
    },
  );

  test('disarm is persistent and prevents execution', () async {
    await controller.arm(path, choice, 'high', [account()]);
    await controller.disarm();
    controller.observe(path, [account(used: 0, observed: start + 1)], '1');
    final restored = CodexResetDowngrade(request: request)..restore(prefs);
    expect(restored.armed, isFalse);
    restored.dispose();
    expect(calls, isEmpty);
  });

  test('partial results and transport errors never auto retry', () async {
    for (final transportError in [false, true]) {
      var count = 0;
      final failing = CodexResetDowngrade(
        now: () => DateTime.fromMillisecondsSinceEpoch(start),
        request: (_, _) async {
          count++;
          if (transportError) throw StateError('offline');
          return {
            'updated': ['a'],
            'skipped': ['unknown'],
            'failed': ['b'],
          };
        },
      )..restore(prefs);
      await failing.arm(path, choice, 'high', [account()]);
      failing.observe(path, [account(used: 0, observed: start + 1)], '1');
      await flush();
      failing.observe(path, [account(used: 0, observed: start + 2)], '1');
      await flush();
      expect(count, 1);
      expect(failing.phase, 'failed');
      failing.dispose();
    }
  });

  test('unsupported effort cannot be armed', () async {
    await expectLater(
      controller.arm(path, choice, 'invented', [account()]),
      throwsStateError,
    );
    expect(controller.armed, isFalse);
  });

  test(
    'minor reset timestamp jitter while already unused is not a new reset',
    () async {
      await controller.arm(path, choice, 'high', [account(used: 0)]);
      controller.observe(path, [
        account(used: 0, observed: start + 1, reset: start + 101000),
      ], '1');
      await flush();
      expect(calls, isEmpty);
      expect(controller.armed, isTrue);
    },
  );

  test(
    'busy-turn deferral is explicit, consumed once, and never called full success',
    () async {
      final deferred = CodexResetDowngrade(
        now: () => DateTime.fromMillisecondsSinceEpoch(start),
        request: (_, _) async => {
          'updated': ['a', 'b'],
          'skipped': [],
          'failed': [],
          'live_failed': ['a'],
        },
      )..restore(prefs);
      await deferred.arm(path, choice, 'high', [account()]);
      deferred.observe(path, [account(used: 0, observed: start + 1)], '1');
      await flush();
      expect(deferred.phase, 'failed');
      expect(
        deferred.status,
        contains('1 busy turns could not be changed yet'),
      );
      expect(deferred.status, contains('future replies have the new settings'));
      expect(deferred.armed, isFalse);
      deferred.dispose();
    },
  );

  test('replacing credentials in the same slot is not a reset', () async {
    await controller.arm(path, choice, 'high', [account(accountKey: 'old')]);
    controller.observe(path, [
      account(used: 0, observed: start + 1, accountKey: 'new'),
    ], '1');
    await flush();
    expect(calls, isEmpty);
    expect(controller.armed, isTrue);
  });

  test(
    'native account freshness round trips and AppState ignores busy/replayed readings',
    () async {
      final policy = CodexResetDowngrade(
        request: request,
        now: () => DateTime.fromMillisecondsSinceEpoch(start),
      );
      final app = AppState.forTesting(
        sendRequest: (_) {},
        preferences: prefs,
        downgrade: policy,
      );
      void emit({
        double used = 40,
        int observed = start - 1,
        bool busy = false,
      }) {
        final state = UiState(
          themeSeedColorValue: AppState.themeSeedColors.first,
          busy: false,
          sessionsMarkdownPath: path,
          itemsJson: '[]',
          warningsJson: '[]',
          recentCodexJson: '[]',
          recentKimiJson: '[]',
          recentOpencodeJson: '[]',
          recentQwenJson: '[]',
          recentMuseJson: '[]',
          recentZcodeJson: '[]',
          recentBusy: false,
          codexAccountsJson: jsonEncode([
            {
              'slot': '1',
              'name': 'one',
              'weekly_used_percent': used,
              'weekly_reset_at': start + 604800000,
              'weekly_window_seconds': 604800,
              'usage_observed_at': observed,
              'usage_account_key': 'same-account',
            },
          ]),
          codexActiveAccount: '1',
          codexAccountBusy: busy,
          museAccountsJson: '[]',
          museAccountBusy: false,
          zcodeAccountsJson: '[]',
          zcodeAccountBusy: false,
        );
        assignRustSignal['UiState']!(state.bincodeSerialize(), Uint8List(0));
      }

      emit();
      await flush();
      expect(app.codexAccounts.single.usageObservedAt, start - 1);
      expect(app.codexAccounts.single.usageAccountKey, 'same-account');
      await policy.arm(path, choice, 'high', app.codexAccounts);
      emit(used: 0, observed: start + 1, busy: true);
      await flush();
      expect(calls, isEmpty);
      emit(used: 0, observed: start + 1);
      emit(used: 0, observed: start + 1);
      await flush();
      expect(calls.length, 1);
      app.dispose();
    },
  );

  testWidgets(
    'compact control loads actual models, defaults High, arms and disarms',
    (tester) async {
      final widgetController = CodexResetDowngrade(
        request: (_, payload) async => {
          'models': [
            {
              'id': 'gpt-6.1-sol',
              'name': 'GPT-6.1 Sol',
              'efforts': ['low', 'high'],
              'default_effort': 'low',
            },
            {
              'id': 'another',
              'name': 'Another model',
              'efforts': ['medium'],
              'default_effort': 'medium',
            },
          ],
        },
      )..restore(prefs);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CodexDowngradeButton(
              controller: widgetController,
              path: path,
              accounts: [account()],
            ),
          ),
        ),
      );
      expect(
        tester.getSize(find.byType(IconButton)).width,
        lessThanOrEqualTo(40),
      );
      await tester.tap(find.byKey(const ValueKey('codex-reset-downgrade')));
      await tester.pumpAndSettle();
      expect(find.text('GPT-6.1 Sol'), findsOneWidget);
      expect(find.text('High'), findsOneWidget);
      expect(find.text('Fast off'), findsOneWidget);
      await tester.tap(find.text('Arm once'));
      await tester.pumpAndSettle();
      expect(widgetController.armed, isTrue);
      await tester.tap(find.byKey(const ValueKey('codex-reset-downgrade')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Disarm'));
      await tester.pumpAndSettle();
      expect(widgetController.armed, isFalse);
      await tester.pumpWidget(const SizedBox());
      widgetController.dispose();
    },
  );
}
