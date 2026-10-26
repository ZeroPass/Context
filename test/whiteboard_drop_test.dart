import 'dart:io';
import 'dart:typed_data';

import 'package:context/app/file_references.dart';
import 'package:context/app/app_state.dart';
import 'package:context/app/models.dart';
import 'package:context/app/whiteboard.dart';
import 'package:context/app/whiteboard_file.dart';
import 'package:context/app/whiteboard_drop.dart';
import 'package:context/ui/widgets/whiteboard_pane.dart';
import 'package:context/ui/widgets/whiteboard_drop_surface.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class DropReader extends FileWhiteboardReader {
  @override
  Stream<void> changes(String markdownPath) => const Stream.empty();
  @override
  Future<List<RecentContext>> recent(
    String path,
    SessionProvider provider,
    int limit,
  ) async => List.generate(
    whiteboardSlotCount,
    (i) => RecentContext(
      provider: SessionProvider.codex,
      id: 'drop-$i',
      title: 'Drop item $i',
      updatedAt: i,
      localDrop: true,
      agentPrompt: 'Read `/drop-$i/README.md`.',
    ),
  );
  @override
  Future<ResponseHistory> history(
    String path,
    RecentContext session,
    int limit,
  ) async => ResponseHistory(
    [
      SessionResponse(
        text: 'Material for ${session.id}',
        timestamp: '',
        turnId: session.id,
      ),
    ],
    null,
    false,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('agent paths use the board distro and Windows mount paths', () {
    const board = r'\\wsl.localhost\Ubuntu\home\me\Context\whiteboard.md';
    expect(
      dropAgentPath(r'\\wsl.localhost\Ubuntu\home\me\a.md', board: board),
      '/home/me/a.md',
    );
    expect(
      dropAgentPath(r'D:\My Files\a.png', board: board),
      '/mnt/d/My Files/a.png',
    );
    expect(
      dropAgentPath(r'\\wsl.localhost\Debian\tmp\a', board: board),
      r'\\wsl.localhost\Debian\tmp\a',
    );
    expect(dropAgentPath(r'D:\a', board: r'C:\Context\whiteboard.md'), r'D:\a');
  });

  test(
    'files stay in place, README and preview links preserve special paths',
    () async {
      final root = Directory.systemTemp.createTempSync('context-drop-');
      addTearDown(() => root.deleteSync(recursive: true));
      final file = File.fromUri(root.uri.resolve('image%20(%231)%20%25.png'))
        ..writeAsBytesSync([1, 2, 3]);
      String? body;
      String? prompt;
      final drops = WhiteboardDrop(
        publish: (board, title, output, agent, dropFolder) async {
          expect(board, '${root.path}${Platform.pathSeparator}whiteboard.md');
          expect(title, 'image (#1) %.png');
          body = output;
          prompt = agent;
          expect(dropFolder, isNot(contains(Platform.pathSeparator)));
        },
      );
      await drops.publish('${root.path}/sessions.md', {
        'files': [file.path],
      });
      expect(prompt, startsWith('Read `'));
      final readme = prompt!.split('`')[1];
      expect(File(readme).readAsStringSync(), contains(file.path));
      expect(body, contains('![image (#1) %.png]'));
      final encoded = RegExp(r'<([^>]+)>').firstMatch(body!)![1]!;
      expect(FileReferenceResolver.clean(encoded), file.path);
      expect(file.readAsBytesSync(), [1, 2, 3]);
      expect(Directory(readme).parent.listSync().length, 2);
      final marker = File('${File(readme).parent.path}/.context-drop.json');
      expect(marker.readAsStringSync(), contains('context.whiteboard.drop.v1'));
    },
  );

  test(
    'pasted text and image are saved; missing input never publishes',
    () async {
      final root = Directory.systemTemp.createTempSync('context-paste-');
      addTearDown(() => root.deleteSync(recursive: true));
      var publishes = 0;
      final drops = WhiteboardDrop(
        publish: (_, title, body, prompt, dropFolder) async {
          publishes++;
        },
      );
      final md = '${root.path}/sessions.md';
      final prompt = await drops.publish(md, {'text': '# My note\n\nDetails'});
      final folder = File(prompt.split('`')[1]).parent;
      expect(
        File('${folder.path}/message.md').readAsStringSync(),
        '# My note\n\nDetails',
      );
      final bytes = Uint8List.fromList([1, 2, 3]);
      final image = await drops.publish(md, {
        'image': bytes,
        'extension': 'png',
      });
      final imageFolder = File(image.split('`')[1]).parent;
      expect(
        File('${imageFolder.path}/clipboard.png').readAsBytesSync(),
        bytes,
      );
      await expectLater(drops.publish(md, {}), throwsStateError);
      await expectLater(
        drops.publish(md, {
          'files': ['${root.path}/missing'],
        }),
        throwsStateError,
      );
      await expectLater(
        drops.publish(md, {'text': 'x' * (2 * 1024 * 1024 + 1)}),
        throwsStateError,
      );
      expect(publishes, 2);
    },
  );

  test(
    'pasting a quoted existing path references it instead of storing text',
    () async {
      final root = Directory.systemTemp.createTempSync('context-path-paste-');
      addTearDown(() => root.deleteSync(recursive: true));
      final file = File('${root.path}/report.md')
        ..writeAsStringSync('unchanged');
      final drop = WhiteboardDrop(
        publish: (_, title, body, prompt, dropFolder) async {
          expect(title, 'report.md');
          expect(body, isNot(contains('message.md')));
        },
      );
      await drop.publish('${root.path}/sessions.md', {
        'text': '"${file.path}"',
      });
      expect(file.readAsStringSync(), 'unchanged');
    },
  );

  test(
    'writer failure keeps staged content for recovery and reports failure',
    () async {
      final root = Directory.systemTemp.createTempSync('context-failed-drop-');
      addTearDown(() => root.deleteSync(recursive: true));
      final drop = WhiteboardDrop(
        publish: (_, title, body, prompt, dropFolder) async {
          throw StateError('locked');
        },
      );
      await expectLater(
        drop.publish('${root.path}/sessions.md', {'text': 'recover me'}),
        throwsStateError,
      );
      final folder =
          Directory('${root.path}/whiteboard-drops').listSync().single
              as Directory;
      expect(
        File('${folder.path}/message.md').readAsStringSync(),
        'recover me',
      );
    },
  );

  testWidgets(
    'drop overlay stays inside its pane and disabled pane rejects events',
    (tester) async {
      final key = GlobalKey<WhiteboardDropSurfaceState>();
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(whiteboardInputChannel, (call) async {
            calls.add(call);
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(whiteboardInputChannel, null),
      );
      Future<void> event(String method, Object args) async {
        await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .handlePlatformMessage(
              whiteboardInputChannel.name,
              const StandardMethodCodec().encodeMethodCall(
                MethodCall(method, args),
              ),
              (_) {},
            );
        await tester.pump();
      }

      Widget page(bool enabled) => MaterialApp(
        home: Scaffold(
          body: Row(
            children: [
              const SizedBox(width: 250, child: Text('Sessions')),
              Expanded(
                child: WhiteboardDropSurface(
                  key: key,
                  path: '/work/sessions.md',
                  enabled: enabled,
                  onPublished: () {},
                  child: const Text('Board'),
                ),
              ),
            ],
          ),
        ),
      );
      await tester.pumpWidget(page(true));
      await tester.pump();
      await event('hover', true);
      final overlay = find.byKey(const ValueKey('whiteboard-drop-overlay'));
      expect(overlay, findsOneWidget);
      expect(tester.getTopLeft(overlay).dx, greaterThanOrEqualTo(250));
      expect(find.text('Sessions'), findsOneWidget);
      final bounds = calls.last.arguments as Float64List;
      expect(bounds.first, 250 * tester.view.devicePixelRatio);
      await event('hover', false);
      expect(overlay, findsNothing);
      await tester.pumpWidget(page(false));
      await tester.pump();
      await event('hover', true);
      expect(overlay, findsNothing);
      expect(calls.last.arguments, Float64List(4));
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'paste publishes once and reports completion without notifications',
    (tester) async {
      final root = Directory.systemTemp.createTempSync('context-paste-widget-');
      addTearDown(() => root.deleteSync(recursive: true));
      final key = GlobalKey<WhiteboardDropSurfaceState>();
      var count = 0;
      var published = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            whiteboardInputChannel,
            (call) async => call.method == 'paste' ? {'text': 'hello'} : null,
          );
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(whiteboardInputChannel, null),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: WhiteboardDropSurface(
              key: key,
              path: '${root.path}/sessions.md',
              enabled: true,
              publisher: WhiteboardDrop(
                publish: (_, title, body, prompt, dropFolder) async {
                  count++;
                },
              ),
              onPublished: () => published = true,
              child: const Text('Board'),
            ),
          ),
        ),
      );
      await tester.runAsync(() => key.currentState!.paste());
      await tester.pump();
      expect(count, 1);
      expect(published, isTrue);
      expect(find.text('Preparing drop...'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('retained pane updates native bounds on resize without polling', (
    tester,
  ) async {
    final calls = <MethodCall>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(whiteboardInputChannel, (call) async {
      calls.add(call);
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(whiteboardInputChannel, null),
    );
    final pane = WhiteboardDropSurface(
      path: '/work/sessions.md',
      enabled: true,
      onPublished: () {},
      child: const Text('Board'),
    );
    Widget page(double left) => MaterialApp(
      home: Scaffold(
        body: Row(
          children: [
            SizedBox(width: left),
            Expanded(child: pane),
          ],
        ),
      ),
    );
    await tester.pumpWidget(page(100));
    await tester.pump();
    expect(
      (calls.last.arguments as Float64List).first,
      100 * tester.view.devicePixelRatio,
    );
    await tester.pumpWidget(page(300));
    await tester.pump();
    expect(
      (calls.last.arguments as Float64List).first,
      300 * tester.view.devicePixelRatio,
    );
    final count = calls.length;
    await tester.pump(const Duration(minutes: 5));
    expect(calls.length, count);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'six slim drop tabs copy prompts; Ctrl+V stays out of editable fields',
    (tester) async {
      var copied = '';
      var pastes = 0;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        if (call.method == 'Clipboard.getData') return {'text': copied};
        return null;
      });
      messenger.setMockMethodCallHandler(whiteboardInputChannel, (call) async {
        if (call.method == 'paste') pastes++;
        return null;
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(SystemChannels.platform, null);
        messenger.setMockMethodCallHandler(whiteboardInputChannel, null);
      });
      final state = AppState.forTesting(sendRequest: (_) {})
        ..sessionsMarkdownPath = '/work/sessions.md';
      final text = TextEditingController();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                TextField(controller: text),
                Expanded(
                  child: WhiteboardPane(appState: state, reader: DropReader()),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final tabY = tester
          .getCenter(find.byKey(const ValueKey('whiteboard-session-drop-0')))
          .dy;
      for (var i = 0; i < whiteboardSlotCount; i++) {
        final row = find.byKey(ValueKey('whiteboard-session-drop-$i'));
        expect(row, findsOneWidget);
        expect(tester.getSize(row).height, 30);
        expect(tester.getCenter(row).dy, tabY);
      }
      await tester.tap(
        find.byKey(const ValueKey('whiteboard-drop-copy-drop-2')),
      );
      await tester.pumpAndSettle();
      expect(copied, 'Read `/drop-2/README.md`.');
      expect(find.text('Material for drop-0'), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);
      await tester.tap(find.text('Drop item 1'));
      await tester.pumpAndSettle();
      expect(copied, 'Read `/drop-1/README.md`.');
      expect(find.text('Material for drop-1'), findsOneWidget);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(pastes, 1);
      await tester.tap(find.byType(TextField));
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(pastes, 1);
      expect(text.text, copied);
      await tester.pumpWidget(const SizedBox());
      state.dispose();
      text.dispose();
    },
  );
}
