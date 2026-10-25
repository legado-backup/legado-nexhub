/// 阅读趋势折线图 —— 近 7 / 30 天每日时长（CustomPainter 手绘，
/// 与热力图同一套视觉语言：无图表库依赖）。
///
/// - 折线 + 渐变面积填充，基线网格 2 条；
/// - Y 轴不放刻度（时长跨度差异大，刻度意义有限），峰值以图例展示
///   在卡片头部（由调用方渲染）；
/// - X 轴展示首 / 中 / 尾三个日期标签；
/// - 7 天模式画数据点，30 天点距过密不画。
library;

import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

/// 手绘趋势折线图。
class TrendChart extends StatelessWidget {
  /// 每日时长（秒），index 0 = 起始日。长度 0 视为无数据。
  final List<int> dailySec;

  /// 与 [dailySec] 对齐的起始日（用于 X 轴标签）。
  final DateTime startDate;

  /// 折线主色。
  final Color lineColor;

  const TrendChart({
    super.key,
    required this.dailySec,
    required this.startDate,
    required this.lineColor,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final days = dailySec.length;
    if (days == 0) return const SizedBox(height: 96);
    final showDots = days <= 8;

    String label(int i) {
      final d = startDate.add(Duration(days: i));
      return '${d.month}/${d.day}';
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SizedBox(
          height: 108,
          child: CustomPaint(
            painter: _TrendPainter(
              values: dailySec.map((s) => s.toDouble()).toList(),
              lineColor: lineColor,
              gridColor: scheme.outlineVariant.withValues(alpha: 0.4),
              showDots: showDots,
            ),
          ),
        ),
        const SizedBox(height: 2),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: <Widget>[
            Text(
              label(0),
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
            Text(
              label(days ~/ 2),
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
            Text(
              label(days - 1),
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ],
    );
  }
}

class _TrendPainter extends CustomPainter {
  final List<double> values;
  final Color lineColor;
  final Color gridColor;
  final bool showDots;

  _TrendPainter({
    required this.values,
    required this.lineColor,
    required this.gridColor,
    required this.showDots,
  });

  @override
  void paint(Canvas canvas, Size size) {
    const topPad = 6.0;
    final chartH = size.height - topPad;
    final n = values.length;
    final maxV = values.fold<double>(0, math.max);
    // 全 0 时画一条贴底基线（有数据但无活动 vs 无数据由调用方空态处理）。
    final scale = chartH / (maxV > 0 ? maxV : 1);

    Offset point(int i) {
      final x = n == 1 ? size.width / 2 : i * (size.width / (n - 1));
      final v = values[i] * scale;
      return Offset(x, topPad + chartH - v);
    }

    // 基线网格：1/2 与全高两条虚线。
    final grid = Paint()
      ..color = gridColor
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    for (final t in <double>[0.5, 1.0]) {
      final y = topPad + chartH * (1 - t);
      _dashedLine(canvas, grid, Offset(0, y), Offset(size.width, y));
    }

    if (maxV <= 0) {
      // 无活动：贴底实线示意。
      final base = Paint()
        ..color = lineColor.withValues(alpha: 0.45)
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke;
      canvas.drawLine(
        Offset(0, topPad + chartH),
        Offset(size.width, topPad + chartH),
        base,
      );
      return;
    }

    final line = Path()..moveTo(point(0).dx, point(0).dy);
    for (var i = 1; i < n; i++) {
      line.lineTo(point(i).dx, point(i).dy);
    }

    // 渐变面积填充。
    final area = Path.from(line)
      ..lineTo(point(n - 1).dx, topPad + chartH)
      ..lineTo(point(0).dx, topPad + chartH)
      ..close();
    final rect = Rect.fromLTWH(0, topPad, size.width, chartH);
    canvas.drawPath(
      area,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[
            lineColor.withValues(alpha: 0.28),
            lineColor.withValues(alpha: 0.02),
          ],
        ).createShader(rect),
    );

    final linePaint = Paint()
      ..color = lineColor
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;
    canvas.drawPath(line, linePaint);

    if (showDots) {
      final dot = Paint()..color = lineColor;
      for (var i = 0; i < n; i++) {
        canvas.drawCircle(point(i), 2.6, dot);
      }
    }
  }

  void _dashedLine(Canvas canvas, Paint paint, Offset from, Offset to) {
    const dash = 4.0;
    const gap = 4.0;
    var x = from.dx;
    while (x < to.dx) {
      canvas.drawLine(Offset(x, from.dy), Offset(math.min(x + dash, to.dx), to.dy), paint);
      x += dash + gap;
    }
  }

  @override
  bool shouldRepaint(_TrendPainter old) =>
      old.values.length != values.length ||
      old.lineColor != lineColor ||
      old.showDots != showDots ||
      (values.isNotEmpty &&
          old.values.isNotEmpty &&
          !_listEquals(old.values, values));

  static bool _listEquals(List<double> a, List<double> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
