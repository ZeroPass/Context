import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:context/app/models.dart';
import 'package:context/app/whiteboard_file.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final root = Platform.environment['CONTEXT_WHITEBOARD_WSL_PROBE'];
  test(
    'Linux publication reaches Windows reader over WSL share',
    () async {
      final normalized = root!.replaceAll('\\', '/');
      final match = RegExp(
        r'^//wsl(?:\.localhost|\$)/([^/]+)(/.*)$',
      ).firstMatch(normalized)!;
      final distro = match.group(1)!;
      final linuxRoot = match.group(2)!;
      final project = linuxRoot.substring(0, linuxRoot.indexOf('/.buildlog/'));
      final binary =
          '$project/.buildlog/whiteboard-writer/release/context-whiteboard';
      await Directory(root).create(recursive: true);
      final file = File('$root/whiteboard.md');
      await file.writeAsString('<!-- probe fixture -->\n');
      final reader = FileWhiteboardReader();
      final waits = <String, Completer<int>>{};
      final clocks = <String, Stopwatch>{};
      final subscription = reader.changes('$root/codex sessions.md').listen((
        _,
      ) async {
        final posts = await reader.recent(
          '$root/codex sessions.md',
          SessionProvider.codex,
          3,
        );
        for (final post in posts) {
          final wait = waits[post.title];
          if (wait != null && !wait.isCompleted) {
            wait.complete(clocks[post.title]!.elapsedMicroseconds);
          }
        }
      });
      try {
        for (var i = 0; i < 8; i++) {
          final title = 'WSL push $i';
          waits[title] = Completer<int>();
          clocks[title] = Stopwatch()..start();
          final process = await Process.start('wsl.exe', [
            '-d',
            distro,
            '--cd',
            project,
            '--exec',
            binary,
            '--file',
            '$linuxRoot/whiteboard.md',
            '--title',
            title,
            '--provider',
            'codex',
          ]);
          final out = process.stdout.transform(utf8.decoder).join();
          final err = process.stderr.transform(utf8.decoder).join();
          process.stdin.encoding = utf8;
          process.stdin.write('# $title\n\nFinal output: \u017e \u{1f642}\n');
          await process.stdin.close();
          expect(await process.exitCode, 0, reason: await err);
          expect(jsonDecode(await out)['published'], isTrue);
          final elapsed = await waits[title]!.future.timeout(
            const Duration(seconds: 3),
          );
          final posts = await reader.recent(
            '$root/codex sessions.md',
            SessionProvider.codex,
            3,
          );
          expect(posts.first.title, title);
          expect(posts.length, lessThanOrEqualTo(3));
          final history = await reader.history(
            '$root/codex sessions.md',
            posts.first,
            1,
          );
          expect(
            history.responses.single.text,
            '# $title\n\nFinal output: \u017e \u{1f642}\n',
          );
          // Same Windows stopwatch includes wsl.exe startup; this is not bare event latency.
          stdout.writeln(
            jsonEncode({
              'sample': i,
              'request_to_read_us': elapsed,
              'entries': posts.length,
            }),
          );
        }
      } finally {
        await subscription.cancel();
        reader.dispose();
      }
    },
    skip: !Platform.isWindows || root == null,
  );
}
