// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'results_service.dart';
import '../services/notification_service.dart';
import '../services/question_service.dart';
import '../services/location_service.dart';
import '../services/passkeys_service.dart';
import '../services/device_id_provider.dart';
import '../services/request_deduplication_service.dart';
import '../services/startup_cache_service.dart';
import '../services/analytics_service.dart';
import '../services/congratulations_service.dart';
import '../services/achievement_service.dart';
import '../services/home_widget_service.dart';
import '../services/app_review_service.dart';
import '../services/post_answer_prompts.dart';
import '../widgets/notification_bell.dart';
import '../utils/streak_logic.dart' as streak_logic;
import 'question_service.dart' show StreakUpdateEvent;
import 'network_service.dart' show isMissingRpc;

class UserService extends ChangeNotifier {
  static const String _answeredKey = 'answered_questions';
  static const String _postedKey = 'posted_questions';
  static const String _savedKey = 'saved_questions';
  static const String _hideAnsweredKey = 'hideAnsweredQuestions';
  static const String _reportedKey = 'reported_questions';
  static const String _reportedReasonsKey = 'reported_question_reasons';
  static const String _dismissedKey = 'dismissed_questions';
  // Day-stamped credits earned by asking (posting) a question. Same store
  // family as answered questions; feeds streak derivation (QOTD-first).
  static const String _askedStreakCreditsKey = 'asked_streak_credits';
  static const String _userIdKey = 'user_id';
  static const String _notifyResponsesKey = 'notify_responses';
  static const String _notifyQOTDKey = 'notify_qotd';

  /// Master toggle for friend-graph pushes (WP-F). Defaults to true, matching
  /// `notification_settings.friend_events_enabled`'s own default — a friend
  /// request that never arrives is worse than one that does.
  static const String _notifyFriendEventsKey = 'notify_friend_events';
  static const String _showNSFWKey = 'showNSFWContent';
  static const String _boostLocalActivityKey = 'boost_local_activity';
  static const String _notificationPermissionShownKey = 'notification_permission_shown';
  // WP-A: timestamp of the most recent notification ask, so a declined
  // pre-prompt can be re-asked after a week. The legacy bool above is kept
  // (and still written) for backward compatibility with pre-v1.3.1 installs.
  static const String _notificationPermissionLastAskedAtKey = 'notification_permission_last_asked_at';
  static const String _notificationPermissionGrantedInAppKey = 'notification_permission_granted_in_app';
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

  List<Map<String, dynamic>> _answeredQuestions = [];
  // Day-stamped streak credits earned by asking a question. Shape per entry:
  // {'timestamp': iso8601}. Combined with counting answers to derive streaks.
  List<Map<String, dynamic>> _askedStreakCredits = [];
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
  bool _notifyFriendEvents = true;
  bool _showNSFWContent = false;
  bool _hasEverEnabledNSFW = false; // Track if user has ever enabled NSFW in settings
  bool _hideAnsweredQuestions = false;
  bool _boostLocalActivity = true;
  bool _notificationPermissionShown = false;
  DateTime? _notificationPermissionLastAskedAt;
  bool _notificationPermissionGrantedInApp = false;
  String? _userId;

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

  /// Day-stamped credits earned by asking (posting) a question. Exposed so
  /// streak derivation can combine both credit sources (QOTD-first §Streak).
  List<Map<String, dynamic>> get askedStreakCredits => _askedStreakCredits;
  List<Map<String, dynamic>> get postedQuestions => _postedQuestions;
  List<Map<String, dynamic>> get savedQuestions => _savedQuestions;
  String? get userLocation => _userLocation;
  bool get notifyResponses => _notifyResponses;
  bool get notifyQOTD => _notifyQOTD;
  bool get notifyFriendEvents => _notifyFriendEvents;
  bool get showNSFWContent => _showNSFWContent;
  bool get hideAnsweredQuestions => _hideAnsweredQuestions;
  bool get boostLocalActivity => _boostLocalActivity;
  bool get notificationPermissionShown => _notificationPermissionShown;

  /// When the notification pre-prompt was last shown (null = never recorded).
  DateTime? get notificationPermissionLastAskedAt => _notificationPermissionLastAskedAt;

  /// Whether the user accepted the in-app pre-prompt at least once — the signal
  /// that stops the weekly re-ask.
  bool get notificationPermissionGrantedInApp => _notificationPermissionGrantedInApp;
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
    _loadQuestions(_askedStreakCreditsKey, _askedStreakCredits);
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
    _notifyFriendEvents = _prefs.getBool(_notifyFriendEventsKey) ?? true;

    _showNSFWContent = _prefs.getBool(_showNSFWKey) ?? false;
    _hasEverEnabledNSFW = _prefs.getBool(_hasEverEnabledNSFWKey) ?? _showNSFWContent;
    _boostLocalActivity = _prefs.getBool(_boostLocalActivityKey) ?? true;
    _notificationPermissionShown = _prefs.getBool(_notificationPermissionShownKey) ?? false;
    _notificationPermissionGrantedInApp =
        _prefs.getBool(_notificationPermissionGrantedInAppKey) ?? false;
    final lastAskedRaw = _prefs.getString(_notificationPermissionLastAskedAtKey);
    _notificationPermissionLastAskedAt =
        lastAskedRaw == null ? null : DateTime.tryParse(lastAskedRaw);
    // Backfill for installs that predate the timestamp: they were asked at some
    // unknown point, so stamp the upgrade moment and start their week now
    // (never retro-trigger an immediate re-ask on update day).
    if (_notificationPermissionShown && _notificationPermissionLastAskedAt == null) {
      _notificationPermissionLastAskedAt = DateTime.now();
      _prefs.setString(_notificationPermissionLastAskedAtKey,
          _notificationPermissionLastAskedAt!.toIso8601String());
    }

    // Load location history
    _loadLocationHistory();

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

    // Pre-load engagement ranking since UserScreen loads on startup (needed for city info)
    print('USER SERVICE: Pre-loading engagement ranking...');
    try {
      await getUserEngagementRanking();
      print('USER SERVICE: Engagement ranking pre-loaded successfully');
    } catch (e) {
      print('USER SERVICE: Warning - could not pre-load engagement ranking: $e');
      // Don't fail initialization if this fails
    }
    
    print('USER SERVICE: initialization completed');
    
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
      'notifications_enabled': _notifyResponses || _notifyQOTD,
      'qotd_subscribed': _notifyQOTD,
      'nsfw_enabled': _showNSFWContent,
      'boost_local_activity': _boostLocalActivity,
      'total_questions_answered': _answeredQuestions.length,
      'total_questions_posted': _postedQuestions.length,
      'hide_answered_questions': _hideAnsweredQuestions,
    };
    
    await analytics.setUserProperties(properties);
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

  Future<void> addAnsweredQuestion(Map<String, dynamic> question, {BuildContext? context, String? answer}) async {
    if (!_answeredQuestions.any((q) => q['id'] == question['id'])) {
      // Calculate previous streak before adding the question
      final previousStreak = _calculateCurrentAnswerStreak(_answeredQuestions);
      final wasStreakExtendedToday = _hasExtendedStreakToday(_answeredQuestions);

      // Build the record to persist. Stamp a timestamp if the caller passed a
      // raw server map (which carries `created_at`, not `timestamp`) so the
      // streak math — which keys off `timestamp` — always sees this answer.
      // This is caller-proof: it fixes the historical QOTD-overlay bug where
      // overlay answers never counted (the overlay passed a timestamp-less map).
      final record = Map<String, dynamic>.from(question);
      record['timestamp'] ??= DateTime.now().toIso8601String();

      // Only answering the effective QOTD (real QOTD or its NSFW fallback)
      // credits the streak. Archive / feed / deep-link answers store false.
      final questionId = record['id']?.toString() ?? '';
      final countsForStreak = QuestionService().isEffectiveQotd(questionId);
      record['counts_for_streak'] = countsForStreak;

      // The notification pre-prompt is owed after a QOTD answer, from EVERY
      // path: the home hero, the full answer screens (Archive / deep link /
      // search), a discussion comment, and the onboarding replay. This is the
      // one choke point they all reach, but it has no BuildContext — so it only
      // records the debt; `PostAnswerPrompts.maybeShow` drains it from whichever
      // surface is visible afterwards. See `post_answer_prompts.dart`.
      if (countsForStreak) {
        try {
          await PostAnswerPrompts.markQotdAnswered();
        } catch (e) {
          print('Error recording post-answer notification prompt: $e');
        }
      }

      // Optionally persist the user's answer text/value if the caller provided
      // one (plumbing for the QOTD-first "your answer" surfaces).
      if (answer != null) {
        record['answer'] = answer;
      }

      _answeredQuestions.add(record);
      await _saveQuestions(_answeredKey, _answeredQuestions);

      // Calculate new streak after adding the question
      final newStreak = _calculateCurrentAnswerStreak(_answeredQuestions);
      final isStreakExtendedToday = _hasExtendedStreakToday(_answeredQuestions);

      // Only trigger animation when streak is actually extended for the day AND previous streak was 1+
      if (!wasStreakExtendedToday && isStreakExtendedToday && previousStreak >= 1) {
        print('Streak extended! Previous: $previousStreak, New: $newStreak');
        // Held, not fired: PostAnswerPrompts.maybeShow (which every QOTD answer
        // reaches — see markQotdAnswered above) plays it unless the
        // notification dialog or the first-answerer celebration takes the slot.
        if (countsForStreak) {
          PostAnswerPrompts.holdStreakCelebration(previousStreak, newStreak);
        } else {
          StreakUpdateEvent.notifyStreakExtended(previousStreak, newStreak);
        }
      } else if (previousStreak == 0) {
        print('First streak answer (0->1), no animation triggered');
      } else if (wasStreakExtendedToday) {
        print('Streak already extended today, no animation triggered');
      }

      // Update home screen widget with new streak data (strict value — reflects
      // whether the day genuinely has credit, not a hardcoded true).
      try {
        await HomeWidgetService().updateWidget(
          streakCount: newStreak,
          hasExtendedToday: isStreakExtendedToday,
        );
      } catch (e) {
        print('Error updating home widget after answering question: $e');
        // Don't let this error interrupt the normal flow
      }

      // Sync the (possibly-changed) streak to the server, non-blocking, only
      // when this accrual actually counted.
      if (countsForStreak) {
        syncStreakToServer();
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
      
      // Native app-store review prompt. This method is the one choke point
      // every answer surface passes through, so it is the only hook needed.
      // Fire-and-forget and self-rationing (2nd answer, then weekly, 3/year):
      // see AppReviewService / utils/app_review_logic.dart.
      AppReviewService().scheduleMaybeRequestReview(answeredCount: _answeredQuestions.length);

      notifyListeners();
    }
  }

  /// Record that the user asked (posted) a question today, granting a
  /// day-stamped streak credit. A day with an asked-credit extends the streak
  /// exactly like answering the effective QOTD does (QOTD-first §Streak rule).
  Future<void> addStreakCreditForAsking() async {
    // Streak state BEFORE the credit lands.
    final previousStreak = _calculateCurrentAnswerStreak(_answeredQuestions);
    final wasStreakExtendedToday = _hasExtendedStreakToday(_answeredQuestions);

    _askedStreakCredits.add({'timestamp': DateTime.now().toIso8601String()});
    await _saveQuestions(_askedStreakCreditsKey, _askedStreakCredits);

    // Streak state AFTER the credit lands.
    final newStreak = _calculateCurrentAnswerStreak(_answeredQuestions);
    final isStreakExtendedToday = _hasExtendedStreakToday(_answeredQuestions);

    // Same celebration conditions as answering.
    if (!wasStreakExtendedToday && isStreakExtendedToday && previousStreak >= 1) {
      print('Streak extended by asking! Previous: $previousStreak, New: $newStreak');
      StreakUpdateEvent.notifyStreakExtended(previousStreak, newStreak);
    }

    // Update home screen widget with new streak data.
    try {
      await HomeWidgetService().updateWidget(
        streakCount: newStreak,
        hasExtendedToday: isStreakExtendedToday,
      );
    } catch (e) {
      print('Error updating home widget after asking a question: $e');
    }

    // Sync streak to server, non-blocking.
    syncStreakToServer();

    notifyListeners();
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
    _askedStreakCredits.clear();
    _postedQuestions.clear();
    _savedQuestions.clear();
    await _prefs.remove(_answeredKey);
    await _prefs.remove(_askedStreakCreditsKey);
    await _prefs.remove(_postedKey);
    await _prefs.remove(_savedKey);
    notifyListeners();
  }

  void setUserLocation(String location) {
    _userLocation = location;
    notifyListeners();
  }

  Future<void> setNotifyResponses(bool value) async {
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

  /// Friend requests, acceptances, licks, forwards and reactions (WP-F).
  ///
  /// Unlike the other toggles this one has no FCM topic of its own — friend
  /// pushes ride the personal `user_{id}` topic — so the server-side
  /// `notification_settings.friend_events_enabled` flag is what actually
  /// suppresses them. Per-friend muting stays where it is, on the friendship
  /// row (WP-E).
  Future<void> setNotifyFriendEvents(bool value) async {
    _notifyFriendEvents = value;
    _prefs.setBool(_notifyFriendEventsKey, value);

    final notificationService = NotificationService();
    await notificationService.setFriendEventsEnabled(value);

    notifyListeners();
  }

  Future<void> setNotifyQOTD(bool value) async {
    _notifyQOTD = value;
    _prefs.setBool(_notifyQOTDKey, value);

    // Handle FCM subscription. Nothing is scheduled locally any more: the Drop
    // arrives at the server's random minute and is shown on arrival, so the
    // `qotd` topic subscription is the whole switch.
    final notificationService = NotificationService();
    if (value) {
      await notificationService.subscribeToQOTD();
      print('QOTD notifications enabled - FCM topic subscribed');
    } else {
      await notificationService.unsubscribeFromQOTD();
      print('QOTD notifications disabled - FCM topic unsubscribed');
    }
    // Keep the server row in step. QOTD push is topic-based, so `qotd_enabled`
    // does not gate delivery today — but it is the column every other surface
    // (and any future per-user send) reads, and it was never written by the
    // client at all.
    await notificationService.setQotdEnabled(value);

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

  /// Whether [questionId] is in the locally persisted answered list, read
  /// straight from SharedPreferences so context-less callers (the home-screen
  /// widget refresh on resume and on a QOTD push) can ask without a
  /// UserService instance. The server cannot answer this: `responses` is
  /// anonymous and has no user column (DBarchitecture.md).
  static Future<bool> hasAnsweredLocally(String questionId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_answeredKey);
      if (raw == null) return false;
      final decoded = json.decode(raw);
      if (decoded is! List) return false;
      return decoded.any((q) => q is Map && q['id']?.toString() == questionId);
    } catch (_) {
      return false;
    }
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
        // PRIVACY (review 2026-09-19 P0-2): no email, no display name, no
        // handle. The F-Droid consent slide promises "No names, emails, or
        // device fingerprints" (analytics_consent_slide.dart), and PostHog is
        // not where an address belongs. Only the two aggregate facts a cohort
        // split needs travel.
        {
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
      
            // Get fresh vote counts from the batched results RPC
      final Map<String, int> voteCounts =
          await ResultsService().fetchVoteCounts(questionIds);
      
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

  /// Record that the notification pre-prompt (or the Settings nudge that
  /// replaces it when the OS permission is denied) was just shown. Writes both
  /// the legacy bool and the WP-A timestamp the re-ask gate reads.
  Future<void> recordNotificationPermissionAsked({DateTime? at}) async {
    final stamp = at ?? DateTime.now();
    _notificationPermissionShown = true;
    _notificationPermissionLastAskedAt = stamp;
    await _prefs.setBool(_notificationPermissionShownKey, true);
    await _prefs.setString(
        _notificationPermissionLastAskedAtKey, stamp.toIso8601String());
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
            // Get total user count separately (same as app drawer platform
            // stats). A client count of `users` rows sees only the caller's
            // own row, so it asks get_platform_user_count() instead, and only
            // falls back to the count query where that RPC is undeployed.
            int totalUsers = 0;
            try {
              final raw = await _supabase.rpc('get_platform_user_count');
              totalUsers = raw is num ? raw.toInt() : 0;
            } catch (e) {
              if (!isMissingRpc(e)) rethrow;
              AnalyticsService()
                  .trackRpcNotDeployedOnce('get_platform_user_count');
              final totalUsersResponse = await _supabase
                  .from('users')
                  .select('id')
                  .count(CountOption.exact);
              totalUsers = totalUsersResponse.count;
            }

            final result = {
              'rank': response['rank'] as int? ?? 0,
              'totalUsers': totalUsers, // Actual total user count
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

  // Whether the one-time notification permission ask is still pending.
  //
  // NOTE: this is only the *first-ask* half of the decision. The full rule —
  // first ask vs weekly re-ask vs stay quiet, and in-app dialog vs Settings
  // deep link — lives in `utils/post_answer_prompt_logic.dart` and is performed
  // by `PostAnswerPrompts`. Prefer those; this getter is kept because the
  // Settings screen and older call sites read it.
  bool shouldShowNotificationPermissionDialog() {
    return !_notificationPermissionShown;
  }

  // Method to call when notification permissions are granted
  Future<void> onNotificationPermissionsGranted() async {
    // Accepting the pre-prompt retires the weekly re-ask (WP-A).
    _notificationPermissionGrantedInApp = true;
    await _prefs.setBool(_notificationPermissionGrantedInAppKey, true);

    // Enable both notification types when permissions are granted. These are
    // now awaited: each setter already does its own FCM topic subscription and
    // server `notification_settings` write, so the separate subscribe calls
    // that used to follow were duplicates racing the setters.
    await setNotifyQOTD(true);
    await setNotifyResponses(true);
    print('UserService: Both notification types enabled and subscribed after permission grant');
  }

  // Method to call when notification permissions are denied
  Future<void> onNotificationPermissionsDenied() async {
    // Declining keeps the user eligible for one re-ask a week later (WP-A).
    _notificationPermissionGrantedInApp = false;
    await _prefs.setBool(_notificationPermissionGrantedInAppKey, false);

    // Disable both notification types when permissions are denied. As above,
    // the setters own the topic unsubscribe and the server write.
    await setNotifyQOTD(false);
    await setNotifyResponses(false);
    print('UserService: Both notification types disabled and unsubscribed after permission denial');
  }

  /// Re-applies the stored notification preferences to the FCM topics and the
  /// server `notification_settings` row.
  ///
  /// Needed because the OS permission can change outside the app: a user who
  /// declined, then turned notifications on in the system Settings app, comes
  /// back with prefs that say "on" but no topic subscriptions (the grant
  /// happened while the app was backgrounded, and nothing re-ran). The Settings
  /// screen calls this on resume; it is idempotent, so calling it when nothing
  /// changed is harmless.
  Future<void> resyncNotificationState() async {
    try {
      final notificationService = NotificationService();
      if (_notifyQOTD) {
        await notificationService.subscribeToQOTD();
      } else {
        await notificationService.unsubscribeFromQOTD();
      }
      await notificationService.setQotdEnabled(_notifyQOTD);

      if (_notifyResponses) {
        await notificationService.subscribeToQuestionActivity();
      } else {
        await notificationService.unsubscribeFromQuestionActivity();
      }
      await notificationService.setFriendEventsEnabled(_notifyFriendEvents);
      // Nothing local left to re-assert: the QOTD reminder was retired with the
      // Drop and the streak reminder with it, so every category above is a
      // server/topic write.
      print('UserService: notification state re-synced');
    } catch (e) {
      print('UserService: error re-syncing notification state: $e');
    }
  }

  /// Debug-only: forgets that the notification prompt was ever shown, so the
  /// post-answer first ask can be retested on a device that has already seen it.
  ///
  /// Clears the legacy bool, the WP-A timestamp, the in-app-granted flag and any
  /// owed post-answer prompt. Does NOT touch the OS permission — that can only
  /// be reset by deleting the app (or, on the simulator, erasing it).
  Future<void> resetNotificationPromptState() async {
    _notificationPermissionShown = false;
    _notificationPermissionLastAskedAt = null;
    _notificationPermissionGrantedInApp = false;
    await _prefs.remove(_notificationPermissionShownKey);
    await _prefs.remove(_notificationPermissionLastAskedAtKey);
    await _prefs.remove(_notificationPermissionGrantedInAppKey);
    await PostAnswerPrompts.clearOwed();
    notifyListeners();
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

  // Calculate current answer streak.
  //
  // Delegates to the pure [streak_logic.calculateAnswerStreak], combining
  // counting answers (effective-QOTD answers, plus grandfathered legacy
  // records) with asked-question credits. A day counts if any counting answer
  // OR any asked-credit lands on it (QOTD-first §Streak rule).
  int _calculateCurrentAnswerStreak(List<Map<String, dynamic>> questions) {
    return streak_logic.calculateAnswerStreak(
      questions,
      askedCredits: _askedStreakCredits,
    );
  }

  // Whether the streak has already been extended today, from either credit
  // source (counting answer or asked-question credit).
  bool _hasExtendedStreakToday(List<Map<String, dynamic>> questions) {
    return streak_logic.hasExtendedStreakToday(
      questions,
      askedCredits: _askedStreakCredits,
    );
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