// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

class SuggestionWatchlistService extends ChangeNotifier {
  static const String _watchlistKey = 'suggestion_watchlist';
  
  SharedPreferences? _prefs;
  Map<String, Map<String, dynamic>> _watchlist = {};
  final _supabase = Supabase.instance.client;
  final _messaging = FirebaseMessaging.instance;
  
  // Getters
  Map<String, Map<String, dynamic>> get watchlist => _watchlist;
  
  bool isWatching(String suggestionId) {
    return _watchlist.containsKey(suggestionId);
  }
  
  int getWatchedSuggestionCount() {
    return _watchlist.length;
  }
  
  List<String> getWatchedSuggestionIds() {
    return _watchlist.keys.toList();
  }

  // Initialize the service
  Future<void> initialize() async {
    _prefs = await SharedPreferences.getInstance();
    await _loadWatchlist();
    await _syncWithServerSubscriptions();
  }

  // Sync local watchlist with server subscriptions
  Future<void> _syncWithServerSubscriptions() async {
    try {
      final user = _supabase.auth.currentUser;
      if (user == null) return;

      // Get server subscriptions
      final response = await _supabase
          .from('suggestion_subscriptions')
          .select('suggestion_id, subscription_source, last_comment_count, subscribed_at, muted')
          .eq('user_id', user.id)
          .eq('muted', false);

      final serverSubscriptions = response as List<dynamic>;

      // Sync server subscriptions to local
      for (final sub in serverSubscriptions) {
        final suggestionId = sub['suggestion_id'] as String;
        if (!_watchlist.containsKey(suggestionId)) {
          _watchlist[suggestionId] = {
            'last_comment_count': sub['last_comment_count'] ?? 0,
            'subscribed_at': sub['subscribed_at'] ?? DateTime.now().toIso8601String(),
            'subscription_source': sub['subscription_source'] ?? 'manual',
          };

          // Subscribe to FCM topic
          await _messaging.subscribeToTopic('suggestion_$suggestionId');
        }
      }

      // Sync local subscriptions to server
      final serverSuggestionIds = serverSubscriptions.map((s) => s['suggestion_id'] as String).toSet();
      for (final suggestionId in _watchlist.keys.toList()) {
        if (!serverSuggestionIds.contains(suggestionId)) {
          // Local subscription missing from server - create it
          final entry = _watchlist[suggestionId]!;
          await _supabase.from('suggestion_subscriptions').upsert({
            'suggestion_id': suggestionId,
            'user_id': user.id,
            'subscription_source': entry['subscription_source'] ?? 'manual',
            'last_comment_count': entry['last_comment_count'] ?? 0,
          });
        }
      }

      await _saveWatchlist();
      notifyListeners();
      print('✅ Synced ${_watchlist.length} suggestion subscriptions with server');
    } catch (e) {
      print('❌ Error syncing suggestion subscriptions with server: $e');
    }
  }

  // Load watchlist from local storage
  Future<void> _loadWatchlist() async {
    try {
      final String? watchlistJson = _prefs?.getString(_watchlistKey);
      if (watchlistJson != null) {
        final Map<String, dynamic> decoded = json.decode(watchlistJson);
        _watchlist = decoded.map((key, value) => 
          MapEntry(key, Map<String, dynamic>.from(value))
        );
        print('Loaded suggestion watchlist with ${_watchlist.length} suggestions');
      }
    } catch (e) {
      print('Error loading suggestion watchlist: $e');
      _watchlist = {};
    }
    notifyListeners();
  }

  // Save watchlist to local storage
  Future<void> _saveWatchlist() async {
    try {
      final String watchlistJson = json.encode(_watchlist);
      await _prefs?.setString(_watchlistKey, watchlistJson);
      print('Saved suggestion watchlist with ${_watchlist.length} suggestions');
    } catch (e) {
      print('Error saving suggestion watchlist: $e');
    }
  }

  // Subscribe to a suggestion
  Future<void> subscribeToSuggestion(
    String suggestionId, 
    int currentCommentCount, {
    bool showSnackbar = true,
    bool isAutoSubscribe = false,
    String? source, // 'manual', 'comment', 'author'
  }) async {
    if (_watchlist.containsKey(suggestionId)) {
      print('Already watching suggestion: $suggestionId');
      return;
    }

    try {
      // 1. Create server subscription
      final user = _supabase.auth.currentUser;
      if (user != null) {
        await _supabase.from('suggestion_subscriptions').upsert({
          'suggestion_id': suggestionId,
          'user_id': user.id,
          'subscription_source': source ?? 'manual',
          'last_comment_count': currentCommentCount,
          'subscribed_at': DateTime.now().toIso8601String(),
          'muted': false,
        });
        
        // 2. Subscribe to FCM topic
        await _messaging.subscribeToTopic('suggestion_$suggestionId');
        print('✅ Subscribed to FCM topic: suggestion_$suggestionId');
      }
    } catch (e) {
      print('❌ Error creating server suggestion subscription: $e');
      // Continue with local subscription even if server fails
    }

    // 3. Update local state
    _watchlist[suggestionId] = {
      'last_comment_count': currentCommentCount,
      'subscribed_at': DateTime.now().toIso8601String(), 
      'subscription_source': source ?? 'manual',
    };

    await _saveWatchlist();
    notifyListeners();
    
    if (!isAutoSubscribe && showSnackbar) {
      // Show confirmation only for manual subscriptions
      print('📱 Subscribed to suggestion notifications');
    }
    
    print('Subscribed to suggestion: $suggestionId with $currentCommentCount comments');
  }

  // Unsubscribe from a suggestion
  Future<void> unsubscribeFromSuggestion(String suggestionId) async {
    if (!_watchlist.containsKey(suggestionId)) {
      print('Not watching suggestion: $suggestionId');
      return;
    }

    try {
      // 1. Delete server subscription
      final user = _supabase.auth.currentUser;
      if (user != null) {
        print('🗑️ Attempting to delete subscription for user ${user.id} from suggestion $suggestionId');
        
        final deleteResponse = await _supabase.from('suggestion_subscriptions')
          .delete()
          .eq('suggestion_id', suggestionId)
          .eq('user_id', user.id);
        
        print('✅ Delete operation completed');
        
        // 2. Unsubscribe from FCM topic
        await _messaging.unsubscribeFromTopic('suggestion_$suggestionId');
        print('✅ Unsubscribed from FCM topic: suggestion_$suggestionId');
      } else {
        print('❌ No authenticated user found for unsubscribe operation');
      }
    } catch (e) {
      print('❌ Error deleting server suggestion subscription: $e');
      // Continue with local unsubscription even if server fails
    }

    // 3. Update local state
    _watchlist.remove(suggestionId);
    await _saveWatchlist();
    notifyListeners();
    
    print('Unsubscribed from suggestion: $suggestionId');
  }

  // Toggle subscription status
  Future<bool> toggleSubscription(
    String suggestionId, 
    int currentCommentCount,
  ) async {
    if (isWatching(suggestionId)) {
      await unsubscribeFromSuggestion(suggestionId);
      return false; // Now unsubscribed
    } else {
      await subscribeToSuggestion(suggestionId, currentCommentCount);
      return true; // Now subscribed
    }
  }

  // Update watchlist entry after receiving notification
  Future<void> updateWatchlistEntry(
    String suggestionId, 
    int newCommentCount,
  ) async {
    if (!_watchlist.containsKey(suggestionId)) {
      print('Suggestion not in watchlist: $suggestionId');
      return;
    }

    _watchlist[suggestionId] = {
      ..._watchlist[suggestionId]!,
      'last_comment_count': newCommentCount,
    };

    await _saveWatchlist();
    notifyListeners();
    
    print('Updated suggestion watchlist entry for $suggestionId: $newCommentCount comments');
  }

  // Get watchlist entry for a suggestion
  Map<String, dynamic>? getWatchlistEntry(String suggestionId) {
    return _watchlist[suggestionId];
  }

  // Clear all subscriptions (for testing or user preference)
  Future<void> clearAllSubscriptions() async {
    _watchlist.clear();
    await _saveWatchlist();
    notifyListeners();
    print('Cleared all suggestion subscriptions');
  }

  // Get statistics for debugging
  Map<String, dynamic> getStats() {
    final now = DateTime.now();
    int recentSubscriptions = 0;
    
    for (final entry in _watchlist.values) {
      try {
        final subscribedAt = DateTime.parse(entry['subscribed_at']);
        if (now.difference(subscribedAt).inDays < 7) {
          recentSubscriptions++;
        }
      } catch (e) {
        // Skip invalid entries
      }
    }

    return {
      'total_subscriptions': _watchlist.length,
      'recent_subscriptions': recentSubscriptions,
      'suggestion_ids': _watchlist.keys.toList(),
    };
  }
}