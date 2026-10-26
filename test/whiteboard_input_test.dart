import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:context/app/whiteboard_input.dart';
import 'package:context/app/workspace_paths.dart';
import 'package:context/ui/widgets/whiteboard_input_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late WhiteboardInputs inputs;
  late List<Map<String, dynamic>> writes;
  late String sessions;
  setUp(() {
    root = Directory.systemTemp.createTempSync('context-input-test-');
    sessions = '${root.path}/sessions.md';
    writes = [];
    inputs = WhiteboardInputs(
      writer:
          (
            board,
            title,
            body,
            prompt,
            folder, {
            bool replace = false,
            bool remove = false,
          }) async {
            writes.add({
              'board': board,
              'title': title,
              'body': body,
              'prompt': prompt,
              'folder': folder,
              'replace': replace,
              'remove': remove,
            });
          },
    );
  });
  tearDown(() => root.deleteSync(recursive: true));

  test(
    'new input persists; repeated drops append references to one tab',
    () async {
      var draft = await inputs.create(sessions);
      final one = File('${root.path}/report.md')..writeAsStringSync('# Report');
      final two = File('${root.path}/movie.mp4')..writeAsBytesSync([1, 2]);
      expect(writes.single['replace'], false);
      draft = await inputs.add(draft, {
        'files': [one.path],
      }, paste: false);
      draft = await inputs.add(draft, {
        'files': [two.path],
      }, paste: false);
      expect(
        draft.files.map((f) => f.path),
        [one.path, two.path].map(contextPaths(sessions).normalize),
      );
      expect(draft.files.every((f) => !f.owned), true);
      expect(draft.ownedFiles, isEmpty);
      expect(writes.map((w) => w['folder']).toSet(), {draft.folder});
      expect(writes.skip(1).every((w) => w['replace'] == true), true);
      final restored = (await inputs.load(sessions, draft.folder))!;
      expect(restored.files, hasLength(2));
      expect(
        File(draft.readme).readAsStringSync(),
        contains(contextPaths(sessions).normalize(one.path)),
      );
      expect(one.readAsStringSync(), '# Report');
    },
  );

  test(
    'per-file notes and instructions survive reload and reach Markdown',
    () async {
      var draft = await inputs.create(sessions);
      final file = File('${root.path}/data.csv')..writeAsStringSync('value\n1');
      draft = await inputs.add(draft, {
        'files': [file.path],
      }, paste: false);
      draft = draft.copyWith(
        instructions: 'Compare these results.',
        files: [draft.files.single.withNote('Measured after calibration.')],
      );
      await inputs.save(draft);
      final restored = (await inputs.load(sessions, draft.folder))!;
      expect(restored.instructions, 'Compare these results.');
      expect(restored.files.single.note, 'Measured after calibration.');
      expect(writes.last['body'], contains('Measured after calibration.'));
      expect(
        File(draft.readme).readAsStringSync(),
        contains('Compare these results.'),
      );
    },
  );

  test(
    'explicit copy owns only the new copy, never changes its original',
    () async {
      var draft = await inputs.create(sessions);
      final file = File('${root.path}/image.png')..writeAsBytesSync([1, 2, 3]);
      draft = await inputs.add(draft, {
        'files': [file.path],
      }, paste: false);
      draft = await inputs.store(draft, draft.files.single.id);
      expect(draft.files.single.owned, true);
      expect(draft.files.single.path, isNot(file.path));
      expect(File(draft.files.single.path).readAsBytesSync(), [1, 2, 3]);
      expect(draft.files.single.path, startsWith(draft.directory));
      expect(file.readAsBytesSync(), [1, 2, 3]);
      expect(draft.ownedFiles, hasLength(1));
    },
  );

  test(
    'pasted files, images and text persist independently of clipboard',
    () async {
      var draft = await inputs.create(sessions);
      final file = File('${root.path}/paste.md')
        ..writeAsStringSync('clipboard file');
      draft = await inputs.add(draft, {
        'files': [file.path],
      }, paste: true);
      file.writeAsStringSync('changed original');
      expect(
        File(draft.files.single.path).readAsStringSync(),
        'clipboard file',
      );
      draft = await inputs.add(draft, {
        'image': Uint8List.fromList([4, 5, 6]),
        'extension': 'png',
      }, paste: true);
      draft = await inputs.add(draft, {
        'text': 'Use the first image.',
      }, paste: true);
      final restored = (await inputs.load(sessions, draft.folder))!;
      expect(restored.files.every((f) => f.owned), true);
      expect(File(restored.files.last.path).readAsBytesSync(), [4, 5, 6]);
      expect(restored.instructions, 'Use the first image.');
    },
  );

  test('quoted clipboard paths are copied as attachments', () async {
    var draft = await inputs.create(sessions);
    final file = File('${root.path}/quoted file.txt')
      ..writeAsStringSync('kept');
    draft = await inputs.add(draft, {'text': '"${file.path}"'}, paste: true);
    expect(draft.instructions, isEmpty);
    expect(draft.files.single.owned, true);
    expect(File(draft.files.single.path).readAsStringSync(), 'kept');
    expect(file.readAsStringSync(), 'kept');
  });

  test('invalid payloads fail before creating an input tab', () {
    for (final payload in <Map<Object?, Object?>>[
      {},
      {'text': '   '},
      {
        'files': [1],
      },
      {'image': 'invalid'},
      {'error': 'Clipboard unavailable'},
    ]) {
      expect(() => WhiteboardInputs.validateData(payload), throwsStateError);
    }
    expect(writes, isEmpty);
  });

  test('removed attachments remain owned for eventual cleanup', () async {
    var draft = await inputs.create(sessions);
    draft = await inputs.add(draft, {
      'image': Uint8List.fromList([1]),
    }, paste: true);
    final owned = draft.ownedFiles.single;
    await inputs.save(draft.copyWith(files: []));
    final restored = (await inputs.load(sessions, draft.folder))!;
    expect(restored.files, isEmpty);
    expect(restored.ownedFiles, contains(owned));
    await inputs.remove(restored);
    expect(writes.last['remove'], true);
  });

  test('expired folders and forged owned paths fail closed', () async {
    final draft = await inputs.create(sessions);
    final marker = File('${draft.directory}/.context-drop.json');
    marker.writeAsStringSync(
      jsonEncode({
        'schema': 'context.whiteboard.drop.v1',
        'folder': draft.folder,
        'retired': true,
      }),
    );
    await expectLater(inputs.save(draft), throwsStateError);
    expect(writes, hasLength(1));
    await expectLater(
      inputs.load(sessions, '../elsewhere'),
      completion(isNull),
    );
  });

  testWidgets(
    'compact file controls and notes are editable without Markdown tools',
    (tester) async {
      var draft = WhiteboardInputDraft(
        board: '${root.path}/whiteboard.md',
        folder: 'input-1',
        files: [InputAttachment('f-1', '${root.path}/sample.md')],
      );
      var stores = 0, previews = 0, folders = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) => WhiteboardInputEditor(
                draft: draft,
                onChanged: (change) => setState(() => draft = change(draft)),
                onAdd: () {},
                onCopy: () {},
                onDelete: () {},
                onStore: (_) => stores++,
                onPreview: (_) => previews++,
                onReveal: (_) => folders++,
                onExternal: (_) {},
              ),
            ),
          ),
        ),
      );
      await tester.enterText(
        find.byKey(const ValueKey('input-note-f-1')),
        'What this file contains.',
      );
      expect(draft.files.single.note, 'What this file contains.');
      await tester.tap(find.byKey(const ValueKey('input-store-f-1')));
      await tester.tap(find.byKey(const ValueKey('input-preview-f-1')));
      await tester.tap(find.byIcon(Icons.folder_open_rounded));
      expect([stores, previews, folders], [1, 1, 1]);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
