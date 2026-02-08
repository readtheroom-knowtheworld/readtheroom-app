// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:supabase_flutter/supabase_flutter.dart';

class CountryService {
  static final _supabase = Supabase.instance.client;
  static Map<String, String>? _countryToIsoCache;
  static Map<String, String>? _isoToCountryCache;

  /// Get ISO_A3 code for a country name from the database
  static Future<String?> getIsoCodeForCountry(String countryName) async {
    // Check cache first
    if (_countryToIsoCache?.containsKey(countryName) == true) {
      return _countryToIsoCache![countryName];
    }
    
    try {
      final response = await _supabase
          .from('countries')
          .select('iso3_code')
          .eq('country_name_en', countryName)
          .maybeSingle();
      
      if (response != null && response['iso3_code'] != null) {
        // Cache the result
        _countryToIsoCache ??= {};
        _countryToIsoCache![countryName] = response['iso3_code'];
        return response['iso3_code'];
      }
      
      // Try common variations if exact match fails
      final variations = _getCountryVariations(countryName);
      for (String variation in variations) {
        final variationResponse = await _supabase
            .from('countries')
            .select('iso3_code')
            .eq('country_name_en', variation)
            .maybeSingle();
        
        if (variationResponse != null && variationResponse['iso3_code'] != null) {
          // Cache both the original name and variation
          _countryToIsoCache ??= {};
          _countryToIsoCache![countryName] = variationResponse['iso3_code'];
          _countryToIsoCache![variation] = variationResponse['iso3_code'];
          return variationResponse['iso3_code'];
        }
      }
      
      print('No ISO3 code found for country: "$countryName"');
      return null;
    } catch (e) {
      print('Error getting ISO code for country "$countryName": $e');
      return null;
    }
  }

  /// Get country name from ISO_A3 code
  static Future<String?> getCountryNameFromIso(String isoCode) async {
    // Check cache first
    if (_isoToCountryCache?.containsKey(isoCode) == true) {
      return _isoToCountryCache![isoCode];
    }
    
    try {
      final response = await _supabase
          .from('countries')
          .select('country_name_en')
          .eq('iso3_code', isoCode)
          .maybeSingle();
      
      if (response != null && response['country_name_en'] != null) {
        // Cache the result
        _isoToCountryCache ??= {};
        _isoToCountryCache![isoCode] = response['country_name_en'];
        return response['country_name_en'];
      }
      
      return null;
    } catch (e) {
      print('Error getting country name for ISO code "$isoCode": $e');
      return null;
    }
  }

  /// Preload all country mappings for better performance
  static Future<void> preloadCountryMappings() async {
    try {
      final response = await _supabase
          .from('countries')
          .select('country_name_en, iso3_code')
          .not('iso3_code', 'is', null);
      
      if (response != null) {
        _countryToIsoCache = {};
        _isoToCountryCache = {};
        
        for (var row in response) {
          final countryName = row['country_name_en'] as String;
          final isoCode = row['iso3_code'] as String;
          
          _countryToIsoCache![countryName] = isoCode;
          _isoToCountryCache![isoCode] = countryName;
        }
        
        print('Preloaded ${_countryToIsoCache!.length} country mappings');
      }
    } catch (e) {
      print('Error preloading country mappings: $e');
    }
  }

  /// Get all countries with their ISO codes from the database
  static Future<List<String>> getAllCountries() async {
    try {
      final response = await _supabase
          .from('countries')
          .select('country_name_en')
          .not('iso3_code', 'is', null)
          .order('country_name_en');
      
      if (response != null) {
        return response.map((row) => row['country_name_en'] as String).toList();
      }
      
      return [];
    } catch (e) {
      print('Error getting all countries: $e');
      return [];
    }
  }

  /// Clear the cache (useful for testing or when data changes)
  static void clearCache() {
    _countryToIsoCache = null;
    _isoToCountryCache = null;
  }

  /// Get common variations of country names
  static List<String> _getCountryVariations(String countryName) {
    final variations = <String>[];
    final lower = countryName.toLowerCase();

    // United States variations
    if (lower.contains('united states') || lower == 'usa' || lower == 'us' || lower == 'america') {
      variations.addAll(['United States of America', 'United States', 'USA', 'US', 'America']);
    }
    
    // United Kingdom variations
    if (lower.contains('united kingdom') || lower == 'uk' || lower == 'britain' || lower == 'great britain' || lower == 'england') {
      variations.addAll(['United Kingdom', 'UK', 'Britain', 'Great Britain', 'England']);
    }
    
    // China variations
    if (lower.contains('china') || lower == 'prc') {
      variations.addAll(['China', 'People\'s Republic of China', 'PRC']);
    }
    
    // Iran variations
    if (lower.contains('iran') || lower.contains('persia')) {
      variations.addAll(['Iran', 'Islamic Republic of Iran', 'Persia']);
    }
    
    // Russia variations
    if (lower.contains('russia') || lower.contains('russian federation')) {
      variations.addAll(['Russia', 'Russian Federation']);
    }
    
    // Syria variations
    if (lower.contains('syria') || lower.contains('syrian arab republic')) {
      variations.addAll(['Syria', 'Syrian Arab Republic']);
    }
    
    // Venezuela variations
    if (lower.contains('venezuela')) {
      variations.addAll(['Venezuela', 'Bolivarian Republic of Venezuela']);
    }

    // Czech Republic variations
    if (lower.contains('czech')) {
      variations.addAll(['Czech Republic', 'Czechia']);
    }

    // Hong Kong variations
    if (lower.contains('hong kong')) {
      variations.addAll(['Hong Kong', 'Hong Kong SAR China', 'Hong Kong, China']);
    }

    // Taiwan variations
    if (lower.contains('taiwan')) {
      variations.addAll(['Taiwan', 'Taiwan, Province of China', 'Chinese Taipei']);
    }

    // Macau variations
    if (lower.contains('macau') || lower.contains('macao')) {
      variations.addAll(['Macau', 'Macao', 'Macau SAR China', 'Macao SAR China']);
    }

    return variations.where((v) => v != countryName).toList();
  }
} 