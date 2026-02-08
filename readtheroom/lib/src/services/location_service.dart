// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import '../data/countries_data.dart';
import 'analytics_service.dart';

class LocationService extends ChangeNotifier {
  final _supabase = Supabase.instance.client;
  Map<String, List<Map<String, dynamic>>> _citiesByCountry = {}; // Cache cities by country code
  Map<String, dynamic>? _selectedCity;
  String? _selectedCountry;
  bool _isLoading = false;
  bool _isInitialized = false;
  late SharedPreferences _prefs;
  static const String _selectedCityKey = 'selected_city';
  static const String _selectedCountryKey = 'selected_country';
  
  // Cache for country name to country code mapping
  Map<String, String> _countryNameToCodeCache = {};
  bool _countryCacheLoaded = false;
  
  // Cache for all country names from database
  List<String> _databaseCountries = [];
  bool _databaseCountriesLoaded = false;

  Map<String, dynamic>? get selectedCity => _selectedCity;
  String? get selectedCountry => _selectedCountry;
  Map<String, dynamic>? get userLocation {
    if (_selectedCity != null) {
      return _selectedCity;
    } else if (_selectedCountry != null) {
      return {
        'country_name_en': _selectedCountry,
        'country_code': _getCountryCodeFromCache(_selectedCountry!),
      };
    }
    return null;
  }
  bool get isLoading => _isLoading;
  List<Map<String, dynamic>> get cities {
    // Return all cached cities for backward compatibility
    final allCities = <Map<String, dynamic>>[];
    for (final cities in _citiesByCountry.values) {
      allCities.addAll(cities);
    }
    return allCities;
  }
  bool get isInitialized => _isInitialized;
  bool get hasLocation => _selectedCity != null || _selectedCountry != null;
  bool get hasCity => _selectedCity != null;

  LocationService();

  Future<void> _loadSavedLocation() async {
    _prefs = await SharedPreferences.getInstance();
    await _loadSelectedCity();
    await _loadSelectedCountry();
  }

  // Load cities for a specific country code (filtered and sorted by population)
  Future<List<Map<String, dynamic>>> loadCitiesForCountry(String countryCode) async {
    // Check cache first
    if (_citiesByCountry.containsKey(countryCode)) {
      return _citiesByCountry[countryCode]!;
    }

    try {
      print('Loading cities for country code: $countryCode');
      final response = await _supabase
          .from('cities')
          .select('id, ascii_name, country_code, country_name_en, population, lat, lng, admin1_code, admin2_code, timezone')
          .eq('country_code', countryCode)
          .not('ascii_name', 'is', null)
          .neq('ascii_name', '') // Also filter out empty strings
          .order('population', ascending: false)
          .limit(100); // Top 100 cities by population per country
      
      final cities = List<Map<String, dynamic>>.from(response.map((city) => {
        'id': city['id'],
        'name': _formatCityNameWithState(city['ascii_name'], city['admin1_code']), // Use formatted name with state/province
        'display_name': city['ascii_name'], // Keep original name for internal use
        'country_name_en': city['country_name_en'] ?? _getCountryNameFromCode(city['country_code'] ?? ''),
        'country_code': city['country_code'],
        'population': city['population'] ?? 0,
        'lat': city['lat']?.toDouble(),
        'lng': city['lng']?.toDouble(),
        'admin1_code': city['admin1_code'],
        'admin2_code': city['admin2_code'],
        'timezone': city['timezone'],
      }).where((city) => city['display_name'] != null && city['display_name'].toString().trim().isNotEmpty)); // Additional client-side filtering
      
      // Cache the results
      _citiesByCountry[countryCode] = cities;
      print('Loaded ${cities.length} cities for $countryCode (sorted by population, using ASCII names, filtered for null safety)');
      return cities;
      
    } catch (e) {
      print('Error loading cities for country $countryCode: $e');
      return [];
    }
  }

  Future<void> _loadSelectedCity() async {
    final cityJson = _prefs.getString(_selectedCityKey);
    if (cityJson != null) {
      try {
        final loadedCity = Map<String, dynamic>.from(json.decode(cityJson));
        
        // Validate that the loaded city has a valid name
        final cityName = loadedCity['name']?.toString().trim();
        if (cityName == null || cityName.isEmpty) {
          print('Warning: Loaded city has null or empty name, clearing selection');
          await _prefs.remove(_selectedCityKey);
          return;
        }
        
        _selectedCity = loadedCity;
        
        // Ensure the loaded city has an ID (for backward compatibility)
        if (_selectedCity!['id'] == null) {
          _selectedCity!['id'] = _generateCityId(
            _selectedCity!['name'],
            _selectedCity!['country_name_en']
          );
          // Save the updated city with ID
          _saveSelectedCity();
        }
      } catch (e) {
        print('Error loading saved city: $e');
        // Clear invalid city data
        await _prefs.remove(_selectedCityKey);
      }
    }
  }

  Future<void> _loadSelectedCountry() async {
    _selectedCountry = _prefs.getString(_selectedCountryKey);
  }

  Future<void> _saveSelectedCity() async {
    if (_selectedCity != null) {
      await _prefs.setString(_selectedCityKey, json.encode(_selectedCity));
    } else {
      await _prefs.remove(_selectedCityKey);
    }
  }

  Future<void> _saveSelectedCountry() async {
    if (_selectedCountry != null) {
      await _prefs.setString(_selectedCountryKey, _selectedCountry!);
    } else {
      await _prefs.remove(_selectedCountryKey);
    }
  }

  Future<void> initialize() async {
    if (_isInitialized) return;
    
    try {
      print('Initializing LocationService...');
      
      // Skip loading countries during initialization for faster startup
      // Countries will be loaded lazily when needed (search, location lookup, etc.)
      
      await _loadSavedLocation();
      _isInitialized = true;
      notifyListeners();
      print('LocationService initialized successfully');
    } catch (e) {
      print('Error initializing LocationService: $e');
      _isInitialized = true; // Mark as initialized even on error to prevent infinite loops
      notifyListeners();
    }
  }

  // Deprecated - kept for backward compatibility
  Future<void> _loadCitiesSilently() async {
    // No longer loads all cities - cities are loaded on demand by country
    print('Cities are now loaded on-demand by country for better performance');
  }

  // Deprecated - kept for backward compatibility  
  Future<void> loadCities() async {
    // No longer loads all cities - cities are loaded on demand by country
    print('Cities are now loaded on-demand by country for better performance');
  }

  Future<Map<String, dynamic>?> getCurrentCity() async {
    if (!_isInitialized) {
      await initialize();
    }
    return _selectedCity;
  }

  void setSelectedCity(Map<String, dynamic> city) {
    // Validate that the city has a valid name (ASCII name)
    final cityName = city['name']?.toString().trim();
    if (cityName == null || cityName.isEmpty) {
      print('Warning: Attempting to set city with null or empty name');
      return;
    }
    
    // Ensure the city has an ID
    if (city['id'] == null) {
      city = Map<String, dynamic>.from(city);
      city['id'] = _generateCityId(city['name'], city['country_name_en']);
    }
    
    _selectedCity = city;
    _selectedCountry = city['country_name_en'];
    _saveSelectedCity();
    _saveSelectedCountry();
    
    // Track location change in analytics
    final analytics = AnalyticsService();
    analytics.trackLocationChanged('city', cityName, {
      'country': city['country_name_en'],
      'country_code': city['country_code'],
    });
    
    // Track as part of onboarding if this is during initial setup
    final supabase = Supabase.instance.client;
    if (supabase.auth.currentUser != null) {
      analytics.trackOnboardingStep('location_city', 6, {
        'city': cityName,
        'country': city['country_name_en'],
      });
    }
    
    notifyListeners();
  }

  void clearSelectedCity() {
    _selectedCity = null;
    _saveSelectedCity();
    notifyListeners();
  }

  void clearSelectedCountry() {
    _selectedCountry = null;
    _selectedCity = null;
    _saveSelectedCountry();
    _saveSelectedCity();
    notifyListeners();
  }

  List<Map<String, dynamic>> searchCities(String query) {
    if (query.isEmpty) return [];
    
    // Search across all cached cities
    final allCities = cities; // Uses the getter that combines all cached cities
    if (allCities.isEmpty) return [];

    final lowercaseQuery = query.toLowerCase();
    return allCities.where((city) {
      final cityName = city['name']?.toString().toLowerCase() ?? '';
      final countryName = city['country_name_en']?.toString().toLowerCase() ?? '';
      // Only include cities with valid names
      return cityName.isNotEmpty && (cityName.contains(lowercaseQuery) || 
             countryName.contains(lowercaseQuery));
    }).toList();
  }

  List<String> getCountries() {
    // Ensure database countries are loaded, fallback to hardcoded if not
    if (_databaseCountriesLoaded && _databaseCountries.isNotEmpty) {
      return List<String>.from(_databaseCountries);
    } else {
      // Fallback to hardcoded data if database not loaded yet
      return List<String>.from(CountriesData.countries);
    }
  }

  Future<List<Map<String, dynamic>>> getCitiesByCountry(String country) async {
    // Get country code first
    String? countryCode;
    try {
      countryCode = await getCountryCodeForName(country);
    } catch (e) {
      print('Error getting country code from database: $e');
      countryCode = _getCountryCodeFromCache(country);
    }
    
    if (countryCode == null) {
      // Fallback to hardcoded data
      return CountriesData.getCitiesForCountry(country);
    }
    
    // Load cities for this country
    return await loadCitiesForCountry(countryCode);
  }

  Future<List<String>> searchCountries(String query) async {
    if (query.isEmpty) return [];
    
    // Ensure database countries are loaded
    if (!_databaseCountriesLoaded) {
      await _loadCountriesCache();
    }
    
    final lowercaseQuery = query.toLowerCase();
    final countries = _databaseCountriesLoaded && _databaseCountries.isNotEmpty 
        ? _databaseCountries 
        : CountriesData.countries;
    
    final results = countries
        .where((country) => country.toLowerCase().contains(lowercaseQuery))
        .toList();
    
    print('Country search for "$query" found ${results.length} matches (using ${_databaseCountriesLoaded ? 'database' : 'hardcoded'} data)');
    return results;
  }

  void setSelectedCountry(String country) {
    // If we have a selected city, check if it belongs to the new country
    if (_selectedCity != null) {
      final cityCountry = _selectedCity!['country_name_en'];
      if (cityCountry != null && cityCountry != country) {
        // Clear the city if it doesn't belong to the new country
        print('Clearing city ${_selectedCity!['name']} as it does not belong to $country');
        _selectedCity = null;
        _saveSelectedCity();
      }
    }
    
    _selectedCountry = country;
    _saveSelectedCountry();
    
    // Track location change in analytics
    final analytics = AnalyticsService();
    analytics.trackLocationChanged('country', country, {
      'country_code': _getCountryCodeFromCache(country),
    });
    
    // Track as part of onboarding if this is during initial setup
    final supabase = Supabase.instance.client;
    if (supabase.auth.currentUser != null) {
      analytics.trackOnboardingStep('location_country', 5, {
        'country': country,
      });
    }
    
    notifyListeners();
  }

  // Load all countries from database and cache the name -> code mapping
  Future<void> _loadCountriesCache() async {
    if (_countryCacheLoaded) return;
    
    try {
      print('Loading countries mapping from database...');
      final response = await _supabase
          .from('countries')
          .select('country_name_en, country_code')
          .not('country_name_en', 'is', null)
          .not('country_code', 'is', null)
          .order('country_name_en'); // Sort alphabetically
      
      _countryNameToCodeCache.clear();
      _databaseCountries.clear();
      
      for (final country in response) {
        final name = country['country_name_en'] as String;
        final code = country['country_code'] as String;
        if (name.isNotEmpty && code.isNotEmpty) {
          _countryNameToCodeCache[name] = code;
          _databaseCountries.add(name);
        }
      }
      
      _countryCacheLoaded = true;
      _databaseCountriesLoaded = true;
      print('Loaded ${_countryNameToCodeCache.length} countries from database');
      
      // Debug: Check if common countries are present
      final commonCountries = ['Hong Kong', 'United States of America', 'United Kingdom', 'Canada', 'Australia'];
      for (final country in commonCountries) {
        if (_countryNameToCodeCache.containsKey(country)) {
          print('✓ Found "$country" in database');
        } else {
          print('✗ Missing "$country" in database');
        }
      }
      
    } catch (e) {
      print('Error loading countries from database: $e');
      // Fallback to hardcoded data if database fails
      _databaseCountries = List<String>.from(CountriesData.countries);
      _databaseCountriesLoaded = true;
      
      // Fallback to a minimal hardcoded mapping for essential countries
      _countryNameToCodeCache = {
        'United States of America': 'US',
        'United States': 'US',
        'USA': 'US',
        'United Kingdom': 'GB',
        'UK': 'GB',
        'Great Britain': 'GB',
        'Canada': 'CA',
        'Australia': 'AU',
        'Germany': 'DE',
        'Deutschland': 'DE',
        'France': 'FR',
        'Japan': 'JP',
        'China': 'CN',
        'People\'s Republic of China': 'CN',
        'India': 'IN',
        'Brazil': 'BR',
        'Brasil': 'BR',
        'Russia': 'RU',
        'Russian Federation': 'RU',
        'Mexico': 'MX',
        'Italy': 'IT',
        'Spain': 'ES',
        'Netherlands': 'NL',
        'Switzerland': 'CH',
        'Sweden': 'SE',
        'Norway': 'NO',
        'Denmark': 'DK',
        'Finland': 'FI',
        'South Korea': 'KR',
        'Republic of Korea': 'KR',
        'Oman': 'OM',
        'Hong Kong': 'HK', // Add Hong Kong to fallback
      };
      _countryCacheLoaded = true;
      print('Fallback: Using hardcoded country data with Hong Kong included');
    }
  }

  // Get country code from cache
  String? _getCountryCodeFromCache(String countryName) {
    return _countryNameToCodeCache[countryName];
  }

  // Get country code from country name using the database cache
  Future<String?> getCountryCodeForName(String countryName) async {
    print('Looking up country code for: "$countryName"');
    
    // Ensure countries cache is loaded
    if (!_countryCacheLoaded) {
      await _loadCountriesCache();
    }
    
    // Try exact match first
    String? code = _getCountryCodeFromCache(countryName);
    if (code != null) {
      print('Found exact match for "$countryName": $code');
      return code;
    }
    
    // Try case-insensitive search
    final lowerQuery = countryName.toLowerCase();
    for (final entry in _countryNameToCodeCache.entries) {
      if (entry.key.toLowerCase() == lowerQuery) {
        print('Found case-insensitive match for "$countryName": ${entry.value}');
        return entry.value;
      }
    }
    
    // Try partial matching for common variations
    final variations = [
      countryName.replaceAll(' of America', ''),
      countryName.replaceAll('United States of America', 'United States'),
      countryName.replaceAll('United Kingdom', 'UK'),
      countryName.replaceAll('Russian Federation', 'Russia'),
      countryName.replaceAll('Republic of Korea', 'South Korea'),
      countryName.replaceAll('People\'s Republic of China', 'China'),
    ];
    
    for (final variation in variations) {
      if (variation != countryName) {
        code = _getCountryCodeFromCache(variation);
        if (code != null) {
          print('Found variation match for "$countryName" -> "$variation": $code');
          // Cache this variation for future use
          _countryNameToCodeCache[countryName] = code;
          return code;
        }
      }
    }
    
    // If not found in cache, try querying database directly with multiple name variations
    final searchNames = [countryName, ...variations].toSet().toList();
    
    for (final searchName in searchNames) {
      try {
        print('Trying database query for: "$searchName"');
        final response = await _supabase
            .from('countries')
            .select('country_code')
            .eq('country_name_en', searchName)
            .maybeSingle(); // Use maybeSingle instead of single to avoid exceptions
        
        if (response != null) {
          final code = response['country_code'] as String?;
          if (code != null && code.isNotEmpty) {
            print('Found database match for "$searchName": $code');
            // Add both the original name and the found variation to cache
            _countryNameToCodeCache[countryName] = code;
            _countryNameToCodeCache[searchName] = code;
            return code;
          }
        }
      } catch (e) {
        print('Database query failed for "$searchName": $e');
      }
    }
    
    print('No country code found for "$countryName" after trying all variations');
    return null;
  }

  // Refresh the countries cache from database
  Future<void> refreshCountriesCache() async {
    _countryCacheLoaded = false;
    await _loadCountriesCache();
    notifyListeners();
  }

  Future<List<Map<String, dynamic>>> searchCitiesInCountry(String query, String country) async {
    if (query.isEmpty || query.length < 3) {
      // Only search after user types 3+ characters for better performance and more targeted results
      return [];
    }

    // Get country code first
    String? countryCode;
    try {
      countryCode = await getCountryCodeForName(country);
    } catch (e) {
      print('Error getting country code from database: $e');
      countryCode = _getCountryCodeFromCache(country);
    }
    
    if (countryCode == null) {
      print('Warning: No country code found for "$country"');
      return [];
    }

    print('Searching cities in $country (code: $countryCode) for "$query" (${query.length} chars)');

    try {
      // Direct database search with the user's query - no pre-loading needed
      final lowercaseQuery = query.toLowerCase();
      final response = await _supabase
          .from('cities')
          .select('id, ascii_name, country_code, country_name_en, population, lat, lng, admin1_code, admin2_code, timezone')
          .eq('country_code', countryCode)
          .not('ascii_name', 'is', null)
          .neq('ascii_name', '')
          .ilike('ascii_name', '%$query%') // Case-insensitive search
          .order('population', ascending: false)
          .limit(500); // Allow many more results - up to 500 cities

      final cities = List<Map<String, dynamic>>.from(response.map((city) => {
        'id': city['id'],
        'name': _formatCityNameWithState(city['ascii_name'], city['admin1_code']),
        'display_name': city['ascii_name'], // Keep original name for internal use
        'country_name_en': city['country_name_en'] ?? _getCountryNameFromCode(city['country_code'] ?? ''),
        'country_code': city['country_code'],
        'population': city['population'] ?? 0,
        'lat': city['lat']?.toDouble(),
        'lng': city['lng']?.toDouble(),
        'admin1_code': city['admin1_code'],
        'admin2_code': city['admin2_code'],
        'timezone': city['timezone'],
      }).where((city) => city['display_name'] != null && city['display_name'].toString().trim().isNotEmpty));

      print('Direct search for "$query" in $country returned ${cities.length} cities');
      return cities;

    } catch (e) {
      print('Error searching cities for "$query" in $country: $e');
      return [];
    }
  }

  // Get all available cities for a country (for showing what's available)
  Future<List<Map<String, dynamic>>> getAvailableCitiesForCountry(String country) async {
    // Get country code first
    String? countryCode;
    try {
      countryCode = await getCountryCodeForName(country);
    } catch (e) {
      print('Error getting country code from database: $e');
      countryCode = _getCountryCodeFromCache(country);
    }
    
    if (countryCode == null) {
      print('Warning: No country code found for "$country"');
      return [];
    }
    
    // Load and return cities for this country (sorted by population)
    return await loadCitiesForCountry(countryCode);
  }

  // Generate a deterministic UUID-like ID from city name and country
  String _generateCityId(String cityName, String countryName) {
    // Create a deterministic hash-based ID (using ASCII city name)
    final combined = '$cityName-$countryName';
    final hash = combined.hashCode.abs();
    
    // Format as UUID-like string (not a real UUID, but database-compatible)
    final hex = hash.toRadixString(16).padLeft(8, '0');
    return '${hex.substring(0, 8)}-${hex.substring(0, 4)}-${hex.substring(0, 4)}-${hex.substring(0, 4)}-${hex.padRight(12, '0').substring(0, 12)}';
  }

  // Helper method to format city name with state/province when admin1_code is not numeric
  String _formatCityNameWithState(String cityName, String? admin1Code) {
    if (admin1Code == null || admin1Code.isEmpty) {
      return cityName;
    }
    
    // Check if admin1_code is numeric (like "01", "02", etc.)
    final isNumeric = RegExp(r'^[0-9]+$').hasMatch(admin1Code);
    if (isNumeric) {
      return cityName; // Don't include numeric codes
    }
    
    // Include non-numeric admin1_code (like state abbreviations: "CA", "NY", "TX")
    return '$cityName, $admin1Code';
  }

  // Helper method to get country name from country code
  String _getCountryNameFromCode(String countryCode) {
    // Try ISO_A3 first
    String countryName = CountriesData.getCountryNameFromIso(countryCode.toUpperCase());
    if (countryName.isNotEmpty) {
      return countryName;
    }
    
    // Fallback for common ISO_A2 codes
    final iso2ToName = {
      'US': 'United States of America',
      'GB': 'United Kingdom',
      'CA': 'Canada',
      'AU': 'Australia',
      'DE': 'Germany',
      'FR': 'France',
      'JP': 'Japan',
      'CN': 'China',
      'IN': 'India',
      'BR': 'Brazil',
      'OM': 'Oman',
    };
    
    return iso2ToName[countryCode.toUpperCase()] ?? countryCode;
  }

  // Method to refresh cities from database (clears cache and reloads)
  Future<void> refreshCities() async {
    _citiesByCountry.clear();
    notifyListeners();
  }
  
  // Method to refresh cities for a specific country
  Future<void> refreshCitiesForCountry(String country) async {
    final countryCode = await getCountryCodeForName(country);
    if (countryCode != null) {
      _citiesByCountry.remove(countryCode);
      await loadCitiesForCountry(countryCode);
      notifyListeners();
    }
  }
} 