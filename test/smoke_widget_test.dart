import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pm25_capture/visuals.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pm25_capture/capture.dart';
import 'package:pm25_capture/domain.dart';
import 'package:pm25_capture/main.dart';
import 'package:pm25_capture/store.dart';

class FixtureStore extends Store {
  FixtureStore() : super(NativeDatabase.memory());
  @override
  Future<void> recover() async {}
  @override
  Future<CaptureConfig> loadConfig() async => const CaptureConfig();
  @override
  Future<List<DataRowMap>> batches() async => List.generate(
    16,
    (i) => {
      'id': 'B$i',
      'project': i == 0 ? '测试项目' : '批次 $i',
      'tester': '实验员',
      'created': DateTime(2026, 11, 27, 9, 30).millisecondsSinceEpoch,
      'status': 0,
      'rois': '[]',
      'config': '{}',
    },
  );
}

void main() {
  testWidgets(
    'unverified native capture stays disabled; demo requires a choice',
    (tester) async {
      final store = FixtureStore();
      addTearDown(store.close);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(360, 740);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(NativeSource.channel, (
        MethodCall call,
      ) async {
        return call.method == 'close'
            ? null
            : {'validated': false, 'message': '相机未验收'};
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(NativeSource.channel, null),
      );
      await tester.pumpWidget(CaptureApp(store));
      await tester.pumpAndSettle();
      final newBatch = find.text('新建批次');
      expect(
        tester.getCenter(find.widgetWithText(FilledButton, '新建批次')).dx,
        180,
      );
      final list = find.byType(ListView);
      await tester.dragUntilVisible(
        find.text('批次 15'),
        list,
        const Offset(0, -280),
      );
      expect(
        tester.getBottomLeft(find.text('批次 15')).dy,
        lessThan(tester.getTopLeft(newBatch).dy),
      );
      await tester.dragUntilVisible(
        find.text('测试项目'),
        list,
        const Offset(0, 280),
      );
      await tester.ensureVisible(find.text('测试项目'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('测试项目'));
      await tester.pumpAndSettle();
      final native = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, '开始采集'),
      );
      expect(native.onPressed, isNull);
      await tester.tap(find.text('真实采集未就绪 · 缺少验收'));
      await tester.pumpAndSettle();
      expect(find.textContaining('未安装可用的 REC'), findsOneWidget);
      expect(find.textContaining('AF/AE 锁定和正式识别链路'), findsOneWidget);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('进入离线演示'));
      await tester.pumpAndSettle();
      expect(find.textContaining('所有读数均为合成数据'), findsOneWidget);
      await tester.ensureVisible(find.text('使用演示 ROI'));
      await tester.tap(find.text('使用演示 ROI'));
      await tester.pumpAndSettle();
      final demo = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, '开始演示'),
      );
      expect(demo.onPressed, isNotNull);
      final portrait = tester.getSize(find.byType(RoiCanvas));
      expect(portrait.height, greaterThan(550));
      tester.view.physicalSize = const Size(740, 360);
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byType(RoiCanvas)).width, greaterThan(680));
      expect(find.text('开始演示').hitTestable(), findsOneWidget);
      expect(find.byTooltip('加载模板').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
