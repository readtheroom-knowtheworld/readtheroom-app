// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Tap targets on the full-screen dot map: every dot's hit circle reaches past
// its visible rim, but never into a neighbour's. These tests pin both halves.

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:read_the_room/src/utils/map_clustering.dart';
import 'package:read_the_room/src/utils/map_hit_targets.dart';

math.Point<double> _p(double x, double y) => math.Point<double>(x, y);

void main() {
  group('dotHitRadii', () {
    test('a lone dot gets the 44 px minimum target', () {
      final hit = dotHitRadii([_p(0, 0)], [kDotRadiusBase]);
      expect(hit, [kDotMinHitRadius]);
    });

    test('a big lone dot still reaches past its rim by the padding', () {
      final hit = dotHitRadii([_p(0, 0)], [30.0]);
      expect(hit.single, 30.0 + kDotHitPadding);
    });

    test('far-apart dots are not capped', () {
      final hit = dotHitRadii(
        [_p(0, 0), _p(200, 0)],
        [kDotRadiusBase, kDotRadiusLarge],
      );
      expect(hit, [kDotMinHitRadius, kDotMinHitRadius]);
    });

    test('two equal close dots meet exactly at the midpoint', () {
      // 30 px apart: each wants 22, capped at half the distance.
      final hit = dotHitRadii([_p(0, 0), _p(30, 0)], [7.0, 7.0]);
      expect(hit[0], closeTo(15.0, 1e-9));
      expect(hit[1], closeTo(15.0, 1e-9));
    });

    test('a small dot beside a big one keeps its share of the gap', () {
      // Rims are 30 - 16 - 7 = 7 px apart; each side gets 3.5 px of it.
      final hit = dotHitRadii([_p(0, 0), _p(30, 0)], [16.0, 7.0]);
      expect(hit[0], closeTo(19.5, 1e-9));
      expect(hit[1], closeTo(10.5, 1e-9));
      expect(hit[0] + hit[1], lessThanOrEqualTo(30.0 + 1e-9));
    });

    test('never shrinks below the visible dot, even when dots overlap', () {
      // Cross-country dots can draw overlapping: 10 px apart, radii 7 and 11.
      final hit = dotHitRadii([_p(0, 0), _p(10, 0)], [7.0, 11.0]);
      expect(hit, [7.0, 11.0]);
    });

    test('touching dots keep exactly their visible radii', () {
      final hit = dotHitRadii([_p(0, 0), _p(14, 0)], [7.0, 7.0]);
      expect(hit, [7.0, 7.0]);
    });

    test('the cap comes from the nearest neighbour', () {
      final hit = dotHitRadii(
        [_p(0, 0), _p(24, 0), _p(0, 40)],
        [7.0, 7.0, 7.0],
      );
      expect(hit[0], closeTo(12.0, 1e-9)); // nearest is 24 px away
      expect(hit[1], closeTo(12.0, 1e-9));
      expect(hit[2], closeTo(20.0, 1e-9)); // nearest is 40 px away
    });

    test('hit circles never overlap unless the dots themselves do', () {
      final rng = math.Random(42);
      const sizes = [kDotRadiusBase, kDotRadiusMedium, kDotRadiusLarge];
      for (var trial = 0; trial < 200; trial++) {
        final n = 2 + rng.nextInt(12);
        final centers = [
          for (var i = 0; i < n; i++)
            _p(rng.nextDouble() * 150, rng.nextDouble() * 150),
        ];
        final radii = [for (var i = 0; i < n; i++) sizes[rng.nextInt(3)]];
        final hit = dotHitRadii(centers, radii);
        for (var i = 0; i < n; i++) {
          expect(hit[i], greaterThanOrEqualTo(radii[i]));
          expect(
            hit[i],
            lessThanOrEqualTo(
              math.max(kDotMinHitRadius, radii[i] + kDotHitPadding),
            ),
          );
          for (var j = i + 1; j < n; j++) {
            final d = centers[i].distanceTo(centers[j]);
            if (d >= radii[i] + radii[j]) {
              expect(
                hit[i] + hit[j],
                lessThanOrEqualTo(d + 1e-9),
                reason: 'trial $trial: dots $i and $j',
              );
            }
          }
        }
      }
    });

    test('empty input yields no radii', () {
      expect(dotHitRadii(const [], const []), isEmpty);
    });
  });

  group('projectToWorldPixels', () {
    test('one zoom level doubles on-screen distances', () {
      const a = LatLng(51.5, -0.1);
      const b = LatLng(48.9, 2.35);
      final d3 = projectToWorldPixels(
        a,
        3,
      ).distanceTo(projectToWorldPixels(b, 3));
      final d4 = projectToWorldPixels(
        a,
        4,
      ).distanceTo(projectToWorldPixels(b, 4));
      expect(d4, closeTo(d3 * 2, 1e-6));
    });

    test('origin maps to the centre of the world square', () {
      final p = projectToWorldPixels(const LatLng(0, 0), 0);
      expect(p.x, closeTo(128, 1e-9));
      expect(p.y, closeTo(128, 1e-9));
    });
  });
}
