// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'dart:math' as Math;
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../models/category.dart' as app_category;
import 'package:supabase_flutter/supabase_flutter.dart';
import '../services/notification_service.dart';
import '../services/question_service.dart';
import '../services/comment_service.dart';
import '../services/location_service.dart';
import '../services/passkeys_service.dart';
import '../services/device_id_provider.dart';
import '../services/request_deduplication_service.dart';
import '../services/startup_cache_service.dart';
import '../services/analytics_service.dart';
import '../services/congratulations_service.dart';
import '../services/achievement_service.dart';
import '../services/streak_reminder_service.dart';
import '../services/qotd_reminder_service.dart';
import '../services/home_widget_service.dart';
import '../widgets/notification_bell.dart';
import 'question_service.dart' show StreakUpdateEvent;

class UserService extends ChangeNotifier {
  static const String _answeredKey = 'answered_questions';
  static const String _postedKey = 'posted_questions';
  static const String _savedKey = 'saved_questions';
  static const String _hideAnsweredKey = 'hideAnsweredQuestions';
  static const String _reportedKey = 'reported_questions';
  static const String _reportedReasonsKey = 'reported_question_reasons';
  static const String _dismissedKey = 'dismissed_questions';
  static const String _userIdKey = 'user_id';
  static const String _enabledQuestionTypesKey = 'enabled_question_types';
  static const String _notifyResponsesKey = 'notify_responses';
  static const String _notifyQOTDKey = 'notify_qotd';
  static const String _notifyStreakRemindersKey = 'notify_streak_reminders';
  static const String _streakReminderTimeKey = 'streak_reminder_time';
  static const String _qotdReminderTimeKey = 'qotd_reminder_time';
  static const String _showNSFWKey = 'showNSFWContent';
  static const String _boostLocalActivityKey = 'boost_local_activity';
  static const String _enabledCategoriesKey = 'enabled_categories';
  static const String _notificationPermissionShownKey = 'notification_permission_shown';
  static const String _qotdClickCountKey = 'qotd_click_count';
  static const String _votedSuggestionsKey = 'voted_suggestions';
  static const String _hasEverEnabledNSFWKey = 'hasEverEnabledNSFW';
  static const String _locationHistoryKey = 'location_history';
  static const String _pendingLocationSwitchKey = 'pending_location_switch';
  static const String _ratedQuestionsKey = 'rated_questions';
  static const String _questionRatingValuesKey = 'question_rating_values';
  static const String _generationKey = 'user_generation';

  // Device ID migration tracking
  static const String _migrationAttemptCountKey = 'migration_attempt_count';
  static const String _lastMigrationAttemptKey = 'last_migration_attempt';
  static const String _migrationSuccessKey = 'migration_success';

  // Cache for vote count refreshes
  DateTime? _lastVoteCountRefresh;
  static const Duration _voteCountCacheDuration = Duration(minutes: 2);

  // Cache for engagement ranking
  Map<String, dynamic>? _cachedEngagementRanking;
  DateTime? _lastEngagementRankingRefresh;
  
  // Getter for cached engagement ranking (for UI access)
  Map<String, dynamic>? get cachedEngagementRanking => _cachedEngagementRanking;
  static const Duration _engagementRankingCacheDuration = Duration(minutes: 30); // Cache for 30 minutes

  // Define all available question types
  static const List<Map<String, dynamic>> allQuestionTypes = [
    {'id': 'approval_rating', 'name': 'Approval', 'icon': Icons.thumbs_up_down},
    {'id': 'multiple_choice', 'name': 'Choice', 'icon': Icons.check_box},
    {'id': 'text', 'name': 'Text', 'icon': Icons.text_fields},
  ];

  List<Map<String, dynamic>> _answeredQuestions = [];
  List<Map<String, dynamic>> _postedQuestions = [];
  List<Map<String, dynamic>> _savedQuestions = [];
  List<String> _reportedQuestionIds = [];
  Map<String, List<String>> _reportedQuestionReasons = {}; // questionId -> list of reasons
  List<String> _dismissedQuestionIds = [];
  DateTime? _lastReportTime;
  late SharedPreferences _prefs;
  String? _userLocation;
  bool _notifyResponses = false;
  bool _notifyQOTD = true;
  bool _notifyStreakReminders = false;
  TimeOfDay _streakReminderTime = TimeOfDay(hour: 18, minute: 0); // Default to 6 PM
  TimeOfDay _qotdReminderTime = TimeOfDay(hour: 19, minute: 30); // Default to 7:30 PM
  bool _showNSFWContent = false;
  bool _hasEverEnabledNSFW = false; // Track if user has ever enabled NSFW in settings
  bool _hideAnsweredQuestions = false;
  bool _boostLocalActivity = true;
  bool _notificationPermissionShown = false;
  int _qotdClickCount = 0;
  List<String> _enabledCategories = app_category.Category.allCategories.map((c) => c.name).toList();
  List<String> _enabledQuestionTypes = [];
  String? _userId;

  // Suggestions management
  List<Map<String, dynamic>> _suggestions = [];
  Set<String> _votedSuggestions = {};
  bool _suggestionsLoaded = false;

  // Generation preference
  String? _generation;

  // Question rating tracking (local-only, anonymous)
  Set<String> _ratedQuestions = {};
  Map<String, double> _questionRatingValues = {};
  
  // Location history management
  List<Map<String, dynamic>> _locationHistory = [];
  Map<String, dynamic>? _pendingLocationSwitch;
  
  // Track initialization state
  bool _isInitialized = false;

  // Request deduplication service for preventing duplicate API calls
  final _deduplicationService = RequestDeduplicationService();

  // Streak leaderboard - synced to server on feed refresh
  int _streakRank = 0;
  bool _isTopTenStreak = false;
  
  // Startup cache service for enhanced caching during initialization
  final _startupCache = StartupCacheService();

  // Static variable to track temporary filter across screens
  static String? _temporaryCategoryFilter;
  
  // Static method to check if there's a temporary category filter active
  static bool hasTemporaryCategoryFilter() {
    return _temporaryCategoryFilter != null;
  }
  
  // Static method to set temporary category filter
  static void setTemporaryCategoryFilter(String? categoryName) {
    _temporaryCategoryFilter = categoryName;
  }

  UserService() {
    _loadData();
  }
  
  // Method to wait for initialization to complete
  Future<void> waitForInitialization() async {
    if (_isInitialized) return;
    
    // Wait for _loadData to complete
    while (!_isInitialized) {
      await Future.delayed(Duration(milliseconds: 10));
    }
    
    // Attempt automatic migration after initialization
    await _attemptAutomaticMigration();
  }

  String get userId {
    if (_userId == null) {
      _userId = DateTime.now().millisecondsSinceEpoch.toString();
      _prefs.setString(_userIdKey, _userId!);
    }
    return _userId!;
  }

  List<Map<String, dynamic>> get answeredQuestions => _answeredQuestions;
  List<Map<String, dynamic>> get postedQuestions => _postedQuestions;
  List<Map<String, dynamic>> get savedQuestions => _savedQuestions;
  String? get userLocation => _userLocation;
  bool get notifyResponses => _notifyResponses;
  bool get notifyQOTD => _notifyQOTD;
  bool get notifyStreakReminders => _notifyStreakReminders;
  TimeOfDay get streakReminderTime => _streakReminderTime;
  TimeOfDay get qotdReminderTime => _qotdReminderTime;
  bool get showNSFWContent => _showNSFWContent;
  bool get hideAnsweredQuestions => _hideAnsweredQuestions;
  bool get boostLocalActivity => _boostLocalActivity;
  bool get notificationPermissionShown => _notificationPermissionShown;
  List<String> get enabledCategories => _enabledCategories;
  List<String> get enabledQuestionTypes => _enabledQuestionTypes;
  List<Map<String, dynamic>> get suggestions => _suggestions;
  bool get hasEverEnabledNSFW => _hasEverEnabledNSFW;
  
  // Location history getters
  List<Map<String, dynamic>> get locationHistory => _locationHistory;
  Map<String, dynamic>? get pendingLocationSwitch => _pendingLocationSwitch;
  bool get hasPendingLocationSwitch => _pendingLocationSwitch != null;

  // Streak leaderboard getters
  int get streakRank => _streakRank;
  bool get isTopTenStreak => _isTopTenStreak;

  // Generation getters
  String? get generation => _generation;
  bool get hasGeneration => _generation != null;

  Future<void> setGeneration(String? generation) async {
    _generation = generation;
    if (generation != null) {
      await _prefs.setString(_generationKey, generation);
    } else {
      await _prefs.remove(_generationKey);
    }
    notifyListeners();
  }

  Future<void> _loadData() async {
    _prefs = await SharedPreferences.getInstance();
    _userId = _prefs.getString(_userIdKey);
    _loadQuestions(_answeredKey, _answeredQuestions);
    _loadQuestions(_postedKey, _postedQuestions);
    _loadQuestions(_savedKey, _savedQuestions);
    _hideAnsweredQuestions = _prefs.getBool(_hideAnsweredKey) ?? false;
    _reportedQuestionIds = _prefs.getStringList(_reportedKey) ?? [];
    
    // Load reported question reasons
    final reportedReasonsJson = _prefs.getString(_reportedReasonsKey);
    if (reportedReasonsJson != null) {
      try {
        final Map<String, dynamic> decoded = json.decode(reportedReasonsJson);
        _reportedQuestionReasons = decoded.map((key, value) => 
          MapEntry(key, List<String>.from(value)));
      } catch (e) {
        print('Error loading reported question reasons: $e');
        _reportedQuestionReasons = {};
      }
    }
    _dismissedQuestionIds = _prefs.getStringList(_dismissedKey) ?? [];
    
    // Load all user preference settings
    _notifyResponses = _prefs.getBool(_notifyResponsesKey) ?? false;
    _notifyQOTD = _prefs.getBool(_notifyQOTDKey) ?? true;
    _notifyStreakReminders = _prefs.getBool(_notifyStreakRemindersKey) ?? false;
    
    // Load streak reminder time (default to 6 PM if not set)
    final savedReminderHour = _prefs.getInt(_streakReminderTimeKey + '_hour') ?? 18;
    final savedReminderMinute = _prefs.getInt(_streakReminderTimeKey + '_minute') ?? 0;
    _streakReminderTime = TimeOfDay(hour: savedReminderHour, minute: savedReminderMinute);

    // Load QOTD reminder time (default to 7:30 PM if not set)
    final savedQotdHour = _prefs.getInt(_qotdReminderTimeKey + '_hour') ?? 19;
    final savedQotdMinute = _prefs.getInt(_qotdReminderTimeKey + '_minute') ?? 30;
    _qotdReminderTime = TimeOfDay(hour: savedQotdHour, minute: savedQotdMinute);
    _showNSFWContent = _prefs.getBool(_showNSFWKey) ?? false;
    _hasEverEnabledNSFW = _prefs.getBool(_hasEverEnabledNSFWKey) ?? _showNSFWContent;
    _boostLocalActivity = _prefs.getBool(_boostLocalActivityKey) ?? true;
    _notificationPermissionShown = _prefs.getBool(_notificationPermissionShownKey) ?? false;
    _qotdClickCount = _prefs.getInt(_qotdClickCountKey) ?? 0;

    // Load location history
    _loadLocationHistory();
    
    // Load enabled categories
    final savedCategories = _prefs.getStringList(_enabledCategoriesKey);
    if (savedCategories != null) {
      _enabledCategories = List<String>.from(savedCategories);
      
      // Check for new categories and re-enable all topics when new ones are found
      final allCategoryNames = app_category.Category.allCategories.map((c) => c.name).toList();
      final newCategories = allCategoryNames.where((name) => !_enabledCategories.contains(name)).toList();
      
      if (newCategories.isNotEmpty) {
        // When new categories are detected (app update), re-enable all topics
        // This ensures users see questions from all topics including the new ones
        _enabledCategories = allCategoryNames;
        _prefs.setStringList(_enabledCategoriesKey, _enabledCategories);
        print('New categories detected (${newCategories.join(", ")}), re-enabled all topics for better visibility');
      }
    } else {
      // Default to all categories enabled
      _enabledCategories = app_category.Category.allCategories.map((c) => c.name).toList();
      _prefs.setStringList(_enabledCategoriesKey, _enabledCategories);
    }
    
    // Check authentication status
    final supabase = Supabase.instance.client;
    final isAuthenticated = supabase.auth.currentUser != null;
    
    // Load enabled question types from preferences
    final enabledTypes = _prefs.getStringList(_enabledQuestionTypesKey);
    if (enabledTypes != null) {
      _enabledQuestionTypes = List<String>.from(enabledTypes);
      
      // If user is authenticated and text questions aren't enabled, enable them by default
      if (isAuthenticated && !_enabledQuestionTypes.contains('text')) {
        _enabledQuestionTypes.add('text');
        _prefs.setStringList(_enabledQuestionTypesKey, _enabledQuestionTypes);
      }
      
      // If user is not authenticated, ensure text questions are disabled
      if (!isAuthenticated && _enabledQuestionTypes.contains('text')) {
        _enabledQuestionTypes.remove('text');
        _prefs.setStringList(_enabledQuestionTypesKey, _enabledQuestionTypes);
      }
    } else {
      // Set default question types based on authentication
      _enabledQuestionTypes = allQuestionTypes
          .where((type) => type['id'] != 'text' || isAuthenticated)
          .map((t) => t['id'] as String)
          .toList();
      
      // Save the initial state
      _prefs.setStringList(_enabledQuestionTypesKey, _enabledQuestionTypes);
    }
    
    // Load voted suggestions from local storage
    final votedSuggestions = _prefs.getStringList(_votedSuggestionsKey);
    if (votedSuggestions != null) {
      _votedSuggestions = Set<String>.from(votedSuggestions);
    }

    // Load rated questions from local storage
    final ratedQuestions = _prefs.getStringList(_ratedQuestionsKey);
    if (ratedQuestions != null) {
      _ratedQuestions = Set<String>.from(ratedQuestions);
    }
    final ratingValuesJson = _prefs.getString(_questionRatingValuesKey);
    if (ratingValuesJson != null) {
      final decoded = json.decode(ratingValuesJson) as Map<String, dynamic>;
      _questionRatingValues = decoded.map((k, v) => MapEntry(k, (v as num).toDouble()));
    }

    // Load generation preference
    _generation = _prefs.getString(_generationKey);

    // Defer feedback loading to improve startup performance
    // Suggestions/feedback will be loaded lazily when needed
    print('=== SUGGESTIONS DEBUG: UserService initialization (skipping feedback loading for faster startup) ===');
    
    // Pre-load engagement ranking since UserScreen loads on startup (needed for city info)
    print('USER SERVICE: Pre-loading engagement ranking...');
    try {
      await getUserEngagementRanking();
      print('USER SERVICE: Engagement ranking pre-loaded successfully');
    } catch (e) {
      print('USER SERVICE: Warning - could not pre-load engagement ranking: $e');
      // Don't fail initialization if this fails
    }
    
    print('SUGGESTIONS: UserService initialization completed (feedback will be loaded on-demand)');
    
    _isInitialized = true;
    
    // Track user properties in analytics
    await _updateAnalyticsUserProperties();
    
    notifyListeners();
  }
  
  // Update analytics user properties based on current state
  Future<void> _updateAnalyticsUserProperties() async {
    final analytics = AnalyticsService();
    final supabase = Supabase.instance.client;
    final isAuthenticated = supabase.auth.currentUser != null;
    
    // Build user properties
    final properties = {
      'is_authenticated': isAuthenticated,
      'notifications_enabled': _notifyResponses || _notifyQOTD || _notifyStreakReminders,
      'qotd_subscribed': _notifyQOTD,
      'streak_reminders_enabled': _notifyStreakReminders,
      'nsfw_enabled': _showNSFWContent,
      'boost_local_activity': _boostLocalActivity,
      'enabled_question_types': _enabledQuestionTypes,
      'enabled_categories': _enabledCategories,
      'total_questions_answered': _answeredQuestions.length,
      'total_questions_posted': _postedQuestions.length,
      'hide_answered_questions': _hideAnsweredQuestions,
    };
    
    await analytics.setUserProperties(properties);
  }

  Future<void> _loadFeedbackFromDatabase() async {
    print('=== SUGGESTIONS DEBUG: Starting _loadFeedbackFromDatabase() ===');
    try {
      final _supabase = Supabase.instance.client;
      
      print('SUGGESTIONS: Querying suggestions table...');
      
      // Get suggestions with vote counts using a more efficient approach
      final response = await _supabase
          .from('suggestions')
          .select('*')
          .order('created_at', ascending: false);
      
      print('SUGGESTIONS: Suggestions query completed. Found ${response?.length ?? 0} suggestions');
          
                if (response != null) {
        print('SUGGESTIONS: Processing ${response.length} suggestions from database');
        
        // Get all suggestion IDs to query votes efficiently
        final suggestionIds = response.map((item) => item['id']).toList();
        print('SUGGESTIONS: Getting vote counts for ${suggestionIds.length} suggestion IDs');
        
        // Get all votes for these suggestions in one query
        final allVotes = await _supabase
            .from('suggestion_votes')
            .select('suggestion_id')
            .inFilter('suggestion_id', suggestionIds);
        
        print('SUGGESTIONS: Retrieved ${allVotes?.length ?? 0} total votes from database');
        
        // Get all comments for these suggestions in one query
        final allComments = await _supabase
            .from('comments')
            .select('suggestion_id')
            .inFilter('suggestion_id', suggestionIds);
        
        print('SUGGESTIONS: Retrieved ${allComments?.length ?? 0} total comments from database');
        
        // Count votes per suggestion
        final voteCountsMap = <String, int>{};
        // Count comments per suggestion
        final commentCountsMap = <String, int>{};
        if (allVotes != null) {
          for (final vote in allVotes) {
            final suggestionId = vote['suggestion_id'].toString();
            voteCountsMap[suggestionId] = (voteCountsMap[suggestionId] ?? 0) + 1;
          }
        }
        
        if (allComments != null) {
          for (final comment in allComments) {
            final suggestionId = comment['suggestion_id'].toString();
            commentCountsMap[suggestionId] = (commentCountsMap[suggestionId] ?? 0) + 1;
          }
        }
        
        print('SUGGESTIONS: Vote counts map created with ${voteCountsMap.length} entries');
        print('SUGGESTIONS: Comment counts map created with ${commentCountsMap.length} entries');
        
        // Convert to our format with vote counts and comment counts
        _suggestions = response.map((item) {
          final suggestionId = item['id'].toString();
          final voteCount = voteCountsMap[suggestionId] ?? 0;
          final commentCount = commentCountsMap[suggestionId] ?? 0;
          
          return {
            'id': suggestionId,
            'text': item['suggestion'],
            'votes': voteCount,
            'comment_count': commentCount,
            'timestamp': item['created_at'],
            'userId': item['user_id'],
          };
        }).toList();
        
        print('SUGGESTIONS: Successfully loaded ${_suggestions.length} suggestions with vote counts');
      } else {
        print('SUGGESTIONS: No suggestions found in database response');
        _suggestions = [];
      }
    } catch (e) {
      print('SUGGESTIONS ERROR: Failed to load suggestions from database: $e');
      // If database load fails, try to load from local storage
      final String? jsonString = _prefs.getString('suggestions');
      if (jsonString != null) {
        print('SUGGESTIONS: Loading from local storage fallback');
        final List<dynamic> decoded = json.decode(jsonString);
        _suggestions = decoded.map((item) => Map<String, dynamic>.from(item)).toList();
        print('SUGGESTIONS: Loaded ${_suggestions.length} suggestions from local storage');
      } else {
        print('SUGGESTIONS: No local storage fallback available');
        _suggestions = [];
      }
    }
    
    // Mark suggestions as loaded
    _suggestionsLoaded = true;
    print('SUGGESTIONS: _loadFeedbackFromDatabase() completed. Total: ${_suggestions.length}');
  }

  void _loadQuestions(String key, List<Map<String, dynamic>> targetList) {
    final String? jsonString = _prefs.getString(key);
    if (jsonString != null) {
      final List<dynamic> decoded = json.decode(jsonString);
      targetList.clear();
      targetList.addAll(decoded.map((item) => Map<String, dynamic>.from(item)));
    }
  }

  Future<void> _saveQuestions(String key, List<Map<String, dynamic>> questions) async {
    final String jsonString = json.encode(questions);
    await _prefs.setString(key, jsonString);
  }

  Future<void> addAnsweredQuestion(Map<String, dynamic> question, {BuildContext? context}) async {
    if (!_answeredQuestions.any((q) => q['id'] == question['id'])) {
      // Calculate previous streak before adding the question
      final previousStreak = _calculateCurrentAnswerStreak(_answeredQuestions);
      final wasStreakExtendedToday = _hasExtendedStreakToday(_answeredQuestions);
      
      _answeredQuestions.add(question);
      await _saveQuestions(_answeredKey, _answeredQuestions);
      
      // Calculate new streak after adding the question
      final newStreak = _calculateCurrentAnswerStreak(_answeredQuestions);
      final isStreakExtendedToday = _hasExtendedStreakToday(_answeredQuestions);
      
      // Only trigger animation when streak is actually extended for the day AND previous streak was 1+
      if (!wasStreakExtendedToday && isStreakExtendedToday && previousStreak >= 1) {
        print('Streak extended! Previous: $previousStreak, New: $newStreak');
        StreakUpdateEvent.notifyStreakExtended(previousStreak, newStreak);
      } else if (previousStreak == 0) {
        print('First streak answer (0->1), no animation triggered');
      } else if (wasStreakExtendedToday) {
        print('Streak already extended today, no animation triggered');
      }
      
      // Handle streak reminder cancellation when user answers
      // Pass the user's custom reminder time and current streak for personalized messages
      try {
        final streakReminderService = StreakReminderService();
        await streakReminderService.onQuestionAnswered(_streakReminderTime, newStreak);
      } catch (e) {
        print('Error handling streak reminder after answering question: $e');
        // Don't let this error interrupt the normal flow
      }

      // Update home screen widget with new streak data
      try {
        await HomeWidgetService().updateWidget(
          streakCount: newStreak,
          hasExtendedToday: true,
        );
      } catch (e) {
        print('Error updating home widget after answering question: $e');
        // Don't let this error interrupt the normal flow
      }

      // Update QOTD widget if the answered question is the QOTD (Android only)
      try {
        final questionService = QuestionService();
        final qotd = questionService.questionOfTheDay;
        if (qotd != null) {
          final hasAnsweredQOTD = questionService.hasAnsweredQuestionOfTheDay(this);
          await HomeWidgetService().updateQOTDWidget(
            questionText: qotd['prompt']?.toString() ?? '',
            voteCount: qotd['votes'] as int? ?? 0,
            commentCount: qotd['comment_count'] as int? ?? 0,
            hasAnswered: hasAnsweredQOTD,
            questionId: qotd['id']?.toString() ?? '',
          );
        }
      } catch (e) {
        print('Error updating QOTD widget after answering question: $e');
        // Don't let this error interrupt the normal flow
      }

      // Check for achievements after answering questions
      if (context != null) {
        try {
          final achievementService = AchievementService(
            userService: this,
            context: context,
          );
          await achievementService.init();
          
          final congratulationsService = CongratulationsService(
            userService: this,
            achievementService: achievementService,
          );
          await congratulationsService.init();
          
          // Check for 10 questions answered achievement
          if (_answeredQuestions.length == 10) {
            await congratulationsService.showCongratulationsIfEligible(
              context,
              AchievementType.answered20Questions,
            );
          }
          
          // Check for Camo Counter top 20 achievement (check periodically)
          // Only check every 10 answered questions to avoid too many API calls
          if (_answeredQuestions.length % 10 == 0) {
            await congratulationsService.showCongratulationsIfEligible(
              context,
              AchievementType.camoTop20,
            );
          }
        } catch (e) {
          print('Error showing congratulations after answering question: $e');
          // Don't let this error interrupt the normal flow
        }
      }
      
      notifyListeners();
    }
  }

  // Remove a question from answered questions (useful if submission failed)
  void removeAnsweredQuestion(String questionId) {
    _answeredQuestions.removeWhere((q) => q['id']?.toString() == questionId);
    _saveQuestions(_answeredKey, _answeredQuestions);
    notifyListeners();
    print('Removed question $questionId from answered questions');
  }

  // Mark a question as answered by ID only (for guest migration)
  Future<void> _markQuestionAsAnsweredById(String questionId) async {
    // Check if already marked as answered
    if (_answeredQuestions.any((q) => q['id']?.toString() == questionId)) {
      print('Question $questionId already in answered list');
      return;
    }
    
    // Create a minimal question object with just the ID
    // This is sufficient for the hasAnsweredQuestion check
    final minimalQuestion = {'id': questionId};
    _answeredQuestions.add(minimalQuestion);
    
    await _saveQuestions(_answeredKey, _answeredQuestions);
    print('Added question $questionId to answered list (from guest migration)');
  }

  void addPostedQuestion(Map<String, dynamic> question) {
    if (!_postedQuestions.any((q) => q['id'] == question['id'])) {
      _postedQuestions.add(question);
      _saveQuestions(_postedKey, _postedQuestions);
      notifyListeners();
    }
  }

  void addSavedQuestion(Map<String, dynamic> question) {
    if (!_savedQuestions.any((q) => q['id'] == question['id'])) {
      // Add to the beginning of the list so most recently saved appears first
      _savedQuestions.insert(0, question);
      _saveQuestions(_savedKey, _savedQuestions);
      notifyListeners();
    }
  }

  void removeSavedQuestion(dynamic questionId) {
    _savedQuestions.removeWhere((q) => q['id'].toString() == questionId.toString());
    _saveQuestions(_savedKey, _savedQuestions);
    notifyListeners();
  }

  // Add methods to clear data if needed
  Future<void> clearAllData() async {
    _answeredQuestions.clear();
    _postedQuestions.clear();
    _savedQuestions.clear();
    await _prefs.remove(_answeredKey);
    await _prefs.remove(_postedKey);
    await _prefs.remove(_savedKey);
    notifyListeners();
  }

  void setUserLocation(String location) {
    _userLocation = location;
    notifyListeners();
  }

  void setNotifyResponses(bool value) async {
    _notifyResponses = value;
    _prefs.setBool(_notifyResponsesKey, value);
    
    // Handle FCM subscription for question activity
    final notificationService = NotificationService();
    if (value) {
      await notificationService.subscribeToQuestionActivity();
      print('Question activity notifications enabled - subscribed to q-activity topic');
    } else {
      await notificationService.unsubscribeFromQuestionActivity();
      print('Question activity notifications disabled - unsubscribed from q-activity topic');
    }
    
    notifyListeners();
  }

  void setNotifyQOTD(bool value) async {
    _notifyQOTD = value;
    _prefs.setBool(_notifyQOTDKey, value);

    // Handle FCM subscription
    final notificationService = NotificationService();
    // Handle local QOTD reminder scheduling
    final qotdReminderService = QOTDReminderService();
    if (value) {
      await notificationService.subscribeToQOTD();
      await qotdReminderService.setRemindersEnabled(true, _qotdReminderTime);
      print('QOTD notifications enabled - FCM topic subscribed, local reminders scheduled');
    } else {
      await notificationService.unsubscribeFromQOTD();
      await qotdReminderService.setRemindersEnabled(false);
      print('QOTD notifications disabled - FCM topic unsubscribed, local reminders cancelled');
    }

    notifyListeners();
  }

  void setNotifyStreakReminders(bool value) async {
    _notifyStreakReminders = value;
    _prefs.setBool(_notifyStreakRemindersKey, value);
    
    // Handle streak reminder scheduling
    final streakReminderService = StreakReminderService();
    await streakReminderService.setRemindersEnabled(value, _streakReminderTime);
    
    if (value) {
      print('Streak reminders enabled');
    } else {
      print('Streak reminders disabled');
    }
    
    notifyListeners();
  }

  void setStreakReminderTime(TimeOfDay time) async {
    _streakReminderTime = time;
    await _prefs.setInt(_streakReminderTimeKey + '_hour', time.hour);
    await _prefs.setInt(_streakReminderTimeKey + '_minute', time.minute);
    
    // If reminders are enabled, reschedule with the new time
    if (_notifyStreakReminders) {
      final streakReminderService = StreakReminderService();
      await streakReminderService.setRemindersEnabled(true, _streakReminderTime); // This will reschedule with new time
    }
    
    print('Streak reminder time set to ${time.hour}:${time.minute.toString().padLeft(2, '0')}');
    notifyListeners();
  }

  void setQotdReminderTime(TimeOfDay time) async {
    _qotdReminderTime = time;
    await _prefs.setInt(_qotdReminderTimeKey + '_hour', time.hour);
    await _prefs.setInt(_qotdReminderTimeKey + '_minute', time.minute);

    // If QOTD is enabled, reschedule with the new time
    if (_notifyQOTD) {
      final qotdReminderService = QOTDReminderService();
      await qotdReminderService.setRemindersEnabled(true, _qotdReminderTime);
    }

    print('QOTD reminder time set to ${time.hour}:${time.minute.toString().padLeft(2, '0')}');
    notifyListeners();
  }

  void setShowNSFWContent(bool value) {
    _showNSFWContent = value;
    if (value) {
      _hasEverEnabledNSFW = true;
      _prefs.setBool(_hasEverEnabledNSFWKey, true);
    }
    _prefs.setBool(_showNSFWKey, value);
    notifyListeners();
  }

  void setBoostLocalActivity(bool value) {
    _boostLocalActivity = value;
    _prefs.setBool(_boostLocalActivityKey, value);
    
    // Clear feed cache to force refresh with new boost setting
    // Note: We need to import and access QuestionService for this
    print('DEBUG: Boost local activity changed to: $value - feed cache should be cleared');
    
    notifyListeners();
  }

  void setHideAnsweredQuestions(bool value) {
    _hideAnsweredQuestions = value;
    _prefs.setBool(_hideAnsweredKey, value);
    notifyListeners();
  }

  void toggleCategory(String categoryName) {
    if (_enabledCategories.contains(categoryName)) {
      _enabledCategories.remove(categoryName);
    } else {
      _enabledCategories.add(categoryName);
    }
    _prefs.setStringList(_enabledCategoriesKey, _enabledCategories);
    notifyListeners();
  }

  // Enable all categories
  void enableAllCategories() {
    _enabledCategories = app_category.Category.allCategories.map((c) => c.name).toList();
    _prefs.setStringList(_enabledCategoriesKey, _enabledCategories);
    notifyListeners();
  }

  // Toggle question type preference
  void toggleQuestionType(String typeId) {
    if (_enabledQuestionTypes.contains(typeId)) {
      // Only remove if it's not the last enabled type
      if (_enabledQuestionTypes.length > 1) {
        _enabledQuestionTypes.remove(typeId);
      }
    } else {
      _enabledQuestionTypes.add(typeId);
    }
    
    // Save to preferences
    _prefs.setStringList(_enabledQuestionTypesKey, _enabledQuestionTypes);
    
    notifyListeners();
  }

  // Check if a question type is enabled
  bool isQuestionTypeEnabled(String typeId) {
    return _enabledQuestionTypes.contains(typeId);
  }

  // Helper method to check if a question has been answered
  bool hasAnsweredQuestion(dynamic questionId) {
    return _answeredQuestions.any((q) => q['id'].toString() == questionId.toString());
  }

  void reportQuestion(String questionId, [List<String>? reasons]) {
    if (!_reportedQuestionIds.contains(questionId)) {
      _reportedQuestionIds.add(questionId);
      _prefs.setStringList(_reportedKey, _reportedQuestionIds);
      
      // Store reasons if provided
      if (reasons != null && reasons.isNotEmpty) {
        _reportedQuestionReasons[questionId] = reasons;
        _prefs.setString(_reportedReasonsKey, json.encode(_reportedQuestionReasons));
      }
      
      _lastReportTime = DateTime.now();
      notifyListeners();
    }
  }

  bool isQuestionReported(String questionId) {
    return _reportedQuestionIds.contains(questionId);
  }
  
  // Check if a question should be hidden based on report reasons
  bool shouldHideReportedQuestion(String questionId) {
    if (!_reportedQuestionIds.contains(questionId)) {
      return false; // Not reported, don't hide
    }
    
    // Get reasons for this question
    final reasons = _reportedQuestionReasons[questionId];
    if (reasons == null || reasons.isEmpty) {
      return true; // No reasons stored, assume it should be hidden (legacy behavior)
    }
    
    // Define helpful reasons that shouldn't cause hiding
    final helpfulReasons = {'Not marked as NSFW/18+', 'Not categorized correctly'};
    
    // Only hide if there are non-helpful reasons
    return reasons.any((reason) => !helpfulReasons.contains(reason));
  }
  
  // Get report reasons for a question
  List<String>? getReportReasons(String questionId) {
    return _reportedQuestionReasons[questionId];
  }

  bool canReport() {
    if (_lastReportTime == null) return true;
    return DateTime.now().difference(_lastReportTime!).inSeconds >= 60;
  }

  int getReportCooldownSeconds() {
    if (_lastReportTime == null) return 0;
    final elapsed = DateTime.now().difference(_lastReportTime!).inSeconds;
    return (60 - elapsed).clamp(0, 60);
  }

  // Dismissed questions methods
  void dismissQuestion(String questionId) {
    if (!_dismissedQuestionIds.contains(questionId)) {
      _dismissedQuestionIds.add(questionId);
      _prefs.setStringList(_dismissedKey, _dismissedQuestionIds);
      notifyListeners();
    }
  }

  void undismissQuestion(String questionId) {
    if (_dismissedQuestionIds.contains(questionId)) {
      _dismissedQuestionIds.remove(questionId);
      _prefs.setStringList(_dismissedKey, _dismissedQuestionIds);
      notifyListeners();
    }
  }

  bool isQuestionDismissed(String questionId) {
    return _dismissedQuestionIds.contains(questionId);
  }

  void addSuggestion(Map<String, dynamic> suggestion) {
    final _supabase = Supabase.instance.client;
    
    // Check if user is authenticated
    if (_supabase.auth.currentUser == null) {
      print('Error: User must be authenticated to submit suggestions');
      return;
    }
    
    // Remove the ID from the suggestion as it will be generated by the database
    final suggestionToSubmit = Map<String, dynamic>.from(suggestion);
    suggestionToSubmit.remove('id');
    
    // Add to local list first for immediate feedback
    _suggestions.insert(0, suggestion);
    notifyListeners();
    
    // Submit to database
    _submitSuggestionToDatabase(suggestionToSubmit).then((databaseId) {
      if (databaseId != null) {
        // Update the local suggestion with the database ID
        suggestion['id'] = databaseId;
        notifyListeners();
      }
    });
  }

  Future<String?> _submitSuggestionToDatabase(Map<String, dynamic> suggestion) async {
    try {
      final _supabase = Supabase.instance.client;
      
      // Get the current user's ID
      final user = _supabase.auth.currentUser;
      if (user == null) {
        print('Error: User must be authenticated to submit suggestions');
        return null;
      }
      
      // Create the suggestion record
      final suggestionData = {
        'suggestion': suggestion['text'],
        'user_id': user.id, // Use the authenticated user's UUID
        'created_at': suggestion['timestamp'],
      };
      
      // Insert into Supabase and get the response with the new ID
      final response = await _supabase
          .from('suggestions')
          .insert(suggestionData)
          .select()
          .single();
          
      if (response != null) {
        print('Suggestion submitted to database successfully with ID: ${response['id']}');
        
        // Auto-subscribe suggestion author
        try {
          final commentService = CommentService();
          await commentService.autoSubscribeToSuggestion(response['id'], user.id, 'author');
          print('✅ Auto-subscribed suggestion author to suggestion ${response['id']}');
        } catch (e) {
          print('❌ Error auto-subscribing suggestion author: $e');
          // Don't fail suggestion creation if subscription fails
        }
        
        return response['id'].toString();
      }
      return null;
    } catch (e) {
      print('Error submitting suggestion to database: $e');
      // Continue with local storage even if database submission fails
      return null;
    }
  }

  bool hasVotedSuggestion(String suggestionId) {
    return _votedSuggestions.contains(suggestionId);
  }

  // Question rating tracking methods
  bool hasRatedQuestion(String questionId) {
    return _ratedQuestions.contains(questionId);
  }

  double? getQuestionRating(String questionId) {
    return _questionRatingValues[questionId];
  }

  Future<void> setQuestionRating(String questionId, double value) async {
    _ratedQuestions.add(questionId);
    _questionRatingValues[questionId] = value;
    _prefs.setStringList(_ratedQuestionsKey, _ratedQuestions.toList());
    _prefs.setString(_questionRatingValuesKey, json.encode(_questionRatingValues));
    notifyListeners();
  }

  Future<void> clearQuestionRating(String questionId) async {
    _ratedQuestions.remove(questionId);
    _questionRatingValues.remove(questionId);
    _prefs.setStringList(_ratedQuestionsKey, _ratedQuestions.toList());
    _prefs.setString(_questionRatingValuesKey, json.encode(_questionRatingValues));
    notifyListeners();
  }

  // Check if user has actually voted in the database (for debugging/sync)
  Future<bool> hasVotedSuggestionInDatabase(String suggestionId) async {
    try {
      final _supabase = Supabase.instance.client;
      final user = _supabase.auth.currentUser;
      
      if (user == null) {
        return false; // Not authenticated, can't have voted
      }
      
      final vote = await _supabase
          .from('suggestion_votes')
          .select('id')
          .eq('suggestion_id', suggestionId)
          .eq('user_id', user.id)
          .maybeSingle();
          
      return vote != null;
    } catch (e) {
      print('ERROR: Failed to check vote status in database: $e');
      return false;
    }
  }

  // Vote on a suggestion - returns true if successful, false if authentication required
  Future<bool> voteSuggestion(String suggestionId) async {
    final _supabase = Supabase.instance.client;
    final user = _supabase.auth.currentUser;
    
    if (user == null) {
      print('DEBUG: Authentication required for voting');
      return false; // Signal that authentication is required
    }
    
    print('DEBUG: User voting for suggestion $suggestionId');
    
    try {
      // Add vote to database first
      await _addVoteToDatabase(suggestionId);
      
      // Update local vote count for immediate UI feedback
      final suggestion = _suggestions.firstWhere((s) => s['id'] == suggestionId);
      final oldVotes = suggestion['votes'] ?? 0;
      suggestion['votes'] = oldVotes + 1;
      _votedSuggestions.add(suggestionId);
      
      print('DEBUG: Updated local vote count from $oldVotes to ${suggestion['votes']}');
      
      // Persist voted suggestions to local storage
      _prefs.setStringList(_votedSuggestionsKey, _votedSuggestions.toList());
      
      notifyListeners();
      
      print('DEBUG: Vote submission completed for suggestion $suggestionId');
      return true;
    } catch (e) {
      print('ERROR: Vote submission failed: $e');
      
      // Check if this is a duplicate vote error (user already voted)
      if (e.toString().contains('duplicate key value violates unique constraint')) {
        print('DEBUG: User has already voted for this suggestion');
        // Update local state to reflect they have voted
        if (!_votedSuggestions.contains(suggestionId)) {
          _votedSuggestions.add(suggestionId);
          _prefs.setStringList(_votedSuggestionsKey, _votedSuggestions.toList());
          notifyListeners();
        }
        return true; // Don't show authentication error for duplicate votes
      }
      
      return false; // Show authentication error for other failures
    }
  }

  // Remove vote from suggestion - returns true if successful, false if authentication required
  Future<bool> removeVoteSuggestion(String suggestionId) async {
    final _supabase = Supabase.instance.client;
    final user = _supabase.auth.currentUser;
    
    if (user == null) {
      print('DEBUG: Authentication required for removing vote');
      return false; // Signal that authentication is required
    }
    
    print('DEBUG: User removing vote for suggestion $suggestionId');
    
    // Check local vs database state for debugging
    final localHasVoted = _votedSuggestions.contains(suggestionId);
    final dbHasVoted = await hasVotedSuggestionInDatabase(suggestionId);
    print('DEBUG: Vote state check - Local: $localHasVoted, Database: $dbHasVoted');
    
    if (!dbHasVoted) {
      print('DEBUG: No vote found in database to remove, but updating local state');
      // Update local state to match database
      _votedSuggestions.remove(suggestionId);
      _prefs.setStringList(_votedSuggestionsKey, _votedSuggestions.toList());
      notifyListeners();
      return true; // Consider this successful since the desired state is achieved
    }
    
    try {
      // Remove vote from database first
      await _removeVoteFromDatabase(suggestionId);
      
      // Update local vote count
      final suggestion = _suggestions.firstWhere((s) => s['id'] == suggestionId);
      final oldVotes = suggestion['votes'] ?? 0;
      suggestion['votes'] = Math.max(0, oldVotes - 1); // Prevent negative votes
      _votedSuggestions.remove(suggestionId);
      
      print('DEBUG: Updated local vote count from $oldVotes to ${suggestion['votes']}');
      
      // Persist voted suggestions to local storage
      _prefs.setStringList(_votedSuggestionsKey, _votedSuggestions.toList());
      
      notifyListeners();
      
      print('DEBUG: Vote removal completed for suggestion $suggestionId');
      return true;
    } catch (e) {
      print('ERROR: Remove vote failed: $e');
      return false;
    }
  }

  Future<void> _addVoteToDatabase(String suggestionId) async {
    try {
      final _supabase = Supabase.instance.client;
      final user = _supabase.auth.currentUser;
      
      if (user == null) {
        throw Exception('User must be authenticated to vote');
      }
      
      print('DEBUG: Adding vote for suggestion $suggestionId by user ${user.id}');
      
      // Prepare vote data with user_id (no location data needed)
      final voteData = {
        'suggestion_id': suggestionId,
        'user_id': user.id,
      };
      
      print('DEBUG: Vote data to insert: $voteData');
      
      // Add vote to suggestion_votes table
      final response = await _supabase
          .from('suggestion_votes')
          .insert(voteData)
          .select();
          
      print('SUCCESS: Added vote to database for suggestion $suggestionId');
      print('DEBUG: Database response: $response');
    } catch (e) {
      print('ERROR: Failed to add vote to database for suggestion $suggestionId: $e');
      print('ERROR: Exception details: ${e.toString()}');
      rethrow; // Re-throw to handle in calling method
    }
  }

  Future<void> _removeVoteFromDatabase(String suggestionId) async {
    try {
      final _supabase = Supabase.instance.client;
      final user = _supabase.auth.currentUser;
      
      if (user == null) {
        throw Exception('User must be authenticated to remove vote');
      }
      
      print('DEBUG: Attempting to delete vote for suggestion $suggestionId by user ${user.id}');
      
      // First, check if the vote exists
      final existingVote = await _supabase
          .from('suggestion_votes')
          .select('id')
          .eq('suggestion_id', suggestionId)
          .eq('user_id', user.id)
          .maybeSingle();
          
      if (existingVote == null) {
        print('DEBUG: No vote found to delete - user has not voted for this suggestion');
        return; // No vote to delete
      }
      
      // Remove the user's vote for this suggestion
      final response = await _supabase
          .from('suggestion_votes')
          .delete()
          .eq('suggestion_id', suggestionId)
          .eq('user_id', user.id)
          .select();
          
      if (response.isNotEmpty) {
        print('SUCCESS: Successfully deleted vote for suggestion $suggestionId');
      } else {
        print('WARNING: Delete operation returned empty response');
      }
    } catch (e) {
      print('ERROR: Failed to remove vote from database: $e');
      rethrow; // Re-throw to handle in calling method
    }
  }

  // Public method to ensure suggestions are loaded (for preloading before navigation)
  Future<void> ensureSuggestionsLoaded() async {
    if (!_suggestionsLoaded || _suggestions.isEmpty) {
      print('=== SUGGESTIONS DEBUG: ensureSuggestionsLoaded() - loading suggestions ===');
      await _loadFeedbackFromDatabase();
      notifyListeners();
    } else {
      print('=== SUGGESTIONS DEBUG: ensureSuggestionsLoaded() - suggestions already loaded (${_suggestions.length}) ===');
    }
  }

  // Public method to refresh feedback from database
  Future<void> refreshFeedback() async {
    print('=== SUGGESTIONS DEBUG: refreshFeedback() called ===');
    _suggestionsLoaded = false; // Reset flag to allow reload
    await _loadFeedbackFromDatabase();
    print('SUGGESTIONS: refreshFeedback() completed, calling notifyListeners()');
    notifyListeners();
  }

  /// Get suggestions by their IDs (for linked suggestions)
  Future<List<Map<String, dynamic>>> getSuggestionsByIds(List<String> suggestionIds) async {
    if (suggestionIds.isEmpty) {
      return [];
    }
    
    final _supabase = Supabase.instance.client;
    
    try {
      print('SUGGESTIONS: Fetching suggestions by IDs: $suggestionIds');
      
      // Fetch suggestions data
      final suggestionsResponse = await _supabase
          .from('suggestions')
          .select('*')
          .inFilter('id', suggestionIds);
      
      // Fetch vote counts for these suggestions
      final votesResponse = await _supabase
          .from('suggestion_votes')
          .select('suggestion_id')
          .inFilter('suggestion_id', suggestionIds);
      
      // Fetch comment counts for these suggestions
      final commentsResponse = await _supabase
          .from('comments')
          .select('suggestion_id')
          .inFilter('suggestion_id', suggestionIds);
      
      // Create vote counts map
      final Map<String, int> voteCountsMap = {};
      for (final vote in votesResponse) {
        final suggestionId = vote['suggestion_id'].toString();
        voteCountsMap[suggestionId] = (voteCountsMap[suggestionId] ?? 0) + 1;
      }
      
      // Create comment counts map
      final Map<String, int> commentCountsMap = {};
      for (final comment in commentsResponse) {
        final suggestionId = comment['suggestion_id'].toString();
        commentCountsMap[suggestionId] = (commentCountsMap[suggestionId] ?? 0) + 1;
      }
      
      List<Map<String, dynamic>> suggestions = [];
      
      for (final suggestion in suggestionsResponse) {
        final suggestionId = suggestion['id'].toString();
        final voteCount = voteCountsMap[suggestionId] ?? 0;
        final commentCount = commentCountsMap[suggestionId] ?? 0;
        
        final suggestionData = {
          'id': suggestionId,
          'suggestion': suggestion['suggestion'],
          'text': suggestion['suggestion'], // Maintain compatibility
          'votes': voteCount,
          'comment_count': commentCount,
          'timestamp': suggestion['created_at'],
          'created_at': suggestion['created_at'],
          'user_id': suggestion['user_id'],
        };
        
        suggestions.add(suggestionData);
      }
      
      print('SUGGESTIONS: Successfully fetched ${suggestions.length} suggestions by IDs');
      return suggestions;
    } catch (e) {
      print('Error fetching suggestions by IDs: $e');
      return [];
    }
  }

  // Test method to force refresh suggestions bypassing cache
  Future<void> forceRefreshSuggestions() async {
    print('=== SUGGESTIONS DEBUG: FORCE REFRESH - clearing cache ===');
    // Clear local storage cache
    await _prefs.remove('suggestions');
    _suggestions.clear();
    _suggestionsLoaded = false; // Reset flag to allow reload
    
    // Force reload from database
    await _loadFeedbackFromDatabase();
    print('SUGGESTIONS: Force refresh completed');
    notifyListeners();
  }

  // Handle authentication state changes
  Future<void> onAuthStateChanged([dynamic guestTrackingService]) async {
    final supabase = Supabase.instance.client;
    final isAuthenticated = supabase.auth.currentUser != null;
    final analytics = AnalyticsService();
    
    print('Auth state changed - authenticated: $isAuthenticated');
    
    // Track authentication state and identify user
    if (isAuthenticated) {
      final user = supabase.auth.currentUser!;
      await analytics.identifyUser(
        user.id, 
        {
          'email': user.email,
          'is_authenticated': true,
          'auth_provider': user.appMetadata['provider'] ?? 'unknown',
        },
        {
          'account_created_at': user.createdAt,
          'first_login_at': DateTime.now().toIso8601String(),
        }
      );
      
      // Track authentication completion
      await analytics.trackEvent('onboarding_auth_completed', {
        'auth_method': user.appMetadata['provider'] ?? 'unknown',
      });
    } else {
      // User logged out
      await analytics.reset();
    }
    
    // Migrate guest-viewed questions to authenticated user's answered list
    if (isAuthenticated && guestTrackingService != null) {
      print('User authenticated - migrating guest-viewed questions to answered list');
      await _migrateGuestViewedQuestions(guestTrackingService);
    }
    
    // Update question type preferences based on new auth state
    if (isAuthenticated && !_enabledQuestionTypes.contains('text')) {
      // User just signed in - enable text questions by default
      _enabledQuestionTypes.add('text');
      await _prefs.setStringList(_enabledQuestionTypesKey, _enabledQuestionTypes);
      print('Enabled text questions for authenticated user');
      notifyListeners();
    } else if (!isAuthenticated && _enabledQuestionTypes.contains('text')) {
      // User just signed out - disable text questions
      _enabledQuestionTypes.remove('text');
      await _prefs.setStringList(_enabledQuestionTypesKey, _enabledQuestionTypes);
      print('Disabled text questions for unauthenticated user');
      notifyListeners();
    }
    
    // Note: Feedback/suggestions are now loaded only when explicitly requested
    // (when user visits feedback screen) to improve startup performance
  }

  /// Migrate guest-viewed questions to authenticated user's answered list
  Future<void> _migrateGuestViewedQuestions(dynamic guestTrackingService) async {
    try {
      // Ensure guest tracking service is initialized
      await guestTrackingService.waitForInitialization();
      
      // Get all guest-viewed question IDs
      final guestViewedIds = guestTrackingService.viewedQuestionIds;
      
      if (guestViewedIds.isEmpty) {
        print('No guest-viewed questions to migrate');
        await guestTrackingService.clearGuestData();
        return;
      }
      
      print('Migrating ${guestViewedIds.length} guest-viewed questions to authenticated answered list');
      
      // Add all guest-viewed questions to the authenticated user's answered list
      for (final questionId in guestViewedIds) {
        await _markQuestionAsAnsweredById(questionId);
        print('✅ Migrated guest question $questionId to answered list');
      }
      
      // Clear guest tracking data after successful migration
      await guestTrackingService.clearGuestData();
      
      print('✅ Successfully migrated ${guestViewedIds.length} guest-viewed questions to authenticated user');
      
      // Notify listeners to refresh UI
      notifyListeners();
      
    } catch (e) {
      print('❌ Error migrating guest-viewed questions: $e');
      // Still clear guest data even on error to prevent future issues
      try {
        await guestTrackingService.clearGuestData();
      } catch (clearError) {
        print('❌ Error clearing guest data after migration failure: $clearError');
      }
    }
  }

  /// Attempt automatic Android device ID migration on app startup
  Future<void> _attemptAutomaticMigration() async {
    try {
      // Only proceed if this is Android platform
      if (!Platform.isAndroid) {
        return;
      }
      
      // Check if user is authenticated
      final supabase = Supabase.instance.client;
      if (supabase.auth.currentUser == null) {
        return;
      }
      
      // Check if device has legacy Android ID
      final isLegacy = await DeviceIdProvider.isLegacyAndroidId();
      if (!isLegacy) {
        return;
      }
      
      // Check if migration was already successful
      final migrationSuccess = _prefs.getBool(_migrationSuccessKey) ?? false;
      if (migrationSuccess) {
        return;
      }
      
      // Check migration attempt history to prevent infinite retries
      final attemptCount = _prefs.getInt(_migrationAttemptCountKey) ?? 0;
      final lastAttemptString = _prefs.getString(_lastMigrationAttemptKey);
      
      // If too many attempts, don't retry automatically
      if (attemptCount >= 3) {
        print('🔐 UserService: Automatic migration disabled - too many failed attempts ($attemptCount)');
        return;
      }
      
      // If last attempt was recent (within 1 hour), don't retry
      if (lastAttemptString != null) {
        final lastAttempt = DateTime.tryParse(lastAttemptString);
        if (lastAttempt != null && DateTime.now().difference(lastAttempt).inHours < 1) {
          print('🔐 UserService: Automatic migration skipped - recent attempt (${DateTime.now().difference(lastAttempt).inMinutes} minutes ago)');
          return;
        }
      }
      
      print('🔐 UserService: Starting automatic Android device ID migration (attempt ${attemptCount + 1}/3)');
      
      // Update attempt tracking
      await _prefs.setInt(_migrationAttemptCountKey, attemptCount + 1);
      await _prefs.setString(_lastMigrationAttemptKey, DateTime.now().toIso8601String());
      
      // Attempt migration
      final passkeysService = PasskeysService();
      final success = await passkeysService.migrateDeviceId();
      
      if (success) {
        print('🔐 UserService: ✅ Automatic migration successful!');
        await _prefs.setBool(_migrationSuccessKey, true);
        
        // Reset attempt counter on success
        await _prefs.remove(_migrationAttemptCountKey);
        await _prefs.remove(_lastMigrationAttemptKey);
        
        // Notify listeners for UI updates
        notifyListeners();
      } else {
        print('🔐 UserService: ❌ Automatic migration failed (attempt ${attemptCount + 1}/3)');
      }
      
    } catch (e) {
      print('🔐 UserService: ❌ Automatic migration error: $e');
    }
  }

  // Get filtered lists that exclude hidden questions
  Future<List<Map<String, dynamic>>> getFilteredAnsweredQuestions(dynamic questionService) async {
    final filteredQuestions = await _filterHiddenQuestions(_answeredQuestions, questionService);
    
    // Populate missing fields for minimal questions (from guest migration)
    await _populateMissingQuestionFields(filteredQuestions, questionService);
    
    // Update vote counts from database for answered questions
    await _refreshVoteCountsForQuestions(filteredQuestions);
    
    return filteredQuestions;
  }
  
  Future<List<Map<String, dynamic>>> getFilteredPostedQuestions(dynamic questionService) async {
    final filteredQuestions = await _filterHiddenQuestions(_postedQuestions, questionService);
    
    // Populate missing fields for minimal questions
    await _populateMissingQuestionFields(filteredQuestions, questionService);
    
    // Update vote counts from database for posted questions
    await _refreshVoteCountsForQuestions(filteredQuestions);
    
    return filteredQuestions;
  }
  
  Future<List<Map<String, dynamic>>> getFilteredSavedQuestions(dynamic questionService) async {
    final filteredQuestions = await _filterHiddenQuestions(_savedQuestions, questionService);
    
    // Populate missing fields for minimal questions
    await _populateMissingQuestionFields(filteredQuestions, questionService);
    
    // Update vote counts from database for saved questions
    await _refreshVoteCountsForQuestions(filteredQuestions);
    
    return filteredQuestions;
  }
  
  Future<List<Map<String, dynamic>>> getFilteredDismissedQuestions(dynamic questionService) async {
    if (_dismissedQuestionIds.isEmpty) return [];
    
    try {
      // Fetch dismissed questions from database by their IDs
      final dismissedQuestions = await questionService.getQuestionsByIds(_dismissedQuestionIds);
      
      // Filter out hidden questions
      final filteredQuestions = await _filterHiddenQuestions(dismissedQuestions, questionService);
      
      // Update vote counts from database for dismissed questions
      await _refreshVoteCountsForQuestions(filteredQuestions);
      
      return filteredQuestions;
    } catch (e) {
      print('Error fetching dismissed questions: $e');
      return [];
    }
  }
  
  Future<List<Map<String, dynamic>>> getFilteredCommentedQuestions(dynamic questionService) async {
    if (!_isInitialized) {
      print('UserService not initialized when fetching commented questions');
      return [];
    }
    
    final currentUserId = Supabase.instance.client.auth.currentUser?.id;
    if (currentUserId == null) {
      print('No current user ID when fetching commented questions');
      return [];
    }
    
    print('Fetching commented questions for user: $currentUserId');
    
    try {
      // Query comments table to get questions where user has commented
      // Only get comments on questions (not suggestions)
      final commentsResponse = await Supabase.instance.client
          .from('comments')
          .select('question_id')
          .eq('author_id', currentUserId)
          .eq('is_hidden', false)
          .not('question_id', 'is', null);
      
      print('Comments query response: ${commentsResponse?.length ?? 0} comments found');
      
      if (commentsResponse == null || commentsResponse.isEmpty) {
        print('No comments found for user $currentUserId');
        // Try alternative query to debug
        final allCommentsResponse = await Supabase.instance.client
            .from('comments')
            .select('question_id, author_id')
            .eq('author_id', currentUserId);
        print('Debug: All comments for user (including hidden): ${allCommentsResponse?.length ?? 0}');
        return [];
      }
      
      // Extract unique question IDs, filtering out nulls
      final questionIds = commentsResponse
          .where((comment) => comment['question_id'] != null)
          .map<String>((comment) => comment['question_id'].toString())
          .toSet()
          .toList();
      
      print('Unique question IDs from comments: ${questionIds.length} questions');
      
      if (questionIds.isEmpty) return [];
      
      // Fetch the actual questions using the question service
      final commentedQuestions = await questionService.getQuestionsByIds(questionIds);
      
      print('Fetched ${commentedQuestions.length} questions from question service');
      
      // Filter out hidden questions
      final filteredQuestions = await _filterHiddenQuestions(commentedQuestions, questionService);
      
      print('After filtering hidden questions: ${filteredQuestions.length} questions remain');
      
      // Update vote counts from database for commented questions
      await _refreshVoteCountsForQuestions(filteredQuestions);
      
      return filteredQuestions;
    } catch (e) {
      print('Error fetching commented questions: $e');
      print('Stack trace: ${StackTrace.current}');
      return [];
    }
  }
  
  // Helper method to filter out hidden and private questions
  Future<List<Map<String, dynamic>>> _filterHiddenQuestions(List<Map<String, dynamic>> questions, dynamic questionService) async {
    if (questions.isEmpty) return questions;
    
    try {
      final questionIds = questions.map((q) => q['id'].toString()).toList();
      // print('DEBUG: _filterHiddenQuestions - Starting with ${questions.length} questions');
      
      // Get both hidden and existing question IDs
      final hiddenIds = await questionService.getHiddenQuestionIds(questionIds);
      final existingIds = await questionService.getExistingQuestionIds(questionIds);
      
      // print('DEBUG: _filterHiddenQuestions - hiddenIds: ${hiddenIds.length} hidden');
      // print('DEBUG: _filterHiddenQuestions - existingIds: ${existingIds.length} existing');
      
      // Get complete question data to check for private questions (include hidden for accurate filtering)
      final completeQuestions = await questionService.getQuestionsByIds(questionIds, includeHidden: true);
      // print('DEBUG: _filterHiddenQuestions - getQuestionsByIds returned ${completeQuestions.length} questions');
      
      final privateQuestionIds = completeQuestions
          .where((q) => q['is_private'] == true)
          .map((q) => q['id'].toString())
          .toSet();
      
      // print('DEBUG: _filterHiddenQuestions - privateQuestionIds: ${privateQuestionIds.length} private');
      
      final filteredQuestions = questions.where((question) {
        final questionId = question['id'].toString();
        final exists = existingIds.contains(questionId);
        final notHidden = !hiddenIds.contains(questionId);
        final notPrivate = !privateQuestionIds.contains(questionId);
        
        // Only log individual filter-outs when debugging specific issues
        // if (!exists || !notHidden || !notPrivate) {
        //   print('DEBUG: _filterHiddenQuestions - Filtering out question $questionId: exists=$exists, notHidden=$notHidden, notPrivate=$notPrivate');
        // }
        
        // Keep only questions that exist in database AND are not hidden AND are not private
        return exists && notHidden && notPrivate;
      }).toList();
      
      print('DEBUG: _filterHiddenQuestions - Returning ${filteredQuestions.length} questions after filtering ${questions.length} total');
      return filteredQuestions;
    } catch (e) {
      print('Error filtering hidden and private questions: $e');
      // print('DEBUG: _filterHiddenQuestions - Exception occurred, returning original ${questions.length} questions');
      return questions; // Return original list if filtering fails
    }
  }

  // Helper method to populate missing fields for minimal questions
  Future<void> _populateMissingQuestionFields(List<Map<String, dynamic>> questions, dynamic questionService) async {
    if (questions.isEmpty) return;
    
    try {
      // Find questions that are missing essential fields (minimal questions from guest migration)
      final minimalQuestions = questions.where((question) {
        return question['prompt'] == null && 
               question['title'] == null && 
               question['timestamp'] == null && 
               question['created_at'] == null &&
               question['id'] != null;
      }).toList();
      
      if (minimalQuestions.isEmpty) return;
      
      // Get question IDs that need to be populated
      final questionIds = minimalQuestions.map((q) => q['id'].toString()).toList();
      
      // Fetch complete question data from database
      final completeQuestions = await questionService.getQuestionsByIds(questionIds);
      
      // Create a map for quick lookup
      final Map<String, Map<String, dynamic>> completeQuestionsMap = {};
      for (final question in completeQuestions) {
        if (question['id'] != null) {
          completeQuestionsMap[question['id'].toString()] = question;
        }
      }
      
      // Update minimal questions with complete data
      for (final minimalQuestion in minimalQuestions) {
        final questionId = minimalQuestion['id'].toString();
        final completeQuestion = completeQuestionsMap[questionId];
        
        if (completeQuestion != null) {
          // Populate missing fields
          minimalQuestion['prompt'] = completeQuestion['prompt'];
          minimalQuestion['title'] = completeQuestion['title'];
          minimalQuestion['type'] = completeQuestion['type'];
          minimalQuestion['timestamp'] = completeQuestion['timestamp'];
          minimalQuestion['created_at'] = completeQuestion['created_at'];
          minimalQuestion['votes'] = completeQuestion['votes'];
          
          // Copy any other essential fields
          minimalQuestion.addAll(completeQuestion);
        }
      }
      
      // Save updated questions back to SharedPreferences
      await _saveQuestions(_answeredKey, _answeredQuestions);
      
      print('Populated missing fields for ${minimalQuestions.length} minimal questions');
    } catch (e) {
      print('Error populating missing question fields: $e');
      // Don't throw - just continue with existing data
    }
  }

  // Helper method to refresh vote counts for questions using centralized logic
  Future<void> _refreshVoteCountsForQuestions(List<Map<String, dynamic>> questions) async {
    if (questions.isEmpty) return;
    
    // Check if any questions are missing vote counts (null means not fetched yet)
    final hasMissingVotes = questions.any((q) => q['votes'] == null);
    
    // Check if we've refreshed recently AND all questions have vote counts
    final now = DateTime.now();
    if (!hasMissingVotes && 
        _lastVoteCountRefresh != null && 
        now.difference(_lastVoteCountRefresh!) < _voteCountCacheDuration) {
      return;
    }
    
    try {
      // Use centralized vote counting from QuestionService (singleton)
      final questionService = QuestionService();
      
      // Batch update vote counts for better performance
      final questionIds = questions
          .map((q) => q['id']?.toString())
          .where((id) => id != null && id.isNotEmpty)
          .cast<String>()
          .toList();
      
      if (questionIds.isEmpty) return;
      
      // Get fresh vote counts from database in batch
      final _supabase = Supabase.instance.client;
      final responsesResponse = await _supabase
          .from('responses')
          .select('question_id')
          .inFilter('question_id', questionIds);

      // Count responses per question
      final Map<String, int> voteCounts = {};
      if (responsesResponse != null && responsesResponse is List) {
        for (final response in responsesResponse) {
          if (response != null && response is Map<String, dynamic>) {
            final questionId = response['question_id']?.toString();
            if (questionId != null && questionId.isNotEmpty) {
              voteCounts[questionId] = (voteCounts[questionId] ?? 0) + 1;
            }
          }
        }
      }
      
      // Update vote counts in the questions list
      int updatedCount = 0;
      for (var question in questions) {
        if (question != null && question is Map<String, dynamic>) {
          final questionId = question['id']?.toString();
          if (questionId != null && questionId.isNotEmpty) {
            final newVotes = voteCounts[questionId] ?? 0;
            if (question['votes'] != newVotes) {
              question['votes'] = newVotes;
              updatedCount++;
            }
          } else {
            question['votes'] = 0;
          }
        }
      }
      
      // Update cache timestamp only if we successfully updated
      _lastVoteCountRefresh = now;
      
      if (updatedCount > 0) {
        print('Updated vote counts for $updatedCount questions');
        // Expire timestamp to trigger fresh fetch, but keep stale data for UI fallback
        _lastEngagementRankingRefresh = null;
      }
      
    } catch (e) {
      print('Error refreshing vote counts: $e');
      // Don't update cache timestamp on error to allow retry
    }
  }

  void setNotificationPermissionShown(bool shown) {
    _notificationPermissionShown = shown;
    _prefs.setBool(_notificationPermissionShownKey, shown);
    notifyListeners();
  }

  // Get user engagement ranking with caching - now using materialized view
  Future<Map<String, dynamic>> getUserEngagementRanking({bool forceRefresh = false}) async {
    final now = DateTime.now();
    
    // Check startup cache first (fastest)
    if (!forceRefresh) {
      final cachedData = _startupCache.getUserData<Map<String, dynamic>>('engagement_ranking');
      if (cachedData != null) {
        print('Using startup cache for engagement ranking data');
        return cachedData;
      }
    }
    
    // Check if we have local cached data and it's still valid
    if (!forceRefresh && 
        _cachedEngagementRanking != null && 
        _lastEngagementRankingRefresh != null &&
        now.difference(_lastEngagementRankingRefresh!) < _engagementRankingCacheDuration) {
      print('Using local cached engagement ranking data');
      // Also cache in startup cache for next time
      _startupCache.cacheUserData('engagement_ranking', _cachedEngagementRanking!);
      return _cachedEngagementRanking!;
    }

    // Use request deduplication to prevent multiple concurrent requests
    final _supabase = Supabase.instance.client;
    final currentUser = _supabase.auth.currentUser;
    final userId = currentUser?.id ?? 'anonymous';
    final requestKey = 'engagement_ranking_$userId';
    
    return _deduplicationService.deduplicateRequest(requestKey, () async {
      print('Fetching fresh engagement ranking data from materialized view');
      
      try {
        if (currentUser == null) {
          return {'rank': 0, 'totalUsers': 0, 'totalChameleons': 0, 'userEngagement': 0, 'camoQuality': 0.0, 'cqiRank': 0, 'questionsPosted': 0, 'recent_30d_rank': 0, 'hasCqi': false};
        }

        // Try to use materialized view first (much faster)
        try {
          final response = await _supabase
              .from('user_engagement_rankings')
              .select('*')
              .eq('user_id', currentUser.id)
              .single();

          if (response != null) {
            // Get total user count separately (same as app drawer platform stats)
            final totalUsersResponse = await _supabase
                .from('users')
                .select('id')
                .count(CountOption.exact);
            
            final result = {
              'rank': response['rank'] as int? ?? 0,
              'totalUsers': totalUsersResponse.count ?? 0, // Actual total user count
              'totalChameleons': response['total_chameleons'] as int? ?? 0, // Users who posted questions
              'userEngagement': response['engagement_score'] as int? ?? 0,
              'camoQuality': (response['camo_quality'] as num?)?.toDouble() ?? 0.0,
              'cqiRank': response['cqi_rank'] as int? ?? 0,
              'questionsPosted': response['questions_posted'] as int? ?? 0,
              'recent_30d_rank': response['recent_30d_rank'] as int? ?? 0,
              'hasCqi': response['camo_quality'] != null,
            };

            // Cache the result in both local cache and startup cache
            _cachedEngagementRanking = result;
            _lastEngagementRankingRefresh = now;
            _startupCache.cacheUserData('engagement_ranking', result);
            
            print('Got ranking from materialized view: rank=${result['rank']}, engagement=${result['userEngagement']}, totalUsers=${result['totalUsers']}, totalChameleons=${result['totalChameleons']}');
            return result;
          }
        } catch (e) {
          print('Materialized view not available, falling back to manual calculation: $e');
        }

        // Simple fallback - return zeros if materialized view is unavailable
        print('Materialized view unavailable, returning default values');
        return {'rank': 0, 'totalUsers': 0, 'totalChameleons': 0, 'userEngagement': 0, 'camoQuality': 0.0, 'cqiRank': 0, 'questionsPosted': 0, 'recent_30d_rank': 0, 'hasCqi': false};

      } catch (e) {
        print('Error calculating user engagement ranking: $e');
        return {'rank': 0, 'totalUsers': 0, 'totalChameleons': 0, 'userEngagement': 0, 'camoQuality': 0.0, 'cqiRank': 0, 'questionsPosted': 0, 'recent_30d_rank': 0, 'hasCqi': false};
      }
    });
  }

  // Force refresh engagement ranking (for manual refresh)
  Future<Map<String, dynamic>> refreshEngagementRanking() async {
    return getUserEngagementRanking(forceRefresh: true);
  }

  // Get user engagement ranking with camo quality - returns Map<String, dynamic> to handle double values
  Future<Map<String, dynamic>> getUserEngagementRankingWithCamoQuality({bool forceRefresh = false}) async {
    // Just call the existing method which now includes camo quality
    final result = await getUserEngagementRanking(forceRefresh: forceRefresh);
    // Convert to Map<String, dynamic> to handle mixed types
    return Map<String, dynamic>.from(result);
  }

  // Method to check if we should show the notification permission dialog
  // Only shows after the 2nd QOTD click attempt (not the first)
  bool shouldShowNotificationPermissionDialog() {
    // If already shown, don't show again
    if (_notificationPermissionShown) {
      return false;
    }

    // Increment click count
    _qotdClickCount++;
    _prefs.setInt(_qotdClickCountKey, _qotdClickCount);

    // Show on 2nd click or later (not the first)
    return _qotdClickCount >= 2;
  }

  // Method to call when notification permissions are granted
  Future<void> onNotificationPermissionsGranted() async {
    // Enable both notification types when permissions are granted
    setNotifyQOTD(true);
    setNotifyResponses(true);
    
    // Also subscribe to the FCM topics
    try {
      final notificationService = NotificationService();
      await notificationService.subscribeToQOTD();
      await notificationService.subscribeToQuestionActivity();
      print('UserService: Both notification types enabled and subscribed after permission grant');
    } catch (e) {
      print('UserService: Error subscribing to topics after permission grant: $e');
    }
  }

  // Method to call when notification permissions are denied
  Future<void> onNotificationPermissionsDenied() async {
    // Disable both notification types when permissions are denied
    setNotifyQOTD(false);
    setNotifyResponses(false);
    
    // Also unsubscribe from the FCM topics
    try {
      final notificationService = NotificationService();
      await notificationService.unsubscribeFromQOTD();
      await notificationService.unsubscribeFromQuestionActivity();
      print('UserService: Both notification types disabled and unsubscribed after permission denial');
    } catch (e) {
      print('UserService: Error unsubscribing from topics after permission denial: $e');
    }
  }

  // Get current user's engagement score using the same filtering as the counter display
  Future<int> getCurrentEngagementScore(dynamic questionService) async {
    final filteredQuestions = await getFilteredPostedQuestions(questionService);
    
    int totalEngagement = 0;
    for (final question in filteredQuestions) {
      final votes = question['votes'] as int? ?? 0;
      totalEngagement += votes;
    }
    
    return totalEngagement;
  }

  // Location history management methods
  void _loadLocationHistory() {
    final historyJson = _prefs.getString(_locationHistoryKey);
    if (historyJson != null) {
      try {
        final List<dynamic> historyList = json.decode(historyJson);
        _locationHistory = historyList.cast<Map<String, dynamic>>();
      } catch (e) {
        print('Error loading location history: $e');
        _locationHistory = [];
      }
    }
    
    final pendingJson = _prefs.getString(_pendingLocationSwitchKey);
    if (pendingJson != null) {
      try {
        _pendingLocationSwitch = json.decode(pendingJson);
      } catch (e) {
        print('Error loading pending location switch: $e');
        _pendingLocationSwitch = null;
      }
    }
  }

  void _saveLocationHistory() {
    try {
      _prefs.setString(_locationHistoryKey, json.encode(_locationHistory));
    } catch (e) {
      print('Error saving location history: $e');
    }
  }

  // Add a location to history (called when user changes location)
  void addLocationToHistory(Map<String, dynamic> location) {
    // Only track cities, not countries alone
    if (location['city'] == null) {
      print('LocationHistory: Skipping location without city');
      return;
    }
    
    if (location['country'] == null) {
      print('LocationHistory: Skipping location without country');
      return;
    }
    
    print('LocationHistory: Adding city to history: ${location['city']}, ${location['country']}');
    
    // Remove if already exists
    _locationHistory.removeWhere((l) => 
      l['country'] == location['country'] && 
      l['city'] == location['city']
    );
    
    // Add to front with timestamp
    final locationWithTimestamp = Map<String, dynamic>.from(location);
    locationWithTimestamp['timestamp'] = DateTime.now().toIso8601String();
    _locationHistory.insert(0, locationWithTimestamp);
    
    // Keep only last 3 locations
    if (_locationHistory.length > 3) {
      _locationHistory = _locationHistory.take(3).toList();
    }
    
    print('LocationHistory: History now has ${_locationHistory.length} cities');
    
    _saveLocationHistory();
    notifyListeners();
  }

  // Get next location in cycling order
  Map<String, dynamic>? getNextLocationInCycle(Map<String, dynamic>? currentLocation) {
    if (_locationHistory.length < 2) return null;
    
    // Find current location in history
    int currentIndex = -1;
    if (currentLocation != null) {
      currentIndex = _locationHistory.indexWhere((l) => 
        l['country'] == currentLocation['country'] && 
        l['city'] == currentLocation['city']
      );
    }
    
    // Get next location (cycle to beginning if at end)
    int nextIndex = (currentIndex + 1) % _locationHistory.length;
    return _locationHistory[nextIndex];
  }

  // Get previous location in cycling order  
  Map<String, dynamic>? getPreviousLocationInCycle(Map<String, dynamic>? currentLocation) {
    if (_locationHistory.length < 2) return null;
    
    // Find current location in history
    int currentIndex = -1;
    if (currentLocation != null) {
      currentIndex = _locationHistory.indexWhere((l) => 
        l['country'] == currentLocation['country'] && 
        l['city'] == currentLocation['city']
      );
    }
    
    // Get previous location (cycle to end if at beginning)
    int prevIndex = currentIndex <= 0 
        ? _locationHistory.length - 1 
        : currentIndex - 1;
    return _locationHistory[prevIndex];
  }

  // Set pending location switch (for confirmation)
  void setPendingLocationSwitch(Map<String, dynamic>? location) {
    _pendingLocationSwitch = location;
    if (location != null) {
      _prefs.setString(_pendingLocationSwitchKey, json.encode(location));
    } else {
      _prefs.remove(_pendingLocationSwitchKey);
    }
    notifyListeners();
  }

  // Apply pending location switch
  void applyPendingLocationSwitch(LocationService locationService) {
    if (_pendingLocationSwitch == null) return;
    
    final location = _pendingLocationSwitch!;
    
    // Apply to LocationService
    if (location['city'] != null) {
      locationService.setSelectedCity(location['city']);
    }
    if (location['country'] != null) {
      locationService.setSelectedCountry(location['country']);
    }
    
    // Clear pending switch
    setPendingLocationSwitch(null);
    
    print('Applied location switch: ${location['city'] ?? location['country']}');
  }

  // Clear pending location switch
  void clearPendingLocationSwitch() {
    setPendingLocationSwitch(null);
  }

  // Apply location switch directly without pending confirmation
  Future<void> applyLocationSwitch(Map<String, dynamic> location, LocationService locationService) async {
    print('LocationSwitch: Applying switch to ${location['city']}, ${location['country']}');
    print('LocationSwitch: Has cityObject: ${location['cityObject'] != null}');
    
    // Apply to LocationService
    if (location['cityObject'] != null) {
      // Use the full city object if available
      locationService.setSelectedCity(location['cityObject']);
      print('LocationSwitch: Successfully set city using cityObject');
    } else if (location['city'] != null && location['country'] != null) {
      // Try to find the city object from LocationService
      print('LocationSwitch: No cityObject found, attempting to lookup city: ${location['city']} in ${location['country']}');
      
      final cityObject = await _findCityObject(location['city'], location['country'], locationService);
      if (cityObject != null) {
        locationService.setSelectedCity(cityObject);
        print('LocationSwitch: Successfully found and set city object');
        
        // Update the history entry with the found city object for future use
        _updateHistoryEntryWithCityObject(location, cityObject);
      } else {
        // Fallback: set country only
        locationService.setSelectedCountry(location['country']);
        print('Warning: Could not find city object for ${location['city']}, only set country');
      }
    }
    
    print('Applied direct location switch: ${location['city'] ?? location['country']}');
  }

  // Helper method to find city object by name and country
  Future<Map<String, dynamic>?> _findCityObject(String cityName, String countryName, LocationService locationService) async {
    try {
      print('LocationSwitch: Looking up country code for $countryName');
      
      // Get country code for the country name
      final countryCode = await locationService.getCountryCodeForName(countryName);
      if (countryCode == null) {
        print('LocationSwitch: Could not find country code for $countryName');
        return null;
      }
      
      print('LocationSwitch: Found country code $countryCode for $countryName');
      
      // Load cities for the country
      final cities = await locationService.loadCitiesForCountry(countryCode);
      
      // Search for the city in the loaded cities
      for (final city in cities) {
        if (city['name'] == cityName && city['country_name_en'] == countryName) {
          print('LocationSwitch: Found city object for $cityName');
          return city;
        }
      }
      
      print('LocationSwitch: Could not find city object for $cityName in $countryName');
      return null;
    } catch (e) {
      print('LocationSwitch: Error finding city object: $e');
      return null;
    }
  }

  // Helper method to update history entry with found city object
  void _updateHistoryEntryWithCityObject(Map<String, dynamic> location, Map<String, dynamic> cityObject) {
    final index = _locationHistory.indexWhere((l) => 
      l['country'] == location['country'] && 
      l['city'] == location['city']
    );
    
    if (index != -1) {
      _locationHistory[index]['cityObject'] = cityObject;
      _saveLocationHistory();
      print('LocationSwitch: Updated history entry with city object');
    }
  }

  // Initialize location history with current location
  void initializeLocationHistory(LocationService locationService) {
    print('LocationHistory: Initializing location history. Current history size: ${_locationHistory.length}');
    
    if (_locationHistory.isNotEmpty) {
      print('LocationHistory: Already initialized with ${_locationHistory.length} locations');
      return; // Already initialized
    }
    
    // Add current location to history if available
    final currentLocation = _getCurrentLocationFromService(locationService);
    print('LocationHistory: Current location from service: $currentLocation');
    
    if (currentLocation != null) {
      addLocationToHistory(currentLocation);
    } else {
      print('LocationHistory: No current location available');
    }
  }

  // Helper to get current location from LocationService
  Map<String, dynamic>? _getCurrentLocationFromService(LocationService locationService) {
    final country = locationService.userLocation?['country_name_en'];
    final cityObject = locationService.selectedCity;
    final cityName = cityObject?['name'];
    
    // Only return if we have both city and country
    if (country == null || cityName == null || cityObject == null) return null;
    
    return {
      'country': country,
      'city': cityName,
      'cityObject': cityObject,  // Include full city object
    };
  }

  // Get location display name
  String getLocationDisplayName(Map<String, dynamic> location) {
    final city = location['city'];
    final country = location['country'];
    
    String cityName = 'Unknown City';
    if (city != null) {
      if (city is Map) {
        cityName = city['name'] ?? 'Unknown City';
      } else if (city is String) {
        cityName = city;
      }
    }
    
    if (country != null) {
      return '$cityName, $country';
    }
    
    return cityName;
  }

  // Calculate current answer streak
  int _calculateCurrentAnswerStreak(List<Map<String, dynamic>> questions) {
    if (questions.isEmpty) return 0;
    
    // Get current date (today) and normalize to start of day
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    
    // Group questions by date
    final Map<DateTime, List<Map<String, dynamic>>> questionsByDate = {};
    
    for (final question in questions) {
      try {
        final timestamp = question['timestamp'];
        if (timestamp != null) {
          final date = DateTime.parse(timestamp);
          final dateKey = DateTime(date.year, date.month, date.day);
          questionsByDate.putIfAbsent(dateKey, () => []);
          questionsByDate[dateKey]!.add(question);
        }
      } catch (e) {
        print('Error parsing timestamp: $e');
        continue;
      }
    }
    
    // Calculate streak starting from today
    int streak = 0;
    DateTime checkDate = today;
    
    // Check if user had activity today, if not, start from yesterday
    if (!questionsByDate.containsKey(today)) {
      checkDate = today.subtract(Duration(days: 1));
    }
    
    // Count consecutive days with at least one activity
    while (questionsByDate.containsKey(checkDate)) {
      streak++;
      checkDate = checkDate.subtract(Duration(days: 1));
    }
    
    return streak;
  }

  // Check if user has answered any question today (extended their streak)
  bool _hasExtendedStreakToday(List<Map<String, dynamic>> questions) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    
    for (final question in questions) {
      try {
        final timestamp = question['timestamp'];
        if (timestamp != null) {
          final date = DateTime.parse(timestamp);
          final questionDate = DateTime(date.year, date.month, date.day);
          if (questionDate.isAtSameMomentAs(today)) {
            return true;
          }
        }
      } catch (e) {
        print('Error parsing timestamp: $e');
        continue;
      }
    }
    
    return false;
  }

  /// Sync the user's current streak to the server and get their rank
  /// Called on feed refresh to update leaderboard position
  /// Returns the user's rank (1 = highest streak) or 0 if not ranked
  Future<void> syncStreakToServer() async {
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) {
      print('🔥 Streak sync: User not authenticated, skipping');
      return;
    }

    final currentStreak = _calculateCurrentAnswerStreak(_answeredQuestions);
    print('🔥 Streak sync: Syncing streak=$currentStreak to server');

    try {
      final result = await Supabase.instance.client.rpc(
        'sync_streak_and_get_rank',
        params: {'p_current_streak': currentStreak},
      );

      if (result != null && result is List && result.isNotEmpty) {
        final data = result[0];
        _streakRank = data['rank'] ?? 0;
        _isTopTenStreak = data['is_top_10'] ?? false;
        print('🔥 Streak sync: Rank=$_streakRank, isTopTen=$_isTopTenStreak');
        notifyListeners();
      }
    } catch (e) {
      print('🔥 Streak sync error: $e');
      // Don't rethrow - streak sync is non-critical
    }
  }
} 