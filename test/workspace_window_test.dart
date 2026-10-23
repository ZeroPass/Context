import 'dart:async';

import 'package:context/app/app_state.dart';
import 'package:context/app/workspace_window.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];
  final adjusted = <double>[];
  var width = 800.0;
  var normal = true;
  var maximumWidth = 4000.0;
  var failResize = false;
  late WorkspaceWindow window;
  late SharedPreferences prefs;

  Future<void> create([Map<String, Object> values = const {}]) async {
    SharedPreferences.setMockInitialValues(values);
    prefs = await SharedPreferences.getInstance();
    window = WorkspaceWindow(prefs, onSplitAdjusted: adjusted.add);
  }

  Future<void> resized(double value, {bool isNormal = true}) async {
    width = value;
    normal = isNormal;
    final done = Completer<void>();
    ServicesBinding.instance.channelBuffers.push(
      workspaceWindowChannel.name,
      const StandardMethodCodec().encodeMethodCall(
        MethodCall('resized', {'width': width, 'normal': normal}),
      ),
      (_) => done.complete(),
    );
    await done.future;
  }

  List<double> getRequestedWidths() => calls
      .where((call) => call.method == 'setWidth')
      .map((call) => call.arguments as double)
      .toList();

  setUp(() async {
    calls.clear();
    adjusted.clear();
    width = 800;
    normal = true;
    maximumWidth = 4000;
    failResize = false;
    messenger.setMockMethodCallHandler(workspaceWindowChannel, (call) async {
      calls.add(call);
      if (call.method == 'setWidth') {
        if (failResize) throw PlatformException(code: 'window_resize');
        width = (call.arguments as double).clamp(320, maximumWidth);
      }
      return {'width': width, 'normal': normal};
    });
    await create();
  });

  tearDown(() {
    window.dispose();
    messenger.setMockMethodCallHandler(workspaceWindowChannel, null);
  });

  test(
    'default opening expands from 100 to 300 percent and hiding restores Context width',
    () async {
      await window.restore(visible: false);
      await window.setVisible(true);
      expect(width, 2400);
      expect(adjusted.last, closeTo(1 / 3, 0.0001));
      await window.setVisible(false);
      expect(width, 800);
      expect(prefs.getDouble('contextWindowWidth'), 800);
      expect(prefs.containsKey('whiteboardWindowWidth'), isFalse);
    },
  );

  test(
    'resizing Context updates the base width while expanded resizing adjusts the split',
    () async {
      await window.restore(visible: false);
      await resized(900);
      await window.setVisible(true);
      expect(width, 2700);
      await resized(1600);
      expect(adjusted.last, 900 / 1600);
      await window.setVisible(false);
      expect(width, 900);
      await resized(1000);
      await window.setVisible(true);
      expect(width, 3000);
      await window.setVisible(false);
      expect(width, 1000);
    },
  );

  for (final visible in [false, true]) {
    test(
      'restart restores saved ${visible ? 'expanded' : 'Context-only'} width',
      () async {
        await create({
          'contextWindowWidth': 750.0,
          'whiteboardWindowWidth': 1450.0,
          'whiteboardSplit': 0.5,
        });
        await window.restore(visible: visible);
        expect(width, visible ? 1500 : 750);
        await window.setVisible(!visible);
        expect(width, visible ? 750 : 1500);
        expect(prefs.containsKey('whiteboardWindowWidth'), isFalse);
      },
    );
  }

  test(
    'first launch with Whiteboard already enabled expands exactly once',
    () async {
      await window.restore(visible: true);
      expect(width, 2400);
      await window.setVisible(true);
      expect(width, 2400);
      expect(getRequestedWidths(), [2400]);
      await window.setVisible(false);
      expect(width, 800);
    },
  );

  test(
    'maximized or minimized bounds do not resize or replace normal widths',
    () async {
      await create({
        'contextWindowWidth': 750.0,
        'whiteboardWindowWidth': 1450.0,
        'whiteboardSplit': 0.5,
      });
      normal = false;
      width = 2200;
      await window.restore(visible: true);
      await resized(2200, isNormal: false);
      await window.setVisible(false);
      expect(getRequestedWidths(), isEmpty);
      expect(prefs.getDouble('contextWindowWidth'), 750);
      expect(prefs.containsKey('whiteboardWindowWidth'), isFalse);
      normal = true;
      width = 750;
      await window.setVisible(true);
      expect(width, 1500);
    },
  );

  test(
    'rapid toggles are serialized without accumulating extra growth',
    () async {
      await window.restore(visible: false);
      await Future.wait([
        window.setVisible(true),
        window.setVisible(false),
        window.setVisible(true),
        window.setVisible(false),
      ]);
      expect(width, 800);
      expect(getRequestedWidths(), [800, 2400, 800, 2400, 800]);
    },
  );

  test(
    'minimizing does not replace the effective split with iconic window bounds',
    () async {
      await window.restore(visible: true);
      expect(adjusted, [1 / 3]);
      await resized(160, isNormal: false);
      expect(adjusted, [1 / 3]);
      await resized(2400);
      expect(adjusted.last, 1 / 3);
    },
  );

  test(
    'screen cap adjusts the effective split without losing the preferred ratio',
    () async {
      maximumWidth = 1600;
      await window.restore(visible: false);
      await window.setVisible(true);
      expect(width, 1600);
      expect(adjusted.last, 0.5);
      expect(prefs.containsKey('whiteboardSplit'), isFalse);
      await window.setVisible(false);
      await window.setVisible(true);
      expect(width, 1600);
      expect(getRequestedWidths(), [800, 2400, 800, 2400]);
      await window.setVisible(false);
      maximumWidth = 4000;
      await window.setVisible(true);
      expect(width, 2400);
      expect(adjusted.last, closeTo(1 / 3, 0.0001));
    },
  );

  test('opening never narrows a newly enlarged Context-only window', () async {
    await create({
      'contextWindowWidth': 750.0,
      'whiteboardWindowWidth': 1000.0,
    });
    await window.restore(visible: false);
    await resized(1100);
    await window.setVisible(true);
    expect(width, 3300);
  });

  test(
    'divider-selected ratio controls the next expansion, not a stale saved width',
    () async {
      await create({'whiteboardWindowWidth': 1200.0});
      await window.restore(visible: false);
      await window.setVisible(true);
      expect(width, 2400);
      window.setSplit(0.5);
      await window.setVisible(false);
      expect(width, 800);
      await window.setVisible(true);
      expect(width, 1600);
      expect(adjusted.last, 0.5);
      window.setSplit(0.25);
      await window.setVisible(false);
      await window.setVisible(true);
      expect(width, 3200);
      expect(adjusted.last, 0.25);
    },
  );

  test(
    'screen cap still applies to an explicitly saved divider ratio',
    () async {
      await create({'contextWindowWidth': 800.0, 'whiteboardSplit': 0.25});
      maximumWidth = 1920;
      await window.restore(visible: true);
      expect(width, 1920);
      expect(adjusted.last, closeTo(800 / 1920, 0.0001));
      expect(prefs.getDouble('whiteboardSplit'), 0.25);
      await window.setVisible(false);
      expect(width, 800);
      await window.setVisible(true);
      expect(width, 1920);
    },
  );

  test(
    'missing native support leaves the existing layout usable without polling',
    () async {
      messenger.setMockMethodCallHandler(workspaceWindowChannel, null);
      await window.restore(visible: false);
      await window.setVisible(true);
      await window.setVisible(false);
      expect(calls, isEmpty);
    },
  );

  test('a failed resize does not block later toggles', () async {
    await window.restore(visible: false);
    failResize = true;
    await expectLater(
      window.setVisible(true),
      throwsA(isA<PlatformException>()),
    );
    failResize = false;
    await window.setVisible(false);
    await window.setVisible(true);
    expect(width, 2400);
  });

  test('disposed window ignores queued work', () async {
    await window.restore(visible: false);
    calls.clear();
    final pending = window.setVisible(true);
    window.dispose();
    await pending;
    expect(calls, isEmpty);
  });

  test('invalid stored dimensions and split values fall back safely', () async {
    await create({'contextWindowWidth': -20.0, 'whiteboardWindowWidth': 'bad'});
    await window.restore(visible: true);
    expect(width, 2400);
    for (final value in [null, double.nan, double.infinity, 0, 1, -1, 'bad']) {
      expect(
        whiteboardContextFraction(value),
        defaultWhiteboardContextFraction,
      );
    }
    expect(whiteboardContextFraction(0.45), 0.45);
  });

  test(
    'AppState persists the split separately from visibility and reloads it',
    () async {
      final first = AppState.forTesting(
        sendRequest: (_) {},
        preferences: prefs,
      );
      await first.setWhiteboardSplit(0.47);
      await first.setWhiteboardEnabled(true);
      first.dispose();
      final reopened = AppState.forTesting(
        sendRequest: (_) {},
        preferences: prefs,
      );
      expect(reopened.whiteboardSplit, 0.47);
      expect(reopened.whiteboardEnabled, isTrue);
      await reopened.setWhiteboardEnabled(false);
      expect(reopened.whiteboardSplit, 0.47);
      reopened.dispose();
    },
  );
}
