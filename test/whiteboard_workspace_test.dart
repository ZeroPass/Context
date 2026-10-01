import 'dart:ui' show PointerDeviceKind;

import 'package:context/ui/widgets/whiteboard_workspace.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class ProbePane extends StatefulWidget {
  const ProbePane({super.key, required this.label});
  final String label;
  @override
  State<ProbePane> createState() => ProbePaneState();
}

class ProbePaneState extends State<ProbePane> {
  final controller = ScrollController();
  int count = 0;
  void increment() => setState(() => count++);
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scrollbar(
    controller: controller,
    child: ListView(
      key: ValueKey('${widget.label}-scroll'),
      controller: controller,
      children: [
        Text('${widget.label}: $count'),
        for (var index = 0; index < 40; index++)
          SizedBox(height: 48, child: Text('${widget.label} row $index')),
      ],
    ),
  );
}

void main() {
  Future<void> setSize(WidgetTester tester, double width) async {
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1;
    await tester.pumpAndSettle();
  }

  Future<void> mount(
    WidgetTester tester, {
    required Widget contextPane,
    required Widget whiteboardPane,
    required bool Function() visible,
    required void Function(StateSetter) onSetter,
  }) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              onSetter(setState);
              return WhiteboardWorkspace(
                visible: visible(),
                contextPane: contextPane,
                whiteboardPane: whiteboardPane,
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'default split gives Whiteboard two thirds and respects minimum widths',
    (tester) async {
      await mount(
        tester,
        contextPane: const Text('Left'),
        whiteboardPane: const Text('Right'),
        visible: () => true,
        onSetter: (_) {},
      );
      final left = find.byKey(const ValueKey('context-pane'));
      final right = find.byKey(const ValueKey('whiteboard-pane'));
      expect(tester.getSize(left).width, closeTo((1400 - 18) / 3, 0.01));
      expect(tester.getSize(right).width, closeTo((1400 - 18) * 2 / 3, 0.01));
      await setSize(tester, 1000);
      expect(tester.getSize(left).width, 400);
      expect(tester.getSize(right).width, 582);
      await setSize(tester, 678);
      expect(tester.getSize(left).width, 400);
      expect(tester.getSize(right).width, 260);
      expect(find.byType(PageView), findsNothing);
      await setSize(tester, 677);
      expect(find.byType(PageView), findsOneWidget);
      expect(find.byKey(const ValueKey('whiteboard-divider')), findsNothing);
      expect(tester.getSize(right).width, 677);
      await tester.tap(find.byKey(const ValueKey('workspace-page-0')));
      await tester.pumpAndSettle();
      expect(tester.getSize(left).width, 677);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'panes keep state, scroll, and custom split through paging and resize',
    (tester) async {
      final leftKey = GlobalKey<ProbePaneState>();
      final rightKey = GlobalKey<ProbePaneState>();
      var visible = false;
      late StateSetter update;
      await mount(
        tester,
        contextPane: ProbePane(key: leftKey, label: 'Context'),
        whiteboardPane: ProbePane(key: rightKey, label: 'Whiteboard'),
        visible: () => visible,
        onSetter: (setter) => update = setter,
      );
      final leftState = leftKey.currentState!;
      leftState.increment();
      leftState.controller.jumpTo(100);
      update(() => visible = true);
      await tester.pumpAndSettle();
      final rightState = rightKey.currentState!;
      rightState.increment();
      rightState.controller.jumpTo(120);
      await tester.drag(
        find.byKey(const ValueKey('whiteboard-divider')),
        const Offset(120, 0),
      );
      await tester.pumpAndSettle();
      final customWidth = tester
          .getSize(find.byKey(const ValueKey('context-pane')))
          .width;
      await setSize(tester, 650);
      final pages = find.byType(PageView);
      expect(tester.widget<PageView>(pages).controller!.page, 1);
      expect(leftKey.currentState, same(leftState));
      expect(rightKey.currentState, same(rightState));
      expect(leftState.controller.offset, 100);
      expect(rightState.controller.offset, 120);
      expect(leftState.count, 1);
      expect(rightState.count, 1);
      await tester.drag(pages, const Offset(500, 0));
      await tester.pumpAndSettle();
      expect(tester.widget<PageView>(pages).controller!.page, 0);
      await tester.drag(
        find.byKey(const ValueKey('Context-scroll')),
        const Offset(0, -120),
      );
      await tester.pumpAndSettle();
      final leftOffset = leftState.controller.offset;
      expect(leftOffset, greaterThan(100));
      expect(tester.widget<PageView>(pages).controller!.page, 0);
      await setSize(tester, 1400);
      expect(leftKey.currentState, same(leftState));
      expect(rightKey.currentState, same(rightState));
      expect(leftState.controller.offset, leftOffset);
      expect(rightState.controller.offset, 120);
      expect(
        tester.getSize(find.byKey(const ValueKey('context-pane'))).width,
        closeTo(customWidth, 0.01),
      );
      await setSize(tester, 650);
      expect(tester.widget<PageView>(pages).controller!.page, 0);
      update(() => visible = false);
      await tester.pumpAndSettle();
      expect(leftKey.currentState, same(leftState));
      expect(leftState.controller.offset, leftOffset);
      expect(rightKey.currentState, isNull);
      update(() => visible = true);
      await tester.pumpAndSettle();
      expect(tester.widget<PageView>(pages).controller!.page, 1);
      expect(leftKey.currentState, same(leftState));
      expect(leftState.controller.offset, leftOffset);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('narrow screens offer page buttons and mouse swipes', (
    tester,
  ) async {
    await mount(
      tester,
      contextPane: const ProbePane(label: 'Context'),
      whiteboardPane: const ProbePane(label: 'Whiteboard'),
      visible: () => true,
      onSetter: (_) {},
    );
    await setSize(tester, 360);
    final pages = find.byType(PageView);
    expect(tester.widget<PageView>(pages).controller!.page, 1);
    await tester.tap(find.byKey(const ValueKey('workspace-page-0')));
    await tester.pumpAndSettle();
    expect(tester.widget<PageView>(pages).controller!.page, 0);
    final mouse = await tester.startGesture(
      tester.getCenter(pages),
      kind: PointerDeviceKind.mouse,
    );
    await mouse.moveBy(const Offset(-260, 0));
    await mouse.up();
    await tester.pumpAndSettle();
    expect(tester.widget<PageView>(pages).controller!.page, 1);
    await tester.tap(find.byKey(const ValueKey('workspace-page-0')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('workspace-page-1')));
    await tester.pumpAndSettle();
    expect(tester.widget<PageView>(pages).controller!.page, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
