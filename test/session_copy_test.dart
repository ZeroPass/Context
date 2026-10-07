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

  Future<AppState> mount(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final state = AppState.forTesting(sendRequest: (_) {})
      ..sessionsMarkdownPath = '/test/codex-out/codex sessions.md'
      ..items = [
        ConfigItem.session(
          commandId: arduId,
          name: 'Reported session',
          provider: SessionProvider.codex,
        ),
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
