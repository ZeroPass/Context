import 'package:context/ui/widgets/file_location_button.dart';
import 'package:context/ui/widgets/passive_tooltip.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'tooltip escapes pane clipping, stays inside the window and passes clicks',
    (tester) async {
      var clicks = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  height: 90,
                  child: GestureDetector(
                    onTap: () => clicks++,
                    child: const ColoredBox(color: Colors.red),
                  ),
                ),
                Positioned(
                  top: 92,
                  right: 0,
                  width: 44,
                  height: 44,
                  child: ClipRect(
                    child: PassiveTooltip(
                      message: 'Floating tip',
                      child: IconButton(
                        onPressed: () {},
                        icon: const Icon(Icons.info_outline),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(10, 500));
      await mouse.moveTo(tester.getCenter(find.byIcon(Icons.info_outline)));
      await tester.pump(const Duration(milliseconds: 150));
      final label = find.text('Floating tip');
      expect(label, findsOneWidget);
      final bounds = tester.getRect(label);
      expect(bounds.bottom, lessThan(90));
      expect(bounds.right, lessThanOrEqualTo(tester.view.physicalSize.width));
      expect(bounds.left, greaterThanOrEqualTo(0));
      // Touch taps must pass through even while the mouse keeps the tip visible.
      await tester.tapAt(bounds.center);
      expect(clicks, 1);
      await mouse.moveTo(bounds.center);
      await tester.pump();
      expect(label, findsNothing);
      expect(tester.takeException(), isNull);
      await mouse.removePointer();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'top-edge tooltip goes below and disappears on exit or disposal',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: PassiveTooltip(
                message: 'Top edge tip',
                preferBelow: true,
                child: IconButton(
                  onPressed: () {},
                  icon: const Icon(Icons.info_outline),
                ),
              ),
            ),
          ),
        ),
      );
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(500, 500));
      final button = find.byIcon(Icons.info_outline);
      await mouse.moveTo(tester.getCenter(button));
      await tester.pump(const Duration(milliseconds: 150));
      final label = find.text('Top edge tip');
      expect(label, findsOneWidget);
      expect(
        tester.getRect(label).top,
        greaterThan(tester.getRect(button).bottom),
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(label, findsNothing);
      expect(tester.takeException(), isNull);
      await mouse.removePointer();
    },
  );

  testWidgets(
    'folder left click reveals, right click menu opens in default app',
    (tester) async {
      var revealed = 0;
      var opened = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: FileLocationButton(
                onReveal: () => revealed++,
                onOpenExternal: () => opened++,
              ),
            ),
          ),
        ),
      );
      final button = find.byIcon(Icons.folder_open_rounded);
      expect(find.text('Open in default app'), findsNothing);
      expect(find.byIcon(Icons.open_in_new_rounded), findsNothing);
      await tester.tap(button);
      expect(revealed, 1);
      expect(opened, 0);
      final mouse = await tester.startGesture(
        tester.getCenter(button),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await mouse.up();
      await tester.pumpAndSettle();
      expect(find.text('Open in default app'), findsOneWidget);
      expect(opened, 0);
      await tester.tap(find.text('Open in default app'));
      await tester.pumpAndSettle();
      expect(opened, 1);
      expect(revealed, 1);
      expect(tester.takeException(), isNull);
    },
  );
}
