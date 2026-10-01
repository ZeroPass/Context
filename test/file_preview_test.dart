import 'dart:io';

import 'package:context/app/app_state.dart';
import 'package:context/app/file_references.dart';
import 'package:context/main.dart';
import 'package:context/ui/widgets/file_preview.dart';
import 'package:context/ui/widgets/passive_tooltip.dart';
import 'package:context/ui/widgets/video_preview.dart';
import 'package:context/ui/widgets/whiteboard_pane.dart';
import 'package:flutter/material.dart';
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
