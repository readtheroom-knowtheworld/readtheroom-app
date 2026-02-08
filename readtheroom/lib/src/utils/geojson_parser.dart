// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';
import 'package:flutter/services.dart' show rootBundle;
import 'package:latlong2/latlong.dart';

/// A single polygon part with an outer ring and optional holes.
class GeoPolygonPart {
  final List<LatLng> outerRing;
  final List<List<LatLng>> holes;

  GeoPolygonPart({required this.outerRing, this.holes = const []});
}

/// A parsed country feature from GeoJSON with one or more polygon parts.
class GeoCountry {
  final String isoA3;
  final String name;
  final List<GeoPolygonPart> parts;

  GeoCountry({required this.isoA3, required this.name, required this.parts});
}

/// Parses the Natural Earth GeoJSON asset and provides hit testing.
class GeoJsonParser {
  static List<GeoCountry>? _cache;

  /// Load and parse the GeoJSON asset. Returns cached result on subsequent calls.
  static Future<List<GeoCountry>> loadCountries() async {
    if (_cache != null) return _cache!;

    final jsonStr =
        await rootBundle.loadString('assets/ne_50m_admin_0_countries.json');
    final Map<String, dynamic> geojson = json.decode(jsonStr);
    final features = geojson['features'] as List;

    final countries = <GeoCountry>[];
    for (final feature in features) {
      final props = feature['properties'] as Map<String, dynamic>;
      final geometry = feature['geometry'] as Map<String, dynamic>;

      // Prefer ISO_A3, fall back to ADM0_A3 for countries where ISO_A3 is "-99"
      // (France, Norway, Kosovo, N. Cyprus, Somaliland, etc.)
      String isoCode = props['ISO_A3']?.toString() ?? '';
      if (isoCode.isEmpty || isoCode == '-99') {
        isoCode = props['ADM0_A3']?.toString() ?? '';
      }
      if (isoCode.isEmpty || isoCode == '-99') continue;

      final name = props['NAME']?.toString() ?? isoCode;
      final parts = <GeoPolygonPart>[];

      if (geometry['type'] == 'Polygon') {
        parts.add(_parsePolygon(geometry['coordinates'] as List));
      } else if (geometry['type'] == 'MultiPolygon') {
        for (final poly in geometry['coordinates'] as List) {
          parts.add(_parsePolygon(poly as List));
        }
      }

      if (parts.isNotEmpty) {
        countries.add(GeoCountry(isoA3: isoCode, name: name, parts: parts));
      }
    }

    _cache = countries;
    return countries;
  }

  /// Parse a single Polygon coordinate array: [[outer], [hole1], [hole2], ...]
  static GeoPolygonPart _parsePolygon(List rings) {
    final outerRing = _parseRing(rings[0] as List);
    final holes = <List<LatLng>>[];
    for (int i = 1; i < rings.length; i++) {
      holes.add(_parseRing(rings[i] as List));
    }
    return GeoPolygonPart(outerRing: outerRing, holes: holes);
  }

  /// Convert GeoJSON coordinate array to LatLng list.
  /// GeoJSON uses [longitude, latitude]; LatLng uses (latitude, longitude).
  static List<LatLng> _parseRing(List coords) {
    return coords
        .map<LatLng>(
            (c) => LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble()))
        .toList();
  }

  /// Ray-casting point-in-polygon hit test across all countries.
  /// Returns the ISO_A3 code of the country containing [point], or null.
  static String? hitTest(LatLng point, List<GeoCountry> countries) {
    for (final country in countries) {
      for (final part in country.parts) {
        if (_pointInPolygon(point, part.outerRing)) {
          // Verify point is not inside a hole
          bool inHole = false;
          for (final hole in part.holes) {
            if (_pointInPolygon(point, hole)) {
              inHole = true;
              break;
            }
          }
          if (!inHole) return country.isoA3;
        }
      }
    }
    return null;
  }

  /// Standard ray-casting algorithm for point-in-polygon test.
  static bool _pointInPolygon(LatLng point, List<LatLng> polygon) {
    bool inside = false;
    final int n = polygon.length;
    final double px = point.longitude;
    final double py = point.latitude;

    for (int i = 0, j = n - 1; i < n; j = i++) {
      final double xi = polygon[i].longitude;
      final double yi = polygon[i].latitude;
      final double xj = polygon[j].longitude;
      final double yj = polygon[j].latitude;

      if (((yi > py) != (yj > py)) &&
          (px < (xj - xi) * (py - yi) / (yj - yi) + xi)) {
        inside = !inside;
      }
    }
    return inside;
  }

  /// Clear the cache (useful for testing or memory management).
  static void clearCache() {
    _cache = null;
  }
}
