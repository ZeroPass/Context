import 'package:context/app/app_state.dart';
import 'package:context/app/models.dart';
import 'package:context/app/session_terminal.dart';
import 'package:context/app/terminal_tabs.dart';
import 'package:context/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const arduId = '00000000-0000-4000-8000-000000007d40';
const otherId = '11111111-1111-1111-1111-111111111111';

void windowsTest(String name, WidgetTesterCallback callback) {
  testWidgets(
    name,
    callback,
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  var actual = 'previous copied text';
  var ignoreWrites = false;
  final writes = <String>[];
  final terminalCalls = <MethodCall>[];
  var elevated = true;
  var cancelElevation = false;

  setUp(() {
    actual = 'previous copied text';
    ignoreWrites = false;
    writes.clear();
    elevated = true;
    cancelElevation = false;
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('context/clipboard'), (
          call,
        ) async {
          final text = call.arguments as String;
          writes.add(text);
          if (!ignoreWrites) actual = text;
          return null;
        });
    terminalCalls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(sessionTerminalChannel, (call) async {
          terminalCalls.add(call);
          if (call.method == 'readSettings') {
            return '{"defaultProfile":"{12345678-1234-1234-1234-123456789abc}",'
                '"profiles":{"list":[{"guid":"{12345678-1234-1234-1234-123456789abc}",'
                '"name":"Ubuntu","source":"Windows.Terminal.Wsl"}]}}';
          }
          if (call.method == 'restartElevated' && cancelElevation) {
            throw PlatformException(
              code: 'cancelled',
              message: 'Approval cancelled',
            );
          }
          return call.method == 'isElevated' ? elevated : null;
        });
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
        .setMockMethodCallHandler(
          const MethodChannel('context/clipboard'),
          null,
        );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(sessionTerminalChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  Future<AppState> mount(
    WidgetTester tester, {
    String name = 'Reported session',
    SessionProvider provider = SessionProvider.codex,
    SharedPreferences? preferences,
  }) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final state =
        AppState.forTesting(sendRequest: (_) {}, preferences: preferences)
          ..sessionsMarkdownPath = '/test/codex-out/codex sessions.md'
          ..items = [
            ConfigItem.session(
              commandId: arduId,
              name: name,
              provider: provider,
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

  windowsTest(
    'main UI never opens a startup restart dialog or requests elevation',
    (tester) async {
      elevated = false;
      final state = await mount(tester);
      await tester.pumpAndSettle();
      expect(find.text('Approve Terminal access?'), findsNothing);
      expect(state.openSessionsInTerminal, isFalse);
      state.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.text('Approve Terminal access?'), findsNothing);
      expect(
        terminalCalls.where((call) => call.method == 'isElevated'),
        isEmpty,
      );
      expect(
        terminalCalls.where((call) => call.method == 'restartElevated'),
        isEmpty,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
    },
  );

  windowsTest('deferred startup approval waits for a Terminal action', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'askTerminalAdminAtStartup': false,
    });
    final prefs = await SharedPreferences.getInstance();
    elevated = false;
    final state = await mount(tester, preferences: prefs);
    await tester.pumpAndSettle();
    expect(terminalCalls, isEmpty);
    expect(find.text('Approve Terminal access?'), findsNothing);
    state.openSessionsInTerminal = true;
    await tester.tap(find.text('7d40'));
    await tester.pumpAndSettle();
    expect(find.text('Approve Terminal access?'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  });

  windowsTest(
    'Settings exposes and saves startup approval without elevating now',
    (tester) async {
      final prefs = await SharedPreferences.getInstance();
      final state = await mount(tester, preferences: prefs);
      await tester.tap(find.byIcon(Icons.settings_outlined));
      await tester.pumpAndSettle();
      final option = find.byKey(const ValueKey('terminal-startup-admin'));
      await tester.ensureVisible(option);
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(option).value, isTrue);
      await tester.tap(option);
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(option).value, isFalse);
      expect(prefs.getBool('askTerminalAdminAtStartup'), isFalse);
      expect(terminalCalls, isEmpty);
      expect(state.openSessionsInTerminal, isFalse);
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
    },
  );

  windowsTest(
    'Terminal group X closes a live window and only deletes a closed group',
    (tester) async {
      final state = await mount(tester);
      var present = true;
      final monitor = TerminalTabs(
        reader: (_) async => {
          'sessions': [
            if (present)
              {
                'provider': 'codex',
                'launch_session_id': arduId,
                'name': 'Reported session',
                'cwd': '/home/test',
                'distro': 'Ubuntu-24.04',
                'pid': 10,
                'start': '123',
              },
          ],
          'windows': [
            if (present)
              {
                'hwnd': 100,
                'pid': 200,
                'started': '300',
                'tabs': [
                  {'title': 'Reported session', 'selected': true},
                ],
              },
          ],
        },
      );
      state.terminalTabs = monitor;
      monitor.follow(state.sessionsMarkdownPath, active: true);
      await tester.pump();
      state.notifyListeners();
      await tester.pumpAndSettle();
      final group = monitor.groups.single;
      final close = find.byKey(ValueKey('terminal-close-${group.id}'));
      await tester.tap(close);
      await tester.pumpAndSettle();
      expect(find.text('Close Terminal 1?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(terminalCalls.where((c) => c.method == 'closeWindow'), isEmpty);
      await tester.tap(close);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Close window'));
      await finishCopy(tester);
      expect(
        terminalCalls.singleWhere((c) => c.method == 'closeWindow').arguments,
        ['100', '200', '300'],
      );
      expect(monitor.groups, hasLength(1));
      present = false;
      await tester.tap(close);
      await tester.pumpAndSettle();
      expect(monitor.groups, hasLength(1));
      expect(
        find.text('Window is already closed. The group stays saved.'),
        findsOneWidget,
      );
      expect(find.text('Saved'), findsWidgets);
      await tester.tap(close);
      await tester.pumpAndSettle();
      expect(monitor.groups, isEmpty);
      expect(
        terminalCalls.where((c) => c.method == 'closeWindow'),
        hasLength(1),
      );
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
    },
  );

  void expectMenuOrder(WidgetTester tester, {required bool terminalDefault}) {
    final copy = find.text('Copy resume command');
    final terminal = find.text('Open in Terminal');
    expect(copy, findsOneWidget);
    expect(terminal, findsOneWidget);
    expect(
      tester.getTopLeft(terminalDefault ? copy : terminal).dy,
      lessThan(tester.getTopLeft(terminalDefault ? terminal : copy).dy),
    );
  }

  windowsTest('saved session menu opens without changing copy as default', (
    tester,
  ) async {
    final state = await mount(tester);
    await state.setOpenSessionsInTerminal(false);
    state.recentCodex = [
      const RecentContext(
        provider: SessionProvider.codex,
        id: arduId,
        title: 'Original name',
        updatedAt: 0,
        workDir: '/home/user/saved project',
      ),
    ];
    await tester.tap(
      find.text('Reported session'),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    expectMenuOrder(tester, terminalDefault: false);
    await tester.tap(find.text('Open in Terminal'));
    await finishCopy(tester);
    final args =
        terminalCalls.singleWhere((call) => call.method == 'openTab').arguments
            as List;
    expect(args[args.indexOf('--title') + 1], 'Reported session');
    expect(args[args.indexOf('--cd') + 1], '/home/user/saved project');
    expect(args.last, arduId);
    expect(writes, isEmpty);
    expect(state.openSessionsInTerminal, isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('openSessionsInTerminal'), isFalse);
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('session-codex-$arduId')),
        matching: find.text('7d40'),
      ),
    );
    await finishCopy(tester);
    expect(writes, ['codex resume $arduId']);
    expect(
      terminalCalls.where((call) => call.method == 'openTab'),
      hasLength(1),
    );
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  });

  for (final terminalDefault in [false, true]) {
    windowsTest(
      'recent menu offers both actions with terminal default $terminalDefault',
      (tester) async {
        final state = await mount(tester);
        await state.setOpenSessionsInTerminal(terminalDefault);
        state.recentProvider = SessionProvider.kimi;
        state.recentKimi = [
          const RecentContext(
            provider: SessionProvider.kimi,
            id: 'recent-4321',
            title: 'Recent Kimi',
            updatedAt: 0,
            workDir: '/home/user/recent project',
          ),
        ];
        state.setFilterQuery('Reported');
        await tester.pump();
        final title = find.text('Recent Kimi');
        await tester.ensureVisible(title);
        final choices = terminalDefault
            ? ['Copy resume command', 'Open in Terminal']
            : ['Open in Terminal', 'Copy resume command'];
        for (final choice in choices) {
          await tester.tap(title, buttons: kSecondaryMouseButton);
          await tester.pumpAndSettle();
          expectMenuOrder(tester, terminalDefault: terminalDefault);
          await tester.tap(find.text(choice));
          await finishCopy(tester);
        }
        final args =
            terminalCalls
                    .singleWhere((call) => call.method == 'openTab')
                    .arguments
                as List;
        expect(args[args.indexOf('--cd') + 1], '/home/user/recent project');
        expect(args.sublist(args.indexOf('context-session') + 1), [
          'kimi',
          '--session',
          'recent-4321',
        ]);
        expect(writes, ['kimi --session recent-4321']);
        expect(state.items, hasLength(2));
        expect(state.openSessionsInTerminal, terminalDefault);
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getBool('openSessionsInTerminal'), terminalDefault);
        await tester.pumpWidget(const SizedBox.shrink());
        state.dispose();
      },
    );
  }

  for (final cancelled in [false, true]) {
    windowsTest(
      'helper approval preserves copy default (cancelled: $cancelled)',
      (tester) async {
        elevated = false;
        cancelElevation = cancelled;
        final state = await mount(tester);
        await state.setOpenSessionsInTerminal(false);
        await tester.tap(
          find.text('Reported session'),
          buttons: kSecondaryMouseButton,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Open in Terminal'));
        await tester.pumpAndSettle();
        expect(find.text('Approve Terminal access?'), findsOneWidget);
        await tester.tap(find.text('Approve Terminal access'));
        await tester.pumpAndSettle();
        expect(terminalCalls.map((call) => call.method), [
          'isElevated',
          'restartElevated',
          if (!cancelled) ...['readSettings', 'openTab'],
        ]);
        expect(state.openSessionsInTerminal, isFalse);
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getBool('openSessionsInTerminal'), isFalse);
        expect(writes, isEmpty);
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('7d40'));
        await finishCopy(tester);
        expect(writes, ['codex resume $arduId']);
        await tester.pumpWidget(const SizedBox.shrink());
        state.dispose();
      },
    );
  }

  windowsTest('dismissing session menu does not copy or launch', (
    tester,
  ) async {
    final state = await mount(tester);
    await tester.tap(
      find.text('Reported session'),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    expectMenuOrder(tester, terminalDefault: false);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(find.text('Open in Terminal'), findsNothing);
    expect(terminalCalls, isEmpty);
    expect(writes, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  });

  windowsTest('unsupported ZCode session menu remains copy-only', (
    tester,
  ) async {
    final state = await mount(tester, provider: SessionProvider.zcode);
    state.openSessionsInTerminal = true;
    await tester.tap(
      find.text('Reported session'),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    expect(find.text('Open in Terminal'), findsNothing);
    await tester.tap(find.text('Copy session id'));
    await finishCopy(tester);
    expect(writes, [arduId]);
    expect(terminalCalls, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  });

  windowsTest('recent session launches with its own cwd without adding it', (
    tester,
  ) async {
    final state = await mount(tester);
    state.openSessionsInTerminal = true;
    state.recentProvider = SessionProvider.kimi;
    state.recentKimi = [
      const RecentContext(
        provider: SessionProvider.kimi,
        id: 'recent-4321',
        title: 'Recent Kimi',
        updatedAt: 0,
        workDir: '/home/user/recent project',
      ),
    ];
    state.setFilterQuery('Reported');
    await tester.pump();
    final title = find.text('Recent Kimi');
    await tester.ensureVisible(title);
    await tester.tap(title);
    await finishCopy(tester);
    final args =
        terminalCalls.singleWhere((call) => call.method == 'openTab').arguments
            as List;
    expect(args, contains('--profile'));
    expect(
      args[args.indexOf('--profile') + 1],
      '{12345678-1234-1234-1234-123456789abc}',
    );
    expect(args[args.indexOf('--cd') + 1], '/home/user/recent project');
    expect(args.sublist(args.indexOf('context-session') + 1), [
      'kimi',
      '--session',
      'recent-4321',
    ]);
    expect(state.items, hasLength(2));
    expect(writes, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  });

  windowsTest('cancelled administrator approval keeps the current app usable', (
    tester,
  ) async {
    elevated = false;
    cancelElevation = true;
    final state = await mount(tester);
    state.openSessionsInTerminal = true;
    await tester.tap(find.text('7d40'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Approve Terminal access'));
    await tester.pumpAndSettle();
    expect(terminalCalls.map((call) => call.method), [
      'isElevated',
      'restartElevated',
    ]);
    expect(state.openSessionsInTerminal, isTrue);
    expect(find.text('Reported session'), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  });

  windowsTest(
    'terminal mode opens badge, name and blank area without copying',
    (tester) async {
      final state = await mount(tester);
      state.openSessionsInTerminal = true;
      state.setFilterQuery('Reported');
      await tester.pump();
      final card = find.byKey(const ValueKey('session-codex-$arduId'));
      for (final point in [
        tester.getCenter(find.text('7d40')),
        tester.getCenter(find.text('Reported session')),
        tester.getCenter(card),
      ]) {
        await tester.tapAt(point);
        await finishCopy(tester);
      }
      final launches = terminalCalls
          .where((call) => call.method == 'openTab')
          .toList();
      expect(launches, hasLength(3));
      expect(launches.first.arguments, contains(arduId));
      expect(writes, isEmpty);
      expect(find.text('Opened in Terminal.'), findsOneWidget);
      await tester.tap(
        find.descendant(
          of: card,
          matching: find.byIcon(Icons.call_split_rounded),
        ),
      );
      await finishCopy(tester);
      expect(writes, [state.items.first.forkCommand]);
      expect(
        terminalCalls.where((call) => call.method == 'openTab'),
        hasLength(3),
      );
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
    },
  );

  windowsTest(
    'right-click copies and double-click still renames in terminal mode',
    (tester) async {
      final state = await mount(tester);
      state.openSessionsInTerminal = true;
      await tester.tap(
        find.text('Reported session'),
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();
      expectMenuOrder(tester, terminalDefault: true);
      await tester.tap(find.text('Copy resume command'));
      await finishCopy(tester);
      expect(writes, ['codex resume $arduId']);
      await tester.tap(find.text('Reported session'));
      await tester.pump(const Duration(milliseconds: 80));
      await tester.tap(find.text('Reported session'));
      await tester.pumpAndSettle();
      expect(find.text('Rename Session'), findsOneWidget);
      expect(terminalCalls, isEmpty);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
    },
  );

  windowsTest(
    'normal Context requests helper approval instead of per-tab UAC',
    (tester) async {
      elevated = false;
      final state = await mount(tester);
      state.openSessionsInTerminal = true;
      await tester.tap(find.text('7d40'));
      await tester.pumpAndSettle();
      expect(find.text('Approve Terminal access?'), findsOneWidget);
      expect(terminalCalls.map((call) => call.method), ['isElevated']);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(terminalCalls.where((call) => call.method == 'openTab'), isEmpty);
      expect(writes, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
    },
  );

  windowsTest('clear filter appears immediately and restores all contexts', (
    tester,
  ) async {
    final state = await mount(tester);
    final field = find.byType(TextField);
    final clear = find.byKey(const ValueKey('clear-context-filter'));
    final height = tester.getSize(field).height;
    expect(clear, findsNothing);
    await tester.enterText(field, 'R');
    await tester.pump();
    expect(clear, findsOneWidget);
    expect(tester.getSize(field).height, height);
    await tester.enterText(field, 'Reported');
    await tester.pump();
    expect(find.text('Other'), findsNothing);
    await tester.tap(clear);
    await tester.pump();
    expect(state.filterQuery, isEmpty);
    expect(tester.widget<TextField>(field).controller!.text, isEmpty);
    expect(tester.widget<TextField>(field).focusNode!.hasFocus, isTrue);
    expect(clear, findsNothing);
    expect(find.text('Reported session'), findsOneWidget);
    expect(find.text('Other'), findsOneWidget);
    expect(tester.getSize(field).height, height);
    expect(writes, isEmpty);
    expect(state.dirty, isFalse);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  });

  windowsTest('clear filter works for no matches and whitespace', (
    tester,
  ) async {
    final state = await mount(tester);
    final field = find.byType(TextField);
    final clear = find.byKey(const ValueKey('clear-context-filter'));
    for (final query in ['no matching contexts', '   ']) {
      await tester.enterText(field, query);
      await tester.pump();
      expect(clear, findsOneWidget);
      if (query.trim().isNotEmpty) {
        expect(find.text('No matching contexts.'), findsOneWidget);
      }
      await tester.tap(clear);
      await tester.pump();
      expect(state.filterQuery, isEmpty);
      expect(clear, findsNothing);
      expect(find.text('Other'), findsOneWidget);
    }
    await tester.enterText(field, 'Other');
    await tester.pump();
    state.setFilterQuery('Reported');
    await tester.pump();
    expect(tester.widget<TextField>(field).controller!.text, 'Reported');
    expect(find.text('Other'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  });

  windowsTest(
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

  windowsTest(
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

  windowsTest(
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

  windowsTest('double-clicking the name still opens rename without copying', (
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

  windowsTest('right-side fork and delete buttons do not copy resume', (
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

  windowsTest(
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

  windowsTest(
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
