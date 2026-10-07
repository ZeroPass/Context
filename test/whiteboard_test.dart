import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:context/app/app_state.dart';
import 'package:context/app/file_references.dart';
import 'package:context/app/models.dart';
import 'package:context/app/whiteboard.dart';
import 'package:context/src/bindings/bindings.dart';
import 'package:context/ui/widgets/whiteboard_pane.dart';
import 'package:context/ui/widgets/passive_tooltip.dart';
import 'package:context/ui/widgets/recent_sessions.dart';
import 'package:context/ui/widgets/file_preview.dart';
import 'package:context/ui/widgets/file_location_button.dart';
import 'package:context/ui/widgets/video_preview.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeReader implements WhiteboardReader {
  final limits = <int>[];
  final histories = <(String, int)>[];
  final delayed = <String, Completer<ResponseHistory>>{};
  String answer = 'A completed response.\n\n- One result\n- Another result';
  int? recentCount;
  List<RecentContext>? sessions;
  Completer<List<RecentContext>>? recentWait;
  @override
  List<SessionProvider> get providers => const [SessionProvider.codex];
  @override
  Future<List<RecentContext>> recent(
    String path,
    SessionProvider provider,
    int limit,
  ) async {
    limits.add(limit);
    if (recentWait != null) return recentWait!.future;
    if (sessions != null) return sessions!.take(limit).toList();
    return List.generate(
      recentCount ?? limit,
      (n) => RecentContext(
        provider: provider,
        id: 'session-$n-1234',
        title: 'Synthetic session $n',
        updatedAt: 100 - n,
      ),
    );
  }

  @override
  Future<ResponseHistory> history(
    String path,
    RecentContext session,
    int limit,
  ) async {
    histories.add((session.id, limit));
    if (delayed.containsKey(session.id)) return delayed[session.id]!.future;
    return ResponseHistory(
      List.generate(
        limit,
        (n) => SessionResponse(
          text: n == 0 ? answer : 'Earlier answer $n',
          timestamp: '2026-09-30T12:00:00Z',
          turnId: '${session.id}:$n',
        ),
      ),
      '/home/luka/codex-out',
      false,
    );
  }

  @override
  void dispose() {}
}

class FakeWhiteboardVideo extends PreviewVideoSession {
  String? opened;
  bool released = false;
  @override
  Duration get position => Duration.zero;
  @override
  Duration get duration => const Duration(minutes: 1);
  @override
  bool get playing => false;
  @override
  bool get buffering => false;
  @override
  double get volume => 100;
  @override
  String? get error => null;
  @override
  Widget buildVideo() => const Text('Synthetic local video');
  @override
  Future<void> open(String path) async => opened = path;
  @override
  Future<void> togglePlayback() async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> seek(Duration position) async {}
  @override
  Future<void> setVolume(double volume) async {}
  @override
  void dispose() {
    released = true;
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

  test('WSL resolution strips line numbers and prefers session cwd', () async {
    final checks = <String>[];
    final resolver = FileReferenceResolver(
      markdownPath:
          r'\\wsl.localhost\Ubuntu-24.04\home\luka\codex-out\codex sessions.md',
      roots: [r'\\wsl.localhost\Ubuntu-24.04\home\luka\codex-out'],
      workDir: '/home/luka/codex-out/project',
      windows: true,
      exists: (path) async {
        checks.add(path);
        return path.endsWith(r'project\data\metrics.csv');
      },
    );
    final result = await resolver.resolve('data/metrics.csv:12:4');
    expect(result.paths, [
      r'\\wsl.localhost\Ubuntu-24.04\home\luka\codex-out\project\data\metrics.csv',
    ]);
    expect(checks, hasLength(1));
    expect(
      resolver.translate('/home/luka/codex-out/a.png#L12'),
      r'\\wsl.localhost\Ubuntu-24.04\home\luka\codex-out\a.png',
    );
    await resolver.resolve('data/metrics.csv:12:4');
    expect(checks, hasLength(1));
  });

  test(
    'fallback locations are bounded and ambiguous matches retained',
    () async {
      final checked = <String>[];
      final resolver = FileReferenceResolver(
        markdownPath: '/work/context.md',
        windows: false,
        roots: List.generate(30, (n) => '/root$n'),
        exists: (path) async {
          checked.add(path);
          return path == '/root1/image.png' || path == '/root2/image.png';
        },
      );
      final result = await resolver.resolve('image.png');
      expect(result.paths, ['/root1/image.png', '/root2/image.png']);
      expect(checked, hasLength(20));
      expect((await resolver.resolve('missing.csv')).missing, isTrue);
      expect(
        FileReferenceResolver.clean(r'C:\work\file.csv:1'),
        r'C:\work\file.csv',
      );
    },
  );

  test('file link labels preserve extensions without changing raw paths', () {
    expect(fileReferenceLabel('notes', 'docs/notes.md:12'), 'notes.md');
    expect(fileReferenceLabel('Notes', r'C:\docs\notes.md'), 'notes.md');
    expect(
      fileReferenceLabel('Report', 'reports/final.md#L2'),
      'Report (final.md)',
    );
    expect(
      fileReferenceLabel('Read the report', 'reports/final.markdown'),
      'Read the report (final.markdown)',
    );
    expect(fileReferenceLabel('metrics.csv', 'out/metrics.csv'), 'metrics.csv');
    expect(
      fileReferenceLabel('docs/notes.md:12', 'docs/notes.md:12'),
      'docs/notes.md:12',
    );
    expect(
      fileReferenceLabel('Image', 'sample%20image.png'),
      'Image (sample image.png)',
    );
    expect(
      fileReferenceLabel(
        'Documentation',
        'https://example.test/docs/README.md?view=1',
      ),
      'Documentation (README.md)',
    );
    expect(fileReferenceLabel('Website', 'https://example.test'), 'Website');
    expect(fileReferenceLabel('Folder', 'docs/reports'), 'Folder');
  });

  test(
    'preview allowlist includes Markdown, raster images and videos only',
    () {
      for (final extension in [
        'md',
        'markdown',
        'png',
        'jpg',
        'jpeg',
        'webp',
        'gif',
        'bmp',
        'mp4',
        'webm',
        'mov',
        'mkv',
        'avi',
        'm4v',
      ]) {
        expect(isWhiteboardPreview('file.$extension'), isTrue);
        expect(isWhiteboardPreview('file.${extension.toUpperCase()}'), isTrue);
      }
      for (final path in [
        'data.csv',
        'report.pdf',
        'config.json',
        'source.rs',
        'script.py',
        'image.svg',
        'archive.zip',
        'notes.txt',
        'folder',
      ]) {
        expect(isWhiteboardPreview(path), isFalse, reason: path);
      }
    },
  );

  test('Whiteboard wire layout matches Rust', () {
    final request = ReadWhiteboard(
      requestId: Uint64.fromBigInt(BigInt.one),
      sessionsMarkdownPath: 'p',
      provider: 'codex',
      sessionId: 's',
      limit: 3,
    );
    final bytes = request
        .bincodeSerialize()
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    expect(
      bytes,
      '01000000000000000100000000000000700500000000000000636f64657801000000000000007303000000',
    );
    final response = WhiteboardResult.bincodeDeserialize(
      Uint8List.fromList([
        1,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        2,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        123,
        125,
        0,
      ]),
    );
    expect(response.requestId, Uint64.fromBigInt(BigInt.one));
    expect(response.payloadJson, '{}');
    expect(response.error, isNull);
  });

  Future<void> mount(
    WidgetTester tester,
    AppState app,
    FakeReader reader, {
    double width = 650,
    double height = 950,
    ReferenceOpener openFile = openReference,
    PreviewVideoSession Function() videoFactory = NativePreviewVideoSession.new,
  }) async {
    tester.view.physicalSize = Size(width, height);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    app.sessionsMarkdownPath = '/test/codex-out/codex sessions.md';
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          fontFamily: 'Oxanium',
          colorSchemeSeed: const Color(0xFFFABD2F),
        ),
        home: Scaffold(
          body: RepaintBoundary(
            key: const ValueKey('whiteboard-snapshot'),
            child: Builder(
              builder: (context) => Material(
                color: Theme.of(context).colorScheme.surface,
                child: WhiteboardPane(
                  appState: app,
                  reader: reader,
                  openFile: openFile,
                  videoFactory: videoFactory,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
  }

  Finder tip(String message) => find.byWidgetPredicate(
    (widget) => widget is PassiveTooltip && widget.message == message,
  );

  Future<void> flushReferences(WidgetTester tester) async {
    for (var step = 0; step < 8; step++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      await tester.pump();
    }
  }

  Future<void> openFolderMenu(WidgetTester tester, Finder button) async {
    final mouse = await tester.startGesture(
      tester.getCenter(button),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await mouse.up();
    await tester.pumpAndSettle();
  }

  void expectPlainReference(WidgetTester tester, String label) {
    final text = find.text(label);
    expect(text, findsOneWidget);
    expect(
      find.ancestor(of: text, matching: find.byType(InkWell)),
      findsNothing,
    );
    final style = tester.widget<Text>(text).style!;
    expect(style.decoration, TextDecoration.none);
    final scheme = Theme.of(tester.element(text)).colorScheme;
    expect(style.color, isNot(scheme.primary));
  }

  String localPath(String path) =>
      Platform.isWindows ? path.replaceAll('/', '\\') : path;

  testWidgets(
    'recent rows reuse Context styling and leave only normal bottom padding',
    (tester) async {
      final app = AppState.forTesting(sendRequest: (_) {});
      final reader = FakeReader();
      await mount(tester, app, reader);
      expect(find.byType(RecentSessionCard), findsNWidgets(3));
      final row = find.byKey(
        const ValueKey('whiteboard-session-session-2-1234'),
      );
      final section = find.byKey(const ValueKey('whiteboard-recent-section'));
      expect(
        tester.getRect(section).bottom - tester.getRect(row).bottom,
        closeTo(10, 0.1),
      );
      final card = tester.widget<RecentSessionCard>(row);
      expect(card.trailing, isNull);
      expect(card.tip, 'Click card to view the last response');
      final title = find.descendant(
        of: row,
        matching: find.text('Synthetic session 2'),
      );
      final badge = find.descendant(
        of: row,
        matching: find.text(card.session.shortId),
      );
      expect(tester.getRect(badge).right, lessThan(tester.getRect(title).left));
      expect(tester.widget<Text>(title).style?.fontWeight, FontWeight.w500);
      final container = tester.widget<Container>(
        find.descendant(of: row, matching: find.byType(Container)).first,
      );
      final decoration = container.decoration! as BoxDecoration;
      final scheme = Theme.of(tester.element(row)).colorScheme;
      expect(
        decoration.color,
        scheme.surfaceContainerLowest.withValues(alpha: 0.62),
      );
      expect(decoration.borderRadius, BorderRadius.circular(10));
      final originalHeight = tester.getSize(section).height;
      reader.recentCount = 1;
      await tester.tap(tip('Refresh recent sessions'));
      await tester.pump();
      await tester.pump();
      expect(tester.getSize(section).height, lessThan(originalHeight));
      final onlyRow = find.byKey(
        const ValueKey('whiteboard-session-session-0-1234'),
      );
      expect(
        tester.getRect(section).bottom - tester.getRect(onlyRow).bottom,
        closeTo(10, 0.1),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
    },
  );

  testWidgets(
    'short narrow Whiteboard scrolls expanded recents without overflowing',
    (tester) async {
      final app = AppState.forTesting(sendRequest: (_) {});
      final reader = FakeReader();
      await mount(tester, app, reader, width: 280, height: 400);
      await tester.tap(find.byKey(const ValueKey('whiteboard-recent-toggle')));
      await tester.pump();
      await tester.pump();
      expect(reader.limits.last, 10);
      final scroll = find.byKey(const ValueKey('whiteboard-scroll'));
      expect(find.byType(ListView), findsNothing);
      await tester.drag(scroll, const Offset(0, -1000));
      await tester.pumpAndSettle();
      expect(
        find
            .byKey(const ValueKey('whiteboard-session-session-9-1234'))
            .hitTestable(),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
    },
  );

  testWidgets(
    'Codex only, latest response opens automatically, ten and history stay lazy',
    (tester) async {
      final app = AppState.forTesting(sendRequest: (_) {});
      final reader = FakeReader();
      app.items = const [
        ConfigItem(
          kind: ConfigItemKind.session,
          id: 'saved',
          name: 'Saved Context name',
          commandId: 'session-0-1234',
          colorHex: '',
          provider: SessionProvider.codex,
        ),
      ];
      await mount(tester, app, reader);
      expect(reader.limits, [3]);
      expect(reader.histories, [('session-0-1234', 1)]);
      expect(find.text('Last response'), findsOneWidget);
      expect(find.text('Codex'), findsOneWidget);
      expect(find.text('Kimi'), findsNothing);
      expect(find.text('Saved Context name'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('whiteboard-session-session-2-1234')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('whiteboard-session-session-3-1234')),
        findsNothing,
      );
      final answer = find.byKey(
        const ValueKey('whiteboard-answer-session-0-1234:0'),
      );
      final recents = find.byKey(const ValueKey('whiteboard-recent-section'));
      expect(
        tester.getRect(recents).top - tester.getRect(answer).bottom,
        closeTo(1, 0.1),
      );
      expect(
        tester.getRect(find.text('30/9 14:00')).top,
        greaterThan(tester.getRect(find.text('Last response')).bottom),
      );
      await tester.tap(find.byKey(const ValueKey('whiteboard-history-toggle')));
      await tester.pump();
      await tester.pump();
      expect(reader.histories.last, ('session-0-1234', 3));
      expect(find.text('Earlier answer 1', findRichText: true), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('whiteboard-recent-toggle')));
      await tester.pump();
      await tester.pump();
      expect(reader.limits.last, 10);
      await tester.tap(
        find.byKey(const ValueKey('whiteboard-session-session-1-1234')),
      );
      await tester.pump();
      await tester.pump();
      expect(reader.histories.last, ('session-1-1234', 1));
      expect(tip('Click card to copy resume command'), findsNothing);
      expect(find.byType(RecentProviderTab), findsOneWidget);
      expect(find.byType(RecentSectionHeader), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
    },
  );

  testWidgets('late response cannot replace the newly selected session', (
    tester,
  ) async {
    final app = AppState.forTesting(sendRequest: (_) {});
    final reader = FakeReader();
    reader.delayed['session-0-1234'] = Completer<ResponseHistory>();
    await mount(tester, app, reader);
    await tester.tap(
      find.byKey(const ValueKey('whiteboard-session-session-1-1234')),
    );
    await tester.pump();
    await tester.pump();
    reader.delayed['session-0-1234']!.complete(
      const ResponseHistory(
        [SessionResponse(text: 'STALE ANSWER', timestamp: '', turnId: 'old')],
        null,
        false,
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('STALE ANSWER', findRichText: true), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    app.dispose();
  });

  testWidgets(
    'ordinary file text never opens apps, folder reveal and menu remain explicit',
    (tester) async {
      final app = AppState.forTesting(sendRequest: (_) {});
      final reader = FakeReader();
      final opens = <(String, bool)>[];
      final directory = Directory.systemTemp.createTempSync(
        'context-whiteboard-files-',
      );
      final file = File('${directory.path}/metrics.csv');
      file.writeAsStringSync('synthetic,data\n');
      reader.answer =
          '**Results**\n\nSaved [metrics](${file.path.replaceAll('\\', '/')}:1).\n\n`metrics.csv:12`\n\nNo thinking traces.';
      app.setWhiteboardSearchRoots([directory.path]);
      await mount(
        tester,
        app,
        reader,
        width: 280,
        openFile: (path, {bool reveal = false}) async {
          opens.add((path, reveal));
        },
      );
      for (var step = 0; step < 3; step++) {
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 40));
        });
        await tester.pump();
      }
      expect(tip('Open in default app'), findsNothing);
      expect(tip('Open file location (right-click for more)'), findsWidgets);
      expect(find.byType(FileLocationButton), findsNWidgets(2));
      for (final label in ['metrics.csv', 'metrics.csv:12']) {
        expectPlainReference(tester, label);
        await tester.tap(find.text(label));
      }
      await tester.pump();
      expect(opens, isEmpty);
      expect(find.byType(WhiteboardFilePreview), findsNothing);
      final folder = find.byType(FileLocationButton).first;
      await tester.tap(folder);
      await tester.pump();
      expect(opens, [(localPath(file.path), true)]);
      await openFolderMenu(tester, folder);
      expect(find.text('Open in default app'), findsOneWidget);
      expect(opens, hasLength(1));
      await tester.tap(find.text('Open in default app'));
      await tester.pumpAndSettle();
      expect(opens, [
        (localPath(file.path), true),
        (localPath(file.path), false),
      ]);
      expect(tester.takeException(), isNull);
      final evidence = Platform.environment['CONTEXT_UI_EVIDENCE_DIR'];
      if (evidence != null) {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const ValueKey('whiteboard-snapshot')),
        );
        await tester.runAsync(() async {
          final image = await boundary.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          if (bytes != null) {
            await File(
              '$evidence/whiteboard-codex-narrow.png',
            ).writeAsBytes(bytes.buffer.asUint8List());
          }
          image.dispose();
        });
      }
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
      directory.deleteSync(recursive: true);
    },
  );

  testWidgets(
    'Markdown links preview locally above the response and follow their own directory',
    (tester) async {
      final app = AppState.forTesting(sendRequest: (_) {});
      final reader = FakeReader();
      final opens = <(String, bool)>[];
      final root = Directory.systemTemp.createTempSync('context-linked-md-');
      final docs = Directory('${root.path}/docs')..createSync();
      final child = File('${docs.path}/child.md');
      child.writeAsStringSync(
        '# Child document\n\nResolved beside the parent.',
      );
      final parent = File('${docs.path}/notes.md');
      File('${docs.path}/data.csv').writeAsStringSync('a,b\n');
      parent.writeAsStringSync(
        '# Parent document\n\n[Child](child.md)\n\n'
        '[Data](data.csv)\n\n[Missing](missing.md)',
      );
      reader.answer = 'Read [notes](${parent.path.replaceAll('\\', '/')}).';
      app.setWhiteboardSearchRoots([root.path]);
      await mount(
        tester,
        app,
        reader,
        openFile: (path, {bool reveal = false}) async {
          opens.add((path, reveal));
        },
      );
      Future<void> flushFiles() async {
        for (var step = 0; step < 8; step++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 40)),
          );
          await tester.pump();
        }
      }

      await flushFiles();
      expect(find.text('notes.md'), findsOneWidget);
      expect(tip('Open in Context'), findsOneWidget);
      await tester.tap(find.text('notes.md'));
      await flushFiles();
      expect(find.byType(WhiteboardFilePreview), findsOneWidget);
      final previewController = tester
          .widget<WhiteboardFilePreview>(find.byType(WhiteboardFilePreview))
          .controller;
      expect(previewController.error, isNull);
      expect(previewController.loading, isFalse);
      expect(previewController.markdown, contains('Parent document'));
      expect(find.text('Parent document', findRichText: true), findsOneWidget);
      expectPlainReference(tester, 'data.csv');
      expectPlainReference(tester, 'missing.md');
      expect(find.text('Not found · add location'), findsOneWidget);
      await tester.tap(find.text('data.csv'));
      await tester.tap(find.text('missing.md'));
      await tester.pump();
      expect(opens, isEmpty);
      final toolbarFolder = find
          .descendant(
            of: find.byType(WhiteboardFilePreview),
            matching: find.byType(FileLocationButton),
          )
          .first;
      await openFolderMenu(tester, toolbarFolder);
      expect(opens, isEmpty);
      await tester.tap(find.text('Open in default app'));
      await tester.pumpAndSettle();
      await flushFiles();
      expect(opens, [(localPath(parent.path), false)]);
      final preview = find.byKey(const ValueKey('whiteboard-file-preview'));
      expect(
        tester.getSize(preview).height,
        lessThan(tester.getSize(preview).width),
      );
      final response = find.text('Last response');
      expect(
        tester.getRect(preview).bottom,
        lessThanOrEqualTo(tester.getRect(response).top),
      );
      expect(find.text('Synthetic session 0'), findsOneWidget);
      await tester.tap(tip('Expand to app'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('child.md'));
      await flushFiles();
      expect(find.text('Child document', findRichText: true), findsOneWidget);
      expect(opens, [(localPath(parent.path), false)]);
      expect(find.text('Parent document', findRichText: true), findsNothing);
      await tester.tap(tip('Exit expanded view'));
      await tester.pumpAndSettle();
      expect(find.text('Child document', findRichText: true), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
      root.deleteSync(recursive: true);
    },
  );

  testWidgets(
    'compact response image and full preview support live zoom, reset and expansion',
    (tester) async {
      final app = AppState.forTesting(sendRequest: (_) {});
      final reader = FakeReader();
      final fixtureRoot = Directory('build/whiteboard-test-fixtures')
        ..createSync(recursive: true);
      final directory = fixtureRoot.createTempSync('image-');
      final file = File('${directory.path}/sample image.png').absolute;
      await tester.runAsync(() async {
        final recorder = ui.PictureRecorder();
        final canvas = ui.Canvas(recorder);
        canvas.drawColor(const Color(0xFFEEE8D4), ui.BlendMode.src);
        canvas.drawRRect(
          ui.RRect.fromRectAndRadius(
            const ui.Rect.fromLTWH(40, 30, 280, 140),
            const ui.Radius.circular(12),
          ),
          ui.Paint()..color = const Color(0xFF8EC07C),
        );
        canvas.drawCircle(
          const ui.Offset(180, 100),
          40,
          ui.Paint()..color = const Color(0xFFFABD2F),
        );
        final picture = recorder.endRecording();
        final image = await picture.toImage(360, 200);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        file.writeAsBytesSync(bytes!.buffer.asUint8List());
        image.dispose();
        picture.dispose();
      });
      final source = file.path.replaceAll('\\', '/').replaceAll(' ', '%20');
      await tester.pumpWidget(const MaterialApp(home: Scaffold()));
      await tester.runAsync(() async {
        final resolver = FileReferenceResolver(
          markdownPath: '',
          roots: const [],
        );
        // URI serialization also normalizes the Windows drive-letter case.
        for (final reference in {source, Uri.parse(source).toString()}) {
          final path = (await resolver.resolve(reference)).paths.single;
          final provider = FileImage(File(path));
          await precacheImage(
            provider,
            tester.element(find.byType(Scaffold)),
          ).timeout(const Duration(seconds: 10));
          await precacheImage(
            ResizeImage(provider, width: 400),
            tester.element(find.byType(Scaffold)),
          ).timeout(const Duration(seconds: 10));
        }
      });
      reader.answer =
          'Preview [sample image]($source).\n\n![Thumbnail]($source)';
      await mount(tester, app, reader);
      await tester.runAsync(() async {
        await precacheImage(
          FileImage(file),
          tester.element(find.byType(Scaffold)),
        );
      });
      for (var step = 0; step < 3; step++) {
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 40));
        });
        await tester.pump();
      }
      final thumbnail = find.byKey(
        const ValueKey('whiteboard-response-thumbnail'),
      );
      expect(thumbnail, findsOneWidget);
      expect(
        tester
            .renderObject<RenderImage>(
              find.descendant(of: thumbnail, matching: find.byType(RawImage)),
            )
            .image,
        isNotNull,
      );
      expect(tester.getSize(thumbnail).height, closeTo(90, 0.1));
      expect(tester.getSize(thumbnail).width, closeTo(162, 0.1));
      await tester.tap(find.text('sample image.png'));
      for (var step = 0; step < 3; step++) {
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 40));
        });
        await tester.pump();
      }
      expect(find.byType(WhiteboardFilePreview), findsOneWidget);
      expect(find.text('Last response'), findsOneWidget);
      expect(find.byType(InteractiveViewer), findsOneWidget);
      expect(tip('Expand to app'), findsOneWidget);
      expect(tip('Open in default app'), findsNothing);
      expect(tip('Open file location (right-click for more)'), findsWidgets);
      expect(find.byIcon(Icons.open_in_new_rounded), findsNothing);
      expect(find.byType(FileLocationButton), findsNWidgets(3));
      final background = tester.widget<ColoredBox>(
        find.byKey(const ValueKey('whiteboard-preview-background')),
      );
      final scheme = Theme.of(tester.element(thumbnail)).colorScheme;
      expect(background.color, scheme.surfaceContainerLow);
      expect(background.color, isNot(scheme.surface));
      final zoom = find.byKey(const ValueKey('whiteboard-image-zoom'));
      expect(
        find.descendant(of: zoom, matching: find.text('100%')),
        findsOneWidget,
      );
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: tester.getCenter(find.byType(InteractiveViewer)),
          scrollDelta: const Offset(0, -140),
        ),
      );
      await tester.pump();
      final transform = tester
          .widget<InteractiveViewer>(find.byType(InteractiveViewer))
          .transformationController!;
      final scale = transform.value.getMaxScaleOnAxis();
      final preview = find.byKey(const ValueKey('whiteboard-file-preview'));
      expect(
        tester.getSize(preview).height,
        lessThanOrEqualTo(tester.getSize(preview).width),
      );
      expect(scale, greaterThan(1));
      expect(
        find.descendant(
          of: zoom,
          matching: find.text('${(scale * 100).round()}%'),
        ),
        findsOneWidget,
      );
      final evidence = Platform.environment['CONTEXT_UI_EVIDENCE_DIR'];
      if (evidence != null) {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const ValueKey('whiteboard-snapshot')),
        );
        await tester.runAsync(() async {
          final image = await boundary.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(
            '$evidence/whiteboard-image-preview.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      await tester.tap(tip('Expand to app'));
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsOneWidget);
      expect(find.byType(InteractiveViewer), findsOneWidget);
      expect(
        tester
            .widget<InteractiveViewer>(find.byType(InteractiveViewer))
            .transformationController!
            .value
            .getMaxScaleOnAxis(),
        closeTo(scale, 0.001),
      );
      Navigator.of(tester.element(find.byType(Dialog))).pop();
      await tester.pumpAndSettle();
      await tester.tap(zoom);
      await tester.pump();
      expect(transform.value, Matrix4.identity());
      expect(
        find.descendant(of: zoom, matching: find.text('100%')),
        findsOneWidget,
      );
      tester.view.physicalSize = const Size(280, 950);
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.tap(tip('Close preview'));
      await tester.pump();
      expect(find.byType(InteractiveViewer), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
      // Flutter can retain a memory-mapped image until the tester process exits.
      // Keep this fixture under ignored build/, cleaned with the staged test tree.
    },
  );

  testWidgets(
    'refresh preserves chosen response and reopening selects latest',
    (tester) async {
      final app = AppState.forTesting(sendRequest: (_) {});
      final reader = FakeReader();
      await mount(tester, app, reader);
      expect(reader.histories, [('session-0-1234', 1)]);
      await tester.tap(
        find.byKey(const ValueKey('whiteboard-session-session-1-1234')),
      );
      await tester.pump();
      await tester.pump();
      await tester.tap(tip('Refresh recent sessions'));
      await tester.pump();
      await tester.pump();
      expect(reader.histories.last, ('session-1-1234', 1));
      await tester.pumpWidget(const SizedBox.shrink());
      await mount(tester, app, reader);
      expect(reader.histories.last, ('session-0-1234', 1));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
    },
  );

  testWidgets('empty recents load a response when a session later appears', (
    tester,
  ) async {
    final app = AppState.forTesting(sendRequest: (_) {});
    final reader = FakeReader()..recentCount = 0;
    await mount(tester, app, reader);
    expect(reader.histories, isEmpty);
    reader.recentCount = 1;
    await tester.tap(tip('Refresh recent sessions'));
    await tester.pump();
    await tester.pump();
    expect(reader.histories, [('session-0-1234', 1)]);
    expect(find.text('Last response'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    app.dispose();
  });

  RecentContext session(String id, int updatedAt) => RecentContext(
    provider: SessionProvider.codex,
    id: id,
    title: 'Session $id',
    updatedAt: updatedAt,
  );

  testWidgets('two second updates reorder recents and follow the newest', (
    tester,
  ) async {
    final app = AppState.forTesting(sendRequest: (_) {});
    final reader = FakeReader()..sessions = [session('a', 2), session('b', 1)];
    await mount(tester, app, reader);
    expect(reader.histories.last, ('a', 1));
    reader.sessions = [session('b', 3), session('a', 2)];
    reader.answer = 'Fresh answer';
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(reader.histories.last, ('b', 1));
    expect(find.text('Fresh answer', findRichText: true), findsOneWidget);
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('whiteboard-session-b'))).dy,
      lessThan(
        tester
            .getTopLeft(find.byKey(const ValueKey('whiteboard-session-a')))
            .dy,
      ),
    );
    expect(find.text('Latest'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    app.dispose();
  });

  testWidgets('older selection stays pinned while new cards move above it', (
    tester,
  ) async {
    final app = AppState.forTesting(sendRequest: (_) {});
    final reader = FakeReader()..sessions = [session('a', 2), session('b', 1)];
    await mount(tester, app, reader);
    await tester.tap(find.byKey(const ValueKey('whiteboard-session-b')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    reader.sessions = [session('c', 3), session('a', 2), session('b', 1)];
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(reader.histories.last, ('b', 1));
    expect(find.text('Pinned'), findsOneWidget);
    expect(find.byKey(const ValueKey('whiteboard-answer-b:0')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('whiteboard-follow-latest')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(reader.histories.last, ('c', 1));
    expect(find.text('Latest'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    app.dispose();
  });

  testWidgets('answer polling runs while metadata refresh is blocked', (
    tester,
  ) async {
    final app = AppState.forTesting(sendRequest: (_) {});
    final reader = FakeReader();
    await mount(tester, app, reader);
    reader.recentWait = Completer<List<RecentContext>>();
    reader.answer = 'Reply without a global refresh';
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(
      find.text('Reply without a global refresh', findRichText: true),
      findsOneWidget,
    );
    expect(find.byType(LinearProgressIndicator), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    reader.recentWait!.complete(const []);
    await tester.pump();
    app.dispose();
  });

  testWidgets('list and answer refresh controls are independent', (
    tester,
  ) async {
    final app = AppState.forTesting(sendRequest: (_) {});
    final reader = FakeReader();
    await mount(tester, app, reader);
    final lists = reader.limits.length;
    final replies = reader.histories.length;
    await tester.tap(find.byKey(const ValueKey('whiteboard-response-refresh')));
    await tester.pump();
    await tester.pump();
    expect(reader.limits.length, lists);
    expect(reader.histories.length, replies + 1);
    await tester.tap(tip('Refresh recent sessions'));
    await tester.pump();
    await tester.pump();
    expect(reader.limits.length, lists + 1);
    expect(reader.histories.length, replies + 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    app.dispose();
  });

  testWidgets('cached selection appears immediately while it is revalidated', (
    tester,
  ) async {
    final app = AppState.forTesting(sendRequest: (_) {});
    final reader = FakeReader();
    await mount(tester, app, reader);
    await tester.tap(
      find.byKey(const ValueKey('whiteboard-session-session-1-1234')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    reader.delayed['session-0-1234'] = Completer<ResponseHistory>();
    await tester.tap(
      find.byKey(const ValueKey('whiteboard-session-session-0-1234')),
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey('whiteboard-answer-session-0-1234:0')),
      findsOneWidget,
    );
    expect(find.text('Reading last response...'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    reader.delayed['session-0-1234']!.complete(
      const ResponseHistory([], null, false),
    );
    await tester.pump();
    app.dispose();
  });

  testWidgets(
    'unchanged background checks keep Markdown and scrolling intact',
    (tester) async {
      final app = AppState.forTesting(sendRequest: (_) {});
      final reader = FakeReader()
        ..answer = List.generate(50, (n) => 'Paragraph $n').join('\n\n');
      await mount(tester, app, reader, height: 600);
      final markdown = tester.widget<MarkdownBody>(find.byType(MarkdownBody));
      final controller = tester
          .widget<SingleChildScrollView>(
            find.byKey(const ValueKey('whiteboard-scroll')),
          )
          .controller!;
      controller.jumpTo(100);
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(
        identical(
          markdown,
          tester.widget<MarkdownBody>(find.byType(MarkdownBody)),
        ),
        isTrue,
      );
      expect(controller.offset, 100);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
    },
  );

  testWidgets(
    'offscreen Whiteboard stops polling and refreshes when revealed',
    (tester) async {
      final app = AppState.forTesting(sendRequest: (_) {});
      final reader = FakeReader();
      await mount(tester, app, reader);
      Future<void> show(bool visible) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: TickerMode(
                enabled: visible,
                child: WhiteboardPane(appState: app, reader: reader),
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));
      }

      await show(false);
      final lists = reader.limits.length;
      final replies = reader.histories.length;
      await tester.pump(const Duration(seconds: 6));
      expect(reader.limits.length, lists);
      expect(reader.histories.length, replies);
      await show(true);
      expect(reader.limits.length, greaterThan(lists));
      expect(reader.histories.length, greaterThan(replies));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
    },
  );

  testWidgets('following a new session preserves the open preview', (
    tester,
  ) async {
    final app = AppState.forTesting(sendRequest: (_) {});
    final root = Directory.systemTemp.createTempSync('context-follow-preview-');
    final notes = File('${root.path}/notes.md')
      ..writeAsStringSync('# Keep open');
    final reader = FakeReader()
      ..sessions = [session('a', 1)]
      ..answer = '[notes](${notes.path.replaceAll('\\', '/')})';
    await mount(tester, app, reader);
    await flushReferences(tester);
    await tester.tap(find.text('notes.md'));
    await flushReferences(tester);
    final preview = tester
        .widget<WhiteboardFilePreview>(find.byType(WhiteboardFilePreview))
        .controller;
    reader.sessions = [session('b', 2), session('a', 1)];
    reader.answer = 'New session answer';
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(reader.histories.last, ('b', 1));
    expect(
      identical(
        preview,
        tester
            .widget<WhiteboardFilePreview>(find.byType(WhiteboardFilePreview))
            .controller,
      ),
      isTrue,
    );
    expect(preview.markdown, contains('Keep open'));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    app.dispose();
    root.deleteSync(recursive: true);
  });

  testWidgets('manual answer refresh retries newly available files', (
    tester,
  ) async {
    final app = AppState.forTesting(sendRequest: (_) {});
    final root = Directory.systemTemp.createTempSync('context-retry-file-');
    final notes = File('${root.path}/notes.md');
    final reader = FakeReader()
      ..answer = '[notes](${notes.path.replaceAll('\\', '/')})';
    await mount(tester, app, reader);
    await flushReferences(tester);
    expect(find.text('Not found · add location'), findsOneWidget);
    notes.writeAsStringSync('# Newly available');
    await tester.tap(find.byKey(const ValueKey('whiteboard-response-refresh')));
    await tester.pump();
    await flushReferences(tester);
    expect(find.text('Not found · add location'), findsNothing);
    expect(tip('Open in Context'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    app.dispose();
    root.deleteSync(recursive: true);
  });

  testWidgets('response controls fit the minimum Whiteboard width', (
    tester,
  ) async {
    final app = AppState.forTesting(sendRequest: (_) {});
    final reader = FakeReader();
    await mount(tester, app, reader, width: 235);
    expect(
      find.byKey(const ValueKey('whiteboard-response-refresh')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('whiteboard-follow-latest')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    app.dispose();
  });

  testWidgets('empty recent lists remain quiet after the initial load', (
    tester,
  ) async {
    final app = AppState.forTesting(sendRequest: (_) {});
    final reader = FakeReader()..recentCount = 0;
    await mount(tester, app, reader);
    expect(find.text('No recent sessions found.'), findsOneWidget);
    reader.recentWait = Completer<List<RecentContext>>();
    await tester.pump(const Duration(seconds: 2));
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.text('Refreshing...'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    reader.recentWait!.complete(const []);
    await tester.pump();
    app.dispose();
  });

  testWidgets(
    'named links retain extensions, only previews and websites are clickable',
    (tester) async {
      final app = AppState.forTesting(sendRequest: (_) {});
      final reader = FakeReader();
      final opens = <(String, bool)>[];
      final root = Directory.systemTemp.createTempSync('context-link-labels-');
      final notes = File('${root.path}/notes.md')..writeAsStringSync('# Notes');
      final data = File('${root.path}/data.csv')..writeAsStringSync('a,b\n');
      reader.answer =
          '[Read notes](${notes.path.replaceAll('\\', '/')})\n\n'
          '[Results](${data.path.replaceAll('\\', '/')})\n\n'
          '[Web notes](https://example.test/notes.md)';
      await mount(
        tester,
        app,
        reader,
        openFile: (path, {bool reveal = false}) async {
          opens.add((path, reveal));
        },
      );
      for (var step = 0; step < 8; step++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 40)),
        );
        await tester.pump();
      }
      expect(find.text('Read notes (notes.md)'), findsOneWidget);
      expect(find.text('Results (data.csv)'), findsOneWidget);
      expect(find.text('Web notes (notes.md)'), findsOneWidget);
      expect(tip('Open in Context'), findsOneWidget);
      expect(tip('Right-click folder to open in default app'), findsOneWidget);
      expect(tip('Open in browser'), findsOneWidget);
      expect(find.byType(FileLocationButton), findsNWidgets(2));
      expectPlainReference(tester, 'Results (data.csv)');
      await tester.tap(find.text('Results (data.csv)'));
      await tester.pump();
      expect(opens, isEmpty);
      await tester.tap(find.text('Web notes (notes.md)'));
      await tester.pump();
      expect(opens, [('https://example.test/notes.md', false)]);
      expect(find.byType(WhiteboardFilePreview), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
      root.deleteSync(recursive: true);
    },
  );

  testWidgets(
    'fallback Markdown callbacks never launch unsupported files or folders',
    (tester) async {
      final app = AppState.forTesting(sendRequest: (_) {});
      final reader = FakeReader();
      final opens = <(String, bool)>[];
      final root = Directory.systemTemp.createTempSync('context-non-links-');
      final files = [
        for (final name in [
          'report.pdf',
          'image.svg',
          'config.json',
          'script.py',
        ])
          File('${root.path}/$name')..writeAsStringSync('synthetic fixture'),
      ];
      final folder = Directory('${root.path}/output')..createSync();
      reader.answer = [
        for (final file in files)
          '[${file.uri.pathSegments.last}](${file.path.replaceAll('\\', '/')}:1)',
        '[Output folder](${folder.path.replaceAll('\\', '/')})',
      ].join('\n\n');
      await mount(
        tester,
        app,
        reader,
        openFile: (path, {bool reveal = false}) async {
          opens.add((path, reveal));
        },
      );
      await flushReferences(tester);
      expect(find.byType(FileLocationButton), findsNWidgets(5));
      final markdown = tester.widget<MarkdownBody>(find.byType(MarkdownBody));
      for (final file in files) {
        final label = file.uri.pathSegments.last;
        expectPlainReference(tester, label);
        await tester.tap(find.text(label));
        markdown.onTapLink!(label, '${file.path}:1', '');
      }
      expectPlainReference(tester, 'Output folder');
      markdown.onTapLink!('Output folder', folder.path, '');
      await flushReferences(tester);
      expect(opens, isEmpty);
      expect(find.byType(WhiteboardFilePreview), findsNothing);
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
      root.deleteSync(recursive: true);
    },
  );

  testWidgets(
    'executable confirmation appears only for explicit folder-menu opening',
    (tester) async {
      final app = AppState.forTesting(sendRequest: (_) {});
      final reader = FakeReader();
      final opens = <(String, bool)>[];
      final root = Directory.systemTemp.createTempSync('context-script-menu-');
      final file = File('${root.path}/script.py')
        ..writeAsStringSync('# fixture');
      reader.answer = '[script](${file.path.replaceAll('\\', '/')})';
      await mount(
        tester,
        app,
        reader,
        openFile: (path, {bool reveal = false}) async {
          opens.add((path, reveal));
        },
      );
      await flushReferences(tester);
      expectPlainReference(tester, 'script.py');
      await tester.tap(find.text('script.py'));
      await tester.pump();
      expect(opens, isEmpty);
      expect(find.byType(AlertDialog), findsNothing);
      final folder = find.byType(FileLocationButton);
      await openFolderMenu(tester, folder);
      await tester.tap(find.text('Open in default app'));
      await tester.pumpAndSettle();
      expect(find.text('Open executable file?'), findsOneWidget);
      expect(opens, isEmpty);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(opens, isEmpty);
      await openFolderMenu(tester, folder);
      await tester.tap(find.text('Open in default app'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(opens, [(localPath(file.path), false)]);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
      root.deleteSync(recursive: true);
    },
  );

  testWidgets('video links open in Context without launching external apps', (
    tester,
  ) async {
    final app = AppState.forTesting(sendRequest: (_) {});
    final reader = FakeReader();
    final opens = <(String, bool)>[];
    final video = FakeWhiteboardVideo();
    final root = Directory.systemTemp.createTempSync('context-video-link-');
    final file = File('${root.path}/clip.mp4')..writeAsStringSync('fixture');
    reader.answer = '[clip](${file.path.replaceAll('\\', '/')}:1)';
    await mount(
      tester,
      app,
      reader,
      openFile: (path, {bool reveal = false}) async {
        opens.add((path, reveal));
      },
      videoFactory: () => video,
    );
    await flushReferences(tester);
    expect(tip('Open in Context'), findsOneWidget);
    await tester.tap(find.text('clip.mp4'));
    await flushReferences(tester);
    expect(video.opened, localPath(file.path));
    expect(find.byType(WhiteboardFilePreview), findsOneWidget);
    expect(find.text('Synthetic local video'), findsOneWidget);
    expect(opens, isEmpty);
    final toolbarFolder = find.descendant(
      of: find.byType(WhiteboardFilePreview),
      matching: find.byType(FileLocationButton),
    );
    await openFolderMenu(tester, toolbarFolder);
    await tester.tap(find.text('Open in default app'));
    await tester.pumpAndSettle();
    await flushReferences(tester);
    expect(opens, [(localPath(file.path), false)]);
    await tester.tap(tip('Close preview'));
    await tester.pump();
    expect(video.released, isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    app.dispose();
    root.deleteSync(recursive: true);
  });

  testWidgets(
    'answers and recents share one scroll area and use natural height',
    (tester) async {
      final app = AppState.forTesting(sendRequest: (_) {});
      final reader = FakeReader()
        ..answer = List.generate(
          20,
          (index) => 'Response paragraph $index.',
        ).join('\n\n');
      await mount(tester, app, reader, width: 450, height: 400);
      final scroll = find.byKey(const ValueKey('whiteboard-scroll'));
      final controller = tester
          .widget<SingleChildScrollView>(scroll)
          .controller!;
      final answer = find.byKey(
        const ValueKey('whiteboard-answer-session-0-1234:0'),
      );
      expect(tester.getSize(answer).height, greaterThan(400));
      expect(find.byType(ListView), findsNothing);
      expect(find.byType(SingleChildScrollView), findsOneWidget);
      expect(controller.position.maxScrollExtent, greaterThan(0));
      final recents = find.byKey(const ValueKey('whiteboard-recent-section'));
      final recentsTop = tester.getRect(recents).top;
      controller.jumpTo(controller.position.maxScrollExtent);
      await tester.pump();
      expect(tester.getRect(recents).top, lessThan(recentsTop));
      expect(
        find
            .byKey(const ValueKey('whiteboard-session-session-2-1234'))
            .hitTestable(),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('whiteboard-recent-toggle')));
      await tester.pump();
      await tester.pump();
      controller.jumpTo(controller.position.maxScrollExtent);
      await tester.pump();
      expect(tester.getSize(recents).height, greaterThan(400));
      expect(
        find
            .byKey(const ValueKey('whiteboard-session-session-9-1234'))
            .hitTestable(),
        findsOneWidget,
      );
      controller.jumpTo(0);
      await tester.pump();
      expect(find.text('Last response').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
    },
  );

  testWidgets(
    'long Markdown preview stops at a square while the pane still scrolls',
    (tester) async {
      final app = AppState.forTesting(sendRequest: (_) {});
      final reader = FakeReader();
      final root = Directory.systemTemp.createTempSync(
        'context-square-preview-',
      );
      final file = File('${root.path}/notes.md')
        ..writeAsStringSync(
          List.generate(
            50,
            (index) => 'Document paragraph $index.',
          ).join('\n\n'),
        );
      reader.answer = '[notes](${file.path.replaceAll('\\', '/')})';
      await mount(tester, app, reader, width: 450, height: 650);
      await flushReferences(tester);
      await tester.tap(find.text('notes.md'));
      await flushReferences(tester);
      final preview = find.byKey(const ValueKey('whiteboard-file-preview'));
      expect(tester.getSize(preview), const Size(450, 450));
      final markdownScroll = find.descendant(
        of: preview,
        matching: find.byType(SingleChildScrollView),
      );
      final documentController = tester
          .widget<SingleChildScrollView>(markdownScroll)
          .controller!;
      expect(documentController.position.maxScrollExtent, greaterThan(0));
      documentController.jumpTo(documentController.position.maxScrollExtent);
      await tester.pump();
      expect(
        find.text('Document paragraph 49.', findRichText: true).hitTestable(),
        findsOneWidget,
      );
      final paneController = tester
          .widget<SingleChildScrollView>(
            find.byKey(const ValueKey('whiteboard-scroll')),
          )
          .controller!;
      paneController.jumpTo(paneController.position.maxScrollExtent);
      await tester.pump();
      expect(
        find
            .byKey(const ValueKey('whiteboard-session-session-2-1234'))
            .hitTestable(),
        findsOneWidget,
      );
      paneController.jumpTo(0);
      await tester.pump();
      await tester.tap(tip('Expand to app'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('whiteboard-app-preview')),
        findsOneWidget,
      );
      expect(find.byType(WhiteboardFilePreview), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(tester.getSize(preview), const Size(450, 450));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
      root.deleteSync(recursive: true);
    },
  );
}
