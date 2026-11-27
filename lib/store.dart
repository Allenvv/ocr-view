import 'dart:convert';
import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'domain.dart';

class Store extends GeneratedDatabase {
  Store([QueryExecutor? executor])
    : super(
        executor ??
            driftDatabase(
              name: 'pm25_capture',
              native: const DriftNativeOptions(shareAcrossIsolates: true),
            ),
      );
  @override
  int get schemaVersion => 1;
  @override
  Iterable<TableInfo<Table, dynamic>> get allTables => const [];
  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (_) async {
      for (final sql in schema) {
        await customStatement(sql);
      }
    },
    beforeOpen: (_) async {
      await customStatement('PRAGMA foreign_keys=ON');
      await customStatement('PRAGMA busy_timeout=5000');
    },
  );
  static const schema = [
    '''CREATE TABLE batches(id TEXT PRIMARY KEY, project TEXT NOT NULL, tester TEXT NOT NULL,
      remark TEXT NOT NULL, created INTEGER NOT NULL, started INTEGER, stopped INTEGER,
      status INTEGER NOT NULL DEFAULT 0, rois TEXT NOT NULL DEFAULT '[]', config TEXT NOT NULL DEFAULT '{}')''',
    'CREATE INDEX batch_order ON batches(created DESC)',
    '''CREATE TABLE records(id INTEGER PRIMARY KEY AUTOINCREMENT, batch TEXT NOT NULL REFERENCES batches(id) ON DELETE CASCADE,
      device TEXT NOT NULL, timestamp INTEGER NOT NULL, scheduled INTEGER NOT NULL, interval INTEGER NOT NULL,
      value REAL, original_value REAL, confidence REAL NOT NULL, manual INTEGER NOT NULL DEFAULT 0,
      remark TEXT NOT NULL DEFAULT '', status TEXT NOT NULL CHECK(status IN ('normal','review','failed')))''',
    'CREATE INDEX records_time ON records(batch,timestamp,id)',
    'CREATE INDEX records_device_time ON records(batch,device,timestamp)',
    'CREATE INDEX records_status ON records(batch,status,id)',
    '''CREATE TABLE logs(id INTEGER PRIMARY KEY AUTOINCREMENT, time INTEGER NOT NULL, type TEXT NOT NULL,
      content TEXT NOT NULL, batch TEXT REFERENCES batches(id) ON DELETE CASCADE)''',
    'CREATE INDEX logs_batch ON logs(batch,type,id)',
    'CREATE TABLE templates(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL UNIQUE, rois TEXT NOT NULL, saved INTEGER NOT NULL)',
    'CREATE TABLE settings(id INTEGER PRIMARY KEY CHECK(id=1), config TEXT NOT NULL)',
  ];
  int get now => DateTime.now().millisecondsSinceEpoch;
  Future<List<DataRowMap>> query(
    String sql, [
    List<Variable> vars = const [],
  ]) async => (await customSelect(
    sql,
    variables: vars,
  ).get()).map((r) => r.data).toList();
  Future<List<DataRowMap>> batches() =>
      query('SELECT * FROM batches ORDER BY created DESC');
  Future<DataRowMap> batchById(String id) async =>
      (await query('SELECT * FROM batches WHERE id=?', [Variable(id)])).single;
  Future<void> newBatch(
    String id,
    String project,
    String tester,
    String remark,
  ) => transaction(() async {
    await customStatement(
      'INSERT INTO batches(id,project,tester,remark,created) VALUES(?,?,?,?,?)',
      [id, project, tester, remark, now],
    );
    await log('action', '新建批次', id);
  });
  Future<void> deleteBatch(String id) => transaction(() async {
    await customStatement('DELETE FROM batches WHERE id=?', [id]);
    await log('action', '删除批次 $id');
  });
  Future<void> recover() => transaction(() async {
    final active = await query('SELECT id FROM batches WHERE status=1');
    for (final row in active) {
      await stop(row['id'] as String, '上次运行未正常退出；已保留记录并结束批次');
    }
  });
  Future<void> begin(String id, List<Roi> rois, Map<String, Object?> config) =>
      transaction(() async {
        if (!validRois(rois)) throw ArgumentError('ROI 无效');
        if ((await batchById(id))['status'] != 0) throw StateError('批次已开始');
        await customStatement(
          'UPDATE batches SET started=?,status=1,rois=?,config=? WHERE id=?',
          [now, encodeRois(rois), jsonEncode(config), id],
        );
        await log('action', '开始采集', id);
      });
  Future<void> stop(String id, String reason) => transaction(() async {
    await customStatement(
      'UPDATE batches SET stopped=?,status=2 WHERE id=? AND status=1',
      [now, id],
    );
    await log('action', reason, id);
  });
  Future<void> log(String type, String text, [String? id]) => customStatement(
    'INSERT INTO logs(time,type,content,batch) VALUES(?,?,?,?)',
    [now, type, text, id],
  );
  Future<void> clearLogs() => customStatement('DELETE FROM logs');
  Future<List<DataRowMap>> logs(String? id) => id == null
      ? query('SELECT * FROM logs ORDER BY id DESC LIMIT 300')
      : query('SELECT * FROM logs WHERE batch=? ORDER BY id DESC LIMIT 300', [
          Variable(id),
        ]);
  Future<List<DataRowMap>> ocrLogs(String id, int afterId) => query(
    'SELECT * FROM logs WHERE batch=? AND type=? AND id>? ORDER BY id LIMIT 1000',
    [Variable(id), const Variable('ocr'), Variable(afterId)],
  );
  Future<void> writeRound(
    String id,
    int timestamp,
    int scheduled,
    int period,
    List<DataRowMap> readings,
  ) => transaction(() async {
    for (final r in readings) {
      await customStatement(
        '''INSERT INTO records(batch,device,timestamp,scheduled,interval,value,original_value,confidence,status)
        VALUES(?,?,?,?,?,?,?,?,?)''',
        [
          id,
          r['device'],
          timestamp,
          scheduled,
          period,
          r['value'],
          r['value'],
          r['confidence'],
          r['status'],
        ],
      );
      if (r['error'] != null) await log('ocr', jsonEncode(r), id);
    }
  });
  Future<List<DataRowMap>> records(String id, String filter, int offset) {
    final condition = filter == 'manual'
        ? ' AND manual=1'
        : statuses.contains(filter)
        ? ' AND status=?'
        : '';
    return query(
      'SELECT * FROM records WHERE batch=?$condition ORDER BY id DESC LIMIT 50 OFFSET ?',
      [
        Variable(id),
        if (statuses.contains(filter)) Variable(filter),
        Variable(offset),
      ],
    );
  }

  Future<List<DataRowMap>> exportPage(String id, int afterId) => query(
    'SELECT * FROM records WHERE batch=? AND id>? ORDER BY id LIMIT 1000',
    [Variable(id), Variable(afterId)],
  );
  Future<DataRowMap> stats(String id) async => (await query(
    '''SELECT
    (SELECT COUNT(*) FROM records WHERE batch=?) total,
    (SELECT COUNT(*) FROM records WHERE batch=? AND status='failed') failed,
    (SELECT COUNT(*) FROM logs WHERE batch=? AND type='dropFrame') dropped''',
    [Variable(id), Variable(id), Variable(id)],
  )).single;
  Future<List<DataRowMap>> latest(String id, List<Roi> rois) async => [
    for (final roi in rois)
      ...await query(
        'SELECT * FROM records WHERE batch=? AND device=? ORDER BY timestamp DESC,id DESC LIMIT 1',
        [Variable(id), Variable(roi.device)],
      ),
  ];
  Future<List<DataRowMap>> trend(String id, int start, int end) => query(
    '''WITH sampled AS (
       SELECT *, CAST((timestamp-?)/? AS INTEGER) bucket FROM records WHERE batch=? AND timestamp BETWEEN ? AND ?
    ), ranked AS (SELECT *, ROW_NUMBER() OVER (PARTITION BY device,bucket ORDER BY timestamp DESC,id DESC) n FROM sampled)
    SELECT * FROM ranked WHERE n=1 ORDER BY timestamp,id''',
    [
      Variable(start),
      Variable((end - start) ~/ 300 + 1),
      Variable(id),
      Variable(start),
      Variable(end),
    ],
  );
  Future<void> correct(
    int rowId,
    String id,
    double? value,
    String remark,
  ) => transaction(() async {
    if (value != null && (!value.isFinite || value < 0)) {
      throw ArgumentError('数值无效');
    }
    await customStatement(
      'UPDATE records SET remark=?, value=COALESCE(?,value), manual=CASE WHEN ? IS NULL THEN manual ELSE 1 END WHERE id=? AND batch=?',
      [remark, value, value, rowId, id],
    );
    await log('action', '${value == null ? '修改备注' : '人工修正'} #$rowId', id);
  });
  static String encodeRois(List<Roi> rois) =>
      jsonEncode(rois.map((r) => r.toJson()).toList());
  static List<Roi> decodeRois(Object? encoded) =>
      (jsonDecode(encoded as String? ?? '[]') as List)
          .map((r) => Roi.fromJson(r as Map))
          .toList();
  Future<List<DataRowMap>> templates() =>
      query('SELECT * FROM templates ORDER BY saved DESC');
  Future<void> saveTemplate(String name, List<Roi> rois) async {
    if (!validRois(rois) || name.trim().isEmpty) {
      throw ArgumentError('模板名称或 ROI 无效');
    }
    await customStatement(
      'INSERT INTO templates(name,rois,saved) VALUES(?,?,?) ON CONFLICT(name) DO UPDATE SET rois=excluded.rois,saved=excluded.saved',
      [name.trim(), encodeRois(rois), now],
    );
  }

  Future<void> renameTemplate(int id, String name) => customStatement(
    'UPDATE templates SET name=?,saved=? WHERE id=?',
    [name, now, id],
  );
  Future<void> deleteTemplate(int id) =>
      customStatement('DELETE FROM templates WHERE id=?', [id]);
  Future<CaptureConfig> loadConfig() async {
    final rows = await query('SELECT config FROM settings WHERE id=1');
    return rows.isEmpty
        ? const CaptureConfig()
        : CaptureConfig.fromJson(
            jsonDecode(rows.single['config'] as String) as Map,
          );
  }

  Future<void> saveConfig(CaptureConfig config) async {
    if (!config.valid) throw ArgumentError('配置范围无效');
    await customStatement(
      'INSERT OR REPLACE INTO settings(id,config) VALUES(1,?)',
      [jsonEncode(config.toJson())],
    );
  }
}
