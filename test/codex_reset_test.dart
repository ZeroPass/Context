import 'package:context/app/codex_reset.dart';
import 'package:context/app/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime(2026, 10, 20, 12);
  CodexAccount account(String slot, DateTime reset, {int window = 604800}) =>
      CodexAccount(
        slot: slot,
        name: slot,
        weeklyUsedPercent: 0,
        weeklyResetAt: reset.millisecondsSinceEpoch,
        weeklyWindowSeconds: window,
      );

  test('monthly account does not override latest genuine weekly reset', () {
    final latestWeekly = now.add(const Duration(days: 6, hours: 20));
    expect(
      codexManualResetBase([
        account('1', now.add(const Duration(days: 6))),
        account('2', latestWeekly),
        account('3', now.add(const Duration(days: 30)), window: 2592000),
      ], now: now),
      latestWeekly,
    );
  });

  test(
    'only monthly or unavailable accounts use a seven-day picker horizon',
    () {
      for (final accounts in [
        [account('3', now.add(const Duration(days: 30)), window: 2592000)],
        [account('3', now.add(const Duration(days: 3)), window: 2592000)],
        [const CodexAccount(slot: '1', name: 'unavailable')],
      ]) {
        expect(
          codexManualResetBase(accounts, now: now),
          now.add(const Duration(days: 7)),
        );
      }
    },
  );

  test(
    'stale or out-of-window weekly resets cannot strand picker in November',
    () {
      final good = now.add(const Duration(days: 3));
      expect(
        codexManualResetBase([
          account('stale', now.subtract(const Duration(days: 1))),
          account('bad', now.add(const Duration(days: 31))),
          account('good', good),
        ], now: now),
        good,
      );
      expect(
        codexManualResetBase([
          const CodexAccount(
            slot: 'bad',
            name: 'bad',
            weeklyResetAt: 9223372036854775807,
          ),
        ], now: now),
        now.add(const Duration(days: 7)),
      );
    },
  );

  test('manual overrides do not become the API-based picker anchor', () {
    final weekly = now.add(const Duration(days: 5));
    expect(
      codexManualResetBase([
        CodexAccount(
          slot: '1',
          name: '1',
          weeklyResetAt: weekly.millisecondsSinceEpoch,
          manualResetAt: now
              .add(const Duration(days: 30))
              .millisecondsSinceEpoch,
        ),
      ], now: now),
      weekly,
    );
    expect(codexManualResetBase(const [], now: now), isNull);
  });
}
