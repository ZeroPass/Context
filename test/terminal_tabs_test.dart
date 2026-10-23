import 'dart:async';
import 'dart:convert';

import 'package:context/app/app_state.dart';
import 'package:context/app/models.dart';
import 'package:context/app/terminal_tabs.dart';
import 'package:context/ui/widgets/terminal_tabs_card.dart';
import 'package:context/ui/widgets/passive_tooltip.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> snapshot({
  String provider = 'codex',
  String? id = 'test-1234',
}) => {
  'sessions': [
    {
      'provider': provider,
      'launch_session_id': id,
      'name': 'Example',
      'cwd': '/home/test/project',
      'distro': 'Ubuntu',
      'pid': 10,
      'start': '1',
    },
  ],
  'windows': [
    {
      'hwnd': 1,
      'tabs': [
        {'title': 'Example | project', 'selected': true},
      ],
    },
  ],
};

const groupPath = r'\\wsl.localhost\Ubuntu-24.04\home\test\Context\sessions.md';

Map<String, dynamic> windowSnapshot(
  List<int> ids, {
  int window = 1,
  bool present = true,
}) => {
  'sessions': [
    for (final i in ids)
      <String, dynamic>{
        'provider': 'codex',
        'launch_session_id': 'session-$i',
        'name': 'Session $i',
        'cwd': '/home/test/project',
        'distro': 'Ubuntu-24.04',
        'pid': window * 100 + i,
        'start': '123',
      },
  ],
  'windows': [
    if (present)
      {
        'hwnd': window,
        'pid': window + 1000,
        'started': '${90000 + window}',
        'tabs': [
          for (final i in ids)
            {'title': 'Session $i', 'selected': i == ids.first},
        ],
      },
  ],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'observed full close remains a distinct group even if a handle is reused',
    (tester) async {
      var data = windowSnapshot([1, 2]);
      final monitor = TerminalTabs(reader: (_) async => data);
      monitor.follow(groupPath, active: true);
      await tester.pump();
      data = windowSnapshot([], present: false);
      await monitor.refresh(force: true);
      data = windowSnapshot([3]);
      await monitor.refresh(force: true);
      expect(monitor.groups, hasLength(2));
      expect(monitor.groups.first.closed, true);
      expect(monitor.isActive(monitor.groups.first), false);
      expect(monitor.groups.first.members, hasLength(2));
      expect(monitor.isActive(monitor.groups.last), true);
      monitor.dispose();
    },
  );

  testWidgets(
    'failed restore members survive live snapshots and app restart until retried',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      var data = windowSnapshot([1, 2]);
      final monitor = TerminalTabs(
        reader: (_) async => data,
        preferences: prefs,
      );
      monitor.follow(groupPath, active: true);
      await tester.pump();
      final original = monitor.groups.single;
      data = windowSnapshot([], present: false);
      await expectLater(
        monitor.openGroup(original, (session, _) async {
          if (session.id == 'session-2') {
            throw StateError('Failed second launch');
          }
          data = windowSnapshot([1], window: 2);
          await monitor.refresh(force: true);
          return true;
        }),
        throwsStateError,
      );
      expect(monitor.groups.single.members, hasLength(2));
      expect(monitor.groups.single.pending, hasLength(1));
      await monitor.flushGroups();
      monitor.dispose();
      final next = TerminalTabs(reader: (_) async => data, preferences: prefs);
      next.follow(groupPath, active: true);
      await tester.pump(const Duration(seconds: 4));
      expect(next.groups.single.members, hasLength(2));
      final attempts = <String>[];
      await next.openGroup(next.groups.single, (session, _) async {
        attempts.add(session.id);
        data = windowSnapshot([1, 2], window: 2);
        return true;
      });
      expect(attempts, ['session-2']);
      expect(next.groups.single.pending, isEmpty);
      expect(next.groups.single.id, original.id);
      next.dispose();
    },
  );

  testWidgets('saved Context names can identify and order Terminal tabs', (
    tester,
  ) async {
    final data = windowSnapshot([1, 2]);
    ((data['windows'] as List).single as Map)['tabs'] = [
      {'title': 'Saved two'},
      {'title': 'Saved one'},
    ];
    final monitor = TerminalTabs(
      reader: (_) async => data,
      savedSessions: () => [
        ConfigItem.session(
          commandId: 'session-1',
          name: 'Saved one',
          provider: SessionProvider.codex,
        ),
        ConfigItem.session(
          commandId: 'session-2',
          name: 'Saved two',
          provider: SessionProvider.codex,
        ),
      ],
    );
    monitor.follow(groupPath, active: true);
    await tester.pump();
    expect(monitor.groups.single.members.map((s) => s.id), [
      'session-2',
      'session-1',
    ]);
    monitor.dispose();
  });

  testWidgets(
    'unknown live IDs block unsafe restore, rather than guessing duplicates',
    (tester) async {
      var data = windowSnapshot([1]);
      final monitor = TerminalTabs(reader: (_) async => data);
      monitor.follow(groupPath, active: true);
      await tester.pump();
      final saved = monitor.groups.single;
      data = windowSnapshot([2], window: 2);
      ((data['sessions'] as List).single as Map)['launch_session_id'] = null;
      var opens = 0;
      await expectLater(
        monitor.openGroup(saved, (_, _) async {
          opens++;
          return true;
        }),
        throwsStateError,
      );
      expect(opens, 0);
      monitor.dispose();
    },
  );

  test('Claude parsing, copy/fork and provider migration', () async {
    SharedPreferences.setMockInitialValues({});
    final state = AppState.forTesting(
      sendRequest: (_) {},
      preferences: await SharedPreferences.getInstance(),
    );
    addTearDown(state.dispose);
    state.recentTabOrder = [
      'codex',
      'kimi',
      'opencode',
      'qwen',
      'muse',
      'zcode',
    ];
    expect(state.orderedRecentTabs, contains(SessionProvider.claude));
    state.hideRecentTab(SessionProvider.claude);
    expect(state.orderedRecentTabs, isNot(contains(SessionProvider.claude)));
    state.unhideRecentTab(SessionProvider.claude);
    expect(state.orderedRecentTabs, contains(SessionProvider.claude));
    final parsed = state.parseSessionInput(
      'claude --resume abc-1234',
      fallback: SessionProvider.codex,
    );
    expect(parsed.provider, SessionProvider.claude);
    final item = ConfigItem.session(
      commandId: parsed.id,
      name: 'Claude',
      provider: parsed.provider,
    );
    expect(item.shortId, '1234');
    expect(item.resumeCommand, 'claude --resume abc-1234');
    expect(item.forkCommand, 'claude --resume abc-1234 --fork-session');
  });

  testWidgets('discovery coalesces and stops polling while inactive', (
    tester,
  ) async {
    var reads = 0;
    final pending = Completer<Map<String, dynamic>>();
    final monitor = TerminalTabs(
      reader: (_) {
        reads++;
        return pending.future;
      },
    );
    monitor.follow('/test', active: true);
    await monitor.refresh(force: true);
    expect(reads, 1);
    pending.complete(snapshot());
    await tester.pump();
    expect(monitor.sessions.single.shortId, '1234');
    expect(monitor.tabFor(monitor.sessions.single)?['selected'], true);
    monitor.follow('/test', active: false);
    await tester.pump(const Duration(minutes: 2));
    expect(reads, 1);
    monitor.dispose();
  });

  testWidgets('path changes discard old snapshots and refresh the new path', (
    tester,
  ) async {
    final old = Completer<Map<String, dynamic>>();
    final calls = <String>[];
    final monitor = TerminalTabs(
      reader: (path) {
        calls.add(path);
        return path == '/old'
            ? old.future
            : Future.value(snapshot(provider: 'claude'));
      },
    );
    monitor.follow('/old', active: true);
    monitor.follow('/new', active: true);
    old.complete(snapshot());
    await tester.pump();
    expect(calls, ['/old', '/new']);
    expect(monitor.sessions.single.provider, SessionProvider.claude);
    monitor.dispose();
  });

  testWidgets('failures retain last data and unknown IDs are not invented', (
    tester,
  ) async {
    var fail = false;
    final monitor = TerminalTabs(
      reader: (_) async {
        if (fail) throw StateError('offline');
        return snapshot(provider: 'claude', id: null);
      },
    );
    monitor.follow('/test', active: true);
    await tester.pump();
    expect(monitor.sessions.single.shortId, '?');
    fail = true;
    await monitor.refresh(force: true);
    expect(monitor.sessions, hasLength(1));
    expect(monitor.error, contains('previous snapshot'));
    monitor.dispose();
  });

  testWidgets('ambiguous tab titles do not claim selection', (tester) async {
    final data = snapshot();
    (data['sessions'] as List).add(<String, Object?>{
      ...Map<String, Object?>.from((data['sessions'] as List).first as Map),
      'pid': 20,
    });
    final monitor = TerminalTabs(reader: (_) async => data);
    monitor.follow('/test', active: true);
    await tester.pump();
    expect(monitor.tabFor(monitor.sessions.first), isNull);
    monitor.dispose();
  });

  testWidgets('Terminal cards reuse saved names and remain non-interactive', (
    tester,
  ) async {
    final monitor = TerminalTabs(reader: (_) async => snapshot());
    monitor.follow('/test', active: true);
    await tester.pump();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TerminalTabsCard(
            monitor: monitor,
            saved: [
              ConfigItem.session(
                commandId: 'test-1234',
                name: 'Saved name',
                provider: SessionProvider.codex,
              ),
            ],
            providerColor: (_) => Colors.amber,
          ),
        ),
      ),
    );
    expect(find.text('Terminal tabs'), findsOneWidget);
    expect(find.text('Codex 1234'), findsNothing);
    expect(find.text('Saved name'), findsOneWidget);
    final tab = find.byKey(const ValueKey('terminal-session-10:1'));
    final ink = tester.widget<InkWell>(
      find.descendant(of: tab, matching: find.byType(InkWell)),
    );
    expect(ink.onTap, isNull);
    expect(tester.widget<PassiveTooltip>(tab).message, 'Codex\ntest-1234');
    expect(find.textContaining('Ubuntu'), findsNothing);
    await tester.tap(find.text('Saved name'));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    monitor.dispose();
  });

  testWidgets('compact tabs fit four across and wrap without expanding names', (
    tester,
  ) async {
    final data = snapshot();
    data['sessions'] = [
      for (var i = 0; i < 5; i++)
        {
          ...Map<String, dynamic>.from((snapshot()['sessions'] as List).first),
          'pid': 10 + i,
          'launch_session_id': 'test-123$i',
        },
    ];
    final monitor = TerminalTabs(reader: (_) async => data);
    monitor.follow('/test', active: true);
    await tester.pump();
    const longName =
        'A very long saved session name that should never widen a tab';
    for (final width in [320.0, 460.0, 700.0]) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: width,
                child: TerminalTabsCard(
                  monitor: monitor,
                  saved: [
                    ConfigItem.session(
                      commandId: 'test-1230',
                      name: longName,
                      provider: SessionProvider.codex,
                    ),
                    ConfigItem.session(
                      commandId: 'test-1231',
                      name: 'Wrong provider',
                      provider: SessionProvider.claude,
                    ),
                  ],
                  providerColor: (_) => Colors.amber,
                ),
              ),
            ),
          ),
        ),
      );
      final labels = [
        find.text(longName),
        for (var i = 1; i < 5; i++) find.text('Codex 123$i'),
      ];
      Finder tile(int i) =>
          find.byKey(ValueKey('terminal-session-${10 + i}:1'));
      final firstY = tester.getTopLeft(tile(0)).dy;
      for (var i = 0; i < 4; i++) {
        expect(tester.getTopLeft(tile(i)).dy, firstY);
      }
      for (final label in labels.take(4)) {
        final text = tester.widget<Text>(label);
        expect(text.maxLines, 1);
        expect(text.overflow, TextOverflow.ellipsis);
      }
      expect(
        tester.getTopLeft(tile(4)).dy,
        width < 600 ? greaterThan(firstY) : firstY,
      );
      expect(find.text('Example'), findsNothing);
      expect(find.text('Wrong provider'), findsNothing);
      expect(find.textContaining('Ubuntu'), findsNothing);
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(const SizedBox.shrink());
    monitor.dispose();
  });

  testWidgets(
    'window groups persist; individual closes shrink and whole closes preserve',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      var data = windowSnapshot([1, 2, 3]);
      var now = DateTime(2026, 10, 23);
      final monitor = TerminalTabs(
        reader: (_) async => data,
        preferences: prefs,
        now: () => now,
      );
      monitor.follow(groupPath, active: true);
      await tester.pump();
      expect(monitor.groups.single.members, hasLength(3));
      final original = monitor.groups.single.id;
      data = windowSnapshot([1, 3]);
      await monitor.refresh(force: true);
      expect(monitor.groups.single.members, hasLength(3));
      now = now.add(const Duration(seconds: 3));
      await tester.pump(const Duration(seconds: 3));
      expect(monitor.groups.single.members.map((s) => s.id), [
        'session-1',
        'session-3',
      ]);
      data = windowSnapshot([], present: false);
      await monitor.refresh(force: true);
      expect(monitor.isActive(monitor.groups.single), false);
      expect(monitor.groups.single.members, hasLength(2));
      await monitor.flushGroups();
      monitor.dispose();

      final restarted = TerminalTabs(
        reader: (_) async => data,
        preferences: prefs,
      );
      expect(restarted.groups.single.id, original);
      data = windowSnapshot([4], window: 2);
      restarted.follow(groupPath, active: true);
      await tester.pump();
      expect(restarted.groups, hasLength(2));
      expect(restarted.groups.first.id, original);
      expect(restarted.groups.first.members, hasLength(2));
      expect(restarted.groups.last.members.single.id, 'session-4');
      await restarted.renameGroup(original, 'Work');
      expect(restarted.groups.first.name, 'Work');
      await expectLater(
        restarted.deleteGroup(restarted.groups.last.id),
        throwsStateError,
      );
      await restarted.deleteGroup(original);
      expect(restarted.groups, hasLength(1));
      final stored =
          jsonDecode(prefs.getString(TerminalTabs.groupsPreferenceKey)!) as Map;
      expect(stored['groups'], hasLength(1));
      restarted.dispose();
    },
  );

  testWidgets(
    'a closing window does not save its intermediate empty or partial set',
    (tester) async {
      var data = windowSnapshot([1, 2, 3]);
      final monitor = TerminalTabs(reader: (_) async => data);
      monitor.follow(groupPath, active: true);
      await tester.pump();
      data = windowSnapshot([1]);
      await monitor.refresh(force: true);
      data = windowSnapshot([], present: false);
      await tester.pump(const Duration(seconds: 3));
      expect(monitor.groups.single.members, hasLength(3));
      expect(monitor.isActive(monitor.groups.single), false);
      monitor.dispose();
    },
  );

  testWidgets('window identity reuse creates a new group, not replacement', (
    tester,
  ) async {
    var data = windowSnapshot([1, 2]);
    final monitor = TerminalTabs(reader: (_) async => data);
    monitor.follow(groupPath, active: true);
    await tester.pump();
    final old = monitor.groups.single.id;
    data = windowSnapshot([3]);
    ((data['windows'] as List).single as Map)['started'] = '999999';
    await monitor.refresh(force: true);
    expect(monitor.groups, hasLength(2));
    expect(monitor.groups.first.id, old);
    expect(monitor.isActive(monitor.groups.first), false);
    expect(monitor.groups.first.members, hasLength(2));
    monitor.dispose();
  });

  testWidgets(
    'partial restore skips existing sessions and appends only missing tabs',
    (tester) async {
      var data = windowSnapshot([1, 2]);
      final monitor = TerminalTabs(reader: (_) async => data);
      monitor.follow(groupPath, active: true);
      await tester.pump();
      final remembered = monitor.groups.single;
      var opens = 0;
      expect(
        await monitor.openGroup(remembered, (_, _) async {
          opens++;
          return true;
        }),
        'Already open in Terminal.',
      );
      expect(opens, 0);
      data = windowSnapshot([], present: false);
      await monitor.refresh(force: true);
      data = windowSnapshot([1], window: 2);
      await monitor.refresh(force: true);
      final result = await monitor.openGroup(remembered, (
        session,
        target,
      ) async {
        opens++;
        expect(session.id, 'session-2');
        expect(target, '0');
        data = windowSnapshot([1, 2], window: 2);
        return true;
      });
      expect(opens, 1);
      expect(result, 'Opened 1 tab; 1 already open.');
      expect(monitor.groups, hasLength(2));
      expect(monitor.groups.first.id, remembered.id);
      expect(monitor.groups.first.window.handle, '1');
      expect(monitor.groups.first.closed, true);
      expect(monitor.groups.last.window.handle, '2');
      expect(monitor.groups.last.members.map((s) => s.id), [
        'session-1',
        'session-2',
      ]);
      monitor.dispose();
    },
  );

  testWidgets(
    'pending launches and simultaneous clicks do not duplicate tabs',
    (tester) async {
      var data = windowSnapshot([1, 2]);
      final monitor = TerminalTabs(reader: (_) async => data);
      monitor.follow(groupPath, active: true);
      await tester.pump();
      final group = monitor.groups.single;
      data = windowSnapshot([], present: false);
      final gate = Completer<bool>();
      var opened = 0;
      final first = monitor.openGroup(group, (_, _) {
        opened++;
        return gate.future;
      });
      await tester.pump();
      expect(
        await monitor.openGroup(group, (_, _) async {
          opened++;
          return true;
        }),
        contains('already opening'),
      );
      gate.complete(true);
      await first;
      expect(opened, 2);
      expect(
        await monitor.openGroup(group, (_, _) async {
          opened++;
          return true;
        }),
        'Already open in Terminal.',
      );
      expect(opened, 2);
      monitor.dispose();
    },
  );

  testWidgets(
    'partial launch failures preserve successful pending launches for retry',
    (tester) async {
      var data = windowSnapshot([1, 2]);
      final monitor = TerminalTabs(reader: (_) async => data);
      monitor.follow(groupPath, active: true);
      await tester.pump();
      final group = monitor.groups.single;
      data = windowSnapshot([], present: false);
      await expectLater(
        monitor.openGroup(group, (s, _) async {
          if (s.id == 'session-2') throw StateError('Launch failed');
          return true;
        }),
        throwsStateError,
      );
      final retried = <String>[];
      await monitor.openGroup(group, (s, _) async {
        retried.add(s.id);
        return true;
      });
      expect(retried, ['session-2']);
      monitor.dispose();
    },
  );

  testWidgets(
    'failed or incomplete discovery cannot clear groups or authorize duplicate opens',
    (tester) async {
      var data = windowSnapshot([1]);
      var fail = false;
      final monitor = TerminalTabs(
        reader: (_) async {
          if (fail) throw StateError('offline');
          return data;
        },
      );
      monitor.follow(groupPath, active: true);
      await tester.pump();
      final group = monitor.groups.single;
      fail = true;
      var opened = 0;
      await expectLater(
        monitor.openGroup(group, (_, _) async {
          opened++;
          return true;
        }),
        throwsStateError,
      );
      expect(opened, 0);
      expect(monitor.groups.single.members, hasLength(1));
      fail = false;
      data = {
        ...windowSnapshot([], present: false),
        'warnings': ['Process limit reached'],
      };
      await expectLater(
        monitor.openGroup(group, (_, _) async {
          opened++;
          return true;
        }),
        throwsStateError,
      );
      data = {
        ...windowSnapshot([], present: false),
        'tab_error': 'UIA unavailable',
      };
      await expectLater(monitor.deleteGroup(group.id), throwsStateError);
      expect(monitor.groups.single.id, group.id);
      monitor.dispose();
    },
  );

  testWidgets(
    'tab groups use the observed tab order and keep windows separate',
    (tester) async {
      final a = windowSnapshot([2, 1]);
      final b = windowSnapshot([3], window: 2);
      final data = {
        'sessions': [
          ...b['sessions'] as List,
          ...(a['sessions'] as List).reversed,
        ],
        'windows': [...a['windows'] as List, ...b['windows'] as List],
      };
      final monitor = TerminalTabs(reader: (_) async => data);
      monitor.follow(groupPath, active: true);
      await tester.pump();
      expect(monitor.orderedSessions().map((s) => s.id), [
        'session-2',
        'session-1',
        'session-3',
      ]);
      expect(monitor.groups, hasLength(2));
      expect(monitor.groups.first.members.map((s) => s.id), [
        'session-2',
        'session-1',
      ]);
      expect(monitor.groups.last.members.single.id, 'session-3');
      monitor.dispose();
    },
  );

  testWidgets(
    'corrupt group storage is not overwritten by automatic snapshots',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        TerminalTabs.groupsPreferenceKey: 'broken json',
      });
      final prefs = await SharedPreferences.getInstance();
      final monitor = TerminalTabs(
        reader: (_) async => windowSnapshot([1]),
        preferences: prefs,
      );
      monitor.follow(groupPath, active: true);
      await tester.pump();
      await monitor.flushGroups();
      expect(monitor.groupsError, contains('not overwritten'));
      expect(prefs.getString(TerminalTabs.groupsPreferenceKey), 'broken json');
      monitor.dispose();
    },
  );

  testWidgets(
    'group strip exposes restore and close actions with compact tooltips',
    (tester) async {
      final monitor = TerminalTabs(reader: (_) async => windowSnapshot([1, 2]));
      monitor.follow(groupPath, active: true);
      await tester.pump();
      final group = monitor.groups.single;
      var opens = 0, closes = 0;
      TerminalSession? clicked;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalTabsCard(
              monitor: monitor,
              saved: const [],
              providerColor: (_) => Colors.amber,
              onOpen: (_, session) {
                opens++;
                clicked = session;
              },
              onClose: (_) => closes++,
            ),
          ),
        ),
      );
      expect(find.text('Terminal 1'), findsOneWidget);
      expect(find.text('Open'), findsOneWidget);
      expect(find.textContaining('PID'), findsNothing);
      await tester.tap(find.byKey(ValueKey('terminal-open-${group.id}')));
      expect(opens, 1);
      expect(clicked, isNull);
      await tester.tap(find.text('Codex on-1'));
      expect(opens, 2);
      expect(clicked?.id, 'session-1');
      await tester.tap(find.byKey(ValueKey('terminal-close-${group.id}')));
      expect(closes, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      monitor.dispose();
    },
  );
}
