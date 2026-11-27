import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'capture.dart';
import 'domain.dart';
import 'store.dart';
import 'visuals.dart';
import 'lab_style.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(CaptureApp(Store()));
}

class CaptureApp extends StatelessWidget {
  final Store store;
  const CaptureApp(this.store, {super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'PM2.5 视觉采集记录仪',
    debugShowCheckedModeBanner: false,
    theme: LabStyle.theme(),
    home: Home(store),
  );
}

void notice(BuildContext context, String message) => ScaffoldMessenger.of(
  context,
).showSnackBar(SnackBar(content: Text(message)));
String statusLabel(Object? status) => switch (status) {
  'normal' => '正常',
  'review' => '待复核',
  'failed' => '识别失败',
  _ => '暂无',
};
Widget field(TextEditingController c, String title, {bool numeric = false}) =>
    Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: c,
        keyboardType: numeric
            ? const TextInputType.numberWithOptions(decimal: true)
            : null,
        decoration: InputDecoration(labelText: title),
      ),
    );
Future<List<String>?> form(
  BuildContext context,
  String title,
  List<String> labels,
  List<String> values, {
  Set<int> numeric = const {},
  String? Function(List<String>)? validate,
}) async {
  final controllers = values
      .map((v) => TextEditingController(text: v))
      .toList();
  String? error;
  final result = await showDialog<List<String>>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, update) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 430,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (error != null)
                  Text(
                    error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                for (var i = 0; i < labels.length; i++)
                  field(
                    controllers[i],
                    labels[i],
                    numeric: numeric.contains(i),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final input = controllers.map((c) => c.text.trim()).toList();
              final problem = validate?.call(input);
              if (problem != null) {
                update(() => error = problem);
                return;
              }
              Navigator.pop(context, input);
            },
            child: const Text('保存'),
          ),
        ],
      ),
    ),
  );
  // Await the dialog's reverse transition before releasing its controllers.
  unawaited(
    Future<void>.delayed(const Duration(milliseconds: 350), () {
      for (final c in controllers) {
        c.dispose();
      }
    }),
  );
  return result;
}

Future<bool> confirm(BuildContext context, String title, String text) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(text),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认'),
          ),
        ],
      ),
    ) ??
    false;

class Home extends StatefulWidget {
  final Store store;
  const Home(this.store, {super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  Store get store => widget.store;
  late Future<List<DataRowMap>> load;
  @override
  void initState() {
    super.initState();
    load = _init();
  }

  Future<List<DataRowMap>> _init() async {
    await store.recover();
    return store.batches();
  }

  void refresh() {
    final next = store.batches();
    setState(() {
      load = next;
    });
  }

  Future<void> open(DataRowMap row) async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => BatchPage(store, row)));
    if (mounted) refresh();
  }

  Future<void> add() async {
    final ids = (await store.batches())
        .map((row) => row['id'] as String)
        .toSet();
    if (!mounted) return;
    final v = await form(
      context,
      '新建批次',
      ['批次编号', '项目名称', '测试人员', '备注'],
      [nextBatchNumber(DateTime.now(), ids), '', '', ''],
      validate: (input) => input.take(3).any((v) => v.isEmpty)
          ? '批次编号、项目和测试人员不能为空'
          : ids.contains(input.first)
          ? '批次编号已存在，请更换'
          : null,
    );
    if (!mounted || v == null) return;
    if (v.take(3).any((x) => x.isEmpty)) {
      notice(context, '批次编号、项目和测试人员不能为空');
      return;
    }
    try {
      await store.newBatch(v[0], v[1], v[2], v[3]);
      final row = await store.batchById(v[0]);
      if (mounted) await open(row);
    } catch (e) {
      if (mounted) notice(context, '无法创建批次：$e');
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Row(
        children: [
          Icon(Icons.air_rounded, color: LabStyle.primary, size: 23),
          SizedBox(width: 8),
          Flexible(
            child: Text(
              'AIR LAB',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(letterSpacing: 1.5),
            ),
          ),
        ],
      ),
      actions: [
        IconButton(
          tooltip: 'ROI 模板',
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute<void>(builder: (_) => TemplatePage(store)),
          ),
          icon: const Icon(Icons.crop_free),
        ),
        IconButton(
          tooltip: '本地日志',
          onPressed: () => showLogs(context, store, null),
          icon: const Icon(Icons.receipt_long),
        ),
        IconButton(
          tooltip: '系统配置',
          onPressed: () => editSettings(context, store),
          icon: const Icon(Icons.settings_outlined),
        ),
      ],
    ),
    floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
    floatingActionButton: FilledButton.icon(
      onPressed: add,
      icon: const Icon(Icons.add_rounded),
      label: const Text('建立测试'),
      style: FilledButton.styleFrom(
        minimumSize: const Size(204, 48),
        backgroundColor: LabStyle.primary.withValues(alpha: .92),
      ),
    ),
    body: FutureBuilder(
      future: load,
      builder: (context, s) {
        if (s.hasError) return Center(child: Text('数据库打开失败：${s.error}'));
        if (!s.hasData) return const Center(child: CircularProgressIndicator());
        final rows = s.data!;
        return Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1100),
            child: ListView(
              padding: EdgeInsets.fromLTRB(
                20,
                12,
                20,
                84 + MediaQuery.paddingOf(context).bottom,
              ),
              children: [
                const Text('AIR QUALITY WORKSPACE', style: LabStyle.eyebrow),
                const SizedBox(height: 6),
                Text(
                  '空气质量实验室',
                  style: Theme.of(context).textTheme.headlineLarge,
                ),
                const SizedBox(height: 6),
                Text(
                  'PM2.5 视觉采集与数据复核',
                  style: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.copyWith(color: LabStyle.secondary),
                ),
                const SizedBox(height: 22),
                const LabOverview(),
                const SizedBox(height: 24),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '测试批次',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    LabBadge('${rows.length} 个批次'),
                  ],
                ),
                const SizedBox(height: 10),
                if (rows.isEmpty)
                  const Card(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text('暂无批次。新建批次后，可在取景画面框选仪器屏幕。'),
                    ),
                  ),
                for (final row in rows)
                  Card(
                    clipBehavior: Clip.antiAlias,
                    child: ListTile(
                      contentPadding: const EdgeInsets.only(left: 14, right: 6),
                      onTap: () => open(row),
                      leading: Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: LabStyle.primaryWash,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(
                          row['status'] == 2
                              ? Icons.history_rounded
                              : Icons.layers_outlined,
                          color: LabStyle.primary,
                          size: 21,
                        ),
                      ),
                      title: Text(
                        '${row['project']}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      subtitle: Padding(
                        padding: const EdgeInsets.only(top: 5, bottom: 5),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            LabBadge(
                              ['未开始', '采集中', '已停止'][row['status'] as int],
                              color: row['status'] == 1
                                  ? LabStyle.green
                                  : LabStyle.secondary,
                              background: row['status'] == 1
                                  ? LabStyle.greenWash
                                  : LabStyle.canvas,
                            ),
                            const SizedBox(height: 5),
                            Text(
                              '${dateLabel((row['started'] ?? row['created']) as int?)} · ${row['tester']}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                      trailing: IconButton(
                        tooltip: '删除批次',
                        icon: const Icon(
                          Icons.delete_outline_rounded,
                          size: 20,
                        ),
                        onPressed: () async {
                          if (await confirm(
                                context,
                                '删除批次？',
                                '会删除该批次及其全部记录和关联日志。',
                              ) &&
                              mounted) {
                            await store.deleteBatch(row['id'] as String);
                            if (mounted) refresh();
                          }
                        },
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    ),
  );
}

class LabOverview extends StatelessWidget {
  const LabOverview({super.key});
  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: const BoxDecoration(
      border: Border(left: BorderSide(color: LabStyle.line, width: 2)),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: LabStyle.gap,
        vertical: 4,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('关于本地采集', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            '框选仪器屏幕，查看与复核读数。数据仅保存在本机，可导出 CSV。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    ),
  );
}

class BatchPage extends StatefulWidget {
  final Store store;
  final DataRowMap initial;
  const BatchPage(this.store, this.initial, {super.key});
  @override
  State<BatchPage> createState() => _BatchPageState();
}

class _BatchPageState extends State<BatchPage> with WidgetsBindingObserver {
  Store get store => widget.store;
  late DataRowMap batch;
  String get id => batch['id'] as String;
  int get status => batch['status'] as int;
  late List<Roi> rois;
  CaptureSource? source;
  CameraState? camera;
  CaptureLoop? loop;
  Timer? cameraPoll;
  bool polling = false;
  CaptureConfig config = const CaptureConfig();
  List<DataRowMap> records = [], trend = [], latest = [];
  DataRowMap stats = {};
  int selected = -1, page = 0, from = 0, to = 1, zoom = 1, back = 0;
  String filter = 'all';
  bool busy = false, table = false, leaving = false, trendFullscreen = false;
  bool get demo =>
      source?.demo == true ||
      (jsonDecode(batch['config'] as String) as Map)['mode'] == 'demo';
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    batch = widget.initial;
    rois = Store.decodeRois(batch['rois']);
    unawaited(
      run(() async {
        config = status == 0
            ? await store.loadConfig()
            : CaptureConfig.fromJson(
                jsonDecode(batch['config'] as String) as Map,
              );
        if (status == 0) {
          await useCamera();
        } else {
          await reload();
        }
      }),
    );
  }

  Future<void> run(Future<void> Function() operation) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await operation();
    } catch (e) {
      if (mounted) notice(context, '操作失败：$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> useCamera() async {
    cameraPoll?.cancel();
    await source?.close();
    final current = NativeSource()..config = config;
    source = current;
    camera = await current.open();
    if (!mounted) {
      await current.close();
      return;
    }
    {
      cameraPoll = Timer.periodic(const Duration(milliseconds: 250), (_) async {
        if (!mounted || polling || busy || status != 0 || source != current) {
          return;
        }
        polling = true;
        try {
          final next = await current.state();
          if (mounted &&
              source == current &&
              status == 0 &&
              (next.aspect != camera?.aspect ||
                  next.turns != camera?.turns ||
                  next.bufferTurns != camera?.bufferTurns ||
                  !listEquals(next.crop, camera?.crop) ||
                  next.description != camera?.description ||
                  next.texture != camera?.texture ||
                  next.probeSupported != camera?.probeSupported ||
                  next.tuneSupported != camera?.tuneSupported ||
                  !listEquals(
                    next.blockers(rois, config.period),
                    camera?.blockers(rois, config.period),
                  ))) {
            setState(() => camera = next);
          }
        } catch (_) {
          /* Reconnect is available from the editor. */
        } finally {
          polling = false;
        }
      });
    }
    if (mounted) setState(() {});
  }

  Future<void> reload() async {
    final current = DateTime.now().millisecondsSinceEpoch;
    final start = (batch['started'] as int? ?? current) - config.period;
    final stop = batch['stopped'] as int? ?? current;
    final span = (stop - start).clamp(config.period, 1 << 50);
    final window = status == 2
        ? (span ~/ zoom).clamp(config.period, span)
        : config.window * 1000;
    final end = status == 2
        ? (stop - back * (window ~/ 2)).clamp(start + window, stop)
        : stop;
    final begin = end - window;
    final newTrend = await store.trend(id, begin, end);
    final newRecords = await store.records(id, filter, page * 50);
    final newStats = await store.stats(id);
    final newLatest = await store.latest(id, rois);
    if (mounted) {
      setState(() {
        trend = newTrend;
        records = newRecords;
        stats = newStats;
        latest = newLatest;
        from = begin;
        to = end;
      });
    }
  }

  Future<void> start() async {
    final input = source;
    if (input == null || !validRois(rois)) {
      throw StateError('请至少配置一个合法且设备编号不重复的 ROI');
    }
    final state = await input.state();
    camera = state;
    if (!config.valid || !state.allows(rois, config.period)) {
      throw StateError(
        [
          ...state.blockers(rois, config.period),
          if (!config.valid) '系统采样设置无效。',
        ].join(' '),
      );
    }
    if (!mounted || leaving) return;
    await store.begin(id, rois, {
      ...state.snapshot,
      ...config.toJson(),
      'mode': 'native',
      'hardwareValidation': hardwareValidation,
    });
    batch = await store.batchById(id);
    loop = CaptureLoop(
      store,
      id,
      List.unmodifiable(rois),
      config,
      input,
      reload,
      (message) async {
        final current = await store.batchById(id);
        await source?.close();
        if (mounted) {
          setState(() => batch = current);
          notice(context, message);
          await reload();
        }
      },
    );
    cameraPoll?.cancel();
    loop!.resume();
    await reload();
  }

  Future<void> stop([String reason = '停止采集']) async {
    await loop?.pause();
    if (status != 1) return;
    await store.stop(id, reason);
    batch = await store.batchById(id);
    await source?.close();
    if (mounted) await reload();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!demo &&
        status == 1 &&
        (state == AppLifecycleState.hidden ||
            state == AppLifecycleState.paused ||
            state == AppLifecycleState.detached)) {
      unawaited(
        stop('应用离开前台，已停止采集').catchError((Object e) {
          if (mounted) notice(context, '停止失败：$e');
        }),
      );
    }
  }

  @override
  void dispose() {
    cameraPoll?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    final current = loop;
    if (current != null) {
      unawaited(current.pause().whenComplete(() => source?.close()));
    } else {
      unawaited(source?.close());
    }
    super.dispose();
  }

  Future<void> exit() async {
    if (busy || leaving) return;
    if (status == 1 &&
        !await confirm(context, '退出采集？', '离开将停止当前批次，已保存的数据可以回放。')) {
      return;
    }
    if (!mounted) return;
    try {
      if (status == 1) await stop('离开监控页，已停止采集');
      if (mounted) {
        setState(() => leaving = true);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) Navigator.pop(context);
        });
      }
    } catch (e) {
      if (mounted) notice(context, '退出失败：$e');
    }
  }

  Future<void> saveTemplate() async {
    if (!validRois(rois)) throw StateError('请先绘制合法 ROI');
    final result = await form(context, '保存 ROI 模板', ['模板名称'], ['']);
    if (result != null) await store.saveTemplate(result.single, rois);
    if (mounted && result != null) notice(context, '模板已保存');
  }

  Future<void> loadTemplate() async {
    final templates = await store.templates();
    if (!mounted) return;
    final row = await showDialog<DataRowMap>(
      context: context,
      builder: (c) => SimpleDialog(
        title: const Text('加载 ROI 模板'),
        children: [
          if (templates.isEmpty)
            const Padding(padding: EdgeInsets.all(20), child: Text('没有已保存的模板')),
          for (final row in templates)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(c, row),
              child: Text('${row['name']}'),
            ),
        ],
      ),
    );
    if (row != null && mounted) {
      if (camera?.texture == null) throw StateError('请先连接真实相机，再加载和核对模板');
      final next = Store.decodeRois(row['rois']);
      if (!validRois(next)) throw StateError('模板无效：每批最多 8 个 ROI，坐标须合法且编号不得重复');
      if (row['viewport_version'] != 1 &&
          !await confirm(
            context,
            '核对旧模板',
            '旧模板的相机方向未知。请在真实取景中核对每个框；如不对齐请重画。',
          )) {
        return;
      }
      if (!mounted) return;
      setState(() {
        rois = next;
        selected = -1;
      });
    }
  }

  Future<void> editRecord(DataRowMap row) async {
    final v = await form(
      context,
      '${row['device']} · ${dateLabel(row['timestamp'] as int)}',
      ['人工 PM2.5（留空仅修改备注）', '备注'],
      ['', '${row['remark']}'],
      numeric: {0},
    );
    if (v == null) return;
    final value = double.tryParse(v[0]);
    if (v[0].isNotEmpty && (value == null || !value.isFinite || value < 0)) {
      throw ArgumentError('请输入非负数值');
    }
    await store.correct(row['id'] as int, id, value, v[1]);
    await reload();
  }

  Future<void> export({bool failures = false}) async {
    final safe = id.replaceAll(RegExp(r'[^a-zA-Z0-9_.-]'), '_');
    final name =
        '${demo ? 'DEMO_' : ''}${safe.isEmpty ? 'batch' : safe}${failures ? '_ocr_failures' : ''}.csv';
    final out = StringBuffer('\uFEFF');
    out.write(
      csvLine(
        failures
            ? ['timestamp_ms', 'time_str', 'batch_id', 'content', 'type']
            : [
                'timestamp_ms',
                'scheduled_at_ms',
                'actual_interval_ms',
                'time_str',
                'batch_id',
                'device_id',
                'pm25_value',
                'confidence',
                'is_manual_modify',
                'remark',
                'status',
                'raw_pm25_value',
                'corrected_pm25_value',
                'model_version',
                'model_sha256',
                'cycle_ms',
                'roi_index',
              ],
      ),
    );
    final frozen = jsonDecode(batch['config'] as String) as Map;
    final roiIndexes = {
      for (var i = 0; i < rois.length; i++) rois[i].device: i + 1,
    };
    var after = 0;
    while (true) {
      final rows = failures
          ? await store.ocrLogs(id, after)
          : await store.exportPage(id, after);
      for (final row in rows) {
        out.write(
          csvLine(
            failures
                ? [
                    row['time'],
                    dateLabel(row['time'] as int),
                    id,
                    row['content'],
                    row['type'],
                  ]
                : [
                    row['timestamp'],
                    row['scheduled'],
                    row['interval'],
                    dateLabel(row['timestamp'] as int),
                    id,
                    row['device'],
                    row['value'],
                    row['confidence'],
                    row['manual'] == 1,
                    row['remark'],
                    row['status'],
                    row['original_value'],
                    row['manual'] == 1 ? row['value'] : null,
                    frozen['modelVersion'],
                    frozen['modelSha256'],
                    frozen['period'],
                    roiIndexes[row['device']],
                  ],
          ),
        );
      }
      if (rows.length < 1000) break;
      after = rows.last['id'] as int;
    }
    final bytes = Uint8List.fromList(utf8.encode(out.toString()));
    final path = await FilePicker.platform.saveFile(
      dialogTitle: '导出 CSV',
      fileName: name,
      type: FileType.custom,
      allowedExtensions: ['csv'],
      bytes: Platform.isAndroid ? bytes : null,
    );
    if (path == null) return;
    if (!Platform.isAndroid) await File(path).writeAsBytes(bytes, flush: true);
    await store.log('action', '导出 $name', id);
    if (mounted) notice(context, '已导出 $name');
  }

  List<String> get startBlockers => [
    ...?camera?.blockers(rois, config.period),
    if (camera == null) '正在连接采集源，请稍候。',
    if (!validRois(rois)) '请先画出至少一个有效 ROI，且设备编号不能重复。',
    if (!config.valid) '请在首页的系统配置中检查采样设置。',
  ];

  Future<void> showCaptureStatus() => showDialog<void>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(demo ? '离线演示状态' : '真实采集状态'),
      content: SingleChildScrollView(
        child: ListBody(
          children: [
            Text(camera?.description ?? '正在连接采集源'),
            const SizedBox(height: 12),
            if (startBlockers.isEmpty)
              const Text('已就绪，可以开始。')
            else
              ...startBlockers.map(
                (reason) => Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text('• $reason'),
                ),
              ),
            if (!demo && camera?.data['validated'] != true)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  '正式采集：请项目维护者安装符合要求的模型，并在目标手机上完成识别、采样档位与 AF/AE 锁定验收。',
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c), child: const Text('关闭')),
      ],
    ),
  );

  Future<void> showRois() async {
    final i = await showModalBottomSheet<int>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (c) => FractionallySizedBox(
        heightFactor: .75,
        child: SafeArea(
          top: false,
          child: Column(
            children: [
              Text(
                'ROI 列表 · ${rois.length}',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              if (rois.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(20),
                  child: Text('回到取景画面后，拖动空白处添加 ROI。'),
                ),
              Expanded(
                child: ListView.builder(
                  itemCount: rois.length,
                  itemBuilder: (c, i) => ListTile(
                    leading: const Icon(Icons.crop_free),
                    title: Text(rois[i].device),
                    selected: i == selected,
                    onTap: () => Navigator.pop(c, i),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: '编辑设备编号',
                          icon: const Icon(Icons.edit_outlined),
                          onPressed: () => Navigator.pop(c, -i - 1),
                        ),
                        IconButton(
                          tooltip: '删除 ROI',
                          icon: const Icon(Icons.close),
                          onPressed: () => Navigator.pop(c, rois.length + i),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (i == null || !mounted) return;
    if (i < 0) {
      final n = -i - 1;
      await run(() async {
        final v = await form(context, '编辑 ROI', ['设备编号'], [rois[n].device]);
        if (v == null || !mounted) return;
        final next = [...rois]..[n] = rois[n].rename(v.single.trim());
        if (!validRois(next)) throw ArgumentError('设备编号无效或重复');
        setState(() {
          rois = next;
          selected = n;
        });
      });
    } else if (i >= rois.length) {
      setState(() {
        rois = [...rois]..removeAt(i - rois.length);
        selected = -1;
      });
    } else {
      setState(() => selected = i);
    }
  }

  Widget editor() => LayoutBuilder(
    builder: (context, box) {
      final wide = box.maxWidth >= 600 && box.maxWidth > box.maxHeight;
      final blockers = startBlockers;
      final available = blockers.isEmpty;
      final shortStatus = demo
          ? '离线演示 · 合成读数'
          : camera == null
          ? '正在连接相机…'
          : camera?.data['validated'] != true
          ? '真实采集未就绪 · 缺少验收'
          : available
          ? '真实采集已就绪'
          : '真实采集未就绪 · 查看原因';
      final hint = '拖画新框 · 框内移动 · 拖四角调整';
      Widget panel(Widget child) => Material(
        color: const Color(0xeefafcfc),
        borderRadius: BorderRadius.circular(16),
        child: child,
      );
      final statusButton = TextButton.icon(
        onPressed: showCaptureStatus,
        icon: Icon(
          demo ? Icons.science_outlined : Icons.info_outline,
          size: 18,
        ),
        label: Text(shortStatus, maxLines: 1, overflow: TextOverflow.ellipsis),
        style: TextButton.styleFrom(
          foregroundColor: demo ? LabStyle.amber : LabStyle.ink,
        ),
      );
      final toolbar = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!demo)
            IconButton(
              tooltip: '重连相机',
              color: LabStyle.ink,
              icon: const Icon(Icons.refresh),
              onPressed: busy ? null : () => run(() => useCamera()),
            ),
          IconButton(
            tooltip: '加载模板',
            color: LabStyle.ink,
            icon: const Icon(Icons.folder_open_rounded),
            onPressed: busy ? null : () => run(loadTemplate),
          ),
          IconButton(
            tooltip: '保存模板',
            color: LabStyle.ink,
            icon: const Icon(Icons.save_outlined),
            onPressed: busy || !validRois(rois)
                ? null
                : () => run(saveTemplate),
          ),
          TextButton.icon(
            onPressed: busy ? null : showRois,
            icon: const Icon(Icons.crop_free, size: 19),
            style: TextButton.styleFrom(foregroundColor: LabStyle.ink),
            label: Text('ROI ${rois.length}'),
          ),
          if (!demo &&
              (camera?.tuneSupported == true || camera?.probeSupported == true))
            PopupMenuButton<String>(
              tooltip: '相机测试',
              iconColor: LabStyle.ink,
              enabled: !busy,
              itemBuilder: (_) => [
                if (camera?.tuneSupported == true)
                  PopupMenuItem(
                    value: 'tune',
                    enabled: selected >= 0,
                    child: const Text('相机调优（ROI 优先）'),
                  ),
                if (camera?.probeSupported == true)
                  PopupMenuItem(
                    value: 'probe',
                    enabled: selected >= 0,
                    child: const Text('测试选中 ROI（不入库）'),
                  ),
              ],
              onSelected: (action) => run(() async {
                if (action == 'tune') {
                  camera = await source!.tune(rois[selected]);
                  await store.log('action', camera!.description, id);
                  if (context.mounted) notice(context, camera!.description);
                } else {
                  final reading = await (source! as NativeSource).probe(
                    rois[selected],
                  );
                  if (context.mounted) {
                    notice(
                      context,
                      reading.error ??
                          '不入库测试：${reading.text.isEmpty ? '未识别' : reading.text} · 置信度 ${reading.confidence.toStringAsFixed(2)}',
                    );
                  }
                }
              }),
            ),
        ],
      );
      final startButton = FilledButton.icon(
        onPressed: busy
            ? null
            : available
            ? () => run(start)
            : showCaptureStatus,
        style: FilledButton.styleFrom(
          disabledForegroundColor: LabStyle.secondary,
          disabledBackgroundColor: LabStyle.canvas,
        ),
        icon: Icon(
          available ? Icons.play_arrow_rounded : Icons.info_outline,
          size: 19,
        ),
        label: Text(available ? (demo ? '开始演示' : '开始采集') : '查看启动条件'),
      );
      return ColoredBox(
        color: LabStyle.canvas,
        child: Stack(
          fit: StackFit.expand,
          children: [
            RoiCanvas(
              rois: rois,
              selected: selected,
              texture: camera?.texture,
              aspect: demo || camera?.texture == null
                  ? box.maxWidth / box.maxHeight
                  : camera!.aspect,
              turns: demo ? 0 : camera?.turns ?? 0,
              bufferTurns: camera?.bufferTurns ?? 0,
              crop: camera?.crop,
              demo: demo,
              onSelect: (i) => setState(() => selected = i),
              onChange: busy || (!demo && camera?.texture == null)
                  ? null
                  : (i, r) {
                      if (i < 0 && rois.length >= maxRois) {
                        notice(context, '每批最多 8 个 ROI');
                        return;
                      }
                      setState(() {
                        rois = [...rois];
                        if (i < 0) {
                          rois.add(r);
                          selected = rois.length - 1;
                        } else {
                          rois[i] = r;
                        }
                      });
                    },
            ),
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Column(
                  children: [
                    Row(
                      children: [
                        panel(BackButton(onPressed: exit)),
                        const SizedBox(width: 6),
                        Flexible(child: panel(statusButton)),
                        if (wide) ...[const Spacer(), panel(toolbar)],
                      ],
                    ),
                    if (!wide)
                      Align(
                        alignment: Alignment.centerRight,
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          reverse: true,
                          child: panel(toolbar),
                        ),
                      ),
                    if (busy) const LinearProgressIndicator(),
                    const Spacer(),
                    Align(
                      alignment: Alignment.bottomCenter,
                      child: panel(
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                          child: Wrap(
                            alignment: WrapAlignment.center,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            spacing: 4,
                            children: [
                              if (wide)
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                  ),
                                  child: Text(
                                    hint,
                                    style: const TextStyle(
                                      color: LabStyle.secondary,
                                      fontSize: 12,
                                    ),
                                  ),
                                ),
                              startButton,
                            ],
                          ),
                        ),
                      ),
                    ),
                    if (!wide)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: IgnorePointer(
                          child: panel(
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 5,
                              ),
                              child: Text(
                                hint,
                                style: const TextStyle(
                                  color: LabStyle.secondary,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    },
  );

  Widget trendPlot({bool fullscreen = false}) => RepaintBoundary(
    child: TrendChart(
      data: trend,
      devices: rois.map((r) => r.device).toList(),
      from: from,
      to: to,
      expand: fullscreen,
      onRow: (row) => run(() => editRecord(row)),
    ),
  );

  Widget fullscreenTrend() => SafeArea(
    top: false,
    child: Padding(
      padding: const EdgeInsets.all(LabStyle.gap),
      child: Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(LabStyle.gap),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (demo) ...[
                const Align(
                  alignment: Alignment.centerLeft,
                  child: LabBadge(
                    '离线演示 · 合成读数',
                    color: LabStyle.amber,
                    background: LabStyle.amberWash,
                    icon: Icons.science_outlined,
                  ),
                ),
                const SizedBox(height: 10),
              ],
              Expanded(child: trendPlot(fullscreen: true)),
            ],
          ),
        ),
      ),
    ),
  );

  Widget monitor() {
    final active = loop?.active ?? false;
    final viewSelector = Align(
      alignment: Alignment.centerLeft,
      child: SegmentedButton<bool>(
        segments: const [
          ButtonSegment(
            value: false,
            label: Text('趋势图'),
            icon: Icon(Icons.show_chart_rounded),
          ),
          ButtonSegment(
            value: true,
            label: Text('记录表'),
            icon: Icon(Icons.table_rows_outlined),
          ),
        ],
        selected: {table},
        showSelectedIcon: false,
        onSelectionChanged: (value) => setState(() => table = value.single),
        style: ButtonStyle(
          side: const WidgetStatePropertyAll(BorderSide(color: LabStyle.line)),
          backgroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected)
                ? LabStyle.primaryWash
                : LabStyle.surface,
          ),
          foregroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected)
                ? LabStyle.primary
                : LabStyle.secondary,
          ),
        ),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('PM2.5 / SESSION', style: LabStyle.eyebrow),
        const SizedBox(height: 6),
        Text(
          status == 1 ? '实时监控' : '历史回放',
          style: Theme.of(context).textTheme.headlineLarge,
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            LabBadge(
              status == 1 ? (active ? '采集中' : '已暂停') : '已停止',
              color: active ? LabStyle.green : LabStyle.secondary,
              background: active ? LabStyle.greenWash : LabStyle.primaryWash,
            ),
            LabBadge(
              '${config.period} ms / 次',
              color: LabStyle.accentBlue,
              background: LabStyle.accentBlueWash,
            ),
            if (jsonDecode(batch['config'] as String)['hardwareValidation'] ==
                    true &&
                !demo)
              const LabBadge(
                '真机验证构建 · 非正式交付',
                color: LabStyle.amber,
                background: LabStyle.amberWash,
              ),
            if (demo)
              const LabBadge(
                '离线演示 · 合成读数',
                color: LabStyle.amber,
                background: LabStyle.amberWash,
                icon: Icons.science_outlined,
              ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          '${dateLabel(batch['started'] as int?)} ～ ${dateLabel(batch['stopped'] as int?)}',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 16),
        if (status == 2) ...[viewSelector, const SizedBox(height: 12)],
        if (status == 1 || !table)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '浓度趋势',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                      ),
                      IconButton(
                        tooltip: '全屏查看趋势',
                        onPressed: () => setState(() => trendFullscreen = true),
                        icon: const Icon(Icons.fullscreen_rounded),
                      ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    'PM2.5 浓度 · µg/m³',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 12),
                  if (status == 2)
                    Wrap(
                      spacing: 8,
                      children: [
                        IconButton(
                          tooltip: '较早',
                          onPressed: busy || zoom == 1
                              ? null
                              : () => run(() async {
                                  back++;
                                  await reload();
                                }),
                          icon: const Icon(Icons.arrow_back),
                        ),
                        IconButton(
                          tooltip: '较晚',
                          onPressed: busy || back == 0
                              ? null
                              : () => run(() async {
                                  back--;
                                  await reload();
                                }),
                          icon: const Icon(Icons.arrow_forward),
                        ),
                        IconButton(
                          tooltip: '放大',
                          onPressed: busy || zoom >= 32
                              ? null
                              : () => run(() async {
                                  zoom *= 2;
                                  back *= 2;
                                  await reload();
                                }),
                          icon: const Icon(Icons.zoom_in),
                        ),
                        IconButton(
                          tooltip: '缩小',
                          onPressed: busy || zoom <= 1
                              ? null
                              : () => run(() async {
                                  zoom ~/= 2;
                                  back ~/= 2;
                                  await reload();
                                }),
                          icon: const Icon(Icons.zoom_out),
                        ),
                      ],
                    ),
                  trendPlot(),
                ],
              ),
            ),
          ),
        const SizedBox(height: 18),
        LayoutBuilder(
          builder: (context, box) {
            final count = box.maxWidth >= 520 ? 4 : 2;
            final width = (box.maxWidth - (count - 1) * 8) / count;
            return Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final (label, value, color) in [
                  ('采集记录', '${stats['total'] ?? 0}', LabStyle.primary),
                  ('识别失败', '${stats['failed'] ?? 0}', LabStyle.amber),
                  ('丢帧', '${stats['dropped'] ?? 0}', LabStyle.secondary),
                  (
                    'P95 耗时',
                    '${percentile95(loop?.durations ?? []) ?? '—'} ms',
                    LabStyle.accentBlue,
                  ),
                ])
                  SizedBox(
                    width: width,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: LabStyle.surface,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              label,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                            Text(
                              value,
                              style: LabStyle.number.copyWith(
                                fontSize: 23,
                                fontWeight: FontWeight.w700,
                                color: color,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
        if (loop?.warning != null)
          Text(
            loop!.warning!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          alignment: WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (status == 1) ...[
              OutlinedButton.icon(
                onPressed: busy
                    ? null
                    : () => run(() async {
                        if (active) {
                          await loop?.pause();
                          await store.log('action', '暂停采集', id);
                        } else {
                          final current = await source!.state();
                          if (!current.allows(rois, config.period)) {
                            throw StateError(
                              current.blockers(rois, config.period).join(' '),
                            );
                          }
                          loop?.resume();
                          await store.log('action', '恢复采集', id);
                        }
                      }),
                icon: Icon(active ? Icons.pause : Icons.play_arrow),
                label: Text(active ? '暂停' : '继续'),
              ),
              FilledButton(
                onPressed: busy ? null : () => run(() => stop()),
                child: const Text('停止批次'),
              ),
            ],
            MenuAnchor(
              menuChildren: [
                MenuItemButton(
                  onPressed: busy ? null : () => run(() => export()),
                  leadingIcon: const Icon(Icons.ios_share_rounded),
                  child: const Text('导出 CSV'),
                ),
                MenuItemButton(
                  onPressed: busy
                      ? null
                      : () => run(() => export(failures: true)),
                  leadingIcon: const Icon(Icons.file_download_outlined),
                  child: const Text('导出失败日志'),
                ),
                MenuItemButton(
                  onPressed: () => showLogs(context, store, id),
                  leadingIcon: const Icon(Icons.receipt_long),
                  child: const Text('日志'),
                ),
              ],
              builder: (_, controller, child) => OutlinedButton.icon(
                onPressed: () =>
                    controller.isOpen ? controller.close() : controller.open(),
                icon: const Icon(Icons.more_horiz_rounded),
                label: const Text('更多'),
              ),
            ),
          ],
        ),
        if (status == 1)
          Wrap(spacing: 8, children: [for (final roi in rois) deviceCard(roi)]),
        const SizedBox(height: 8),
        if (status == 1)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => setState(() => table = !table),
              icon: Icon(table ? Icons.expand_less : Icons.expand_more),
              label: Text(table ? '收起记录表' : '展开记录表'),
            ),
          ),
        const SizedBox(height: 8),
        if (table) ...[
          Wrap(
            spacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              const Text('筛选'),
              DropdownButton<String>(
                value: filter,
                items: [
                  for (final v in ['all', ...statuses, 'manual'])
                    DropdownMenuItem(
                      value: v,
                      child: Text(
                        v == 'all'
                            ? '所有记录'
                            : v == 'manual'
                            ? '人工修改'
                            : statusLabel(v),
                      ),
                    ),
                ],
                onChanged: busy
                    ? null
                    : (v) => run(() async {
                        filter = v ?? 'all';
                        page = 0;
                        await reload();
                      }),
              ),
              IconButton(
                tooltip: '上一页',
                onPressed: busy || page == 0
                    ? null
                    : () => run(() async {
                        page--;
                        await reload();
                      }),
                icon: const Icon(Icons.chevron_left),
              ),
              Text('第 ${page + 1} 页'),
              IconButton(
                tooltip: '下一页',
                onPressed: busy || records.length < 50
                    ? null
                    : () => run(() async {
                        page++;
                        await reload();
                      }),
                icon: const Icon(Icons.chevron_right),
              ),
            ],
          ),
          for (final row in records)
            Card(
              child: ListTile(
                onTap: busy ? null : () => run(() => editRecord(row)),
                title: Text(
                  '${row['device']} · ${row['value'] ?? '—'} · ${statusLabel(row['status'])}${row['manual'] == 1 ? ' · 人工' : ''}',
                ),
                subtitle: Text(
                  '${dateLabel(row['timestamp'] as int)}  置信度 ${row['confidence']}\n${row['remark']}',
                ),
                trailing: const Icon(Icons.edit_outlined),
              ),
            ),
          if (records.isEmpty)
            const Padding(padding: EdgeInsets.all(16), child: Text('没有匹配记录')),
        ],
      ],
    );
  }

  Widget deviceCard(Roi roi) {
    final row = latest.where((r) => r['device'] == roi.device).firstOrNull;
    final value = row?['value'] as num?;
    final alarm =
        value != null &&
        ((config.alarmMax != null && value > config.alarmMax!) ||
            (config.alarmMin != null && value < config.alarmMin!));
    final status = row?['status'];
    return SizedBox(
      width: 152,
      child: Card(
        color: alarm
            ? LabStyle.redWash
            : status == 'review'
            ? LabStyle.amberWash
            : null,
        child: InkWell(
          onTap: row == null || busy ? null : () => run(() => editRecord(row)),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(roi.device),
                Text(
                  value?.toString() ?? '—',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                Text(
                  '${alarm ? '告警 · ' : ''}${statusLabel(status)}${row?['manual'] == 1 ? ' · 人工' : ''}',
                ),
                Text(
                  '置信度 ${(row?['confidence'] as num?)?.toStringAsFixed(2) ?? '—'}',
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: leaving,
    onPopInvokedWithResult: (done, _) {
      if (done) return;
      if (trendFullscreen) {
        setState(() => trendFullscreen = false);
      } else {
        unawaited(exit());
      }
    },
    child: Scaffold(
      appBar: trendFullscreen
          ? AppBar(
              leading: IconButton(
                tooltip: '退出全屏',
                icon: const Icon(Icons.close_rounded),
                onPressed: () => setState(() => trendFullscreen = false),
              ),
              title: const Text('PM2.5 浓度趋势 · µg/m³'),
            )
          : status == 0
          ? null
          : AppBar(
              leading: BackButton(onPressed: exit),
              title: Text(
                '${batch['project']} · ${status == 0
                    ? 'ROI 编辑'
                    : status == 1
                    ? '实时监控'
                    : '回放'}',
              ),
            ),
      body: trendFullscreen
          ? fullscreenTrend()
          : status == 0
          ? editor()
          : Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1150),
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
                  children: [
                    if (busy) const LinearProgressIndicator(),
                    monitor(),
                  ],
                ),
              ),
            ),
    ),
  );
}

class TemplatePage extends StatefulWidget {
  final Store store;
  const TemplatePage(this.store, {super.key});
  @override
  State<TemplatePage> createState() => _TemplatePageState();
}

class _TemplatePageState extends State<TemplatePage> {
  late Future<List<DataRowMap>> data = widget.store.templates();
  void refresh() {
    final next = widget.store.templates();
    setState(() {
      data = next;
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('ROI 模板')),
    body: FutureBuilder(
      future: data,
      builder: (context, s) {
        if (s.hasError) return Center(child: Text('${s.error}'));
        if (!s.hasData) return const Center(child: CircularProgressIndicator());
        return ListView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
          children: [
            Text('模板库', style: Theme.of(context).textTheme.headlineLarge),
            const SizedBox(height: 8),
            Text(
              '在批次取景页保存或加载 ROI 模板。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 20),
            if (s.data!.isEmpty)
              const Card(
                child: Padding(
                  padding: EdgeInsets.all(20),
                  child: Text('暂无 ROI 模板'),
                ),
              ),
            for (final row in s.data!)
              Card(
                child: ListTile(
                  title: Text('${row['name']}'),
                  subtitle: Text(
                    '${Store.decodeRois(row['rois']).length} 个 ROI · ${dateLabel(row['saved'] as int)}',
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: '重命名',
                        icon: const Icon(Icons.edit_outlined),
                        onPressed: () async {
                          final result = await form(
                            context,
                            '重命名模板',
                            ['名称'],
                            ['${row['name']}'],
                          );
                          if (!mounted ||
                              result == null ||
                              result.single.isEmpty) {
                            return;
                          }
                          try {
                            await widget.store.renameTemplate(
                              row['id'] as int,
                              result.single,
                            );
                            if (mounted) refresh();
                          } catch (e) {
                            if (context.mounted) notice(context, '无法重命名：$e');
                          }
                        },
                      ),
                      IconButton(
                        tooltip: '删除模板',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () async {
                          if (await confirm(context, '删除模板？', '不影响已开始的批次。') &&
                              mounted) {
                            await widget.store.deleteTemplate(row['id'] as int);
                            if (mounted) refresh();
                          }
                        },
                      ),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    ),
  );
}

Future<void> editSettings(BuildContext context, Store store) async {
  final config = await store.loadConfig();
  if (!context.mounted) return;
  final v = await form(
    context,
    '系统设置 · 上传关闭',
    [
      '周期（1000/2000/5000 ms，真实相机仅允许已验证配置）',
      '高置信阈值（0.75–0.95）',
      '低置信阈值（0.40–0.70）',
      '告警下限（可空）',
      '告警上限（可空）',
      '曲线窗口（60–1800 秒）',
      '失败快照（0 关闭 / 1 保存）',
      '相机调优超时（1000–5000 ms）',
    ],
    [
      '${config.period}',
      '${config.high}',
      '${config.low}',
      config.alarmMin?.toString() ?? '',
      config.alarmMax?.toString() ?? '',
      '${config.window}',
      config.saveSnapshot ? '1' : '0',
      '${config.tuneTimeoutMs}',
    ],
    numeric: {0, 1, 2, 3, 4, 5, 6, 7},
    validate: (v) => const {'0', '1'}.contains(v[6]) ? null : '失败快照仅可填写 0 或 1',
  );
  if (v == null) return;
  try {
    await store.saveConfig(
      CaptureConfig(
        period: int.parse(v[0]),
        high: double.parse(v[1]),
        low: double.parse(v[2]),
        alarmMin: v[3].isEmpty ? null : double.parse(v[3]),
        alarmMax: v[4].isEmpty ? null : double.parse(v[4]),
        window: int.parse(v[5]),
        saveSnapshot: v[6] == '1',
        tuneTimeoutMs: int.parse(v[7]),
      ),
    );
    if (context.mounted) notice(context, '配置已保存，仅对之后启动的批次生效');
  } catch (e) {
    if (context.mounted) notice(context, '无效的设置：$e');
  }
}

Future<void> showLogs(BuildContext context, Store store, String? id) async {
  await Navigator.push(
    context,
    MaterialPageRoute<void>(
      builder: (context) => Scaffold(
        appBar: AppBar(
          title: const Text('最近 300 条本地日志'),
          actions: [
            if (id == null)
              IconButton(
                tooltip: '清空日志',
                icon: const Icon(Icons.delete_sweep_outlined),
                onPressed: () async {
                  if (await confirm(
                        context,
                        '清空全部日志？',
                        '此操作不可撤销，批次及读数不会被删除。',
                      ) &&
                      context.mounted) {
                    await store.clearLogs();
                    if (context.mounted) Navigator.pop(context);
                  }
                },
              ),
          ],
        ),
        body: FutureBuilder(
          future: store.logs(id),
          builder: (context, s) {
            if (s.hasError) return Center(child: Text('${s.error}'));
            if (!s.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            final rows = s.data!;
            if (rows.isEmpty) return const Center(child: Text('暂无日志'));
            return ListView.builder(
              itemCount: rows.length,
              itemBuilder: (context, i) {
                final r = rows[i];
                return ListTile(
                  title: Text('${r['type']} · ${dateLabel(r['time'] as int)}'),
                  subtitle: SelectableText(logSummary(r)),
                );
              },
            );
          },
        ),
      ),
    ),
  );
}
