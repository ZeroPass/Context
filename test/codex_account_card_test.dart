import 'dart:async';

import 'package:context/ui/widgets/codex_account_card.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> mount(
    WidgetTester tester, {
    Future<bool> Function()? activate,
    bool selected = false,
    bool reduceMotion = false,
    VoidCallback? rename,
    VoidCallback? delete,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: reduceMotion),
          child: Scaffold(
            body: Center(
              child: SizedBox(
                width: 500,
                child: CodexAccountCard(
                  name: 'Work account',
                  slot: '2',
                  selected: selected,
                  surfaceColor: const Color(0xFF292827),
                  accentColor: const Color(0xFF6AD697),
                  outlineColor: const Color(0xFF686868),
                  onActivate: activate,
                  usage: const Text('42% left'),
                  actions: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        onPressed: rename,
                        tooltip: 'Rename',
                        icon: const Icon(Icons.edit_outlined),
                      ),
                      IconButton(
                        onPressed: delete,
                        tooltip: 'Delete',
                        icon: const Icon(Icons.delete_outline),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('hover has an activation hint without changing card geometry', (
    tester,
  ) async {
    await mount(tester, activate: () async => true);
    final card = find.byType(CodexAccountCard);
    final bounds = tester.getRect(card);
    final usage = tester.widget<Text>(find.text('42% left'));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.text('Work account')));
    await tester.pumpAndSettle();
    expect(find.textContaining('click to activate'), findsOneWidget);
    expect(tester.getRect(card), bounds);
    expect(tester.widget<Text>(find.text('42% left')), same(usage));
    final press = await tester.startGesture(
      tester.getCenter(find.text('Work account')),
    );
    await tester.pump(const Duration(milliseconds: 140));
    expect(tester.getRect(card), bounds);
    await press.cancel();
    await mouse.moveTo(Offset.zero);
    await tester.pumpAndSettle();
    expect(find.textContaining('click to activate'), findsNothing);
    expect(tester.getRect(card), bounds);
  });

  testWidgets('pending switch pulses and ignores duplicate presses', (
    tester,
  ) async {
    final completion = Completer<bool>();
    var calls = 0;
    await mount(
      tester,
      activate: () {
        calls += 1;
        return completion.future;
      },
    );
    final bounds = tester.getRect(find.byType(CodexAccountCard));
    await tester.tap(find.text('Work account'));
    await tester.pump();
    expect(find.textContaining('switching...'), findsOneWidget);
    expect(find.text('Slot 2 \u00b7 active'), findsNothing);
    expect(tester.binding.transientCallbackCount, greaterThan(0));
    await tester.tap(find.text('Work account'));
    await tester.pump(const Duration(milliseconds: 200));
    expect(calls, 1);
    expect(tester.getRect(find.byType(CodexAccountCard)), bounds);
    completion.complete(true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.textContaining('switching...'), findsNothing);
    expect(tester.binding.transientCallbackCount, greaterThan(0));
    await tester.pumpAndSettle();
    expect(tester.binding.transientCallbackCount, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed switch stops without a success animation', (
    tester,
  ) async {
    final completion = Completer<bool>();
    await mount(tester, activate: () => completion.future);
    await tester.tap(find.text('Work account'));
    await tester.pump(const Duration(milliseconds: 300));
    completion.complete(false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.textContaining('switching...'), findsNothing);
    expect(find.text('Slot 2 \u00b7 active'), findsNothing);
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('reduced motion keeps pending feedback static', (tester) async {
    final completion = Completer<bool>();
    await mount(tester, reduceMotion: true, activate: () => completion.future);
    await tester.tap(find.text('Work account'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.textContaining('switching...'), findsOneWidget);
    expect(tester.binding.transientCallbackCount, 0);
    completion.complete(true);
    await tester.pump();
    await tester.pump();
    expect(tester.binding.transientCallbackCount, 0);
    expect(find.textContaining('switching...'), findsNothing);
  });

  testWidgets('management buttons never activate the account', (tester) async {
    var activated = 0;
    var renamed = 0;
    var deleted = 0;
    await mount(
      tester,
      activate: () async {
        activated += 1;
        return true;
      },
      rename: () => renamed += 1,
      delete: () => deleted += 1,
    );
    await tester.tap(find.byTooltip('Rename'));
    await tester.tap(find.byTooltip('Delete'));
    await tester.pumpAndSettle();
    expect(activated, 0);
    expect(renamed, 1);
    expect(deleted, 1);
    expect(find.textContaining('switching...'), findsNothing);
  });

  testWidgets('active and disabled cards do not offer activation', (
    tester,
  ) async {
    var calls = 0;
    await mount(
      tester,
      selected: true,
      activate: () async {
        calls += 1;
        return true;
      },
    );
    await tester.tap(find.text('Work account'));
    await tester.pumpAndSettle();
    expect(calls, 0);
    expect(find.text('Slot 2 \u00b7 active'), findsOneWidget);
    await mount(tester);
    await tester.tap(find.text('Work account'));
    await tester.pumpAndSettle();
    expect(calls, 0);
    expect(find.textContaining('switching...'), findsNothing);
  });

  testWidgets('keyboard focus and Enter activate the account', (tester) async {
    final completion = Completer<bool>();
    var calls = 0;
    await mount(
      tester,
      activate: () {
        calls += 1;
        return completion.future;
      },
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(find.textContaining('Enter to activate'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(calls, 1);
    expect(find.textContaining('switching...'), findsOneWidget);
    completion.complete(true);
    await tester.pumpAndSettle();
  });

  testWidgets('disposing a pending card stops its animation safely', (
    tester,
  ) async {
    final completion = Completer<bool>();
    await mount(tester, activate: () => completion.future);
    await tester.tap(find.text('Work account'));
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    completion.complete(false);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(tester.binding.transientCallbackCount, 0);
  });
}
