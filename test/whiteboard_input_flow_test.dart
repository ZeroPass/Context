import 'dart:async';
import 'dart:io';

import 'package:context/app/app_state.dart';
import 'package:context/app/models.dart';
import 'package:context/app/whiteboard.dart';
import 'package:context/app/whiteboard_file.dart';
import 'package:context/app/whiteboard_input.dart';
import 'package:context/app/workspace_paths.dart';
import 'package:context/ui/widgets/whiteboard_drop_surface.dart';
import 'package:context/ui/widgets/whiteboard_input_editor.dart';
import 'package:context/ui/widgets/whiteboard_pane.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class InputBoardFixture extends FileWhiteboardReader {
  final entries = <RecentContext>[];
  final bodies = <String, String>{};
  var writes = 0;
  int? expected;
  Completer<void>? waiting;
  Future<void> untilWrites(int count) {
    if (writes >= count) {
      return Future.value();
    }
    expected = count;
    return (waiting = Completer<void>()).future.timeout(
      const Duration(seconds: 10),
    );
  }

  Future<void> write(
    String board,
    String title,
    String body,
    String prompt,
    String folder, {
    bool replace = false,
    bool remove = false,
  }) async {
    final old = entries.where((s) => s.dropFolder == folder).firstOrNull;
    final position = old == null ? 0 : entries.indexOf(old);
    if (old != null) {
      entries.remove(old);
    }
    if (!remove) {
      final entry = RecentContext(
        provider: SessionProvider.codex,
        id: old?.id ?? 'input-$writes',
        title: title,
        updatedAt: old?.updatedAt ?? writes,
        localDrop: true,
        agentPrompt: prompt,
        dropFolder: folder,
      );
      entries.insert(position, entry);
      bodies[entry.id] = body;
    }
    writes++;
    if (expected != null &&
        writes >= expected! &&
        waiting?.isCompleted == false) {
      waiting!.complete();
    }
  }

  void output() {
    entries.insert(
      0,
      const RecentContext(
        provider: SessionProvider.codex,
        id: 'output',
        title: 'Agent result',
        updatedAt: 99,
      ),
    );
    bodies['output'] = 'An agent output.';
  }

  @override
  Stream<void> changes(String path) => const Stream.empty();
  @override
  Future<List<RecentContext>> recent(
    String path,
    SessionProvider provider,
    int limit,
  ) async => List.of(entries.take(limit));
  @override
  Future<ResponseHistory> history(
    String path,
    RecentContext session,
    int limit,
  ) async => ResponseHistory(
    [
      SessionResponse(
        text: bodies[session.id] ?? '',
        timestamp: '',
        turnId: session.id,
      ),
    ],
    null,
    false,
  );
}

// Widget scheduling stays deterministic; real persistence and owned-file
// cleanup are covered by the input-store and native writer tests.
class MemoryInputs extends WhiteboardInputs {
  MemoryInputs(this.board);
  final InputBoardFixture board;
  final drafts = <String, WhiteboardInputDraft>{};
  int serial = 0;

  @override
  Future<WhiteboardInputDraft> create(String sessionsPath) async {
    final draft = WhiteboardInputDraft(
      board: contextPaths(
        sessionsPath,
      ).join(contextPaths(sessionsPath).dirname(sessionsPath), 'whiteboard.md'),
      folder: 'input-${serial++}',
    );
    drafts[draft.folder] = draft;
    await board.write(draft.board, draft.title, '', draft.prompt, draft.folder);
    return draft;
  }

  @override
  Future<WhiteboardInputDraft?> load(String path, String folder) async =>
      drafts[folder];

  @override
  Future<void> save(WhiteboardInputDraft draft) async {
    drafts[draft.folder] = draft;
    await board.write(
      draft.board,
      draft.title,
      '',
      draft.prompt,
      draft.folder,
      replace: true,
    );
  }

  @override
  Future<WhiteboardInputDraft> add(
    WhiteboardInputDraft draft,
    Map<Object?, Object?> data, {
    required bool paste,
  }) async {
    final next = draft.copyWith(
      files: [
        ...draft.files,
        for (final path in (data['files'] as List).cast<String>())
          InputAttachment(
            'file-${serial++}',
            contextPaths(draft.board).normalize(path),
          ),
      ],
    );
    await save(next);
    return next;
  }
}

void main() {
  testWidgets(
    'drop creates input, appends to active input, pins it, and plus saves notes',
    (tester) async {
      final root = Directory.systemTemp.createTempSync('context-input-flow-');
      addTearDown(() => root.deleteSync(recursive: true));
      final one = File('${root.path}/one.md')..writeAsStringSync('# One');
      final two = File('${root.path}/two.md')..writeAsStringSync('# Two');
      final board = InputBoardFixture();
      final inputs = MemoryInputs(board);
      final state = AppState.forTesting(sendRequest: (_) {})
        ..sessionsMarkdownPath = '${root.path}/sessions.md';
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        whiteboardInputChannel,
        (_) async => null,
      );
      addTearDown(
        () => messenger.setMockMethodCallHandler(whiteboardInputChannel, null),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Row(
              children: [
                const SizedBox(width: 180, child: Text('Sessions')),
                Expanded(
                  child: WhiteboardPane(
                    appState: state,
                    reader: board,
                    inputs: inputs,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      Future<void> event(String method, Object value) async {
        unawaited(
          messenger.handlePlatformMessage(
            whiteboardInputChannel.name,
            const StandardMethodCodec().encodeMethodCall(
              MethodCall(method, value),
            ),
            (_) {},
          ),
        );
        await tester.pumpAndSettle();
      }

      await event('hover', true);
      final overlay = find.byKey(const ValueKey('whiteboard-drop-overlay'));
      expect(overlay, findsOneWidget);
      expect(tester.getTopLeft(overlay).dx, 180);
      await event('drop', {
        'files': [one.path],
      });
      expect(board.entries, hasLength(1));
      expect(find.byType(WhiteboardInputEditor), findsOneWidget);
      final folder = board.entries.single.dropFolder;
      await event('drop', {
        'files': [two.path],
      });
      expect(board.entries, hasLength(1));
      final editor = tester.widget<WhiteboardInputEditor>(
        find.byType(WhiteboardInputEditor),
      );
      expect(
        editor.draft.files.map((f) => f.path),
        [
          one.path,
          two.path,
        ].map(contextPaths(state.sessionsMarkdownPath).normalize),
      );
      expect(editor.draft.files.every((f) => !f.owned), true);
      final id = editor.draft.files.first.id;
      await tester.enterText(
        find.byKey(ValueKey('input-note-$id')),
        'Calibration input',
      );
      await tester.pump();
      expect(
        tester
            .widget<WhiteboardInputEditor>(find.byType(WhiteboardInputEditor))
            .draft
            .files
            .first
            .note,
        'Calibration input',
      );
      final plus = tester.widget<IconButton>(
        find.byKey(const ValueKey('whiteboard-new-input')),
      );
      plus.onPressed!();
      await tester.pumpAndSettle();
      expect(inputs.drafts[folder]!.files.first.note, 'Calibration input');
      expect(board.entries, hasLength(2));
      expect(
        tester
            .widget<WhiteboardInputEditor>(find.byType(WhiteboardInputEditor))
            .draft
            .files,
        isEmpty,
      );
      board.output();
      await tester.tap(
        find.byKey(const ValueKey('whiteboard-publication-refresh')),
      );
      await tester.pumpAndSettle();
      expect(find.byType(WhiteboardInputEditor), findsOneWidget);
      await tester.tap(find.text('Agent result'));
      await tester.pumpAndSettle();
      expect(find.byType(WhiteboardInputEditor), findsNothing);
      await event('drop', {
        'files': [one.path],
      });
      expect(board.entries.where((s) => s.localDrop), hasLength(3));
      expect(find.byType(WhiteboardInputEditor), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
    },
    timeout: const Timeout(Duration(seconds: 45)),
  );
}
