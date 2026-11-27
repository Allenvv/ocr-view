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
  for (final status in [1, 2]) {
    testWidgets('batch status $status has one app bar menu', (tester) async {
      final store = FixtureStore();
      addTearDown(store.close);
      await tester.pumpWidget(
        MaterialApp(
          home: BatchPage(store, {
            'id': 'MENU',
            'project': '菜单测试',
            'status': status,
            'rois': '[]',
            'config': '{}',
          }),
        ),
      );
      await tester.pump();
      final menu = find.byTooltip('更多');
      expect(menu, findsOneWidget);
      expect(
        find.ancestor(of: menu, matching: find.byType(AppBar)),
        findsOneWidget,
      );
      await tester.tap(menu);
      await tester.pumpAndSettle();
      expect(find.text('导出 CSV'), findsOneWidget);
      expect(find.text('导出失败日志'), findsOneWidget);
      expect(find.text('日志'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });
  }

  testWidgets('creation dialog has only one field and opens the ROI editor', (
    tester,
  ) async {
    final store = FixtureStore();
    addTearDown(store.close);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      NativeSource.channel,
      (call) async => null,
    );
    addTearDown(
      () => messenger.setMockMethodCallHandler(NativeSource.channel, null),
    );
    await tester.pumpWidget(CaptureApp(store));
    await tester.pumpAndSettle();
    await tester.tap(find.text('建立测试'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'ONLY-ID');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.byType(RoiCanvas), findsOneWidget);
    expect(find.byTooltip('相机测试'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'unverified native capture stays disabled; no production demo entry exists',
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
      final newBatch = find.text('建立测试');
      expect(
        tester.getCenter(find.widgetWithText(FilledButton, '建立测试')).dx,
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
      expect(find.text('开始采集'), findsNothing);
      await tester.tap(find.text('查看启动条件'));
      await tester.pumpAndSettle();
      expect(find.textContaining('内置离线识别模型不可用'), findsOneWidget);
      expect(find.textContaining('AF/AE 锁定和正式识别链路'), findsOneWidget);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      expect(find.text('进入离线演示'), findsNothing);
      final portrait = tester.getSize(find.byType(RoiCanvas));
      expect(portrait.height, greaterThan(550));
      tester.view.physicalSize = const Size(740, 360);
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byType(RoiCanvas)).width, greaterThan(680));
      expect(find.text('查看启动条件').hitTestable(), findsOneWidget);
      expect(find.byTooltip('加载模板').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
