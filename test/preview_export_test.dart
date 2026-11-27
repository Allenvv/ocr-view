import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pm25_capture/capture.dart';
import 'package:pm25_capture/main.dart';
import 'package:pm25_capture/domain.dart';
import 'package:pm25_capture/lab_style.dart';
import 'smoke_widget_test.dart' show FixtureStore;

class PreviewStore extends FixtureStore {
  @override
  Future<List<DataRowMap>> batches() async {
    final entries = await super.batches();
    return [
      entries.first,
      await batchById('preview-history'),
      ...entries.skip(1),
    ];
  }
}

void main() {
  const export = bool.fromEnvironment('EXPORT_PM25_PREVIEWS');
  testWidgets(
    'export final effect using Flutter widgets and a simulated camera',
    skip: !export,
    (tester) async {
      final sdk = Platform.environment['PM25_FLUTTER']!;
      final sys = Platform.environment['WINDIR']!;
      Future<void> load(String family, String path) async {
        final loader = FontLoader(family)
          ..addFont(
            Future.value(ByteData.sublistView(File(path).readAsBytesSync())),
          );
        await loader.load();
      }

      await tester.runAsync(() async {
        await load('PreviewCJK', '$sys/Fonts/msyh.ttc');
        await load(
          'MaterialIcons',
          '$sdk/bin/cache/artifacts/material_fonts/materialicons-regular.otf',
        );
      });
      final fixture = PreviewStore();
      final beginning = DateTime.now()
          .subtract(const Duration(seconds: 27))
          .millisecondsSinceEpoch;
      await fixture.newBatch('preview-history', '离线演示批次', '实验员', '仅用于界面预览');
      await fixture.begin(
        'preview-history',
        const [
          Roi('DEV01', .11, .28, .37, .58),
          Roi('DEV02', .58, .28, .84, .58),
        ],
        {'mode': 'demo'},
      );
      await fixture.customStatement('UPDATE batches SET started=? WHERE id=?', [
        beginning,
        'preview-history',
      ]);
      for (var i = 0; i < 26; i++) {
        final stamp = beginning + i * 1000;
        await fixture.writeRound('preview-history', stamp, stamp, 1000, [
          Reading(
            'DEV01',
            '${[23, 26, 24, 33, 29, 30, 26][i % 7]}',
            .96,
          ).classify(const CaptureConfig()),
          Reading(
            'DEV02',
            '${[38, 36, 42, 40, 46, 41, 39, 38, 36][i % 9]}',
            .93,
          ).classify(const CaptureConfig()),
        ]);
      }
      await fixture.stop('preview-history', '离线演示完成');
      addTearDown(fixture.close);
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        NativeSource.channel,
        (call) async => call.method == 'close'
            ? null
            : {
                'validated': false,
                'ready': false,
                'framesReady': false,
                'storageReady': true,
                'message': '相机预览未连接（效果预览）',
              },
      );
      addTearDown(
        () => messenger.setMockMethodCallHandler(NativeSource.channel, null),
      );
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(392, 800);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final frame = GlobalKey();
      Future<void> save(String name) async {
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          final image =
              await (frame.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary)
                  .toImage(pixelRatio: 2);
          final bytes = (await image.toByteData(
            format: ui.ImageByteFormat.png,
          ))!;
          final output = Directory(
            Platform.environment['PM25_PREVIEW_DIR'] ?? 'artifacts',
          )..createSync(recursive: true);
          File(
            '${output.path}/$name.png',
          ).writeAsBytesSync(bytes.buffer.asUint8List());
          image.dispose();
        });
      }

      await tester.pumpWidget(
        RepaintBoundary(
          key: frame,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: LabStyle.theme(fontFamily: 'PreviewCJK'),
            home: Home(fixture),
          ),
        ),
      );
      await save('PM25-v0.3.0-home');
      await tester.tap(find.text('测试项目'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('真实采集未就绪 · 缺少验收'));
      await save('PM25-v0.3.0-capture-status');
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('进入离线演示'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('使用演示 ROI'));
      await save('PM25-v0.3.0-roi-portrait');
      tester.view.physicalSize = const Size(800, 392);
      await save('PM25-v0.3.0-roi-landscape');
      tester.view.physicalSize = const Size(392, 870);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('离线演示批次'));
      await tester.tap(find.text('离线演示批次'));
      await save('PM25-v0.3.0-monitor');
      expect(find.text('浓度趋势'), findsOneWidget);
      expect(find.text('52'), findsOneWidget);
      await tester.tap(find.byTooltip('全屏查看趋势'));
      await save('PM25-fullscreen-trend');
      expect(find.byTooltip('退出全屏'), findsOneWidget);
      expect(find.text('DEV01'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('52'), findsOneWidget);
      await tester.ensureVisible(find.text('记录表'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('记录表'));
      await tester.pumpAndSettle();
      expect(find.text('浓度趋势'), findsNothing);
      await tester.tap(find.text('趋势图'));
      await tester.pumpAndSettle();
      expect(find.text('浓度趋势'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
