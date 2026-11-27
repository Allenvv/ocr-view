import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/services.dart';
import 'domain.dart';
import 'store.dart';

const hardwareValidation = bool.fromEnvironment('PM25_HARDWARE_VALIDATION');

class CameraState {
  final Map<Object?, Object?> data;
  const CameraState(this.data);
  int? get texture => data['textureId'] as int?;
  double get aspect =>
      (data['width'] as num? ?? 16) / (data['height'] as num? ?? 9);
  String get description => data['message'] as String? ?? '无相机信息';
  bool get probeSupported => data['probeSupported'] == true;
  bool get tuneSupported => data['tuneSupported'] == true;
  int get turns => data['turns'] as int? ?? 0;
  int get bufferTurns => data['bufferTurns'] as int? ?? 0;
  List<num>? get crop => (data['crop'] as List?)?.cast<num>();
  List<String> blockers(List<Roi> rois, int period) {
    final isDemo = data['mode'] == 'demo';
    final profiles = data['profiles'] as Map?;
    final validation =
        hardwareValidation && !isDemo && samplingPeriods.contains(period);
    final capacity = data['roiLimit'] as int?;
    return [
      if (isDemo &&
          (data['validated'] != true ||
              data['ready'] != true ||
              data['framesReady'] != true))
        '离线演示尚未准备好。',
      if (!isDemo && data['modelAvailable'] != true)
        '未安装可用的 REC 识别模型。 ${data['modelProblem'] ?? ''}',
      if (!isDemo && !validation && data['validated'] != true)
        '当前设备及相机采样档位未验收。',
      if (!isDemo && data['ready'] != true)
        data['platform'] == 'Windows Media Foundation'
            ? '未确认 UVC 固定设备与模式。'
            : 'AF/AE 锁定和正式识别链路不可用。',
      if (!isDemo && data['framesReady'] != true) '未收到新鲜相机帧；请检查相机权限并重连。',
      if (data['storageReady'] != true) '可用存储不足或尚未确认。',
      if (!isDemo &&
          !validation &&
          profiles != null &&
          !profiles.containsKey('$period:${rois.length}'))
        '该 ROI 数量与周期组合尚未通过验收。',
      if (!isDemo &&
          !validation &&
          data['validated'] == true &&
          capacity != null &&
          capacity > 0 &&
          rois.length > capacity)
        '目标设备已验收的采样档位仅支持 $capacity 个 ROI；请更换已验收档位。',
      if (!validation &&
          (isDemo || data['validated'] == true) &&
          !(data['periods'] as List? ?? []).contains(period))
        '当前档位不支持该采样周期。',
    ];
  }

  bool allows(List<Roi> rois, int period) => blockers(rois, period).isEmpty;
  Map<String, Object?> get snapshot =>
      data.map((k, v) => MapEntry(k.toString(), v))..remove('textureId');
}

abstract class CaptureSource {
  bool get demo;
  Future<CameraState> open();
  Future<CameraState> state();
  Future<CameraState> tune(Roi roi);
  Future<FrameReadings> sample(List<Roi> rois, int budgetMs);
  Future<void> close();
}

class NativeSource implements CaptureSource {
  Object? _sessionId;
  CaptureConfig config = const CaptureConfig();
  static const channel = MethodChannel('pm25_capture/camera');
  @override
  bool get demo => false;
  Future<CameraState> _call(String name, [Object? args]) async {
    try {
      return CameraState(
        await channel.invokeMapMethod<Object?, Object?>(name, args) ?? {},
      );
    } on MissingPluginException {
      return const CameraState({'message': '本构建没有注册原生相机适配器，真实采集不可用'});
    }
  }

  @override
  Future<CameraState> open() async {
    final report = await _call('open');
    _sessionId = report.data['sessionId'];
    return report;
  }

  @override
  Future<CameraState> state() => _call('state');
  @override
  Future<CameraState> tune(Roi roi) =>
      _call('tune', {...roi.toJson(), 'timeoutMs': config.tuneTimeoutMs});
  @override
  Future<FrameReadings> sample(List<Roi> rois, int budgetMs) async {
    final elapsed = Stopwatch()..start();
    var result = await channel
        .invokeMapMethod<Object?, Object?>('sample', {
          'rois': rois.map((r) => r.toJson()).toList(),
          'budgetMs': budgetMs,
          'sessionId': _sessionId,
          'saveSnapshot': config.saveSnapshot,
          'low': config.low,
        })
        .timeout(Duration(milliseconds: budgetMs));
    while (result?['pending'] == true &&
        elapsed.elapsedMilliseconds < budgetMs) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      result = await channel.invokeMapMethod<Object?, Object?>('sampleResult');
    }
    if (result?['fatal'] case final String code) {
      throw PlatformException(code: code);
    }
    if (result == null || result['pending'] == true) {
      throw StateError('无帧或采集超时');
    }
    return FrameReadings(result['timestampMs'] as int, [
      for (final item in result['readings'] as List)
        Reading(
          item['deviceId'] as String,
          item['text'] as String,
          (item['confidence'] as num).toDouble(),
          item['error'] as String?,
          item['snapshot'] is Uint8List
              ? base64Encode(item['snapshot'] as Uint8List)
              : null,
        ),
    ]);
  }

  Future<Reading> probe(Roi roi) async {
    var row = await channel.invokeMapMethod<Object?, Object?>(
      'probe',
      roi.toJson(),
    );
    final elapsed = Stopwatch()..start();
    while (row?['pending'] == true && elapsed.elapsedMilliseconds < 5000) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      row = await channel.invokeMapMethod<Object?, Object?>('probeResult');
    }
    if (row == null || row['pending'] == true) {
      throw StateError('未在 5 秒内返回识别结果');
    }
    return Reading(
      roi.device,
      row['text'] as String,
      (row['confidence'] as num).toDouble(),
      row['error'] as String?,
    );
  }

  @override
  Future<void> close() => _call('close');
}

class DemoSource implements CaptureSource {
  int count = 0;
  @override
  bool get demo => true;
  @override
  Future<CameraState> open() => state();
  @override
  Future<CameraState> state() async => const CameraState({
    'message': '离线演示 · 合成读数，不使用相机',
    'mode': 'demo',
    'validated': true,
    'ready': true,
    'framesReady': true,
    'storageReady': true,
    'periods': samplingPeriods,
  });
  @override
  Future<CameraState> tune(Roi roi) => state();
  @override
  Future<FrameReadings> sample(List<Roi> rois, int budgetMs) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final round = count++;
    return FrameReadings(now, [
      for (var i = 0; i < rois.length; i++)
        Reading(
          rois[i].device,
          round % 17 == 0 && i == 0
              ? ''
              : (24 + 11 * i + 9 * math.sin(round / 5 + i)).toStringAsFixed(1),
          round % 17 == 0 && i == 0
              ? .35
              : (round + i) % 7 == 0
              ? .73
              : .96,
        ),
    ]);
  }

  @override
  Future<void> close() async {}
}

class CaptureLoop {
  final Store store;
  final String id;
  final List<Roi> rois;
  final CaptureConfig config;
  final CaptureSource source;
  final Future<void> Function() onUpdate;
  final void Function(String) onFatal;
  final Stopwatch _elapsed = Stopwatch();
  Timer? _timer;
  bool _active = false;
  Future<void>? _inFlight;
  int _origin = 0, _next = 0, _timeoutStreak = 0, _lastFrame = 0;
  final List<int> durations = [];
  String? warning;
  bool get active => _active;
  CaptureLoop(
    this.store,
    this.id,
    this.rois,
    this.config,
    this.source,
    this.onUpdate,
    this.onFatal,
  );
  int get budget => config.period * 8 ~/ 10;
  void resume() {
    if (_active || _inFlight != null) return;
    _active = true;
    _elapsed
      ..reset()
      ..start();
    _origin = DateTime.now().millisecondsSinceEpoch;
    _next = config.period;
    _schedule();
  }

  Future<void> pause() async {
    _active = false;
    _timer?.cancel();
    await _inFlight;
    _elapsed.stop();
  }

  void _schedule() {
    if (!_active) return;
    _timer = Timer(
      Duration(milliseconds: math.max(0, _next - _elapsed.elapsedMilliseconds)),
      () {
        _inFlight = _tick();
        unawaited(
          _inFlight!.whenComplete(() {
            _inFlight = null;
            _schedule();
          }),
        );
      },
    );
  }

  Future<void> _drop(int scheduled, int elapsed, String reason) async {
    _timeoutStreak++;
    if (_timeoutStreak >= 3) warning = '持续丢拍：请减少 ROI，或为下一批明确选择已验证的较慢周期。';
    await store.log(
      'dropFrame',
      'scheduled_at_ms=$scheduled elapsed_ms=$elapsed $reason',
      id,
    );
  }

  Future<void> _tick() async {
    final slot = _next;
    final scheduled = _origin + slot;
    _next += config.period;
    final started = _elapsed.elapsedMilliseconds;
    try {
      if (started - slot >= budget) {
        await _drop(scheduled, started - slot, '错过截止时间');
      } else {
        FrameReadings? frame;
        Object? issue;
        try {
          frame = await source.sample(rois, budget - (started - slot));
        } catch (e) {
          issue = e;
        }
        final took = _elapsed.elapsedMilliseconds - slot;
        durations.add(took);
        if (durations.length > 300) durations.removeAt(0);
        if (!_active) return;
        if (issue is PlatformException &&
            const [
              'camera_lost',
              'storage_low',
              'lock_lost',
              'model_lost',
            ].contains(issue.code)) {
          _active = false;
          await store.stop(id, issue.message ?? issue.code);
          onFatal(issue.message ?? issue.code);
          return;
        }
        if (took >= budget ||
            frame == null ||
            frame.timestamp < scheduled - config.period ||
            frame.timestamp <= _lastFrame) {
          await _drop(
            scheduled,
            took,
            took >= budget ? '超时' : '无新鲜帧 ${issue ?? ''}',
          );
        } else {
          _timeoutStreak = 0;
          _lastFrame = frame.timestamp;
          warning = null;
          final byDevice = {for (final r in frame.readings) r.device: r};
          final readings = [
            for (final roi in rois)
              (byDevice[roi.device] ?? Reading(roi.device, '', 0, '缺少该 ROI 结果'))
                  .classify(config),
          ];
          await store.writeRound(
            id,
            frame.timestamp,
            scheduled,
            config.period,
            readings,
          );
        }
      }
      // Never replay missed slots; aggregate the start time of each missed cadence in the log.
      final elapsed = _elapsed.elapsedMilliseconds;
      while (_active && _next <= elapsed) {
        await _drop(_origin + _next, elapsed - _next, '上一轮仍在处理');
        _next += config.period;
      }
      if (_active) await onUpdate();
    } catch (e) {
      _active = false;
      try {
        await store.stop(id, '采集出错：$e');
      } catch (_) {
        /* Preserve original error. */
      }
      onFatal('采集已停止：$e');
    }
  }
}
