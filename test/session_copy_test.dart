import 'package:context/app/app_state.dart';
import 'package:context/app/models.dart';
import 'package:context/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

const arduId = '00000000-0000-4000-8000-000000007d40';
const otherId = '11111111-1111-1111-1111-111111111111';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  var actual = 'previous copied text';
  var ignoreWrites = false;
  final writes = <String>[];

  setUp(() {
    actual = 'previous copied text';
    ignoreWrites = false;
    writes.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          switch (call.method) {
            case 'Clipboard.setData':
              final text = (call.arguments as Map)['text'] as String;
              writes.add(text);
              if (!ignoreWrites) actual = text;
              return null;
            case 'Clipboard.getData':
              return {'text': actual};
            case 'Clipboard.hasStrings':
              return {'value': actual.isNotEmpty};
          }
          return null;
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  Future<AppState> mount(
    WidgetTester tester, {
    String name = 'Reported session',
    SessionProvider provider = SessionProvider.codex,
  }) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final state = AppState.forTesting(sendRequest: (_) {})
      ..sessionsMarkdownPath = '/test/codex-out/codex sessions.md'
      ..items = [
        ConfigItem.session(commandId: arduId, name: name, provider: provider),
        ConfigItem.session(
          commandId: otherId,
          name: 'Other',
          provider: SessionProvider.codex,
        ),
      ];
    await tester.pumpWidget(
      ChangeNotifierProvider.value(value: state, child: const ContextView()),
    );
    await tester.pump(const Duration(milliseconds: 300));
    return state;
  }

  Future<void> finishCopy(WidgetTester tester) async {
    for (var step = 0; step < 8; step++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  testWidgets(
    '7d40 badge and blank card space copy its full command after another card',
    (tester) async {
      final state = await mount(tester);
      await tester.tap(find.text('1111'));
      await finishCopy(tester);
      expect(actual, 'codex resume $otherId');
      await tester.tap(find.text('7d40'));
      await finishCopy(tester);
      expect(actual, 'codex resume $arduId');
      final card = find.byKey(const ValueKey('session-codex-$arduId'));
      final rect = tester.getRect(card);
      actual = 'previous copied text';
      await tester.tapAt(Offset(rect.center.dx, rect.center.dy));
      await finishCopy(tester);
      expect(actual, 'codex resume $arduId');
      expect(find.text('Resume copied.'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
    },
  );

  testWidgets(
    'session name text copies instead of intercepting the card click',
    (tester) async {
      final state = await mount(tester);
      await tester.tap(find.text('Other'));
      await finishCopy(tester);
      expect(actual, 'codex resume $otherId');
      await tester.tap(find.text('Reported session'));
      await finishCopy(tester);
      expect(actual, 'codex resume $arduId');
      expect(writes, ['codex resume $otherId', 'codex resume $arduId']);
      expect(find.text('Resume copied.'), findsOneWidget);
      expect(find.text('Double-click the name to rename it.'), findsNothing);
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
    },
  );

  testWidgets(
    'long ellipsized name copies across its text area, also when filtered',
    (tester) async {
      final name = List.filled(30, 'Long session name').join(' ');
      final state = await mount(tester, name: name);
      for (final filtered in [false, true]) {
        if (filtered) {
          state.setFilterQuery('Long session');
          await tester.pump();
        }
        final rect = tester.getRect(find.text(name));
        for (final x in [rect.left + 2, rect.center.dx, rect.right - 2]) {
          actual = 'previous copied text';
          await tester.tapAt(Offset(x, rect.center.dy));
          await finishCopy(tester);
          expect(actual, 'codex resume $arduId');
        }
      }
      expect(writes, hasLength(6));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
    },
  );

  testWidgets('double-clicking the name still opens rename without copying', (
    tester,
  ) async {
    final state = await mount(tester);
    await tester.tap(find.text('Reported session'));
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tap(find.text('Reported session'));
    await finishCopy(tester);
    expect(find.text('Rename Session'), findsOneWidget);
    expect(actual, 'previous copied text');
    expect(writes, isEmpty);
    await tester.tap(find.text('Cancel'));
    await finishCopy(tester);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  });

  testWidgets('right-side fork and delete buttons do not copy resume', (
    tester,
  ) async {
    final state = await mount(tester);
    final card = find.byKey(const ValueKey('session-codex-$arduId'));
    await tester.tap(
      find.descendant(
        of: card,
        matching: find.byIcon(Icons.call_split_rounded),
      ),
    );
    await finishCopy(tester);
    expect(actual, state.items.first.forkCommand);
    expect(writes, [state.items.first.forkCommand]);
    await tester.tap(
      find.descendant(
        of: card,
        matching: find.byIcon(Icons.delete_outline_rounded),
      ),
    );
    await finishCopy(tester);
    expect(state.items.where((item) => item.commandId == arduId), isEmpty);
    expect(writes, hasLength(1));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  });

  testWidgets(
    'disabled fork button and drag handle never copy the resume command',
    (tester) async {
      final state = await mount(tester, provider: SessionProvider.kimi);
      final card = find.byKey(const ValueKey('session-kimi-$arduId'));
      for (final icon in [
        Icons.call_split_rounded,
        Icons.drag_indicator_rounded,
      ]) {
        await tester.tap(
          find.descendant(of: card, matching: find.byIcon(icon)),
        );
        await finishCopy(tester);
        expect(actual, 'previous copied text');
        expect(writes, isEmpty);
      }
      await tester.tap(find.text('Reported session'));
      await finishCopy(tester);
      expect(actual, state.items.first.resumeCommand);
      expect(writes, hasLength(1));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
    },
  );

  testWidgets(
    'stale clipboard produces an error and removes the previous copied message',
    (tester) async {
      final state = await mount(tester);
      await tester.tap(find.text('1111'));
      await finishCopy(tester);
      expect(actual, 'codex resume $otherId');
      expect(find.text('Resume copied.'), findsOneWidget);
      ignoreWrites = true;
      await tester.tap(find.text('7d40'));
      await finishCopy(tester);
      expect(actual, 'codex resume $otherId');
      expect(
        writes.where((text) => text == 'codex resume $arduId'),
        hasLength(4),
      );
      expect(find.text('Resume copied.'), findsNothing);
      expect(
        find.text('Clipboard could not be updated. Please try again.'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
    },
  );
}
