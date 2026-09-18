import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:context/app/app_state.dart';
import 'package:context/app/models.dart';
import 'package:context/main.dart';
import 'package:context/src/bindings/bindings.dart';
import 'package:context/ui/home_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show FontLoader, rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

const markdownPath = '/test/codex-out/codex sessions.md';
const snapshotKey = ValueKey('app-snapshot');

void emitState({
  String path = markdownPath,
  String name = 'Saved session',
  bool busy = false,
  bool accountBusy = false,
  bool recentBusy = false,
  String? recentTitle,
  String? warning,
  double usedPercent = 31.0,
  int? apiResetAt,
  int? manualResetAt,
  String? activeSlot = '1',
  List<Map<String, Object?>> extraAccounts = const [],
}) {
  String recentJson(String provider) => jsonEncode([
    if (recentTitle != null)
      {
        'provider': provider,
        'id': '$provider-recent',
        'title': '$recentTitle $provider',
        'updated_at': 1,
      },
  ]);
  final state = UiState(
    themeSeedColorValue: AppState.themeSeedColors.first,
    busy: busy,
    sessionsMarkdownPath: path,
    itemsJson: jsonEncode([
      {
        'kind': 'session',
        'id': 'test-session',
        'command_id': '11111111-1111-1111-1111-111111111111',
        'name': name,
        'color_hex': '',
        'provider': 'codex',
      },
    ]),
    warningsJson: jsonEncode([?warning]),
    recentCodexJson: recentJson('codex'),
    recentKimiJson: recentJson('kimi'),
    recentOpencodeJson: recentJson('opencode'),
    recentQwenJson: recentJson('qwen'),
    recentMuseJson: recentJson('muse'),
    recentZcodeJson: recentJson('zcode'),
    recentBusy: recentBusy,
    codexAccountsJson: jsonEncode([
      {
        'slot': '1',
        'name': 'Test account',
        'weekly_used_percent': usedPercent,
        'weekly_reset_at':
            apiResetAt ??
            DateTime.now().add(const Duration(days: 6)).millisecondsSinceEpoch,
        'weekly_window_seconds': 604800,
        'manual_reset_at': manualResetAt,
      },
      ...extraAccounts,
    ]),
    codexActiveAccount: activeSlot,
    codexAccountBusy: accountBusy,
    museAccountsJson: jsonEncode(const []),
    museAccountBusy: false,
    zcodeAccountsJson: jsonEncode(const []),
    zcodeAccountBusy: false,
  );
  assignRustSignal['UiState']!(state.bincodeSerialize(), Uint8List(0));
}

void finish(Uint64 requestId, {bool ok = true}) {
  final result = OpFinished(
    requestId: requestId,
    ok: ok,
    error: ok ? null : 'Simulated save failure',
  );
  assignRustSignal['OpFinished']!(result.bincodeSerialize(), Uint8List(0));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    // Use shipped fonts rather than the test font in the visual evidence.
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
  late AppState state;
  late List<Uint64> requests;

  void stateTest(String description, WidgetTesterCallback body) {
    testWidgets(description, (tester) async {
      // Native stream callbacks and the timers they create must share the
      // widget test's fake-clock zone, rather than setUp's real-clock zone.
      requests = <Uint64>[];
      state = AppState.forTesting(
        sendRequest: (requestId) {
          if (requestId != Uint64.fromBigInt(BigInt.zero)) {
            requests.add(requestId);
          }
        },
      );
      state.sessionsMarkdownPath = markdownPath;
      state.autosaveEnabled = false;
      try {
        await body(tester);
      } finally {
        state.dispose();
      }
    });
  }

  Future<void> mountApp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: state,
        child: const RepaintBoundary(key: snapshotKey, child: ContextView()),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<void> pumpSignalFrame(WidgetTester tester) async {
    // An idle app has no scheduled frame until the async Rust stream delivers.
    await tester.pump();
    await tester.pump();
  }

  Future<void> capture(WidgetTester tester, String name) async {
    final directory = Platform.environment['CONTEXT_UI_EVIDENCE_DIR'];
    if (directory == null || directory.isEmpty) return;
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(snapshotKey),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage();
      try {
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        if (bytes == null) throw StateError('Could not capture UI evidence.');
        await File(
          '$directory/$name.png',
        ).writeAsBytes(bytes.buffer.asUint8List());
      } finally {
        image.dispose();
      }
    });
  }

  stateTest(
    'account press keeps pending animation across refresh and activates on success',
    (tester) async {
      final reset = DateTime.now()
          .add(const Duration(days: 6))
          .millisecondsSinceEpoch;
      final second = <Map<String, Object?>>[
        {
          'slot': '2',
          'name': 'Second account',
          'weekly_used_percent': 12.0,
          'weekly_reset_at': reset,
          'weekly_window_seconds': 604800,
        },
      ];
      emitState(apiResetAt: reset, extraAccounts: second);
      await tester.pump();
      await mountApp(tester);
      await capture(tester, 'accounts-idle');
      final mouse = await tester.createGesture(
        kind: ui.PointerDeviceKind.mouse,
      );
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await mouse.moveTo(tester.getCenter(find.text('Second account')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 180));
      expect(find.text('Slot 2 \u00b7 click to activate'), findsOneWidget);
      await capture(tester, 'accounts-hover');
      await tester.tap(find.text('Second account'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(requests, hasLength(1));
      expect(state.codexActiveAccount, '1');
      expect(find.text('Slot 2 \u00b7 switching...'), findsOneWidget);
      await capture(tester, 'accounts-switching');
      emitState(apiResetAt: reset, extraAccounts: second, accountBusy: true);
      await pumpSignalFrame(tester);
      expect(find.text('Slot 2 \u00b7 switching...'), findsOneWidget);
      await tester.tap(find.text('Second account'));
      expect(requests, hasLength(1));
      emitState(apiResetAt: reset, extraAccounts: second, activeSlot: '2');
      finish(requests.single);
      await pumpSignalFrame(tester);
      await tester.pump(const Duration(milliseconds: 300));
      expect(state.codexActiveAccount, '2');
      expect(find.text('Slot 2 \u00b7 active'), findsOneWidget);
      expect(find.textContaining('switching...'), findsNothing);
      await capture(tester, 'accounts-activated');
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  stateTest(
    'failed account switch keeps the old active account and clears animation',
    (tester) async {
      emitState(
        extraAccounts: const [
          {'slot': '2', 'name': 'Second account'},
        ],
      );
      await tester.pump();
      await mountApp(tester);
      await tester.tap(find.text('Second account'));
      await tester.pump();
      expect(find.text('Slot 2 \u00b7 switching...'), findsOneWidget);
      finish(requests.single, ok: false);
      await pumpSignalFrame(tester);
      await tester.pump(const Duration(milliseconds: 300));
      expect(state.codexActiveAccount, '1');
      expect(find.text('Slot 1 \u00b7 active'), findsOneWidget);
      expect(find.textContaining('switching...'), findsNothing);
      expect(state.codexAccountBusy, isFalse);
      expect(state.codexAccountError, isNotNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  stateTest(
    'unchanged payloads reuse lists and changes replace only their list',
    (tester) async {
      final reset = DateTime.now()
          .add(const Duration(days: 6))
          .millisecondsSinceEpoch;
      emitState(
        apiResetAt: reset,
        recentTitle: 'Recent',
        warning: 'Test warning',
      );
      await tester.pump();
      final before = (
        state.items,
        state.codexAccounts,
        state.warnings,
        state.recentCodex,
        state.recentKimi,
        state.recentOpencode,
        state.recentQwen,
      );
      emitState(
        apiResetAt: reset,
        recentTitle: 'Recent',
        warning: 'Test warning',
        accountBusy: true,
      );
      await tester.pump();
      expect((
        state.items,
        state.codexAccounts,
        state.warnings,
        state.recentCodex,
        state.recentKimi,
        state.recentOpencode,
        state.recentQwen,
      ), before);

      emitState(
        apiResetAt: reset,
        recentTitle: 'Recent',
        warning: 'Test warning',
        usedPercent: 55,
      );
      await tester.pump();
      expect(state.items, same(before.$1));
      expect(state.codexAccounts, isNot(same(before.$2)));
      expect(state.codexAccounts.single.weeklyUsedPercent, 55);
      expect(state.recentCodex, same(before.$4));

      emitState(
        apiResetAt: reset,
        recentTitle: 'New',
        warning: 'New warning',
        usedPercent: 55,
      );
      await tester.pump();
      expect(state.warnings, ['New warning']);
      expect(state.recentCodex.single.title, 'New codex');
      expect(state.recentKimi.single.title, 'New kimi');
      expect(state.recentOpencode.single.title, 'New opencode');
      expect(state.recentQwen.single.title, 'New qwen');
    },
  );

  stateTest(
    'cached accounts restore after a path change clears visible accounts',
    (tester) async {
      final reset = DateTime.now()
          .add(const Duration(days: 6))
          .millisecondsSinceEpoch;
      emitState(apiResetAt: reset);
      await tester.pump();
      final accounts = state.codexAccounts;
      const path = '/other/codex sessions.md';
      final reload = state.loadConfig(markdownPath: path);
      expect(state.codexAccounts, isEmpty);
      emitState(path: path, apiResetAt: reset);
      finish(requests.single);
      await tester.pump();
      await reload;
      expect(state.codexAccounts, same(accounts));
    },
  );

  stateTest('theme rebuilds only when theme settings change', (tester) async {
    emitState();
    await tester.pump();
    await mountApp(tester);
    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    state.setFilterQuery('Saved');
    await tester.pump();
    emitState(accountBusy: true, usedPercent: 50);
    await pumpSignalFrame(tester);
    expect(tester.widget<MaterialApp>(find.byType(MaterialApp)), same(app));
    state.setThemeAppearance(ThemeAppearance.light);
    await tester.pump(const Duration(milliseconds: 300));
    final light = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(light, isNot(same(app)));
    expect(light.theme!.brightness, Brightness.light);
    expect(light.theme!.colorScheme, isNot(app.theme!.colorScheme));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  stateTest('filtering leaves account and recent widgets intact', (
    tester,
  ) async {
    emitState(recentTitle: 'Recent');
    await tester.pump();
    await mountApp(tester);
    final account = tester.widget<Text>(find.text('Test account'));
    final recent = tester.widget<Text>(find.text('Recent codex'));
    await tester.enterText(find.byType(TextField), 'Saved');
    await tester.pump();
    expect(find.text('Saved session'), findsOneWidget);
    expect(tester.widget<Text>(find.text('Test account')), same(account));
    expect(tester.widget<Text>(find.text('Recent codex')), same(recent));
    await tester.enterText(find.byType(TextField), 'no matching session');
    await tester.pump();
    expect(find.text('No matching contexts.'), findsOneWidget);
    expect(find.text('Saved session'), findsNothing);
    expect(tester.widget<Text>(find.text('Test account')), same(account));
    expect(tester.widget<Text>(find.text('Recent codex')), same(recent));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  stateTest(
    'account updates leave session rows intact but real edits still rebuild them',
    (tester) async {
      emitState();
      await tester.pump();
      await mountApp(tester);
      final session = tester.widget<Text>(find.text('Saved session'));
      emitState(accountBusy: true);
      await pumpSignalFrame(tester);
      emitState(usedPercent: 55);
      await pumpSignalFrame(tester);
      expect(tester.widget<Text>(find.text('Saved session')), same(session));
      expect(find.text('45% left'), findsOneWidget);
      state.renameSession(0, 'Renamed session');
      await tester.pump();
      expect(find.text('Saved session'), findsNothing);
      expect(find.text('Renamed session'), findsOneWidget);
      expect(find.text('Unsaved'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  stateTest(
    'recent refresh leaves accounts intact and provider switching works',
    (tester) async {
      final reset = DateTime.now()
          .add(const Duration(days: 6))
          .millisecondsSinceEpoch;
      emitState(apiResetAt: reset, recentTitle: 'Recent');
      await tester.pump();
      await mountApp(tester);
      final account = tester.widget<Text>(find.text('Test account'));
      final session = tester.widget<Text>(find.text('Saved session'));
      emitState(apiResetAt: reset, recentTitle: 'Recent', recentBusy: true);
      await pumpSignalFrame(tester);
      emitState(apiResetAt: reset, recentTitle: 'Updated');
      await pumpSignalFrame(tester);
      expect(tester.widget<Text>(find.text('Test account')), same(account));
      expect(tester.widget<Text>(find.text('Saved session')), same(session));
      expect(find.text('Updated codex'), findsOneWidget);
      state.setRecentProvider(SessionProvider.kimi);
      await tester.pump();
      expect(find.text('Updated kimi'), findsOneWidget);
      expect(find.text('Test account'), findsNothing);
      state.setRecentProvider(SessionProvider.codex);
      await tester.pump();
      expect(find.text('Test account'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  stateTest(
    'refresh boundaries recalculate pacing even with unchanged account payload',
    (tester) async {
      final reset = DateTime.now()
          .add(const Duration(days: 6))
          .millisecondsSinceEpoch;
      emitState(apiResetAt: reset);
      await tester.pump();
      await mountApp(tester);
      final accounts = state.codexAccounts;
      final paceFinder = find.textContaining('Pace:');
      final pace = tester.widget<Text>(paceFinder);
      emitState(apiResetAt: reset, accountBusy: true);
      await pumpSignalFrame(tester);
      final refreshing = tester.widget<Text>(paceFinder);
      expect(refreshing, isNot(same(pace)));
      emitState(apiResetAt: reset);
      await pumpSignalFrame(tester);
      expect(tester.widget<Text>(paceFinder), isNot(same(refreshing)));
      expect(state.codexAccounts, same(accounts));
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  stateTest('coalesced refresh still updates time-based labels', (
    tester,
  ) async {
    final reset = DateTime.now()
        .add(const Duration(days: 6))
        .millisecondsSinceEpoch;
    emitState(apiResetAt: reset, recentTitle: 'Recent');
    await tester.pump();
    await mountApp(tester);
    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    final accounts = state.codexAccounts;
    final recent = state.recentCodex;
    final paceFinder = find.textContaining('Pace:');
    final pace = tester.widget<Text>(paceFinder);
    final recentTitle = tester.widget<Text>(find.text('Recent codex'));
    final session = tester.widget<Text>(find.text('Saved session'));
    emitState(
      apiResetAt: reset,
      recentTitle: 'Recent',
      accountBusy: true,
      recentBusy: true,
    );
    emitState(apiResetAt: reset, recentTitle: 'Recent');
    await pumpSignalFrame(tester);
    expect(state.codexAccountRefreshRevision, 1);
    expect(state.recentRefreshRevision, 1);
    expect(state.codexAccounts, same(accounts));
    expect(state.recentCodex, same(recent));
    expect(tester.widget<Text>(paceFinder), isNot(same(pace)));
    expect(
      tester.widget<Text>(find.text('Recent codex')),
      isNot(same(recentTitle)),
    );
    expect(tester.widget<Text>(find.text('Saved session')), same(session));
    expect(tester.widget<MaterialApp>(find.byType(MaterialApp)), same(app));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  stateTest('busy controls and warnings still follow backend state', (
    tester,
  ) async {
    emitState();
    await tester.pump();
    await mountApp(tester);
    final addEntry = find.widgetWithText(FilledButton, 'Add Entry');
    expect(tester.widget<FilledButton>(addEntry).onPressed, isNotNull);
    emitState(busy: true, warning: 'Test warning');
    await pumpSignalFrame(tester);
    expect(tester.widget<FilledButton>(addEntry).onPressed, isNull);
    expect(find.text('Test warning'), findsOneWidget);
    emitState();
    await pumpSignalFrame(tester);
    expect(tester.widget<FilledButton>(addEntry).onPressed, isNotNull);
    expect(find.text('Test warning'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  stateTest('reset saves and clears independently of account refresh', (
    tester,
  ) async {
    emitState(accountBusy: true);
    await tester.pump();
    final refresh = state.loadCodexAccounts();
    final refreshRequest = requests.single;
    final reset = state.setCodexManualReset(
      DateTime.now().add(const Duration(days: 1)),
    );
    expect(state.codexManualResetBusy, isTrue);
    expect(requests, hasLength(2));
    finish(requests.last);
    await tester.pump();
    await reset;
    expect(state.codexManualResetBusy, isFalse);
    expect(state.codexAccountBusy, isTrue);

    final clear = state.clearCodexManualReset();
    finish(requests.last);
    await tester.pump();
    await clear;
    expect(state.codexAccountBusy, isTrue);
    emitState();
    finish(refreshRequest);
    await tester.pump();
    await refresh;
    expect(state.codexAccountBusy, isFalse);
  });

  stateTest('refresh triggers coalesce instead of queuing another refresh', (
    tester,
  ) async {
    final refresh = state.loadCodexAccounts();
    await state.loadCodexAccounts();
    await state.loadCodexAccounts();
    expect(requests, hasLength(1));
    finish(requests.single);
    await tester.pump();
    await refresh;
    expect(requests, hasLength(1));
  });

  stateTest('failed reset releases its own busy flag without ending refresh', (
    tester,
  ) async {
    emitState(accountBusy: true);
    await tester.pump();
    final save = state.setCodexManualReset(
      DateTime.now().add(const Duration(days: 1)),
    );
    final failure = expectLater(save, throwsException);
    finish(requests.single, ok: false);
    await tester.pump();
    await failure;
    expect(state.codexManualResetBusy, isFalse);
    expect(state.codexAccountBusy, isTrue);
  });

  stateTest('background state never replaces unsaved session names', (
    tester,
  ) async {
    emitState();
    await tester.pump();
    state.renameSession(0, 'My unsaved name');
    emitState(accountBusy: true);
    await tester.pump();
    emitState();
    await tester.pump();
    expect(state.items.single.name, 'My unsaved name');
    expect(state.dirty, isTrue);
  });

  stateTest('an older save cannot mark newer edits as saved', (tester) async {
    emitState();
    await tester.pump();
    state.renameSession(0, 'First edit');
    final save = state.saveConfig();
    emitState(name: 'First edit', busy: true);
    await tester.pump();
    state.renameSession(0, 'Second edit');
    emitState(name: 'First edit');
    finish(requests.single);
    await tester.pump();
    await save;
    expect(state.items.single.name, 'Second edit');
    expect(state.dirty, isTrue);

    final latestSave = state.saveConfig();
    emitState(name: 'Second edit');
    finish(requests.last);
    await tester.pump();
    await latestSave;
    expect(state.dirty, isFalse);
  });

  stateTest('autosave retries edits made during a previous save', (
    tester,
  ) async {
    state.autosaveEnabled = true;
    emitState();
    await tester.pump();
    state.renameSession(0, 'First edit');
    await tester.pump(const Duration(milliseconds: 500));
    final firstSave = requests.single;
    emitState(name: 'First edit', busy: true);
    await tester.pump();
    state.renameSession(0, 'Second edit');
    await tester.pump(const Duration(milliseconds: 600));
    expect(requests, hasLength(1));
    emitState(name: 'First edit');
    finish(firstSave);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(requests, hasLength(2));
    emitState(name: 'Second edit');
    finish(requests.last);
    await tester.pump();
    expect(state.dirty, isFalse);
  });

  stateTest('explicit reload can replace unsaved edits', (tester) async {
    emitState();
    await tester.pump();
    state.renameSession(0, 'Discard this edit');
    final reload = state.loadConfig();
    emitState(busy: true);
    await tester.pump();
    emitState(name: 'Loaded from markdown');
    finish(requests.single);
    await tester.pump();
    await reload;
    expect(state.items.single.name, 'Loaded from markdown');
    expect(state.dirty, isFalse);
  });

  stateTest(
    'reload restores an unchanged file even when completion arrives first',
    (tester) async {
      emitState();
      await tester.pump();
      state.renameSession(0, 'Discard this edit');
      final reload = state.loadConfig();
      finish(requests.single);
      await tester.pump();
      await reload;
      emitState();
      await tester.pump();
      expect(state.items.single.name, 'Saved session');
      expect(state.dirty, isFalse);
    },
  );

  stateTest('old refresh state cannot undo a newly selected markdown path', (
    tester,
  ) async {
    emitState();
    await tester.pump();
    const nextPath = '/other/codex-out/codex sessions.md';
    final reload = state.loadConfig(markdownPath: nextPath);
    emitState(accountBusy: true);
    await tester.pump();
    expect(state.sessionsMarkdownPath, nextPath);
    emitState(path: nextPath, name: 'Other file');
    finish(requests.single);
    await tester.pump();
    await reload;
    expect(state.items.single.name, 'Other file');
    expect(state.sessionsMarkdownPath, nextPath);
  });

  stateTest('manual reset dialog opens and submits while accounts refresh', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    emitState(accountBusy: true);
    await tester.pump();
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: state,
        child: const MaterialApp(home: HomeScreen()),
      ),
    );
    await tester.tap(find.byTooltip('Set manual reset'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Set manual Codex reset'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Set'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(requests, hasLength(1));
    expect(state.codexManualResetBusy, isTrue);
    final manual = DateTime.now()
        .add(const Duration(days: 1))
        .millisecondsSinceEpoch;
    emitState(accountBusy: true, manualResetAt: manual);
    finish(requests.last);
    await tester.pump();
    await tester.tap(find.byTooltip('Remove manual reset'));
    await tester.pump();
    expect(requests, hasLength(2));
    emitState(accountBusy: true);
    finish(requests.last);
    await tester.pump();
    expect(state.codexManualResetBusy, isFalse);
    expect(state.codexAccountBusy, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
