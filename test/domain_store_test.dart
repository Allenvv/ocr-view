import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pm25_capture/domain.dart';
import 'package:pm25_capture/store.dart';

void main() {
  const settings = CaptureConfig();
  const roi = Roi('DEV01', .1, .1, .5, .5);
  test('ROI limits, normalization and unique device IDs', () {
    expect(validRois([]), false);
    expect(validRois([roi]), true);
    expect(validRois([roi, roi.rename('dev01')]), false);
    expect(validRois([const Roi('a', 0, 0, .01, .5)]), false);
    expect(validRois(List.generate(12, (i) => roi.rename('$i'))), true);
  });
  test('templates round trip more than five ROIs', () async {
    final store = Store(NativeDatabase.memory());
    addTearDown(store.close);
    final many = List.generate(12, (i) => roi.rename('D$i'));
    await store.saveTemplate('many', many);
    final row = (await store.templates()).single;
    expect(
      Store.decodeRois(row['rois']).map((r) => r.toJson()),
      many.map((r) => r.toJson()),
    );
  });
  test('threshold boundaries and invalid numeric text', () {
    expect(
      const Reading('a', '19.2', .85).classify(settings)['status'],
      'normal',
    );
    expect(
      const Reading('a', '19.2', .60).classify(settings)['status'],
      'review',
    );
    expect(const Reading('a', '19.2', .59).classify(settings)['value'], null);
    for (final value in ['a19', '1..2', '-3', '3e2', 'NaN', '1 2']) {
      expect(Reading('a', value, .99).classify(settings)['status'], 'failed');
    }
  });
  test('CSV escapes text and neutralizes formulas', () {
    expect(
      csvLine(['a,b', 'a"b', '=2+2', null, 3]),
      '"a,b","a""b","\'=2+2","","3"\r\n',
    );
  });
  test(
    'SQLite persists record provenance, timing, recovery and cascade',
    () async {
      final store = Store(NativeDatabase.memory());
      addTearDown(store.close);
      await store.newBatch('demo', 'test', 'person', '');
      await store.begin('demo', [roi], {'mode': 'demo', 'period': 2000});
      await store.writeRound('demo', 1500, 1600, 2000, [
        const Reading('DEV01', '21.3', .8).classify(settings),
      ]);
      final row = (await store.records('demo', 'review', 0)).single;
      expect(row['scheduled'], 1600);
      expect(row['interval'], 2000);
      await store.correct(row['id'] as int, 'demo', 23, 'verified');
      final edit = (await store.records('demo', 'manual', 0)).single;
      expect(edit['original_value'], 21.3);
      expect(edit['value'], 23);
      expect(edit['status'], 'review');
      expect((await store.trend('demo', 1000, 2000)).single['value'], 23);
      await store.recover();
      expect((await store.batchById('demo'))['status'], 2);
      await store.deleteBatch('demo');
      expect(await store.exportPage('demo', 0), isEmpty);
    },
  );
}
