import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'domain.dart';
import 'lab_style.dart';

class RoiCanvas extends StatelessWidget {
  final List<Roi> rois;
  final int selected;
  final int? texture;
  final double aspect;
  final int turns, bufferTurns;
  final List<num>? crop;
  final bool demo;
  final ValueChanged<int> onSelect;
  final void Function(int, Roi)? onChange;
  const RoiCanvas({
    super.key,
    required this.rois,
    required this.selected,
    required this.texture,
    required this.aspect,
    this.turns = 0,
    this.bufferTurns = 0,
    this.crop,
    required this.demo,
    required this.onSelect,
    this.onChange,
  });
  @override
  Widget build(BuildContext context) => Center(
    child: AspectRatio(
      aspectRatio: aspect,
      child: LayoutBuilder(
        builder: (context, box) {
          Offset normalized(Offset p) => Offset(
            (p.dx / box.maxWidth).clamp(0, 1),
            (p.dy / box.maxHeight).clamp(0, 1),
          );
          String nextId() {
            for (var i = 1; ; i++) {
              final id = 'DEV${i.toString().padLeft(2, '0')}';
              if (rois.every((r) => r.device.toUpperCase() != id)) return id;
            }
          }

          return _InteractiveCanvas(
            key: ValueKey((
              turns,
              bufferTurns,
              box.maxWidth,
              box.maxHeight,
              texture,
              crop?.join(','),
              demo,
            )),
            rois: [for (final r in rois) rotateRoi(r, turns)],
            selected: selected,
            boxSize: Size(box.maxWidth, box.maxHeight),
            textureTurns: turns + bufferTurns,
            crop: crop,
            texture: texture,
            demo: demo,
            onSelect: onSelect,
            project: normalized,
            onChange: onChange == null
                ? null
                : (i, r) => onChange!(i, rotateRoi(r, -turns)),
            nextId: nextId,
          );
        },
      ),
    ),
  );
}

class _InteractiveCanvas extends StatefulWidget {
  final List<Roi> rois;
  final int selected;
  final int? texture;
  final bool demo;
  final Size boxSize;
  final int textureTurns;
  final List<num>? crop;
  final ValueChanged<int> onSelect;
  final void Function(int, Roi)? onChange;
  final Offset Function(Offset) project;
  final String Function() nextId;
  const _InteractiveCanvas({
    super.key,
    required this.boxSize,
    required this.textureTurns,
    required this.crop,
    required this.rois,
    required this.selected,
    required this.texture,
    required this.demo,
    required this.onSelect,
    required this.onChange,
    required this.project,
    required this.nextId,
  });
  @override
  State<_InteractiveCanvas> createState() => _InteractiveCanvasState();
}

class _InteractiveCanvasState extends State<_InteractiveCanvas> {
  Offset? start;
  Roi? original, draft;
  int index = -1, corner = -1;
  Rect bounds(Roi r) => Rect.fromLTRB(r.l, r.t, r.r, r.b);
  Offset pixels(Offset p) =>
      Offset(p.dx * widget.boxSize.width, p.dy * widget.boxSize.height);
  List<Offset> cornersOf(Roi r) => [
    Offset(r.l, r.t),
    Offset(r.r, r.t),
    Offset(r.r, r.b),
    Offset(r.l, r.b),
  ];
  int hitCorner(Roi r, Offset p) {
    final corners = cornersOf(r);
    var nearest = -1;
    var best = 16.0;
    for (var i = 0; i < corners.length; i++) {
      final d = pixels(p - corners[i]).distance;
      if (d < best) {
        best = d;
        nearest = i;
      }
    }
    return nearest;
  }

  int hit(Offset p) {
    final active = widget.selected;
    if (active >= 0 &&
        active < widget.rois.length &&
        hitCorner(widget.rois[active], p) >= 0) {
      return active;
    }
    return widget.rois.lastIndexWhere((r) => bounds(r).contains(p));
  }

  void begin(Offset p) {
    start = p;
    index = hit(p);
    corner = -1;
    original = index < 0 ? null : widget.rois[index];
    final r = original;
    if (r != null) {
      corner = hitCorner(r, p);
      widget.onSelect(index);
    }
  }

  void move(Offset p) {
    final a = start;
    if (a == null) return;
    final r = original;
    Rect rect;
    if (r == null) {
      rect = Rect.fromPoints(a, p);
    } else if (corner >= 0) {
      final opposite = [
        Offset(r.r, r.b),
        Offset(r.l, r.b),
        Offset(r.l, r.t),
        Offset(r.r, r.t),
      ][corner];
      final handle = cornersOf(r)[corner] + p - a;
      rect = Rect.fromPoints(
        opposite,
        Offset(handle.dx.clamp(0, 1), handle.dy.clamp(0, 1)),
      );
    } else {
      final d = p - a;
      rect = bounds(
        r,
      ).shift(Offset(d.dx.clamp(-r.l, 1 - r.r), d.dy.clamp(-r.t, 1 - r.b)));
    }
    setState(
      () => draft = Roi(
        r?.device ?? widget.nextId(),
        rect.left,
        rect.top,
        rect.right,
        rect.bottom,
      ),
    );
  }

  void end() {
    final r = draft;
    if (r != null && r.valid) widget.onChange?.call(index, r);
    setState(() {
      draft = null;
      start = null;
    });
  }

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.zero,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      dragStartBehavior: DragStartBehavior.down,
      onTapDown: (d) {
        final i = hit(widget.project(d.localPosition));
        if (i >= 0) widget.onSelect(i);
      },
      onPanStart: widget.onChange == null
          ? null
          : (d) => begin(widget.project(d.localPosition)),
      onPanUpdate: widget.onChange == null
          ? null
          : (d) => move(widget.project(d.localPosition)),
      onPanEnd: widget.onChange == null ? null : (_) => end(),
      onPanCancel: () {
        setState(() {
          draft = null;
          start = null;
        });
      },
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (widget.texture != null)
            RotatedBox(
              quarterTurns: widget.textureTurns,
              child: LayoutBuilder(
                builder: (context, box) {
                  final c = widget.crop;
                  if (c == null) return Texture(textureId: widget.texture!);
                  final w = box.maxWidth / c[2];
                  final h = box.maxHeight / c[3];
                  return Stack(
                    clipBehavior: Clip.hardEdge,
                    children: [
                      Positioned(
                        left: -c[0] * w,
                        top: -c[1] * h,
                        width: w,
                        height: h,
                        child: Texture(textureId: widget.texture!),
                      ),
                    ],
                  );
                },
              ),
            )
          else if (widget.demo)
            CustomPaint(
              painter: _DemoPreview(
                Theme.of(context).textTheme.bodyMedium?.fontFamily,
              ),
            )
          else
            ColoredBox(
              color: LabStyle.blueWash,
              child: Center(
                child: Text(
                  '等待相机预览',
                  style: const TextStyle(color: LabStyle.secondary),
                ),
              ),
            ),
          CustomPaint(
            painter: _RoiPaint(
              widget.rois,
              widget.selected,
              draft,
              index,
              Theme.of(context).textTheme.bodyMedium?.fontFamily,
            ),
          ),
        ],
      ),
    ),
  );
}

/// Neutral instrument mockup, never presented as a live camera frame.
class _DemoPreview extends CustomPainter {
  final String? fontFamily;
  const _DemoPreview(this.fontFamily);
  @override
  void paint(Canvas canvas, Size size) {
    final region = Offset.zero & size;
    canvas.drawRect(
      region,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xffe6efff), Color(0xfff4f0fb)],
        ).createShader(region),
    );
    final grid = Paint()..color = const Color(0x244a65ac);
    for (var x = 0.0; x < size.width; x += 28) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), grid);
    }
    for (var y = 0.0; y < size.height; y += 28) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
    for (final (center, value) in [(0.24, '24.0'), (0.71, '38.7')]) {
      final w = size.width;
      final h = size.height;
      final rect = Rect.fromLTWH(w * (center - .15), h * .25, w * .30, h * .44);
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(13)),
        Paint()..color = const Color(0xfffbfcff),
      );
      final screen = Rect.fromLTWH(
        w * (center - .13),
        h * .28,
        w * .26,
        h * .30,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(screen, const Radius.circular(6)),
        Paint()..color = const Color(0xffe6edfd),
      );
      void text(String value, double y, double fontSize, Color color) {
        final painter = TextPainter(
          text: TextSpan(
            text: value,
            style: TextStyle(
              color: color,
              fontSize: fontSize,
              fontFamily: fontFamily,
              fontWeight: FontWeight.w600,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        painter.paint(
          canvas,
          Offset(w * center - painter.width / 2, h * y - painter.height / 2),
        );
        painter.dispose();
      }

      text('PM2.5', .365, 12, LabStyle.secondary);
      text(value, .465, (w * .065).clamp(13, 34), LabStyle.ink);
      canvas.drawCircle(
        Offset(w * center, h * .63),
        4,
        Paint()..color = LabStyle.violet,
      );
    }
  }

  @override
  bool shouldRepaint(_DemoPreview oldDelegate) =>
      oldDelegate.fontFamily != fontFamily;
}

class _RoiPaint extends CustomPainter {
  final List<Roi> list;
  final int selected;
  final Roi? draft;
  final int index;
  final String? fontFamily;
  _RoiPaint(this.list, this.selected, this.draft, this.index, this.fontFamily);
  @override
  void paint(Canvas canvas, Size size) {
    void draw(Roi roi, bool active) {
      final rect = Rect.fromLTRB(
        roi.l * size.width,
        roi.t * size.height,
        roi.r * size.width,
        roi.b * size.height,
      );
      final color = active ? LabStyle.blue : LabStyle.violet;
      canvas.drawRect(rect, Paint()..color = color.withValues(alpha: .09));
      canvas.drawRect(
        rect,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = active ? 2.5 : 1.5,
      );
      if (active) {
        for (final v in [
          rect.topLeft,
          rect.topRight,
          rect.bottomLeft,
          rect.bottomRight,
        ]) {
          canvas.drawCircle(v, 4, Paint()..color = color);
        }
      }
      final tp = TextPainter(
        text: TextSpan(
          text: roi.device,
          style: TextStyle(
            color: Colors.white,
            backgroundColor: color,
            fontSize: 12,
            fontFamily: fontFamily,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: (size.width - rect.left).clamp(0, size.width));
      tp.paint(canvas, rect.topLeft + const Offset(3, 3));
      tp.dispose();
    }

    for (var i = 0; i < list.length; i++) {
      if (draft == null || index != i) draw(list[i], i == selected);
    }
    if (draft != null) draw(draft!, true);
  }

  @override
  bool shouldRepaint(_RoiPaint old) =>
      list != old.list ||
      selected != old.selected ||
      draft != old.draft ||
      index != old.index ||
      fontFamily != old.fontFamily;
}

class TrendChart extends StatelessWidget {
  final List<DataRowMap> data;
  final List<String> devices;
  final int from, to;
  final ValueChanged<DataRowMap> onRow;
  const TrendChart({
    super.key,
    required this.data,
    required this.devices,
    required this.from,
    required this.to,
    required this.onRow,
  });
  @override
  Widget build(BuildContext context) => Column(
    children: [
      Align(
        alignment: Alignment.centerLeft,
        child: Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            for (var i = 0; i < devices.length; i++)
              DecoratedBox(
                decoration: BoxDecoration(
                  color: LabStyle.canvas,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.circle,
                        size: 8,
                        color: LabStyle
                            .chartSeries[i % LabStyle.chartSeries.length],
                      ),
                      const SizedBox(width: 6),
                      Text(
                        devices[i],
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
      const SizedBox(height: 12),
      if (!data.any((r) => r['value'] is num))
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 48),
          child: Text(
            '当前时段暂无有效读数',
            style: TextStyle(color: LabStyle.secondary),
          ),
        )
      else
        SizedBox(
          height: 206,
          child: LayoutBuilder(
            builder: (context, box) {
              final painter = _TrendPainter(
                data,
                devices,
                from,
                to,
                Theme.of(context).textTheme.bodySmall?.fontFamily,
              );
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapUp: (e) {
                  final w = box.maxWidth, h = box.maxHeight;
                  if (w <= 50) return;
                  final size = Size(w, h);
                  DataRowMap? pick;
                  var distance = 22.0;
                  for (final row in data) {
                    if (row['value'] == null) continue;
                    final d =
                        (painter.point(row, size) - e.localPosition).distance;
                    if (d < distance) {
                      distance = d;
                      pick = row;
                    }
                  }
                  if (pick != null) onRow(pick);
                },
                child: CustomPaint(painter: painter, size: Size.infinite),
              );
            },
          ),
        ),
    ],
  );
}

class _TrendPainter extends CustomPainter {
  final List<DataRowMap> data;
  final List<String> devices;
  final int from, to;
  late final double maxY = data.fold<double>(10, (m, r) {
    final v = (r['value'] as num?)?.toDouble() ?? 0;
    return v > m ? v : m;
  });
  late final double axisMax = ((maxY / 4 / 5).ceil() * 20).toDouble();
  final String? fontFamily;
  _TrendPainter(this.data, this.devices, this.from, this.to, this.fontFamily);
  Offset point(DataRowMap r, Size s) => Offset(
    44 +
        ((r['timestamp'] as int) - from) /
            (to - from).clamp(1, 1 << 62) *
            (s.width - 54),
    12 + (1 - (r['value'] as num) / axisMax) * (s.height - 39),
  );
  @override
  void paint(Canvas canvas, Size s) {
    if (s.width <= 54) return;
    final p = Paint()
      ..color = LabStyle.line
      ..strokeWidth = 1;
    void text(String value, Offset position, {bool end = false}) {
      final tp = TextPainter(
        text: TextSpan(
          text: value,
          style: LabStyle.number.copyWith(
            color: LabStyle.secondary,
            fontSize: 11,
            fontFamily: fontFamily,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: s.width);
      tp.paint(canvas, end ? position.translate(-tp.width, 0) : position);
      tp.dispose();
    }

    for (var i = 0; i <= 4; i++) {
      final y = 12 + (s.height - 39) * i / 4;
      canvas.drawLine(Offset(44, y), Offset(s.width - 10, y), p);
      text(
        (axisMax * (1 - i / 4)).toStringAsFixed(0),
        Offset(34, y - 7),
        end: true,
      );
    }
    String time(int ms) => DateTime.fromMillisecondsSinceEpoch(
      ms,
    ).toLocal().toString().substring(11, 19);
    text(time(from), Offset(44, s.height - 19));
    text(time(to), Offset(s.width - 10, s.height - 19), end: true);
    if (s.width >= 290 && to - from >= 2000) {
      text(
        time((from + to) ~/ 2),
        Offset((s.width + 34) / 2 + 23, s.height - 19),
        end: true,
      );
    }
    canvas.save();
    canvas.clipRect(Rect.fromLTRB(42, 8, s.width - 7, s.height - 24));
    for (var i = 0; i < devices.length; i++) {
      final line = Paint()
        ..color = LabStyle.chartSeries[i % LabStyle.chartSeries.length]
        ..strokeWidth = 2.25
        ..strokeCap = StrokeCap.round;
      Offset? last;
      for (final row in data.where((row) => row['device'] == devices[i])) {
        if (row['value'] == null) {
          last = null;
          continue;
        }
        final current = point(row, s);
        if (last != null) canvas.drawLine(last, current, line);
        canvas.drawCircle(current, row['manual'] == 1 ? 3 : 1.5, line);
        last = current;
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_TrendPainter old) =>
      old.data != data ||
      old.devices != devices ||
      old.from != from ||
      old.to != to ||
      old.fontFamily != fontFamily;
}
