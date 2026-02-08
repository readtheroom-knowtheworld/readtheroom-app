// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

// lib/src/utils/location_persistence.dart
import 'package:shared_preferences/shared_preferences.dart';
import '../widgets/location_filter_dialog.dart';

class LocationPersistence {
  static const String _locationFilterKey = 'location_filter_type';

  /// Save the selected location filter type to SharedPreferences
  static Future<void> saveLocationFilter(LocationFilterType filterType) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_locationFilterKey, filterType.name);
  }

  /// Load the saved location filter type from SharedPreferences
  /// Returns LocationFilterType.global as default for new users
  static Future<LocationFilterType> loadLocationFilter() async {
    final prefs = await SharedPreferences.getInstance();
    final filterString = prefs.getString(_locationFilterKey);
    
    if (filterString == null) {
      return LocationFilterType.global; // Default for new users
    }
    
    // Convert string back to enum
    switch (filterString) {
      case 'global':
        return LocationFilterType.global;
      case 'country':
        return LocationFilterType.country;
      case 'city':
        return LocationFilterType.city;
      default:
        return LocationFilterType.global; // Fallback to default
    }
  }

  /// Clear the saved location filter (useful for debugging or reset)
  static Future<void> clearLocationFilter() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_locationFilterKey);
  }

  /// Check if a location filter has been previously saved
  static Future<bool> hasLocationFilter() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.containsKey(_locationFilterKey);
  }
}