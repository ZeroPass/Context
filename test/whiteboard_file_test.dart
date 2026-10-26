import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:context/app/app_state.dart';
import 'package:context/app/models.dart';
import 'package:context/app/whiteboard.dart';
import 'package:context/app/whiteboard_file.dart';
import 'package:context/app/workspace_paths.dart';
import 'package:context/ui/widgets/whiteboard_pane.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

String entry(int id, {String? body}) {
  final content = body ?? 'Output $id';
  final metadata = {
    'id': 'post-$id',
    'title': 'Post $id',
    'provider': id.isEven ? 'codex' : 'kimi',
    'cwd': '/work',
    'published_at_ms': 1700000000000 + id,
    'body_bytes': utf8.encode(content).length,
    'body_chars': content.length,
  };
  return '<!-- context:whiteboard:entry ${jsonEncode(metadata)} -->\n$content\n<!-- context:whiteboard:end post-$id -->\n';
}

class ExampleState extends AppState {
  ExampleState() : super.forTesting(sendRequest: (_) {});
  @override
  Future<void> loadConfig({String? markdownPath}) async {
    sessionsMarkdownPath = markdownPath!;
  }
}

class PublishedTabsReader extends FileWhiteboardReader {
  final updates = StreamController<void>.broadcast();
  List<RecentContext> entries = List.generate(
    4,
    (i) => RecentContext(
      provider: SessionProvider.codex,
      id: 'tab-$i',
      title: 'Report $i with a deliberately long descriptive title',
      updatedAt: 10 - i,
    ),
  );

  @override
  Stream<void> changes(String path) => updates.stream;

  @override
  Future<List<RecentContext>> recent(
    String path,
    SessionProvider provider,
    int limit,
  ) async => entries.take(limit).toList();

  @override
  Future<ResponseHistory> history(
    String path,
    RecentContext session,
    int limit,
  ) async => ResponseHistory(
    [
      SessionResponse(
        text: 'Published body for ${session.id}',
        timestamp: '',
        turnId: session.id,
      ),
    ],
    null,
    false,
  );

  @override
  void dispose() {
    unawaited(updates.close());
    super.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final manifest =
        jsonDecode(await rootBundle.loadString('FontManifest.json')) as List;
    for (final entry in manifest.cast<Map<String, dynamic>>()) {
      final loader = FontLoader(entry['family'] as String);
      for (final font
          in (entry['fonts'] as List).cast<Map<String, dynamic>>()) {
        loader.addFont(rootBundle.load(font['asset'] as String));
      }
      await loader.load();
    }
  });

  Future<void> captureTabs(WidgetTester tester, double width) async {
    final destination = Platform.environment['CONTEXT_UI_EVIDENCE_DIR'];
    if (destination == null) return;
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('published-tabs-snapshot')),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage();
      try {
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        await File(
          '$destination/published-tabs-${width.toInt()}.png',
        ).writeAsBytes(data!.buffer.asUint8List());
      } finally {
        image.dispose();
      }
    });
  }

  Future<(AppState, PublishedTabsReader)> mountTabs(
    WidgetTester tester, {
    double width = 1000,
  }) async {
    tester.view.physicalSize = Size(width, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final state = AppState.forTesting(sendRequest: (_) {})
      ..sessionsMarkdownPath = '/test/Context/sessions.md';
    final reader = PublishedTabsReader();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      reader.dispose();
      state.dispose();
    });
    await tester.pumpWidget(
      RepaintBoundary(
        key: const ValueKey('published-tabs-snapshot'),
        child: MaterialApp(
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFFB09C61),
            ),
            fontFamily: 'Oxanium',
          ),
          home: Scaffold(
            body: WhiteboardPane(appState: state, reader: reader),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return (state, reader);
  }

  Finder tab(String id) => find.byKey(ValueKey('whiteboard-session-$id'));
  bool selected(WidgetTester tester, String id) =>
      tester.widget<Semantics>(tab(id)).properties.selected!;

  for (final width in [1000.0, 260.0]) {
    testWidgets(
      'published tabs stay on one line and select output at $width px',
      (tester) async {
        await mountTabs(tester, width: width);
        final y = tester.getCenter(tab('tab-0')).dy;
        for (var i = 0; i < 4; i++) {
          expect(tester.getCenter(tab('tab-$i')).dy, y);
          expect(tester.getSize(tab('tab-$i')).height, 36);
          expect(selected(tester, 'tab-$i'), i == 0);
          if (i > 0) {
            expect(
              tester.getRect(tab('tab-$i')).left,
              greaterThan(tester.getRect(tab('tab-${i - 1}')).right),
            );
          }
        }
        expect(find.text('Published body for tab-0'), findsOneWidget);
        final strip = find.byKey(const ValueKey('whiteboard-published-tabs'));
        final scroll = tester.widget<SingleChildScrollView>(strip).controller!;
        if (width < 500) {
          expect(scroll.position.maxScrollExtent, greaterThan(0));
          await tester.drag(strip, const Offset(-500, 0));
          await tester.pumpAndSettle();
          expect(scroll.offset, greaterThan(0));
        } else {
          expect(scroll.position.maxScrollExtent, 0);
        }
        await tester.tap(tab('tab-3'));
        await tester.pumpAndSettle();
        expect(find.text('Published body for tab-3'), findsOneWidget);
        expect(selected(tester, 'tab-3'), isTrue);
        expect(selected(tester, 'tab-0'), isFalse);
        expect(tester.takeException(), isNull);
        await captureTabs(tester, width);
      },
    );
  }

  testWidgets(
    'published tabs retain pinning, follow new output and handle pruning',
    (tester) async {
      final (_, reader) = await mountTabs(tester, width: 260);
      final strip = find.byKey(const ValueKey('whiteboard-published-tabs'));
      await tester.drag(strip, const Offset(-500, 0));
      await tester.pumpAndSettle();
      await tester.tap(tab('tab-2'));
      await tester.pumpAndSettle();
      final newEntry = RecentContext(
        provider: SessionProvider.codex,
        id: 'tab-new',
        title: 'Newest published report',
        updatedAt: 20,
      );
      reader.entries = [newEntry, ...reader.entries.take(3)];
      reader.updates.add(null);
      await tester.pumpAndSettle();
      expect(find.text('Published body for tab-2'), findsOneWidget);
      expect(selected(tester, 'tab-2'), isTrue);
      expect(tab('tab-3'), findsNothing);

      // Pruning the pinned entry falls back to the newest retained tab.
      reader.entries = reader.entries.take(3).toList();
      reader.updates.add(null);
      await tester.pumpAndSettle();
      expect(find.text('Published body for tab-new'), findsOneWidget);
      expect(selected(tester, 'tab-new'), isTrue);
      expect(tester.widget<SingleChildScrollView>(strip).controller!.offset, 0);
      reader.entries = [];
      reader.updates.add(null);
      await tester.pumpAndSettle();
      expect(strip, findsNothing);
      expect(
        find.text('No published entries yet. Ask an agent: wb.md'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  test('publishing prompt has the dynamic full location and no embedded rules', () {
    expect(
      whiteboardPublishPrompt('/home/alex/My Context/sessions.md'),
      'Read `/home/alex/My Context/whiteboard.md` and follow its instructions to publish your last final answer.',
    );
    expect(
      whiteboardPublishPrompt(r'D:\Apps\Context\sessions.md'),
      r'Read `D:\Apps\Context\whiteboard.md` and follow its instructions to publish your last final answer.',
    );
    final wsl = whiteboardPublishPrompt(
      r'\\wsl.localhost\Debian\home\alex\My Context\sessions.md',
    );
    expect(wsl, contains('`/home/alex/My Context/whiteboard.md`'));
    expect(
      wsl,
      contains(
        r'Windows: `\\wsl.localhost\Debian\home\alex\My Context\whiteboard.md`',
      ),
    );
    expect(
      whiteboardPublishPrompt('//wsl\$/Ubuntu/home/bob/Context/sessions.md'),
      contains('`/home/bob/Context/whiteboard.md`'),
    );
    expect(whiteboardPublishPrompt(''), isEmpty);
    expect(
      whiteboardFilePath('//wsl\$/Ubuntu/home/bob/Context/sessions.md'),
      r'\\wsl$\Ubuntu\home\bob\Context\whiteboard.md',
    );
  });
  test(
    'parser keeps newest four and ignores debris without changing Markdown',
    () {
      final body = '# Full output\n\n[notes](notes.md)\n\n```text\n---\n```\n';
      final entries = List.generate(
        8,
        (id) => '${entry(id, body: body)}TRASH\n',
      ).join();
      final text =
          '<!-- instructions -->\n$entries'
          '<!-- context:whiteboard:entry broken -->\nunfinished';
      final posts = parseWhiteboard(text);
      expect(posts.map((p) => p.id), ['post-7', 'post-6', 'post-5', 'post-4']);
      expect(posts.every((p) => p.body == body), isTrue);
      expect(parseWhiteboard(entry(1) + entry(2) + entry(1)).map((p) => p.id), [
        'post-1',
        'post-2',
      ]);
    },
  );

  test(
    'paths migrate only the legacy default and keep codex-out for file predictions',
    () {
      expect(
        migratedSessionPath('/home/user/codex-out/codex sessions.md'),
        '/home/user/codex-out/Context/codex sessions.md',
      );
      expect(
        migratedSessionPath(
          r'\\wsl.localhost\Ubuntu\home\user\codex-out\codex sessions.md',
        ),
        r'\\wsl.localhost\Ubuntu\home\user\codex-out\Context\codex sessions.md',
      );
      expect(
        migratedSessionPath('/work/my-sessions.md'),
        '/work/my-sessions.md',
      );
      expect(
        whiteboardFilePath('/home/user/codex-out/Context/codex sessions.md'),
        '/home/user/codex-out/Context/whiteboard.md',
      );
      expect(
        sessionWorkspaceRoot('/home/user/codex-out/Context/codex sessions.md'),
        '/home/user/codex-out',
      );
    },
  );

  test(
    'example creation stays in the chosen folder and never overwrites',
    () async {
      final root = Directory.systemTemp.createTempSync('context-example-');
      final path = '${root.path}/Context/codex sessions.md';
      final state = ExampleState()..sessionsMarkdownPath = path;
      try {
        expect(await state.createExampleMarkdownFile(), path);
        expect(await File(path).exists(), isTrue);
        final before = await File(path).readAsString();
        await expectLater(state.createExampleMarkdownFile(), throwsException);
        expect(await File(path).readAsString(), before);
      } finally {
        state.dispose();
        root.deleteSync(recursive: true);
      }
    },
  );

  test(
    'file reader loads only pushed entries, not a session database',
    () async {
      final root = Directory.systemTemp.createTempSync('context-push-reader-');
      final reader = FileWhiteboardReader();
      final md = '${root.path}/codex sessions.md';
      try {
        await File(
          '${root.path}/whiteboard.md',
        ).writeAsString(entry(1) + entry(2));
        final items = await reader.recent(md, SessionProvider.codex, 10);
        expect(items.map((i) => i.id), ['post-2', 'post-1']);
        expect(
          (await reader.history(md, items.first, 3)).responses.single.text,
          'Output 2',
        );
        expect(reader.providers, isEmpty);
      } finally {
        reader.dispose();
        root.deleteSync(recursive: true);
      }
    },
  );

  test(
    'watch notices atomic replacement and ignores unrelated files',
    () async {
      final root = Directory.systemTemp.createTempSync('context-push-watch-');
      final reader = FileWhiteboardReader();
      final path = '${root.path}/whiteboard.md';
      StreamSubscription<void>? subscription;
      try {
        await File(path).writeAsString(entry(1));
        final changed = Completer<void>();
        subscription = reader.changes('${root.path}/codex sessions.md').listen((
          _,
        ) {
          if (!changed.isCompleted) changed.complete();
        });
        await File('${root.path}/unrelated.txt').writeAsString('ignore');
        await Future<void>.delayed(const Duration(milliseconds: 80));
        expect(changed.isCompleted, isFalse);
        final tmp = File('${root.path}/.whiteboard.test.tmp');
        await tmp.writeAsString(entry(2));
        await tmp.rename(path);
        await changed.future.timeout(const Duration(seconds: 2));
        expect(
          (await reader.recent(
            '${root.path}/codex sessions.md',
            SessionProvider.codex,
            3,
          )).single.title,
          'Post 2',
        );
      } finally {
        await subscription?.cancel();
        reader.dispose();
        root.deleteSync(recursive: true);
      }
    },
  );

  testWidgets('push pane shows newest output, no session tabs or pull controls', (
    tester,
  ) async {
    var clipboard = '';
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        clipboard = (call.arguments as Map)['text'] as String;
      }
      if (call.method == 'Clipboard.getData') return {'text': clipboard};
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    final root = Directory.systemTemp.createTempSync('context-push-pane-');
    final state = AppState.forTesting(sendRequest: (_) {})
      ..sessionsMarkdownPath = '${root.path}/codex sessions.md';
    final reader = FileWhiteboardReader();
    await tester.runAsync(
      () =>
          File('${root.path}/whiteboard.md').writeAsString(entry(1) + entry(2)),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WhiteboardPane(appState: state, reader: reader),
        ),
      ),
    );
    for (var n = 0; n < 20; n++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pump(const Duration(milliseconds: 30));
    }
    expect(find.text('Published entries'), findsOneWidget);
    final copyPrompt = find.byKey(const ValueKey('whiteboard-copy-prompt'));
    expect(copyPrompt, findsOneWidget);
    await tester.tap(copyPrompt);
    await tester.pump(const Duration(milliseconds: 300));
    expect(clipboard, whiteboardPublishPrompt(state.sessionsMarkdownPath));
    expect(
      find.text('First prompt copied. Paste it to your agent.'),
      findsOneWidget,
    );
    expect(find.text('Output 2'), findsOneWidget);
    expect(find.text('Codex'), findsNothing);
    expect(find.text('Last 3'), findsNothing);
    expect(
      find.byKey(const ValueKey('whiteboard-recent-toggle')),
      findsNothing,
    );
    await tester.runAsync(() async {
      final tmp = File('${root.path}/.whiteboard.next.tmp');
      await tmp.writeAsString(entry(2) + entry(3));
      await tmp.rename('${root.path}/whiteboard.md');
    });
    // Each fake-clock turn separately delivers real stat/read/close completions.
    for (var n = 0; n < 20; n++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pump(const Duration(milliseconds: 30));
      if (find.text('Output 3').evaluate().isNotEmpty) break;
    }
    expect(find.text('Output 3'), findsOneWidget);
    expect(find.text('Output 2'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    reader.dispose();
    state.dispose();
    root.deleteSync(recursive: true);
  });
}
