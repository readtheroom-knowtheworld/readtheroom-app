// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'package:flutter/foundation.dart';

/// Service to prevent duplicate API requests during app initialization
/// This helps avoid the issue where multiple services make the same expensive database queries
class RequestDeduplicationService {
  static final RequestDeduplicationService _instance = RequestDeduplicationService._internal();
  factory RequestDeduplicationService() => _instance;
  RequestDeduplicationService._internal();

  // Store active requests by their unique key
  final Map<String, Future<dynamic>> _activeRequests = {};
  
  // Store completed requests for short-term caching during initialization
  final Map<String, dynamic> _completedRequests = {};
  final Map<String, DateTime> _completionTimestamps = {};
  
  // Cache duration for completed requests (short-term during initialization)
  static const Duration _cacheDuration = Duration(minutes: 2);

  /// Deduplicate a request by key. If the same request is already in progress, 
  /// returns the existing Future. If recently completed, returns cached result.
  Future<T> deduplicateRequest<T>(
    String requestKey, 
    Future<T> Function() requestFunction,
    {Duration? cacheDuration}
  ) async {
    final effectiveCacheDuration = cacheDuration ?? _cacheDuration;
    
    // Check if we have a recent cached result
    if (_completedRequests.containsKey(requestKey)) {
      final timestamp = _completionTimestamps[requestKey];
      if (timestamp != null && 
          DateTime.now().difference(timestamp) < effectiveCacheDuration) {
        print('🔄 REQUEST DEDUP: Using cached result for $requestKey');
        return _completedRequests[requestKey] as T;
      } else {
        // Cache expired, remove it
        _completedRequests.remove(requestKey);
        _completionTimestamps.remove(requestKey);
      }
    }

    // Check if request is already in progress
    if (_activeRequests.containsKey(requestKey)) {
      print('🔄 REQUEST DEDUP: Waiting for existing request: $requestKey');
      return _activeRequests[requestKey] as Future<T>;
    }

    print('🚀 REQUEST DEDUP: Starting new request: $requestKey');
    
    // Start new request
    final future = requestFunction().then((result) {
      // Cache the result
      _completedRequests[requestKey] = result;
      _completionTimestamps[requestKey] = DateTime.now();
      
      // Remove from active requests
      _activeRequests.remove(requestKey);
      
      print('✅ REQUEST DEDUP: Completed and cached: $requestKey');
      return result;
    }).catchError((error) {
      // Remove from active requests on error
      _activeRequests.remove(requestKey);
      print('❌ REQUEST DEDUP: Failed request: $requestKey - $error');
      throw error;
    });

    // Store the active request
    _activeRequests[requestKey] = future;
    
    return future;
  }

  /// Clear all cached data (useful for logout or major state changes)
  void clearCache() {
    _activeRequests.clear();
    _completedRequests.clear();
    _completionTimestamps.clear();
    print('🧹 REQUEST DEDUP: Cache cleared');
  }

  /// Clear expired cached entries
  void cleanupExpiredCache() {
    final now = DateTime.now();
    final expiredKeys = <String>[];
    
    _completionTimestamps.forEach((key, timestamp) {
      if (now.difference(timestamp) > _cacheDuration) {
        expiredKeys.add(key);
      }
    });
    
    for (final key in expiredKeys) {
      _completedRequests.remove(key);
      _completionTimestamps.remove(key);
    }
    
    if (expiredKeys.isNotEmpty) {
      print('🧹 REQUEST DEDUP: Cleaned up ${expiredKeys.length} expired cache entries');
    }
  }

  /// Get stats for debugging
  Map<String, int> getStats() {
    return {
      'activeRequests': _activeRequests.length,
      'cachedResults': _completedRequests.length,
    };
  }
}