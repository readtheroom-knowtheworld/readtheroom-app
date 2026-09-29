// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:math' as math;

/// Preferred minimum touch-target radius for a dot (logical px) — a 44 px
/// diameter, the platform guideline for a comfortable tap.
const double kDotMinHitRadius = 22.0;

/// Slack added around every visible dot, so even the biggest dot's hit area
/// reaches a little beyond its rim.
const double kDotHitPadding = 6.0;

/// Tap radii for a set of dots, in the same units as [centers] (on-screen
/// logical px at the current zoom).
///
/// Each dot wants `max(minHitRadius, radius + padding)`, but no two hit areas
/// may overlap: for every pair, the empty gap between the two *visible* rims is
/// split evenly, so dot i is capped at `r_i + max(0, d - r_i - r_j) / 2`. Two
/// equal dots therefore meet exactly at the midpoint (half the distance between
/// centres), and a small dot beside a big one keeps its fair share of the gap
/// instead of losing it to the big dot's larger visual radius.
///
/// A hit area is never smaller than its visible dot: when two dots already
/// draw overlapping (dots from different countries never merge), each keeps
/// just its visual radius — exactly the tap area it had before.
///
/// O(n²); pure and deterministic.
List<double> dotHitRadii(
  List<math.Point<double>> centers,
  List<double> radii, {
  double minHitRadius = kDotMinHitRadius,
  double padding = kDotHitPadding,
}) {
  assert(centers.length == radii.length);
  final n = centers.length;
  final hit = List<double>.generate(
    n,
    (i) => math.max(minHitRadius, radii[i] + padding),
  );
  for (var i = 0; i < n; i++) {
    for (var j = i + 1; j < n; j++) {
      final d = centers[i].distanceTo(centers[j]);
      final halfGap = math.max(0.0, d - radii[i] - radii[j]) / 2;
      final capI = radii[i] + halfGap;
      final capJ = radii[j] + halfGap;
      if (hit[i] > capI) hit[i] = capI;
      if (hit[j] > capJ) hit[j] = capJ;
    }
  }
  // No floor pass needed: every cap is r_i + (gap ≥ 0) / 2 ≥ r_i, so a hit
  // radius never drops below its visible dot.
  return hit;
}
