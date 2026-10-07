import 'dart:async';

import 'package:context/app/clipboard_writer.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const arduCommand = 'codex resume 00000000-0000-4000-8000-000000007d40';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'success requires actual clipboard text, not a successful write call',
    () async {
      var clipboard = 'previous command';
      var writes = 0;
      final copier = ClipboardWriter(
        write: (text) async {
          writes++;
          if (writes == 3) clipboard = text;
        },
        read: () async => clipboard,
        delay: (_) async {},
      );
      expect(await copier.copy(arduCommand), isTrue);
      expect(clipboard, arduCommand);
      expect(writes, 3);
    },
  );

  test('persistent silent failure is an error, never success', () async {
    var writes = 0;
    final copier = ClipboardWriter(
      write: (_) async => writes++,
      read: () async => 'previous command',
      delay: (_) async {},
    );
    await expectLater(
      copier.copy(arduCommand),
      throwsA(isA<ClipboardCopyException>()),
    );
    expect(writes, 4);
  });

  test(
    'temporary clipboard lock is retried and failures do not poison later copies',
    () async {
      var locked = true;
      var clipboard = 'previous';
      var writes = 0;
      final copier = ClipboardWriter(
        write: (text) async {
          writes++;
          if (locked) throw PlatformException(code: 'Clipboard error');
          clipboard = text;
        },
        read: () async => clipboard,
        delay: (_) async {},
      );
      await expectLater(
        copier.copy(arduCommand),
        throwsA(isA<ClipboardCopyException>()),
      );
      expect(writes, 4);
      locked = false;
      expect(await copier.copy(arduCommand), isTrue);
      expect(clipboard, arduCommand);
    },
  );

  test(
    'rapid clicks skip queued older requests and cannot retry over a newer copy',
    () async {
      var clipboard = 'previous';
      final firstWrite = Completer<void>();
      final started = Completer<void>();
      final writes = <String>[];
      final copier = ClipboardWriter(
        write: (text) async {
          writes.add(text);
          if (writes.length == 1) {
            started.complete();
            await firstWrite.future;
          }
          clipboard = text;
        },
        read: () async => clipboard,
        delay: (_) async {},
      );
      final first = copier.copy('first');
      await started.future;
      final skipped = copier.copy('second');
      final latest = copier.copy(arduCommand);
      firstWrite.complete();
      expect(await first, isFalse);
      expect(await skipped, isFalse);
      expect(await latest, isTrue);
      expect(writes, ['first', arduCommand]);
      expect(clipboard, arduCommand);
    },
  );

  test(
    'null clipboard reads and read errors are not reported as success',
    () async {
      var reads = 0;
      final copier = ClipboardWriter(
        write: (_) async {},
        read: () async {
          reads++;
          if (reads.isEven) throw PlatformException(code: 'Clipboard error');
          return null;
        },
        delay: (_) async {},
      );
      await expectLater(
        copier.copy(arduCommand),
        throwsA(isA<ClipboardCopyException>()),
      );
      expect(reads, 4);
    },
  );

  test(
    'Windows uses the native writer and verifies through the platform reader',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const channel = MethodChannel('context/clipboard');
      var clipboard = 'previous';
      final nativeWrites = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'writeText');
        clipboard = call.arguments as String;
        nativeWrites.add(clipboard);
        return null;
      });
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        expect(call.method, 'Clipboard.getData');
        return {'text': clipboard};
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(channel, null);
        messenger.setMockMethodCallHandler(SystemChannels.platform, null);
      });
      expect(await ClipboardWriter().copy(arduCommand), isTrue);
      expect(nativeWrites, [arduCommand]);
    },
  );
}
