// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'package:flutter/foundation.dart';

/// Enhanced caching service specifically designed for app startup optimization
/// This service provides intelligent caching during initialization to prevent duplicate work
class StartupCacheService {
  static final StartupCacheService _instance = StartupCacheService._internal();
  factory StartupCacheService() => _instance;
  StartupCacheService._internal();

  // Cache storage with different categories
  final Map<String, dynamic> _userDataCache = {};
  final Map<String, dynamic> _locationDataCache = {};  
  final Map<String, dynamic> _questionDataCache = {};
  final Map<String, dynamic> _systemDataCache = {};
  
  // Timestamps for cache expiration
  final Map<String, DateTime> _cacheTimestamps = {};
  
  // Cache configuration
  static const Duration _shortTermCache = Duration(minutes: 2); // For initialization
  static const Duration _mediumTermCache = Duration(minutes: 10); // For session data
  static const Duration _longTermCache = Duration(hours: 1); // For static data
  
  // Track cache hits/misses for optimization
  int _cacheHits = 0;
  int _cacheMisses = 0;

  /// Store user-related data (engagement ranking, settings, etc.)
  void cacheUserData(String key, dynamic data, {Duration? duration}) {
    _userDataCache[key] = data;
    _cacheTimestamps['user_$key'] = DateTime.now();
    print('📥 STARTUP CACHE: Cached user data - $key');
    _trackCacheOperation(true);
  }

  /// Get user-related data from cache
  T? getUserData<T>(String key, {Duration duration = _mediumTermCache}) {
    final cacheKey = 'user_$key';
    if (_isValidCache(cacheKey, duration)) {
      print('🎯 STARTUP CACHE: Hit for user data - $key');
      _trackCacheOperation(true);
      return _userDataCache[key] as T?;
    }
    print('❌ STARTUP CACHE: Miss for user data - $key');
    _trackCacheOperation(false);
    return null;
  }

  /// Store location-related data (countries, location history, etc.)
  void cacheLocationData(String key, dynamic data, {Duration? duration}) {
    _locationDataCache[key] = data;
    _cacheTimestamps['location_$key'] = DateTime.now();
    print('📥 STARTUP CACHE: Cached location data - $key');
  }

  /// Get location-related data from cache
  T? getLocationData<T>(String key, {Duration duration = _longTermCache}) {
    final cacheKey = 'location_$key';
    if (_isValidCache(cacheKey, duration)) {
      print('🎯 STARTUP CACHE: Hit for location data - $key');
      _trackCacheOperation(true);
      return _locationDataCache[key] as T?;
    }
    print('❌ STARTUP CACHE: Miss for location data - $key');
    _trackCacheOperation(false);
    return null;
  }

  /// Store question-related data (frequently accessed questions, vote counts, etc.)
  void cacheQuestionData(String key, dynamic data, {Duration? duration}) {
    _questionDataCache[key] = data;
    _cacheTimestamps['question_$key'] = DateTime.now();
    print('📥 STARTUP CACHE: Cached question data - $key');
  }

  /// Get question-related data from cache
  T? getQuestionData<T>(String key, {Duration duration = _shortTermCache}) {
    final cacheKey = 'question_$key';
    if (_isValidCache(cacheKey, duration)) {
      print('🎯 STARTUP CACHE: Hit for question data - $key');
      _trackCacheOperation(true);
      return _questionDataCache[key] as T?;
    }
    print('❌ STARTUP CACHE: Miss for question data - $key');
    _trackCacheOperation(false);
    return null;
  }

  /// Store system-related data (app settings, feature flags, etc.)
  void cacheSystemData(String key, dynamic data, {Duration? duration}) {
    _systemDataCache[key] = data;
    _cacheTimestamps['system_$key'] = DateTime.now();
    print('📥 STARTUP CACHE: Cached system data - $key');
  }

  /// Get system-related data from cache
  T? getSystemData<T>(String key, {Duration duration = _longTermCache}) {
    final cacheKey = 'system_$key';
    if (_isValidCache(cacheKey, duration)) {
      print('🎯 STARTUP CACHE: Hit for system data - $key');
      _trackCacheOperation(true);
      return _systemDataCache[key] as T?;
    }
    print('❌ STARTUP CACHE: Miss for system data - $key');
    _trackCacheOperation(false);
    return null;
  }

  /// Store multiple items in a single operation (batch caching)
  void batchCache(Map<String, dynamic> items, String category, {Duration? duration}) {
    final now = DateTime.now();
    
    switch (category.toLowerCase()) {
      case 'user':
        _userDataCache.addAll(items);
        break;
      case 'location':
        _locationDataCache.addAll(items);
        break;
      case 'question':
        _questionDataCache.addAll(items);
        break;
      case 'system':
        _systemDataCache.addAll(items);
        break;
    }
    
    // Update timestamps for all items
    for (final key in items.keys) {
      _cacheTimestamps['${category}_$key'] = now;
    }
    
    print('📦 STARTUP CACHE: Batch cached ${items.length} $category items');
  }

  /// Preload commonly needed data during app startup
  Future<void> preloadStartupData() async {
    print('🚀 STARTUP CACHE: Beginning startup data preload...');
    
    // This method can be extended to preload frequently accessed data
    // For now, it just initializes the cache structures
    
    print('✅ STARTUP CACHE: Startup data preload completed');
  }

  /// Check if a cache entry is valid
  bool _isValidCache(String cacheKey, Duration duration) {
    final timestamp = _cacheTimestamps[cacheKey];
    if (timestamp == null) return false;
    
    return DateTime.now().difference(timestamp) < duration;
  }

  /// Track cache operations for performance monitoring
  void _trackCacheOperation(bool isHit) {
    if (isHit) {
      _cacheHits++;
    } else {
      _cacheMisses++;
    }
  }

  /// Clean up expired cache entries
  void cleanupExpiredEntries() {
    final now = DateTime.now();
    final expiredKeys = <String>[];
    
    _cacheTimestamps.forEach((key, timestamp) {
      // Use longest cache duration for cleanup check
      if (now.difference(timestamp) > _longTermCache) {
        expiredKeys.add(key);
      }
    });
    
    for (final key in expiredKeys) {
      _cacheTimestamps.remove(key);
      
      // Remove from appropriate cache based on key prefix
      if (key.startsWith('user_')) {
        _userDataCache.remove(key.substring(5));
      } else if (key.startsWith('location_')) {
        _locationDataCache.remove(key.substring(9));
      } else if (key.startsWith('question_')) {
        _questionDataCache.remove(key.substring(9));
      } else if (key.startsWith('system_')) {
        _systemDataCache.remove(key.substring(7));
      }
    }
    
    if (expiredKeys.isNotEmpty) {
      print('🧹 STARTUP CACHE: Cleaned up ${expiredKeys.length} expired entries');
    }
  }

  /// Clear all cached data
  void clearAll() {
    _userDataCache.clear();
    _locationDataCache.clear();
    _questionDataCache.clear();
    _systemDataCache.clear();
    _cacheTimestamps.clear();
    _cacheHits = 0;
    _cacheMisses = 0;
    print('🧹 STARTUP CACHE: Cleared all cached data');
  }

  /// Clear specific category of cached data
  void clearCategory(String category) {
    switch (category.toLowerCase()) {
      case 'user':
        _userDataCache.clear();
        _removeTimestampsForCategory('user_');
        break;
      case 'location':
        _locationDataCache.clear();
        _removeTimestampsForCategory('location_');
        break;
      case 'question':
        _questionDataCache.clear();
        _removeTimestampsForCategory('question_');
        break;
      case 'system':
        _systemDataCache.clear();
        _removeTimestampsForCategory('system_');
        break;
    }
    print('🧹 STARTUP CACHE: Cleared $category cache');
  }

  /// Remove timestamps for a specific category
  void _removeTimestampsForCategory(String prefix) {
    final keysToRemove = _cacheTimestamps.keys
        .where((key) => key.startsWith(prefix))
        .toList();
    
    for (final key in keysToRemove) {
      _cacheTimestamps.remove(key);
    }
  }

  /// Get cache statistics for performance monitoring
  Map<String, dynamic> getCacheStats() {
    final totalRequests = _cacheHits + _cacheMisses;
    final hitRate = totalRequests > 0 ? (_cacheHits / totalRequests * 100) : 0.0;
    
    return {
      'cacheHits': _cacheHits,
      'cacheMisses': _cacheMisses,
      'hitRate': hitRate.toStringAsFixed(1) + '%',
      'totalEntries': _cacheTimestamps.length,
      'categories': {
        'user': _userDataCache.length,
        'location': _locationDataCache.length,
        'question': _questionDataCache.length,
        'system': _systemDataCache.length,
      }
    };
  }

  /// Print cache statistics for debugging
  void printCacheStats() {
    final stats = getCacheStats();
    print('📊 STARTUP CACHE STATS:');
    print('   Cache Hits: ${stats['cacheHits']}');
    print('   Cache Misses: ${stats['cacheMisses']}');
    print('   Hit Rate: ${stats['hitRate']}');
    print('   Total Entries: ${stats['totalEntries']}');
    print('   Categories: ${stats['categories']}');
  }
}