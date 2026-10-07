import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:context/app/clipboard_writer.dart';
import 'package:context/app/app_state.dart';
import 'package:context/app/file_references.dart';
import 'package:context/app/models.dart';
import 'package:context/app/preview_actions.dart';
import 'package:context/app/whiteboard.dart';
import 'package:context/ui/widgets/file_location_button.dart';
import 'package:context/ui/widgets/file_preview.dart';
import 'package:context/ui/widgets/preview_context_menu.dart';
import 'package:context/ui/widgets/video_preview.dart';
import 'package:context/ui/widgets/whiteboard_pane.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class RecordingActions extends PreviewActions {
  final copied = <String>[];
  final saved = <String>[];
  final snapshots = <Uint8List>[];
  bool fail = false;
  @override
  Future<bool> copy(String path, {String? markdown}) async {
    if (fail) throw StateError('Clipboard unavailable');
    copied.add(path);
    return true;
  }

  @override
  Future<bool> saveAs(String path) async {
    saved.add(path);
    return true;
  }

  @override
  Future<bool> copyImage(Future<Uint8List> Function() bytes) async {
    snapshots.add(await bytes());
    return true;
  }
}

class SnapshotVideo extends PreviewVideoSession {
  int captures = 0;
  @override
  Duration get position => const Duration(seconds: 5);
  @override
  Duration get duration => const Duration(seconds: 10);
  @override
  bool get playing => false;
  @override
  bool get buffering => false;
  @override
  double get volume => 100;
  @override
  String? get error => null;
  @override
  Widget buildVideo() => const SizedBox.expand(child: Text('Video surface'));
  @override
  Future<void> open(String path) async {}
  @override
  Future<void> togglePlayback() async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> seek(Duration position) async {}
  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<Uint8List> snapshot() async {
    captures++;
    return Uint8List.fromList([1, 2, 3]);
  }
}

Future<void> secondaryClick(WidgetTester tester, Finder target) async {
  final mouse = await tester.startGesture(
    tester.getCenter(target),
    kind: PointerDeviceKind.mouse,
    buttons: kSecondaryMouseButton,
  );
  await mouse.up();
  await tester.pumpAndSettle();
}

class MarkdownReader implements WhiteboardReader {
  MarkdownReader(this.path, this.directory);
  final String path;
  final String directory;
  @override
  List<SessionProvider> get providers => const [SessionProvider.codex];
  @override
  Future<List<RecentContext>> recent(
    String path,
    SessionProvider provider,
    int limit,
  ) async => [
    RecentContext(
      provider: provider,
      id: 'synthetic',
      title: 'Report',
      updatedAt: 1,
    ),
  ];
  @override
  Future<ResponseHistory> history(
    String config,
    RecentContext session,
    int limit,
  ) async => ResponseHistory(
    [
      SessionResponse(
        text: '[Document](${path.replaceAll('\\', '/')})',
        timestamp: '',
        turnId: 'test',
      ),
    ],
    directory,
    false,
  );
  @override
  void dispose() {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const channel = MethodChannel('context/clipboard');

  test(
    'image copying produces full-size bottom-up Windows bitmap pixels',
    () async {
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      canvas.drawRect(
        const ui.Rect.fromLTWH(0, 0, 2, 1),
        ui.Paint()..color = const ui.Color(0xFFFF0000),
      );
      canvas.drawRect(
        const ui.Rect.fromLTWH(0, 1, 2, 1),
        ui.Paint()..color = const ui.Color(0xFF0000FF),
      );
      final picture = recorder.endRecording();
      final image = await picture.toImage(2, 2);
      final encoded = (await image.toByteData(
        format: ui.ImageByteFormat.png,
      ))!.buffer.asUint8List();
      image.dispose();
      picture.dispose();
      final dib = await PreviewActions.imageDib(encoded);
      final header = ByteData.sublistView(dib);
      expect(header.getUint32(0, Endian.little), 40);
      expect(header.getInt32(4, Endian.little), 2);
      expect(header.getInt32(8, Endian.little), 2);
      expect(header.getUint16(14, Endian.little), 32);
      expect(dib.sublist(40, 44), [255, 0, 0, 255]);
      expect(dib.sublist(48, 52), [0, 0, 255, 255]);
    },
  );

  test(
    'slow media preparation cannot overwrite a later session command',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final calls = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final prepare = Completer<Object>();
      var current = '';
      final clipboard = ClipboardWriter(
        write: (text) async => current = text,
        read: () async => current,
      );
      final media = clipboard.copyMedia(() => prepare.future, 'writeImage');
      final resume = clipboard.copy('codex resume newest');
      prepare.complete(Uint8List(4));
      expect(await media, isFalse);
      expect(await resume, isTrue);
      expect(current, 'codex resume newest');
      expect(calls, isEmpty);
    },
  );

  test(
    'binary clipboard contention retries and never reports a failed copy',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      var attempts = 0;
      var preparation = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'writeFile');
        attempts++;
        if (attempts < 3) throw PlatformException(code: 'Clipboard error');
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final writer = ClipboardWriter(delay: (_) async {});
      expect(
        await writer.copyMedia(() async {
          preparation++;
          return r'C:\clip.mp4';
        }, 'writeFile'),
        isTrue,
      );
      expect(attempts, 3);
      expect(preparation, 1);
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => throw PlatformException(code: 'Clipboard error'),
      );
      await expectLater(
        writer.copyMedia(() async => r'C:\clip.mp4', 'writeFile'),
        throwsA(isA<ClipboardCopyException>()),
      );
    },
  );

  test(
    'Markdown copies text and video copies a file, not its path as text',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      var text = '';
      final directory = Directory.systemTemp.createTempSync(
        'context-copy-preview-',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final md = File('${directory.path}/notes.md')
        ..writeAsStringSync('# Original\nFull text.');
      final video = File('${directory.path}/clip.mp4')
        ..writeAsBytesSync([1, 2, 3]);
      final actions = PreviewActions(
        clipboard: ClipboardWriter(
          write: (value) async => text = value,
          read: () async => text,
        ),
      );
      expect(await actions.copy(md.path), isTrue);
      expect(text, '# Original\nFull text.');
      expect(await actions.copy(video.path), isTrue);
      expect(calls.single.method, 'writeFile');
      expect(calls.single.arguments, video.absolute.path);
      expect(text, '# Original\nFull text.');
    },
  );

  test(
    'Save as preserves original bytes, cancellation and self-copy are safe',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'context-save-preview-',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final source = File('${directory.path}/clip.mp4')
        ..writeAsBytesSync(List.generate(100000, (i) => i % 256));
      final destination = File('${directory.path}/saved.mp4');
      final actions = PreviewActions(savePicker: (_) async => destination.path);
      expect(await actions.saveAs(source.path), isTrue);
      expect(destination.readAsBytesSync(), source.readAsBytesSync());
      expect(
        await PreviewActions(savePicker: (_) async => null).saveAs(source.path),
        isFalse,
      );
      await expectLater(
        PreviewActions(
          savePicker: (_) async => source.path,
        ).saveAs(source.path),
        throwsStateError,
      );
      expect(source.lengthSync(), 100000);
      await expectLater(
        PreviewActions.readBounded(source.path, 10),
        throwsStateError,
      );
    },
  );

  testWidgets('nested Markdown media opens exactly its own copy/save menu', (
    tester,
  ) async {
    final actions = RecordingActions();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PreviewContextMenu(
            path: 'document.md',
            actions: actions,
            child: Center(
              child: PreviewContextMenu(
                path: 'embedded.png',
                actions: actions,
                child: const SizedBox(
                  width: 150,
                  height: 150,
                  child: Text('Image'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await secondaryClick(tester, find.text('Image'));
    expect(find.text('Copy'), findsOneWidget);
    expect(find.text('Save as...'), findsOneWidget);
    expect(find.text('Copy snapshot'), findsNothing);
    await tester.tap(find.text('Copy'));
    await tester.pumpAndSettle();
    expect(actions.copied, ['embedded.png']);
    await secondaryClick(tester, find.text('Image'));
    await tester.tap(find.text('Save as...'));
    await tester.pumpAndSettle();
    expect(actions.saved, ['embedded.png']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('folder menu remains independent of Markdown preview menu', (
    tester,
  ) async {
    var external = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PreviewContextMenu(
            path: 'document.md',
            child: Center(
              child: FileLocationButton(
                onReveal: () {},
                onOpenExternal: () => external++,
              ),
            ),
          ),
        ),
      ),
    );
    await secondaryClick(tester, find.byType(FileLocationButton));
    expect(find.text('Open in default app'), findsOneWidget);
    expect(find.text('Save as...'), findsNothing);
    await tester.tap(find.text('Open in default app'));
    await tester.pumpAndSettle();
    expect(external, 1);
  });

  testWidgets(
    'open video preview copies current frame and original file separately',
    (tester) async {
      final video = SnapshotVideo();
      final actions = RecordingActions();
      final controller = WhiteboardPreviewController(
        resolverFor: (path) =>
            FileReferenceResolver(markdownPath: path, roots: const []),
        videoFactory: () => video,
      );
      await controller.open('video.mp4');
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: WhiteboardFilePreview(
              controller: controller,
              markdownBuilder: (text, _) => Text(text),
              onClose: controller.close,
              onOpenExternal: () {},
              onReveal: () {},
              actions: actions,
            ),
          ),
        ),
      );
      await secondaryClick(tester, find.text('Video surface'));
      expect(find.text('Copy snapshot'), findsOneWidget);
      await tester.tap(find.text('Copy snapshot'));
      await tester.pumpAndSettle();
      expect(video.captures, 1);
      expect(actions.snapshots.single, [1, 2, 3]);
      await secondaryClick(tester, find.text('Video surface'));
      await tester.tap(find.text('Copy'));
      await tester.pumpAndSettle();
      expect(actions.copied, ['video.mp4']);
      await secondaryClick(tester, find.text('Video surface'));
      await tester.tap(find.text('Save as...'));
      await tester.pumpAndSettle();
      expect(actions.saved, ['video.mp4']);
      await tester.tap(find.byIcon(Icons.fullscreen_rounded));
      await tester.pumpAndSettle();
      await secondaryClick(tester, find.text('Video surface'));
      await tester.tap(find.text('Copy snapshot'));
      await tester.pumpAndSettle();
      expect(video.captures, 2);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
  );

  testWidgets('failed preview copies show an error, never copied feedback', (
    tester,
  ) async {
    final actions = RecordingActions()..fail = true;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PreviewContextMenu(
            path: 'image.png',
            actions: actions,
            child: const Text('Bad copy'),
          ),
        ),
      ),
    );
    await secondaryClick(tester, find.text('Bad copy'));
    await tester.tap(find.text('Copy'));
    await tester.pumpAndSettle();
    expect(find.text('Copied.'), findsNothing);
    expect(find.textContaining('Clipboard unavailable'), findsOneWidget);
  });

  testWidgets(
    'real Markdown document and its image/video have independent menus',
    (tester) async {
      final directory = Directory.systemTemp.createTempSync(
        'context-md-media-',
      );
      final md = File('${directory.path}/board.md')
        ..writeAsStringSync(
          'Document body\n\n![Image](picture.png)\n\n[Video](clip.mp4)',
        );
      File('${directory.path}/clip.mp4').writeAsBytesSync([1]);
      final imageFile = File('${directory.path}/picture.png');
      await tester.runAsync(() async {
        final recorder = ui.PictureRecorder();
        ui.Canvas(
          recorder,
        ).drawColor(const ui.Color(0xFF66AA44), ui.BlendMode.src);
        final picture = recorder.endRecording();
        final image = await picture.toImage(16, 16);
        imageFile.writeAsBytesSync(
          (await image.toByteData(
            format: ui.ImageByteFormat.png,
          ))!.buffer.asUint8List(),
        );
        image.dispose();
        picture.dispose();
      });
      final app = AppState.forTesting(sendRequest: (_) {})
        ..sessionsMarkdownPath = '${directory.path}/sessions.md';
      final actions = RecordingActions();
      final video = SnapshotVideo();
      await tester.pumpWidget(const MaterialApp(home: Scaffold()));
      // Preload before mounting: joining an image load started inside the
      // widget test's fake clock from runAsync would wait for a missing pump.
      await tester.runAsync(() async {
        final resolver = FileReferenceResolver(
          markdownPath: md.path,
          roots: [directory.path],
          workDir: directory.path,
        );
        final path = (await resolver.resolve('picture.png')).paths.single;
        await precacheImage(
          ResizeImage(FileImage(File(path)), width: 400),
          tester.element(find.byType(Scaffold)),
        ).timeout(const Duration(seconds: 10));
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: WhiteboardPane(
              appState: app,
              reader: MarkdownReader(md.path, directory.path),
              previewActions: actions,
              videoFactory: () => video,
              openFile: (path, {bool reveal = false}) async =>
                  fail('No external launches expected.'),
            ),
          ),
        ),
      );
      Future<void> flush() async {
        for (var step = 0; step < 8; step++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 40)),
          );
          await tester.pump(const Duration(milliseconds: 40));
        }
      }

      await flush();
      await tester.tap(find.text('Document (board.md)'));
      await flush();
      await secondaryClick(tester, find.text('Document body'));
      expect(find.text('Copy'), findsOneWidget);
      expect(find.text('Save as...'), findsOneWidget);
      await tester.tap(find.text('Copy'));
      await tester.pumpAndSettle();
      String normalized(String path) =>
          path.replaceAll('\\', '/').toLowerCase();
      expect(normalized(actions.copied.last), normalized(md.path));
      final thumbnail = find.byKey(
        const ValueKey('whiteboard-response-thumbnail'),
      );
      expect(thumbnail, findsOneWidget);
      expect(tester.getSize(thumbnail).width, greaterThan(0));
      await secondaryClick(tester, thumbnail);
      expect(find.text('Copy'), findsOneWidget);
      await tester.tap(find.text('Copy'));
      await tester.pumpAndSettle();
      expect(normalized(actions.copied.last), normalized(imageFile.path));
      await secondaryClick(tester, find.text('Video (clip.mp4)'));
      expect(find.text('Copy snapshot'), findsOneWidget);
      await tester.tap(find.text('Copy snapshot'));
      await flush();
      expect(video.captures, 1);
      expect(actions.snapshots, hasLength(1));
      expect(find.text('Video surface'), findsOneWidget);
      expect(find.text('Snapshot copied.'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      app.dispose();
      directory.deleteSync(recursive: true);
    },
  );
}
