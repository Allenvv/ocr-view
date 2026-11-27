import 'dart:math' as math;

const samplingPeriods = [1000, 2000, 5000];
const statuses = ['normal', 'review', 'failed'];

class Roi {
  final String device;
  final double l, t, r, b;
  const Roi(this.device, this.l, this.t, this.r, this.b);
  bool get valid =>
      device.trim().isNotEmpty &&
      [l, t, r, b].every((v) => v.isFinite && v >= 0 && v <= 1) &&
      r - l >= .02 &&
      b - t >= .02 &&
      (r - l) * (b - t) <= .9;
  Map<String, Object> toJson() => {
    'deviceId': device,
    'l': l,
    't': t,
    'r': r,
    'b': b,
  };
  factory Roi.fromJson(Map data) => Roi(
    data['deviceId'] as String,
    (data['l'] as num).toDouble(),
    (data['t'] as num).toDouble(),
    (data['r'] as num).toDouble(),
    (data['b'] as num).toDouble(),
  );
  Roi rename(String name) => Roi(name, l, t, r, b);
}

bool validRois(List<Roi> rois) =>
    rois.isNotEmpty &&
    rois.every((r) => r.valid) &&
    rois.map((r) => r.device.trim().toUpperCase()).toSet().length ==
        rois.length;

// ROIs stay in the rotation-0 viewport; only their display coordinates rotate.
Roi rotateRoi(Roi r, int turns) => switch (turns % 4) {
  1 => Roi(r.device, 1 - r.b, r.l, 1 - r.t, r.r),
  2 => Roi(r.device, 1 - r.r, 1 - r.b, 1 - r.l, 1 - r.t),
  3 => Roi(r.device, r.t, 1 - r.r, r.b, 1 - r.l),
  _ => r,
};

class CaptureConfig {
  final int period, window;
  final double high, low;
  final double? alarmMin, alarmMax;
  const CaptureConfig({
    this.period = 1000,
    this.window = 300,
    this.high = .85,
    this.low = .60,
    this.alarmMin,
    this.alarmMax,
  });
  bool get valid =>
      samplingPeriods.contains(period) &&
      window >= 60 &&
      window <= 1800 &&
      high >= .75 &&
      high <= .95 &&
      low >= .4 &&
      low <= .7 &&
      high > low &&
      (alarmMin == null || (alarmMin!.isFinite && alarmMin! >= 0)) &&
      (alarmMax == null ||
          (alarmMax!.isFinite && alarmMax! >= (alarmMin ?? 0)));
  Map<String, Object?> toJson() => {
    'period': period,
    'window': window,
    'high': high,
    'low': low,
    'alarmMin': alarmMin,
    'alarmMax': alarmMax,
  };
  factory CaptureConfig.fromJson(Map data) => CaptureConfig(
    period: data['period'] as int? ?? 1000,
    window: data['window'] as int? ?? 300,
    high: (data['high'] as num?)?.toDouble() ?? .85,
    low: (data['low'] as num?)?.toDouble() ?? .60,
    alarmMin: (data['alarmMin'] as num?)?.toDouble(),
    alarmMax: (data['alarmMax'] as num?)?.toDouble(),
  );
}

class Reading {
  final String device, text;
  final double confidence;
  final String? error;
  const Reading(this.device, this.text, this.confidence, [this.error]);
  Map<String, Object?> classify(CaptureConfig config) {
    final c = confidence.isFinite && confidence >= 0 && confidence <= 1
        ? confidence
        : 0.0;
    final text = this.text.trim();
    final number = RegExp(r'^(?:[0-9]+(?:\.[0-9]+)?|\.[0-9]+)$').hasMatch(text)
        ? double.tryParse(text)
        : null;
    final failure =
        error ??
        (number == null || !number.isFinite
            ? '无有效数字'
            : c < config.low
            ? '置信度过低'
            : null);
    return {
      'device': device,
      'value': failure == null ? number : null,
      'confidence': c,
      'status': failure != null
          ? 'failed'
          : c >= config.high
          ? 'normal'
          : 'review',
      'text': text,
      'error': failure,
    };
  }
}

class FrameReadings {
  final int timestamp;
  final List<Reading> readings;
  const FrameReadings(this.timestamp, this.readings);
}

typedef DataRowMap = Map<String, Object?>;
String dateLabel(int? millis) => millis == null
    ? '—'
    : DateTime.fromMillisecondsSinceEpoch(
        millis,
      ).toLocal().toString().split('.').first;
int? percentile95(List<int> durations) {
  if (durations.isEmpty) return null;
  final sorted = [...durations]..sort();
  return sorted[math.max(0, (sorted.length * .95).ceil() - 1)];
}

String csvLine(Iterable<Object?> values) =>
    '${values.map((value) {
      var text = value?.toString() ?? '';
      // Prevent spreadsheet formula interpretation of user-controlled text.
      if (value is String && RegExp(r'^[\s\uFEFF]*[=+\-@\t\r\n]').hasMatch(text)) {
        text = "'$text";
      }
      return '"${text.replaceAll('"', '""')}"';
    }).join(',')}\r\n';
