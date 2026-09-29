// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Unit tests for the pure camera math behind the dot map: lat/lng bounds →
// (center, zoom) for a viewport, the antimeridian-safe country bounds used by
// the full-screen map's "zoom to my country" intro, and the local country-name
// → ISO resolution that feeds it. All network-free and deterministic.

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:read_the_room/src/utils/map_camera_logic.dart';

/// Projected width (px) of [bounds] at [zoom], for asserting a camera really
/// does fit what it claims to.
double _projectedWidth(GeoBounds bounds, double zoom, {double tile = 256.0}) =>
    bounds.lngSpan / 360.0 * tile * math.pow(2.0, zoom);

double _projectedHeight(GeoBounds bounds, double zoom, {double tile = 256.0}) =>
    (latToYNorm(bounds.minLat) - latToYNorm(bounds.maxLat)).abs() *
    tile *
    math.pow(2.0, zoom);

void main() {
  group('GeoBounds', () {
    test('ofPositions encloses every point, empty yields null', () {
      expect(GeoBounds.ofPositions(const []), isNull);

      final b = GeoBounds.ofPositions(const [
        LatLng(10, -20),
        LatLng(-5, 30),
        LatLng(40, 5),
      ])!;
      expect(b.minLat, -5);
      expect(b.maxLat, 40);
      expect(b.minLng, -20);
      expect(b.maxLng, 30);
      expect(b.lngSpan, 50);
      expect(b.latSpan, 45);
    });

    test('center uses the longitude midpoint and a Mercator-correct latitude',
        () {
      const b = GeoBounds(minLat: 0, minLng: -10, maxLat: 60, maxLng: 30);
      expect(b.center.longitude, closeTo(10, 1e-9));
      // Mercator stretches high latitudes, so the projected midpoint sits
      // north of the plain arithmetic mean (30°).
      expect(b.center.latitude, greaterThan(30));
      expect(b.center.latitude, lessThan(60));
    });

    test('spansAntimeridian flags boxes wider than half the globe', () {
      const wide = GeoBounds(minLat: 40, minLng: -179, maxLat: 70, maxLng: 179);
      const narrow = GeoBounds(minLat: 40, minLng: 20, maxLat: 70, maxLng: 150);
      expect(wide.spansAntimeridian, isTrue);
      expect(narrow.spansAntimeridian, isFalse);
    });
  });

  group('cameraForBounds', () {
    test('the fitted camera really fits the bounds inside the padded box', () {
      const bounds = GeoBounds(minLat: 35, minLng: -10, maxLat: 60, maxLng: 20);
      final cam = cameraForBounds(bounds, 400, 800, padding: 24);

      expect(_projectedWidth(bounds, cam.zoom), lessThanOrEqualTo(400 - 48 + 1e-6));
      expect(
          _projectedHeight(bounds, cam.zoom), lessThanOrEqualTo(800 - 48 + 1e-6));
      expect(cam.center.longitude, closeTo(5, 1e-9));
    });

    test('more padding never zooms in further', () {
      const bounds = GeoBounds(minLat: 35, minLng: -10, maxLat: 60, maxLng: 20);
      final tight = cameraForBounds(bounds, 400, 800, padding: 8);
      final loose = cameraForBounds(bounds, 400, 800, padding: 64);
      expect(loose.zoom, lessThanOrEqualTo(tight.zoom));
    });

    test('a bigger viewport never zooms out further', () {
      const bounds = GeoBounds(minLat: 35, minLng: -10, maxLat: 60, maxLng: 20);
      final small = cameraForBounds(bounds, 320, 640);
      final large = cameraForBounds(bounds, 900, 1400);
      expect(large.zoom, greaterThanOrEqualTo(small.zoom));
    });

    test('a degenerate (single-point) box clamps to maxZoom, not infinity', () {
      const dot = GeoBounds(minLat: 21, minLng: 57, maxLat: 21, maxLng: 57);
      final cam = cameraForBounds(dot, 400, 800, maxZoom: 6);
      expect(cam.zoom, 6);
      expect(cam.center.latitude, closeTo(21, 1e-9));
      expect(cam.center.longitude, closeTo(57, 1e-9));
    });

    test('a world-spanning box clamps to minZoom', () {
      const world = GeoBounds(minLat: -80, minLng: -179, maxLat: 80, maxLng: 179);
      final cam = cameraForBounds(world, 100, 100, minZoom: 0.4);
      expect(cam.zoom, 0.4);
    });
  });

  group('boundsForRings — antimeridian safety', () {
    List<LatLng> ring(double minLat, double minLng, double maxLat, double maxLng,
        {int extra = 0}) {
      return [
        LatLng(minLat, minLng),
        LatLng(maxLat, minLng),
        LatLng(maxLat, maxLng),
        LatLng(minLat, maxLng),
        for (var i = 0; i < extra; i++) LatLng(minLat, minLng),
      ];
    }

    test('no usable geometry yields null', () {
      expect(boundsForRings(const []), isNull);
      expect(boundsForRings(const [[]]), isNull);
    });

    test('a single ring is used as-is', () {
      final b = boundsForRings([ring(35, -10, 60, 20)])!;
      expect(b.minLat, 35);
      expect(b.maxLng, 20);
    });

    test('nearby parts are absorbed into the frame', () {
      // Mainland (seeded: most vertices) plus a smaller offshore part.
      final b = boundsForRings([
        ring(25, -125, 49, -67, extra: 20), // contiguous US
        ring(18, -161, 23, -154), // Hawaii
      ])!;
      expect(b.minLng, -161);
      expect(b.maxLng, -67);
      expect(b.spansAntimeridian, isFalse);
    });

    test('a part across the seam is dropped instead of spanning the globe', () {
      // Russia-shaped: a big mainland ring plus a small ring beyond 180° that
      // Natural Earth wraps to the negative side.
      final b = boundsForRings([
        ring(41, 19, 78, 180, extra: 40), // mainland
        ring(64, -180, 71, -169), // Chukotka, wrapped
      ])!;
      expect(b.minLng, 19);
      expect(b.maxLng, 180);
      expect(b.spansAntimeridian, isFalse);
    });

    test('the largest ring seeds the frame regardless of order', () {
      final big = ring(41, 19, 78, 180, extra: 40);
      final small = ring(64, -180, 71, -169);
      final a = boundsForRings([big, small])!;
      final b = boundsForRings([small, big])!;
      expect(a.minLng, b.minLng);
      expect(a.maxLng, b.maxLng);
      expect(a.minLat, b.minLat);
    });
  });

  group('cameraForCountry', () {
    test('frames the polygon bounds when they are usable', () {
      const bounds = GeoBounds(minLat: 16, minLng: 52, maxLat: 26, maxLng: 60);
      final cam = cameraForCountry(
        centroid: const LatLng(21, 56),
        bounds: bounds,
        width: 400,
        height: 800,
      );
      expect(cam.zoom, greaterThan(kCountryMinZoom));
      expect(cam.zoom, lessThanOrEqualTo(kCountryMaxZoom));
      expect(cam.center.longitude, closeTo(56, 1e-9));
    });

    test('falls back to the centroid at a sensible zoom without bounds', () {
      final cam = cameraForCountry(
        centroid: const LatLng(21, 57),
        bounds: null,
        width: 400,
        height: 800,
      );
      expect(cam.zoom, kCountryFallbackZoom);
      expect(cam.center.latitude, 21);
      expect(cam.center.longitude, 57);
    });

    test('antimeridian-spanning bounds also fall back to the centroid', () {
      const wrapped =
          GeoBounds(minLat: 41, minLng: -180, maxLat: 78, maxLng: 180);
      final cam = cameraForCountry(
        centroid: const LatLng(61, 96),
        bounds: wrapped,
        width: 400,
        height: 800,
      );
      expect(cam.zoom, kCountryFallbackZoom);
      expect(cam.center.longitude, 96);
    });

    test('a city-state is capped, a continent-sized country is floored', () {
      const tiny = GeoBounds(minLat: 1.2, minLng: 103.6, maxLat: 1.5, maxLng: 104.1);
      const huge = GeoBounds(minLat: -55, minLng: -82, maxLat: 13, maxLng: -34);
      expect(
          cameraForCountry(
                  centroid: const LatLng(1.35, 103.8),
                  bounds: tiny,
                  width: 400,
                  height: 800)
              .zoom,
          kCountryMaxZoom);
      expect(
          cameraForCountry(
                  centroid: const LatLng(-10, -55),
                  bounds: huge,
                  width: 400,
                  height: 800)
              .zoom,
          greaterThanOrEqualTo(kCountryMinZoom));
    });
  });

  group('country-name resolution', () {
    const table = {
      'USA': 'United States of America',
      'RUS': 'Russia',
      'CIV': "Côte d'Ivoire",
      'OMN': 'Oman',
      'NER': 'Niger',
      'NGA': 'Nigeria',
      'BIH': 'Bosnia and Herz.',
      'DOM': 'Dominican Republic',
      'DMA': 'Dominica',
    };

    test('normalizeCountryName folds case, punctuation and diacritics', () {
      expect(normalizeCountryName("Côte d'Ivoire"), 'cotedivoire');
      expect(normalizeCountryName('  United  Kingdom '), 'unitedkingdom');
      expect(normalizeCountryName('The Gambia'), 'gambia');
      expect(normalizeCountryName('!!'), '');
    });

    test('exact names resolve', () {
      expect(isoForCountryName('Oman', table), 'OMN');
      expect(isoForCountryName('oman', table), 'OMN');
      expect(isoForCountryName("Cote d Ivoire", table), 'CIV');
      expect(isoForCountryName('Niger', table), 'NER'); // exact beats prefix
    });

    test('a unique prefix bridges naming gaps in either direction', () {
      expect(isoForCountryName('United States', table), 'USA');
      expect(isoForCountryName('Russian Federation', table), 'RUS');
      expect(isoForCountryName('Bosnia and Herzegovina', table), 'BIH');
    });

    test('ambiguous or unknown names resolve to null, never a guess', () {
      // "Domini" prefixes both Dominica and the Dominican Republic.
      expect(isoForCountryName('Domini', table), isNull);
      expect(isoForCountryName('Atlantis', table), isNull);
      expect(isoForCountryName('', table), isNull);
      // Too short to prefix-match safely.
      expect(isoForCountryName('Om', table), isNull);
    });
  });
}
