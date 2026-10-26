import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:context/app/app_state.dart';
import 'package:context/app/models.dart';
import 'package:context/app/session_list.dart';
import 'package:context/main.dart';
import 'package:context/src/bindings/bindings.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

ConfigItem entry(int number) => ConfigItem.session(
  commandId: '00000000-0000-4000-8000-${number.toString().padLeft(12, '0')}',
  name: 'Entry $number',
  provider: SessionProvider.codex,
);
ConfigItem group(String id) =>
    ConfigItem.group(id: id, name: 'Group $id', colorHex: '#8EC07C');
List<ConfigItem> grouped() => [
  group('one'),
  ...List.generate(15, (i) => entry(i + 1)),
  ConfigItem.groupEnd(id: 'one'),
  entry(16),
];
const snapshot = ValueKey('sessions-snapshot');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
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

  test(
    'compact view contains ten sessions, expanded view all original indices',
    () {
      final items = List.generate(21, (i) => entry(i + 1));
      final compact = SessionListView(items, expanded: false);
      expect(compact.indices, List.generate(10, (i) => i));
      expect(compact.total, 21);
      expect(compact.canExpand, isTrue);
      expect(
        SessionListView(items, expanded: true).indices,
        List.generate(21, (i) => i),
      );
      expect(items.length, 21);
    },
  );

  test(
    'group markers do not consume the ten-session allowance and real lip remains',
    () {
      final items = grouped();
      final compact = SessionListView(items, expanded: false);
      expect(compact.indices, [...List.generate(11, (i) => i), 16]);
      expect(compact.indices.where((i) => items[i].isSession).length, 10);
      expect(items[compact.indices.last].isGroupEnd, isTrue);
      expect(items.length, 18);
    },
  );

  test('small lists retain empty groups without an expand button', () {
    final items = [group('empty'), ConfigItem.groupEnd(id: 'empty'), entry(1)];
    final compact = SessionListView(items, expanded: false);
    expect(compact.indices, [0, 1, 2]);
    expect(compact.canExpand, isFalse);
  });

  test('filtered projection searches full data, then limits matches only', () {
    final items = List.generate(40, (i) => entry(i + 1));
    final matches = List.generate(20, (i) => i + 20);
    final compact = SessionListView(items, expanded: false, matches: matches);
    expect(compact.indices, matches.take(10).toList());
    expect(compact.total, 20);
    expect(
      SessionListView(items, expanded: true, matches: matches).indices,
      matches,
    );
  });

  test(
    'dropping below a projected lip leaves the entire real group intact',
    () {
      final app = AppState.forTesting(sendRequest: (_) {})
        ..items = grouped()
        ..autosaveEnabled = false;
      final compact = SessionListView(app.items, expanded: false);
      app.reorderItems(
        compact.indices[1],
        compact.insertionIndex(1, compact.indices.length - 1),
      );
      final moved = app.items.indexWhere(
        (item) => item.commandId == entry(1).commandId,
      );
      expect(app.groupForItem(moved), isNull);
      expect(app.memberIndicesForGroup(0).length, 14);
      expect(app.items.where((item) => item.isSession).length, 16);
      app.dispose();
    },
  );

  test(
    'moving a partly hidden group moves all members without absorbing neighbours',
    () {
      final app = AppState.forTesting(sendRequest: (_) {})
        ..items = [...List.generate(9, (i) => entry(i + 100)), ...grouped()]
        ..autosaveEnabled = false;
      final compact = SessionListView(app.items, expanded: false);
      app.reorderItems(compact.indices[9], compact.insertionIndex(9, 0));
      expect(app.items.first.isGroup, isTrue);
      expect(app.memberIndicesForGroup(0).length, 15);
      expect(app.items[16].isGroupEnd, isTrue);
      expect(app.groupForItem(17), isNull);
      expect(app.items.where((item) => item.isSession).length, 25);
      app.dispose();
    },
  );

  Future<AppState> mount(
    WidgetTester tester, {
    List<ConfigItem>? items,
    double width = 900,
    double height = 1600,
    void Function(Uint64)? sender,
  }) async {
    tester.view.physicalSize = Size(width, height);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final app = AppState.forTesting(sendRequest: sender ?? (_) {})
      ..items = items ?? List.generate(21, (i) => entry(i + 1))
      ..sessionsMarkdownPath = '/test/Context/context.md'
      ..autosaveEnabled = false;
    addTearDown(app.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: const RepaintBoundary(key: snapshot, child: ContextView()),
      ),
    );
    await tester.pumpAndSettle();
    return app;
  }

  Future<void> capture(WidgetTester tester, String name) async {
    final destination = Platform.environment['CONTEXT_UI_EVIDENCE_DIR'];
    if (destination == null) return;
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(snapshot),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage();
      try {
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        await File(
          '$destination/$name.png',
        ).writeAsBytes(data!.buffer.asUint8List());
      } finally {
        image.dispose();
      }
    });
  }

  testWidgets('all header controls share one line, with groups as a badge', (
    tester,
  ) async {
    await mount(tester, items: grouped(), width: 400);
    final row = find.byKey(const ValueKey('sessions-header-row'));
    final title = find.descendant(of: row, matching: find.text('Sessions'));
    final count = find.byKey(const ValueKey('sessions-count'));
    final save = find.byKey(const ValueKey('sessions-save'));
    final filter = find.byKey(const ValueKey('context-filter'));
    final y = tester.getCenter(title).dy;
    for (final control in [count, save, filter]) {
      expect(tester.getCenter(control).dy, closeTo(y, 1));
    }
    expect(
      tester.getRect(filter).left,
      greaterThan(tester.getRect(save).right),
    );
    expect(find.text('Groups'), findsNothing);
    expect(
      tester
          .widget<Badge>(find.byKey(const ValueKey('sessions-group-badge')))
          .isLabelVisible,
      isTrue,
    );
    expect(find.text('Saved'), findsOneWidget);
    expect(find.text('Save'), findsNothing);
    expect(tester.takeException(), isNull);
    await capture(tester, 'sessions-compact-400');
  });

  Finder session(int number) =>
      find.byKey(ValueKey('session-codex-${entry(number).commandId}'));

  ScrollController controller(WidgetTester tester, String key) =>
      tester.widget<CustomScrollView>(find.byKey(ValueKey(key))).controller!;

  Future<void> wheel(WidgetTester tester, Offset point, double delta) async {
    await tester.sendEventToBinding(
      PointerScrollEvent(position: point, scrollDelta: Offset(0, delta)),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'ten sessions fit initially; expand removes viewport; remount collapses',
    (tester) async {
      final app = await mount(tester);
      expect(
        tester
            .widget<SliverReorderableList>(find.byType(SliverReorderableList))
            .itemCount,
        21,
      );
      expect(session(11).hitTestable(), findsNothing);
      expect(
        tester.getSize(find.byKey(const ValueKey('sessions-scroll'))).height,
        440,
      );
      final expand = find.byKey(const ValueKey('sessions-expand'));
      await tester.ensureVisible(expand);
      await tester.tap(expand);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('sessions-scroll')), findsNothing);
      expect(
        tester
            .widget<SliverReorderableList>(find.byType(SliverReorderableList))
            .itemCount,
        21,
      );
      expect(app.items.length, 21);
      expect(app.dirty, isFalse);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        ChangeNotifierProvider.value(value: app, child: const ContextView()),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<SliverReorderableList>(find.byType(SliverReorderableList))
            .itemCount,
        21,
      );
      expect(session(11).hitTestable(), findsNothing);
      expect(controller(tester, 'sessions-scroll').offset, 0);
      expect(find.text('Show all 21'), findsOneWidget);
    },
  );

  testWidgets(
    'collapse returns to ten without hiding or altering the header or data',
    (tester) async {
      final app = await mount(tester);
      final expand = find.byKey(const ValueKey('sessions-expand'));
      await tester.ensureVisible(expand);
      await tester.tap(expand);
      await tester.pumpAndSettle();
      await tester.ensureVisible(expand);
      await tester.tap(expand);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<SliverReorderableList>(find.byType(SliverReorderableList))
            .itemCount,
        21,
      );
      expect(session(11).hitTestable(), findsNothing);
      expect(controller(tester, 'sessions-scroll').offset, 0);
      expect(
        find.byKey(const ValueKey('sessions-header-row')).hitTestable(),
        findsOneWidget,
      );
      expect(app.items.length, 21);
      expect(app.dirty, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'search finds hidden sessions and clearing restores the compact list',
    (tester) async {
      final app = await mount(tester);
      final filter = find.byKey(const ValueKey('context-filter'));
      await tester.enterText(filter, 'Entry 21');
      await tester.pumpAndSettle();
      expect(
        find.byKey(ValueKey('session-codex-${entry(21).commandId}')),
        findsOneWidget,
      );
      expect(find.text('1/21'), findsOneWidget);
      expect(find.byKey(const ValueKey('sessions-expand')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('clear-context-filter')));
      await tester.pumpAndSettle();
      expect(app.filterQuery, isEmpty);
      expect(
        tester
            .widget<SliverReorderableList>(find.byType(SliverReorderableList))
            .itemCount,
        21,
      );
      expect(session(11).hitTestable(), findsNothing);
      expect(find.text('Entry 21'), findsNothing);
    },
  );

  testWidgets(
    'wheel over row text, blank space and controls scrolls both ways',
    (tester) async {
      final app = await mount(tester);
      final inner = controller(tester, 'sessions-scroll');
      final outer = controller(tester, 'context-scroll');
      final row = session(4);
      final rect = tester.getRect(row);
      final points = [
        tester.getCenter(
          find.descendant(of: row, matching: find.text('Entry 4')),
        ),
        tester.getCenter(find.descendant(of: row, matching: find.text('0004'))),
        Offset(rect.right - 180, rect.center.dy),
        for (final icon in [
          Icons.call_split_rounded,
          Icons.delete_outline_rounded,
          Icons.drag_indicator_rounded,
        ])
          tester.getCenter(
            find.descendant(of: row, matching: find.byIcon(icon)),
          ),
      ];
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer();
      addTearDown(mouse.removePointer);
      for (final point in points) {
        await mouse.moveTo(point);
        await tester.pump(const Duration(milliseconds: 180));
        await wheel(tester, point, 120);
        expect(inner.offset, 120);
        expect(outer.offset, 0);
        expect(session(11).hitTestable(), findsOneWidget);
        await wheel(tester, point, -120);
        expect(inner.offset, 0);
        expect(session(11).hitTestable(), findsNothing);
      }
      expect(app.dirty, isFalse);
      expect(app.items.length, 21);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('wheel at list bounds continues through the surrounding pane', (
    tester,
  ) async {
    await mount(tester, height: 650);
    final inner = controller(tester, 'sessions-scroll');
    final outer = controller(tester, 'context-scroll');
    final point = tester.getCenter(session(4));
    expect(outer.position.maxScrollExtent, greaterThan(0));
    await wheel(tester, point, 10000);
    expect(inner.offset, inner.position.maxScrollExtent);
    expect(outer.offset, 0);
    await wheel(tester, point, 100);
    expect(outer.offset, 100);
    await wheel(tester, point, -10000);
    expect(inner.offset, 0);
    expect(outer.offset, 100);
    await wheel(tester, point, -100);
    expect(outer.offset, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('expanded sessions retain normal outer wheel scrolling', (
    tester,
  ) async {
    await mount(tester, height: 1000);
    final expand = find.byKey(const ValueKey('sessions-expand'));
    await tester.ensureVisible(expand);
    await tester.tap(expand);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('sessions-scroll')), findsNothing);
    final outer = controller(tester, 'context-scroll');
    outer.jumpTo(0);
    await tester.pumpAndSettle();
    final point = tester.getCenter(session(4));
    await wheel(tester, point, 120);
    expect(outer.offset, 120);
    await wheel(tester, point, -120);
    expect(outer.offset, 0);
  });

  testWidgets(
    'scrolled groups retain their real ending and original row indices',
    (tester) async {
      final app = await mount(tester, items: grouped());
      final inner = controller(tester, 'sessions-scroll');
      expect(session(11).hitTestable(), findsNothing);
      await wheel(tester, tester.getCenter(session(4)), 10000);
      expect(inner.offset, inner.position.maxScrollExtent);
      expect(session(15).hitTestable(), findsOneWidget);
      expect(
        find.byKey(const ValueKey('group-end-one')).hitTestable(),
        findsOneWidget,
      );
      final list = tester.widget<SliverReorderableList>(
        find.byType(SliverReorderableList),
      );
      list.onReorderItem!(15, 0);
      await tester.pumpAndSettle();
      expect(app.items.first.commandId, entry(15).commandId);
      expect(app.groupForItem(0), isNull);
      expect(app.memberIndicesForGroup(1).length, 14);
      expect(app.items.where((item) => item.isSession).length, 16);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('filtered matches scroll fully and clearing restores the start', (
    tester,
  ) async {
    final app = await mount(tester);
    final filter = find.byKey(const ValueKey('context-filter'));
    await tester.enterText(filter, 'Entry');
    await tester.pumpAndSettle();
    await wheel(tester, tester.getCenter(session(4)), 10000);
    expect(session(21).hitTestable(), findsOneWidget);
    await tester.enterText(filter, 'Entry 21');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('sessions-scroll')), findsNothing);
    expect(session(21).hitTestable(), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('clear-context-filter')));
    await tester.pumpAndSettle();
    expect(controller(tester, 'sessions-scroll').offset, 0);
    expect(session(1).hitTestable(), findsOneWidget);
    expect(app.dirty, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'single save button changes label and performs the real save action',
    (tester) async {
      final requests = <Uint64>[];
      final app = await mount(tester, sender: requests.add);
      final button = find.byKey(const ValueKey('sessions-save'));
      expect(tester.widget<FilledButton>(button).onPressed, isNull);
      app.renameSession(0, 'Changed');
      await tester.pumpAndSettle();
      expect(find.text('Save'), findsOneWidget);
      expect(find.text('Saved'), findsNothing);
      expect(tester.widget<FilledButton>(button).onPressed, isNotNull);
      await tester.tap(button);
      await tester.pump();
      expect(requests.length, 1);
      assignRustSignal['OpFinished']!(
        OpFinished(requestId: requests.single, ok: true).bincodeSerialize(),
        Uint8List(0),
      );
      await tester.pumpAndSettle();
      expect(app.dirty, isFalse);
      expect(find.text('Saved'), findsOneWidget);
      expect(find.text('Save'), findsNothing);
      expect(tester.widget<FilledButton>(button).onPressed, isNull);
    },
  );
}
