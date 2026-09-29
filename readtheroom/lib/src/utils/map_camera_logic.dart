// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:math' as math;
import 'package:latlong2/latlong.dart';

/// Pure camera math for the dot map: lat/lng bounds → a (center, zoom) target
/// that frames those bounds inside a viewport.
///
/// Kept free of Flutter and flutter_map so both the inline preview
/// (`fitDotCamera`) and the full-screen map's "zoom to my country" intro can
/// share — and unit-test — exactly the same projection.

/// Default zoom used when a country's polygon bounds are unusable (missing
/// geometry, or a country that wraps the antimeridian) and we can only frame
/// its centroid. Roughly "a medium country fills the screen".
const double kCountryFallbackZoom = 4.5;

/// Padding (logical px) left around a country when framing its bounds, so the
/// coastline never sits flush against the screen edge.
const double kCountryFitPadding = 48.0;

/// Zoom bounds for country framing. The minimum stops a sprawling country from
/// looking like the world view we just animated away from; the maximum stops a
/// city-state from landing at street level.
const double kCountryMinZoom = 1.6;
const double kCountryMaxZoom = 7.0;

/// A camera target: where to point the map and how far in.
class CameraTarget {
  final LatLng center;
  final double zoom;

  const CameraTarget(this.center, this.zoom);

  @override
  String toString() =>
      'CameraTarget(${center.latitude}, ${center.longitude} @ $zoom)';
}

/// An axis-aligned lat/lng box.
class GeoBounds {
  final double minLat;
  final double minLng;
  final double maxLat;
  final double maxLng;

  const GeoBounds({
    required this.minLat,
    required this.minLng,
    required this.maxLat,
    required this.maxLng,
  });

  /// Bounds enclosing every position in [positions], or null when empty.
  static GeoBounds? ofPositions(Iterable<LatLng> positions) {
    var minLat = 90.0, maxLat = -90.0, minLng = 180.0, maxLng = -180.0;
    var any = false;
    for (final p in positions) {
      any = true;
      minLat = math.min(minLat, p.latitude);
      maxLat = math.max(maxLat, p.latitude);
      minLng = math.min(minLng, p.longitude);
      maxLng = math.max(maxLng, p.longitude);
    }
    if (!any) return null;
    return GeoBounds(
        minLat: minLat, minLng: minLng, maxLat: maxLat, maxLng: maxLng);
  }

  double get lngSpan => maxLng - minLng;
  double get latSpan => maxLat - minLat;

  /// True when the box is so wide it almost certainly straddles the ±180°
  /// seam (e.g. naive bounds over Russia or Fiji) rather than genuinely
  /// spanning half the planet.
  bool get spansAntimeridian => lngSpan > 180.0;

  /// Mercator-correct centre: the longitude midpoint, and the latitude whose
  /// projected Y sits halfway between the projected north and south edges.
  LatLng get center => LatLng(
        yNormToLat((latToYNorm(maxLat) + latToYNorm(minLat)) / 2.0),
        (minLng + maxLng) / 2.0,
      );

  GeoBounds extendedWith(GeoBounds other) => GeoBounds(
        minLat: math.min(minLat, other.minLat),
        minLng: math.min(minLng, other.minLng),
        maxLat: math.max(maxLat, other.maxLat),
        maxLng: math.max(maxLng, other.maxLng),
      );
}

/// Bounds for a multi-part country polygon.
///
/// Natural Earth splits countries at the antimeridian, so naive min/max over
/// every ring turns Russia, Fiji or the Aleutians into a world-spanning box.
/// Instead we seed from the *largest* ring (the mainland) and only absorb
/// another ring when doing so keeps the box narrower than half the globe —
/// so Alaska and Hawaii still join the contiguous US, while Chukotka does not
/// drag Russia's frame across the seam.
///
/// Returns null when [rings] holds no usable geometry.
GeoBounds? boundsForRings(List<List<LatLng>> rings) {
  final usable = rings.where((r) => r.isNotEmpty).toList();
  if (usable.isEmpty) return null;

  // Seed with the ring carrying the most vertices — the mainland, in practice.
  var seedIndex = 0;
  for (var i = 1; i < usable.length; i++) {
    if (usable[i].length > usable[seedIndex].length) seedIndex = i;
  }

  var bounds = GeoBounds.ofPositions(usable[seedIndex])!;
  for (var i = 0; i < usable.length; i++) {
    if (i == seedIndex) continue;
    final part = GeoBounds.ofPositions(usable[i]);
    if (part == null) continue;
    final merged = bounds.extendedWith(part);
    if (merged.spansAntimeridian) continue; // Would wrap the seam — skip.
    bounds = merged;
  }
  return bounds;
}

/// Camera that frames [bounds] inside a [width]×[height] viewport (logical px)
/// leaving [padding] on every side, clamped to `[minZoom, maxZoom]`.
///
/// Deterministic and projection-exact (Web Mercator, [tileSize]-px tiles), so a
/// caller can cluster at precisely the zoom this returns.
CameraTarget cameraForBounds(
  GeoBounds bounds,
  double width,
  double height, {
  double padding = 24.0,
  double minZoom = 0.4,
  double maxZoom = 6.0,
  double tileSize = 256.0,
}) {
  final availW = math.max(1.0, width - 2 * padding);
  final availH = math.max(1.0, height - 2 * padding);

  // Fraction of the whole world spanned on each axis (guard tiny spans so a
  // single point resolves to maxZoom rather than infinity).
  final xFraction = math.max(bounds.lngSpan / 360.0, 1e-6);
  final yFraction = math.max(
      (latToYNorm(bounds.minLat) - latToYNorm(bounds.maxLat)).abs(), 1e-6);

  final zoomX = _log2(availW / (tileSize * xFraction));
  final zoomY = _log2(availH / (tileSize * yFraction));
  final zoom = math.min(zoomX, zoomY).clamp(minZoom, maxZoom).toDouble();

  return CameraTarget(bounds.center, zoom);
}

/// Camera that frames a country.
///
/// Prefers the country's polygon [bounds]; falls back to [centroid] at
/// [fallbackZoom] when there is no usable geometry (or the geometry wraps the
/// antimeridian), so "zoom to my country" always has somewhere to go.
CameraTarget cameraForCountry({
  required LatLng centroid,
  GeoBounds? bounds,
  required double width,
  required double height,
  double padding = kCountryFitPadding,
  double minZoom = kCountryMinZoom,
  double maxZoom = kCountryMaxZoom,
  double fallbackZoom = kCountryFallbackZoom,
  double tileSize = 256.0,
}) {
  if (bounds == null || bounds.spansAntimeridian) {
    return CameraTarget(centroid, fallbackZoom.clamp(minZoom, maxZoom));
  }
  return cameraForBounds(
    bounds,
    width,
    height,
    padding: padding,
    minZoom: minZoom,
    maxZoom: maxZoom,
    tileSize: tileSize,
  );
}

double _log2(double v) => math.log(v) / math.ln2;

/// Normalised Web-Mercator Y in [0,1] (0 = north pole, 1 = south pole).
double latToYNorm(double lat) {
  final s = math.sin(lat * math.pi / 180.0).clamp(-0.9999, 0.9999).toDouble();
  return 0.5 - math.log((1 + s) / (1 - s)) / (4 * math.pi);
}

/// Inverse of [latToYNorm].
double yNormToLat(double y) {
  final t = (0.5 - y) * 4 * math.pi;
  final e = math.exp(t);
  final s = (e - 1) / (e + 1); // tanh(t/2)
  return math.asin(s) * 180.0 / math.pi;
}

/// Normalises a country name for comparison: lower-cased, stripped of
/// punctuation and whitespace, diacritics folded, leading "the" dropped — so
/// "Côte d'Ivoire", "Cote D'Ivoire" and "cotedivoire" collapse to one key.
String normalizeCountryName(String raw) {
  final lower = raw.toLowerCase();
  final buffer = StringBuffer();
  for (final rune in lower.runes) {
    final ch = String.fromCharCode(rune);
    if (_asciiWord.hasMatch(ch)) {
      buffer.write(ch);
    } else {
      final folded = _diacriticFolds[ch];
      if (folded != null) buffer.write(folded);
    }
  }
  var out = buffer.toString();
  if (out.startsWith('the') && out.length > 3) out = out.substring(3);
  return out;
}

final RegExp _asciiWord = RegExp(r'[a-z0-9]');

const Map<String, String> _diacriticFolds = {
  'à': 'a',
  'á': 'a',
  'â': 'a',
  'ã': 'a',
  'ä': 'a',
  'å': 'a',
  'ç': 'c',
  'è': 'e',
  'é': 'e',
  'ê': 'e',
  'ë': 'e',
  'ì': 'i',
  'í': 'i',
  'î': 'i',
  'ï': 'i',
  'ñ': 'n',
  'ò': 'o',
  'ó': 'o',
  'ô': 'o',
  'õ': 'o',
  'ö': 'o',
  'ù': 'u',
  'ú': 'u',
  'û': 'u',
  'ü': 'u',
  'ý': 'y',
};

/// Resolves a human country [name] against a `code → display name` map (the
/// bundled centroid asset, the parsed GeoJSON, or the app's own country
/// table), returning the code.
///
/// Exact normalised match first, then a *unique* prefix match in either
/// direction — which bridges the common naming gaps ("United States" →
/// "United States of America", "Russian Federation" → "Russia") without a
/// hand-maintained alias table. Anything ambiguous (no candidate, or more than
/// one) resolves to null rather than guessing.
String? isoForCountryName(String name, Map<String, String> codeToName) {
  final q = normalizeCountryName(name);
  if (q.isEmpty) return null;

  String? uniquePrefix;
  var prefixMatches = 0;
  for (final entry in codeToName.entries) {
    final candidate = normalizeCountryName(entry.value);
    if (candidate.isEmpty) continue;
    if (candidate == q) return entry.key;
    if (q.length >= 4 &&
        candidate.length >= 4 &&
        (candidate.startsWith(q) || q.startsWith(candidate))) {
      prefixMatches++;
      uniquePrefix = entry.key;
    }
  }
  return prefixMatches == 1 ? uniquePrefix : null;
}
