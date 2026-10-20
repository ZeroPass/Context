import 'dart:io';
import 'dart:ui' as ui;

import 'package:context/app/app_state.dart';
import 'package:context/app/file_references.dart';
import 'package:context/main.dart';
import 'package:context/ui/widgets/file_preview.dart';
import 'package:context/ui/widgets/passive_tooltip.dart';
import 'package:context/ui/widgets/video_preview.dart';
import 'package:context/ui/widgets/whiteboard_pane.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakeVideo extends PreviewVideoSession {
  String? opened;
  bool released = false;
  @override
  Duration position = Duration.zero;
  @override
  Duration duration = const Duration(minutes: 2);
  @override
  bool playing = false;
  @override
  bool buffering = false;
  @override
  double volume = 100;
  @override
  String? get error => null;
  @override
  Widget buildVideo() => const ColoredBox(
    color: Colors.black,
    child: Center(
      child: Text('Synthetic video', style: TextStyle(color: Colors.white)),
    ),
  );
  @override
  Future<void> open(String path) async => opened = path;
  @override
  Future<void> togglePlayback() async {
    playing = !playing;
    notifyListeners();
  }

  @override
  Future<void> pause() async {
    playing = false;
    notifyListeners();
  }

  @override
  Future<void> seek(Duration value) async {
    position = value;
    notifyListeners();
  }

  @override
  Future<void> setVolume(double value) async {
    volume = value;
    notifyListeners();
  }

  @override
  void dispose() {
    released = true;
    super.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Finder tip(String text) => find.byWidgetPredicate(
    (widget) => widget is PassiveTooltip && widget.message == text,
  );

  testWidgets(
    'wheel scrolls the pane until selected; selection gates zoom and has an outline',
    (tester) async {
      final directory = Directory.systemTemp.createTempSync('context-image-');
      final file = File('${directory.path}/image.png');
      await tester.runAsync(() async {
        final recorder = ui.PictureRecorder();
        ui.Canvas(recorder).drawColor(Colors.green, ui.BlendMode.src);
        final picture = recorder.endRecording();
        final image = await picture.toImage(160, 100);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        file.writeAsBytesSync(bytes!.buffer.asUint8List());
        image.dispose();
        picture.dispose();
      });
      final controller = WhiteboardPreviewController(
        resolverFor: (path) =>
            FileReferenceResolver(markdownPath: path, roots: []),
      );
      await controller.open(file.path);
      final scroll = ScrollController();
      await tester.pumpWidget(const MaterialApp(home: Scaffold()));
      await tester.runAsync(
        () => precacheImage(
          FileImage(file),
          tester.element(find.byType(Scaffold)),
        ).timeout(const Duration(seconds: 10)),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 420,
              height: 450,
              child: SingleChildScrollView(
                controller: scroll,
                child: Column(
                  children: [
                    TextButton(
                      onPressed: () {},
                      child: const Text('Outside viewer'),
                    ),
                    SizedBox(
                      height: 250,
                      child: WhiteboardFilePreview(
                        controller: controller,
                        markdownBuilder: (text, _) => Text(text),
                        onClose: controller.close,
                        onOpenExternal: () {},
                        onReveal: () {},
                      ),
                    ),
                    const SizedBox(height: 1000),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      final imageArea = find.byKey(
        const ValueKey('whiteboard-image-selection'),
      );
      final transform = tester
          .widget<InteractiveViewer>(find.byType(InteractiveViewer))
          .transformationController!;
      Future<void> wheel(double dy) async {
        await tester.sendEventToBinding(
          PointerScrollEvent(
            position: tester.getCenter(imageArea),
            scrollDelta: Offset(0, dy),
          ),
        );
        await tester.pump();
      }

      await wheel(60);
      expect(scroll.offset, greaterThan(0));
      expect(transform.value, Matrix4.identity());
      scroll.jumpTo(0);
      await tester.pump();
      await tester.tap(imageArea);
      await tester.pump(const Duration(milliseconds: 350));
      final decoration =
          tester.widget<DecoratedBox>(imageArea).decoration as BoxDecoration;
      expect((decoration.border! as Border).top.color.a, greaterThan(0));
      await wheel(-140);
      expect(transform.value.getMaxScaleOnAxis(), greaterThan(1));
      expect(scroll.offset, 0);
      final scale = transform.value.getMaxScaleOnAxis();
      await tester.tap(find.text('Outside viewer'));
      await tester.pump();
      await wheel(60);
      expect(scroll.offset, greaterThan(0));
      expect(transform.value.getMaxScaleOnAxis(), scale);
      scroll.jumpTo(0);
      await tester.pump();
      controller.setGallery([file.path, '${directory.path}/next.png']);
      await tester.tap(tip('Next attachment (Right arrow)'));
      await tester.pump();
      final afterNavigation =
          tester.widget<DecoratedBox>(imageArea).decoration as BoxDecoration;
      expect((afterNavigation.border! as Border).top.color.a, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      scroll.dispose();
      // Windows can retain the decoded file mapping until the test process exits.
    },
  );

  testWidgets(
    'mixed attachments navigate with buttons and keys, including expanded view',
    (tester) async {
      final directory = Directory.systemTemp.createTempSync('context-gallery-');
      final first = File('${directory.path}/first.md')
        ..writeAsStringSync('First document');
      final last = File('${directory.path}/last.md')
        ..writeAsStringSync('Last document');
      final videos = <FakeVideo>[];
      final controller = WhiteboardPreviewController(
        resolverFor: (path) =>
            FileReferenceResolver(markdownPath: path, roots: []),
        videoFactory: () {
          final video = FakeVideo();
          videos.add(video);
          return video;
        },
      );
      await tester.runAsync(() => controller.open(first.path));
      controller.setGallery([first.path, 'synthetic.mp4', last.path]);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 400,
              child: Column(
                children: [
                  TextButton(
                    onPressed: () {},
                    child: const Text('Outside viewer'),
                  ),
                  Expanded(
                    child: WhiteboardFilePreview(
                      controller: controller,
                      markdownBuilder: (text, _) => Text(text),
                      onClose: controller.close,
                      onOpenExternal: () {},
                      onReveal: () {},
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      final counter = find.byKey(const ValueKey('whiteboard-preview-counter'));
      Future<void> finishLoad() async {
        for (var step = 0; step < 30; step++) {
          await tester.pump(const Duration(milliseconds: 40));
          await tester.runAsync(
            () async => Future<void>.delayed(const Duration(milliseconds: 40)),
          );
          if (!controller.loading) break;
        }
        expect(controller.loading, isFalse);
        await tester.pumpAndSettle();
      }

      expect(tester.widget<Text>(counter).data, '1/3');
      await tester.tap(tip('Next attachment (Right arrow)'));
      await tester.pumpAndSettle();
      expect(controller.kind, WhiteboardPreviewKind.video);
      expect(tester.widget<Text>(counter).data, '2/3');
      expect(videos, hasLength(1));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await finishLoad();
      expect(controller.path, last.path);
      expect(videos.single.released, isTrue);
      expect(tester.widget<Text>(counter).data, '3/3');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(controller.path, last.path);
      // Double-click expands only app content and keeps the toolbar above it.
      await tester.tap(find.text('Last document'));
      await tester.pump(const Duration(milliseconds: 80));
      await tester.tap(find.text('Last document'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('whiteboard-app-preview')),
        findsOneWidget,
      );
      expect(tester.widget<Text>(counter).data, '3/3');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      expect(controller.kind, WhiteboardPreviewKind.video);
      expect(tester.widget<Text>(counter).data, '2/3');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('whiteboard-app-preview')),
        findsNothing,
      );
      expect(tester.widget<Text>(counter).data, '2/3');
      await tester.tap(find.text('Outside viewer'));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(controller.kind, WhiteboardPreviewKind.video);
      await tester.tap(tip('Previous attachment (Left arrow)'));
      await finishLoad();
      expect(controller.path, first.path);
      expect(tester.widget<Text>(counter).data, '1/3');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      directory.deleteSync(recursive: true);
    },
  );

  testWidgets(
    'Whiteboard visibility persists on and off across app state recreation',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      var app = AppState.forTesting(sendRequest: (_) {}, preferences: prefs);
      expect(app.whiteboardEnabled, isFalse);
      await app.setWhiteboardEnabled(true);
      expect(prefs.getBool('whiteboardEnabled'), isTrue);
      app.dispose();
      app = AppState.forTesting(sendRequest: (_) {}, preferences: prefs);
      expect(app.whiteboardEnabled, isTrue);
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        ChangeNotifierProvider.value(value: app, child: const ContextView()),
      );
      await tester.pump();
      expect(find.byType(WhiteboardPane), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('whiteboard-toggle')));
      await tester.pump();
      await tester.pump();
      expect(find.byType(WhiteboardPane), findsNothing);
      expect(prefs.getBool('whiteboardEnabled'), isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
      app = AppState.forTesting(sendRequest: (_) {}, preferences: prefs);
      expect(app.whiteboardEnabled, isFalse);
      app.dispose();
    },
  );

  test(
    'preview classifies supported files and bounded Markdown reads',
    () async {
      expect(isPreviewMarkdown('notes.md'), isTrue);
      expect(isPreviewMarkdown('notes.markdown'), isTrue);
      expect(isPreviewVideo('movie.MP4'), isTrue);
      expect(isPreviewVideo('clip.m4v'), isTrue);
      expect(isPreviewVideo('notes.md'), isFalse);
      final directory = Directory.systemTemp.createTempSync(
        'context-md-preview-',
      );
      final file = File('${directory.path}/notes.md');
      file.writeAsStringSync('# Notes\n\nOriginal content.');
      final controller = WhiteboardPreviewController(
        resolverFor: (path) => FileReferenceResolver(
          markdownPath: path,
          roots: [directory.path],
          workDir: directory.path,
        ),
      );
      await controller.open(file.path);
      expect(controller.kind, WhiteboardPreviewKind.markdown);
      expect(controller.markdown, contains('# Notes'));
      expect(controller.error, isNull);
      file.writeAsBytesSync(
        List.filled(WhiteboardPreviewController.maxMarkdownBytes + 1, 65),
      );
      await controller.open(file.path);
      expect(controller.error, contains('too large'));
      expect(controller.markdown, isNull);
      final stale = controller.open(file.path);
      controller.close();
      await stale;
      expect(controller.path, isNull);
      expect(controller.markdown, isNull);
      controller.dispose();
      directory.deleteSync(recursive: true);
    },
  );

  testWidgets(
    'Markdown preview fills its pane and app expansion exits with Escape',
    (tester) async {
      final directory = Directory.systemTemp.createTempSync('context-md-view-');
      final file = File('${directory.path}/notes.md');
      file.writeAsStringSync('# Preview notes\n\nLocal Markdown content.');
      final controller = WhiteboardPreviewController(
        resolverFor: (path) => FileReferenceResolver(
          markdownPath: path,
          roots: [directory.path],
          workDir: directory.path,
        ),
      );
      await tester.runAsync(() => controller.open(file.path));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 400,
                height: 450,
                child: WhiteboardFilePreview(
                  controller: controller,
                  markdownBuilder: (text, _) => MarkdownBody(data: text),
                  onClose: controller.close,
                  onOpenExternal: () {},
                  onReveal: () {},
                ),
              ),
            ),
          ),
        ),
      );
      expect(find.text('Preview notes', findRichText: true), findsOneWidget);
      await tester.tap(tip('Expand to app'));
      await tester.pumpAndSettle();
      final expanded = find.byKey(const ValueKey('whiteboard-app-preview'));
      expect(expanded, findsOneWidget);
      expect(tester.getSize(expanded).width, greaterThan(400));
      expect(find.text('Preview notes', findRichText: true), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(expanded, findsNothing);
      expect(find.text('Preview notes', findRichText: true), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      directory.deleteSync(recursive: true);
    },
  );

  testWidgets(
    'video controls and app expansion share one session and release it',
    (tester) async {
      final video = FakeVideo();
      var created = 0;
      final controller = WhiteboardPreviewController(
        resolverFor: (path) =>
            FileReferenceResolver(markdownPath: path, roots: const []),
        videoFactory: () {
          created++;
          return video;
        },
      );
      await controller.open('synthetic.mp4');
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: WhiteboardFilePreview(
              controller: controller,
              markdownBuilder: (text, _) => Text(text),
              onClose: controller.close,
              onOpenExternal: () {},
              onReveal: () {},
            ),
          ),
        ),
      );
      expect(video.opened, 'synthetic.mp4');
      await tester.tap(tip('Play video'));
      await tester.pump();
      expect(video.playing, isTrue);
      await tester.tap(tip('Mute video'));
      await tester.pump();
      expect(video.volume, 0);
      final seek = tester.widget<Slider>(
        find.byKey(const ValueKey('whiteboard-video-seek')),
      );
      seek.onChanged!(30000);
      await tester.pump();
      expect(video.position, const Duration(seconds: 30));
      await tester.tap(tip('Expand to app'));
      await tester.pumpAndSettle();
      expect(find.text('Synthetic video'), findsOneWidget);
      expect(created, 1);
      expect(video.position, const Duration(seconds: 30));
      await tester.tap(tip('Exit expanded view'));
      await tester.pumpAndSettle();
      expect(created, 1);
      expect(video.playing, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.close();
      expect(video.released, isTrue);
      controller.dispose();
    },
  );
}
