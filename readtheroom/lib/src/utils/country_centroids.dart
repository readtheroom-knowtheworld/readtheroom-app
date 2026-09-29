// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';
import 'package:flutter/services.dart' show rootBundle;
import 'package:latlong2/latlong.dart';

/// Loads the bundled `country_centroids.json` asset — a precomputed map of
/// ISO_A3 country code → representative centroid point. Used as the fallback
/// location for responses that have no `city_id`, so every response lands
/// somewhere on the dot map without hit-testing polygons at runtime.
///
/// Same key convention as [GeoJsonParser]: ISO_A3, falling back to ADM0_A3
/// where ISO_A3 is "-99".
class CountryCentroids {
  CountryCentroids._();

  static Map<String, LatLng>? _cache;
  static Map<String, String>? _names;

  /// Load and parse the centroid asset. Cached after first call.
  static Future<void> load() async {
    if (_cache != null) return;
    try {
      final jsonStr =
          await rootBundle.loadString('assets/country_centroids.json');
      final Map<String, dynamic> data = json.decode(jsonStr);
      final cache = <String, LatLng>{};
      final names = <String, String>{};
      data.forEach((iso, value) {
        if (value is Map) {
          final lat = (value['lat'] as num?)?.toDouble();
          final lng = (value['lng'] as num?)?.toDouble();
          if (lat != null && lng != null) {
            cache[iso] = LatLng(lat, lng);
            final name = value['name']?.toString();
            if (name != null) names[iso] = name;
          }
        }
      });
      _cache = cache;
      _names = names;
    } catch (e) {
      // Leave caches empty on failure; callers treat a missing centroid as
      // an unplaceable response (skipped) rather than crashing.
      _cache = {};
      _names = {};
    }
  }

  /// Centroid for an ISO_A3 code, or null if unknown / not yet loaded.
  static LatLng? of(String? isoA3) {
    if (isoA3 == null || _cache == null) return null;
    return _cache![isoA3];
  }

  /// Human-readable country name for an ISO_A3 code from the asset.
  static String? nameOf(String? isoA3) {
    if (isoA3 == null || _names == null) return null;
    return _names![isoA3];
  }

  static bool get isLoaded => _cache != null;
}
