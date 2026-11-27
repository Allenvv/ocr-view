import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pm25_capture/capture.dart';
import 'package:pm25_capture/domain.dart';
import 'package:pm25_capture/store.dart';

class SlowSource extends DemoSource {
  int calls = 0;
  int concurrent = 0;
  int maxConcurrent = 0;
  @override
  Future<FrameReadings> sample(List<Roi> rois, int budgetMs) async {
    calls++;
    concurrent++;
    if (concurrent > maxConcurrent) maxConcurrent = concurrent;
    await Future<void>.delayed(const Duration(milliseconds: 260));
    concurrent--;
    return super.sample(rois, budgetMs);
  }
}

void main() {
  test(
    'unverified camera, periods, and capacity cannot start a batch',
    () async {
      final demo = await DemoSource().state();
      const rois = [Roi('DEV01', .1, .1, .4, .4)];
      expect(demo.allows(rois, 1000), isTrue);
      expect(demo.allows(rois, 4000), isFalse);
      expect(demo.allows(List.filled(6, rois.single), 1000), isTrue);
      final native = CameraState({
        ...demo.data,
        'mode': 'native',
        'modelAvailable': true,
        'roiLimit': 5,
      });
      expect(native.allows(rois, 1000), isTrue);
      expect(native.allows(List.filled(6, rois.single), 1000), isFalse);
      final unvalidated = CameraState({...demo.data, 'validated': false});
      expect(unvalidated.allows(rois, 1000), isFalse);
    },
  );

  test('production profile is approved for an exact ROI count and period', () {
    final camera = const CameraState({
      'validated': true,
      'ready': true,
      'framesReady': true,
      'modelAvailable': true,
      'storageReady': true,
      'profiles': {'1000:3': 3, '2000:8': 8},
      'periods': [1000, 2000],
    });
    List<Roi> rois(int count) =>
        List.generate(count, (i) => Roi('DEV$i', .1, .1, .4, .4));
    expect(camera.allows(rois(3), 1000), isTrue);
    expect(camera.allows(rois(8), 2000), isTrue);
    expect(camera.allows(rois(8), 1000), isFalse);
    expect(camera.allows(rois(1), 1000), isFalse);
  });

  test(
    'offline demo writes every ROI beyond five to SQLite with demo provenance',
    () async {
      final store = Store(NativeDatabase.memory());
      addTearDown(store.close);
      final rois = List.generate(8, (i) => Roi('DEV$i', .1, .1, .4, .4));
      await store.newBatch('demo-round', 'test', 'tester', '');
      await store.begin('demo-round', rois, {'mode': 'demo'});
      final updated = Completer<void>();
      final loop = CaptureLoop(
        store,
        'demo-round',
        rois,
        const CaptureConfig(),
        DemoSource(),
        () async {
          if (!updated.isCompleted) updated.complete();
        },
        (error) async {
          if (!updated.isCompleted) updated.completeError(StateError(error));
        },
      );
      addTearDown(loop.pause);
      loop.resume();
      await updated.future.timeout(const Duration(seconds: 4));
      await loop.pause();
      final records = await store.exportPage('demo-round', 0);
      expect(
        records.map((r) => r['device']).toSet(),
        rois.map((r) => r.device).toSet(),
      );
      expect((await store.batchById('demo-round'))['config'], contains('demo'));
    },
  );

  test(
    'overdue results are dropped and missed slots are not replayed',
    () async {
      final store = Store(NativeDatabase.memory());
      addTearDown(store.close);
      const rois = [Roi('DEV01', .1, .1, .4, .4)];
      final source = SlowSource();
      final updated = Completer<void>();
      await store.newBatch('test', 'project', 'tester', '');
      await store.begin('test', rois, {'mode': 'demo'});
      final capture = CaptureLoop(
        store,
        'test',
        rois,
        const CaptureConfig(period: 100),
        source,
        () async {
          if (!updated.isCompleted) updated.complete();
        },
        (error) {
          if (!updated.isCompleted) updated.completeError(StateError(error));
        },
      );
      addTearDown(capture.pause);
      capture.resume();
      await updated.future.timeout(const Duration(seconds: 4));
      await capture.pause();
      expect(source.calls, 1);
      expect(source.maxConcurrent, 1);
      final stats = await store.stats('test');
      expect(stats['total'], 0);
      expect(stats['dropped'], greaterThanOrEqualTo(3));
    },
  );
}
