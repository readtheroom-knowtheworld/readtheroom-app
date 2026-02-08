// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'package:read_the_room/src/services/notification_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

class WatchlistService extends ChangeNotifier {
  static const String _watchlistKey = 'question_watchlist';
  
  SharedPreferences? _prefs;
  Map<String, Map<String, dynamic>> _watchlist = {};
  final _supabase = Supabase.instance.client;
  final _messaging = FirebaseMessaging.instance;
  
  // Getters
  Map<String, Map<String, dynamic>> get watchlist => _watchlist;
  
  bool isWatching(String questionId) {
    return _watchlist.containsKey(questionId);
  }
  
  int getWatchedQuestionCount() {
    return _watchlist.length;
  }
  
  List<String> getWatchedQuestionIds() {
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
          .from('question_subscriptions')
          .select('question_id, subscription_source, last_vote_count, last_comment_count, last_notified_at')
          .eq('user_id', user.id)
          .eq('muted', false);

      final serverSubscriptions = response as List<dynamic>;

      // Sync server subscriptions to local
      for (final sub in serverSubscriptions) {
        final questionId = sub['question_id'] as String;
        if (!_watchlist.containsKey(questionId)) {
          _watchlist[questionId] = {
            'last_vote_count': sub['last_vote_count'] ?? 0,
            'last_comment_count': sub['last_comment_count'] ?? 0,
            'last_notified_at': sub['last_notified_at'] ?? DateTime.now().toIso8601String(),
            'never_notified': false,
            'subscription_source': sub['subscription_source'] ?? 'manual',
          };

          // Subscribe to FCM topic
          await _messaging.subscribeToTopic('question_$questionId');
        }
      }

      // Sync local subscriptions to server
      final serverQuestionIds = serverSubscriptions.map((s) => s['question_id'] as String).toSet();
      for (final questionId in _watchlist.keys.toList()) {
        if (!serverQuestionIds.contains(questionId)) {
          // Local subscription missing from server - create it
          final entry = _watchlist[questionId]!;
          await _supabase.from('question_subscriptions').upsert({
            'question_id': questionId,
            'user_id': user.id,
            'subscription_source': entry['subscription_source'] ?? 'manual',
            'last_vote_count': entry['last_vote_count'] ?? 0,
            'last_comment_count': entry['last_comment_count'] ?? 0,
          });
        }
      }

      await _saveWatchlist();
      notifyListeners();
      print('✅ Synced ${_watchlist.length} subscriptions with server');
    } catch (e) {
      print('❌ Error syncing subscriptions with server: $e');
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
        print('Loaded watchlist with ${_watchlist.length} questions');
      }
    } catch (e) {
      print('Error loading watchlist: $e');
      _watchlist = {};
    }
    notifyListeners();
  }

  // Save watchlist to local storage
  Future<void> _saveWatchlist() async {
    try {
      final String watchlistJson = json.encode(_watchlist);
      await _prefs?.setString(_watchlistKey, watchlistJson);
      print('Saved watchlist with ${_watchlist.length} questions');
    } catch (e) {
      print('Error saving watchlist: $e');
    }
  }

  // Subscribe to a question
  Future<void> subscribeToQuestion(
    String questionId, 
    int currentVoteCount,
    int currentCommentCount, {
    bool showSnackbar = true,
    bool isAutoSubscribe = false,
    String? source, // 'manual', 'comment', 'author'
  }) async {
    if (_watchlist.containsKey(questionId)) {
      print('Already watching question: $questionId');
      return;
    }

    try {
      // 1. Create server subscription
      final user = _supabase.auth.currentUser;
      if (user != null) {
        await _supabase.from('question_subscriptions').upsert({
          'question_id': questionId,
          'user_id': user.id,
          'subscription_source': source ?? 'manual',
          'last_vote_count': currentVoteCount,
          'last_comment_count': currentCommentCount,
        });
        
        // 2. Subscribe to FCM topic
        await _messaging.subscribeToTopic('question_$questionId');
        print('✅ Subscribed to FCM topic: question_$questionId');
      }
    } catch (e) {
      print('❌ Error creating server subscription: $e');
      // Continue with local subscription even if server fails
    }

    // 3. Update local state
    _watchlist[questionId] = {
      'last_vote_count': currentVoteCount,
      'last_comment_count': currentCommentCount,
      'last_notified_at': DateTime.now().toIso8601String(), 
      'never_notified': true, // Flag to bypass cooldown for first notification
      'subscription_source': source ?? 'manual',
    };

    await _saveWatchlist();
    notifyListeners();
    
    if (!isAutoSubscribe && showSnackbar) {
      // Show confirmation only for manual subscriptions
      print('📱 Subscribed to question notifications');
    }
    
    print('Subscribed to question: $questionId with $currentVoteCount votes, $currentCommentCount comments');
  }

  // Unsubscribe from a question
  Future<void> unsubscribeFromQuestion(String questionId) async {
    if (!_watchlist.containsKey(questionId)) {
      print('Not watching question: $questionId');
      return;
    }

    try {
      // 1. Delete server subscription
      final user = _supabase.auth.currentUser;
      if (user != null) {
        print('🗑️ Attempting to delete subscription for user ${user.id} from question $questionId');
        
        // Simple approach: just delete and verify
        print('🗑️ Deleting subscription for question $questionId...');
        
        final deleteResponse = await _supabase.from('question_subscriptions')
          .delete()
          .eq('question_id', questionId)
          .eq('user_id', user.id);
        
        print('✅ Delete operation completed');
        
        // Verify deletion worked by checking if any subscriptions remain
        final remainingSubscriptions = await _supabase
          .from('question_subscriptions')
          .select('id')
          .eq('question_id', questionId)
          .eq('user_id', user.id);
        
        if (remainingSubscriptions.isEmpty) {
          print('✅ Server subscription deleted successfully - verified empty');
        } else {
          print('❌ ${remainingSubscriptions.length} subscription(s) still exist after delete attempt');
        }
        
        // 2. Unsubscribe from FCM topic
        await _messaging.unsubscribeFromTopic('question_$questionId');
        print('✅ Unsubscribed from FCM topic: question_$questionId');
      } else {
        print('❌ No authenticated user found for unsubscribe operation');
      }
    } catch (e) {
      print('❌ Error deleting server subscription: $e');
      print('❌ Error type: ${e.runtimeType}');
      print('❌ Error details: ${e.toString()}');
      // Continue with local unsubscription even if server fails
    }

    // 3. Update local state
    _watchlist.remove(questionId);
    await _saveWatchlist();
    notifyListeners();
    
    print('Unsubscribed from question: $questionId');
  }

  // Toggle subscription status
  Future<bool> toggleSubscription(
    String questionId, 
    int currentVoteCount,
    int currentCommentCount,
  ) async {
    if (isWatching(questionId)) {
      await unsubscribeFromQuestion(questionId);
      return false; // Now unsubscribed
    } else {
      await subscribeToQuestion(questionId, currentVoteCount, currentCommentCount);
      return true; // Now subscribed
    }
  }

  // Update watchlist entry after receiving notification
  Future<void> updateWatchlistEntry(
    String questionId, 
    int newVoteCount,
    int newCommentCount,
  ) async {
    if (!_watchlist.containsKey(questionId)) {
      print('Question not in watchlist: $questionId');
      return;
    }

    _watchlist[questionId] = {
      'last_vote_count': newVoteCount,
      'last_comment_count': newCommentCount,
      'last_notified_at': DateTime.now().toIso8601String(),
      'never_notified': false, // Clear the flag since we're now notifying
    };

    await _saveWatchlist();
    notifyListeners();
    
    print('Updated watchlist entry for $questionId: $newVoteCount votes, $newCommentCount comments');
  }

  // Check if notification should be sent (for push handler)
  bool shouldNotify(
    String questionId, 
    int newVoteCount,
  ) {
    final entry = _watchlist[questionId];
    if (entry == null) return false;

    try {
      final lastNotified = DateTime.parse(entry['last_notified_at']);
      final oldCount = entry['last_vote_count'] ?? 0;
      final timeSince = DateTime.now().difference(lastNotified);
      final percentChange = oldCount > 0 
          ? (newVoteCount - oldCount) / oldCount 
          : (newVoteCount > 0 ? 1.0 : 0.0);

      // Check if this subscription has never been notified (bypass cooldown)
      final neverNotified = entry['never_notified'] == true;
      
      // Match NotificationService logic: 2hr cooldown AND (significant % OR meaningful vote increase)
      final timeCondition = neverNotified || timeSince >= Duration(hours: 2);
      final voteIncrease = newVoteCount - oldCount;
      
      // More flexible conditions: EITHER significant percentage OR meaningful vote count
      final significantPercentage = percentChange > 0.15; // 15% for smaller questions
      final meaningfulVoteIncrease = voteIncrease >= 3; // 3+ votes is always meaningful
      final moderateActivity = voteIncrease >= 2 && percentChange > 0.05; // 2+ votes with 5% increase
      
      final activityCondition = significantPercentage || meaningfulVoteIncrease || moderateActivity;
      
      print('Notification check for $questionId: time=$timeCondition (${neverNotified ? "first notification" : timeSince.inHours.toString() + "h"}), activity=$activityCondition (${(percentChange * 100).toStringAsFixed(1)}%, +$voteIncrease votes)');
      
      return timeCondition && activityCondition;
    } catch (e) {
      print('Error checking notification conditions: $e');
      return false;
    }
  }

  // Get watchlist entry for a question
  Map<String, dynamic>? getWatchlistEntry(String questionId) {
    return _watchlist[questionId];
  }

  // Clear all subscriptions (for testing or user preference)
  Future<void> clearAllSubscriptions() async {
    _watchlist.clear();
    await _saveWatchlist();
    notifyListeners();
    print('Cleared all question subscriptions');
  }

  // Get statistics for debugging
  Map<String, dynamic> getStats() {
    final now = DateTime.now();
    int recentSubscriptions = 0;
    
    for (final entry in _watchlist.values) {
      try {
        final lastNotified = DateTime.parse(entry['last_notified_at']);
        if (now.difference(lastNotified).inDays < 7) {
          recentSubscriptions++;
        }
      } catch (e) {
        // Skip invalid entries
      }
    }

    return {
      'total_subscriptions': _watchlist.length,
      'recent_subscriptions': recentSubscriptions,
      'question_ids': _watchlist.keys.toList(),
    };
  }
} 