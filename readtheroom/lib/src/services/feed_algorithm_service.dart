// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:math' as math;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'location_service.dart';
import 'user_service.dart';

class FeedAlgorithmService {
  final _supabase = Supabase.instance.client;
  static const Duration _cacheDuration = Duration(minutes: 5);
  
  // Cache for region user counts
  Map<String, int> _regionUserCounts = {};
  DateTime? _lastCacheUpdate;

  // Load region user counts from database
  Future<void> _loadRegionUserCounts() async {
    final now = DateTime.now();
    
    // Check if cache is still valid
    if (_lastCacheUpdate != null && 
        now.difference(_lastCacheUpdate!) < _cacheDuration) {
      return;
    }

    try {
      final response = await _supabase
          .from('region_user_counts')
          .select('region_type, region_code, user_count');

      _regionUserCounts.clear();
      for (var row in response) {
        final key = '${row['region_type']}_${row['region_code']}';
        _regionUserCounts[key] = row['user_count'] as int;
      }
      
      _lastCacheUpdate = now;
      print('Loaded ${_regionUserCounts.length} region user counts');
    } catch (e) {
      print('Error loading region user counts: $e');
      // Use default values if database is unavailable
      _setDefaultRegionCounts();
    }
  }

  void _setDefaultRegionCounts() {
    _regionUserCounts = {
      'global_global': 1000,
      'country_US': 400,
      'country_CA': 150,
      'country_GB': 200,
      'country_DE': 180,
      'country_FR': 160,
      'country_AU': 120,
      'country_JP': 250,
      'city_New York': 50,
      'city_Los Angeles': 40,
      'city_London': 35,
      'city_Toronto': 25,
      'city_Sydney': 20,
      'city_Berlin': 30,
      'city_Paris': 28,
      'city_Tokyo': 45,
    };
  }

  // Calculate scope weight based on question targeting
  double _getScopeWeight(String? targetingType, Map<String, dynamic> question) {
    switch (targetingType?.toLowerCase()) {
      case 'city':
        return 1.0;
      case 'country':
        return 0.7;
      case 'globe':
      case 'global':
      default:
        // Check if question has mentioned countries - treat as country-level
        final mentionedCountries = question['mentioned_countries'] as List<dynamic>?;
        if (mentionedCountries != null && mentionedCountries.isNotEmpty) {
          return 0.7; // Same as country-targeted questions
        }
        return 0.3; // Global questions
    }
  }

  // Calculate region scale factor
  double _getRegionScale(String regionType, String regionCode) {
    final globalUsers = _regionUserCounts['global_global'] ?? 1000;
    final regionUsers = _regionUserCounts['${regionType}_$regionCode'] ?? 1;
    
    // Calculate logarithmic scale: log10((global_users / region_users) + 1)
    return math.log(globalUsers / regionUsers + 1) / math.ln10;
  }

  // Calculate match boost based on user location and question targeting
  double _getMatchBoost(
    Map<String, dynamic>? userLocation,
    Map<String, dynamic>? selectedCity,
    Map<String, dynamic> question,
  ) {
    if (userLocation == null) return 1.0;

    final userCountryCode = userLocation['country_code'] as String?;
    final userCountryName = userLocation['country_name_en'] as String?;
    final userCityName = selectedCity?['name'] as String?;
    final userAdmin2 = selectedCity?['admin2_code'] as String?;

    final questionCountryCode = question['country_code'] as String?;
    final questionCityId = question['city_id'] as String?;

    // For city-targeted questions, check if we have city details
    if (questionCityId != null && userCityName != null) {
      // In a real implementation, you'd look up the city details
      // For now, we'll assume the city names match if they're equal
      
      // Exact city match (highest boost)
      if (userCityName == question['city_name']) {
        return 2.0;
      }
      
      // Admin2 match (county/district level)
      if (userAdmin2 != null && userAdmin2 == question['admin2_code']) {
        return 1.5;
      }
    }

    // Country match (for country-targeted questions)
    if (userCountryCode != null && 
        questionCountryCode != null && 
        userCountryCode == questionCountryCode) {
      return 1.2;
    }

    // Check for mentioned countries (questions with @country in description)
    final mentionedCountries = question['mentioned_countries'] as List<dynamic>?;
    if (mentionedCountries != null && mentionedCountries.isNotEmpty && userCountryName != null) {
      final isCountryMentioned = mentionedCountries.any((country) => 
        country.toString().toLowerCase() == userCountryName.toLowerCase());
      if (isCountryMentioned) {
        return 1.2; // Same boost as country-targeted questions
      }
    }

    // No match
    return 1.0;
  }

  // Calculate locality boost
  double _getLocalityBoost(
    bool boostLocalActivity,
    Map<String, dynamic>? userLocation,
    Map<String, dynamic>? selectedCity,
    Map<String, dynamic> question,
  ) {
    if (!boostLocalActivity) {
      return 1.0; // No boost when setting is disabled
    }

    final matchBoost = _getMatchBoost(userLocation, selectedCity, question);
    
    // Determine the region for scale calculation
    String regionType = 'global';
    String regionCode = 'global';
    
    final questionTargeting = question['targeting_type']?.toString().toLowerCase();
    
    if (questionTargeting == 'city' && question['city_name'] != null) {
      regionType = 'city';
      regionCode = question['city_name'];
    } else if (questionTargeting == 'country' && question['country_code'] != null) {
      regionType = 'country';
      regionCode = question['country_code'];
    } else {
      // Check for mentioned countries
      final mentionedCountries = question['mentioned_countries'] as List<dynamic>?;
      if (mentionedCountries != null && mentionedCountries.isNotEmpty) {
        regionType = 'country';
        // For mentioned countries, we need to map country name to country code
        // For now, use a simplified approach - we could enhance this later
        final firstMentionedCountry = mentionedCountries.first.toString();
        regionCode = firstMentionedCountry; // This could be improved with name->code mapping
      }
    }

    final regionScale = _getRegionScale(regionType, regionCode);
    
    return matchBoost * regionScale;
  }

  // Calculate trending score
  double _calculateTrendingScore(
    Map<String, dynamic> question,
    bool boostLocalActivity,
    Map<String, dynamic>? userLocation,
    Map<String, dynamic>? selectedCity,
  ) {
    final voteCount = (question['votes'] as num?)?.toDouble() ?? 0.0;
    final createdAt = DateTime.tryParse(question['created_at']?.toString() ?? '') ?? DateTime.now();
    final hoursSincePost = DateTime.now().difference(createdAt).inMinutes / 60.0;
    
    final scopeWeight = _getScopeWeight(question['targeting_type']?.toString(), question);
    final localityBoost = _getLocalityBoost(boostLocalActivity, userLocation, selectedCity, question);
    
    // Prevent division by zero
    final timeDecay = 1.0 / (1.0 + hoursSincePost);
    
    // Add recency boost for new questions with low votes
    double recencyBoost = 0.0;
    if (hoursSincePost <= 24.0) { // Questions posted in last 24 hours
      // Give a base recency boost that decays over time
      final maxRecencyBoost = localityBoost > 1.0 ? 2.0 : 1.0; // Higher boost for local questions
      recencyBoost = maxRecencyBoost * math.exp(-hoursSincePost / 8.0); // Decays over ~8 hours
      
      // Extra boost for questions with very few votes
      if (voteCount <= 2.0) {
        recencyBoost *= 1.5; // 50% extra boost for questions with 0-2 votes
      }
    }
    
    // Base score from votes
    final baseScore = voteCount * timeDecay * scopeWeight * localityBoost;
    
    // Add recency boost (scaled by scope and locality factors)
    final recencyScore = recencyBoost * scopeWeight * localityBoost;
    
    return baseScore + recencyScore;
  }

  // Calculate popularity score
  double _calculatePopularityScore(
    Map<String, dynamic> question,
    bool boostLocalActivity,
    Map<String, dynamic>? userLocation,
    Map<String, dynamic>? selectedCity,
  ) {
    final voteCount = (question['votes'] as num?)?.toDouble() ?? 0.0;
    final createdAt = DateTime.tryParse(question['created_at']?.toString() ?? '') ?? DateTime.now();
    final hoursSincePost = DateTime.now().difference(createdAt).inMinutes / 60.0;
    
    final scopeWeight = _getScopeWeight(question['targeting_type']?.toString(), question);
    final localityBoost = _getLocalityBoost(boostLocalActivity, userLocation, selectedCity, question);
    
    // Base score from votes
    final baseScore = voteCount * scopeWeight * localityBoost;
    
    // Add a smaller recency boost for popular feed (we still want to help new content)
    double recencyBoost = 0.0;
    if (hoursSincePost <= 12.0 && voteCount <= 1.0) { // Only very new questions with 0-1 votes
      final maxRecencyBoost = localityBoost > 1.0 ? 1.0 : 0.5; // Smaller boost than trending
      recencyBoost = maxRecencyBoost * math.exp(-hoursSincePost / 4.0); // Shorter decay
      recencyBoost *= scopeWeight * localityBoost;
    }
    
    return baseScore + recencyBoost;
  }

  // Calculate new feed score (for grouped sorting when local boost is on)
  int _calculateNewFeedPriority(
    Map<String, dynamic> question,
    bool boostLocalActivity,
    Map<String, dynamic>? userLocation,
    Map<String, dynamic>? selectedCity,
  ) {
    if (!boostLocalActivity) {
      return 1; // All questions have same priority when boost is off
    }

    final matchBoost = _getMatchBoost(userLocation, selectedCity, question);
    
    // Return priority group (lower number = higher priority)
    if (matchBoost >= 2.0) return 1; // City match
    if (matchBoost >= 1.5) return 2; // Admin2 match
    if (matchBoost >= 1.2) return 3; // Country match (including mentioned countries)
    return 4; // No match
  }

  // Sort questions for trending feed - optimized for smaller datasets
  Future<List<dynamic>> getTrendingFeed(
    List<dynamic> questions,
    LocationService locationService,
    UserService userService,
  ) async {
    // Early return for large datasets - trending should be calculated server-side
    if (questions.length > 500) {
      print('Warning: Large dataset detected (${questions.length} questions). Consider server-side trending calculation.');
      // Fallback to basic recency + votes calculation
      return _simpleTrendingSort(questions.cast<Map<String, dynamic>>());
    }

    await _loadRegionUserCounts();
    
    final typedQuestions = questions.cast<Map<String, dynamic>>();
    final userLocation = locationService.userLocation;
    final selectedCity = locationService.selectedCity;
    final boostLocalActivity = userService.boostLocalActivity;

    // Process in batches to reduce memory pressure
    const batchSize = 100;
    final List<Map<String, dynamic>> sortedQuestions = [];
    
    for (int i = 0; i < typedQuestions.length; i += batchSize) {
      final batch = typedQuestions.skip(i).take(batchSize).toList();
      
      final batchWithScores = batch.map((question) {
        final score = _calculateTrendingScore(question, boostLocalActivity, userLocation, selectedCity);
        return Map<String, dynamic>.from(question)
          ..['_trending_score'] = score;
      }).toList();
      
      sortedQuestions.addAll(batchWithScores);
    }

    // Sort by trending score (descending)
    sortedQuestions.sort((a, b) {
      final scoreA = a['_trending_score'] as double;
      final scoreB = b['_trending_score'] as double;
      return scoreB.compareTo(scoreA);
    });

    return sortedQuestions;
  }

  // Simple trending sort for large datasets
  List<Map<String, dynamic>> _simpleTrendingSort(List<Map<String, dynamic>> questions) {
    final now = DateTime.now();
    
    return questions.map((q) => Map<String, dynamic>.from(q)).toList()
      ..sort((a, b) {
        final aCreatedAt = DateTime.tryParse(a['created_at']?.toString() ?? '') ?? now;
        final bCreatedAt = DateTime.tryParse(b['created_at']?.toString() ?? '') ?? now;
        final aVotes = a['votes'] as int? ?? 0;
        final bVotes = b['votes'] as int? ?? 0;
        
        // Simple trending: recency (70%) + votes (30%)
        final aHoursOld = now.difference(aCreatedAt).inHours;
        final bHoursOld = now.difference(bCreatedAt).inHours;
        
        final aScore = (1.0 / (aHoursOld + 1)) * 0.7 + aVotes * 0.3;
        final bScore = (1.0 / (bHoursOld + 1)) * 0.7 + bVotes * 0.3;
        
        return bScore.compareTo(aScore);
      });
  }

  // Sort questions for popular feed
  Future<List<dynamic>> getPopularFeed(
    List<dynamic> questions,
    LocationService locationService,
    UserService userService,
  ) async {
    await _loadRegionUserCounts();
    
    final typedQuestions = questions.cast<Map<String, dynamic>>();
    final userLocation = locationService.userLocation;
    final selectedCity = locationService.selectedCity;
    final boostLocalActivity = userService.boostLocalActivity;

    // Calculate popularity scores for all questions
    final questionsWithScores = typedQuestions.map((question) {
      final score = _calculatePopularityScore(question, boostLocalActivity, userLocation, selectedCity);
      // Create a clean copy without modifying the original
      return Map<String, dynamic>.from(question)
        ..['_popularity_score'] = score;
    }).toList();

    // Sort by popularity score (descending)
    questionsWithScores.sort((a, b) {
      final scoreA = a['_popularity_score'] as double;
      final scoreB = b['_popularity_score'] as double;
      return scoreB.compareTo(scoreA);
    });

    return questionsWithScores;
  }

  // Sort questions for new feed
  Future<List<dynamic>> getNewFeed(
    List<dynamic> questions,
    LocationService locationService,
    UserService userService,
  ) async {
    await _loadRegionUserCounts();
    
    final typedQuestions = questions.cast<Map<String, dynamic>>();
    final userLocation = locationService.userLocation;
    final selectedCity = locationService.selectedCity;
    final boostLocalActivity = userService.boostLocalActivity;

    if (!boostLocalActivity) {
      // Simple chronological sort when boost is off
      final sorted = typedQuestions.map((q) => Map<String, dynamic>.from(q)).toList();
      sorted.sort((a, b) {
        final aCreatedAt = DateTime.tryParse(a['created_at']?.toString() ?? '') ?? DateTime.now();
        final bCreatedAt = DateTime.tryParse(b['created_at']?.toString() ?? '') ?? DateTime.now();
        return bCreatedAt.compareTo(aCreatedAt);
      });
      return sorted;
    }

    // Grouped sort when boost is on: first by location priority, then by time
    final questionsWithPriority = typedQuestions.map((question) {
      final priority = _calculateNewFeedPriority(question, boostLocalActivity, userLocation, selectedCity);
      final createdAt = DateTime.tryParse(question['created_at']?.toString() ?? '') ?? DateTime.now();
      // Create a clean copy without modifying the original
      return Map<String, dynamic>.from(question)
        ..['_location_priority'] = priority
        ..['_created_at_parsed'] = createdAt;
    }).toList();

    questionsWithPriority.sort((a, b) {
      // First sort by location priority (lower number = higher priority)
      final priorityA = a['_location_priority'] as int;
      final priorityB = b['_location_priority'] as int;
      final priorityComparison = priorityA.compareTo(priorityB);
      
      if (priorityComparison != 0) {
        return priorityComparison;
      }
      
      // Then sort by creation time (newer first)
      final timeA = a['_created_at_parsed'] as DateTime;
      final timeB = b['_created_at_parsed'] as DateTime;
      return timeB.compareTo(timeA);
    });

    return questionsWithPriority;
  }
} 