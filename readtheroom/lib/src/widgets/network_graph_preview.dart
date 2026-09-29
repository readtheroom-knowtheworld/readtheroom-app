// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Ego-network graph preview — design doc §5.2 (friend graph), §5.5 (network
// results semantics), §9 (privacy).
//
// A [CustomPainter] ego-network: YOU at the centre, your direct friends on an
// inner ring, and friends-of-friends on a faint outer ring. The picture *is*
// the privacy model:
//
//   • Regular friends render GREY — you know who they are, but their individual
//     answers are private (§5.5). Reciprocal close friends render coloured by
//     their answer, with a halo marking them as close.
//   • Friends-of-friends are smaller anonymous dots, coloured by THEIR answer
//     (same palette as close friends) but carrying no handle — their identity
//     stays hidden. Each has an edge ONLY to its bridging friend, never to
//     another FoF, so their topology between each other is still not exposed.
//   • The "You" node is coloured by YOUR answer and glows in the app's primary.
//
// Layout is fully deterministic (fixed-angle placement, no unseeded Random) and
// scales with the available width. Entrance is a staggered radial scale/fade-in
// (~400 ms) that respects the reduced-motion accessibility setting.
//
// It takes a [NetworkGraphData], so the real `get_network_results` topology and
// the fabricated demo one hydrate the same widget. The server decides what each
// node may say; this widget only draws it. In particular a node with no answer
// is GREY WHOEVER IT IS — a close friend who turned this answer's share flag
// off must be indistinguishable from a regular friend, or the opt-out would be
// observable. There is deliberately no "hidden answer" badge.
//
// A friend who bridges to more answering friends than the server's 3-per-friend
// cap draws carries a small "+N" beside their dot: the count is disclosed, the
// dots are not.

import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../models/network_graph.dart';
import '../services/analytics_service.dart';
import '../utils/results_colors.dart';
import '../utils/approval_labels.dart';
import 'approval_spectrum_legend.dart';

class NetworkGraphPreview extends StatefulWidget {
  final NetworkGraphData data;

  /// Where the graph is drawn, for `network_node_tapped`. Never an id.
  final String surface;

  /// Draw the red-to-green legend under the graph. Approval questions only:
  /// the caller passes the question type, and the graph also detects it from
  /// any node that exposes an approval answer.
  final bool approvalLegend;

  /// The question's end labels for that legend.
  final ApprovalLabels approvalLabels;

  const NetworkGraphPreview({
    Key? key,
    required this.data,
    this.surface = 'results',
    this.approvalLegend = false,
    this.approvalLabels = ApprovalLabels.defaults,
  }) : super(key: key);

  @override
  State<NetworkGraphPreview> createState() => _NetworkGraphPreviewState();
}

class _NetworkGraphPreviewState extends State<NetworkGraphPreview>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
  );
  bool _started = false;

  /// Currently-tapped node id (drives the tooltip). Null = nothing selected.
  String? _selectedId;

  /// Last computed layout, cached for hit-testing tap positions.
  _GraphLayout? _layout;

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
  void didUpdateWidget(NetworkGraphPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Re-run the entrance when the underlying question (and thus the node set)
    // changes, and drop any stale tooltip.
    if (widget.data != oldWidget.data) {
      _selectedId = null;
      if (mounted && MediaQuery.of(context).disableAnimations) {
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

  void _handleTap(Offset localPosition) {
    final layout = _layout;
    if (layout == null) return;
    String? hit;
    // Nearest node whose touch radius contains the tap (favours the topmost /
    // largest by iterating self → friends → fof).
    for (final n in layout.nodes) {
      final touchR = math.max(n.radius + 8, 16.0);
      if ((n.pos - localPosition).distance <= touchR) {
        hit = n.node.id;
        // Prefer self/close friends when overlapping, but a direct hit wins.
        if (n.node.kind == NetworkNodeKind.self ||
            n.node.kind == NetworkNodeKind.closeFriend) {
          break;
        }
      }
    }
    // Review 2026-09-22 B4: the ego graph is the feature, and until now
    // nothing recorded whether anyone touched it. Only OPENS count — a second
    // tap on the selected node closes the tooltip and is not exploration.
    //
    // Never the node's handle or account id: `node_kind` and "did it have an
    // answer" are the whole payload. Whether people probe the grey
    // (no-answer) dots is exactly the opt-out-visibility risk the design
    // worries about, and it is answerable from these two properties alone.
    if (hit != null && hit != _selectedId) {
      final tapped = layout.nodes
          .firstWhere((n) => n.node.id == hit)
          .node;
      AnalyticsService().trackEventAnonymous('network_node_tapped', {
        'node_kind': tapped.kind.name,
        'has_answer': tapped.answerKind != null,
        'surface': widget.surface,
      });
    }
    setState(() {
      _selectedId = (hit == _selectedId) ? null : hit;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final primary = theme.primaryColor;

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth.isFinite && constraints.maxWidth > 0
            ? constraints.maxWidth
            : 320.0;
        final height = (width * 0.78).clamp(220.0, 320.0);
        final size = Size(width, height);

        final layout = _GraphLayout.compute(widget.data, size, context);
        _layout = layout;

        final edgeColor =
            isDark ? Colors.white.withOpacity(0.16) : Colors.black.withOpacity(0.10);
        final faintEdgeColor =
            isDark ? Colors.white.withOpacity(0.09) : Colors.black.withOpacity(0.06);
        final borderColor = isDark ? const Color(0xFF1E1E1E) : Colors.white;
        final overflowColor =
            isDark ? Colors.grey.shade400 : Colors.grey.shade600;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: (d) => _handleTap(d.localPosition),
              child: Stack(
                children: [
                  AnimatedBuilder(
                    animation: _controller,
                    builder: (context, _) {
                      return CustomPaint(
                        size: size,
                        painter: _GraphPainter(
                          layout: layout,
                          progress: _controller.value,
                          primary: primary,
                          edgeColor: edgeColor,
                          faintEdgeColor: faintEdgeColor,
                          borderColor: borderColor,
                          overflowColor: overflowColor,
                          selectedId: _selectedId,
                        ),
                      );
                    },
                  ),
                  if (_selectedId != null)
                    ..._buildTooltip(context, layout, size, primary, isDark),
                ],
              ),
            ),
            // What the colours mean: the approval tooltip chip is only a
            // colour, so this is the one place the scale is spelled out.
            if (_isApproval)
              ApprovalSpectrumLegend(labels: widget.approvalLabels),
          ],
        );
      },
    );
  }

  bool get _isApproval =>
      widget.approvalLegend ||
      widget.data.nodes
          .any((n) => n.answerKind == NetworkAnswerKind.approval);

  List<Widget> _buildTooltip(
    BuildContext context,
    _GraphLayout layout,
    Size size,
    Color primary,
    bool isDark,
  ) {
    _NodeLayout? sel;
    for (final n in layout.nodes) {
      if (n.node.id == _selectedId) {
        sel = n;
        break;
      }
    }
    if (sel == null) return const [];

    final theme = Theme.of(context);
    final node = sel.node;

    // Compose the tooltip content by node kind.
    final String title;
    Widget? chip;
    String? subtitle;
    // Close friends get a "Close friend" line in the primary colour under
    // their handle, so the tap says why this node is coloured (owner
    // decision 2026-09-22). Same on every graph this widget draws, demo or
    // real.
    var isCloseFriend = false;
    switch (node.kind) {
      case NetworkNodeKind.self:
        title = 'You';
        // Text questions colour nothing — not even your own answer (D-1).
        if (node.hasAnswer) {
          chip = _answerChip(context, node);
        } else if (node.answered) {
          subtitle = 'You answered this one';
        }
        break;
      case NetworkNodeKind.closeFriend:
        title = node.handle ?? 'Close friend';
        isCloseFriend = node.handle != null;
        // No answer to show means no chip and the same line a regular friend
        // gets — the opt-out must not be readable off the tooltip either.
        if (node.hasAnswer) {
          chip = _answerChip(context, node);
        } else {
          subtitle = 'Answers stay private';
        }
        break;
      case NetworkNodeKind.friend:
        // Usernames are a close-friends privilege — regular friends stay a
        // generic @friend.
        title = '@friend';
        subtitle = 'Answers stay private';
        break;
      case NetworkNodeKind.friendOfFriend:
        // Answer is revealed (coloured chip) when the server sent one, but the
        // identity never is — and there is nothing to tap through to.
        title = 'Friend of a friend';
        if (node.hasAnswer) {
          chip = _answerChip(context, node);
        } else {
          subtitle = 'Answers stay private';
        }
        break;
    }

    const tipW = 190.0;
    // Anchor above the node, clamped inside the canvas.
    final left = (sel.pos.dx - tipW / 2)
        .clamp(4.0, math.max(4.0, size.width - tipW - 4))
        .toDouble();
    var top = sel.pos.dy - sel.radius - 62;
    if (top < 2) top = sel.pos.dy + sel.radius + 10; // flip below if no room

    return [
      Positioned(
        left: left,
        top: top,
        width: tipW,
        child: Material(
          color: Colors.transparent,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF2A2A2A) : Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: primary.withOpacity(0.25)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(isDark ? 0.4 : 0.12),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (isCloseFriend) ...[
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Icon(Icons.favorite_rounded, size: 12, color: primary),
                      const SizedBox(width: 4),
                      Text(
                        'Close friend',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 6),
                if (chip != null)
                  chip
                else if (subtitle != null)
                  Row(
                    children: [
                      const Icon(Icons.lock_outline_rounded,
                          size: 13, color: Colors.grey),
                      const SizedBox(width: 5),
                      Flexible(
                        child: Text(
                          subtitle,
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: Colors.grey),
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ),
    ];
  }

  Widget _answerChip(BuildContext context, NetworkGraphNode node) {
    final color = _answerColor(context, node) ?? Colors.grey;
    // Approval answers are a colour on the legend's scale, not a word: the
    // chip is just the dot. Multiple choice shows the option text.
    final String? label = node.answerKind == NetworkAnswerKind.approval
        ? null
        : (node.answerLabel ?? '—');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withOpacity(0.6)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(shape: BoxShape.circle, color: color),
          ),
          if (label != null) ...[
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Resolves the theme-aware answer colour for a node that exposes an answer
/// (you / close friends). Returns null for nodes with no answer.
Color? _answerColor(BuildContext context, NetworkGraphNode node) {
  switch (node.answerKind) {
    case NetworkAnswerKind.approval:
      return ResultsColors.forApprovalBucket(context, node.approvalValue ?? 0);
    case NetworkAnswerKind.multipleChoice:
      return ResultsColors.forOptionIndex(context, node.optionIndex ?? 0);
    case null:
      return null;
  }
}

// ---------------------------------------------------------------------------
// Layout — deterministic fixed-angle placement.
// ---------------------------------------------------------------------------

class _NodeLayout {
  final NetworkGraphNode node;
  final Offset pos;
  final double radius;

  /// Colour to fill the node with (theme-resolved).
  final Color fill;

  /// Animation start fraction in [0, 1] (radial stagger: centre → out).
  final double animStart;

  const _NodeLayout({
    required this.node,
    required this.pos,
    required this.radius,
    required this.fill,
    required this.animStart,
  });
}

class _Edge {
  final Offset from;
  final Offset to;

  /// True for friend→FoF edges (rendered thinner + fainter).
  final bool faint;

  /// Animation start fraction of the child node (edge reveals with it).
  final double animStart;

  const _Edge({
    required this.from,
    required this.to,
    required this.faint,
    required this.animStart,
  });
}

class _GraphLayout {
  final List<_NodeLayout> nodes;
  final List<_Edge> edges;
  final Offset center;
  final double selfRadius;

  const _GraphLayout({
    required this.nodes,
    required this.edges,
    required this.center,
    required this.selfRadius,
  });

  static _GraphLayout compute(
      NetworkGraphData data, Size size, BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final center = Offset(size.width / 2, size.height / 2);
    final minDim = math.min(size.width, size.height);

    final selfR = (minDim * 0.11).clamp(16.0, 26.0);
    final friendR = (selfR * 0.6).clamp(9.0, 16.0);
    final fofR = (selfR * 0.36).clamp(5.0, 9.0);

    final outerR = minDim / 2 - fofR - 8;
    final innerR = outerR * 0.55;

    final greyFriend = isDark ? Colors.grey.shade600 : Colors.grey.shade400;
    final greyFof = isDark ? Colors.grey.shade700 : Colors.grey.shade300;

    final nodeLayouts = <_NodeLayout>[];
    final edges = <_Edge>[];
    final posById = <String, Offset>{};
    final angleById = <String, double>{};

    // Centre (you).
    final self = data.self;
    posById['self'] = center;
    nodeLayouts.add(_NodeLayout(
      node: self,
      pos: center,
      radius: selfR,
      fill: _answerColor(context, self) ?? greyFriend,
      animStart: 0.0,
    ));

    // Inner ring: direct friends, evenly spaced from the top, going clockwise.
    final friends = data.directFriends;
    final n = friends.length;
    for (var i = 0; i < n; i++) {
      final angle = -math.pi / 2 + (n == 0 ? 0 : i * 2 * math.pi / n);
      final pos = center + Offset(math.cos(angle), math.sin(angle)) * innerR;
      final f = friends[i];
      posById[f.id] = pos;
      angleById[f.id] = angle;

      // By ANSWER, not by kind: a close friend whose share flag is off has no
      // answer here and renders exactly like a regular friend.
      final fill = _answerColor(context, f) ?? greyFriend;

      // Friends reveal in the first half of the timeline.
      final animStart = 0.12 + (n == 0 ? 0 : (i / n) * 0.30);
      nodeLayouts.add(_NodeLayout(
        node: f,
        pos: pos,
        radius: friendR,
        fill: fill,
        animStart: animStart,
      ));
      edges.add(_Edge(
        from: center,
        to: pos,
        faint: false,
        animStart: animStart,
      ));
    }

    // Outer ring: friends-of-friends fanned around their bridging friend's
    // angle. Deterministic: siblings are spread symmetrically.
    final fof = data.friendsOfFriends;
    final byParent = <String, List<NetworkGraphNode>>{};
    for (final node in fof) {
      (byParent[node.parentId ?? 'self'] ??= []).add(node);
    }
    var fofIndex = 0;
    final fofTotal = math.max(1, fof.length);
    byParent.forEach((parentId, children) {
      final baseAngle = angleById[parentId] ?? -math.pi / 2;
      final c = children.length;
      const spread = 0.42; // radians between adjacent siblings
      for (var j = 0; j < c; j++) {
        final offset = (j - (c - 1) / 2.0) * spread;
        final angle = baseAngle + offset;
        final pos = center + Offset(math.cos(angle), math.sin(angle)) * outerR;
        final node = children[j];
        // FoF reveal in the second half, ordered outward.
        final animStart = 0.45 + (fofIndex / fofTotal) * 0.45;
        fofIndex++;
        // FoF are coloured by their own answer (same palette as close friends),
        // just smaller — anonymous identity, but a visible answer.
        nodeLayouts.add(_NodeLayout(
          node: node,
          pos: pos,
          radius: fofR,
          fill: _answerColor(context, node) ?? greyFof,
          animStart: animStart,
        ));
        // Edge ONLY from the bridging friend — never between FoF nodes.
        final parentPos = posById[parentId] ?? center;
        edges.add(_Edge(
          from: parentPos,
          to: pos,
          faint: true,
          animStart: animStart,
        ));
      }
    });

    return _GraphLayout(
      nodes: nodeLayouts,
      edges: edges,
      center: center,
      selfRadius: selfR,
    );
  }
}

// ---------------------------------------------------------------------------
// Painter
// ---------------------------------------------------------------------------

class _GraphPainter extends CustomPainter {
  final _GraphLayout layout;
  final double progress;
  final Color primary;
  final Color edgeColor;
  final Color faintEdgeColor;
  final Color borderColor;

  /// Colour of the "+N" friend-of-friend overflow glyph.
  final Color overflowColor;
  final String? selectedId;

  _GraphPainter({
    required this.layout,
    required this.progress,
    required this.primary,
    required this.edgeColor,
    required this.faintEdgeColor,
    required this.borderColor,
    required this.overflowColor,
    required this.selectedId,
  });

  /// Eased reveal for a node/edge given its start fraction. Every element
  /// finishes by the end of the timeline: a fixed 40 % window used to leave
  /// the last friends-of-friends (start ≥ 0.6) stuck at partial opacity,
  /// which read as "lighter shades" of the same answer.
  double _reveal(double start) {
    const dur = 0.4; // each element animates over up to 40% of the timeline
    final window = math.min(dur, 1.0 - start);
    if (window <= 0) return progress >= 1.0 ? 1.0 : 0.0;
    return ((progress - start) / window).clamp(0.0, 1.0);
  }

  @visibleForTesting
  double revealForTest(double start) => _reveal(start);

  @override
  void paint(Canvas canvas, Size size) {
    // --- Edges (behind nodes) ---
    for (final e in layout.edges) {
      final p = _reveal(e.animStart);
      if (p <= 0) continue;
      final color = e.faint ? faintEdgeColor : edgeColor;
      final paint = Paint()
        ..color = color.withOpacity(color.opacity * p)
        ..strokeWidth = e.faint ? 1.0 : 1.6
        ..strokeCap = StrokeCap.round;
      // Grow the edge outward from its source as it reveals.
      final end = Offset.lerp(e.from, e.to, Curves.easeOut.transform(p))!;
      canvas.drawLine(e.from, end, paint);
    }

    // --- Nodes ---
    for (final n in layout.nodes) {
      final p = _reveal(n.animStart);
      if (p <= 0) continue;
      final scale = Curves.easeOutBack.transform(p);
      final r = n.radius * scale;
      final selected = n.node.id == selectedId;

      final isSelf = n.node.kind == NetworkNodeKind.self;
      final isClose = n.node.kind == NetworkNodeKind.closeFriend;

      // Self glow (primary-colour halo behind the centre node).
      if (isSelf) {
        final glowPaint = Paint()
          ..color = primary.withOpacity(0.28 * p)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10);
        canvas.drawCircle(n.pos, r + 7, glowPaint);
      }

      // Close-friend halo (soft ring marking reciprocal sharing).
      if (isClose) {
        final haloPaint = Paint()
          ..color = n.fill.withOpacity(0.30 * p)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3.0;
        canvas.drawCircle(n.pos, r + 3.5, haloPaint);
      }

      // Node fill.
      canvas.drawCircle(n.pos, r, Paint()..color = n.fill.withOpacity(p));

      // Border for separation (heavier for the centre).
      canvas.drawCircle(
        n.pos,
        r,
        Paint()
          ..color = borderColor.withOpacity(p)
          ..style = PaintingStyle.stroke
          ..strokeWidth = isSelf ? 2.0 : 1.2,
      );

      // Selection ring.
      if (selected) {
        canvas.drawCircle(
          n.pos,
          r + 4,
          Paint()
            ..color = primary
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2.0,
        );
      }

      // "+N" beside a friend who bridges to more answering friends than the
      // server draws. The remainder is a number; it never becomes dots.
      if (n.node.fofOverflow > 0 && p > 0.6) {
        final dir = (n.pos - layout.center);
        final unit = dir.distance == 0
            ? const Offset(1, 0)
            : Offset(dir.dx / dir.distance, dir.dy / dir.distance);
        final tp = TextPainter(
          text: TextSpan(
            text: '+${n.node.fofOverflow}',
            style: TextStyle(
              color: overflowColor.withOpacity((p - 0.6) / 0.4),
              fontSize: math.max(9.0, n.radius * 0.72),
              fontWeight: FontWeight.w700,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        final anchor = n.pos + unit * (r + 6);
        tp.paint(canvas, anchor - Offset(tp.width / 2, tp.height / 2));
      }

      // "You" label inside the centre node once it has settled.
      if (isSelf && p > 0.6) {
        final tp = TextPainter(
          text: TextSpan(
            text: 'You',
            style: TextStyle(
              color: Colors.white.withOpacity((p - 0.6) / 0.4),
              fontSize: r * 0.5,
              fontWeight: FontWeight.w800,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, n.pos - Offset(tp.width / 2, tp.height / 2));
      }
    }
  }

  @override
  bool shouldRepaint(covariant _GraphPainter old) =>
      old.progress != progress ||
      old.selectedId != selectedId ||
      old.layout != layout;
}
