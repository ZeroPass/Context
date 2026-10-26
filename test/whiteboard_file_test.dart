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
  String? body;
  int recentReads = 0;
  Completer<List<RecentContext>>? pending;
  List<RecentContext> entries = List.generate(
    whiteboardSlotCount,
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
  ) async {
    recentReads++;
    return pending?.future ?? entries.take(limit).toList();
  }

  @override
  Future<ResponseHistory> history(
    String path,
    RecentContext session,
    int limit,
  ) async => ResponseHistory(
    [
      SessionResponse(
        text: body ?? 'Published body for ${session.id}',
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

  Future<void> captureTabs(
    WidgetTester tester,
    double width, {
    String suffix = '',
  }) async {
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
          '$destination/published-tabs-${width.toInt()}$suffix.png',
        ).writeAsBytes(data!.buffer.asUint8List());
      } finally {
        image.dispose();
      }
    });
  }

  Future<(AppState, PublishedTabsReader)> mountTabs(
    WidgetTester tester, {
    double width = 1000,
    PublishedTabsReader? source,
  }) async {
    tester.view.physicalSize = Size(width, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final state = AppState.forTesting(sendRequest: (_) {})
      ..sessionsMarkdownPath = '/test/Context/sessions.md';
    final reader = source ?? PublishedTabsReader();
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
      'six shorter tabs taper in one top row and stay clickable at $width px',
      (tester) async {
        await mountTabs(tester, width: width);
        expect(find.text('Published entries'), findsNothing);
        expect(find.text('6 published'), findsNothing);
        final y = tester.getCenter(tab('tab-0')).dy;
        for (var i = 0; i < whiteboardSlotCount; i++) {
          expect(tester.getCenter(tab('tab-$i')).dy, y);
          expect(tester.getSize(tab('tab-$i')).height, 30);
          expect(selected(tester, 'tab-$i'), i == 0);
          if (i > 0) {
            expect(
              tester.getRect(tab('tab-$i')).left,
              greaterThan(tester.getRect(tab('tab-${i - 1}')).right),
            );
            expect(
              tester.getSize(tab('tab-$i')).width,
              lessThan(tester.getSize(tab('tab-${i - 1}')).width),
            );
          }
        }
        expect(find.text('Published body for tab-0'), findsOneWidget);
        expect(
          tester.getRect(tab('tab-0')).bottom,
          lessThan(tester.getRect(find.text('Published body for tab-0')).top),
        );
        final fade = find.byKey(const ValueKey('whiteboard-aging-tab-5'));
        expect(tester.widget<ShaderMask>(fade).blendMode, BlendMode.dstIn);
        await captureTabs(tester, width, suffix: '-latest');
        final strip = find.byKey(const ValueKey('whiteboard-published-tabs'));
        final toolbar = find.byKey(
          const ValueKey('whiteboard-publication-toolbar'),
        );
        final copy = find.byKey(const ValueKey('whiteboard-copy-prompt'));
        final refresh = find.byKey(
          const ValueKey('whiteboard-publication-refresh'),
        );
        expect(tester.getSize(toolbar).height, 30);
        for (final action in [copy, refresh]) {
          expect(tester.getCenter(action).dy, closeTo(y, 0.1));
          expect(
            tester.getRect(action).left,
            greaterThan(tester.getRect(strip).right),
          );
          expect(action.hitTestable(), findsOneWidget);
        }
        final copyRect = tester.getRect(copy);
        final refreshRect = tester.getRect(refresh);
        final scroll = tester.widget<SingleChildScrollView>(strip).controller!;
        if (width < 500) {
          expect(scroll.position.maxScrollExtent, greaterThan(0));
          await tester.drag(strip, const Offset(-900, 0));
          await tester.pumpAndSettle();
          expect(scroll.offset, greaterThan(0));
        } else {
          expect(scroll.position.maxScrollExtent, 0);
        }
        await tester.tap(tab('tab-5'));
        await tester.pumpAndSettle();
        expect(find.text('Published body for tab-5'), findsOneWidget);
        expect(selected(tester, 'tab-5'), isTrue);
        expect(selected(tester, 'tab-0'), isFalse);
        expect(tester.getRect(copy), copyRect);
        expect(tester.getRect(refresh), refreshRect);
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
      await tester.drag(strip, const Offset(-900, 0));
      await tester.pumpAndSettle();
      await tester.tap(tab('tab-4'));
      await tester.pumpAndSettle();
      final newEntry = RecentContext(
        provider: SessionProvider.codex,
        id: 'tab-new',
        title: 'Newest published report',
        updatedAt: 20,
      );
      reader.entries = [newEntry, ...reader.entries.take(5)];
      reader.updates.add(null);
      await tester.pumpAndSettle();
      expect(find.text('Published body for tab-4'), findsOneWidget);
      expect(selected(tester, 'tab-4'), isTrue);
      expect(tab('tab-5'), findsNothing);

      // Pruning the pinned entry falls back to the newest retained tab.
      reader.entries = reader.entries.take(5).toList();
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

  testWidgets(
    'toolbar refresh keeps its size and actions fixed while loading',
    (tester) async {
      final (_, reader) = await mountTabs(tester);
      final toolbar = find.byKey(
        const ValueKey('whiteboard-publication-toolbar'),
      );
      final refresh = find.byKey(
        const ValueKey('whiteboard-publication-refresh'),
      );
      final copy = find.byKey(const ValueKey('whiteboard-copy-prompt'));
      final rect = tester.getRect(toolbar);
      final refreshRect = tester.getRect(refresh);
      final reads = reader.recentReads;
      reader.pending = Completer<List<RecentContext>>();
      await tester.tap(refresh);
      await tester.pump();
      expect(reader.recentReads, reads + 1);
      expect(tester.widget<IconButton>(refresh).onPressed, isNull);
      expect(tester.widget<IconButton>(copy).onPressed, isNotNull);
      expect(tester.getRect(toolbar), rect);
      expect(tester.getRect(refresh), refreshRect);
      expect(
        find.descendant(
          of: refresh,
          matching: find.byType(CircularProgressIndicator),
        ),
        findsOneWidget,
      );
      reader.pending!.complete(reader.entries);
      reader.pending = null;
      await tester.pumpAndSettle();
      expect(tester.widget<IconButton>(refresh).onPressed, isNotNull);
      expect(tester.getRect(toolbar), rect);
      expect(tester.getRect(refresh), refreshRect);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('top publication strip stays fixed while a long output scrolls', (
    tester,
  ) async {
    final reader = PublishedTabsReader()
      ..body = List.generate(80, (i) => 'Report paragraph $i.').join('\n\n');
    await mountTabs(tester, source: reader);
    final strip = find.byKey(const ValueKey('whiteboard-published-tabs'));
    final scroll = tester
        .widget<SingleChildScrollView>(
          find.byKey(const ValueKey('whiteboard-scroll')),
        )
        .controller!;
    final top = tester.getRect(strip).top;
    expect(top, lessThan(100));
    expect(scroll.position.maxScrollExtent, greaterThan(0));
    scroll.jumpTo(scroll.position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(tester.getRect(strip).top, top);
    expect(tab('tab-5').hitTestable(), findsOneWidget);
    await tester.tap(tab('tab-5'));
    await tester.pumpAndSettle();
    expect(selected(tester, 'tab-5'), isTrue);
    expect(scroll.offset, 0);
    expect(tester.takeException(), isNull);
  });

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
    'parser keeps newest six and ignores debris without changing Markdown',
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
      expect(posts.map((p) => p.id), [
        'post-7',
        'post-6',
        'post-5',
        'post-4',
        'post-3',
        'post-2',
      ]);
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
    expect(find.text('Published entries'), findsNothing);
    final copyPrompt = find.byKey(const ValueKey('whiteboard-copy-prompt'));
    expect(copyPrompt, findsOneWidget);
    await tester.tap(copyPrompt);
    await tester.pump(const Duration(milliseconds: 300));
    expect(clipboard, whiteboardPublishPrompt(state.sessionsMarkdownPath));
    expect(
      tester
          .widget<Semantics>(
            find.byKey(const ValueKey('whiteboard-copy-feedback')),
          )
          .properties
          .label,
      contains('First prompt copied. Paste it to your agent.'),
    );
    expect(
      find.descendant(
        of: copyPrompt,
        matching: find.byIcon(Icons.check_rounded),
      ),
      findsOneWidget,
    );
    expect(find.byType(SnackBar), findsNothing);
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
