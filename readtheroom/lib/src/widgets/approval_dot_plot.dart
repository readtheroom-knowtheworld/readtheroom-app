// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../utils/approval_labels.dart';
import '../utils/results_colors.dart';
import 'approval_spectrum_legend.dart';

/// Beeswarm dot plot for approval results below [kDotPlotThreshold] responses.
///
/// One dot per response along the disapprove…approve axis, with the shared
/// [ApprovalSpectrumLegend] (question's end labels) underneath, coloured by the shared
/// 5-bucket palette ([ResultsColors.forApprovalBucket]) and vertically
/// stacked/jittered to avoid overlap. The average is marked with a grey
/// dashed line capped by a triangle and an "average" label. Dots animate in
/// with a staggered scale-in (~300 ms), respecting the reduced-motion
/// accessibility setting.
///
/// Hand-rolled with a [CustomPainter] — no fl_chart (beeswarm layout is not an
/// fl_chart primitive).
class ApprovalDotPlot extends StatefulWidget {
  /// Response values in [-1, 1].
  final List<double> values;

  /// Average of [values] (already computed by the caller).
  final double average;

  /// Axis end labels (WP-B). Defaults to "Disapprove" / "Approve" — pass the
  /// question's authored labels via [approvalLabelsFrom].
  final ApprovalLabels labels;

  const ApprovalDotPlot({
    Key? key,
    required this.values,
    required this.average,
    this.labels = ApprovalLabels.defaults,
  }) : super(key: key);

  @override
  State<ApprovalDotPlot> createState() => _ApprovalDotPlotState();
}

class _ApprovalDotPlotState extends State<ApprovalDotPlot>
    with TickerProviderStateMixin {
  static const double _dotRadius = 5.5;
  static const double _minDist = 13.0; // centre-to-centre packing distance
  static const double _staggerMs = 14.0;
  static const double _dotMs = 240.0;
  // Headroom above the swarm for the average triangle cap + label above it.
  static const double _topStrip = 28.0;

  late final AnimationController _controller;
  // Average-marker entrance: sweeps from far disapprove to far approve, then
  // elastically settles on the true average; the "average" label fades in as
  // it settles.
  late final AnimationController _avgController;
  late Animation<double> _avgSweep;
  late Animation<double> _avgLabelOpacity;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    final totalMs = (_dotMs + widget.values.length * _staggerMs)
        .clamp(300.0, 1600.0)
        .toInt();
    _controller = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: totalMs),
    );
    _avgController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    );
    _buildAvgAnimation();
  }

  void _buildAvgAnimation() {
    final target = widget.average.clamp(-1.0, 1.0).toDouble();
    _avgSweep = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween(begin: -1.0, end: 1.0)
            .chain(CurveTween(curve: Curves.easeInOut)),
        weight: 35,
      ),
      TweenSequenceItem(
        tween: Tween(begin: 1.0, end: target)
            .chain(CurveTween(curve: Curves.elasticOut)),
        weight: 65,
      ),
    ]).animate(_avgController);
    _avgLabelOpacity = CurvedAnimation(
      parent: _avgController,
      curve: const Interval(0.65, 1.0, curve: Curves.easeIn),
    );
  }

  void _runEntrance({required bool animate}) {
    if (animate) {
      _controller
        ..reset()
        ..forward();
      _avgController
        ..reset()
        ..forward();
    } else {
      _controller.value = 1.0;
      _avgController.value = 1.0;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    _runEntrance(animate: !MediaQuery.of(context).disableAnimations);
  }

  @override
  void didUpdateWidget(ApprovalDotPlot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.average != oldWidget.average) _buildAvgAnimation();
    if (widget.values.length != oldWidget.values.length) {
      _runEntrance(animate: !MediaQuery.of(context).disableAnimations);
    } else if (widget.average != oldWidget.average) {
      // Same dots, new average (e.g. polling refresh): keep it settled.
      _avgController.value = 1.0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _avgController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = [
      for (final v in widget.values) ResultsColors.forApprovalBucket(context, v),
    ];
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final avgColor = isDark ? Colors.grey.shade400 : Colors.grey.shade600;
    // Light axis was shade300 — indistinguishable from the card surface.
    final axisColor = isDark ? Colors.white24 : Colors.grey.shade500;
    final plot = LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final layout = _computeLayout(width);

        return AnimatedBuilder(
          animation: Listenable.merge([_controller, _avgController]),
          builder: (context, child) {
            return CustomPaint(
              size: Size(width, layout.height),
              painter: _DotPlotPainter(
                positions: layout.positions,
                colors: colors,
                axisCenterY: layout.axisCenterY,
                dotRadius: _dotRadius,
                average: _avgSweep.value,
                avgLabelOpacity: _avgLabelOpacity.value,
                avgColor: avgColor,
                axisColor: axisColor,
                topStrip: _topStrip,
                progress: _controller.value,
                totalMs: _dotMs + widget.values.length * _staggerMs,
                staggerMs: _staggerMs,
                dotMs: _dotMs,
                // Dot outline: dark mode uses a background-coloured ring so
                // overlapping dots read as separate; light mode uses a subtle
                // dark outline instead — a white ring on a light surface just
                // looked like a halo (and made pale dots look hollow).
                borderColor: isDark
                    ? const Color(0xFF1E1E1E)
                    : Colors.black.withValues(alpha: 0.18),
              ),
            );
          },
        );
      },
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        plot,
        // Same insets as the response map's legend, so the two spectra line
        // up wherever they sit on one screen (owner, 2026-09-28).
        ApprovalSpectrumLegend(
          labels: widget.labels,
          padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
        ),
      ],
    );
  }

  _PlotLayout _computeLayout(double width) {
    const hMargin = 16.0;
    final usable = math.max(1.0, width - 2 * hMargin);
    final n = widget.values.length;

    final xs = <double>[
      for (final v in widget.values)
        hMargin + ((v.clamp(-1.0, 1.0) + 1) / 2) * usable,
    ];

    // Beeswarm packing: place each dot (in x order) at the smallest vertical
    // offset from the axis that avoids overlapping already-placed dots.
    final order = List<int>.generate(n, (i) => i)
      ..sort((a, b) => xs[a].compareTo(xs[b]));
    final ys = List<double>.filled(n, 0.0);
    final placed = <int>[];
    for (final i in order) {
      final x = xs[i];
      var chosen = 0.0;
      for (var k = 0;; k++) {
        final cand = _candidateOffset(k);
        var ok = true;
        for (final j in placed) {
          final dx = x - xs[j];
          if (dx.abs() >= _minDist) continue;
          final dy = cand - ys[j];
          if (dx * dx + dy * dy < _minDist * _minDist) {
            ok = false;
            break;
          }
        }
        if (ok) {
          chosen = cand;
          break;
        }
      }
      ys[i] = chosen;
      placed.add(i);
    }

    var maxAbs = 0.0;
    for (final y in ys) {
      maxAbs = math.max(maxAbs, y.abs());
    }

    const labelStrip = 4.0;
    final swarmHalf = maxAbs + _dotRadius + 6;
    final height = _topStrip + swarmHalf * 2 + labelStrip;
    final axisCenterY = _topStrip + swarmHalf;

    final positions = <Offset>[
      for (var i = 0; i < n; i++) Offset(xs[i], axisCenterY + ys[i]),
    ];
    return _PlotLayout(
      positions: positions,
      height: height,
      axisCenterY: axisCenterY,
    );
  }

  double _candidateOffset(int k) {
    if (k == 0) return 0;
    final level = (k + 1) ~/ 2;
    return (k.isOdd ? 1 : -1) * level * _minDist;
  }
}

class _PlotLayout {
  final List<Offset> positions;
  final double height;
  final double axisCenterY;
  _PlotLayout({
    required this.positions,
    required this.height,
    required this.axisCenterY,
  });
}

class _DotPlotPainter extends CustomPainter {
  final List<Offset> positions;
  final List<Color> colors;
  final double axisCenterY;
  final double dotRadius;
  final double average;
  final double avgLabelOpacity;
  final Color avgColor;
  final Color axisColor;
  final Color borderColor;
  final double topStrip;
  final double progress;
  final double totalMs;
  final double staggerMs;
  final double dotMs;

  _DotPlotPainter({
    required this.positions,
    required this.colors,
    required this.axisCenterY,
    required this.dotRadius,
    required this.average,
    required this.avgLabelOpacity,
    required this.avgColor,
    required this.axisColor,
    required this.borderColor,
    required this.topStrip,
    required this.progress,
    required this.totalMs,
    required this.staggerMs,
    required this.dotMs,
  });

  @override
  void paint(Canvas canvas, Size size) {
    const hMargin = 16.0;
    final usable = math.max(1.0, size.width - 2 * hMargin);

    // Axis line.
    final axisPaint = Paint()
      ..color = axisColor
      ..strokeWidth = 1.5;
    canvas.drawLine(
      Offset(hMargin, axisCenterY),
      Offset(size.width - hMargin, axisCenterY),
      axisPaint,
    );

    // Average marker (grey dashed line through the swarm, triangle cap).
    final avgX = hMargin + ((average.clamp(-1.0, 1.0) + 1) / 2) * usable;
    final avgPaint = Paint()
      ..color = avgColor
      ..strokeWidth = 2.0;
    final swarmTop = topStrip;
    final swarmBottom = axisCenterY * 2 - topStrip - 2.0;
    _drawDashedLine(
        canvas, Offset(avgX, swarmTop), Offset(avgX, swarmBottom), avgPaint);
    // Triangle cap pointing down at the average position.
    final tri = Path()
      ..moveTo(avgX, swarmTop - 1)
      ..lineTo(avgX - 5, swarmTop - 8)
      ..lineTo(avgX + 5, swarmTop - 8)
      ..close();
    canvas.drawPath(tri, Paint()..color = avgColor);
    // "average" label directly above the triangle, centred on it (clamped to
    // the canvas edges so it never clips). Fades in as the marker settles.
    if (avgLabelOpacity > 0) {
      final avgTp = TextPainter(
        text: TextSpan(
          text: 'average',
          style: TextStyle(
            color: avgColor.withValues(alpha: avgLabelOpacity),
            fontSize: 10,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final labelX = (avgX - avgTp.width / 2)
          .clamp(2.0, math.max(2.0, size.width - 2.0 - avgTp.width))
          .toDouble();
      avgTp.paint(canvas, Offset(labelX, swarmTop - 10 - avgTp.height));
    }

    final borderPaint = Paint()
      ..color = borderColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;

    final elapsed = progress * totalMs;
    for (var i = 0; i < positions.length; i++) {
      final start = i * staggerMs;
      final p = ((elapsed - start) / dotMs).clamp(0.0, 1.0);
      if (p <= 0) continue;
      final scale = Curves.easeOutBack.transform(p);
      final r = dotRadius * scale;
      canvas.drawCircle(positions[i], r, Paint()..color = colors[i]);
      canvas.drawCircle(positions[i], r, borderPaint);
    }
  }

  void _drawDashedLine(Canvas canvas, Offset a, Offset b, Paint paint) {
    const dash = 4.0;
    const gap = 3.0;
    final total = (b - a).distance;
    final dir = (b - a) / total;
    var d = 0.0;
    while (d < total) {
      final s = a + dir * d;
      final e = a + dir * math.min(d + dash, total);
      canvas.drawLine(s, e, paint);
      d += dash + gap;
    }
  }

  @override
  bool shouldRepaint(covariant _DotPlotPainter old) =>
      old.progress != progress ||
      old.positions != positions ||
      old.colors != colors ||
      old.average != average ||
      old.avgLabelOpacity != avgLabelOpacity;
}
