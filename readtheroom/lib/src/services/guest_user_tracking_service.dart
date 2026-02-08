// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'analytics_service.dart';
import 'device_id_provider.dart';

class GuestUserTrackingService extends ChangeNotifier {
  static const String _guestViewCountKey = 'guest_view_count';
  static const String _guestViewedQuestionsKey = 'guest_viewed_questions';
  static const String _guestFirstViewTimestampKey = 'guest_first_view_timestamp';
  static const int _maxGuestViews = 3;

  late SharedPreferences _prefs;
  int _guestViewCount = 0;
  List<String> _viewedQuestionIds = [];
  DateTime? _firstViewTimestamp;
  bool _isInitialized = false;

  int get guestViewCount => _guestViewCount;
  int get remainingViews => (_maxGuestViews - _guestViewCount).clamp(0, _maxGuestViews);
  bool get hasReachedLimit => _guestViewCount >= _maxGuestViews;
  List<String> get viewedQuestionIds => List.unmodifiable(_viewedQuestionIds);
  DateTime? get firstViewTimestamp => _firstViewTimestamp;
  bool get isInitialized => _isInitialized;

  GuestUserTrackingService() {
    _loadData();
  }

  Future<void> _loadData() async {
    _prefs = await SharedPreferences.getInstance();
    
    _guestViewCount = _prefs.getInt(_guestViewCountKey) ?? 0;
    _viewedQuestionIds = _prefs.getStringList(_guestViewedQuestionsKey) ?? [];
    
    final timestampString = _prefs.getString(_guestFirstViewTimestampKey);
    if (timestampString != null) {
      _firstViewTimestamp = DateTime.tryParse(timestampString);
    }
    
    print('DEBUG GuestUserTrackingService loaded: viewCount=$_guestViewCount, viewedQuestions=$_viewedQuestionIds');
    
    // Identify anonymous user in analytics
    await _identifyAnonymousUser();
    
    _isInitialized = true;
    notifyListeners();
  }
  
  Future<void> _identifyAnonymousUser() async {
    try {
      final deviceId = await DeviceIdProvider.getOrCreateDeviceId();
      final analytics = AnalyticsService();
      
      await analytics.identifyAnonymousUser(deviceId);
      await analytics.setUserProperties({
        'guest_view_count': _guestViewCount,
        'guest_questions_viewed': _viewedQuestionIds.length,
        'guest_first_view': _firstViewTimestamp?.toIso8601String(),
      });
    } catch (e) {
      print('Failed to identify anonymous user in analytics: $e');
    }
  }

  Future<void> waitForInitialization() async {
    if (_isInitialized) return;
    
    while (!_isInitialized) {
      await Future.delayed(Duration(milliseconds: 10));
    }
  }

  Future<bool> canViewQuestion(String questionId) async {
    await waitForInitialization();
    
    // If already viewed this question, allow viewing without counting
    if (_viewedQuestionIds.contains(questionId)) {
      return true;
    }
    
    // Check if user has reached the limit
    return _guestViewCount < _maxGuestViews;
  }

  Future<bool> recordQuestionView(String questionId) async {
    await waitForInitialization();
    
    // If already viewed this question, don't increment counter
    if (_viewedQuestionIds.contains(questionId)) {
      return true;
    }
    
    // Check if limit is reached
    if (_guestViewCount >= _maxGuestViews) {
      return false;
    }
    
    // Record the view
    _guestViewCount++;
    _viewedQuestionIds.add(questionId);
    
    print('DEBUG recordQuestionView: Added $questionId, new list: $_viewedQuestionIds');
    
    // Set first view timestamp if this is the first view
    if (_firstViewTimestamp == null) {
      _firstViewTimestamp = DateTime.now();
      await _prefs.setString(_guestFirstViewTimestampKey, _firstViewTimestamp!.toIso8601String());
      
      // Track first guest interaction
      final analytics = AnalyticsService();
      await analytics.trackEvent('onboarding_first_interaction', {
        'interaction_type': 'question_view',
        'is_guest': true,
      });
    }
    
    // Save to preferences
    await _prefs.setInt(_guestViewCountKey, _guestViewCount);
    await _prefs.setStringList(_guestViewedQuestionsKey, _viewedQuestionIds);
    
    // Update analytics properties
    final analytics = AnalyticsService();
    await analytics.setUserProperties({
      'guest_view_count': _guestViewCount,
      'guest_questions_viewed': _viewedQuestionIds.length,
    });
    
    notifyListeners();
    return true;
  }

  bool hasViewedQuestion(String questionId) {
    return _viewedQuestionIds.contains(questionId);
  }

  // Check if a question was viewed as a guest (even after authentication)
  bool wasViewedAsGuest(String questionId) {
    // Return false if not initialized yet (fail safe)
    if (!_isInitialized) return false;
    return _viewedQuestionIds.contains(questionId);
  }

  Future<void> clearGuestData() async {
    await waitForInitialization();
    
    _guestViewCount = 0;
    _firstViewTimestamp = null;
    
    await _prefs.remove(_guestViewCountKey);
    await _prefs.remove(_guestFirstViewTimestampKey);
    // Note: We keep _viewedQuestionIds to prevent voting on previously viewed questions
    
    notifyListeners();
    print('Guest user tracking data cleared (kept viewed question IDs for voting prevention)');
  }

  // Complete clear including viewed questions (for testing/reset purposes)
  Future<void> clearAllGuestData() async {
    await waitForInitialization();
    
    _guestViewCount = 0;
    _viewedQuestionIds.clear();
    _firstViewTimestamp = null;
    
    await _prefs.remove(_guestViewCountKey);
    await _prefs.remove(_guestViewedQuestionsKey);
    await _prefs.remove(_guestFirstViewTimestampKey);
    
    notifyListeners();
    print('All guest user tracking data cleared');
  }

  String getRemainingViewsText() {
    return 'To vote on questions, authenticate as a real human!';
  }

  String getGuestViewTitle() {
    final remaining = remainingViews;
    if (remaining <= 0) {
      return 'Guest View (limit reached)';
    } else {
      return 'Guest View ($remaining remaining)';
    }
  }

  Future<void> resetGuestViews() async {
    await clearGuestData();
    print('Guest views reset');
  }

  Map<String, dynamic> getGuestViewInfo() {
    return {
      'viewCount': _guestViewCount,
      'remainingViews': remainingViews,
      'hasReachedLimit': hasReachedLimit,
      'viewedQuestions': _viewedQuestionIds.length,
      'firstViewTimestamp': _firstViewTimestamp?.toIso8601String(),
    };
  }
}