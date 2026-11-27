import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pm25_capture/domain.dart';
import 'package:pm25_capture/visuals.dart';

void main() {
  for (final turns in [0, 1, 2, 3]) {
    testWidgets(
      'draw, move and resize map to the same viewport at $turns turns',
      (tester) async {
        final canonical = <Roi>[];
        Roi? last;
        var selected = -1;
        await tester.pumpWidget(
          MaterialApp(
            home: Center(
              child: SizedBox(
                width: 340,
                height: 340,
                child: StatefulBuilder(
                  builder: (_, setState) => RoiCanvas(
                    rois: canonical,
                    selected: selected,
                    texture: null,
                    aspect: turns.isEven ? .65 : 1 / .65,
                    demo: true,
                    turns: turns,
                    onSelect: (i) => setState(() => selected = i),
                    onChange: (i, roi) => setState(() {
                      last = roi;
                      if (i < 0) {
                        canonical.add(roi);
                        selected = canonical.length - 1;
                      } else {
                        canonical[i] = roi;
                      }
                    }),
                  ),
                ),
              ),
            ),
          ),
        );
        final rect = tester.getRect(
          find.descendant(
            of: find.byType(RoiCanvas),
            matching: find.byType(GestureDetector),
          ),
        );
        Offset point(double x, double y) =>
            Offset(rect.left + x * rect.width, rect.top + y * rect.height);
        Future<void> drag(double x, double y, double endX, double endY) async {
          final gesture = await tester.startGesture(point(x, y));
          await gesture.moveTo(point((x + endX) / 2, (y + endY) / 2));
          await tester.pump();
          await gesture.moveTo(point(endX, endY));
          await tester.pump();
          await gesture.up();
          await tester.pump();
        }

        void check(double l, double t, double r, double b) {
          final expected = rotateRoi(Roi(last!.device, l, t, r, b), -turns);
          expect(last!.l, closeTo(expected.l, .003));
          expect(last!.t, closeTo(expected.t, .003));
          expect(last!.r, closeTo(expected.r, .003));
          expect(last!.b, closeTo(expected.b, .003));
        }

        await drag(.15, .15, .45, .45);
        check(.15, .15, .45, .45);
        await drag(.30, .30, .43, .42);
        check(.28, .27, .58, .57);
        await drag(.58, .57, .78, .76);
        check(.28, .27, .78, .76);
        expect(canonical, hasLength(1));
      },
    );
  }

  testWidgets('focus taps use the inverse viewport transform', (tester) async {
    Offset? actual;
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 320,
            height: 360,
            child: RoiCanvas(
              rois: const [],
              selected: -1,
              texture: null,
              aspect: 16 / 9,
              turns: 1,
              demo: false,
              onSelect: (_) => fail('ROI selection while adjusting'),
              onFocus: (point) => actual = point,
            ),
          ),
        ),
      ),
    );
    final area = tester.getRect(
      find.descendant(
        of: find.byType(RoiCanvas),
        matching: find.byType(GestureDetector),
      ),
    );
    await tester.tapAt(
      Offset(area.left + area.width * .2, area.top + area.height * .3),
    );
    expect(actual!.dx, closeTo(.3, .001));
    expect(actual!.dy, closeTo(.8, .001));
  });

  testWidgets('live overlays never substitute a past reading on failure', (
    tester,
  ) async {
    Future<void> show(Map<String, String> labels) => tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 320,
            height: 360,
            child: RoiCanvas(
              rois: const [Roi('DEV01', .2, .3, .5, .5)],
              selected: -1,
              texture: null,
              aspect: 9 / 16,
              demo: false,
              onSelect: (_) {},
              liveLabels: labels,
            ),
          ),
        ),
      ),
    );
    await show({'DEV01': '23.1'});
    expect(find.text('DEV01 · 23.1'), findsOneWidget);
    await show({'DEV01': '识别失败'});
    expect(find.text('DEV01 · 识别失败'), findsOneWidget);
    expect(find.text('DEV01 · 23.1'), findsNothing);
  });

  testWidgets('editor draws a seventh ROI', (tester) async {
    final rois = List.generate(
      6,
      (i) => Roi('Device$i', .07 + i * .14, .12, .14 + i * .14, .28),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 320,
            height: 440,
            child: RoiCanvas(
              rois: rois,
              selected: -1,
              texture: null,
              aspect: 320 / 440,
              demo: true,
              onSelect: (_) {},
              onChange: (i, r) {
                expect(i, -1);
                rois.add(r);
              },
            ),
          ),
        ),
      ),
    );
    final rect = tester.getRect(
      find.descendant(
        of: find.byType(RoiCanvas),
        matching: find.byType(GestureDetector),
      ),
    );
    await tester.dragFrom(
      rect.topLeft + const Offset(45, 230),
      const Offset(100, 100),
    );
    expect(rois, hasLength(7));
  });
}
