// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';

/// One multiple-choice option rendered as a row of dots — one dot per vote,
/// wrapped into rows of ~15 — used below [kDotPlotThreshold] responses instead
/// of a percentage bar (spec §4.3).
///
/// Dots animate in with a staggered scale-in (~300 ms), respecting the
/// reduced-motion accessibility setting. Hand-rolled with plain [Container]s.
class McDotRow extends StatefulWidget {
  final String label;
  final int voteCount;
  final int totalResponses;
  final Color color;

  /// Start delay before this row's dots begin filling — lets the results
  /// screen cascade rows top-to-bottom (highest-voted first).
  final int delayMs;

  const McDotRow({
    Key? key,
    required this.label,
    required this.voteCount,
    required this.totalResponses,
    required this.color,
    this.delayMs = 0,
  }) : super(key: key);

  /// Estimated fill time for [voteCount] dots — used by callers to compute
  /// cascading [delayMs] values. Mirrors the internal timing constants.
  static int fillDurationMs(int voteCount) =>
      (220.0 + voteCount * 18.0).clamp(300.0, 1600.0).toInt();

  @override
  State<McDotRow> createState() => _McDotRowState();
}

class _McDotRowState extends State<McDotRow>
    with SingleTickerProviderStateMixin {
  static const double _dotSize = 14.0;
  static const int _perRow = 15;
  static const double _staggerMs = 18.0;
  static const double _dotMs = 220.0;

  late final AnimationController _controller;
  bool _started = false;

  double get _fillMs =>
      (_dotMs + widget.voteCount * _staggerMs).clamp(300.0, 1600.0);

  double get _totalMs => widget.delayMs + _fillMs;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: _totalMs.toInt()),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (MediaQuery.of(context).disableAnimations) {
      _controller.value = 1.0;
    } else {
      _controller.forward();
    }
  }

  @override
  void didUpdateWidget(McDotRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.voteCount != oldWidget.voteCount) {
      _controller.duration = Duration(milliseconds: _totalMs.toInt());
      if (MediaQuery.of(context).disableAnimations) {
        _controller.value = 1.0;
      } else {
        _controller
          ..reset()
          ..forward();
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pct = widget.totalResponses > 0
        ? (widget.voteCount / widget.totalResponses * 100).round()
        : 0;

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Text(
                  widget.label,
                  style: TextStyle(
                    fontWeight: FontWeight.normal,
                    color: Theme.of(context).textTheme.bodyLarge?.color,
                  ),
                ),
              ),
              Text(
                '$pct% (${widget.voteCount})',
                style: TextStyle(
                  fontWeight: FontWeight.normal,
                  color: Theme.of(context).textTheme.bodySmall?.color,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (widget.voteCount > 0)
            AnimatedBuilder(
              animation: _controller,
              builder: (context, child) => _buildDotGrid(),
            ),
        ],
      ),
    );
  }

  Widget _buildDotGrid() {
    final rows = <Widget>[];
    // The controller spans delay + fill; dots only start moving once the
    // delay has elapsed.
    final elapsed = _controller.value * _totalMs - widget.delayMs;
    for (var start = 0; start < widget.voteCount; start += _perRow) {
      final end =
          (start + _perRow) < widget.voteCount ? start + _perRow : widget.voteCount;
      final dots = <Widget>[];
      for (var i = start; i < end; i++) {
        final p = ((elapsed - i * _staggerMs) / _dotMs).clamp(0.0, 1.0);
        final scale = Curves.easeOutBack.transform(p);
        dots.add(Padding(
          padding: const EdgeInsets.only(right: 5, bottom: 5),
          child: Transform.scale(
            scale: scale,
            child: Container(
              width: _dotSize,
              height: _dotSize,
              decoration: BoxDecoration(
                color: widget.color,
                shape: BoxShape.circle,
              ),
            ),
          ),
        ));
      }
      rows.add(Row(mainAxisSize: MainAxisSize.min, children: dots));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: rows);
  }
}

/// A multiple-choice percentage bar that grows from zero on entrance, after an
/// optional [delayMs] — the results screen cascades bars top-to-bottom
/// (highest-voted first). Later [widthFactor] changes (poll refreshes) animate
/// smoothly from the current width with no delay or reset. Respects
/// reduced-motion.
class McResultBar extends StatefulWidget {
  final double widthFactor;
  final Color color;
  final int delayMs;

  /// Track geometry — defaults match the results-screen bars; the QOTD hero
  /// passes its slimmer style.
  final double height;
  final Color? backgroundColor;
  final BorderRadius? fillRadius;

  const McResultBar({
    Key? key,
    required this.widthFactor,
    required this.color,
    this.delayMs = 0,
    this.height = 12,
    this.backgroundColor,
    this.fillRadius,
  }) : super(key: key);

  /// Fill time for one bar; callers add this (with overlap) per row to build
  /// the cascade.
  static const int fillDurationMs = 450;

  @override
  State<McResultBar> createState() => _McResultBarState();
}

class _McResultBarState extends State<McResultBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  bool _started = false;
  double _from = 0.0;
  double _delayFraction = 0.0;

  @override
  void initState() {
    super.initState();
    final totalMs = widget.delayMs + McResultBar.fillDurationMs;
    _delayFraction = widget.delayMs / totalMs;
    _controller = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: totalMs),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (MediaQuery.of(context).disableAnimations) {
      _controller.value = 1.0;
    } else {
      _controller.forward();
    }
  }

  @override
  void didUpdateWidget(McResultBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.widthFactor != oldWidget.widthFactor) {
      // Poll refresh: glide from what's on screen to the new width, no
      // delay/re-cascade.
      _from = _shownFactor(oldWidget.widthFactor);
      _delayFraction = 0.0;
      _controller.duration = const Duration(milliseconds: 300);
      if (MediaQuery.of(context).disableAnimations) {
        _controller.value = 1.0;
      } else {
        _controller
          ..reset()
          ..forward();
      }
    }
  }

  double _shownFactor(double target) {
    final t = _delayFraction >= 1.0
        ? 1.0
        : ((_controller.value - _delayFraction) / (1.0 - _delayFraction))
            .clamp(0.0, 1.0);
    final eased = Curves.easeOutCubic.transform(t);
    return _from + (target - _from) * eased;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final factor = _shownFactor(widget.widthFactor).clamp(0.0, 1.0);
        return Container(
          height: widget.height,
          decoration: BoxDecoration(
            color: widget.backgroundColor ??
                Theme.of(context).colorScheme.surface,
          ),
          child: FractionallySizedBox(
            alignment: Alignment.centerLeft,
            widthFactor: factor,
            child: Container(
              decoration: BoxDecoration(
                color: widget.color,
                borderRadius: widget.fillRadius ??
                    const BorderRadius.only(
                      topRight: Radius.circular(6),
                      bottomRight: Radius.circular(6),
                    ),
              ),
            ),
          ),
        );
      },
    );
  }
}
