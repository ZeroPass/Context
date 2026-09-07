import 'dart:convert';
import 'dart:typed_data';

import 'package:context/app/app_state.dart';
import 'package:context/src/bindings/bindings.dart';
import 'package:context/ui/home_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

const markdownPath = '/test/codex-out/codex sessions.md';

void emitState({
  String path = markdownPath,
  String name = 'Saved session',
  bool busy = false,
  bool accountBusy = false,
  int? manualResetAt,
}) {
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
    warningsJson: '[]',
    recentCodexJson: '[]',
    recentKimiJson: '[]',
    recentOpencodeJson: '[]',
    recentQwenJson: '[]',
    recentBusy: false,
    codexAccountsJson: jsonEncode([
      {
        'slot': '1',
        'name': 'Test account',
        'weekly_used_percent': 31.0,
        'weekly_reset_at': DateTime.now()
            .add(const Duration(days: 6))
            .millisecondsSinceEpoch,
        'weekly_window_seconds': 604800,
        'manual_reset_at': manualResetAt,
      },
    ]),
    codexActiveAccount: '1',
    codexAccountBusy: accountBusy,
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
