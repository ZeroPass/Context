import 'dart:async';

import 'package:context/app/session_terminal.dart';
import 'package:context/app/startup.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final events = <String>[];
  var elevated = false;
  String? elevationError;
  Completer<void>? approval;
  late SharedPreferences preferences;

  setUp(() async {
    events.clear();
    elevated = false;
    elevationError = null;
    approval = null;
    SharedPreferences.setMockInitialValues({});
    preferences = await SharedPreferences.getInstance();
    messenger.setMockMethodCallHandler(sessionTerminalChannel, (call) async {
      events.add(call.method);
      if (call.method == 'isElevated') return elevated;
      if (call.method == 'restartElevated') {
        if (approval != null) await approval!.future;
        if (elevationError != null) {
          throw PlatformException(code: elevationError!);
        }
      }
      return null;
    });
  });
  tearDown(
    () => messenger.setMockMethodCallHandler(sessionTerminalChannel, null),
  );

  Future<bool> launch({
    bool windows = true,
    Future<void> Function()? initialize,
  }) => startContext(
    windows: windows,
    preferences: preferences,
    initializeBackend:
        initialize ??
        () async {
          events.add('backend');
        },
    showApplication: () {
      events.add('app');
    },
  );

  Future<void> drain() async {
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  test(
    'startup approves helper then initializes the same normal-rights app',
    () async {
      expect(await launch(), isTrue);
      expect(events, [
        'isElevated',
        'restartElevated',
        'backend',
        'app',
        'finishStartup',
      ]);
      expect(preferences.getBool('askTerminalAdminAtStartup'), isNull);
    },
  );

  test(
    'pending UAC holds application work then continues without a UI restart',
    () async {
      approval = Completer<void>();
      final launching = launch();
      await drain();
      expect(events, ['isElevated', 'restartElevated']);
      approval!.complete();
      expect(await launching, isTrue);
      expect(events, [
        'isElevated',
        'restartElevated',
        'backend',
        'app',
        'finishStartup',
      ]);
    },
  );

  test(
    'UAC cancellation opens the ordinary app once and never asks in-app',
    () async {
      approval = Completer<void>();
      elevationError = 'cancelled';
      final launching = launch();
      await drain();
      expect(events, ['isElevated', 'restartElevated']);
      approval!.complete();
      expect(await launching, isTrue);
      expect(events, [
        'isElevated',
        'restartElevated',
        'backend',
        'app',
        'finishStartup',
      ]);
    },
  );

  test(
    'already elevated child initializes and reveals only the real app',
    () async {
      elevated = true;
      expect(await launch(), isTrue);
      expect(events, ['isElevated', 'backend', 'app', 'finishStartup']);
    },
  );

  test(
    'deferred approval preference bypasses UAC without changing click behavior',
    () async {
      await preferences.setBool('askTerminalAdminAtStartup', false);
      await preferences.setBool('openSessionsInTerminal', false);
      expect(await launch(), isTrue);
      expect(events, ['backend', 'app', 'finishStartup']);
      expect(preferences.getBool('askTerminalAdminAtStartup'), isFalse);
      expect(preferences.getBool('openSessionsInTerminal'), isFalse);
    },
  );

  test(
    'failed UAC request falls back normally instead of looping or hiding forever',
    () async {
      elevationError = 'terminal_error';
      expect(await launch(), isTrue);
      expect(events, [
        'isElevated',
        'restartElevated',
        'backend',
        'app',
        'finishStartup',
      ]);
    },
  );

  test('non-Windows startup never invokes Windows channels', () async {
    expect(await launch(windows: false), isTrue);
    expect(events, ['backend', 'app']);
  });

  test(
    'window visibility stays held while backend initialization is pending',
    () async {
      elevated = true;
      final backend = Completer<void>();
      final launching = launch(
        initialize: () async {
          events.add('backend');
          await backend.future;
        },
      );
      await drain();
      expect(events, ['isElevated', 'backend']);
      backend.complete();
      expect(await launching, isTrue);
      expect(events, ['isElevated', 'backend', 'app', 'finishStartup']);
    },
  );

  test('backend failure cannot accidentally reveal an empty window', () async {
    elevated = true;
    await expectLater(
      launch(
        initialize: () async {
          throw StateError('backend unavailable');
        },
      ),
      throwsStateError,
    );
    expect(events, ['isElevated']);
  });

  test(
    'startup approval never enables terminal-click default or rewrites preferences',
    () async {
      await preferences.setBool('openSessionsInTerminal', false);
      expect(await launch(), isTrue);
      expect(preferences.getBool('openSessionsInTerminal'), isFalse);
      expect(preferences.getKeys(), {'openSessionsInTerminal'});
    },
  );
}
