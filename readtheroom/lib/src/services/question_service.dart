// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:io';
import 'package:timezone/timezone.dart' as tz;
import 'package:timezone/data/latest.dart' as tz;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter/material.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import '../screens/answer_approval_screen.dart';
import '../utils/supabase_config.dart';
import '../screens/answer_multiple_choice_screen.dart';
import 'watchlist_service.dart';
import '../screens/answer_text_screen.dart';
import '../screens/approval_results_screen.dart';
import '../screens/multiple_choice_results_screen.dart';
import '../screens/text_results_screen.dart';
import '../widgets/authentication_dialog.dart';
import '../services/location_service.dart';
import '../services/guest_user_tracking_service.dart';
import '../data/countries_data.dart';
import '../utils/approval_labels.dart';
import '../utils/archive_logic.dart';
import 'package:provider/provider.dart';
import 'dart:math' as Math;
import '../services/user_service.dart';
import '../services/notification_service.dart';
import '../services/analytics_service.dart';
import '../services/achievement_service.dart';
import '../services/congratulations_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../widgets/notification_permission_dialog.dart';
import '../models/category.dart';
import '../models/question_results.dart';
import 'network_service.dart';
import 'results_service.dart';
import '../screens/answer_approval_screen.dart';
import '../screens/answer_multiple_choice_screen.dart';
import '../screens/answer_text_screen.dart';
import '../screens/text_results_screen.dart';
import '../screens/multiple_choice_results_screen.dart';
import '../screens/approval_results_screen.dart';
import '../services/user_service.dart';
import '../services/location_service.dart';
import '../services/request_deduplication_service.dart';
import '../services/nomination_result.dart';

/// **QuestionService - Optimized Feed Architecture**
/// 
/// This service provides high-performance question feeds using:
/// 1. **Primary**: Edge Function with feed_questions_optimized_v3 materialized view (sub-50ms)
/// 2. **Fallback**: question_feed_scores materialized view with pre-computed scores
/// 3. **Last Resort**: Direct questions table with client-side sorting
/// 
/// **Performance Features:**
/// - CDN caching (1-minute) for global distribution
/// - Pagination support with offset-based infinite scroll
/// - Client-side caching (3-minute) with boost state differentiation
/// - Optimized vote count polling (2-minute intervals)
/// - Location boost with pre-computed admin2 matching
/// 
/// **Expected Performance:**
/// - Feed loading: 0.5-1 second (was 3-5 seconds)
/// - Database queries: 1 per load (was 50+)
/// - Vote count polling: Every 2 minutes (was every 5 seconds)
class QuestionService extends ChangeNotifier {
  // Singleton pattern to prevent multiple instances
  static QuestionService? _instance;
  factory QuestionService() => _instance ??= QuestionService._internal();
  
  final _supabase = Supabase.instance.client;
  /// Every read of answer data goes through here. `responses` is write-only
  /// for clients since the answers read lockdown (2026-09-22) — this service
  /// still INSERTs into it, and never selects from it.
  final _resultsService = ResultsService();
  /// The network surface. Used on the write path only to remember what the
  /// answer was filed with, so the results screen's un-share toggle opens in
  /// the state the user chose.
  final _networkService = NetworkService.shared();
  List<Map<String, dynamic>> _questions = [];
  bool _isLoading = false;
  Map<String, dynamic>? _questionOfTheDay;
  
  // Request deduplication service for preventing duplicate API calls
  final _deduplicationService = RequestDeduplicationService();
  
  // Prefetch throttling to prevent multiple concurrent background prefetch operations
  bool _isPrefetching = false;
  DateTime? _lastPrefetchTime;
  
  // Static flags to prevent duplicate initialization across instances
  static bool _serviceClientInitialized = false;
  static bool _seedingInProgress = false;
  static bool _qotdUpdateInProgress = false;
  static bool _voteCountUpdateInProgress = false;
  static DateTime? _lastVoteCountUpdate;
  DateTime? _lastQuestionOfTheDayUpdate;
  
  // Cache for user location data to avoid database calls during location boosting
  Map<String, dynamic>? _cachedUserLocationData;
  DateTime? _userLocationCacheTimestamp;
  static const Duration _userLocationCacheDuration = Duration(hours: 1); // Cache for 1 hour

  // Feed cache for optimized performance
  final Map<String, List<Map<String, dynamic>>> _feedCache = {};
  final Map<String, DateTime> _feedCacheTimestamps = {};
  static const Duration _feedCacheDuration = Duration(minutes: 3);

  // Background loading status
  final Map<String, bool> _backgroundLoadingFeeds = {};

  // Pagination state
  bool _hasMoreQuestions = true;
  String? _lastFetchedId;
  int _currentPage = 0;
  static const int _pageSize = 50;

  List<Map<String, dynamic>> get questions => _questions;
  bool get isLoading => _isLoading;
  
  // Cache for NSFW fallback question to avoid repeated API calls
  Map<String, dynamic>? _nsfwFallbackQuestion;
  // Day-stamp: a chosen fallback is pinned until the calendar day changes.
  DateTime? _nsfwFallbackCacheTime;
  
  Map<String, dynamic>? get questionOfTheDay {
    // If we don't have a QotD, return null
    if (_questionOfTheDay == null) return null;
    
    // Check if current QotD is hidden (backend moderation)
    // For real database questions, we need to check is_hidden status
    final isHidden = _questionOfTheDay!['is_hidden'] == true;
    
    if (isHidden) {
      print('Current QotD is hidden due to moderation, selecting new QotD...');
      // Async operation - trigger new QotD selection
      _selectNewQotDDueToModeration();
      return null; // Return null until new QotD is selected
    }
    
    return _questionOfTheDay;
  }
  
  // Enhanced method that handles NSFW filtering.
  //
  // [hasAnswered] (optional) lets the fallback skip questions the caller has
  // already answered, so a non-NSFW user still gets a fresh question to
  // answer on NSFW-QOTD days. The chosen fallback is pinned for the calendar
  // day — answering it must flip the home to the answered card, not surface
  // yet another question.
  Future<Map<String, dynamic>?> getQuestionOfTheDay({
    bool showNSFW = true,
    bool Function(String questionId)? hasAnswered,
  }) async {
    // Get the base question of the day
    final baseQotd = questionOfTheDay;
    if (baseQotd == null) return null;

    // Check if current QotD is NSFW and user doesn't want NSFW content
    final isNSFW = baseQotd['nsfw'] == true || baseQotd['is_nsfw'] == true;

    if (isNSFW && !showNSFW) {
      print('Current QotD is NSFW but user has NSFW disabled, fetching trending fallback...');

      // A fallback chosen earlier today stays the day's question.
      final now = DateTime.now();
      if (_nsfwFallbackQuestion != null &&
          _nsfwFallbackCacheTime != null &&
          _isSameCalendarDay(_nsfwFallbackCacheTime!, now)) {
        print('Using today\'s cached NSFW fallback question');
        return _nsfwFallbackQuestion;
      }

      try {
        // Get the highest trending non-NSFW question the user hasn't
        // answered yet as the fallback
        final fallbackQuestion =
            await _getTrendingNonNSFWFallback(hasAnswered: hasAnswered);
        if (fallbackQuestion != null) {
          // Cache the fallback for the rest of the day
          _nsfwFallbackQuestion = fallbackQuestion;
          _nsfwFallbackCacheTime = now;
          print('Using trending non-NSFW question as QotD fallback: ${fallbackQuestion['prompt']}');
          return fallbackQuestion;
        } else {
          print('No suitable trending non-NSFW fallback found, returning null');
          return null;
        }
      } catch (e) {
        print('Error fetching trending non-NSFW fallback: $e');
        return null;
      }
    }

    return baseQotd;
  }

  static bool _isSameCalendarDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  // Get the highest trending non-NSFW question as fallback. Preference order:
  // unanswered global → unanswered any-targeting → answered (grace: better an
  // already-answered card than no question at all).
  Future<Map<String, dynamic>?> _getTrendingNonNSFWFallback({
    bool Function(String questionId)? hasAnswered,
  }) async {
    try {
      print('Fetching top trending non-NSFW question as QotD fallback...');

      // Use the optimized feed to get trending questions
      final trendingQuestions = await fetchOptimizedFeed(
        feedType: 'trending',
        limit: 20, // Enough headroom to find an unanswered one
        filters: {
          'showNSFW': false, // Explicitly exclude NSFW
        },
        useCache: false, // Get fresh data for fallback
      );

      if (trendingQuestions.isEmpty) {
        print('No trending questions found for NSFW fallback');
        return null;
      }

      final nonNsfw = trendingQuestions.where((q) {
        return q['nsfw'] != true && q['is_nsfw'] != true;
      }).toList();

      bool isGlobal(Map<String, dynamic> q) {
        final targeting = q['targeting_type']?.toString().toLowerCase();
        return targeting == 'globe' || targeting == 'global' || targeting == null;
      }

      bool unanswered(Map<String, dynamic> q) {
        if (hasAnswered == null) return true;
        final id = q['id']?.toString();
        return id == null || !hasAnswered(id);
      }

      for (final question in nonNsfw) {
        if (isGlobal(question) && unanswered(question)) {
          print('Selected unanswered trending non-NSFW global question as fallback: ${question['prompt']}');
          return question;
        }
      }
      for (final question in nonNsfw) {
        if (unanswered(question)) {
          print('Selected unanswered trending non-NSFW question (any targeting) as fallback: ${question['prompt']}');
          return question;
        }
      }
      // Everything trending is already answered — degrade to the old rule.
      for (final question in nonNsfw) {
        if (isGlobal(question)) {
          print('All trending answered; using top non-NSFW global question as fallback: ${question['prompt']}');
          return question;
        }
      }
      if (nonNsfw.isNotEmpty) {
        print('All trending answered; using top non-NSFW question as fallback: ${nonNsfw.first['prompt']}');
        return nonNsfw.first;
      }

      print('No suitable non-NSFW questions found in trending feed for fallback');
      return null;
    } catch (e) {
      print('Error in _getTrendingNonNSFWFallback: $e');
      return null;
    }
  }
  
  // Clear NSFW fallback cache when needed
  void clearNSFWFallbackCache() {
    _nsfwFallbackQuestion = null;
    _nsfwFallbackCacheTime = null;
    print('NSFW fallback cache cleared');
  }
  
  bool get hasMoreQuestions => _hasMoreQuestions;

  QuestionService._internal() {
    tz.initializeTimeZones();
    
    // One-time setup for the first instance only.
    if (!_serviceClientInitialized) {
      _serviceClientInitialized = true;

      // Schedule periodic updates for Question of the Day
      _scheduleQuestionOfTheDayUpdates();
      // Seed initial questions (only for the first instance)
      seedInitialQuestions();
    }
  }

  void _scheduleQuestionOfTheDayUpdates() {
    // Update immediately
    _updateQuestionOfTheDay();
    
    // Schedule updates every minute to check if it's time to update
    Future.delayed(Duration(minutes: 1), () {
      _updateQuestionOfTheDay();
      _scheduleQuestionOfTheDayUpdates();
    });
  }

  // Check if it's time to update the Question of the Day (every 12 hours)
  bool _shouldUpdateQuestionOfTheDay() {
    if (_lastQuestionOfTheDayUpdate == null) return true;

    final now = DateTime.now();
    final lastUpdate = _lastQuestionOfTheDayUpdate!;

    // Update if the date has changed (crossed midnight)
    final lastDate = DateTime(lastUpdate.year, lastUpdate.month, lastUpdate.day);
    final today = DateTime(now.year, now.month, now.day);
    if (today.isAfter(lastDate)) {
      print('🌅 Date changed since last QOTD update, refreshing...');
      return true;
    }

    // Also update every 12 hours as a fallback
    return now.difference(lastUpdate).inHours >= 12;
  }

  // Update the Question of the Day (fetches from server-selected QOTD)
  // QOTD selection is now handled server-side via PostgreSQL pg_cron job
  // See: feature-documentation/qotd-backend-selection-2026-02-04.md
  Future<void> _updateQuestionOfTheDay() async {
    // Prevent multiple concurrent QotD updates
    if (_qotdUpdateInProgress) {
      print('🔄 QotD update already in progress, skipping duplicate request');
      return;
    }

    if (!_shouldUpdateQuestionOfTheDay()) return;

    // Use request deduplication to prevent multiple concurrent QotD updates
    const requestKey = 'update_question_of_the_day';
    return _deduplicationService.deduplicateRequest(requestKey, () async {
      _qotdUpdateInProgress = true;

      try {
        final now = DateTime.now();
        final today = DateTime(now.year, now.month, now.day);
        final dateKey = today.toIso8601String().split('T')[0]; // YYYY-MM-DD format

        Map<String, dynamic>? selectedQuestion;

        // Fetch QOTD from server (pre-selected by pg_cron job)
        try {
          final existingQotd = await _supabase
              .from('question_of_the_day_history')
              .select('''
                question_id,
                questions!inner(
                  *,
                  question_options(*),
                  question_categories (
                    categories (
                      id,
                      name,
                      is_nsfw
                    )
                  )
                )
              ''')
              .eq('date', dateKey)
              .single();

          if (existingQotd != null && existingQotd['questions'] != null) {
            final storedQuestion = existingQotd['questions'];

            // Check if the stored question is still valid (not hidden)
            if (storedQuestion['is_hidden'] != true) {
              // Check if the question has any reports
              bool hasReports = false;
              try {
                final reports = await _supabase
                    .from('reports')
                    .select('id')
                    .eq('question_id', storedQuestion['id'])
                    .limit(1);
                hasReports = reports.isNotEmpty;
              } catch (e) {
                print('Error checking reports for QotD: $e');
              }

              if (!hasReports) {
                print('Using server-selected QotD for $dateKey: ${storedQuestion['prompt']}');
                selectedQuestion = _processQotdQuestion(storedQuestion);
              } else {
                print('Server-selected QotD for $dateKey has reports, using fallback');
              }
            } else {
              print('Server-selected QotD for $dateKey is hidden, using fallback');
            }
          }
        } catch (e) {
          // No QOTD found for today - server hasn't selected one yet
          print('No QotD found for $dateKey, using fallback: $e');
        }

        // Fallback: find most popular question from recent days without reports
        if (selectedQuestion == null) {
          selectedQuestion = await _findFallbackQotd(now);
        }

        if (selectedQuestion != null) {
          _questionOfTheDay = selectedQuestion;
          _lastQuestionOfTheDayUpdate = now;

          // Check if user is the author and show achievement notification
          final notificationService = NotificationService();
          await notificationService.showQOTDAuthorNotification(selectedQuestion);
        }

        notifyListeners();
      } catch (e) {
        print('Error fetching question of the day: $e');
      } finally {
        // Reset QotD update flag
        _qotdUpdateInProgress = false;
      }
    });
  }

  // Process a raw question into the expected QOTD format
  Map<String, dynamic> _processQotdQuestion(Map<String, dynamic> question) {
    final processedQuestion = Map<String, dynamic>.from(question);

    // Transform the nested categories structure into a simple array
    final questionCategories = question['question_categories'] as List<dynamic>? ?? [];
    final categories = questionCategories
        .map((qc) => qc['categories'])
        .where((cat) => cat != null)
        .map((cat) => cat['name'] as String)
        .toList();

    processedQuestion['categories'] = categories;
    processedQuestion.remove('question_categories');

    // Map nsfw to is_nsfw for compatibility
    if (processedQuestion.containsKey('nsfw')) {
      processedQuestion['is_nsfw'] = processedQuestion['nsfw'];
    }

    return processedQuestion;
  }

  // Find a fallback QOTD by searching for most popular question without reports
  // Mirrors server logic: last 14 days, excludes past QOTDs, sorted by response count
  Future<Map<String, dynamic>?> _findFallbackQotd(DateTime now) async {
    const maxDaysBack = 30;

    // Fetch last 14 QOTD entries to exclude past selections
    final Set<String> pastQotdIds = {};
    try {
      final history = await _supabase
          .from('question_of_the_day_history')
          .select('question_id')
          .order('date', ascending: false)
          .limit(14);
      for (final entry in history) {
        pastQotdIds.add(entry['question_id'] as String);
      }
    } catch (e) {
      print('Error fetching QOTD history for fallback: $e');
    }

    for (int daysBack = 1; daysBack <= maxDaysBack; daysBack++) {
      final dayStart = now.subtract(Duration(days: daysBack));
      final dayEnd = now.subtract(Duration(days: daysBack - 1));

      try {
        // Get questions from this day, ordered by response count
        final questions = await _supabase
            .from('questions')
            .select('''
              *,
              question_options(*),
              question_categories (
                categories (
                  id,
                  name,
                  is_nsfw
                )
              )
            ''')
            .eq('is_hidden', false)
            .eq('nsfw', false)
            .eq('targeting_type', 'globe')
            .gte('created_at', dayStart.toIso8601String())
            .lt('created_at', dayEnd.toIso8601String())
            .limit(20);

        if (questions == null || questions.isEmpty) continue;

        // Get response counts and filter out reported/past QOTD questions
        final candidates = <Map<String, dynamic>>[];
        for (var question in questions) {
          // Skip past QOTDs
          if (pastQotdIds.contains(question['id'])) continue;

          // Check for reports
          try {
            final reports = await _supabase
                .from('reports')
                .select('id')
                .eq('question_id', question['id'])
                .limit(1);
            if (reports.isNotEmpty) continue; // Has reports, skip
          } catch (e) {
            continue; // Can't verify, skip
          }

                    // Get response count
          int responseCount = 0;
          try {
            responseCount =
                await _resultsService.fetchTotalCount(question['id'].toString());
          } catch (e) {
            // Continue with 0 count
          }

          final processed = _processQotdQuestion(question);
          processed['votes'] = responseCount;
          candidates.add(processed);
        }

        if (candidates.isNotEmpty) {
          // Sort by response count (most popular first)
          candidates.sort((a, b) => (b['votes'] as int).compareTo(a['votes'] as int));
          print('Using fallback QotD from $daysBack day(s) ago: ${candidates.first['prompt']}');
          return candidates.first;
        }
      } catch (e) {
        print('Error searching fallback QotD $daysBack days ago: $e');
      }
    }

    print('No fallback QotD found after $maxDaysBack days');
    return null;
  }

  // Method to handle QotD refresh when current QotD gets moderated
  Future<void> _selectNewQotDDueToModeration() async {
    try {
      print('Refreshing QotD due to moderation of current QotD...');

      // Clear the current QotD immediately
      _questionOfTheDay = null;

      // Force a refresh by resetting the last update time
      _lastQuestionOfTheDayUpdate = null;

      // Trigger immediate QotD fetch
      await _updateQuestionOfTheDay();

      print('QotD refreshed after moderation');
    } catch (e) {
      print('Error refreshing QotD due to moderation: $e');
      _questionOfTheDay = null;
    }
  }

  Future<void> checkQOTDSubscriptionPrompt(BuildContext context, Map<String, dynamic> question) async {
    try {
      // Check if this question is the current QOTD
      if (_questionOfTheDay == null || question['id'] != _questionOfTheDay!['id']) {
        return; // Not a QOTD, no prompt needed
      }

      // Check if user has QOTD notifications enabled
      final notificationService = NotificationService();
      final userService = Provider.of<UserService>(context, listen: false);
      
      // Only prompt if user doesn't have QOTD notifications enabled
      final hasPermissions = await notificationService.arePermissionsGranted();
      if (!hasPermissions || userService.notifyQOTD) {
        return; // Either no permissions or already subscribed to QOTD
      }

      // Check when we last showed this prompt
      final prefs = await SharedPreferences.getInstance();
      final lastPromptTime = prefs.getString('qotd_subscription_last_prompt');
      
      if (lastPromptTime != null) {
        final lastPrompt = DateTime.parse(lastPromptTime);
        final daysSinceLastPrompt = DateTime.now().difference(lastPrompt).inDays;
        
        if (daysSinceLastPrompt < 2) {
          return; // Don't prompt again if shown within the last 2 days
        }
      }

      // Show the QOTD notification permission dialog
      await NotificationPermissionDialog.show(
        context,
        onPermissionGranted: () async {
          // Record that we showed the prompt
          await prefs.setString('qotd_subscription_last_prompt', DateTime.now().toIso8601String());
          
          // Subscribe to QOTD notifications
          await notificationService.subscribeToQOTD();
          
          // Update user service setting
          userService.setNotifyQOTD(true);

          // Show success message
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  '✅ Subscribed to daily questions! You\'ll get notified when new questions are posted.',
                  style: TextStyle(color: Colors.white),
                ),
                backgroundColor: Theme.of(context).primaryColor,
                duration: Duration(seconds: 3),
              ),
            );
          }
        },
        onPermissionDenied: () async {
          // Record that we showed the prompt even if denied
          await prefs.setString('qotd_subscription_last_prompt', DateTime.now().toIso8601String());
        },
      );
    } catch (e) {
      print('Error checking QOTD subscription prompt: $e');
      // Don't block the user experience if this fails
    }
  }

  // Add pagination support (using existing fields from above)

  Future<void> fetchQuestions({
    int limit = 50,
    String? cursor,
    Map<String, dynamic>? filters,
  }) async {
    // If we're already loading or we have sample data, don't fetch
    if (_isLoading) {
      return Future.value();
    }
    
    if (_usingSampleData && _questions.isNotEmpty) {
      print('Using sample data, skipping database fetch');
      return Future.value();
    }
    
    _isLoading = true;
    notifyListeners();
    
    // Store the start time for minimum loading duration
    final loadingStartTime = DateTime.now();

    try {
      print('Fetching questions from Supabase with pagination...');
      
      // Build query with server-side filtering
      var query = _supabase
          .from('questions')
          .select('''
            id,
            prompt,
            description,
            type,
            created_at,
            nsfw,
            is_hidden,
            targeting_type,
            country_code,
            city_id,
            author_id,
            cities(name),
            question_options (
              id,
              option_text,
              sort_order
            ),
            question_categories (
              categories (
                id,
                name,
                is_nsfw
              )
            )
          ''')
          .eq('is_hidden', false);

      // Apply server-side filters if provided
      if (filters != null) {
        // Always filter NSFW content unless explicitly enabled
        if (filters['showNSFW'] != true) {
          query = query.eq('nsfw', false);
        }
        
        if (filters['questionTypes'] != null) {
          final types = filters['questionTypes'] as List<String>;
          if (types.isNotEmpty) {
            // Map client-side types to database enum values
            final mappedTypes = types.map((type) {
              switch (type) {
                case 'approval':
                  return 'approval_rating';
                case 'multipleChoice':
                  return 'multiple_choice';
                default:
                  return type; // text and other types remain the same
              }
            }).toList();
            
            query = query.filter('type', 'in', '(${mappedTypes.map((t) => '"$t"').join(',')})');
          }
        }
        
        // Apply targeting_type filter based on location mode
        final locationFilter = filters['locationFilter'] as String?;
        if (locationFilter == 'global') {
          // Global mode: show globe, country, and user's city questions
          final userCityId = filters['userCity'] as String?;
          if (userCityId != null) {
            // Include user's city questions along with globe and country questions
            query = query.or('targeting_type.in.(globe,country),and(targeting_type.eq.city,city_id.eq.$userCityId)');
          } else {
            // No user city set, show only globe and country questions
            query = query.filter('targeting_type', 'in', '("globe","country")');
          }
        } else if (locationFilter == 'country' && filters['userCountry'] != null) {
          // Country mode: only show questions addressed to user's country (exclude global)
          final userCountry = filters['userCountry'] as String;
          query = query.eq('targeting_type', 'country').eq('country_code', userCountry);
        } else if (locationFilter == 'city' && filters['userCountry'] != null) {
          // City mode: show questions addressed to globe or user's country
          final userCountry = filters['userCountry'] as String;
          query = query.or('targeting_type.eq.globe,country_code.eq.$userCountry');
        }
      } else {
        // If no filters provided, default to hiding NSFW content
        query = query.eq('nsfw', false);
      }

      // Add pagination - use cursor-based for better performance
      if (cursor != null) {
        query = query.lt('created_at', cursor);
      }

      // Order and limit
      final response = await query
          .order('created_at', ascending: false)
          .limit(limit);

      // Check if we got any questions
      if (response.isEmpty) {
        print('No questions found in database');
        _hasMoreQuestions = false;
        
        if (_questions.isEmpty) {
          print('Creating sample data as fallback');
          await seedInitialQuestions();
        }
        return;
      }
      
      print('Found ${response.length} questions in database');
      
      // Transform the data to include categories as a simple array
      final processedQuestions = response.map((question) {
        final Map<String, dynamic> processedQuestion = Map<String, dynamic>.from(question);
        
        // Transform the nested categories structure into a simple array
        final questionCategories = question['question_categories'] as List<dynamic>? ?? [];
        final categories = questionCategories
          .map((qc) => qc['categories'])
          .where((cat) => cat != null)
          .map((cat) => cat['name'] as String)
          .toList();
        
        processedQuestion['categories'] = categories;
        
        // Map nsfw to is_nsfw for compatibility
        if (processedQuestion.containsKey('nsfw')) {
          processedQuestion['is_nsfw'] = processedQuestion['nsfw'];
        }
        
        // Remove the junction table data as it's no longer needed
        processedQuestion.remove('question_categories');
        
        return processedQuestion;
      }).toList();
      
      // If this is a fresh load, replace questions. If pagination, append.
      if (cursor == null) {
        _questions = processedQuestions;
        
        // Skip startup prefetch - responses will be loaded on-demand when user browses
        // This improves startup performance by avoiding blocking database queries
      } else {
        _questions.addAll(processedQuestions);
        
        // Skip pagination prefetch - responses will be loaded on-demand when user browses
        // This improves performance by avoiding blocking database queries
      }
      
      _usingSampleData = false;
      
      // Set cursor for next page
      if (processedQuestions.isNotEmpty) {
        _lastFetchedId = processedQuestions.last['created_at'];
        _hasMoreQuestions = processedQuestions.length == limit;
      } else {
        _hasMoreQuestions = false;
      }
      
      // Calculate vote counts from responses table
      await _updateQuestionResponseCounts();
      
      // Note: Engagement data enrichment moved to progressive loading in UI
      // This allows questions to appear immediately while comments load in background
      
      await _updateQuestionOfTheDay();
      
    } catch (e) {
      print('Error fetching questions: $e');
      
      if (_questions.isEmpty) {
        print('Error fetching from DB, falling back to sample data');
        await seedInitialQuestions();
      }
    } finally {
      // Ensure minimum 2.8-second loading display time
      final loadingDuration = DateTime.now().difference(loadingStartTime);
      final minimumLoadingTime = Duration(milliseconds: 2800);
      
      if (loadingDuration < minimumLoadingTime) {
        final remainingTime = minimumLoadingTime - loadingDuration;
        print('⏳ Extending loading display by ${remainingTime.inMilliseconds}ms to show curio loading');
        await Future.delayed(remainingTime);
      }
      
      _isLoading = false;
      notifyListeners();
    }
  }

  // Get engagement data from the materialized view (same as Edge Function)
  Future<Map<String, dynamic>?> getQuestionEngagementFromView(String questionId) async {
    try {
      final response = await _supabase
          .from('feed_questions_optimized_v3')
          .select('comment_count, reaction_count')
          .eq('id', questionId)
          .limit(1);
      
      if (response != null && response.isNotEmpty) {
        return response.first as Map<String, dynamic>;
      }
      return null;
    } catch (e) {
      print('Error getting engagement data from view for question $questionId: $e');
      return null;
    }
  }

  // Get category counts from the current feed based on materialized view
  Future<Map<String, int>> getCurrentFeedCategoryCounts({
    required String feedType,
    Map<String, dynamic>? filters,
  }) async {
    try {
      // Build the base query with filters
      var queryBuilder = _supabase
          .from('feed_questions_optimized_v3')
          .select('categories')
          .eq('is_hidden', false);

      // Apply filters if provided
      if (filters != null) {
        // NSFW filter
        if (filters['showNSFW'] == false) {
          queryBuilder = queryBuilder.eq('nsfw', false);
        }

        // Question types filter
        final enabledTypes = filters['questionTypes'] as List<String>?;
        if (enabledTypes != null && enabledTypes.isNotEmpty) {
          queryBuilder = queryBuilder.inFilter('type', enabledTypes);
        }

        // Location filters
        final userCountry = filters['userCountry'] as String?;
        final userCity = filters['userCity'] as String?;
        
        if (userCountry != null) {
          if (userCity != null) {
            // User has both country and city - show global, country, and their city questions
            queryBuilder = queryBuilder.or('targeting_type.eq.globe,and(targeting_type.eq.country,country_code.eq.$userCountry),and(targeting_type.eq.city,city_id.eq.$userCity)');
          } else {
            // User has country but no city - show global and their country questions
            queryBuilder = queryBuilder.or('targeting_type.eq.globe,and(targeting_type.eq.country,country_code.eq.$userCountry)');
          }
        } else {
          // No location data - show only global questions
          queryBuilder = queryBuilder.eq('targeting_type', 'globe');
        }
      }

      // Apply sorting and limit based on feed type
      final query = switch (feedType) {
        'trending' => queryBuilder.order('trending_score', ascending: false).limit(100),
        'popular' => queryBuilder.order('popular_score', ascending: false).limit(100),
        'new' => queryBuilder.order('created_at', ascending: false).limit(100),
        _ => queryBuilder.order('trending_score', ascending: false).limit(100),
      };

      final response = await query;

      if (response.isEmpty) {
        print('No questions found for category counting');
        return {};
      }

      // Count categories
      final categoryCounts = <String, int>{};
      
      for (final question in response) {
        final categories = question['categories'] as List<dynamic>?;
        if (categories != null) {
          for (final category in categories) {
            final categoryName = category.toString();
            categoryCounts[categoryName] = (categoryCounts[categoryName] ?? 0) + 1;
          }
        }
      }

      print('📊 Category counts from current feed: $categoryCounts');
      return categoryCounts;
    } catch (e) {
      print('Error getting category counts from feed: $e');
      return {};
    }
  }

  // Get fresh engagement data (reactions and comments) for a question
  Future<Map<String, dynamic>> getQuestionEngagementData(String questionId) async {
    try {
      // Fetch reaction counts
      final reactionsResponse = await _supabase
          .from('question_reactions')
          .select('reaction_type')
          .eq('question_id', questionId);
      
      // Count reactions by type
      final reactionCounts = <String, int>{};
      int totalReactions = 0;
      
      if (reactionsResponse != null) {
        for (final reaction in reactionsResponse) {
          final reactionType = reaction['reaction_type'] as String?;
          if (reactionType != null) {
            reactionCounts[reactionType] = (reactionCounts[reactionType] ?? 0) + 1;
            totalReactions++;
          }
        }
      }
      
      // Fetch comment count
      final commentsResponse = await _supabase
          .from('comments')
          .select('id')
          .eq('question_id', questionId)
          .count(CountOption.exact);
      
      final commentCount = commentsResponse.count ?? 0;
      
      return {
        'reactions': reactionCounts,
        'reaction_count': totalReactions,
        'comment_count': commentCount,
      };
    } catch (e) {
      print('Error getting engagement data for question $questionId: $e');
      return {
        'reactions': <String, int>{},
        'reaction_count': 0,
        'comment_count': 0,
      };
    }
  }

  // Centralized method to get accurate vote count for any question
  Future<int> getAccurateVoteCount(String questionId, String? questionType) async {
    try {
            if (questionType == 'multiple_choice' ||
          questionType == 'multiplechoice' ||
          questionType == 'approval_rating' ||
          questionType == 'approval') {
        // The server does the type-aware validation now: multiple choice counts
        // only answers whose option belongs to THIS question, approval counts
        // only scored answers. Same rule, one round trip, no rows on the wire.
        return await _resultsService.fetchAnsweredCount(questionId);
      } else if (questionType == 'text') {
        // For discussion questions, count unique commenters
        final comments = await _supabase
            .from('comments')
            .select('author_id')
            .eq('question_id', questionId)
            .eq('is_hidden', false);

        final uniqueAuthors = <String>{};
        for (final c in comments ?? []) {
          final authorId = c['author_id']?.toString();
          if (authorId != null) uniqueAuthors.add(authorId);
        }
        return uniqueAuthors.length;
            } else {
        // For other question types, count all responses
        return await _resultsService.fetchTotalCount(questionId);
      }
    } catch (e) {
      print('Error getting accurate vote count for question $questionId: $e');
      return 0;
    }
  }

  // Update response counts for all questions using centralized logic
  Future<void> _updateQuestionResponseCounts() async {
    // Throttle vote count updates (no more than once every 30 seconds)
    final now = DateTime.now();
    if (_voteCountUpdateInProgress) {
      print('🔄 Vote count update already in progress, skipping duplicate request');
      return;
    }
    
    if (_lastVoteCountUpdate != null && 
        now.difference(_lastVoteCountUpdate!) < Duration(seconds: 30)) {
      print('⏸️ Vote count update throttled: Too recent (${now.difference(_lastVoteCountUpdate!).inSeconds}s ago)');
      return;
    }

    // Use request deduplication to prevent multiple concurrent vote count updates
    const requestKey = 'update_question_response_counts';
    return _deduplicationService.deduplicateRequest(requestKey, () async {
      _voteCountUpdateInProgress = true;
      _lastVoteCountUpdate = now;
      
      try {
        print('Updating vote counts for ${_questions.length} questions - MOVED TO BACKGROUND for faster startup');
        
        // Initialize all votes to 0 first for immediate UI display
        for (var i = 0; i < _questions.length; i++) {
          if (_questions[i]['votes'] == null) {
            _questions[i]['votes'] = 0;
          }
        }
        
        // Move the actual vote count fetching to background
        // This prevents blocking app startup while still updating counts
        Future.microtask(() async {
          await _updateVoteCountsInBackground();
        });
        
      } catch (e) {
        print('Error initializing response counts: $e');
        
        // Initialize votes to 0 if not set
        for (var i = 0; i < _questions.length; i++) {
          if (_questions[i]['votes'] == null) {
            _questions[i]['votes'] = 0;
          }
        }
      } finally {
        // Reset vote count update flag immediately since actual work is in background
        _voteCountUpdateInProgress = false;
      }
    });
  }

  // Background method to update vote counts without blocking startup
  Future<void> _updateVoteCountsInBackground() async {
    try {
      print('🔄 Starting background vote count update for ${_questions.length} questions');
      
      for (var i = 0; i < _questions.length; i++) {
        final questionId = _questions[i]['id']?.toString();
        final questionType = _questions[i]['type']?.toString();
        
        if (questionId != null) {
          try {
            final count = await getAccurateVoteCount(questionId, questionType);
            _questions[i]['votes'] = count;
            
            // Notify listeners every 10 questions to show progress
            if ((i + 1) % 10 == 0) {
              notifyListeners();
              print('📊 Background vote count progress: ${i + 1}/${_questions.length} questions updated');
            }
          } catch (e) {
            print('Error counting responses for question $questionId: $e');
            _questions[i]['votes'] = 0;
          }
        } else {
          _questions[i]['votes'] = 0;
        }
        
        // Small delay to avoid overwhelming the database
        await Future.delayed(Duration(milliseconds: 50));
      }
      
      // Final notification after all counts are updated
      notifyListeners();
      print('✅ Background vote count update completed for ${_questions.length} questions');
      
    } catch (e) {
      print('❌ Error in background vote count update: $e');
    }
  }

  Future<List<Map<String, dynamic>>> searchQuestions(String query, {LocationService? locationService, bool includeNSFW = false, bool excludePrivate = false}) async {
    if (query.isEmpty) return [];

    final lowercaseQuery = query.toLowerCase().trim();
    
    // Get user location info for geographic filtering
    String? userCountryCode;
    String? userCityId;
    
    if (locationService != null) {
      userCountryCode = locationService.userLocation?['country_code']?.toString() ?? 
                       locationService.selectedCity?['country_code']?.toString();
      userCityId = locationService.selectedCity?['id']?.toString();
      
      print('Search filtering: userCountry=$userCountryCode, userCity=$userCityId');
    } else {
      print('Search filtering: No location service provided, showing global questions only');
    }
    
    try {
      // Build the database query for searching ALL questions
      var baseQuery = _supabase
          .from('questions')
          .select('''
            *,
            question_categories(categories(*)),
            question_options(id, option_text, sort_order)
          ''')
          .eq('is_hidden', false);
      
      // Conditionally filter private questions based on parameter
      if (excludePrivate) {
        baseQuery = baseQuery.eq('is_private', false);
      }
      
      // Conditionally filter NSFW questions based on parameter
      if (!includeNSFW) {
        baseQuery = baseQuery.eq('nsfw', false);
      }
      
      // Build geographic targeting filter
      if (userCountryCode != null) {
        if (userCityId != null) {
          // User has both country and city - show global, country, and their city questions
          baseQuery = baseQuery.or('targeting_type.eq.globe,and(targeting_type.eq.country,country_code.eq.$userCountryCode),and(targeting_type.eq.city,city_id.eq.$userCityId)');
        } else {
          // User has country but no city - show global and country questions only
          baseQuery = baseQuery.or('targeting_type.eq.globe,and(targeting_type.eq.country,country_code.eq.$userCountryCode)');
        }
      } else {
        // No user location - only show global questions
        baseQuery = baseQuery.eq('targeting_type', 'globe');
      }
      
      // For database search, we need to use PostgreSQL text search or LIKE operators
      // Let's use ilike (case-insensitive LIKE) for broad text matching
      final searchPattern = '%$lowercaseQuery%';
      baseQuery = baseQuery.or('prompt.ilike.$searchPattern,description.ilike.$searchPattern');
      
      // Order by relevance (created_at desc) and limit results
      final response = await baseQuery
          .order('created_at', ascending: false)
          .limit(200); // Increase limit to 200 for search results
      
      if (response.isEmpty) {
        print('Database search "$query": 0 results found');
        return [];
      }
      
      // Transform the data to include categories as a simple array. Counts
      // are fetched in batches below — this loop used to make two sequential
      // requests per row (one counts RPC, one comments select), so a search
      // with 200 matches cost 400 round trips before anything rendered.
      final processedQuestions = <Map<String, dynamic>>[];
      
      for (var question in response) {
        final Map<String, dynamic> processedQuestion = Map<String, dynamic>.from(question);
        
        // Transform the nested categories structure into a simple array
        final questionCategories = question['question_categories'] as List<dynamic>? ?? [];
        final categories = questionCategories
          .map((qc) => qc['categories'])
          .where((cat) => cat != null)
          .map((cat) => cat['name'] as String)
          .toList();
        
        processedQuestion['categories'] = categories;
        
        // Map nsfw to is_nsfw for compatibility
        if (processedQuestion.containsKey('nsfw')) {
          processedQuestion['is_nsfw'] = processedQuestion['nsfw'];
        }
        
        // Remove the junction table data as it's no longer needed
        processedQuestion.remove('question_categories');
        
        processedQuestion['votes'] = 0;
        processedQuestion['comment_count'] = 0;
        processedQuestions.add(processedQuestion);
      }

      // Vote counts (the batch RPC, chunked by the service) and comment counts
      // (one select per 50 questions) in parallel: about three requests for a
      // full page instead of hundreds.
      final ids = [
        for (final q in processedQuestions) q['id'].toString()
      ];
      final counts = await Future.wait([
        _resultsService.fetchVoteCounts(ids).catchError((e) {
          print('Error fetching vote counts for search results: $e');
          return <String, int>{};
        }),
        _fetchCommentCounts(ids),
      ]);
      final voteCounts = counts[0];
      final commentCounts = counts[1];
      for (final q in processedQuestions) {
        final id = q['id'].toString();
        q['votes'] = voteCounts[id] ?? 0;
        q['comment_count'] = commentCounts[id] ?? 0;
      }
      
      // Additional client-side filtering for multiple choice options text search
      final filteredResults = processedQuestions.where((question) {
        // Basic text matching already done by database query
        bool matches = true;
        
        // Additional search in options for multiple choice questions
        if (question['type'] == 'multiple_choice') {
          final options = question['question_options'] as List<dynamic>?;
          if (options != null) {
            final optionMatches = options.any((option) {
              final optionText = option['option_text']?.toString().toLowerCase() ?? '';
              return optionText.contains(lowercaseQuery);
            });
            
            // If we found it in options, keep it; if not, check if it matched title/description from DB query
            if (optionMatches) {
              matches = true;
            }
          }
        }
        
        return matches;
      }).toList();
      
      // Sort by relevance (votes desc, then created_at desc)
      filteredResults.sort((a, b) {
        final votesA = a['votes'] as int? ?? 0;
        final votesB = b['votes'] as int? ?? 0;
        
        if (votesA != votesB) {
          return votesB.compareTo(votesA);
        }
        
        // If votes are equal, sort by creation date
        final dateA = DateTime.tryParse(a['created_at'] ?? '') ?? DateTime.now();
        final dateB = DateTime.tryParse(b['created_at'] ?? '') ?? DateTime.now();
        return dateB.compareTo(dateA);
      });
      
      print('Database search "$query": ${filteredResults.length} results found from ${response.length} database matches');
      return filteredResults;
      
    } catch (e) {
      print('Error performing database search: $e');
      // Fallback to local search if database search fails
      return _searchQuestionsLocally(query, locationService: locationService, excludePrivate: excludePrivate);
    }
  }
  
  // Fallback method for local search (original implementation)
  /// Non-hidden comment counts for [questionIds], `{questionId: n}`. One
  /// select of `question_id` per 50 questions, counted here; questions with
  /// no comments are simply absent. Never throws.
  Future<Map<String, int>> _fetchCommentCounts(List<String> questionIds) async {
    final counts = <String, int>{};
    final ids = questionIds.where((id) => id.isNotEmpty).toSet().toList();
    const chunkSize = 50;
    for (var i = 0; i < ids.length; i += chunkSize) {
      final chunk = ids.sublist(i, (i + chunkSize).clamp(0, ids.length));
      try {
        final rows = await _supabase
            .from('comments')
            .select('question_id')
            .inFilter('question_id', chunk)
            .eq('is_hidden', false)
            .limit(5000);
        for (final row in rows) {
          final id = row['question_id']?.toString();
          if (id == null) continue;
          counts[id] = (counts[id] ?? 0) + 1;
        }
      } catch (e) {
        print('Error fetching comment counts for search results: $e');
      }
    }
    return counts;
  }

  List<Map<String, dynamic>> _searchQuestionsLocally(String query, {LocationService? locationService, bool excludePrivate = false}) {
    if (query.isEmpty) return [];

    final lowercaseQuery = query.toLowerCase().trim();
    
    // Get user location info for geographic filtering
    String? userCountryCode;
    String? userCityId;
    
    if (locationService != null) {
      userCountryCode = locationService.userLocation?['country_code']?.toString() ?? 
                       locationService.selectedCity?['country_code']?.toString();
      userCityId = locationService.selectedCity?['id']?.toString();
    }
    
    final totalQuestions = _questions.length;
    
    final results = _questions.where((question) {
      // First, apply geographic targeting filter
      if (!_isQuestionGeographicallyRelevant(question, userCountryCode, userCityId)) {
        return false;
      }
      
      // Filter out private questions if excludePrivate is true
      if (excludePrivate && question['is_private'] == true) {
        return false;
      }
      
      // Then, apply search text matching
      // Search in prompt (main question title)
      final prompt = question['prompt']?.toString().toLowerCase() ?? '';
      if (prompt.contains(lowercaseQuery)) {
        return true;
      }
      
      // Search in description
      final description = question['description']?.toString().toLowerCase() ?? '';
      if (description.contains(lowercaseQuery)) {
        return true;
      }
      
      // Search in options (for multiple choice questions)
      if (question['type'] == 'multiple_choice' || question['type'] == 'multipleChoice') {
        final options = question['question_options'] as List<dynamic>?;
        if (options != null) {
          for (var option in options) {
            final optionText = option['option_text']?.toString().toLowerCase() ?? '';
            if (optionText.contains(lowercaseQuery)) {
              return true;
            }
          }
        }
      }
      
      return false;
    }).toList()
      ..sort((a, b) {
        // Sort by number of responses (votes)
        final votesA = a['votes'] as int? ?? 0;
        final votesB = b['votes'] as int? ?? 0;
        return votesB.compareTo(votesA);
      });
    
    print('Local search "$query": ${results.length} results from $totalQuestions cached questions (fallback)');
    return results;
  }

  // Helper method to check if a question is geographically relevant to the user
  bool _isQuestionGeographicallyRelevant(Map<String, dynamic> question, String? userCountryCode, String? userCityId) {
    final targeting = question['targeting_type']?.toString().toLowerCase();
    
    // Global questions are always relevant
    if (targeting == 'globe' || targeting == 'global') {
      return true;
    }
    
    // If no user location, only show global questions
    if (userCountryCode == null) {
      return false;
    }
    
    // For country-targeted questions
    if (targeting == 'country') {
      final questionCountryCode = question['country_code']?.toString();
      return questionCountryCode == userCountryCode;
    }
    
    // For city-targeted questions
    if (targeting == 'city') {
      // First check if question targets user's specific city
      final questionCityId = question['city_id']?.toString();
      if (userCityId != null && questionCityId == userCityId) {
        return true;
      }
      
      // If user hasn't selected a city, they can't see city-targeted questions
      if (userCityId == null) {
        return false;
      }
      
      // Question targets a different city - check if same county and country
      // Get user's city details (would need to be passed or cached)
      // For now, this is handled in the home screen filtering logic
      // This method is used for search results where we apply more restrictive filtering
      return false;
    }
    
    // Default to false for unknown targeting types
    return false;
  }

  Future<Map<String, dynamic>?> navigateToAnswerScreen(BuildContext context, Map<String, dynamic> question, {FeedContext? feedContext, bool fromSearch = false, bool fromUserScreen = false, String entrySource = 'other'}) async {
    // Get required services upfront to avoid context issues
    final supabase = Supabase.instance.client;
    final questionId = question['id']?.toString();
    final guestTrackingService = Provider.of<GuestUserTrackingService>(context, listen: false);

    // Check if this question was previously viewed as a guest (even if user is now authenticated)
    if (questionId != null && guestTrackingService.wasViewedAsGuest(questionId)) {
      print('Question $questionId was previously viewed as guest, skipping to results screen');
      return await navigateToResultsScreen(context, question, feedContext: feedContext, fromSearch: fromSearch, fromUserScreen: fromUserScreen, isGuestMode: false);
    }
    
    // Check if user is authenticated
    if (supabase.auth.currentUser == null && questionId != null) {
      // User is not authenticated - check guest view limits
      
      // Check if this question can be viewed
      if (await guestTrackingService.canViewQuestion(questionId)) {
        // Record the view and proceed to results screen (read-only)
        await guestTrackingService.recordQuestionView(questionId);
        print('Guest user viewing question $questionId (${guestTrackingService.guestViewCount}/${3})');
        return await navigateToResultsScreen(context, question, feedContext: feedContext, fromSearch: fromSearch, fromUserScreen: fromUserScreen, isGuestMode: true);
      } else {
        // Guest has reached limit - show authentication dialog
        print('Guest user reached view limit, showing authentication dialog');
        final shouldAuthenticate = await showDialog<bool>(
          context: context,
          builder: (context) => AuthenticationDialog(
            title: 'Authenticate as Human',
            message: 'Please authenticate as a real human to continue browsing. \n\nWe want to make sure you aren\'t a bot so that the answers on this app are authentic.',
            actionButtonText: 'Authenticate',
          ),
        );
        
        if (shouldAuthenticate == true) {
          // User chose to authenticate - navigate to auth screen
          Navigator.pushNamed(context, '/authentication');
        }
        return null;
      }
    }
    
    // User is authenticated - proceed to answer screen normally
    return await _proceedToAnswerScreen(context, question, feedContext: feedContext, fromSearch: fromSearch, fromUserScreen: fromUserScreen, entrySource: entrySource);
  }

  Future<Map<String, dynamic>?> _proceedToAnswerScreen(BuildContext context, Map<String, dynamic> question, {FeedContext? feedContext, bool fromSearch = false, bool fromUserScreen = false, String entrySource = 'other'}) async {
    // Check if this is a QOTD and user should be prompted for QOTD notifications
    await checkQOTDSubscriptionPrompt(context, question);
    
    // Ensure question has all expected fields
    var enhancedQuestion = Map<String, dynamic>.from(question);
    
    // Fetch the current vote count from database
    try {
            final questionId = enhancedQuestion['id']?.toString();
      if (questionId != null) {
        final currentVoteCount = await _resultsService.fetchTotalCount(questionId);
        enhancedQuestion['votes'] = currentVoteCount;
        // print('Updated vote count for question $questionId: $currentVoteCount responses');
      }
    } catch (e) {
      print('Error fetching vote count for answer screen: $e');
      // Fallback to existing vote count or 0
      if (enhancedQuestion['votes'] == null) {
        enhancedQuestion['votes'] = 0;
      }
    }
    
    // Make sure created_at is present
    if (enhancedQuestion['created_at'] == null && enhancedQuestion['timestamp'] != null) {
      enhancedQuestion['created_at'] = enhancedQuestion['timestamp'];
    } else if (enhancedQuestion['created_at'] == null) {
      enhancedQuestion['created_at'] = DateTime.now().toIso8601String();
    }
    
    // Determine type with fallbacks
    final type = enhancedQuestion['type']?.toString().toLowerCase() ?? 'text';
    
    // Navigate based on question type
    if (type == 'approval_rating' || type == 'approval') {
      print('QuestionService: Navigating to approval screen for question ${enhancedQuestion['id']}');
      final result = await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => AnswerApprovalScreen(question: enhancedQuestion, feedContext: feedContext, fromSearch: fromSearch, fromUserScreen: fromUserScreen, entrySource: entrySource),
        ),
      );
      print('QuestionService: Approval screen returned result: $result');
      return result as Map<String, dynamic>?;
    } else if (type == 'multiple_choice' || type == 'multiplechoice') {
      // For multiple choice, make sure options are present
      if (!enhancedQuestion.containsKey('question_options') || 
          (enhancedQuestion['question_options'] as List<dynamic>?)?.isEmpty == true) {
        // Fetch options from database
        try {
          final questionId = enhancedQuestion['id']?.toString();
          if (questionId != null) {
            final optionsResponse = await _supabase
                .from('question_options')
                .select('id, option_text, sort_order')
                .eq('question_id', questionId)
                .order('sort_order');
            
            if (optionsResponse != null && optionsResponse.isNotEmpty) {
              enhancedQuestion['question_options'] = optionsResponse;
              print('Fetched ${optionsResponse.length} options for MC question $questionId');
            } else {
              // Add some default options if no options found in database
              enhancedQuestion['question_options'] = [
                {'option_text': 'Option 1', 'id': '1'},
                {'option_text': 'Option 2', 'id': '2'},
                {'option_text': 'Option 3', 'id': '3'},
              ];
              print('No options found in database, using defaults for question $questionId');
            }
          }
        } catch (e) {
          print('Error fetching question options: $e');
          // Fallback to default options
          enhancedQuestion['question_options'] = [
            {'option_text': 'Option 1', 'id': '1'},
            {'option_text': 'Option 2', 'id': '2'},
            {'option_text': 'Option 3', 'id': '3'},
          ];
        }
      }
      
      print('QuestionService: Navigating to multiple choice screen for question ${enhancedQuestion['id']}');
      final result = await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => AnswerMultipleChoiceScreen(question: enhancedQuestion, feedContext: feedContext, fromSearch: fromSearch, fromUserScreen: fromUserScreen, entrySource: entrySource),
        ),
      );
      print('QuestionService: Multiple choice screen returned result: $result');
      return result as Map<String, dynamic>?;
    } else if (type == 'text') {
      print('QuestionService: Navigating to text screen for question ${enhancedQuestion['id']}');
      final result = await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => AnswerTextScreen(question: enhancedQuestion, feedContext: feedContext, fromSearch: fromSearch, fromUserScreen: fromUserScreen, entrySource: entrySource),
        ),
      );
      print('QuestionService: Text screen returned result: $result');
      return result as Map<String, dynamic>?;
    } else {
      // Default to text question for unknown types
      print('Unknown question type: ${enhancedQuestion['type']}, defaulting to text');
      enhancedQuestion['type'] = 'text';
      final result = await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => AnswerTextScreen(question: enhancedQuestion, feedContext: feedContext, fromSearch: fromSearch, fromUserScreen: fromUserScreen, entrySource: entrySource),
        ),
      );
      return result as Map<String, dynamic>?;
    }
  }

  Future<Map<String, dynamic>?> navigateToResultsScreen(BuildContext context, Map<String, dynamic> question, {FeedContext? feedContext, bool fromSearch = false, bool fromUserScreen = false, bool isGuestMode = false}) async {
    try {
      final questionId = question['id'].toString();
      final questionType = question['type'].toString().toLowerCase();

            // Update the vote count before navigating to results
      try {
        final currentVoteCount = await _resultsService.fetchTotalCount(questionId);
        question['votes'] = currentVoteCount;
        print('Updated vote count for results screen - question $questionId: $currentVoteCount responses');
      } catch (e) {
        print('Error fetching vote count for results screen: $e');
        // Continue with existing vote count
      }

      // Preload data for adjacent questions for smoother navigation
      _preloadAdjacentQuestionData(context, question, feedContext, fromSearch, fromUserScreen);

      // Navigate to appropriate results screen based on question type
      switch (questionType) {
        case 'approval_rating':
        case 'approval':
          // Get the server-computed results for approval questions
          QuestionResults approvalResults =
              QuestionResults.emptyFor(questionId, questionType);
          try {
            approvalResults = await _withErrorHandling(
              () => fetchQuestionResults(questionId, questionType: questionType),
              'Error loading results'
            );
          } catch (e) {
            print('Error loading approval results: $e');
          }
          
          if (!context.mounted) return null;
          final result = await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => ApprovalResultsScreen(
                question: question,
                results: approvalResults,
                feedContext: feedContext,
                fromSearch: fromSearch,
                fromUserScreen: fromUserScreen,
                isGuestMode: isGuestMode,
              ),
            ),
          );
          return result as Map<String, dynamic>?;
          
        case 'multiplechoice':
        case 'multiple_choice':
          // For multiple choice questions, ensure options are loaded
          if (!question.containsKey('question_options') || 
              (question['question_options'] as List<dynamic>?)?.isEmpty == true) {
            try {
              // Fetch options from database
              final optionsResponse = await _supabase
                  .from('question_options')
                  .select('id, option_text, sort_order')
                  .eq('question_id', questionId)
                  .order('sort_order');
              
              if (optionsResponse != null && optionsResponse.isNotEmpty) {
                question['question_options'] = optionsResponse;
                print('Loaded ${optionsResponse.length} options for multiple choice question');
              } else {
                print('No options found for multiple choice question $questionId');
                // Provide fallback options
                question['question_options'] = [
                  {'id': '1', 'option_text': 'Option 1', 'sort_order': 0},
                  {'id': '2', 'option_text': 'Option 2', 'sort_order': 1},
                ];
              }
            } catch (e) {
              print('Error fetching question options: $e');
              // Provide fallback options
              question['question_options'] = [
                {'id': '1', 'option_text': 'Option 1', 'sort_order': 0},
                {'id': '2', 'option_text': 'Option 2', 'sort_order': 1},
              ];
            }
          }
          
          // Get the server-computed results for multiple choice questions
          QuestionResults mcResults =
              QuestionResults.emptyFor(questionId, questionType);
          try {
            mcResults = await _withErrorHandling(
              () => fetchQuestionResults(questionId, questionType: questionType),
              'Error loading results'
            );
          } catch (e) {
            print('Error loading multiple choice results: $e');
          }
          
          if (!context.mounted) return null;
          final result = await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => MultipleChoiceResultsScreen(
                question: question,
                results: mcResults,
                feedContext: feedContext,
                fromSearch: fromSearch,
                fromUserScreen: fromUserScreen,
                isGuestMode: isGuestMode,
              ),
            ),
          );
          return result as Map<String, dynamic>?;
          
        case 'text':
          // Discussion questions: navigate to the discussion screen (AnswerTextScreen)
          if (!context.mounted) return null;
          final result = await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => AnswerTextScreen(
                question: question,
                feedContext: feedContext,
                fromSearch: fromSearch,
                fromUserScreen: fromUserScreen,
              ),
            ),
          );
          return result as Map<String, dynamic>?;
          
        default:
          throw Exception('Unsupported question type: $questionType');
      }
    } catch (e) {
      print('Error in navigateToResultsScreen: $e');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error opening question results: ${e.toString()}'),
            backgroundColor: Colors.red,
          ),
        );
      }
      return null;
    }
  }

  // Method to get current city using LocationService
  Future<Map<String, dynamic>?> getCurrentCity(BuildContext context) async {
    final locationService = Provider.of<LocationService>(context, listen: false);
    return locationService.getCurrentCity();
  }

  /// Per-country approval summary for the map fallback and the country rows:
  /// `[{country, answer}]` with `answer` the country's average in -1..1.
  ///
  /// Since the answers read lockdown (2026-09-22) this is computed by the
  /// server and arrives as a summary — the client never sees the scores that
  /// went into it. Shape unchanged, so every caller kept working.
  Future<List<Map<String, dynamic>>> getResponsesByCountry(String questionId) async {
    try {
      final results = await _resultsService.fetchResults(questionId);
      final out = <Map<String, dynamic>>[];
      for (final c in results.byCountry) {
        final avg = c.breakdown.average;
        if (avg == null) continue;
        out.add({
          'country': c.country,
          'answer': avg.clamp(-1.0, 1.0),
        });
      }

      // Smart prefetch: while the user reads this question, warm the next one.
      _scheduleSmartPrefetch(questionId);

      return out;
    } catch (e) {
      print('Error fetching responses by country: $e');
      return [];
    }
  }

  /// Per-country multiple-choice summary: `[{country, answer}]` with `answer`
  /// the country's most-chosen option ('TIE' when two share the lead).
  ///
  /// [options] is kept in the signature for the empty-question fallback and so
  /// callers did not have to change; the counts themselves come from the
  /// server's per-country breakdown.
  Future<List<Map<String, dynamic>>> getMultipleChoiceResponsesByCountry(
      String questionId, List<String> options) async {
    try {
      final results = await _resultsService.fetchResults(questionId);
      if (results.byCountry.isEmpty) {
        print('No responses found for question $questionId');
        return [];
      }

      final fallback = options.isNotEmpty ? options[0] : '';
      final out = <Map<String, dynamic>>[];
      for (final c in results.byCountry) {
        final top = c.breakdown.topOption;
        out.add({
          'country': c.country,
          'answer': top == 'TIE' && c.breakdown.optionCounts.isEmpty
              ? fallback
              : top,
        });
      }

      _storeValidResponseCount(questionId, results.answered);
      _scheduleSmartPrefetch(questionId);

      return out;
    } catch (e) {
      print('Error fetching multiple choice responses by country: $e');
      return [];
    }
  }

  /// Everything the results surfaces draw for one question, straight from the
  /// results RPCs. The one door onto answer data that this service still has.
  Future<QuestionResults> fetchQuestionResults(String questionId,
      {String questionType = '', bool forceRefresh = false}) async {
    final results = await _resultsService.fetchResults(questionId,
        questionType: questionType, forceRefresh: forceRefresh);
    if (results.total > 0) {
      _storeValidResponseCount(questionId, results.answered);
    }
    return results;
  }

  // Store valid response count for a question
  final Map<String, int> _validResponseCounts = {};
  
  void _storeValidResponseCount(String questionId, int count) {
    _validResponseCounts[questionId] = count;
    print('Stored valid response count for question $questionId: $count');
  }
  
  // Get the valid response count for a question
  int getValidResponseCount(String questionId) {
    return _validResponseCounts[questionId] ?? 0;
  }

  // Add caching support
  final Map<String, List<Map<String, dynamic>>> _responseCache = {};
  final Map<String, DateTime> _cacheTimestamps = {};
  static const Duration _cacheDuration = Duration(minutes: 5);
  
  // Viewed question response cache for instant re-visits
  final Map<String, List<Map<String, dynamic>>> _viewedQuestionCache = {};
  final Map<String, DateTime> _viewedCacheTimestamps = {};
  static const Duration _viewedCacheDuration = Duration(minutes: 30); // Longer cache for viewed questions

  Future<List<Map<String, dynamic>>> getCachedResponses(String questionId, String type) async {
    final cacheKey = '$questionId-$type';
    final now = DateTime.now();
    
    // First check viewed question cache (longer duration, instant for re-visits)
    if (_viewedQuestionCache.containsKey(cacheKey)) {
      final timestamp = _viewedCacheTimestamps[cacheKey];
      if (timestamp != null && now.difference(timestamp) < _viewedCacheDuration) {
        print('⚡ Using viewed question cache for $questionId ($type)');
        return _viewedQuestionCache[cacheKey]!;
      }
    }
    
    // Check if we have a valid short-term cached response
    if (_responseCache.containsKey(cacheKey)) {
      final timestamp = _cacheTimestamps[cacheKey];
      if (timestamp != null && now.difference(timestamp) < _cacheDuration) {
        return _responseCache[cacheKey]!;
      }
    }

    // If no valid cache, fetch from Supabase
    List<Map<String, dynamic>> responses;
    if (type == 'approval' || type == 'approval_rating') {
      responses = await getResponsesByCountry(questionId);
    } else if (type == 'text') {
      responses = await getTextResponses(questionId);
    } else {
      final question = _questions.firstWhere(
        (q) => q['id'].toString() == questionId,
        orElse: () => <String, dynamic>{}
      );
      
      if (question.isEmpty) {
        return [];
      }
      
      final options = (question['question_options'] as List<dynamic>?)
          ?.map((e) => e['option_text'].toString())
          .toList() ?? [];
      responses = await getMultipleChoiceResponsesByCountry(questionId, options);
    }

    // Cache the response in both caches
    _responseCache[cacheKey] = responses;
    _cacheTimestamps[cacheKey] = now;
    
    return responses;
  }
  
  // Store response data when a question is viewed for instant re-visits
  void _cacheViewedQuestionResponses(String questionId, String type, List<Map<String, dynamic>> responses) {
    final cacheKey = '$questionId-$type';
    _viewedQuestionCache[cacheKey] = responses;
    _viewedCacheTimestamps[cacheKey] = DateTime.now();
    print('💾 Cached responses for viewed question $questionId ($type) - ${responses.length} responses');
  }
  
  /// Public text answers for a question, newest first.
  ///
  /// Text answers are the one thing the lockdown still serves per answer — they
  /// are public content. What they no longer carry is the generation and the
  /// exact time: `created_at` here is the HOUR the answer was given, rounded
  /// down server-side.
  Future<List<Map<String, dynamic>>> getTextResponses(String questionId) async {
    try {
      final page = await _resultsService.fetchTextAnswers(questionId);
      if (page.answers.isEmpty) return [];

      // Smart prefetch: while the user reads this question, warm the next one.
      _scheduleSmartPrefetch(questionId);

      return page.toRows();
    } catch (e) {
      print('Error fetching text responses: $e');
      return [];
    }
  }

  // Preload data for adjacent questions to enable smooth navigation
  void _preloadAdjacentQuestionData(BuildContext context, Map<String, dynamic> currentQuestion, FeedContext? feedContext, bool fromSearch, bool fromUserScreen) {
    // Run preloading in background without blocking current navigation
    Future.microtask(() async {
      try {
        final currentQuestionId = currentQuestion['id'].toString();
        print('🚀 Starting preload for adjacent questions from $currentQuestionId');
        
        // Get next and previous questions using feedContext if available
        List<Map<String, dynamic>?> adjacentQuestions = [];
        
        if (feedContext != null) {
          final userService = Provider.of<UserService>(context, listen: false);
          
          if (fromSearch) {
            // For search context, get adjacent questions from search results
            adjacentQuestions = [
              feedContext.getNextQuestionInSearchFeed(userService),
              feedContext.getPreviousQuestionInSearchFeed(userService),
            ];
          } else {
            // For regular feed, get adjacent questions (includes answered ones for natural navigation)
            adjacentQuestions = [
              feedContext.getNextQuestion(userService),
              feedContext.getPreviousQuestion(userService),
            ];
          }
        }
        
        // Preload response data for each adjacent question
        for (final adjacentQuestion in adjacentQuestions) {
          if (adjacentQuestion != null) {
            final questionId = adjacentQuestion['id'].toString();
            final questionType = adjacentQuestion['type'].toString().toLowerCase();
            
            print('📦 Preloading data for $questionType question $questionId');
            
            // Preload response data based on question type
            switch (questionType) {
              case 'approval_rating':
              case 'approval':
                // Preload approval responses
                getCachedResponses(questionId, questionType).catchError((e) {
                  print('Failed to preload approval responses for $questionId: $e');
                });
                break;
                
              case 'multiple_choice':
              case 'multiplechoice':
                // Ensure options are loaded first, then preload responses
                _preloadMultipleChoiceData(adjacentQuestion);
                break;
                
              case 'text':
                // Preload text responses and set preloaded data on question
                _preloadTextData(adjacentQuestion);
                break;
            }
          }
        }
        
        print('✅ Preloading completed for adjacent questions');
      } catch (e) {
        print('⚠️ Error during preloading: $e');
        // Don't let preloading errors affect the main navigation
      }
    });
  }
  
  // Preload multiple choice question data
  Future<void> _preloadMultipleChoiceData(Map<String, dynamic> question) async {
    try {
      final questionId = question['id'].toString();
      
      // Ensure options are loaded
      if (!question.containsKey('question_options') || 
          (question['question_options'] as List<dynamic>?)?.isEmpty == true) {
        final optionsResponse = await _supabase
            .from('question_options')
            .select('id, option_text, sort_order')
            .eq('question_id', questionId)
            .order('sort_order');
        
        if (optionsResponse != null && optionsResponse.isNotEmpty) {
          question['question_options'] = optionsResponse;
        }
      }
      
            // Warm the results and the map cells for this question.
      _resultsService.fetchResults(questionId).catchError((e) {
        print('Failed to preload multiple choice results for $questionId: $e');
        return QuestionResults.emptyFor(questionId, 'multiple_choice');
      });
    } catch (e) {
      print('Error preloading multiple choice data: $e');
    }
  }
  
  // Preload text question data
  Future<void> _preloadTextData(Map<String, dynamic> question) async {
    try {
      final questionId = question['id'].toString();
      final questionType = 'text';
      
      // Fetch and cache text responses
      final textResponses = await getTextResponses(questionId);
      
      // Store preloaded responses in the question object for immediate use
      question['preloaded_text_responses'] = textResponses;
      
      // Also cache in viewed question cache for instant re-visits
      if (textResponses.isNotEmpty) {
        _cacheViewedQuestionResponses(questionId, questionType, textResponses);
      }
      
      print('📝 Preloaded ${textResponses.length} text responses for question $questionId');
    } catch (e) {
      print('Error preloading text data: $e');
    }
  }
  
  // Smart prefetch: Schedule prefetch of next question while user browses current one
  void _scheduleSmartPrefetch(String currentQuestionId) {
    // Find the next question in the feed
    final currentIndex = _questions.indexWhere((q) => q['id'].toString() == currentQuestionId);
    if (currentIndex == -1 || currentIndex >= _questions.length - 1) {
      // Current question not found or is the last question
      return;
    }
    
    final nextQuestion = _questions[currentIndex + 1];
    print('🔮 Smart prefetch: User viewing $currentQuestionId, scheduling prefetch for next question ${nextQuestion['id']}');
    
    // Prefetch the next question after a short delay (while user is reading current question)
    Future.delayed(Duration(seconds: 1), () {
      if (!_isPrefetching) {
        prefetchResponsesInBackground([nextQuestion]);
      }
    });
  }
  
  // Background method to prefetch and cache responses for better performance
  Future<void> prefetchResponsesInBackground(List<Map<String, dynamic>> questions) async {
    // Throttle prefetch operations to prevent multiple concurrent executions
    final now = DateTime.now();
    
    // Skip if already prefetching
    if (_isPrefetching) {
      print('⏸️ PREFETCH THROTTLED: Already prefetching, skipping request for ${questions.length} questions');
      return;
    }
    
    // Skip if we prefetched too recently (within 10 seconds - increased from 5)
    if (_lastPrefetchTime != null && now.difference(_lastPrefetchTime!) < Duration(seconds: 10)) {
      print('⏸️ PREFETCH THROTTLED: Too recent (${now.difference(_lastPrefetchTime!).inSeconds}s ago), skipping prefetch');
      return;
    }
    
    // Set flag immediately to prevent concurrent execution
    _isPrefetching = true;
    _lastPrefetchTime = now;
    
    // Execute prefetch directly without Future.microtask to prevent scheduling bypasses
    try {
      print('🚀 Starting background prefetch for ${questions.length} questions');
      
      for (final question in questions) {
        final questionId = question['id'].toString();
        final questionType = question['type'].toString().toLowerCase();
        
        // Skip if already cached recently
        final cacheKey = '$questionId-$questionType';
        if (_viewedQuestionCache.containsKey(cacheKey)) {
          final timestamp = _viewedCacheTimestamps[cacheKey];
          if (timestamp != null && DateTime.now().difference(timestamp) < Duration(minutes: 10)) {
            print('💾 Skipping $questionId - already cached recently');
            continue; // Skip, already cached recently (shorter check for prefetch)
          }
        }
        
                // Prefetch results for this question - ALWAYS fresh, never the cache
        try {
          int total = 0;

          switch (questionType) {
            case 'text':
              final responses = await getTextResponses(questionId);
              total = responses.length;
              if (responses.isNotEmpty) {
                _cacheViewedQuestionResponses(questionId, questionType, responses);
              }
              print('📦 Prefetched $total fresh text answers for $questionId');
              break;

            default:
              // Approval and multiple choice draw from the results RPCs, which
              // keep their own short cache — warming it is the whole prefetch.
              final results = await _resultsService.fetchResults(questionId,
                  questionType: questionType, forceRefresh: true);
              _resultsService.fetchMapCells(questionId, forceRefresh: true);
              total = results.total;
              print('📦 Prefetched fresh results ($total answers) for $questionId');
              break;
          }

          // IMPORTANT: Update the question's vote count so the results screen
          // does not read the difference as new activity.
          if (total > 0) {
            final questionIndex = _questions.indexWhere((q) => q['id'].toString() == questionId);
            if (questionIndex != -1) {
              _questions[questionIndex]['votes'] = total;
              print('🔄 Updated vote count for prefetched question $questionId: $total');
            }
          }
          
          
          // Add small delay to avoid overwhelming the database
          await Future.delayed(Duration(milliseconds: 200)); // Increased delay
        } catch (e) {
          print('Error prefetching $questionType question $questionId: $e');
          // Continue with next question
        }
      }
        
      print('✅ Background prefetch completed');
    } catch (e) {
      print('⚠️ Error during background prefetch: $e');
    } finally {
      // Reset prefetching flag
      _isPrefetching = false;
      print('🔓 PREFETCH THROTTLING: Released lock');
    }
  }

  // Add offline support
  final Map<String, Map<String, dynamic>> _questionCache = {};
  final Map<String, DateTime> _questionCacheTimestamps = {};
  static const Duration _questionCacheDuration = Duration(hours: 24);

  Future<void> _cacheQuestions(List<Map<String, dynamic>> questions) async {
    for (var question in questions) {
      _questionCache[question['id']] = question;
      _questionCacheTimestamps[question['id']] = DateTime.now();
    }
  }

  Future<List<Map<String, dynamic>>> getCachedQuestions() async {
    final now = DateTime.now();
    return _questionCache.entries
        .where((entry) => now.difference(_questionCacheTimestamps[entry.key]!) < _questionCacheDuration)
        .map((entry) => entry.value)
        .toList();
  }

  // Enhanced error handling
  Future<T> _withErrorHandling<T>(Future<T> Function() operation, String errorMessage) async {
    try {
      return await operation();
    } catch (e) {
      if (e is PostgrestException) {
        print('Database error: ${e.message}');
        if (e.message.contains('timeout')) {
          throw Exception('Request timed out. Please check your internet connection.');
        } else if (e.message.contains('permission denied')) {
          throw Exception('You do not have permission to access this data.');
        } else {
          throw Exception('Database error: ${e.message}');
        }
      } else if (e is AuthException) {
        print('Authentication error: ${e.message}');
        if (e.message.contains('expired')) {
          throw Exception('Your session has expired. Please log in again.');
        } else {
          throw Exception('Authentication error: ${e.message}');
        }
      } else if (e is SocketException) {
        print('Network error: $e');
        throw Exception('Network error. Please check your internet connection.');
      } else {
        print('$errorMessage: $e');
        throw Exception('$errorMessage: $e');
      }
    }
  }

  // Helper method to check if a string is a valid UUID
  bool _isUuid(String str) {
    return RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
        .hasMatch(str.toLowerCase());
  }
  
  // Helper method to generate a UUID from a string
  String _generateUuidFromString(String str) {
    // This is a simple deterministic UUID generator based on the input string
    // In a real app, you might want to use a more sophisticated method
    final random = Math.Random(str.hashCode);
    return '${_generateRandomHex(random, 8)}-${_generateRandomHex(random, 4)}-${_generateRandomHex(random, 4)}-${_generateRandomHex(random, 4)}-${_generateRandomHex(random, 12)}';
  }
  
  String _generateRandomHex(Math.Random random, int length) {
    final buffer = StringBuffer();
    for (var i = 0; i < length; i++) {
      buffer.write(random.nextInt(16).toRadixString(16));
    }
    return buffer.toString();
  }

  // Flag to track if we're using sample data
  bool _usingSampleData = false;

  // Add method to seed initial questions  
  Future<void> seedInitialQuestions() async {
    // Prevent multiple concurrent seeding operations
    if (_seedingInProgress) {
      print('🔄 Seeding already in progress, skipping duplicate request');
      return;
    }

    // If we already have questions (either real or sample), don't reseed
    if (_questions.isNotEmpty) {
      print('Already have ${_questions.length} questions, skipping seed');
      return;
    }

    // Use request deduplication to prevent multiple concurrent seeding
    const requestKey = 'seed_initial_questions';
    return _deduplicationService.deduplicateRequest(requestKey, () async {
      _seedingInProgress = true;
      
      try {
        print('Checking database for questions...');
      
      // Try to get questions from the database
      try {
        final response = await _supabase
            .from('questions')
            .select('id')
            .limit(1);
        
        if (response != null && response.isNotEmpty) {
          print('Found questions in database, loading them');
          _usingSampleData = false;
          await fetchQuestions();
          return;
        }
        
        print('No questions found in database, creating samples');
      } catch (e) {
        print('Error checking database: $e');
        print('Will use sample data instead');
      }
      
      // We only reach here if we need to create sample data
      _usingSampleData = true;
      
      // Create sample questions
      final sampleQuestions = [
        {
          'id': _generateUuidFromString('sample_approval_1'),
          'prompt': 'Do you think remote work should be the new normal?',
          'description': 'As companies adapt to post-pandemic realities, should remote work become standard?',
          'type': 'approval_rating',
          'votes': 42,
          'created_at': DateTime.now().subtract(Duration(days: 3)).toIso8601String(),
          'nsfw': false,
          'is_hidden': false,
          'country_code': 'US',
          'targeting_type': 'globe',
        },
        {
          'id': _generateUuidFromString('sample_multiple_choice_1'),
          'prompt': 'What social media platform do you use most frequently?',
          'description': 'Choose the platform you spend the most time on.',
          'type': 'multiple_choice',
          'votes': 78,
          'created_at': DateTime.now().subtract(Duration(days: 2)).toIso8601String(),
          'nsfw': false,
          'is_hidden': false,
          'country_code': 'US',
          'targeting_type': 'globe',
          'question_options': [
            {'id': _generateUuidFromString('option_instagram'), 'option_text': 'Instagram', 'sort_order': 0},
            {'id': _generateUuidFromString('option_facebook'), 'option_text': 'Facebook', 'sort_order': 1},
            {'id': _generateUuidFromString('option_tiktok'), 'option_text': 'TikTok', 'sort_order': 2},
            {'id': _generateUuidFromString('option_linkedin'), 'option_text': 'LinkedIn', 'sort_order': 3}
          ]
        },
        {
          'id': _generateUuidFromString('sample_text_1'),
          'prompt': 'What book changed your perspective on life?',
          'description': 'Share the title and how it affected you.',
          'type': 'text',
          'votes': 35,
          'created_at': DateTime.now().subtract(Duration(days: 1)).toIso8601String(),
          'nsfw': false,
          'is_hidden': false,
          'country_code': 'US',
          'targeting_type': 'globe',
        },
        {
          'id': _generateUuidFromString('sample_qotd_today'),
          'prompt': 'What\'s one small habit that has had a big impact on your daily life?',
          'description': 'It could be anything from morning routines to productivity tips!',
          'type': 'text',
          'votes': 125,
          'created_at': DateTime.now().toIso8601String(), // Today's date
          'nsfw': false,
          'is_hidden': false,
          'country_code': 'US',
          'targeting_type': 'globe',
        }
      ];
      
      print('Adding ${sampleQuestions.length} sample questions');
      
      // Add sample questions to local collection
      _questions = [...sampleQuestions];
      
      // Create sample responses for the questions
      final sampleApprovalResponses = [
        {'country': 'US', 'answer': 0.8},
        {'country': 'CA', 'answer': 0.6},
        {'country': 'GB', 'answer': 0.4},
        {'country': 'DE', 'answer': -0.2},
        {'country': 'FR', 'answer': 0.1},
      ];
      
      final sampleMultipleChoiceResponses = [
        {'country': 'US', 'answer': 'Instagram'},
        {'country': 'CA', 'answer': 'Instagram'},
        {'country': 'GB', 'answer': 'Facebook'},
        {'country': 'DE', 'answer': 'TikTok'},
        {'country': 'FR', 'answer': 'Instagram'},
      ];
      
      // Cache the responses
      _responseCache['${sampleQuestions[0]['id']}-approval_rating'] = sampleApprovalResponses;
      _cacheTimestamps['${sampleQuestions[0]['id']}-approval_rating'] = DateTime.now();
      
      _responseCache['${sampleQuestions[1]['id']}-multiple_choice'] = sampleMultipleChoiceResponses;
      _cacheTimestamps['${sampleQuestions[1]['id']}-multiple_choice'] = DateTime.now();
      
      // Try to push sample questions to Supabase database. Debug builds only:
      // a release build must never write placeholder content into a real
      // backend just because a fetch failed or came back empty.
      if (kDebugMode) try {
        print('Attempting to seed sample questions to database...');
        
        for (var question in sampleQuestions) {
          // Create a copy of the question without the question_options field
          final questionToInsert = Map<String, dynamic>.from(question);
          
          // Remove question_options as we'll insert these separately
          final questionOptions = questionToInsert.remove('question_options');
          
          // Remove votes field as it doesn't exist in the database schema
          questionToInsert.remove('votes');
          
          try {
            // Insert question to Supabase
            final response = await _supabase
                .from('questions')
                .insert(questionToInsert)
                .select('id');
                
            print('Inserted question: ${response != null ? 'success' : 'failed'}');
            
            // If question is multiple choice, insert its options
            if (questionOptions != null && response != null) {
              final questionId = response[0]['id'];
              
              for (var option in questionOptions) {
                try {
                  // Make sure we have a question_id reference
                  option['question_id'] = questionId;
                  
                  await _supabase
                      .from('question_options')
                      .insert(option);
                } catch (optionError) {
                  print('Error inserting option: $optionError');
                  // Continue with other options
                }
              }
              print('Inserted question options for question $questionId');
            }
          } catch (questionError) {
            print('Error inserting question: $questionError');
            // Continue with other questions
          }
        }
        
        // Seeds sample responses for each question
        for (var i = 0; i < sampleQuestions.length; i++) {
          final questionId = sampleQuestions[i]['id'];
          final questionType = sampleQuestions[i]['type'];
          
          // Choose appropriate response data based on question type
          List<Map<String, dynamic>> responseData = [];
          if (questionType == 'approval_rating') {
            responseData = sampleApprovalResponses;
          } else if (questionType == 'multiple_choice') {
            responseData = sampleMultipleChoiceResponses;
          }
          
          // Skip if no responses for this type
          if (responseData.isEmpty) continue;
          
          // Generate 20 responses per question (4 per country)
          final countries = ['US', 'CA', 'GB', 'DE', 'FR'];
          final random = Math.Random();
          
          for (var country in countries) {
            // Generate 4 responses per country
            for (var j = 0; j < 4; j++) {
              try {
                // Create response object with question_id and country_code
                final responseToInsert = {
                  'question_id': questionId,
                  'country_code': country,
                };
                
                // Add score for approval questions
                if (questionType == 'approval_rating') {
                  // Generate a random score between -100 and 100
                  final baseScore = responseData.firstWhere((r) => r['country'] == country)['answer'] as double;
                  final randomOffset = (random.nextDouble() * 40 - 20) / 100; // Random -0.2 to +0.2
                  final adjustedScore = (baseScore + randomOffset).clamp(-1.0, 1.0);
                  // Convert -1.0 to 1.0 scale to -100 to 100 for storage
                  responseToInsert['score'] = (adjustedScore * 100).toInt();
                }
                
                // Add option_id for multiple choice questions
                if (questionType == 'multiple_choice') {
                  // Look up option_id by option_text
                  final options = sampleQuestions[i]['question_options'] as List?;
                  if (options != null) {
                    final countryPref = responseData.firstWhere(
                      (r) => r['country'] == country,
                      orElse: () => <String, dynamic>{'answer': 'Instagram'} // Default to Instagram
                    );
                    
                    final optionText = countryPref['answer'].toString();
                    final option = options.firstWhere(
                      (o) => o['option_text'] == optionText, 
                      orElse: () => options[random.nextInt(options.length)] // Random fallback
                    );
                    
                    if (option != null && option.isNotEmpty) {
                      responseToInsert['option_id'] = option['id'];
                    }
                  }
                }
                
                await _supabase
                    .from('responses')
                    .insert(responseToInsert);
              } catch (e) {
                print('Error inserting response: $e');
                // Continue with other responses
              }
            }
          }
          
          print('Inserted responses for question $questionId');
        }
        
        print('Successfully seeded database with sample questions and responses');
        _usingSampleData = false;
        await fetchQuestions();  // Refresh questions from database
      } catch (e) {
        print('Error seeding questions to database: $e');
        print('Continuing with local sample data only');
      }
      
      print('Sample data creation complete');
      
        // Notify listeners to update UI
        notifyListeners();
        
      } catch (e) {
        print('Error in seeding process: $e');
        // If seeding fails, make sure we have at least an empty list
        if (_questions.isEmpty) {
          _questions = [];
        }
      } finally {
        // Reset seeding flag
        _seedingInProgress = false;
      }
    });
  }

  // Update vote count for a specific question
  Future<void> updateQuestionVoteCount(String questionId) async {
    try {
      // Find the question in our local collection
      final questionIndex = _questions.indexWhere((q) => q['id'].toString() == questionId);
      if (questionIndex == -1) {
        print('Question not found in local collection: $questionId');
        return;
      }
      
      // Initialize votes if not present (for UI)
      if (_questions[questionIndex]['votes'] == null) {
        _questions[questionIndex]['votes'] = 1;
      } else {
        _questions[questionIndex]['votes'] = (_questions[questionIndex]['votes'] as int) + 1;
      }
      
      // No need to update database - responses are already counted in fetchQuestions
      print('Incrementing vote count locally. Response already recorded in database.');
      
      // Notify listeners to update UI
      notifyListeners();
    } catch (e) {
      print('Error in updateQuestionVoteCount: $e');
    }
  }

  // Record a user's response to prevent duplicate voting
  Future<void> recordUserResponse(String questionId, {UserService? userService, BuildContext? context}) async {
    // Skip recording if userService is not provided
    if (userService == null) {
      print('UserService not provided, skipping recordUserResponse');
      return;
    }
    
    // Find the question in the questions list
    final question = _questions.firstWhere(
      (q) => q['id'].toString() == questionId, 
      orElse: () => <String, dynamic>{
        'prompt': 'Unknown question',
        'type': 'unknown'
      }
    );
    
    // Explicitly create a new Map<String, dynamic> for the answered question
    final answeredQuestion = <String, dynamic>{
      'id': questionId,
      'prompt': question['prompt']?.toString() ?? 'Unknown question',
      'type': question['type']?.toString() ?? 'unknown',
      'timestamp': DateTime.now().toIso8601String()
    };
    
    // Record locally for immediate UI updates and persistence
    await userService.addAnsweredQuestion(answeredQuestion, context: context);
    print('Recorded answered question locally for question $questionId');
  }

  // ---------------------------------------------------------------------------
  // The write path: submit_response()
  // ---------------------------------------------------------------------------
  //
  // All three submit methods below go through `rpc('submit_response', …)`,
  // which writes `responses` and `response_owners` in one transaction. Three
  // things the direct INSERT could never do, and now does not have to:
  //
  //   * `is_authenticated` is stamped server-side instead of being a
  //     client-supplied literal.
  //   * The option is validated against ITS OWN question — `responses.option_id`
  //     has an FK to `question_options(id)` and nothing more.
  //   * The answer path is rate limited, for the first time.
  //
  // The reply carries `vote_count`, so the follow-up `getAccurateVoteCount`
  // round trip every path used to make is gone.
  //
  // GUESTS never reach it: the RPC is granted to `authenticated` only, and all
  // three methods already refuse without a session before they get here. The
  // onboarding answer is not a guest answer — `PendingAnswerService` replays it
  // once a session exists, so it arrives through this same path and IS linked
  // (owner decision D-3).
  //
  // Contract: scripts/response_linkage_03_submit_response.sql

  /// What `submit_response` said, or [notDeployed] when it is not there yet.
  static const int _submitRpcNotDeployed = -1;

  /// Calls `submit_response`. Returns the question's new vote count on success,
  /// [_submitRpcNotDeployed] when PostgREST says there is no such function (the
  /// caller then falls back to the direct insert), or null on any other failure
  /// — which is a real submit failure and must not be retried as an insert, or
  /// a rate-limited user would silently get their row in anyway.
  Future<int?> _submitResponseViaRpc({
    required String questionId,
    required String cityId,
    required String countryCode,
    String? optionId,
    int? score,
    String? textResponse,
    String? generation,
    required bool sharedWithCloseFriends,
  }) async {
    try {
      final raw = await _supabase.rpc('submit_response', params: {
        'p_question_id': questionId,
        'p_city_id': cityId,
        'p_country_code': countryCode,
        'p_option_id': optionId,
        'p_score': score,
        'p_text_response': textResponse,
        'p_generation': generation,
        'p_shared_with_close_friends': sharedWithCloseFriends,
      });
      if (raw is! Map) {
        print('ERROR: submit_response returned ${raw.runtimeType}, not an object');
        AnalyticsService()
            .trackRpcFailed('submit_response', reason: 'bad_shape');
        return null;
      }
      if (raw['success'] != true) {
        // Every refusal is a named error code, not an exception:
        // not_authenticated, rate_limited, question_not_found, question_hidden,
        // invalid_city, invalid_answer, invalid_option.
        print('ERROR: submit_response refused the answer: ${raw['error']}');
        // The server's own closed vocabulary — a code, never a free-text
        // message. This is the only place a refusal survives: the callers just
        // return false (review 2026-09-22 B7).
        final code = raw['error'];
        AnalyticsService().trackRpcFailed('submit_response',
            reason: code is String && code.isNotEmpty ? code : 'refused');
        return null;
      }
      final count = raw['vote_count'];
      return count is num ? count.toInt() : 0;
    } catch (e) {
      if (isMissingRpc(e)) {
        // The backend predates `submit_response`. Fall back to the older
        // insert, so answering still works;
        // the row is simply never linked, and the network surface stays dark.
        print('DEBUG: submit_response is not deployed — falling back to the '
            'direct responses insert.');
        // The single question the linkage rollout hangs on: what fraction of
        // answers are linked versus falling through to the unlinked legacy
        // insert. Once per session — the fact is about the server, not the
        // answer count.
        AnalyticsService().trackSubmitResponseFallbackUsed('not_deployed');
        return _submitRpcNotDeployed;
      }
      print('ERROR: submit_response failed: $e');
      AnalyticsService()
          .trackRpcFailed('submit_response', reason: analyticsRpcReason(e));
      return null;
    }
  }

  // Submit a multiple choice response to the database
  /// [sharedWithCloseFriends] is the per-answer close-friend flag chosen on the
  /// answer form (owner decision 2026-09-17). It rides with the answer to
  /// `submit_response`, which records it on the LINK row — an unlinked row has
  /// no author to share on behalf of. Unlike the 2026-09-17 shape it is no
  /// longer frozen: `NetworkService.setAnswerSharing` can flip it afterwards
  /// (owner decision D-5).
  Future<bool> submitMultipleChoiceResponse(String questionId, String selectedOption, String countryCode, {LocationService? locationService, bool sharedWithCloseFriends = true}) async {
    try {
      print('DEBUG: Submitting MC response - questionId: $questionId, selectedOption: $selectedOption, countryCode: $countryCode');
      
      // First try to find the question in the main questions list
      Map<String, dynamic> question = _questions.firstWhere(
        (q) => q['id'].toString() == questionId,
        orElse: () => <String, dynamic>{}
      );
      
      // If not found in main list, fetch from database (for deep links, search results, etc.)
      if (question.isEmpty) {
        print('DEBUG: Question not found in main feed, fetching from database for ID: $questionId');
        try {
          final fetchedQuestion = await getQuestionById(questionId);
          if (fetchedQuestion == null || fetchedQuestion.isEmpty) {
            print('ERROR: Question not found in database for ID: $questionId');
            return false;
          }
          question = fetchedQuestion;
          // print('DEBUG: Successfully fetched question from database');  // Commented out excessive logging
        } catch (e) {
          print('ERROR: Failed to fetch question from database: $e');
          return false;
        }
      }
      
      print('DEBUG: Found question: ${question['prompt']}');
      
      // Find the option ID
      String? optionId;
      final options = question['question_options'] as List<dynamic>?;
      
      print('DEBUG: Question options: $options');
      
      if (options != null) {
        print('DEBUG: Looking for option with text: "$selectedOption"');
        print('DEBUG: Available option texts: ${options.map((o) => '"${o['option_text']}"').toList()}');
        
        final option = options.firstWhere(
          (o) => o['option_text'].toString() == selectedOption,
          orElse: () => <String, dynamic>{}
        );
        
        print('DEBUG: Found option: $option');
        optionId = option['id']?.toString();
        print('DEBUG: Option ID: $optionId');
      } else {
        print('ERROR: No options found in question');
      }
      
      if (optionId == null) {
        print('ERROR: Option ID not found for selected option: $selectedOption');
        print('DEBUG: This will cause the response submission to fail');
        return false;
      }
      
      // Get the city_id from location service
      final cityId = locationService?.selectedCity?['id'];
      
      if (cityId == null) {
        print('ERROR: User must select their actual city to submit responses');
        print('DEBUG: Available location data: selectedCity=${locationService?.selectedCity}, selectedCountry=${locationService?.selectedCountry}');
        return false;
      }
      
      // Get country_code from city data (preferred) or fallback to provided countryCode
      final resolvedCountryCode = locationService?.selectedCity?['country_code']?.toString() ?? countryCode;
      
      print('DEBUG: Using country_code: $resolvedCountryCode (from city: ${locationService?.selectedCity?['country_code']}, fallback: $countryCode)');
      
      // Get user's generation preference
      final prefs = await SharedPreferences.getInstance();
      final userGeneration = prefs.getString('user_generation');
      final generationValue = (userGeneration != null && userGeneration != 'opt_out') ? userGeneration : null;

      // Create the response object
      final responseData = {
        'question_id': questionId,
        'option_id': optionId,
        'city_id': cityId,
        'country_code': resolvedCountryCode,
        'is_authenticated': true,
        'generation': generationValue,
        // Per-answer close-friend visibility, frozen onto the row.
        'shared_with_close_friends': sharedWithCloseFriends,
      };

      // Insert into Supabase
      print('DEBUG: Submitting multiple choice response to database: $responseData');
      
      // Check if user is authenticated first
      final user = _supabase.auth.currentUser;
      if (user == null) {
        print('ERROR: User not authenticated - cannot submit response');
        return false;
      }
      
      print('DEBUG: User authenticated: ${user.id}');
      
      // Check if this is the user trying to answer their own question
      final isOwnQuestion = question['author_id']?.toString() == user.id || 
                           question['user_id']?.toString() == user.id;
      
      if (isOwnQuestion) {
        print('DEBUG: User is attempting to answer their own question');
        print('DEBUG: This might be blocked by RLS policy - checking if this is allowed...');
      }
      
      // The linked write path. Everything below it is the pre-linkage insert,
      // kept only for a backend that predates `submit_response`.
      int? rpcVoteCount;
      final rpcResult = await _submitResponseViaRpc(
        questionId: questionId,
        cityId: cityId.toString(),
        countryCode: resolvedCountryCode,
        optionId: optionId,
        generation: generationValue,
        sharedWithCloseFriends: sharedWithCloseFriends,
      );
      if (rpcResult != null && rpcResult != _submitRpcNotDeployed) {
        rpcVoteCount = rpcResult;
      } else if (rpcResult == null) {
        // A real refusal (rate limit, hidden question, a bad option). Inserting
        // anyway would route around the server's own answer.
        return false;
      }

      bool responseInserted = rpcVoteCount != null;

      if (!responseInserted) {
        // Insert response directly without user_id (responses table is designed for anonymity)
        print('DEBUG: Inserting response into database: $responseData');

        try {
          // First, let's verify the question exists and is accessible
          print('DEBUG: Verifying question access before inserting response...');
          final questionCheck = await _supabase
              .from('questions')
              .select('id, prompt, is_hidden, author_id')
              .eq('id', questionId)
              .maybeSingle();
        
          if (questionCheck == null) {
            print('ERROR: Question $questionId not found or not accessible');
            throw Exception('Question not found or not accessible');
          }
        
          print('DEBUG: Question verified: ${questionCheck['prompt']} (hidden: ${questionCheck['is_hidden']}, author: ${questionCheck['author_id']})');
        
          if (questionCheck['is_hidden'] == true) {
            print('ERROR: Cannot submit response to hidden question');
            throw Exception('Cannot submit response to hidden question');
          }
        
          // Now try to insert the response
          print('DEBUG: Inserting response into responses table...');
          print('DEBUG: Final response data: $responseData');
        
          await _supabase
              .from('responses')
              .insert(responseData);

          print('SUCCESS: Response inserted into database');
          responseInserted = true;

          // Check if the trigger updated the question (this might fail due to RLS)
          try {
            print('DEBUG: Checking if trigger updated the question...');
            final updatedQuestion = await _supabase
                .from('questions')
                .select('id, is_hidden, updated_at')
                .eq('id', questionId)
                .single();
          
            print('DEBUG: Question after response insertion: hidden=${updatedQuestion['is_hidden']}, updated_at=${updatedQuestion['updated_at']}');
          } catch (triggerError) {
            print('WARNING: Could not verify trigger update: $triggerError');
            print('WARNING: This might indicate the trigger failed due to RLS policy');
          }
        } catch (insertionError) {
          print('ERROR: Database insertion failed: $insertionError');
        
          // Check if this is a self-answer RLS policy issue
          if (isOwnQuestion && insertionError.toString().contains('row-level security')) {
            print('ERROR: RLS policy is blocking self-answers');
            print('ERROR: User cannot answer their own question due to database policy');
            print('ERROR: Question ID: $questionId');
            print('ERROR: User ID: ${user.id}');
            print('ERROR: Question author ID: ${question['author_id']}');
            print('ERROR: Full error details: $insertionError');
            print('ERROR: Error type: ${insertionError.runtimeType}');
          
            // Log the specific RLS policy error details
            if (insertionError is PostgrestException) {
              print('ERROR: PostgrestException details:');
              print('ERROR: - Message: ${insertionError.message}');
              print('ERROR: - Code: ${insertionError.code}');
              print('ERROR: - Details: ${insertionError.details}');
              print('ERROR: - Hint: ${insertionError.hint}');
            }
          
            throw Exception('You cannot answer your own question. This is blocked by the database security policy.');
          }
        
          // Try one more approach - check if we can read from responses table at all
          try {
            print('DEBUG: Testing if we can read from responses table...');
                      final probe = await _resultsService.fetchTotalCount(questionId);
            print('DEBUG: results RPC reachable, question has $probe answers');
          } catch (readError) {
            print('ERROR: results RPC unreachable: $readError');
          }
        
          rethrow;
        }
      }

      // Only proceed if response was actually inserted
      if (!responseInserted) {
        throw Exception('Failed to insert response into database');
      }

      // The results screen's un-share toggle opens in the state chosen here.
      await _networkService
          .rememberSubmittedSharing(questionId, sharedWithCloseFriends);

      // Also increment the option count (this is needed for the UI to reflect changes immediately)
      await incrementOptionCount(questionId, optionId);

      // Update the vote count immediately after successful submission
      try {
        print('DEBUG: Updating vote count after successful response submission...');
        // submit_response counted the rows inside its own transaction; only the
        // fallback insert has to go and ask.
        final updatedVoteCount = rpcVoteCount ??
            await getAccurateVoteCount(questionId, question['type']?.toString());

        // Update the question in local collection
        final questionIndex = _questions.indexWhere((q) => q['id'].toString() == questionId);
        if (questionIndex != -1) {
          _questions[questionIndex]['votes'] = updatedVoteCount;
          print('DEBUG: Updated local vote count for question $questionId: $updatedVoteCount');
        }
        
        // Also update the question object passed to this method for immediate UI update
        question['votes'] = updatedVoteCount;
        
        // Clear any cached vote counts to force fresh data
        _validResponseCounts[questionId] = updatedVoteCount;
        
        notifyListeners();
      } catch (e) {
        print('WARNING: Could not update vote count after submission: $e');
        // Continue anyway since the response was successfully submitted
      }
      
      print('SUCCESS: Multiple choice response submitted successfully');
      
      // Notify listeners that an answer was submitted for immediate vote count update
      VoteCountUpdateEvent.notifyAnswerSubmitted(questionId);
      
      return true;
    } catch (e) {
      print('ERROR: Error submitting multiple choice response: $e');
      print('ERROR: Failed to submit response to database');
      
      // DON'T increment local count if database submission failed
      // This prevents the question from being marked as "answered" when it actually wasn't
      print('WARNING: Response not saved to database, not updating local count to allow retry');
      return false; // Return false so the question isn't marked as answered
    }
  }
  
  // Increment the count for a specific option
  Future<bool> incrementOptionCount(String questionId, String optionId) async {
    try {
      // First, find the question and option in our local data
      final questionIndex = _questions.indexWhere((q) => q['id'].toString() == questionId);
      if (questionIndex == -1) {
        print('Question not found for incrementing option count');
        return false;
      }
      
      final options = _questions[questionIndex]['question_options'] as List<dynamic>?;
      if (options == null) {
        print('No options found for question');
        return false;
      }
      
      // Find the option
      int optionIndex = -1;
      for (var i = 0; i < options.length; i++) {
        if (options[i]['id'].toString() == optionId) {
          optionIndex = i;
          break;
        }
      }
      
      if (optionIndex == -1) {
        print('Option not found in question');
        return false;
      }
      
      // Initialize the option_count if not present
      if (options[optionIndex]['option_count'] == null) {
        options[optionIndex]['option_count'] = 0;
      }
      
      // Increment the count
      options[optionIndex]['option_count'] = (options[optionIndex]['option_count'] as int? ?? 0) + 1;
      
      // Since option_count column doesn't exist in the database, we'll just use local count
      print('Updated option count locally: ${options[optionIndex]['option_count']}');
      
      notifyListeners();
      return true;
    } catch (e) {
      print('Error incrementing option count: $e');
      return false;
    }
  }
  
  // Submit an approval response to the database
  /// [sharedWithCloseFriends] is the per-answer close-friend flag chosen on the
  /// answer form (owner decision 2026-09-17). It is written onto the row and
  /// frozen there; `false` means this one answer is never surfaced to a close
  /// friend. Requires `responses.shared_with_close_friends`
  /// (`scripts/per_answer_share_flag.sql`).
  Future<bool> submitApprovalResponse(String questionId, double score, String countryCode, {LocationService? locationService, bool sharedWithCloseFriends = true}) async {
    try {
      // Check if user is authenticated first
      final user = _supabase.auth.currentUser;
      if (user == null) {
        print('ERROR: User not authenticated - cannot submit approval response');
        return false;
      }
      
      // Convert score from -1.0 to 1.0 range to -100 to 100 integer
      final scoreInt = (score * 100).toInt();
      
      // Get the city_id from location service
      final cityId = locationService?.selectedCity?['id'];
      
      if (cityId == null) {
        print('ERROR: User must select their actual city to submit responses');
        print('DEBUG: Available location data: selectedCity=${locationService?.selectedCity}, selectedCountry=${locationService?.selectedCountry}');
        return false;
      }
      
      // Get country_code from city data (preferred) or fallback to provided countryCode
      final resolvedCountryCode = locationService?.selectedCity?['country_code']?.toString() ?? countryCode;
      
      print('DEBUG: Using country_code: $resolvedCountryCode (from city: ${locationService?.selectedCity?['country_code']}, fallback: $countryCode)');
      
      // Get user's generation preference
      final prefs = await SharedPreferences.getInstance();
      final userGeneration = prefs.getString('user_generation');
      final generationValue = (userGeneration != null && userGeneration != 'opt_out') ? userGeneration : null;

      // Create the response object
      final responseData = {
        'question_id': questionId,
        'score': scoreInt,
        'city_id': cityId,
        'country_code': resolvedCountryCode,
        'is_authenticated': true,
        'generation': generationValue,
        // Per-answer close-friend visibility, frozen onto the row.
        'shared_with_close_friends': sharedWithCloseFriends,
      };

      // The linked write path; the insert below is the pre-linkage fallback.
      int? rpcVoteCount;
      final rpcResult = await _submitResponseViaRpc(
        questionId: questionId,
        cityId: cityId.toString(),
        countryCode: resolvedCountryCode,
        score: scoreInt,
        generation: generationValue,
        sharedWithCloseFriends: sharedWithCloseFriends,
      );
      if (rpcResult == null) return false;
      if (rpcResult != _submitRpcNotDeployed) {
        rpcVoteCount = rpcResult;
        print('SUCCESS: Approval response linked');
      } else {
        // Insert response directly without user_id (responses table has no user_id for anonymity)
        print('Submitting approval response: $responseData');
        await _supabase
            .from('responses')
            .insert(responseData);

        print('SUCCESS: Approval response inserted');
      }

      await _networkService
          .rememberSubmittedSharing(questionId, sharedWithCloseFriends);

      // Update the average score for this question
      await updateQuestionAverageScore(questionId);

      // Update the vote count immediately after successful submission
      try {
        print('DEBUG: Updating vote count after successful approval response submission...');
        final updatedVoteCount =
            rpcVoteCount ?? await getAccurateVoteCount(questionId, 'approval_rating');
        
        // Update the question in local collection
        final questionIndex = _questions.indexWhere((q) => q['id'].toString() == questionId);
        if (questionIndex != -1) {
          _questions[questionIndex]['votes'] = updatedVoteCount;
          print('DEBUG: Updated local vote count for approval question $questionId: $updatedVoteCount');
        }
        
        // Clear any cached vote counts to force fresh data
        _validResponseCounts[questionId] = updatedVoteCount;
        
        notifyListeners();
      } catch (e) {
        print('WARNING: Could not update vote count after approval submission: $e');
        // Continue anyway since the response was successfully submitted
      }
      
      print('Approval response submitted successfully');
      
      // Notify listeners that an answer was submitted for immediate vote count update
      VoteCountUpdateEvent.notifyAnswerSubmitted(questionId);
      
      return true;
    } catch (e) {
      print('Error submitting approval response: $e');
      return false;
    }
  }
  
  // Update the average score for an approval question
  Future<bool> updateQuestionAverageScore(String questionId) async {
    try {
      // Find the question in our local collection
      final questionIndex = _questions.indexWhere((q) => q['id'].toString() == questionId);
      if (questionIndex == -1) {
        print('Question not found for updating average score');
        return false;
      }
      
            // Ask the server for the average — the client never sees the scores.
      final results = await _resultsService
          .fetchResults(questionId, forceRefresh: true);
      final normalized = results.overall.average;

      if (normalized == null) {
        print('No scored responses found for question');
        return false;
      }

      // The RPC normalises to -1..1; `average_score` is stored in -100..100.
      final avgScore = normalized * 100.0;
      
      // Store the average score in the question
      _questions[questionIndex]['average_score'] = avgScore;
      
      // Try to update in the database
      try {
        await _supabase
            .from('questions')
            .update({'average_score': avgScore})
            .eq('id', questionId);
            
        print('Updated question average score in database: $avgScore');
      } catch (e) {
        print('Error updating question average score in database: $e');
        // Continue anyway since we've updated the local data
      }
      
      notifyListeners();
      return true;
    } catch (e) {
      print('Error updating question average score: $e');
      return false;
    }
  }
  
  // Submit a text response to the database
  /// [sharedWithCloseFriends] is the per-answer close-friend flag chosen on the
  /// answer form (owner decision 2026-09-17). It is written onto the row and
  /// frozen there; `false` means this one answer is never surfaced to a close
  /// friend. Requires `responses.shared_with_close_friends`
  /// (`scripts/per_answer_share_flag.sql`).
  Future<bool> submitTextResponse(String questionId, String responseText, String countryCode, {LocationService? locationService, bool sharedWithCloseFriends = true}) async {
    try {
      // Check if user is authenticated first
      final user = _supabase.auth.currentUser;
      if (user == null) {
        print('ERROR: User not authenticated - cannot submit text response');
        return false;
      }
      
      // Get the city_id from location service
      final cityId = locationService?.selectedCity?['id'];
      
      if (cityId == null) {
        print('ERROR: User must select their actual city to submit responses');
        print('DEBUG: Available location data: selectedCity=${locationService?.selectedCity}, selectedCountry=${locationService?.selectedCountry}');
        return false;
      }
      
      // Get country_code from city data (preferred) or fallback to provided countryCode
      final resolvedCountryCode = locationService?.selectedCity?['country_code']?.toString() ?? countryCode;
      
      print('DEBUG: Using country_code: $resolvedCountryCode (from city: ${locationService?.selectedCity?['country_code']}, fallback: $countryCode)');
      
      // Get user's generation preference
      final prefs = await SharedPreferences.getInstance();
      final userGeneration = prefs.getString('user_generation');
      final generationValue = (userGeneration != null && userGeneration != 'opt_out') ? userGeneration : null;

      // Create the response object
      final responseData = {
        'question_id': questionId,
        'text_response': responseText,
        'city_id': cityId,
        'country_code': resolvedCountryCode,
        'is_authenticated': true,
        'generation': generationValue,
        // Per-answer close-friend visibility, frozen onto the row.
        'shared_with_close_friends': sharedWithCloseFriends,
      };

      // The linked write path; the insert below is the pre-linkage fallback.
      int? rpcVoteCount;
      final rpcResult = await _submitResponseViaRpc(
        questionId: questionId,
        cityId: cityId.toString(),
        countryCode: resolvedCountryCode,
        textResponse: responseText,
        generation: generationValue,
        sharedWithCloseFriends: sharedWithCloseFriends,
      );
      if (rpcResult == null) return false;
      if (rpcResult != _submitRpcNotDeployed) {
        rpcVoteCount = rpcResult;
        print('SUCCESS: Text response linked');
      } else {
        // Insert response directly without user_id (responses table has no user_id for anonymity)
        print('Submitting text response: $responseData');
        await _supabase
            .from('responses')
            .insert(responseData);

        print('SUCCESS: Text response inserted');
      }

      await _networkService
          .rememberSubmittedSharing(questionId, sharedWithCloseFriends);

      // Update response counts for this question
      updateTextResponseCount(questionId);

      // Update the vote count immediately after successful submission
      try {
        print('DEBUG: Updating vote count after successful text response submission...');
        final updatedVoteCount =
            rpcVoteCount ?? await getAccurateVoteCount(questionId, 'text');
        
        // Update the question in local collection
        final questionIndex = _questions.indexWhere((q) => q['id'].toString() == questionId);
        if (questionIndex != -1) {
          _questions[questionIndex]['votes'] = updatedVoteCount;
          print('DEBUG: Updated local vote count for text question $questionId: $updatedVoteCount');
        }
        
        // Clear any cached vote counts to force fresh data
        _validResponseCounts[questionId] = updatedVoteCount;
        
        notifyListeners();
      } catch (e) {
        print('WARNING: Could not update vote count after text submission: $e');
        // Continue anyway since the response was successfully submitted
      }
      
      print('Text response submitted successfully');
      
      // Notify listeners that an answer was submitted for immediate vote count update
      VoteCountUpdateEvent.notifyAnswerSubmitted(questionId);
      
      return true;
    } catch (e) {
      print('Error submitting text response: $e');
      return false;
    }
  }
  
  // Update the count of text responses
  Future<bool> updateTextResponseCount(String questionId) async {
    try {
      // Find the question in our local collection
      final questionIndex = _questions.indexWhere((q) => q['id'].toString() == questionId);
      if (questionIndex == -1) {
        print('Question not found for updating text response count');
        return false;
      }
      
            // Get count of responses for this question
      final count = await _resultsService.fetchTextCount(questionId);
      
      // Update the question with the count (local data only)
      _questions[questionIndex]['response_count'] = count;
      
      print('Updated question text response count locally: $count');
      
      // Note: Database doesn't have response_count column, so we only update locally
      // The count will be recalculated when questions are fetched from the database
      
      notifyListeners();
      return true;
    } catch (e) {
      print('Error updating text response count: $e');
      return false;
    }
  }

  Future<List<Map<String, dynamic>>> getQuestions() async {
    try {
      final response = await _supabase
          .from('questions')
          .select()
          .eq('is_hidden', false)
          .order('created_at', ascending: false);

      if (response == null) return [];

      // Get user's location
      final locationService = LocationService();
      final userCountry = locationService.userLocation?['country_name_en'];

      // Sort questions to boost those mentioning user's country
      final questions = List<Map<String, dynamic>>.from(response);
      questions.sort((a, b) {
        // Check if questions mention user's country
        final aMentions = (a['mentioned_countries'] as List?)?.contains(userCountry) ?? false;
        final bMentions = (b['mentioned_countries'] as List?)?.contains(userCountry) ?? false;

        if (aMentions && !bMentions) return -1;
        if (!aMentions && bMentions) return 1;

        // If both mention or neither mentions, sort by votes and timestamp
        final aVotes = a['votes'] ?? 0;
        final bVotes = b['votes'] ?? 0;
        if (aVotes != bVotes) return bVotes.compareTo(aVotes);

        final aTime = DateTime.parse(a['created_at'] ?? a['timestamp'] ?? DateTime.now().toIso8601String());
        final bTime = DateTime.parse(b['created_at'] ?? b['timestamp'] ?? DateTime.now().toIso8601String());
        return bTime.compareTo(aTime);
      });

      return questions;
    } catch (e) {
      print('Error fetching questions: $e');
      return [];
    }
  }

  // Submit a new question to the database
  Future<Map<String, dynamic>?> submitQuestion({
    required String title,
    String? description,
    required String type,
    List<String>? options,
    required String countryCode,
    List<String>? categories,
    bool isNSFW = false,
    List<String>? mentionedCountries,
    String targeting = 'globe', // globe, country, city
    String? cityId,
    bool isPrivate = false,
    // Approval-question end labels (WP-B). Persisted as two question_options
    // rows: sort_order 0 = low/disapprove end, 1 = high/approve end. Null or
    // blank falls back to the defaults (see utils/approval_labels.dart).
    String? approvalLowLabel,
    String? approvalHighLabel,
  }) async {
    try {
      // Get current authenticated user
      final currentUser = _supabase.auth.currentUser;
      if (currentUser == null) {
        throw Exception('User must be authenticated to submit questions');
      }

      // Prepare question data (only include fields that exist in the database)
      final questionData = {
        'prompt': title,
        'description': description,
        'type': type,
        'country_code': countryCode,
        'nsfw': isNSFW,
        'is_hidden': false,
        'is_private': isPrivate,
        'author_id': currentUser.id,
        'targeting_type': targeting,
      };

      // Add city_id only if targeting is 'city' and cityId is provided
      if (targeting == 'city' && cityId != null) {
        questionData['city_id'] = cityId;
      }

      print('Submitting question to database: $questionData');

      // Insert question into Supabase
      final response = await _supabase
          .from('questions')
          .insert(questionData)
          .select('*')
          .single();

      if (response == null) {
        throw Exception('Failed to insert question - no response received');
      }

      final questionId = response['id'];
      print('Question inserted successfully with ID: $questionId');

      // If it's a multiple choice question, insert the options
      if (type == 'multiple_choice' && options != null && options.isNotEmpty) {
        final optionInserts = options.asMap().entries.map((entry) => {
          'question_id': questionId,
          'option_text': entry.value,
          'sort_order': entry.key,
        }).toList();

        // Insert options and get back the actual UUIDs
        final insertedOptions = await _supabase
            .from('question_options')
            .insert(optionInserts)
            .select('id, option_text, sort_order, question_id');

        print('Inserted ${options.length} options for question $questionId');

        // Add the actual options with real UUIDs to the response
        response['question_options'] = insertedOptions;
      }

      // Approval questions store their two slider end labels in the same table
      // (the column comment reserves question_options for "approval rating
      // display labels"). sort_order 0 = low/disapprove end, 1 = high/approve.
      // Written for every approval question so the labels are explicit; older
      // questions without rows fall back to the defaults client-side.
      if (type == 'approval_rating' || type == 'approval') {
        final lowLabel = normalizeApprovalLabel(approvalLowLabel,
            fallback: kDefaultApprovalLowLabel);
        final highLabel = normalizeApprovalLabel(approvalHighLabel,
            fallback: kDefaultApprovalHighLabel);
        try {
          final insertedLabels = await _supabase
              .from('question_options')
              .insert([
                {
                  'question_id': questionId,
                  'option_text': lowLabel,
                  'sort_order': 0,
                },
                {
                  'question_id': questionId,
                  'option_text': highLabel,
                  'sort_order': 1,
                },
              ])
              .select('id, option_text, sort_order, question_id');

          response['question_options'] = insertedLabels;
          print('Inserted approval end labels for question $questionId: '
              '"$lowLabel" / "$highLabel"');
        } catch (e) {
          // Non-fatal: the question is already posted and renders with the
          // default labels if the label rows failed to write.
          print('Error inserting approval end labels for $questionId: $e');
        }
      }

      // Handle categories through the junction table
      if (categories != null && categories.isNotEmpty) {
        // First, get category IDs from the categories table
        final categoryResponse = await _supabase
            .from('categories')
            .select('id, name')
            .filter('name', 'in', '(${categories.map((c) => '"$c"').join(',')})');
        
        // Check if all categories exist
        if (categoryResponse.length != categories.length) {
          final foundCategories = categoryResponse.map((cat) => cat['name'] as String).toSet();
          final missingCategories = categories.where((cat) => !foundCategories.contains(cat)).toList();
          
          throw Exception('Categories not found in database: ${missingCategories.join(', ')}. Please contact support or try different categories.');
        }
        
        // All categories exist, insert into question_categories junction table
        final categoryInserts = categoryResponse.map((cat) => {
          'question_id': questionId,
          'category_id': cat['id'],
        }).toList();

        await _supabase
            .from('question_categories')
            .insert(categoryInserts);

        print('Inserted ${categoryInserts.length} category associations for question $questionId');
      }

      // Add some local data for UI consistency
      response['votes'] = 0;
      response['categories'] = categories ?? [];
      response['mentioned_countries'] = mentionedCountries ?? [];

      // Auto-subscribe author to their question
      try {
        // 1. Subscribe to question topic for comment notifications
        await FirebaseMessaging.instance.subscribeToTopic('question_$questionId');
        print('\u2705 Subscribed author to question topic: question_$questionId');
        
        // 2. Create server subscription record
        await _supabase.from('question_subscriptions').upsert({
          'question_id': questionId,
          'user_id': currentUser.id,
          'subscription_source': 'author',
          'last_vote_count': 0,
          'last_comment_count': 0,
        });
        print('\u2705 Created author subscription record in database');
        
        // 3. Subscribe author to their user topic for creator notifications
        await FirebaseMessaging.instance.subscribeToTopic('user_${currentUser.id}');
        print('\u2705 Subscribed author to user topic: user_${currentUser.id}');
      } catch (e) {
        print('\u274c Error auto-subscribing author: $e');
        // Don't fail question creation if subscription fails
      }

      // Add the new question to local collection for immediate UI update
      _questions.insert(0, response);
      notifyListeners();

      print('Question submitted successfully: ${response['id']}');
      return response;

    } catch (e) {
      print('Error submitting question: $e');
      if (e.toString().contains('permission denied') || e.toString().contains('RLS')) {
        throw Exception('You do not have permission to submit questions. Please check if you are authenticated and not banned.');
      } else if (e.toString().contains('violates')) {
        throw Exception('Question data violates database constraints. Please check your input.');
      } else {
        throw Exception('Failed to submit question: $e');
      }
    }
  }

  // Check if user has answered the Question of the Day
  bool hasAnsweredQuestionOfTheDay(UserService? userService) {
    if (_questionOfTheDay == null || userService == null) return false;

    final questionId = _questionOfTheDay!['id'].toString();
    return userService.hasAnsweredQuestion(questionId);
  }

  /// Whether [questionId] is the "effective" Question of the Day — either the
  /// real QOTD or its cached NSFW fallback. Answering an effective QOTD is the
  /// only answer path that credits the streak (QOTD-first §Streak rule).
  bool isEffectiveQotd(String questionId) {
    if (_questionOfTheDay != null &&
        _questionOfTheDay!['id']?.toString() == questionId) {
      return true;
    }
    if (_nsfwFallbackQuestion != null &&
        _nsfwFallbackQuestion!['id']?.toString() == questionId) {
      return true;
    }
    return false;
  }

  /// Fetch the answer-gated Archive queue — unanswered questions, ordered by
  /// [sort].
  ///
  /// Queries `question_feed_scores` ordered by vote_count desc
  /// ([ArchiveSort.popular], the default) or created_at desc
  /// ([ArchiveSort.newest], the Archive's "New" flip) and returns up to [limit]
  /// questions the user has NOT answered, has NOT reported, and (when
  /// [showNSFW] is false) are non-NSFW. Uses an over-fetch loop (2×limit per
  /// page) so client-side subtraction of answered/reported items still yields a
  /// full page; terminates when [limit] is collected or the source is exhausted
  /// (an empty page). vote_count is normalized to `votes` and engagement data is
  /// enriched before returning. Both sorts take the identical path — only the
  /// ORDER BY column changes — so pagination behaves the same either way.
  ///
  /// Introduced for Phase 2 (swipe context off the QOTD results push); Phase 3
  /// reuses it for the Archive default view.
  Future<List<Map<String, dynamic>>> fetchArchiveQueue({
    required UserService userService,
    int limit = 30,
    int offset = 0,
    bool showNSFW = false,
    ArchiveSort sort = ArchiveSort.popular,
  }) async {
    final List<Map<String, dynamic>> collected = [];
    final int pageSize = (limit * 2).clamp(1, 200);
    int pageOffset = offset;

    try {
      while (collected.length < limit) {
        final response = await _supabase
            .from('question_feed_scores')
            .select('''
              id,
              prompt,
              description,
              type,
              created_at,
              nsfw,
              is_hidden,
              is_private,
              targeting_type,
              country_code,
              city_id,
              author_id,
              categories,
              vote_count,
              question_options (
                id,
                option_text,
                sort_order
              )
            ''')
            .eq('is_hidden', false)
            .neq('is_private', true)
            .filter('targeting_type', 'in', '("globe","country")')
            .order(
              sort == ArchiveSort.newest ? 'created_at' : 'vote_count',
              ascending: false,
            )
            .range(pageOffset, pageOffset + pageSize - 1);

        if (response.isEmpty) break; // Source exhausted.

        for (final question in response) {
          final id = question['id']?.toString();
          if (id == null) continue;

          // Client-side subtraction (matches the home/feed filter rules).
          if (!showNSFW && question['nsfw'] == true) continue;
          if (userService.hasAnsweredQuestion(id)) continue;
          if (userService.shouldHideReportedQuestion(id)) continue;

          final transformed = Map<String, dynamic>.from(question);
          transformed['votes'] = question['vote_count'] ?? 0;
          collected.add(transformed);
          if (collected.length >= limit) break;
        }

        pageOffset += pageSize;
      }

      // Enrich with engagement data (comment/reaction counts) for tiles/results.
      if (collected.isNotEmpty) {
        await enrichQuestionsWithEngagementData(collected);
      }
    } catch (e) {
      print('Error in fetchArchiveQueue: $e');
    }

    return collected;
  }

  /// Fetches fresh vote counts for [ids] from `question_feed_scores` (the same
  /// source [fetchArchiveQueue] orders by), keyed by question id. Batched into a
  /// single `in`-filter query. Ids absent from the view are simply omitted; on
  /// error an empty map is returned — either way the caller falls back to the
  /// vote count stored on the answered record. Used by the Archive Answered view
  /// to rank the user's answered questions by current popularity.
  Future<Map<String, int>> fetchVoteCountsForIds(List<String> ids) async {
    if (ids.isEmpty) return {};
    try {
      final response = await _supabase
          .from('question_feed_scores')
          .select('id, vote_count')
          .inFilter('id', ids);

      final counts = <String, int>{};
      for (final row in response) {
        final id = row['id']?.toString();
        if (id == null) continue;
        counts[id] = (row['vote_count'] as int?) ?? 0;
      }
      return counts;
    } catch (e) {
      print('Error in fetchVoteCountsForIds: $e');
      return {};
    }
  }

  // ==========================================================================
  // Asker's Pick — QOTD nomination (Phase 3b)
  // ==========================================================================

  /// Fetch candidate questions for the post-submit "Help pick an upcoming
  /// Question of the Day" step.
  ///
  /// Returns up to [count] questions a fresh asker could plausibly nominate:
  /// excludes the asker's own questions, text questions (a QOTD is always
  /// multiple choice or approval — matches the server's
  /// `qotd_eligible_questions` view, scripts/qotd_exclude_text_questions.sql),
  /// NSFW/hidden/private, and (client-side) questions that were already a QOTD.
  /// Only globe-targeted questions are surfaced because the server-side
  /// selection only ever picks globe questions — so a nomination for a
  /// country/city question would be a silent no-op.
  ///
  /// Always fills [count] slots: people-asked (organic) questions first, then
  /// the seeded QOTD bank, and as a last resort questions that were a QOTD
  /// more than three months ago (still eligible server-side). Pages through
  /// the pool newest-first until the slots are full or the pool runs out, so
  /// the sheet is never left with one option just because the newest posts
  /// happen to be the asker's own or yesterday's QOTD.
  ///
  /// This is a best-effort approximation for UX only. The `nominate_qotd` RPC
  /// re-checks every rule server-side and rejects gracefully, so a candidate
  /// that slips through here simply produces a friendly message on tap.
  Future<List<Map<String, dynamic>>> fetchQotdCandidates({
    required String excludeAuthorId,
    int count = 3,
  }) async {
    final List<Map<String, dynamic>> candidates = [];

    // Pool = questions not yet shown as the QOTD (never in history, or only
    // scheduled for a future date). The newest posts form the window; within
    // it, the ones that already have votes come first and zero-vote ones are
    // still allowed. nominate_qotd enforces eligibility server-side
    // (scripts/nominate_qotd_future_ok.sql).
    // Questions that have ALREADY BEEN the QOTD (history date <= today, UTC)
    // go last: never-shown first, and a question shown more than three months
    // ago only as a fallback filler (the server's repeat rule, so nominate_qotd
    // still accepts it). Shown within three months = ineligible, skipped.
    // A question scheduled for a FUTURE date is still fair game: the pool is
    // "never shown yet", not "never in the table".
    final Map<String, DateTime> lastQotdDay = {};
    final todayUtc = DateTime.now().toUtc();
    final today = DateTime.utc(todayUtc.year, todayUtc.month, todayUtc.day);
    final repeatCutoff = DateTime.utc(today.year, today.month - 3, today.day);
    try {
      final history = await _supabase
          .from('question_of_the_day_history')
          .select('question_id, date')
          .limit(5000);
      for (final entry in history) {
        final qid = entry['question_id']?.toString();
        final date = DateTime.tryParse(entry['date']?.toString() ?? '');
        if (qid == null || date == null) continue;
        final day = DateTime.utc(date.year, date.month, date.day);
        if (day.isAfter(today)) continue;
        final prev = lastQotdDay[qid];
        if (prev == null || day.isAfter(prev)) lastQotdDay[qid] = day;
      }
    } catch (e) {
      print('Non-critical: could not fetch QOTD history for candidates: $e');
    }

    // Page newest-first until `count` survive the client-side filters. The
    // author and type filters are pushed into the query; the already-a-QOTD
    // exclusion has to stay client-side (the id list can be thousands long),
    // which is why one page is not enough.
    const int pageSize = 30;
    const int maxPages = 10;
    final organic = <Map<String, dynamic>>[]; // people-asked, never a QOTD
    final seeded = <Map<String, dynamic>>[]; // the QOTD bank, never a QOTD
    final repeats = <Map<String, dynamic>>[]; // a QOTD > 3 months ago

    try {
      for (var page = 0; page < maxPages; page++) {
        var query = _supabase
            .from('question_feed_scores')
            .select('''
              id,
              prompt,
              description,
              type,
              created_at,
              nsfw,
              is_hidden,
              is_private,
              targeting_type,
              author_id,
              categories,
              vote_count
            ''')
            .eq('is_hidden', false)
            .eq('nsfw', false)
            .neq('is_private', true)
            .eq('targeting_type', 'globe')
            .neq('type', 'text');
        if (excludeAuthorId.isNotEmpty) {
          // `neq` alone would also drop NULL-author (seeded) rows.
          query = query.or('author_id.is.null,author_id.neq.$excludeAuthorId');
        }
        final response = await query
            .order('created_at', ascending: false) // newest posts first
            .range(page * pageSize, (page + 1) * pageSize - 1);

        // Organic questions (real author) always outrank the seeded launch
        // bank — seeds only fill slots no organic candidate claims, mirroring
        // the server's ordering. NULL author is only a UX-side approximation
        // of is_seeded here (the feed-scores view doesn't expose the column);
        // the server enforces the real ordering.
        for (final question in response) {
          final id = question['id']?.toString();
          if (id == null) continue;
          if (question['type']?.toString() == 'text') continue;

          final authorId = question['author_id']?.toString();
          if (authorId != null && authorId == excludeAuthorId) continue;

          final transformed = Map<String, dynamic>.from(question);
          transformed['votes'] = question['vote_count'] ?? 0;

          final shown = lastQotdDay[id];
          if (shown == null) {
            (authorId == null ? seeded : organic).add(transformed);
          } else if (shown.isBefore(repeatCutoff)) {
            repeats.add(transformed);
          }
        }
        if (organic.length + seeded.length >= count) break;
        if (response.length < pageSize) break; // pool exhausted
      }

      // Within the collected window, questions WITH votes come first (most
      // voted first, newest breaking ties); zero-vote questions stay eligible
      // and simply follow. Organic still outranks seeded.
      int byVotesThenNewest(Map<String, dynamic> a, Map<String, dynamic> b) {
        final v = ((b['votes'] ?? 0) as num).compareTo((a['votes'] ?? 0) as num);
        if (v != 0) return v;
        return (b['created_at']?.toString() ?? '')
            .compareTo(a['created_at']?.toString() ?? '');
      }
      organic.sort(byVotesThenNewest);
      seeded.sort(byVotesThenNewest);
      repeats.sort(byVotesThenNewest);
      candidates
        ..addAll(organic)
        ..addAll(seeded)
        ..addAll(repeats); // fills only what organic + bank could not
      if (candidates.length > count) {
        candidates.removeRange(count, candidates.length);
      }
    } catch (e) {
      print('Error in fetchQotdCandidates: $e');
    }

    return candidates;
  }

  /// Nominate [questionId] as an upcoming Question of the Day via the
  /// `nominate_qotd` RPC. All rules are enforced server-side; the decoded
  /// result is mapped to a [NominationResult] with a user-friendly message.
  Future<NominationResult> nominateQotd(String questionId) async {
    try {
      final result = await _supabase.rpc(
        'nominate_qotd',
        params: {'p_question_id': questionId},
      );

      if (result is Map && result['success'] == true) {
        return const NominationResult.ok();
      }

      final errorCode = result is Map ? result['error']?.toString() : null;
      return NominationResult.fail(NominationResult.parseError(errorCode));
    } catch (e) {
      print('Nominate QOTD error: $e');
      return NominationResult.fail(NominationError.unknown);
    }
  }

  // Load more questions for pagination using optimized Edge Function
  Future<List<Map<String, dynamic>>> loadMoreQuestions({
    required String feedType,
    Map<String, dynamic>? filters,
    UserService? userService,
    int currentOffset = 0,
    Set<String>? qualifyingQuestionIds,
    String? categoryFilter,
  }) async {
    if (_isLoading) {
      print('⚠️  Already loading, skipping loadMoreQuestions');
      return [];
    }

    print('📄 Loading more questions with pagination (offset: $currentOffset)...');

    // When a review or category filter is active, bypass materialized view
    // and query directly for qualifying questions without the 30-day limit
    if (qualifyingQuestionIds != null && qualifyingQuestionIds.isNotEmpty) {
      print('🔍 Review filter active: fetching filtered questions by ID (offset: $currentOffset)');
      return await _fetchFilteredQuestionsByIds(
        feedType: feedType,
        filters: filters,
        userService: userService,
        questionIds: qualifyingQuestionIds,
        offset: currentOffset,
        limit: 50,
      );
    }

    if (categoryFilter != null) {
      print('🔍 Category filter active: fetching filtered questions by category (offset: $currentOffset)');
      return await _fetchFilteredQuestionsByCategory(
        feedType: feedType,
        filters: filters,
        userService: userService,
        categoryName: categoryFilter,
        offset: currentOffset,
        limit: 50,
      );
    }

    // Materialized view limit is 300 questions per feed type
    const int materializedViewLimit = 300;

    // If offset is within materialized view range, use optimized feed
    if (currentOffset < materializedViewLimit) {
      print('📋 Using materialized view for offset $currentOffset');
      return await fetchOptimizedFeed(
        feedType: feedType,
        filters: filters,
        userService: userService,
        offset: currentOffset,
        useCache: false, // Don't use cache for pagination to get fresh data
        forceRefresh: false, // Don't force refresh, just bypass cache
      );
    }

    // Offset exceeds materialized view - switch to raw database queries
    print('🗃️ Offset $currentOffset exceeds materialized view limit ($materializedViewLimit), switching to raw database queries');

    // Calculate offset for raw database query (subtract materialized view size)
    final rawDatabaseOffset = currentOffset - materializedViewLimit;

    return await _fetchRawDatabaseQuestions(
      feedType: feedType,
      filters: filters,
      userService: userService,
      offset: rawDatabaseOffset,
      limit: 50, // Standard batch size
    );
  }

  // Fetch questions directly from raw database when materialized view is exhausted
  Future<List<Map<String, dynamic>>> _fetchRawDatabaseQuestions({
    required String feedType,
    Map<String, dynamic>? filters,
    UserService? userService,
    int offset = 0,
    int limit = 50,
  }) async {
    try {
      print('🗃️ Fetching questions directly from database: feedType=$feedType, offset=$offset, limit=$limit');
      
      // Extract filter parameters
      final showNSFW = filters?['showNSFW'] as bool? ?? false;
      final questionTypes = filters?['questionTypes'] as List<String>?;
      final locationFilter = filters?['locationFilter'] as String?;
      final userCountryCode = filters?['userCountry'] as String?;
      final userCityId = filters?['userCity'] as String?;
      
      // Build base query with same structure as materialized view
      var queryBuilder = _supabase
          .from('questions')
          .select('''
            id, prompt, description, type, created_at, nsfw, is_hidden,
            targeting_type, country_code, city_id, author_id,
            cities(name, admin2_code, country_code, lat, lng),
            question_options(id, option_text, sort_order),
            question_categories(categories(id, name))
          ''')
          .eq('is_hidden', false)
          .gte('created_at', DateTime.now().subtract(Duration(days: 30)).toIso8601String());
      
      // Apply NSFW filter
      if (!showNSFW) {
        queryBuilder = queryBuilder.eq('nsfw', false);
      }
      
      // Apply question type filter
      if (questionTypes != null && questionTypes.isNotEmpty) {
        queryBuilder = queryBuilder.inFilter('type', questionTypes);
      }
      
      // Apply location-based filtering
      if (locationFilter != null && locationFilter != 'global') {
        if (locationFilter == 'country' && userCountryCode != null) {
          // Country mode: show country-targeted questions for user's country + global questions
          queryBuilder = queryBuilder.or(
            'targeting_type.eq.globe,'
            'and(targeting_type.eq.country,country_code.eq.$userCountryCode)'
          );
        } else if (locationFilter == 'city' && userCityId != null && userCountryCode != null) {
          // City mode: show city questions + country questions + global questions
          queryBuilder = queryBuilder.or(
            'targeting_type.eq.globe,'
            'and(targeting_type.eq.country,country_code.eq.$userCountryCode),'
            'targeting_type.eq.city'
          );
        } else {
          // Default to global if location data is missing
          queryBuilder = queryBuilder.eq('targeting_type', 'globe');
        }
      } else {
        // Global mode: show all questions (no location filtering)
        // No additional filtering needed
      }
      
      // Apply sorting based on feed type - all use creation time for initial ordering
      final orderedQuery = queryBuilder.order('created_at', ascending: false);
      
      // Apply pagination
      final response = await orderedQuery
          .range(offset, offset + limit - 1) as List<dynamic>;
      
      print('🗃️ Raw database query returned ${response.length} questions');
      
      if (response.isEmpty) {
        return [];
      }
      
      // Process and calculate scores for each question
      final questions = <Map<String, dynamic>>[];
      
      for (final item in response) {
        final question = Map<String, dynamic>.from(item as Map<String, dynamic>);
        
        // Calculate vote count
        try {
          final voteCount = await getAccurateVoteCount(
            question['id'].toString(),
            question['type']?.toString()
          );
          question['vote_count'] = voteCount;
          question['votes'] = voteCount; // For compatibility
        } catch (e) {
          print('⚠️ Failed to get vote count for question ${question['id']}: $e');
          question['vote_count'] = 0;
          question['votes'] = 0;
        }
        
        // Calculate hours since post
        final createdAt = DateTime.parse(question['created_at']);
        final hoursSincePost = DateTime.now().difference(createdAt).inHours.toDouble();
        question['hours_since_post'] = hoursSincePost > 0 ? hoursSincePost : 0.1;
        
        // Calculate scope weight (from database architecture)
        final targetingType = question['targeting_type']?.toString() ?? 'globe';
        double scopeWeight;
        switch (targetingType) {
          case 'city':
            scopeWeight = 1.0;
            break;
          case 'country':
            scopeWeight = 0.7;
            break;
          case 'globe':
          case 'global':
            scopeWeight = 0.3;
            break;
          default:
            scopeWeight = 0.5;
            break;
        }
        question['scope_weight'] = scopeWeight;
        
        // Process categories array
        final questionCategories = question['question_categories'] as List<dynamic>?;
        if (questionCategories != null) {
          final categories = questionCategories
              .map((qc) => (qc['categories'] as Map<String, dynamic>)['name'].toString())
              .toList();
          question['categories'] = categories;
        } else {
          question['categories'] = <String>[];
        }
        
        // Clean up the nested structure
        question.remove('question_categories');
        
        // Process cities data
        final citiesData = question['cities'] as Map<String, dynamic>?;
        if (citiesData != null) {
          question['city_name'] = citiesData['name'];
          question['admin2_code'] = citiesData['admin2_code'];
          question['city_country_code'] = citiesData['country_code'];
          question['city_lat'] = citiesData['lat'];
          question['city_lng'] = citiesData['lng'];
        }
        
        questions.add(question);
      }
      
      // Apply sorting algorithm client-side (similar to _applyManualTrendingAlgorithm)
      _applySortingAlgorithmToRawQuestions(questions, feedType);
      
      // Apply location boost if enabled AND in city mode only
      if (userService != null && userService.boostLocalActivity && locationFilter == 'city') {
        await _applyLocationBoost(
          questions,
          userCountryCode: userCountryCode,
          userCityId: userCityId,
          feedType: feedType,
        );
        
        // Re-sort after applying location boost
        _applySortingAlgorithmToRawQuestions(questions, feedType);
      }
      
      print('✅ Processed ${questions.length} questions from raw database');
      return questions;
      
    } catch (e, stackTrace) {
      print('❌ Error fetching from raw database: $e');
      print('❌ Stack trace: $stackTrace');
      return [];
    }
  }

  // Batch fetch response counts for question IDs + types in parallel
  // Uses getAccurateVoteCount per question but runs all concurrently
  Future<Map<String, int>> _batchGetResponseCounts(
    List<String> questionIds, [
    Map<String, String?>? questionTypes,
  ]) async {
    if (questionIds.isEmpty) return {};
    try {
      final futures = questionIds.map((qid) async {
        try {
          final qtype = questionTypes?[qid];
          final count = await getAccurateVoteCount(qid, qtype);
          return MapEntry(qid, count);
        } catch (e) {
          return MapEntry(qid, 0);
        }
      });

      final entries = await Future.wait(futures);
      return Map.fromEntries(entries);
    } catch (e) {
      print('⚠️ Batch response count failed: $e');
      return {};
    }
  }

  // Process raw question data: add vote counts, metadata, and categories
  void _processQuestionData(
    Map<String, dynamic> question,
    Map<String, int> voteCounts,
  ) {
    final qid = question['id']?.toString() ?? '';
    final voteCount = voteCounts[qid] ?? 0;
    question['vote_count'] = voteCount;
    question['votes'] = voteCount;

    final createdAt = DateTime.parse(question['created_at']);
    final hoursSincePost = DateTime.now().difference(createdAt).inHours.toDouble();
    question['hours_since_post'] = hoursSincePost > 0 ? hoursSincePost : 0.1;

    final targetingType = question['targeting_type']?.toString() ?? 'globe';
    double scopeWeight;
    switch (targetingType) {
      case 'city': scopeWeight = 1.0; break;
      case 'country': scopeWeight = 0.7; break;
      case 'globe': case 'global': scopeWeight = 0.3; break;
      default: scopeWeight = 0.5; break;
    }
    question['scope_weight'] = scopeWeight;

    final questionCategories = question['question_categories'] as List<dynamic>?;
    if (questionCategories != null) {
      final categories = questionCategories
          .map((qc) => (qc['categories'] as Map<String, dynamic>)['name'].toString())
          .toList();
      question['categories'] = categories;
    } else {
      question['categories'] = <String>[];
    }
    question.remove('question_categories');

    final citiesData = question['cities'] as Map<String, dynamic>?;
    if (citiesData != null) {
      question['city_name'] = citiesData['name'];
      question['admin2_code'] = citiesData['admin2_code'];
      question['city_country_code'] = citiesData['country_code'];
      question['city_lat'] = citiesData['lat'];
      question['city_lng'] = citiesData['lng'];
    }
  }

  // Fetch questions filtered by a set of qualifying IDs (no 30-day limit)
  // Used when a review tag filter is active
  Future<List<Map<String, dynamic>>> _fetchFilteredQuestionsByIds({
    required String feedType,
    Map<String, dynamic>? filters,
    UserService? userService,
    required Set<String> questionIds,
    int offset = 0,
    int limit = 50,
  }) async {
    try {
      print('🔍 Fetching filtered questions by IDs: feedType=$feedType, offset=$offset, limit=$limit, ids=${questionIds.length}');

      final showNSFW = filters?['showNSFW'] as bool? ?? false;
      final questionTypes = filters?['questionTypes'] as List<String>?;
      final idList = questionIds.toList();

      // For popular/trending sort, we need vote counts to determine page order.
      // Fetch metadata + counts first, sort the IDs, then fetch the right page of full data.
      if (feedType == 'popular' || feedType == 'trending') {
        // Step 1: Fetch lightweight metadata (id, type, created_at) for all qualifying IDs
        final metaResponse = await _supabase
            .from('questions')
            .select('id, type, created_at, targeting_type')
            .eq('is_hidden', false)
            .inFilter('id', idList) as List<dynamic>;

        final metaMap = <String, Map<String, dynamic>>{};
        final typeMap = <String, String?>{};
        for (final row in metaResponse) {
          final id = row['id'].toString();
          metaMap[id] = Map<String, dynamic>.from(row);
          typeMap[id] = row['type']?.toString();
        }

        // Step 2: Get response counts in parallel (uses accurate per-type counting)
        final validIds = metaMap.keys.toList();
        final voteCounts = await _batchGetResponseCounts(validIds, typeMap);

        // Step 3: Sort IDs by the feed algorithm
        final sortedIds = List<String>.from(validIds);
        if (feedType == 'popular') {
          sortedIds.sort((a, b) => (voteCounts[b] ?? 0).compareTo(voteCounts[a] ?? 0));
        } else {
          sortedIds.sort((a, b) {
            final aVotes = voteCounts[a] ?? 0;
            final bVotes = voteCounts[b] ?? 0;
            final aMeta = metaMap[a];
            final bMeta = metaMap[b];
            final aCreated = aMeta != null ? DateTime.parse(aMeta['created_at']) : DateTime(2000);
            final bCreated = bMeta != null ? DateTime.parse(bMeta['created_at']) : DateTime(2000);
            final aHours = DateTime.now().difference(aCreated).inHours.toDouble();
            final bHours = DateTime.now().difference(bCreated).inHours.toDouble();
            final aScore = (aVotes + 1) / (aHours + 1);
            final bScore = (bVotes + 1) / (bHours + 1);
            return bScore.compareTo(aScore);
          });
        }

        // Step 3: Take the right page of sorted IDs
        final pageIds = sortedIds.skip(offset).take(limit).toList();
        if (pageIds.isEmpty) return [];

        // Step 4: Fetch full question data for this page only
        var queryBuilder = _supabase
            .from('questions')
            .select('''
              id, prompt, description, type, created_at, nsfw, is_hidden,
              targeting_type, country_code, city_id, author_id,
              cities(name, admin2_code, country_code, lat, lng),
              question_options(id, option_text, sort_order),
              question_categories(categories(id, name))
            ''')
            .inFilter('id', pageIds);

        final response = await queryBuilder as List<dynamic>;

        // Process and maintain sort order
        final questionMap = <String, Map<String, dynamic>>{};
        for (final item in response) {
          final question = Map<String, dynamic>.from(item as Map<String, dynamic>);
          _processQuestionData(question, voteCounts);
          questionMap[question['id'].toString()] = question;
        }

        // Return in sorted order
        final questions = <Map<String, dynamic>>[];
        for (final id in pageIds) {
          if (questionMap.containsKey(id)) {
            questions.add(questionMap[id]!);
          }
        }

        print('✅ Processed ${questions.length} filtered questions by ID (${feedType} sort)');
        return questions;
      }

      // For 'new' feed: simple created_at ordering, paginate directly
      var queryBuilder = _supabase
          .from('questions')
          .select('''
            id, prompt, description, type, created_at, nsfw, is_hidden,
            targeting_type, country_code, city_id, author_id,
            cities(name, admin2_code, country_code, lat, lng),
            question_options(id, option_text, sort_order),
            question_categories(categories(id, name))
          ''')
          .eq('is_hidden', false)
          .inFilter('id', idList);

      if (!showNSFW) {
        queryBuilder = queryBuilder.eq('nsfw', false);
      }

      if (questionTypes != null && questionTypes.isNotEmpty) {
        queryBuilder = queryBuilder.inFilter('type', questionTypes);
      }

      final orderedQuery = queryBuilder.order('created_at', ascending: false);
      final response = await orderedQuery
          .range(offset, offset + limit - 1) as List<dynamic>;

      print('🔍 Filtered-by-ID query returned ${response.length} questions');
      if (response.isEmpty) return [];

      // Batch fetch vote counts for this page (with type info for accurate counting)
      final pageTypeMap = <String, String?>{};
      for (final item in response) {
        pageTypeMap[item['id'].toString()] = item['type']?.toString();
      }
      final pageIds = pageTypeMap.keys.toList();
      final voteCounts = await _batchGetResponseCounts(pageIds, pageTypeMap);

      final questions = <Map<String, dynamic>>[];
      for (final item in response) {
        final question = Map<String, dynamic>.from(item as Map<String, dynamic>);
        _processQuestionData(question, voteCounts);
        questions.add(question);
      }

      print('✅ Processed ${questions.length} filtered questions by ID');
      return questions;

    } catch (e, stackTrace) {
      print('❌ Error fetching filtered questions by ID: $e');
      print('❌ Stack trace: $stackTrace');
      return [];
    }
  }

  // Fetch questions filtered by category name (no 30-day limit)
  // Used when a category filter is active
  Future<List<Map<String, dynamic>>> _fetchFilteredQuestionsByCategory({
    required String feedType,
    Map<String, dynamic>? filters,
    UserService? userService,
    required String categoryName,
    int offset = 0,
    int limit = 50,
  }) async {
    try {
      print('🔍 Fetching filtered questions by category: feedType=$feedType, category=$categoryName, offset=$offset, limit=$limit');

      final showNSFW = filters?['showNSFW'] as bool? ?? false;
      final questionTypes = filters?['questionTypes'] as List<String>?;

      // For popular/trending, first get all matching question IDs, then sort by votes
      if (feedType == 'popular' || feedType == 'trending') {
        // Step 1: Get all question IDs matching this category (with type for accurate vote counting)
        var idQueryBuilder = _supabase
            .from('questions')
            .select('id, type, created_at, targeting_type, question_categories!inner(categories!inner(id, name))')
            .eq('is_hidden', false)
            .eq('question_categories.categories.name', categoryName);

        if (!showNSFW) {
          idQueryBuilder = idQueryBuilder.eq('nsfw', false);
        }
        if (questionTypes != null && questionTypes.isNotEmpty) {
          idQueryBuilder = idQueryBuilder.inFilter('type', questionTypes);
        }

        final idResponse = await idQueryBuilder as List<dynamic>;
        if (idResponse.isEmpty) return [];

        final metaMap = <String, Map<String, dynamic>>{};
        final typeMap = <String, String?>{};
        for (final row in idResponse) {
          final id = row['id'].toString();
          metaMap[id] = Map<String, dynamic>.from(row);
          typeMap[id] = row['type']?.toString();
        }
        final allIds = metaMap.keys.toList();

        // Step 2: Batch get vote counts (parallel, with type info)
        final voteCounts = await _batchGetResponseCounts(allIds, typeMap);

        final sortedIds = List<String>.from(allIds);
        if (feedType == 'popular') {
          sortedIds.sort((a, b) => (voteCounts[b] ?? 0).compareTo(voteCounts[a] ?? 0));
        } else {
          sortedIds.sort((a, b) {
            final aVotes = voteCounts[a] ?? 0;
            final bVotes = voteCounts[b] ?? 0;
            final aMeta = metaMap[a];
            final bMeta = metaMap[b];
            final aCreated = aMeta != null ? DateTime.parse(aMeta['created_at']) : DateTime(2000);
            final bCreated = bMeta != null ? DateTime.parse(bMeta['created_at']) : DateTime(2000);
            final aHours = DateTime.now().difference(aCreated).inHours.toDouble();
            final bHours = DateTime.now().difference(bCreated).inHours.toDouble();
            final aScore = (aVotes + 1) / (aHours + 1);
            final bScore = (bVotes + 1) / (bHours + 1);
            return bScore.compareTo(aScore);
          });
        }

        // Step 4: Page and fetch full data
        final pageIds = sortedIds.skip(offset).take(limit).toList();
        if (pageIds.isEmpty) return [];

        final fullResponse = await _supabase
            .from('questions')
            .select('''
              id, prompt, description, type, created_at, nsfw, is_hidden,
              targeting_type, country_code, city_id, author_id,
              cities(name, admin2_code, country_code, lat, lng),
              question_options(id, option_text, sort_order),
              question_categories(categories(id, name))
            ''')
            .inFilter('id', pageIds) as List<dynamic>;

        final questionMap = <String, Map<String, dynamic>>{};
        for (final item in fullResponse) {
          final question = Map<String, dynamic>.from(item as Map<String, dynamic>);
          _processQuestionData(question, voteCounts);
          questionMap[question['id'].toString()] = question;
        }

        final questions = <Map<String, dynamic>>[];
        for (final id in pageIds) {
          if (questionMap.containsKey(id)) {
            questions.add(questionMap[id]!);
          }
        }

        print('✅ Processed ${questions.length} filtered questions by category (${feedType} sort)');
        return questions;
      }

      // For 'new' feed: simple created_at ordering
      var queryBuilder = _supabase
          .from('questions')
          .select('''
            id, prompt, description, type, created_at, nsfw, is_hidden,
            targeting_type, country_code, city_id, author_id,
            cities(name, admin2_code, country_code, lat, lng),
            question_options(id, option_text, sort_order),
            question_categories!inner(categories!inner(id, name))
          ''')
          .eq('is_hidden', false)
          .eq('question_categories.categories.name', categoryName);

      if (!showNSFW) {
        queryBuilder = queryBuilder.eq('nsfw', false);
      }

      if (questionTypes != null && questionTypes.isNotEmpty) {
        queryBuilder = queryBuilder.inFilter('type', questionTypes);
      }

      final orderedQuery = queryBuilder.order('created_at', ascending: false);
      final response = await orderedQuery
          .range(offset, offset + limit - 1) as List<dynamic>;

      print('🔍 Filtered-by-category query returned ${response.length} questions');
      if (response.isEmpty) return [];

      final catPageTypeMap = <String, String?>{};
      for (final item in response) {
        catPageTypeMap[item['id'].toString()] = item['type']?.toString();
      }
      final catPageIds = catPageTypeMap.keys.toList();
      final voteCounts = await _batchGetResponseCounts(catPageIds, catPageTypeMap);

      final questions = <Map<String, dynamic>>[];
      for (final item in response) {
        final question = Map<String, dynamic>.from(item as Map<String, dynamic>);
        _processQuestionData(question, voteCounts);
        questions.add(question);
      }

      print('✅ Processed ${questions.length} filtered questions by category');
      return questions;

    } catch (e, stackTrace) {
      print('❌ Error fetching filtered questions by category: $e');
      print('❌ Stack trace: $stackTrace');
      return [];
    }
  }

  // Apply sorting algorithm to raw database questions
  void _applySortingAlgorithmToRawQuestions(List<Map<String, dynamic>> questions, String feedType) {
    if (feedType == 'trending') {
      questions.sort((a, b) {
        final aVotes = a['vote_count'] as int? ?? 0;
        final bVotes = b['vote_count'] as int? ?? 0;
        final aHours = a['hours_since_post'] as double? ?? 1.0;
        final bHours = b['hours_since_post'] as double? ?? 1.0;
        final aScopeWeight = a['scope_weight'] as double? ?? 1.0;
        final bScopeWeight = b['scope_weight'] as double? ?? 1.0;
        
        final aScore = (aVotes + 1) / (aHours + 1) * aScopeWeight;
        final bScore = (bVotes + 1) / (bHours + 1) * bScopeWeight;
        
        return bScore.compareTo(aScore); // Descending order
      });
    } else if (feedType == 'popular') {
      questions.sort((a, b) {
        final aVotes = a['vote_count'] as int? ?? 0;
        final bVotes = b['vote_count'] as int? ?? 0;
        final aScopeWeight = a['scope_weight'] as double? ?? 1.0;
        final bScopeWeight = b['scope_weight'] as double? ?? 1.0;
        
        final aScore = aVotes * aScopeWeight;
        final bScore = bVotes * bScopeWeight;
        
        return bScore.compareTo(aScore); // Descending order
      });
    } else if (feedType == 'new') {
      questions.sort((a, b) {
        final aTime = DateTime.parse(a['created_at']);
        final bTime = DateTime.parse(b['created_at']);
        return bTime.compareTo(aTime); // Most recent first
      });
    }
  }

  // Refresh questions (reset pagination)
  Future<void> refreshQuestions({Map<String, dynamic>? filters}) async {
    print('Refreshing questions data...');
    
    if (_usingSampleData) {
      print('Using sample data mode - refresh not needed');
      return;
    }
    
    // Reset pagination
    _currentPage = 0;
    _hasMoreQuestions = true;
    _lastFetchedId = null;
    
    // Fetch fresh data
    await fetchQuestions(filters: filters);
  }

  // Enhanced caching with feed-specific storage (using existing fields from above)
  
  // Get cached user location data (returns null if not cached to avoid database calls)
  Map<String, dynamic>? _getCachedUserLocationData(String? userCityId) {
    if (userCityId == null) return null;
    
    final now = DateTime.now();
    
    // Check if we have valid cached data
    if (_cachedUserLocationData != null && 
        _userLocationCacheTimestamp != null &&
        _cachedUserLocationData!['cityId'] == userCityId &&
        now.difference(_userLocationCacheTimestamp!) < _userLocationCacheDuration) {
      print('DEBUG: Using cached user location data');
      return _cachedUserLocationData;
    }
    
    // Don't make database calls here - return null to skip location boosting
    // Location data should be pre-cached when user selects their city
    print('DEBUG: No cached user location data for cityId: $userCityId - skipping location boost');
    return null;
  }
  
  // Async method to actually fetch and cache user location data
  Future<Map<String, dynamic>?> _fetchAndCacheUserLocationData(String? userCityId) async {
    if (userCityId == null) return null;
    
    // Check cache first to avoid unnecessary database calls
    final cachedData = _getCachedUserLocationData(userCityId);
    if (cachedData != null) {
      print('DEBUG: Using existing cached location data, no database call needed');
      return cachedData;
    }
    
    try {
      print('DEBUG: Fetching and caching user location data for cityId: $userCityId (cache miss)');
      final userCityData = await _supabase
          .from('cities')
          .select('admin1_code, admin2_code, country_code')
          .eq('id', userCityId)
          .single();
      
      // Cache the data with city ID for validation
      _cachedUserLocationData = {
        'cityId': userCityId,
        'admin1_code': userCityData['admin1_code'],
        'admin2_code': userCityData['admin2_code'],
        'country_code': userCityData['country_code'],
      };
      _userLocationCacheTimestamp = DateTime.now();
      
      print('DEBUG: Cached user location - admin1: ${userCityData['admin1_code']}, admin2: ${userCityData['admin2_code']}, country: ${userCityData['country_code']}');
      return _cachedUserLocationData;
    } catch (e) {
      print('Error fetching user location data: $e');
      return null;
    }
  }
  
  // Specialized query for City mode - fetch all city questions and filter by admin2_code
  Future<List<Map<String, dynamic>>> _fetchCityModeQuestions(
    String feedType,
    int limit,
    Map<String, dynamic>? filters,
    UserService? userService,
  ) async {
    try {
      final userCityId = filters?['userCity'] as String?;
      final userCountryCode = filters?['userCountry'] as String?;
      
      if (userCityId == null || userCountryCode == null) {
        print('🏙️ City mode: Missing user city or country, returning empty');
        return [];
      }
      
      print('🏙️ City mode: Fetching city-targeted questions directly...');
      
      // First, get user's city data to find their admin1_code (state/province)
      final userCityData = await _supabase
          .from('cities')
          .select('admin1_code, name')
          .eq('id', userCityId)
          .single();
      
      final userAdmin1Code = userCityData['admin1_code'] as String?;
      final userCityName = userCityData['name'] as String?;
      
      print('🏙️ City mode: User is in $userCityName (admin1: ${userAdmin1Code ?? 'none'})');
      
      // Query ALL city-targeted questions for the user's country
      // We'll filter by admin1_code later during processing
      var baseQuery = _supabase
          .from('questions')
          .select('''
            id,
            prompt,
            description,
            type,
            created_at,
            nsfw,
            is_hidden,
            is_private,
            targeting_type,
            country_code,
            city_id,
            author_id,
            cities!inner(
              id,
              name,
              admin1_code
            ),
            question_options (
              id,
              option_text,
              sort_order
            ),
            question_categories (
              categories (
                id,
                name,
                is_nsfw
              )
            )
          ''')
          .eq('is_hidden', false)
          .eq('targeting_type', 'city')
          .eq('country_code', userCountryCode)
          .gte('created_at', DateTime.now().subtract(Duration(days: 30)).toIso8601String());
      
      // Apply filters
      // Filter out private questions if excludePrivate is true
      if (filters?['excludePrivate'] == true) {
        baseQuery = baseQuery.eq('is_private', false);
      }
      
      if (filters?['showNSFW'] != true) {
        baseQuery = baseQuery.eq('nsfw', false);
      }
      
      if (filters?['questionTypes'] != null) {
        final types = filters!['questionTypes'] as List<String>;
        if (types.isNotEmpty) {
          final mappedTypes = types.map((type) {
            switch (type) {
              case 'approval':
                return 'approval_rating';
              case 'multipleChoice':
                return 'multiple_choice';
              default:
                return type;
            }
          }).toList();
          baseQuery = baseQuery.inFilter('type', mappedTypes);
        }
      }
      
      // Apply ordering and limit
      final response = await baseQuery
          .order('created_at', ascending: false)
          .limit(limit);
      
      print('🏙️ City mode query returned ${response.length} city questions for country $userCountryCode');
      
      // Now filter by admin1_code (state/province) if user has one
      List<Map<String, dynamic>> filteredCityQuestions = [];
      
      if (userAdmin1Code != null && userAdmin1Code.isNotEmpty) {
        // Filter to only include cities in the same state/province
        for (var question in response) {
          final questionAdmin1 = question['cities']?['admin1_code'] as String?;
          if (questionAdmin1 == userAdmin1Code) {
            filteredCityQuestions.add(Map<String, dynamic>.from(question));
          }
        }
        print('🏙️ Filtered to ${filteredCityQuestions.length} questions in same state/province (admin1: $userAdmin1Code)');
      } else {
        // If no admin1_code, include all city questions in the country
        filteredCityQuestions = response.map((q) => Map<String, dynamic>.from(q)).toList();
        print('🏙️ No admin1_code for filtering, keeping all ${filteredCityQuestions.length} city questions');
      }
      
      if (filteredCityQuestions.isEmpty && response.isNotEmpty) {
        print('⚠️ No city questions found in user\'s state/province, will show country questions only');
      }
      
      // Transform the filtered city data
      final processedQuestions = filteredCityQuestions.map<Map<String, dynamic>>((question) {
        final Map<String, dynamic> processedQuestion = Map<String, dynamic>.from(question as Map<String, dynamic>);
        
        // Transform the nested categories structure into a simple array
        final questionCategories = question['question_categories'] as List<dynamic>? ?? [];
        final categories = questionCategories
          .map((qc) => qc['categories'])
          .where((cat) => cat != null)
          .map((cat) => cat['name'] as String)
          .toList();
        
        processedQuestion['categories'] = categories;
        
        // Map nsfw to is_nsfw for compatibility
        if (processedQuestion.containsKey('nsfw')) {
          processedQuestion['is_nsfw'] = processedQuestion['nsfw'];
        }
        
        // Add city data from joined information
        if (processedQuestion['cities'] != null) {
          processedQuestion['city_name'] = processedQuestion['cities']['name'];
          processedQuestion['admin1_code'] = processedQuestion['cities']['admin1_code'];
        }
        
        // Remove the junction table data
        processedQuestion.remove('question_categories');
        
        // Initialize votes to 0 for now
        processedQuestion['votes'] = 0;
        processedQuestion['vote_count'] = 0;
        
        return processedQuestion;
      }).toList();
      
      // Get vote counts in a batch
      await _fetchVoteCountsForQuestions(processedQuestions);
      
      // Apply sorting based on feed type
      switch (feedType) {
        case 'trending':
          _applyTrendingAlgorithm(processedQuestions);
          break;
        case 'popular':
          _applyPopularAlgorithm(processedQuestions);
          break;
        case 'new':
          _applyNewAlgorithm(processedQuestions);
          break;
      }
      
      // Also add country-targeted questions for the user's country
      var countryQuery = _supabase
          .from('questions')
          .select('''
            id,
            prompt,
            description,
            type,
            created_at,
            nsfw,
            is_hidden,
            targeting_type,
            country_code,
            city_id,
            author_id,
            question_options (
              id,
              option_text,
              sort_order
            ),
            question_categories (
              categories (
                id,
                name,
                is_nsfw
              )
            )
          ''')
          .eq('is_hidden', false)
          .eq('targeting_type', 'country')
          .eq('country_code', userCountryCode)
          .gte('created_at', DateTime.now().subtract(Duration(days: 30)).toIso8601String());
      
      // Apply same filters
      if (filters?['showNSFW'] != true) {
        countryQuery = countryQuery.eq('nsfw', false);
      }
      
      if (filters?['questionTypes'] != null) {
        final types = filters!['questionTypes'] as List<String>;
        if (types.isNotEmpty) {
          final mappedTypes = types.map((type) {
            switch (type) {
              case 'approval':
                return 'approval_rating';
              case 'multipleChoice':
                return 'multiple_choice';
              default:
                return type;
            }
          }).toList();
          countryQuery = countryQuery.inFilter('type', mappedTypes);
        }
      }
      
      final countryResponse = await countryQuery.order('created_at', ascending: false).limit(limit);
      
      print('🏙️ City mode: Also found ${countryResponse.length} country questions');
      
      // Process country questions
      final processedCountryQuestions = (countryResponse as List<dynamic>).map<Map<String, dynamic>>((question) {
        final Map<String, dynamic> processedQuestion = Map<String, dynamic>.from(question as Map<String, dynamic>);
        
        // Transform categories
        final questionCategories = question['question_categories'] as List<dynamic>? ?? [];
        final categories = questionCategories
          .map((qc) => qc['categories'])
          .where((cat) => cat != null)
          .map((cat) => cat['name'] as String)
          .toList();
        
        processedQuestion['categories'] = categories;
        
        // Map nsfw to is_nsfw
        if (processedQuestion.containsKey('nsfw')) {
          processedQuestion['is_nsfw'] = processedQuestion['nsfw'];
        }
        
        processedQuestion.remove('question_categories');
        processedQuestion['votes'] = 0;
        processedQuestion['vote_count'] = 0;
        
        return processedQuestion;
      }).toList();
      
      // Get vote counts for country questions
      await _fetchVoteCountsForQuestions(processedCountryQuestions);
      
      // Combine city and country questions
      final allQuestions = [...processedQuestions, ...processedCountryQuestions];
      
      // Remove duplicates
      final uniqueQuestions = _removeDuplicateQuestions(allQuestions);
      
      // Re-apply sorting on combined set
      switch (feedType) {
        case 'trending':
          _applyTrendingAlgorithm(uniqueQuestions);
          break;
        case 'popular':
          _applyPopularAlgorithm(uniqueQuestions);
          break;
        case 'new':
          _applyNewAlgorithm(uniqueQuestions);
          break;
      }
      
      print('🏙️ City mode: Returning ${uniqueQuestions.length} total questions (city + country)');
      
      return uniqueQuestions;
      
    } catch (e) {
      print('❌ Error in City mode query: $e');
      return [];
    }
  }
  
  // Helper method to fetch vote counts for a list of questions
  Future<void> _fetchVoteCountsForQuestions(List<Map<String, dynamic>> questions) async {
    if (questions.isEmpty) return;
    
    try {
            final questionIds = questions
          .map((q) => q['id']?.toString())
          .whereType<String>()
          .toList();
      if (questionIds.isEmpty) return;

      final voteCounts = await _resultsService.fetchVoteCounts(questionIds);
      
      
      for (var question in questions) {
        final questionId = question['id']?.toString();
        if (questionId != null) {
          final voteCount = voteCounts[questionId] ?? 0;
          question['votes'] = voteCount;
          question['vote_count'] = voteCount;
        }
      }
      
      print('📊 Fetched vote counts for ${questions.length} questions');
    } catch (e) {
      print('❌ Error fetching vote counts: $e');
    }
  }

  // Manual fallback for city/country filters when materialized view is empty
  Future<List<Map<String, dynamic>>> _fetchManualLocationFallback({
    required String locationFilter,
    required String feedType,
    required int limit,
    int offset = 0, // Add offset parameter for infinite pagination
    Map<String, dynamic>? filters,
  }) async {
    try {
      print('🔍 Starting manual $locationFilter fallback query...');
      print('🔍 Fallback filters: $filters');
      
      final userCountryCode = filters?['userCountry'] as String?;
      final userCityId = filters?['userCity'] as String?;
      
      if (userCountryCode == null) {
        print('❌ No user country code for manual fallback');
        return [];
      }
    
    // Build the base query - focus on core fields that definitely exist
    var queryBuilder = _supabase
        .from('questions')
        .select('''
          id, prompt, targeting_type, city_id, country_code, 
          created_at, is_hidden, type, description, nsfw
        ''')
        .eq('is_hidden', false)
        .gte('created_at', DateTime.now().subtract(Duration(days: 30)).toIso8601String());
    
    // Apply NSFW and question type filters first
    final showNSFW = filters?['showNSFW'] as bool? ?? false;
    if (!showNSFW) {
      queryBuilder = queryBuilder.eq('nsfw', false);
    }
    
    // Apply question type filter
    final questionTypes = filters?['questionTypes'] as List<String>?;
    if (questionTypes != null && questionTypes.isNotEmpty) {
      queryBuilder = queryBuilder.inFilter('type', questionTypes);
    }
    
    if (locationFilter == 'city' && userCityId != null) {
      // City mode: Show questions from same county + country questions
      try {
        // Get user's city data to find their admin2_code
        final userCityData = await _supabase
            .from('cities')
            .select('admin2_code, country_code')
            .eq('id', userCityId)
            .single();

        final userAdmin2Code = userCityData['admin2_code'] as String?;
        
        if (userAdmin2Code != null) {
          // Get all cities in the same county/admin2_code
          final nearbyCitiesData = await _supabase
              .from('cities')
              .select('id')
              .eq('admin2_code', userAdmin2Code)
              .eq('country_code', userCityData['country_code']);

          final nearbyCityIds = nearbyCitiesData.map((city) => city['id']).toList();
          print('🔍 Manual fallback: Found ${nearbyCityIds.length} cities in same county (admin2: $userAdmin2Code)');
          
          if (nearbyCityIds.isNotEmpty) {
            // Show city questions from nearby cities + country questions
            queryBuilder = queryBuilder.or(
              'and(targeting_type.eq.country,country_code.eq.$userCountryCode),'
              'and(targeting_type.eq.city,city_id.in.(${nearbyCityIds.join(',')}))'
            );
            print('🔍 Manual fallback querying for: nearby cities + country questions');
          } else {
            // Fallback to country questions only
            queryBuilder = queryBuilder
                .eq('targeting_type', 'country')
                .eq('country_code', userCountryCode);
            print('🔍 Manual fallback: No nearby cities found, using country questions only');
          }
        } else {
          // No admin2_code, fallback to exact city + country
          queryBuilder = queryBuilder.or(
            'and(targeting_type.eq.country,country_code.eq.$userCountryCode),'
            'and(targeting_type.eq.city,city_id.eq.$userCityId)'
          );
          print('🔍 Manual fallback: No admin2_code, using exact city + country questions');
        }
      } catch (e) {
        print('❌ Error getting nearby cities for manual fallback: $e');
        // Fallback to exact city + country
        queryBuilder = queryBuilder.or(
          'and(targeting_type.eq.country,country_code.eq.$userCountryCode),'
          'and(targeting_type.eq.city,city_id.eq.$userCityId)'
        );
        print('🔍 Manual fallback: Error fallback to exact city + country questions');
      }
    } else if (locationFilter == 'country') {
      // Get questions targeted to user's country only (exclude global)
      queryBuilder = queryBuilder
          .eq('targeting_type', 'country')
          .eq('country_code', userCountryCode);
    }
    
    final response = await queryBuilder
        .order('created_at', ascending: false)
        .range(offset, offset + limit - 1) as List<dynamic>;
    
    print('🔍 Manual fallback raw database response: ${response.length} questions found');
    
    if (response.isEmpty) {
      print('🔍 Manual fallback found no questions for $locationFilter mode');
      return [];
    }
    
    print('🔍 Manual fallback found ${response.length} questions for $locationFilter mode');
    
    // Convert to proper format and calculate vote counts
    final questions = <Map<String, dynamic>>[];
    
    for (final q in response) {
      final question = Map<String, dynamic>.from(q as Map<String, dynamic>);
      
      // Calculate hours since post
      final createdAt = DateTime.parse(question['created_at']);
      final hoursSincePost = DateTime.now().difference(createdAt).inHours.toDouble();
      question['hours_since_post'] = hoursSincePost > 0 ? hoursSincePost : 0.1;
      
      // Calculate vote count using accurate method
      try {
        final voteCount = await getAccurateVoteCount(
          question['id'].toString(),
          question['type']?.toString()
        );
        question['vote_count'] = voteCount;
        question['votes'] = voteCount; // For compatibility
      } catch (e) {
        print('⚠️ Failed to get vote count for question ${question['id']}: $e');
        question['vote_count'] = 0;
        question['votes'] = 0;
      }
      
      // Calculate scope weight based on targeting type (from DB architecture)
      final targetingType = question['targeting_type']?.toString() ?? 'globe';
      double scopeWeight;
      switch (targetingType) {
        case 'city':
          scopeWeight = 1.0;
          break;
        case 'country':
          scopeWeight = 0.7;
          break;
        case 'globe':
        case 'global':
          scopeWeight = 0.3;
          break;
        default:
          scopeWeight = 0.5;
          break;
      }
      question['scope_weight'] = scopeWeight;
      
      questions.add(question);
    }
    
    // Apply manual trending algorithm
    _applyManualTrendingAlgorithm(questions, feedType);
    
    // Debug: Show vote counts for manual fallback results
    final fallbackVoteCounts = questions.map((q) => q['vote_count'] as int? ?? 0).toList();
    fallbackVoteCounts.sort();
    print('✅ Manual fallback completed: ${questions.length} questions with vote counts: $fallbackVoteCounts');
    return questions;
    } catch (e, stackTrace) {
      print('❌ Manual fallback failed with exception: $e');
      print('❌ Stack trace: $stackTrace');
      return [];
    }
  }
  
  // Manual trending algorithm for fallback queries
  void _applyManualTrendingAlgorithm(List<Map<String, dynamic>> questions, String feedType) {
    if (feedType == 'trending') {
      questions.sort((a, b) {
        final aVotes = a['vote_count'] as int? ?? 0;
        final bVotes = b['vote_count'] as int? ?? 0;
        final aHours = a['hours_since_post'] as double? ?? 1.0;
        final bHours = b['hours_since_post'] as double? ?? 1.0;
        final aScopeWeight = a['scope_weight'] as double? ?? 1.0;
        final bScopeWeight = b['scope_weight'] as double? ?? 1.0;
        
        final aScore = (aVotes + 1) / aHours * aScopeWeight;
        final bScore = (bVotes + 1) / bHours * bScopeWeight;
        
        return bScore.compareTo(aScore); // Descending order
      });
    } else if (feedType == 'popular') {
      questions.sort((a, b) {
        final aVotes = a['vote_count'] as int? ?? 0;
        final bVotes = b['vote_count'] as int? ?? 0;
        return bVotes.compareTo(aVotes); // Most votes first
      });
    } else if (feedType == 'new') {
      questions.sort((a, b) {
        final aTime = DateTime.parse(a['created_at']);
        final bTime = DateTime.parse(b['created_at']);
        return bTime.compareTo(aTime); // Most recent first
      });
    }
  }
  
  // Background loading state (using existing field from above)
  
  // Fetch feed using optimized Edge Function (primary method)
  Future<List<Map<String, dynamic>>> fetchOptimizedFeed({
    required String feedType, // 'trending', 'popular', 'new'
    int limit = 50,
    int offset = 0, // Pagination offset for infinite scroll
    String? cursor,
    Map<String, dynamic>? filters,
    bool useCache = true,
    UserService? userService, // For location boost settings
    bool forceRefresh = false, // Force fresh data (clears cache)
  }) async {
    // Include boost state and offset in cache key for proper cache differentiation
    final boostState = userService?.boostLocalActivity ?? false;
    final cacheKey = '${feedType}_${filters?.hashCode ?? 'default'}_boost_${boostState}_offset_$offset';
    final now = DateTime.now();
    
    // Check cache first (unless forcing refresh)
    if (useCache && !forceRefresh && _feedCache.containsKey(cacheKey)) {
      final timestamp = _feedCacheTimestamps[cacheKey];
      if (timestamp != null && now.difference(timestamp) < _feedCacheDuration) {
        print('📋 Using cached $feedType feed (offset: $offset)');
        return _feedCache[cacheKey]!;
      }
    }
    
    try {
      final stopwatch = Stopwatch()..start();
      
      // In Global mode OR when boost is disabled OR in City mode, bypass Edge Function
      // This ensures pure sorting without any location bias
      final locationFilter = filters?['locationFilter'] as String?;
      final boostDisabled = userService?.boostLocalActivity == false;
      
      if (locationFilter == 'global' || boostDisabled || locationFilter == 'city') {
        final reason = locationFilter == 'global' ? 'Global mode' : 
                      locationFilter == 'city' ? 'City mode' : 'Boost disabled';
        print('🌍 $reason detected: bypassing Edge Function, using direct database query');
        
        // For City mode, use a specialized query
        if (locationFilter == 'city') {
          return await _fetchCityModeQuestions(feedType, limit, filters, userService);
        }
        
        final fallbackResult = await _fetchFallbackFeed(feedType, limit, cursor, filters, userService, offset);
        
        // DEBUG: Log vote counts after fetchOptimizedFeed fallback for popular feed
        if (feedType == 'popular' && fallbackResult.isNotEmpty) {
          final voteCounts = fallbackResult.take(5).map((q) => q['votes'] ?? q['vote_count'] ?? 0).toList();
          print('🐛 DEBUG: After fetchOptimizedFeed fallback - First 5 vote counts: $voteCounts');
        }
        
        return fallbackResult;
      }
      
      print('🚀 Fetching $feedType feed using optimized Edge Function${forceRefresh ? ' (force refresh)' : ''} (offset: $offset)...');
      
      // For City mode, use 'new' feed type to get the broadest set of questions
      // then apply client-side sorting to ensure consistency across all modes
      final actualFeedType = (locationFilter == 'city') ? 'new' : feedType;
      
      if (locationFilter == 'city' && actualFeedType != feedType) {
        print('🏙️ City mode: Using feedType "$actualFeedType" instead of "$feedType" for broader question set');
      }
      
      // Build query parameters for Edge Function
      final queryParams = <String, String>{
        'feedType': actualFeedType,
        'limit': limit.toString(),
        'offset': offset.toString(),
      };
      
      // Add filters to query parameters
      if (filters != null) {
        if (filters['showNSFW'] == true) {
          queryParams['showNSFW'] = 'true';
        }
        
        if (filters['questionTypes'] != null) {
          final types = filters['questionTypes'] as List<String>;
          if (types.isNotEmpty) {
            queryParams['questionTypes'] = types.join(',');
          }
        }
        
        // Pass location filter mode to server
        if (filters['locationFilter'] != null) {
          queryParams['locationFilter'] = filters['locationFilter'] as String;
        }
        
        // Pass user location for server-side filtering
        if (filters['userCountry'] != null) {
          queryParams['userCountry'] = filters['userCountry'] as String;
        }
        
        if (filters['userCity'] != null) {
          queryParams['userCity'] = filters['userCity'] as String;
        }
        
        // Pass excludePrivate filter to server
        if (filters['excludePrivate'] == true) {
          queryParams['excludePrivate'] = 'true';
        }
      }
      
      // Build Edge Function URL (strip /rest/v1 from base URL)
      final baseUrl = _supabase.rest.url.replaceAll('/rest/v1', '');
      final uri = Uri.parse('$baseUrl/functions/v1/swift-service')
          .replace(queryParameters: queryParams);
      
      // Use anon key for Edge Functions (required for proper authentication)
      const anonKey = SupabaseConfig.anonKey;
      
      print('🔗 Edge Function URL: $uri');
      print('🔍 Request parameters: ${queryParams.toString()}');
      print('🎯 Cache key: $cacheKey');
      print('📊 Using cache: $useCache, Force refresh: $forceRefresh');
      
      // Make HTTP request to Edge Function
      final httpStartTime = stopwatch.elapsedMilliseconds;
      
      final requestHeaders = <String, String>{
        'Authorization': 'Bearer $anonKey',
        'apikey': anonKey,
        'Content-Type': 'application/json',
      };
      
      final response = await http.get(uri, headers: requestHeaders);
      final httpEndTime = stopwatch.elapsedMilliseconds;
      
      print('📊 Edge Function response: ${response.statusCode} (${httpEndTime - httpStartTime}ms)');
      
      if (response.statusCode != 200) {
        print('❌ Edge Function failed: ${response.statusCode} - ${response.body}');
        throw Exception('Edge Function returned ${response.statusCode}: ${response.body}');
      }
      
      // Parse JSON response
      final parseStartTime = stopwatch.elapsedMilliseconds;
      final responseData = json.decode(response.body) as List<dynamic>;
      
      if (responseData.isEmpty) {
        print('⚠️  Edge Function returned empty feed for $feedType');
        
        // Check if we need to do manual fallback for city/country filters
        final locationFilter = filters?['locationFilter'] as String?;
        if (locationFilter == 'city' || locationFilter == 'country') {
          print('🔄 Attempting manual database fallback for $locationFilter filter...');
          try {
            final fallbackQuestions = await _fetchManualLocationFallback(
              locationFilter: locationFilter!,
              feedType: feedType,
              limit: limit, // Use the requested limit for infinite pagination
              offset: 0, // Fallback starts from beginning since materialized view is limited
              filters: filters,
            );
            if (fallbackQuestions.isNotEmpty) {
              print('✅ Manual fallback returned ${fallbackQuestions.length} questions');
              // Remove duplicates before returning
              final uniqueQuestions = _removeDuplicateQuestions(fallbackQuestions);
              return uniqueQuestions;
            }
          } catch (e) {
            print('❌ Manual fallback failed: $e');
          }
        }
        
        return [];
      }
      
      // Convert to proper format
      final processedQuestions = responseData.map<Map<String, dynamic>>((question) {
        return Map<String, dynamic>.from(question as Map<String, dynamic>);
      }).toList();
      final parseEndTime = stopwatch.elapsedMilliseconds;
      
      print('✅ Edge Function returned ${processedQuestions.length} questions (JSON parsing: ${parseEndTime - parseStartTime}ms)');
      print('🔍 Debug: First question data structure: ${processedQuestions.isNotEmpty ? processedQuestions.first.keys.toList() : 'No questions'}');
      
      // Check if Edge Function returned appropriate questions for city mode
      final currentLocationFilter = filters?['locationFilter'] as String?;
      if (currentLocationFilter == 'city' && processedQuestions.isNotEmpty) {
        final cityQuestions = processedQuestions.where((q) => q['targeting_type']?.toString() == 'city').toList();
        print('🏙️ Edge Function returned ${cityQuestions.length} city questions out of ${processedQuestions.length} total');
        
        // Debug: Check vote counts and targeting types in returned questions
        if (feedType == 'popular' || feedType == 'new') {
          final voteCounts = processedQuestions.map((q) => q['vote_count'] as int? ?? 0).toList();
          voteCounts.sort();
          print('🔍 Popular mode Edge Function vote counts: min=${voteCounts.isNotEmpty ? voteCounts.first : 'none'}, max=${voteCounts.isNotEmpty ? voteCounts.last : 'none'}, all=$voteCounts');
          
          // Debug: Show targeting types of all questions
          final targetingTypes = processedQuestions.map((q) => q['targeting_type']?.toString() ?? 'unknown').toList();
          final targetingCounts = <String, int>{};
          for (final type in targetingTypes) {
            targetingCounts[type] = (targetingCounts[type] ?? 0) + 1;
          }
          print('🔍 Edge Function targeting types: $targetingCounts');
          
          // Debug: Show low-vote questions specifically
          final lowVoteQuestions = processedQuestions.where((q) => (q['vote_count'] as int? ?? 0) <= 3).toList();
          if (lowVoteQuestions.isNotEmpty) {
            print('🔍 Low-vote questions (≤3 votes): ${lowVoteQuestions.length} found');
            for (final q in lowVoteQuestions.take(3)) {
              print('  - ID: ${q['id']}, votes: ${q['vote_count']}, targeting: ${q['targeting_type']}, city: ${q['city_id']}, prompt: ${q['prompt']?.toString().substring(0, 50) ?? 'no prompt'}...');
            }
          }
        }
        
        if (cityQuestions.isEmpty) {
          print('⚠️  Edge Function returned no city-targeted questions for city mode - attempting manual fallback');
          try {
            final fallbackQuestions = await _fetchManualLocationFallback(
              locationFilter: currentLocationFilter!,
              feedType: feedType,
              limit: limit, // Use the requested limit for infinite pagination
              offset: 0, // Fallback starts from beginning since materialized view is limited
              filters: filters,
            );
            if (fallbackQuestions.isNotEmpty) {
              print('✅ Manual fallback returned ${fallbackQuestions.length} city questions');
              // Remove duplicates before returning
              final uniqueQuestions = _removeDuplicateQuestions(fallbackQuestions);
              return uniqueQuestions;
            } else {
              print('⚠️  Manual fallback also returned no city questions - user will see empty feed or QR code');
            }
          } catch (e) {
            print('❌ Manual fallback failed: $e');
          }
        }
      }
      
      // Note: City mode now uses direct database query, so no need for geographic filtering here
      
      // Apply client-side location boost if enabled AND not in global mode
      final clientProcessingStartTime = stopwatch.elapsedMilliseconds;
      final isCityMode = locationFilter == 'city';
      
      if (userService != null && userService.boostLocalActivity && isCityMode) {
        final userCountryCode = filters?['userCountry'] as String?;
        final userCityId = filters?['userCity'] as String?;
        
        print('🎯 Applying client-side location boost - country: $userCountryCode, city: $userCityId');
        
        // Pre-populate location cache from filters to avoid database calls
        if (userCityId != null && userCountryCode != null && _getCachedUserLocationData(userCityId) == null) {
          _cachedUserLocationData = {
            'cityId': userCityId,
            'admin2_code': null, // Will use admin2_code from Edge Function data
            'country_code': userCountryCode,
          };
          _userLocationCacheTimestamp = DateTime.now();
          print('📍 Pre-populated location cache from filter data');
        }
        
        final boostStartTime = stopwatch.elapsedMilliseconds;
        await _applyLocationBoostToEdgeData(
          processedQuestions,
          userCountryCode: userCountryCode,
          userCityId: userCityId,
          feedType: feedType,
          locationFilter: locationFilter,
        );
        final boostEndTime = stopwatch.elapsedMilliseconds;
        print('🎯 Location boost applied (${boostEndTime - boostStartTime}ms)');
      } else {
        final reason = locationFilter != 'city' ? 'not city mode' : 
                      userService == null ? 'no user service' :
                      !userService.boostLocalActivity ? 'boost disabled' : 'unknown';
        print('📋 Using Edge Function pre-sorted data as-is (location boost skipped: $reason)');
        // Edge Function already provides optimal sorting via feed_questions_optimized_v3
      }

      final clientProcessingEndTime = stopwatch.elapsedMilliseconds;
      print('⚡ Client processing completed (${clientProcessingEndTime - clientProcessingStartTime}ms)');

      // Cache the result for future requests
      _feedCache[cacheKey] = processedQuestions;
      _feedCacheTimestamps[cacheKey] = now;
      
      // Enrich with engagement data (temporary until Edge Function is updated to use v3)
      await enrichQuestionsWithEngagementData(processedQuestions);

      stopwatch.stop();
      print('🎉 Successfully fetched $feedType feed: ${processedQuestions.length} questions (total: ${stopwatch.elapsedMilliseconds}ms)');
      return processedQuestions;

    } catch (e) {
      print('❌ Edge Function error: $e');
      // Review 2026-09-19 P0-4: an empty feed and a broken feed look identical
      // from outside. `reason: edge_function` says the primary path failed but
      // the fallback may still have saved it; `reason: fallback` says the user
      // saw nothing at all.
      AnalyticsService().trackRpcFailed('load_feed', reason: 'edge_function');
      
      // Fallback to question_feed_scores materialized view
      print('🔄 Falling back to question_feed_scores materialized view...');
      try {
        return await _fetchFallbackFeed(feedType, limit, cursor, filters, userService, offset);
      } catch (fallbackError) {
        print('❌ Fallback also failed: $fallbackError');
        AnalyticsService().trackRpcFailed('load_feed', reason: 'fallback');
        return [];
      }
    }
  }



  // Fallback method using question_feed_scores materialized view
  Future<List<Map<String, dynamic>>> _fetchFallbackFeed(
    String feedType,
    int limit,
    String? cursor,
    Map<String, dynamic>? filters, [
    UserService? userService,
    int offset = 0, // Add offset parameter for proper pagination
  ]) async {
    print('🔄 Using fallback: question_feed_scores materialized view');
    
    try {
      // Primary fallback: Use question_feed_scores materialized view for better performance
      var baseQuery = _supabase
          .from('question_feed_scores')
          .select('''
            id,
            prompt,
            description,
            type,
            created_at,
            nsfw,
            is_hidden,
            is_private,
            targeting_type,
            country_code,
            city_id,
            author_id,
            categories,
            vote_count,
            scope_weight,
            hours_since_post,
            trending_score,
            popular_score,
            question_options (
              id,
              option_text,
              sort_order
            )
          ''')
          .eq('is_hidden', false)
          .gte('created_at', DateTime.now().subtract(Duration(days: 30)).toIso8601String());
      
      print('📊 Using question_feed_scores materialized view with pre-computed scores');
      
      // Apply filters efficiently
      if (filters != null) {
        if (filters['showNSFW'] != true) {
          baseQuery = baseQuery.eq('nsfw', false);
        }
        
        if (filters['questionTypes'] != null) {
          final types = filters['questionTypes'] as List<String>;
          if (types.isNotEmpty) {
            final mappedTypes = types.map((type) {
              switch (type) {
                case 'approval':
                  return 'approval_rating';
                case 'multipleChoice':
                  return 'multiple_choice';
                default:
                  return type;
              }
            }).toList();
            baseQuery = baseQuery.filter('type', 'in', '(${mappedTypes.map((t) => '"$t"').join(',')})');
          }
        }
        
        // Apply targeting_type filter based on location mode
        final locationFilter = filters['locationFilter'] as String?;
        if (locationFilter == 'global') {
          // Global mode: show globe, country, and user's city questions
          final userCityId = filters['userCity'] as String?;
          if (userCityId != null) {
            // Include user's city questions along with globe and country questions
            baseQuery = baseQuery.or('targeting_type.in.(globe,country),and(targeting_type.eq.city,city_id.eq.$userCityId)');
            print('🌍 Global mode: targeting_type in (globe, country) OR city_id = $userCityId');
          } else {
            // No user city set, show only globe and country questions
            baseQuery = baseQuery.filter('targeting_type', 'in', '("globe","country")');
            print('🌍 Global mode: targeting_type in (globe, country) - no user city set');
          }
        } else if (locationFilter == 'country' && filters['userCountry'] != null) {
          // Country mode: only show questions addressed to user's country (exclude global)
          final userCountry = filters['userCountry'] as String;
          baseQuery = baseQuery.eq('targeting_type', 'country').eq('country_code', userCountry);
          print('🏳️ Country mode: targeting_type=country AND country_code=$userCountry');
        } else if (locationFilter == 'city' && filters['userCountry'] != null) {
          // City mode: show questions addressed to user's country + city (no globe)
          final userCountry = filters['userCountry'] as String;
          baseQuery = baseQuery.or('and(targeting_type.eq.country,country_code.eq.$userCountry),and(targeting_type.eq.city,country_code.eq.$userCountry)');
          print('🏙️ City mode: targeting_type=country OR city (country_code=$userCountry, no globe)');
        }
      } else {
        baseQuery = baseQuery.eq('nsfw', false);
      }

      // Add pagination
      if (cursor != null) {
        baseQuery = baseQuery.lt('created_at', cursor);
      }

      // Apply ordering based on feed type using pre-computed scores
      // In Global mode OR when boost is disabled, use raw vote_count for pure popularity sorting
      final locationFilter = filters?['locationFilter'] as String?;
      final isGlobalMode = locationFilter == 'global';
      final boostDisabled = userService?.boostLocalActivity == false;
      final usePureSorting = isGlobalMode || boostDisabled;
      
      late final dynamic finalQuery;
      switch (feedType) {
        case 'trending':
          // For trending, always use trending_score (it should not have location bias built-in)
          // The location bias comes from client-side boost, not the score itself
          finalQuery = baseQuery.order('trending_score', ascending: false);
          print('📈 Using pre-computed trending_score for sorting');
          break;
        case 'popular':
          if (usePureSorting) {
            finalQuery = baseQuery.order('vote_count', ascending: false);
            print('🌍 Pure popular: Using vote_count for pure sorting');
          } else {
            finalQuery = baseQuery.order('popular_score', ascending: false);
            print('🔥 Using pre-computed popular_score for sorting');
          }
          break;
        case 'new':
        default:
          finalQuery = baseQuery.order('created_at', ascending: false);
          print('🆕 Using created_at for new feed sorting');
          break;
      }

      final response = await finalQuery.range(offset, offset + limit - 1);
      
      print('📊 Materialized view query returned ${response?.length ?? 0} questions for $feedType feed');
      
      // DEBUG: Log first 5 questions' vote counts for popular feed to verify ordering
      if (feedType == 'popular' && response.isNotEmpty) {
        final voteCounts = response.take(5).map((q) => q['vote_count'] ?? 0).toList();
        print('🐛 DEBUG: First 5 vote counts from materialized view: $voteCounts');
        final isDescending = voteCounts.length <= 1 || 
            voteCounts.asMap().entries.every((entry) => 
                entry.key == 0 || voteCounts[entry.key - 1] >= entry.value);
        print('🐛 DEBUG: Vote counts properly descending: $isDescending');
      }

      if (response.isEmpty) {
        print('⚠️  No questions found for $feedType feed in materialized view');
        
        // Try manual fallback for city/country filters before giving up
        final locationFilter = filters?['locationFilter'] as String?;
        if (locationFilter == 'city' || locationFilter == 'country') {
          print('🔄 Materialized view empty for $locationFilter, attempting manual database fallback...');
          try {
            final fallbackQuestions = await _fetchManualLocationFallback(
              locationFilter: locationFilter!,
              feedType: feedType,
              limit: limit, // Use the requested limit for infinite pagination
              offset: 0, // Fallback starts from beginning since materialized view is limited
              filters: filters,
            );
            if (fallbackQuestions.isNotEmpty) {
              print('✅ Manual fallback returned ${fallbackQuestions.length} questions from materialized view early exit');
              // Remove duplicates before returning
              final uniqueQuestions = _removeDuplicateQuestions(fallbackQuestions);
              return uniqueQuestions;
            }
          } catch (e) {
            print('❌ Manual fallback from materialized view early exit failed: $e');
          }
        }
        
        return [];
      }

      // Transform the data - materialized view already has categories as array
      final processedQuestions = (response as List<dynamic>).map<Map<String, dynamic>>((question) {
        final Map<String, dynamic> processedQuestion = Map<String, dynamic>.from(question as Map<String, dynamic>);
        
        // For materialized view, categories are already processed
        if (processedQuestion['categories'] == null) {
          processedQuestion['categories'] = <String>[];
        }
        
        // Map vote_count to votes for consistency
        if (processedQuestion.containsKey('vote_count')) {
          processedQuestion['votes'] = processedQuestion['vote_count'];
        } else {
          processedQuestion['votes'] = 0;
        }
        
        // Map nsfw to is_nsfw for compatibility
        if (processedQuestion.containsKey('nsfw')) {
          processedQuestion['is_nsfw'] = processedQuestion['nsfw'];
        }
        
        return processedQuestion;
      }).toList();

      print('✅ Processed ${processedQuestions.length} questions from materialized view');

      // Apply location boost if enabled AND in city mode only
      if (userService != null && userService.boostLocalActivity && locationFilter == 'city') {
        final userCountryCode = filters?['userCountry'] as String?;
        final userCityId = filters?['userCity'] as String?;
        
        print('🎯 Applying location boost to materialized view data');
        await _applyLocationBoost(
          processedQuestions,
          userCountryCode: userCountryCode,
          userCityId: userCityId,
          boostLocalActivity: true,
          feedType: feedType,
          locationFilter: locationFilter,
        );
      } else {
        final reason = locationFilter == 'global' ? 'global mode' : 
                      userService == null ? 'no user service' :
                      !userService.boostLocalActivity ? 'boost disabled' : 'unknown';
        print('📋 Materialized view: location boost skipped ($reason)');
      }

      // If no questions found in materialized view for city/country filter, try manual fallback
      if (processedQuestions.isEmpty) {
        final locationFilter = filters?['locationFilter'] as String?;
        if (locationFilter == 'city' || locationFilter == 'country') {
          print('🔄 Materialized view empty for $locationFilter, attempting manual database fallback...');
          try {
            final fallbackQuestions = await _fetchManualLocationFallback(
              locationFilter: locationFilter!,
              feedType: feedType,
              limit: limit, // Use the requested limit for infinite pagination
              offset: 0, // Fallback starts from beginning since materialized view is limited
              filters: filters,
            );
            if (fallbackQuestions.isNotEmpty) {
              print('✅ Manual fallback returned ${fallbackQuestions.length} questions from materialized view path');
              // Remove duplicates before returning
              final uniqueQuestions = _removeDuplicateQuestions(fallbackQuestions);
              return uniqueQuestions;
            }
          } catch (e) {
            print('❌ Manual fallback from materialized view failed: $e');
          }
        }
      }

      // Remove any duplicate questions before returning
      final uniqueQuestions = _removeDuplicateQuestions(processedQuestions);
      
      // DEBUG: Log final vote counts after all processing for popular feed
      if (feedType == 'popular' && uniqueQuestions.isNotEmpty) {
        final finalVoteCounts = uniqueQuestions.take(5).map((q) => q['votes'] ?? q['vote_count'] ?? 0).toList();
        print('🐛 DEBUG: Final 5 vote counts after _fetchFallbackFeed processing: $finalVoteCounts');
        final isDescending = finalVoteCounts.length <= 1 || 
            finalVoteCounts.asMap().entries.every((entry) => 
                entry.key == 0 || finalVoteCounts[entry.key - 1] >= entry.value);
        print('🐛 DEBUG: Final vote counts properly descending: $isDescending');
      }
      
      return uniqueQuestions;
      
    } catch (e) {
      print('⚠️  question_feed_scores not available, falling back to questions table');
      
      // Secondary fallback: Use regular questions table
      var baseQuery = _supabase
          .from('questions')
          .select('''
            id,
            prompt,
            description,
            type,
            created_at,
            nsfw,
            is_hidden,
            targeting_type,
            country_code,
            city_id,
            author_id,
            cities(name),
            question_options (
              id,
              option_text,
              sort_order
            ),
            question_categories (
              categories (
                id,
                name,
                is_nsfw
              )
            )
          ''')
          .eq('is_hidden', false)
          .gte('created_at', DateTime.now().subtract(Duration(days: 30)).toIso8601String());

      // Apply filters efficiently
      if (filters != null) {
        if (filters['showNSFW'] != true) {
          baseQuery = baseQuery.eq('nsfw', false);
        }
        
        if (filters['questionTypes'] != null) {
          final types = filters['questionTypes'] as List<String>;
          if (types.isNotEmpty) {
            final mappedTypes = types.map((type) {
              switch (type) {
                case 'approval':
                  return 'approval_rating';
                case 'multipleChoice':
                  return 'multiple_choice';
                default:
                  return type;
              }
            }).toList();
            baseQuery = baseQuery.filter('type', 'in', '(${mappedTypes.map((t) => '"$t"').join(',')})');
          }
        }
        
        // Apply targeting_type filter based on location mode
        final locationFilter = filters['locationFilter'] as String?;
        if (locationFilter == 'global') {
          // Global mode: show globe, country, and user's city questions
          final userCityId = filters['userCity'] as String?;
          if (userCityId != null) {
            // Include user's city questions along with globe and country questions
            baseQuery = baseQuery.or('targeting_type.in.(globe,country),and(targeting_type.eq.city,city_id.eq.$userCityId)');
            print('🌍 Global mode: targeting_type in (globe, country) OR city_id = $userCityId');
          } else {
            // No user city set, show only globe and country questions
            baseQuery = baseQuery.filter('targeting_type', 'in', '("globe","country")');
            print('🌍 Global mode: targeting_type in (globe, country) - no user city set');
          }
        } else if (locationFilter == 'country' && filters['userCountry'] != null) {
          // Country mode: only show questions addressed to user's country (exclude global)
          final userCountry = filters['userCountry'] as String;
          baseQuery = baseQuery.eq('targeting_type', 'country').eq('country_code', userCountry);
          print('🏳️ Country mode: targeting_type=country AND country_code=$userCountry');
        } else if (locationFilter == 'city' && filters['userCountry'] != null) {
          // City mode: show questions addressed to user's country + city (no globe)
          final userCountry = filters['userCountry'] as String;
          baseQuery = baseQuery.or('and(targeting_type.eq.country,country_code.eq.$userCountry),and(targeting_type.eq.city,country_code.eq.$userCountry)');
          print('🏙️ City mode: targeting_type=country OR city (country_code=$userCountry, no globe)');
        }
      } else {
        baseQuery = baseQuery.eq('nsfw', false);
      }

      // Add pagination
      if (cursor != null) {
        baseQuery = baseQuery.lt('created_at', cursor);
      }

      // Apply ordering based on feed type
      final finalQuery = baseQuery.order('created_at', ascending: false);

      final response = await finalQuery.limit(limit);

      if (response.isEmpty) {
        print('⚠️  No questions found for $feedType feed (questions table)');
        return [];
      }

      // Transform the data to include categories as a simple array
      final processedQuestions = (response as List<dynamic>).map<Map<String, dynamic>>((question) {
        final Map<String, dynamic> processedQuestion = Map<String, dynamic>.from(question as Map<String, dynamic>);
        
        // Transform the nested categories structure into a simple array
        final questionCategories = question['question_categories'] as List<dynamic>? ?? [];
        final categories = questionCategories
          .map((qc) => qc['categories'])
          .where((cat) => cat != null)
          .map((cat) => cat['name'] as String)
          .toList();
        
        processedQuestion['categories'] = categories;
        
        // Map nsfw to is_nsfw for compatibility
        if (processedQuestion.containsKey('nsfw')) {
          processedQuestion['is_nsfw'] = processedQuestion['nsfw'];
        }
        
        // Remove the junction table data as it's no longer needed
        processedQuestion.remove('question_categories');
        
        // Initialize votes to 0 for now
        processedQuestion['votes'] = 0;
        
        return processedQuestion;
      }).toList();

      // Get vote counts in a single batch query
      try {
                final questionIds = processedQuestions
            .map((q) => q['id']?.toString())
            .whereType<String>()
            .toList();
        if (questionIds.isNotEmpty) {
          final voteCounts = await _resultsService.fetchVoteCounts(questionIds);

          for (var question in processedQuestions) {
            final questionId = question['id']?.toString();
            if (questionId != null) {
              question['votes'] = voteCounts[questionId] ?? 0;
            }
          }
        }
      } catch (e) {
        print('ERROR: Failed to fetch vote counts in batch: $e');
      }

      // Apply client-side algorithms for all feed types
      if (feedType == 'trending') {
        _applyTrendingAlgorithm(processedQuestions);
      } else if (feedType == 'popular') {
        _applyPopularAlgorithm(processedQuestions);
      } else if (feedType == 'new') {
        _applyNewAlgorithm(processedQuestions);
      }

      // Apply location boost if enabled AND in city mode only
      final locationFilter = filters?['locationFilter'] as String?;
      final isCityMode = locationFilter == 'city';
      
      if (userService != null && userService.boostLocalActivity && isCityMode) {
        final userCountryCode = filters?['userCountry'] as String?;
        final userCityId = filters?['userCity'] as String?;
        
        await _applyLocationBoost(
          processedQuestions,
          userCountryCode: userCountryCode,
          userCityId: userCityId,
          boostLocalActivity: true,
          feedType: feedType,
          locationFilter: locationFilter,
        );
      } else {
        final reason = locationFilter != 'city' ? 'not city mode' : 
                      userService == null ? 'no user service' :
                      !userService.boostLocalActivity ? 'boost disabled' : 'unknown';
        print('📋 Direct DB: location boost skipped ($reason)');
      }

      // Remove any duplicate questions before returning
      final uniqueQuestions = _removeDuplicateQuestions(processedQuestions);
      return uniqueQuestions;
    }
  }

  // Enhanced trending algorithm using pre-computed values
  void _applyTrendingAlgorithm(List<Map<String, dynamic>> questions) {
    try {
      // PRE-COMPUTE trending scores to avoid expensive operations during sort comparisons
      final precomputedScores = <double>[];
      final now = DateTime.now();
      
      for (int i = 0; i < questions.length; i++) {
        final question = questions[i];
        
        // Pre-compute all values
        final votes = question['votes'] as int? ?? question['vote_count'] as int? ?? 0;
        final timeStr = question['created_at']?.toString() ?? '';
        final questionTime = DateTime.tryParse(timeStr) ?? now;
        final hours = now.difference(questionTime).inHours.toDouble() + 1.0;
        final scopeWeight = double.tryParse(question['scope_weight']?.toString() ?? '1.0') ?? _getDefaultScopeWeight(question['targeting_type']?.toString());
        final isDemo = (question['prompt']?.toString() ?? '').toLowerCase().contains('(demo)');
        
        var score = (votes + 1) / hours * scopeWeight;
        
        if (isDemo) {
          score *= 0.01; // Reduce demo question scores by 99%
        }
        
        precomputedScores.add(score);
      }
      
      // Sort by pre-computed scores
      final indices = List.generate(questions.length, (i) => i);
      indices.sort((a, b) => precomputedScores[b].compareTo(precomputedScores[a]));
      
      // Reorder questions
      final sortedQuestions = indices.map((i) => questions[i]).toList();
      questions.clear();
      questions.addAll(sortedQuestions);
    } catch (e) {
      print('Error applying trending algorithm: $e');
      // If sorting fails, leave in original order
    }
  }

  // Popular algorithm - prioritizes vote count
  void _applyPopularAlgorithm(List<Map<String, dynamic>> questions) {
    try {
      // PRE-COMPUTE popular scores to avoid expensive operations during sort comparisons
      final precomputedData = <Map<String, dynamic>>[];
      final now = DateTime.now();
      
      for (int i = 0; i < questions.length; i++) {
        final question = questions[i];
        
        // Pre-compute all values
        final votes = question['votes'] as int? ?? question['vote_count'] as int? ?? 0;
        final isDemo = (question['prompt']?.toString() ?? '').toLowerCase().contains('(demo)');
        final scopeWeight = double.tryParse(question['scope_weight']?.toString() ?? '1.0') ?? _getDefaultScopeWeight(question['targeting_type']?.toString());
        final timeStr = question['created_at']?.toString() ?? '';
        final questionTime = DateTime.tryParse(timeStr) ?? now;
        
        precomputedData.add({
          'index': i,
          'votes': votes,
          'isDemo': isDemo,
          'scopeWeight': scopeWeight,
          'time': questionTime,
        });
      }
      
      // Sort by pre-computed data
      precomputedData.sort((a, b) {
        // Demo questions ranked lower
        if (a['isDemo'] && !b['isDemo']) return 1;
        if (!a['isDemo'] && b['isDemo']) return -1;
        
        // Primary sort by vote count
        final aVotes = a['votes'] as int;
        final bVotes = b['votes'] as int;
        if (aVotes != bVotes) return bVotes.compareTo(aVotes);
        
        // Secondary sort by scope weight
        final aScopeWeight = a['scopeWeight'] as double;
        final bScopeWeight = b['scopeWeight'] as double;
        if (aScopeWeight != bScopeWeight) return bScopeWeight.compareTo(aScopeWeight);
        
        // Tertiary sort by recency
        final aTime = a['time'] as DateTime;
        final bTime = b['time'] as DateTime;
        return bTime.compareTo(aTime);
      });
      
      // Reorder questions based on sorted indices
      final sortedQuestions = precomputedData.map((data) => questions[data['index'] as int]).toList();
      questions.clear();
      questions.addAll(sortedQuestions);
    } catch (e) {
      print('Error applying popular algorithm: $e');
    }
  }

  // New algorithm - prioritizes recency with optional location grouping
  void _applyNewAlgorithm(List<Map<String, dynamic>> questions) {
    try {
      // PRE-COMPUTE timestamps to avoid expensive operations during sort comparisons
      final precomputedTimes = <DateTime>[];
      final now = DateTime.now();
      
      for (int i = 0; i < questions.length; i++) {
        final question = questions[i];
        final timeStr = question['created_at']?.toString() ?? '';
        final questionTime = DateTime.tryParse(timeStr) ?? now;
        precomputedTimes.add(questionTime);
      }
      
      // Sort by pre-computed timestamps
      final indices = List.generate(questions.length, (i) => i);
      indices.sort((a, b) => precomputedTimes[b].compareTo(precomputedTimes[a]));
      
      // Reorder questions
      final sortedQuestions = indices.map((i) => questions[i]).toList();
      questions.clear();
      questions.addAll(sortedQuestions);
    } catch (e) {
      print('Error applying new algorithm: $e');
    }
  }

  // Helper method to get default scope weight
  double _getDefaultScopeWeight(String? targetingType) {
    switch (targetingType?.toLowerCase()) {
      case 'city':
        return 1.0;
      case 'country':
        return 0.7;
      case 'globe':
      case 'global':
      default:
        return 0.3;
    }
  }

  // Apply geographic filtering for City mode to only show questions from same state/province
  Future<void> _applyCityModeGeographicFiltering(List<Map<String, dynamic>> questions, Map<String, dynamic>? filters) async {
    final userCityId = filters?['userCity'] as String?;
    if (userCityId == null) {
      print('🏙️ City mode filtering: No user city ID, keeping all questions');
      return;
    }

    try {
      // Get user's city data to find their admin2_code
      final userCityData = await _supabase
          .from('cities')
          .select('admin2_code, name, country_code')
          .eq('id', userCityId)
          .single();

      final userAdmin2Code = userCityData['admin2_code'] as String?;
      final userCityName = userCityData['name'] as String?;
      
      if (userAdmin2Code == null) {
        print('🏙️ City mode filtering: No admin2_code for user city, keeping all questions');
        return;
      }

      print('🏙️ City mode filtering: User is in $userCityName (admin2: $userAdmin2Code)');

      // Get all cities in the same county/admin2_code
      final nearbyCitiesData = await _supabase
          .from('cities')
          .select('id')
          .eq('admin2_code', userAdmin2Code)
          .eq('country_code', userCityData['country_code']);

      final nearbyCityIds = nearbyCitiesData.map((city) => city['id'].toString()).toSet();
      print('🏙️ Found ${nearbyCityIds.length} cities in same county (admin2: $userAdmin2Code)');

      // Filter questions to keep only:
      // 1. Country questions (targeting_type = 'country') 
      // 2. City questions from nearby cities only (targeting_type = 'city' AND city_id in nearby cities)
      // NOTE: Globe questions are EXCLUDED in City mode
      final originalCount = questions.length;
      questions.removeWhere((question) {
        final targetingType = question['targeting_type']?.toString();
        final questionCityId = question['city_id']?.toString();

        // Remove globe questions in City mode
        if (targetingType == 'globe') {
          return true; // Remove globe questions
        }
        
        // Keep country questions
        if (targetingType == 'country') {
          return false; // Don't remove
        }

        // For city questions, only keep if they're from nearby cities
        if (targetingType == 'city') {
          final isNearby = questionCityId != null && nearbyCityIds.contains(questionCityId);
          if (!isNearby) {
            final prompt = question['prompt']?.toString() ?? 'no prompt';
            final truncatedPrompt = prompt.length > 50 ? prompt.substring(0, 50) + '...' : prompt;
            print('🚫 Filtering out distant city question: $truncatedPrompt (city_id: $questionCityId)');
          }
          return !isNearby; // Remove if not nearby
        }

        // Unknown targeting type - keep it
        return false;
      });

      final filteredCount = questions.length;
      final removedCount = originalCount - filteredCount;
      
      if (removedCount > 0) {
        print('🏙️ City mode filtering: Removed $removedCount distant city questions, kept $filteredCount questions');
      } else {
        print('🏙️ City mode filtering: All questions were already geographically relevant');
      }

    } catch (e) {
      print('❌ Error applying city mode geographic filtering: $e');
      print('🏙️ Continuing with all questions (no filtering applied)');
    }
  }

  // Apply location boost to Edge Function data (uses pre-fetched location data)
  Future<void> _applyLocationBoostToEdgeData(List<Map<String, dynamic>> questions, {
    String? userCountryCode,
    String? userCityId,
    required String feedType,
    String? locationFilter,
  }) async {
    if (userCountryCode == null && userCityId == null) {
      print('DEBUG: No user location data for boost, applying standard sorting only');
      
      // Apply standard sorting without location boost
      if (feedType == 'trending') {
        _applyTrendingAlgorithm(questions);
      } else if (feedType == 'popular') {
        _applyPopularAlgorithm(questions);
      } else if (feedType == 'new') {
        _applyNewAlgorithm(questions);
      }
      return;
    }
    
    // Get user's admin1_code and admin2_code for regional matching (if city provided)
    String? userAdmin1Code;
    String? userAdmin2Code;
    String? finalUserCountryCode = userCountryCode;
    
    if (userCityId != null) {
      // Use cached user location data to avoid database calls
      final cachedLocationData = _getCachedUserLocationData(userCityId);
      if (cachedLocationData != null) {
        userAdmin1Code = cachedLocationData['admin1_code'];
        userAdmin2Code = cachedLocationData['admin2_code'];
        // Use country from city if not provided
        finalUserCountryCode = finalUserCountryCode ?? cachedLocationData['country_code'];
        print('DEBUG: User location - cityId: $userCityId, admin1: $userAdmin1Code, admin2: $userAdmin2Code, country: $finalUserCountryCode');
      }
    }
    
    if (finalUserCountryCode == null) {
      print('DEBUG: No final country code available for location boost');
      // Apply standard sorting without location boost
      if (feedType == 'trending') {
        _applyTrendingAlgorithm(questions);
      } else if (feedType == 'popular') {
        _applyPopularAlgorithm(questions);
      } else if (feedType == 'new') {
        _applyNewAlgorithm(questions);
      }
      return;
    }
    
    try {
      // PRE-COMPUTE all values to avoid expensive operations during sort comparisons
      final precomputedScores = <double>[];
      
      for (int i = 0; i < questions.length; i++) {
        final question = questions[i];
        
        // Pre-compute base values (avoid repeated calculations)
        final votes = question['vote_count'] as int? ?? 0;
        final hours = (question['hours_since_post'] as num?)?.toDouble() ?? 1.0;
        final scopeWeight = (question['scope_weight'] as num?)?.toDouble() ?? 1.0;
        
        var score = (votes + 1) / hours * scopeWeight;
        
        // Pre-compute location boost (avoid string operations in comparisons)
        final targeting = question['targeting_type']?.toString();
        final questionCityId = question['city_id']?.toString();
        final questionCountryCode = question['country_code']?.toString();
        final isDemo = (question['prompt']?.toString() ?? '').toLowerCase().contains('(demo)');
        
        double matchBoost = 1.0;
        
        if (!isDemo) {
          if (targeting == 'city' && questionCityId == userCityId) {
            matchBoost = 2.0; // City match: highest boost
          } else if (userAdmin2Code != null && questionCityId != null) {
            final questionAdmin2 = question['admin2_code']?.toString();
            if (questionAdmin2 != null && questionAdmin2 == userAdmin2Code) {
              matchBoost = 1.5; // Admin2 match: high boost (county/district level)
            }
          }
          // Check admin1 (state/province) if no admin2 match
          if (matchBoost == 1.0 && userAdmin1Code != null && questionCityId != null) {
            final questionAdmin1 = question['admin1_code']?.toString();
            if (questionAdmin1 != null && questionAdmin1 == userAdmin1Code) {
              matchBoost = 1.2; // Admin1 match: moderate boost (state/province level)
            }
          }
          // Country match gets lowest boost
          if (matchBoost == 1.0 && questionCountryCode == finalUserCountryCode) {
            matchBoost = 1.0; // Country match: no boost (baseline)
          }
        }
        
        score *= matchBoost;
        precomputedScores.add(score);
      }
      
      // Create index array and sort by pre-computed scores (much faster)
      final indices = List.generate(questions.length, (i) => i);
      indices.sort((a, b) => precomputedScores[b].compareTo(precomputedScores[a]));
      
      // Reorder questions based on sorted indices
      final sortedQuestions = indices.map((i) => questions[i]).toList();
      questions.clear();
      questions.addAll(sortedQuestions);
      
      print('Applied location boost to Edge Function data for ${questions.length} questions');
    } catch (e) {
      print('Error applying location boost to Edge Function data: $e');
      // If boost fails, apply standard sorting
      if (feedType == 'trending') {
        _applyTrendingAlgorithm(questions);
      } else if (feedType == 'popular') {
        _applyPopularAlgorithm(questions);
      } else if (feedType == 'new') {
        _applyNewAlgorithm(questions);
      }
    }
  }

  // Apply location boost to questions if enabled (for direct DB calls)
  Future<void> _applyLocationBoost(List<Map<String, dynamic>> questions, {
    String? userCountryCode,
    String? userCityId,
    bool boostLocalActivity = false,
    String feedType = 'trending', // Add feedType parameter
    String? locationFilter,
  }) async {
    if (!boostLocalActivity) {
      print('DEBUG: Location boost disabled via setting');
      return;
    }
    
    // If no country code but we have a city ID, try to get the country from the city
    String? finalUserCountryCode = userCountryCode;
    if (finalUserCountryCode == null && userCityId != null) {
      final cachedLocationData = _getCachedUserLocationData(userCityId);
      if (cachedLocationData != null) {
        finalUserCountryCode = cachedLocationData['country_code'];
        print('DEBUG: Fetched country code from cached city data: $finalUserCountryCode');
      }
    }
    
    if (finalUserCountryCode == null) {
      print('DEBUG: No country code available for location boost');
      return;
    }
    
    try {
      // Get user's admin1_code and admin2_code for regional matching using cached data
      String? userAdmin1Code;
      String? userAdmin2Code;
      if (userCityId != null) {
        final cachedLocationData = _getCachedUserLocationData(userCityId);
        if (cachedLocationData != null) {
          userAdmin1Code = cachedLocationData['admin1_code'];
          userAdmin2Code = cachedLocationData['admin2_code'];
        }
      }
      
      // Note: For Edge Function data, admin2_code should already be included
      // For fallback queries, we'll skip admin2 matching to avoid database calls
      print('DEBUG: Skipping admin2 database lookup - should use Edge Function with pre-fetched data');
      
      // PRE-COMPUTE all values to avoid expensive operations during sort comparisons (fallback version)
      final precomputedScores = <double>[];
      
      for (int i = 0; i < questions.length; i++) {
        final question = questions[i];
        
        // Pre-compute base values
        final votes = question['vote_count'] as int? ?? 0;
        final hours = double.tryParse(question['hours_since_post']?.toString() ?? '1') ?? 1.0;
        final scopeWeight = double.tryParse(question['scope_weight']?.toString() ?? '1.0') ?? 1.0;
        
        var score = (votes + 1) / hours * scopeWeight;
        
        // Pre-compute location boost
        final targeting = question['targeting_type']?.toString();
        final questionCityId = question['city_id']?.toString();
        final questionCountryCode = question['country_code']?.toString();
        final isDemo = (question['prompt']?.toString() ?? '').toLowerCase().contains('(demo)');
        
        double matchBoost = 1.0;
        
        if (!isDemo) {
          if (targeting == 'city' && questionCityId == userCityId) {
            matchBoost = 2.0; // City match: highest boost
          } else if (userAdmin2Code != null && questionCityId != null) {
            final questionAdmin2 = question['admin2_code']?.toString();
            if (questionAdmin2 != null && questionAdmin2 == userAdmin2Code) {
              matchBoost = 1.5; // Admin2 match: high boost (county/district level)
            }
          }
          // Check admin1 (state/province) if no admin2 match
          if (matchBoost == 1.0 && userAdmin1Code != null && questionCityId != null) {
            final questionAdmin1 = question['admin1_code']?.toString();
            if (questionAdmin1 != null && questionAdmin1 == userAdmin1Code) {
              matchBoost = 1.2; // Admin1 match: moderate boost (state/province level)
            }
          }
          // Country match gets no additional boost (baseline)
          if (matchBoost == 1.0 && questionCountryCode == finalUserCountryCode) {
            matchBoost = 1.0; // Country match: no boost (baseline)
          }
          
          // Check for mentioned countries (legacy boost)
          final mentions = question['mentioned_countries'] as List<dynamic>? ?? [];
          if (mentions.any((country) => country.toString().toLowerCase().contains(finalUserCountryCode?.toLowerCase() ?? ''))) {
            matchBoost *= 1.1; // Small additional boost for mentioned countries
          }
        }
        
        score *= matchBoost;
        precomputedScores.add(score);
      }
      
      // Create index array and sort by pre-computed scores (much faster)
      final indices = List.generate(questions.length, (i) => i);
      indices.sort((a, b) => precomputedScores[b].compareTo(precomputedScores[a]));
      
      // Reorder questions based on sorted indices
      final sortedQuestions = indices.map((i) => questions[i]).toList();
      questions.clear();
      questions.addAll(sortedQuestions);
      
      print('Applied location boost with admin2 matching to ${questions.length} questions');
    } catch (e) {
      print('Error applying location boost: $e');
      // If boost fails, leave in original order
    }
    
    // Add summary debug info for popular feed
    if (feedType == 'popular') {
      final lowVoteQuestions = questions.where((q) => (q['vote_count'] as int? ?? 0) < 3).length;
      print('DEBUG: Popular feed - $lowVoteQuestions questions with <3 votes (no location boost applied)');
    }
  }

  // Update response counts for a specific list of questions
  Future<void> _updateQuestionResponseCountsForList(List<Map<String, dynamic>> questions) async {
    try {
            // One batched call for the whole list, instead of a query per question.
      final ids = questions
          .map((q) => q['id']?.toString())
          .whereType<String>()
          .toList();
      final counts = await _resultsService.fetchVoteCounts(ids);
      for (var i = 0; i < questions.length; i++) {
        final questionId = questions[i]['id']?.toString();
        questions[i]['votes'] = questionId == null ? 0 : (counts[questionId] ?? 0);
      }
    } catch (e) {
      print('Error updating response counts for question list: $e');
      
      // Initialize votes to 0 if not set
      for (var i = 0; i < questions.length; i++) {
        if (questions[i]['votes'] == null) {
          questions[i]['votes'] = 0;
        }
      }
    }
  }

  // Apply simple sorting algorithm for trending/popular feeds
  void _applySortingAlgorithm(List<Map<String, dynamic>> questions, String feedType) {
    try {
      if (feedType == 'trending') {
        // Simple trending algorithm: recent activity with vote boost
        questions.sort((a, b) {
          final aVotes = a['votes'] as int? ?? 0;
          final bVotes = b['votes'] as int? ?? 0;
          final aTime = DateTime.tryParse(a['created_at'] ?? '') ?? DateTime.now();
          final bTime = DateTime.tryParse(b['created_at'] ?? '') ?? DateTime.now();
          
          final hoursA = DateTime.now().difference(aTime).inHours + 1;
          final hoursB = DateTime.now().difference(bTime).inHours + 1;
          
          final scoreA = (aVotes + 1) / hoursA;
          final scoreB = (bVotes + 1) / hoursB;
          
          return scoreB.compareTo(scoreA);
        });
      } else if (feedType == 'popular') {
        // Popular algorithm: sort by vote count
        questions.sort((a, b) {
          final aVotes = a['votes'] as int? ?? 0;
          final bVotes = b['votes'] as int? ?? 0;
          return bVotes.compareTo(aVotes);
        });
      }
    } catch (e) {
      print('Error applying sorting algorithm: $e');
      // If sorting fails, leave in chronological order
    }
  }

  // Preload feeds in background for instant switching
  Future<void> preloadAllFeeds({Map<String, dynamic>? filters, UserService? userService}) async {
    final feedTypes = ['trending', 'popular', 'new'];
    
    for (final feedType in feedTypes) {
      if (_backgroundLoadingFeeds[feedType] == true) {
        continue; // Already loading
      }
      
      _backgroundLoadingFeeds[feedType] = true;
      
      // Load in background without blocking UI
      fetchOptimizedFeed(
        feedType: feedType,
        filters: filters,
        useCache: false, // Force fresh data for preload
        userService: userService, // Pass userService for location boost
      ).then((_) {
        _backgroundLoadingFeeds[feedType] = false;
        print('Background preload completed for $feedType feed');
      }).catchError((e) {
        _backgroundLoadingFeeds[feedType] = false;
        print('Background preload failed for $feedType feed: $e');
      });
    }
  }

  // Clear feed cache when needed
  void clearFeedCache() {
    _feedCache.clear();
    _feedCacheTimestamps.clear();
    print('Feed cache cleared');
  }
  
  // Pre-cache user location data when user selects a city
  Future<void> precacheUserLocationData(String? userCityId) async {
    if (userCityId != null) {
      print('DEBUG: Pre-caching user location data for cityId: $userCityId');
      await _fetchAndCacheUserLocationData(userCityId);
    }
  }
  
  // Initialize user location cache in background (call this when app starts)
  Future<void> initializeUserLocationCache(String? userCityId) async {
    if (userCityId != null && _cachedUserLocationData == null) {
      print('DEBUG: Initializing user location cache in background...');
      // Run in background without awaiting to avoid blocking
      _fetchAndCacheUserLocationData(userCityId).then((_) {
        print('DEBUG: User location cache initialized');
      }).catchError((e) {
        print('DEBUG: Failed to initialize user location cache: $e');
      });
    }
  }
  
  // Populate location cache from LocationService data (fast, no database call)
  void populateLocationCacheFromService(String cityId, String countryCode, String? admin2Code) {
    _cachedUserLocationData = {
      'cityId': cityId,
      'admin2_code': admin2Code,
      'country_code': countryCode,
    };
    _userLocationCacheTimestamp = DateTime.now();
    print('DEBUG: Populated location cache from LocationService - cityId: $cityId, country: $countryCode, admin2: $admin2Code');
  }
  
  // Clear user location cache when user changes city
  void clearUserLocationCache() {
    _cachedUserLocationData = null;
    _userLocationCacheTimestamp = null;
    print('DEBUG: User location cache cleared');
  }
  
  // Temporary method to fetch engagement data until Edge Function is updated to use v3
  Future<void> enrichQuestionsWithEngagementData(List<Map<String, dynamic>> questions) async {
    if (questions.isEmpty) return;
    
    // Get question IDs
    final questionIds = questions.map((q) => q['id'].toString()).toList();
    
    // Filter out invalid UUIDs that cause query failures
    final validQuestionIds = questionIds.where((id) {
      // Basic UUID format check (36 characters with hyphens in right places)
      return id.length == 36 && 
             id.split('-').length == 5 &&
             !id.startsWith('test-');
    }).toList();
    
    try {
      
      print('🔍 Enriching ${questionIds.length} questions with engagement data (${validQuestionIds.length} valid UUIDs)');
      
      if (validQuestionIds.isEmpty) {
        print('⚠️ No valid UUIDs found in question IDs, skipping v3 view query');
      }
      
      final engagementData = validQuestionIds.isNotEmpty ? await _supabase
          .from('feed_questions_optimized_v3')
          .select('id, comment_count, reaction_count, reactions, top_emoji')
          .inFilter('id', validQuestionIds) : <Map<String, dynamic>>[];
      
      print('📊 Got engagement data for ${engagementData.length} questions from feed_questions_optimized_v3');
      
      // Debug: Show sample of what we're getting from the view
      if (engagementData.isNotEmpty) {
        final sample = engagementData.first;
        print('📋 Sample engagement data: $sample');
      }
      
      if (engagementData.isEmpty) {
        print('⚠️ No engagement data from v3 view, trying fallback...');
        // Fallback: Try to get comment counts directly from comments table
        try {
          final commentCounts = await _supabase
              .from('comments')
              .select('question_id')
              .inFilter('question_id', questionIds)
              .eq('is_hidden', false);
              
          // Count comments per question
          final commentCountMap = <String, int>{};
          for (final comment in commentCounts) {
            final questionId = comment['question_id'].toString();
            commentCountMap[questionId] = (commentCountMap[questionId] ?? 0) + 1;
          }
          
          // Apply comment counts to questions
          for (final question in questions) {
            final questionId = question['id'].toString();
            question['comment_count'] = commentCountMap[questionId] ?? 0;
            
            if (!validQuestionIds.contains(questionId)) {
              question['reaction_count'] = 0;
              question['reactions'] = {};
            }
          }
          
          print('✅ Applied fallback comment counts to questions');
          notifyListeners(); // Notify UI to rebuild with new reactions data
          return;
        } catch (e) {
          print('❌ Fallback comment query failed: $e');
        }
        
        return;
      }
      
      // Create a map for quick lookup
      final engagementMap = <String, Map<String, dynamic>>{};
      for (final item in engagementData) {
        engagementMap[item['id'].toString()] = item;
      }
      
      // Enrich questions with engagement data
      for (final question in questions) {
        final questionId = question['id'].toString();
        final engagement = engagementMap[questionId];
        
        if (engagement != null) {
          final commentCount = engagement['comment_count'] ?? 0;
          question['comment_count'] = commentCount;
          question['reaction_count'] = engagement['reaction_count'] ?? 0;
          question['reactions'] = engagement['reactions'] ?? {};
          question['top_emoji'] = engagement['top_emoji']; // Include pre-computed top emoji
          
          print('📊 Question ${questionId.substring(0, 8)} enriched with: reactions=${engagement['reactions']}, top_emoji=${engagement['top_emoji']}');
        }
      }
      
      print('✅ Applied engagement data from v3 view to questions');
      notifyListeners(); // Notify UI to rebuild with new engagement data
      
    } catch (e) {
      print('❌ Error fetching engagement data: $e');
    }
  }

  // Get cached feed if available, otherwise fetch via optimized Edge Function
  Future<List<Map<String, dynamic>>> getFeed({
    required String feedType,
    Map<String, dynamic>? filters,
    bool forceRefresh = false,
    UserService? userService,
    int offset = 0, // Add offset support for pagination
  }) async {
    if (forceRefresh) {
      // Clear cache to force fresh data from Edge Function
      final boostState = userService?.boostLocalActivity ?? false;
      final cacheKey = '${feedType}_${filters?.hashCode ?? 'default'}_boost_${boostState}_offset_$offset';
      _feedCache.remove(cacheKey);
      _feedCacheTimestamps.remove(cacheKey);
      print('🔄 Cleared cache for fresh Edge Function data (offset: $offset)');
    }
    
    return await fetchOptimizedFeed(
      feedType: feedType,
      filters: filters,
      useCache: !forceRefresh,
      userService: userService,
      forceRefresh: forceRefresh,
      offset: offset, // Pass offset for pagination
    );
  }



  // Method to update questions list (used by optimized feeds)
  void updateQuestions(List<Map<String, dynamic>> newQuestions, {bool notify = true}) {
    _questions = newQuestions;
    
    // Skip update prefetch - responses will be loaded on-demand when user browses
    // This improves performance by avoiding blocking database queries
    
    if (notify) {
      notifyListeners();
    }
  }

  // Unified client-side sorting method for all feed types
  Future<List<Map<String, dynamic>>> applySortingAlgorithm(
    List<Map<String, dynamic>> questions,
    String feedType,
    UserService userService,
    LocationService locationService,
    Map<String, dynamic>? filters,
  ) async {
    print('DEBUG: Applying $feedType sorting to ${questions.length} questions');
    
    // Create a copy to avoid modifying the original
    final sortedQuestions = List<Map<String, dynamic>>.from(questions);
    
    // Apply the appropriate sorting algorithm
    switch (feedType) {
      case 'trending':
        _applyTrendingAlgorithm(sortedQuestions);
        break;
      case 'popular':
        _applyPopularAlgorithm(sortedQuestions);
        break;
      case 'new':
        _applyNewAlgorithm(sortedQuestions);
        break;
      default:
        print('WARNING: Unknown feed type $feedType, defaulting to new');
        _applyNewAlgorithm(sortedQuestions);
    }
    
    // Apply location boost if enabled AND in city mode only
    final locationFilter = filters?['locationFilter'] as String?;
    final isCityMode = locationFilter == 'city';
    
    if (userService.boostLocalActivity && isCityMode) {
      final userCountryCode = filters?['userCountry'] as String?;
      final userCityId = filters?['userCity'] as String?;
      
      print('DEBUG: Applying location boost for $feedType feed');
      await _applyLocationBoost(
        sortedQuestions,
        userCountryCode: userCountryCode,
        userCityId: userCityId,
        boostLocalActivity: true,
        feedType: feedType,
        locationFilter: locationFilter,
      );
    } else {
      final reason = locationFilter != 'city' ? 'not city mode' : 
                    !userService.boostLocalActivity ? 'boost disabled' : 'unknown';
      print('📋 Legacy feed: location boost skipped ($reason)');
    }
    
    print('DEBUG: $feedType sorting completed');
    return sortedQuestions;
  }

  // Check if the current user is the author of a question
  bool isCurrentUserAuthor(Map<String, dynamic> question) {
    final currentUser = _supabase.auth.currentUser;
    if (currentUser == null) return false;
    
    final authorId = question['author_id']?.toString();
    return authorId != null && authorId == currentUser.id;
  }

  // Delete (hide) a question - soft delete by setting is_hidden to true
  Future<bool> deleteQuestion(String questionId) async {
    try {
      final currentUser = _supabase.auth.currentUser;
      if (currentUser == null) {
        throw Exception('User must be authenticated to delete questions');
      }

      print('Attempting to delete question: $questionId');

      // Update the question to set is_hidden = true (soft delete)
      final response = await _supabase
          .from('questions')
          .update({'is_hidden': true})
          .eq('id', questionId)
          .eq('author_id', currentUser.id) // Ensure only author can delete
          .select('id');

      if (response == null || response.isEmpty) {
        throw Exception('Failed to delete question - either question not found or you are not the author');
      }

      print('Question successfully hidden in database: $questionId');

      // Trigger materialized view refresh to update feeds
      try {
        await refreshMaterializedView();
        print('Materialized view refresh triggered after question deletion');
      } catch (e) {
        print('Warning: Failed to refresh materialized view after deletion: $e');
        // Don't fail the entire deletion if MV refresh fails
      }

      // Remove from local questions list
      _questions.removeWhere((q) => q['id'].toString() == questionId);
      
      // If this was the Question of the Day, clear it
      if (_questionOfTheDay != null && _questionOfTheDay!['id'].toString() == questionId) {
        _questionOfTheDay = null;
        _selectNewQotDDueToModeration(); // Select a new QotD
      }
      
      notifyListeners();
      return true;

    } catch (e) {
      print('Error deleting question: $e');
      return false;
    }
  }

  // Check if questions are hidden by their IDs
  Future<Set<String>> getHiddenQuestionIds(List<String> questionIds) async {
    if (questionIds.isEmpty) return {};
    
    try {
      // Filter out non-UUID IDs to avoid database errors
      final validUuids = questionIds.where((id) => _isUuid(id)).toList();
      
      if (validUuids.isEmpty) {
        print('DEBUG: getHiddenQuestionIds - No valid UUIDs found in: $questionIds');
        return {}; // No valid UUIDs to check
      }
      
      print('DEBUG: getHiddenQuestionIds - Checking ${validUuids.length} valid UUIDs');
      
      // Process in batches to avoid SQL query limits
      const batchSize = 100;
      final Set<String> allHiddenIds = {};
      
      for (int i = 0; i < validUuids.length; i += batchSize) {
        final batch = validUuids.skip(i).take(batchSize).toList();
        print('DEBUG: getHiddenQuestionIds - Processing batch ${(i ~/ batchSize) + 1} with ${batch.length} IDs');
        
        final response = await _supabase
            .from('questions')
            .select('id')
            .eq('is_hidden', true)
            .filter('id', 'in', '(${batch.map((id) => '"$id"').join(',')})');
        
        final batchHiddenIds = response.map((q) => q['id'].toString()).toSet();
        allHiddenIds.addAll(batchHiddenIds);
        print('DEBUG: getHiddenQuestionIds - Batch returned ${batchHiddenIds.length} hidden IDs');
      }
      
      print('DEBUG: getHiddenQuestionIds - Total hidden IDs found: ${allHiddenIds.length}');
      return allHiddenIds;
    } catch (e) {
      print('Error checking hidden question IDs: $e');
      return {};
    }
  }

  // Check which questions exist in the database by their IDs
  Future<Set<String>> getExistingQuestionIds(List<String> questionIds) async {
    if (questionIds.isEmpty) return {};
    
    try {
      // Filter out non-UUID IDs to avoid database errors
      final validUuids = questionIds.where((id) => _isUuid(id)).toList();
      
      if (validUuids.isEmpty) {
        // print('DEBUG: getExistingQuestionIds - No valid UUIDs found in batch');
        return {}; // No valid UUIDs to check
      }
      
      // print('DEBUG: getExistingQuestionIds - Checking ${validUuids.length} valid UUIDs');
      
      // Process in batches to avoid SQL query limits
      const batchSize = 100;
      final Set<String> allExistingIds = {};
      
      for (int i = 0; i < validUuids.length; i += batchSize) {
        final batch = validUuids.skip(i).take(batchSize).toList();
        // print('DEBUG: getExistingQuestionIds - Processing batch ${(i ~/ batchSize) + 1} with ${batch.length} IDs');
        
        final response = await _supabase
            .from('questions')
            .select('id')
            .filter('id', 'in', '(${batch.map((id) => '"$id"').join(',')})');
        
        final batchExistingIds = response.map((q) => q['id'].toString()).toSet();
        allExistingIds.addAll(batchExistingIds);
        // print('DEBUG: getExistingQuestionIds - Batch returned ${batchExistingIds.length} existing IDs');
      }
      
      print('DEBUG: getExistingQuestionIds - Total existing IDs found: ${allExistingIds.length} from ${validUuids.length} checked');
      return allExistingIds;
    } catch (e) {
      print('Error checking existing question IDs: $e');
      return {};
    }
  }

  // Helper function to get a user-friendly country name fallback
  String _getCountryNameFallback(String countryCode) {
    // Common country codes with user-friendly names
    final commonCountries = {
      'US': 'United States',
      'GB': 'United Kingdom', 
      'CA': 'Canada',
      'AU': 'Australia',
      'DE': 'Germany',
      'FR': 'France',
      'IT': 'Italy',
      'ES': 'Spain',
      'JP': 'Japan',
      'CN': 'China',
      'IN': 'India',
      'BR': 'Brazil',
      'MX': 'Mexico',
      'RU': 'Russia',
      'ZA': 'South Africa',
      'KR': 'South Korea',
      'NL': 'Netherlands',
      'SE': 'Sweden',
      'NO': 'Norway',
      'DK': 'Denmark',
      'FI': 'Finland',
      'CH': 'Switzerland',
      'AT': 'Austria',
      'BE': 'Belgium',
      'IE': 'Ireland',
      'PT': 'Portugal',
      'GR': 'Greece',
      'TR': 'Turkey',
      'PL': 'Poland',
      'CZ': 'Czech Republic',
      'HU': 'Hungary',
      'RO': 'Romania',
      'BG': 'Bulgaria',
      'HR': 'Croatia',
      'SI': 'Slovenia',
      'SK': 'Slovakia',
      'LT': 'Lithuania',
      'LV': 'Latvia',
      'EE': 'Estonia',
      'AR': 'Argentina',
      'CL': 'Chile',
      'CO': 'Colombia',
      'PE': 'Peru',
      'VE': 'Venezuela',
      'UY': 'Uruguay',
      'PY': 'Paraguay',
      'BO': 'Bolivia',
      'EC': 'Ecuador',
      'TH': 'Thailand',
      'MY': 'Malaysia',
      'SG': 'Singapore',
      'ID': 'Indonesia',
      'PH': 'Philippines',
      'VN': 'Vietnam',
      'BD': 'Bangladesh',
      'PK': 'Pakistan',
      'LK': 'Sri Lanka',
      'NP': 'Nepal',
      'MM': 'Myanmar',
      'KH': 'Cambodia',
      'LA': 'Laos',
      'EG': 'Egypt',
      'MA': 'Morocco',
      'DZ': 'Algeria',
      'TN': 'Tunisia',
      'LY': 'Libya',
      'SD': 'Sudan',
      'ET': 'Ethiopia',
      'KE': 'Kenya',
      'TZ': 'Tanzania',
      'UG': 'Uganda',
      'RW': 'Rwanda',
      'GH': 'Ghana',
      'NG': 'Nigeria',
      'SN': 'Senegal',
      'CI': 'Ivory Coast',
      'ML': 'Mali',
      'BF': 'Burkina Faso',
      'NE': 'Niger',
      'TD': 'Chad',
      'CM': 'Cameroon',
      'CF': 'Central African Republic',
      'CG': 'Republic of the Congo',
      'CD': 'Democratic Republic of the Congo',
      'AO': 'Angola',
      'ZM': 'Zambia',
      'ZW': 'Zimbabwe',
      'BW': 'Botswana',
      'NA': 'Namibia',
      'SZ': 'Eswatini',
      'LS': 'Lesotho',
      'MG': 'Madagascar',
      'MU': 'Mauritius',
      'SC': 'Seychelles',
      'IL': 'Israel',
      'PS': 'Palestine',
      'JO': 'Jordan',
      'LB': 'Lebanon',
      'SY': 'Syria',
      'IQ': 'Iraq',
      'IR': 'Iran',
      'SA': 'Saudi Arabia',
      'AE': 'United Arab Emirates',
      'QA': 'Qatar',
      'BH': 'Bahrain',
      'KW': 'Kuwait',
      'OM': 'Oman',
      'YE': 'Yemen',
      'AF': 'Afghanistan',
      'UZ': 'Uzbekistan',
      'KZ': 'Kazakhstan',
      'KG': 'Kyrgyzstan',
      'TJ': 'Tajikistan',
      'TM': 'Turkmenistan',
      'MN': 'Mongolia',
      'NZ': 'New Zealand',
      'FJ': 'Fiji',
      'PG': 'Papua New Guinea',
      'SB': 'Solomon Islands',
      'VU': 'Vanuatu',
      'NC': 'New Caledonia',
      'PF': 'French Polynesia',
      'WS': 'Samoa',
      'TO': 'Tonga',
      'KI': 'Kiribati',
      'TV': 'Tuvalu',
      'NR': 'Nauru',
      'PW': 'Palau',
      'FM': 'Micronesia',
      'MH': 'Marshall Islands',
    };
    
    return commonCountries[countryCode.toUpperCase()] ?? countryCode;
  }

  // Get complete question data by ID from database
  Future<Map<String, dynamic>?> getQuestionById(String questionId) async {
    // Use request deduplication to prevent multiple concurrent fetches of the same question
    final requestKey = 'question_by_id_$questionId';
    
    return _deduplicationService.deduplicateRequest<Map<String, dynamic>?>(
      requestKey, 
      () async {
        try {
          print('Fetching question by ID: $questionId');
          
          // Query the database for the complete question data
          final response = await _supabase
              .from('questions')
              .select('''
                *,
                question_options (
                  id,
                  option_text,
                  sort_order
                ),
                question_categories (
                  categories (
                    name
                  )
                )
              ''')
              .eq('id', questionId)
              .eq('is_hidden', false) // Only fetch non-hidden questions
              .single();

          if (response == null) {
            print('Question not found: $questionId');
            return null;
          }

          // Process the response to match the expected format
          final question = Map<String, dynamic>.from(response);
          
          // Extract categories from the nested structure
          final categoriesData = question['question_categories'] as List<dynamic>?;
          if (categoriesData != null) {
            question['categories'] = categoriesData
                .map((cat) => cat['categories']['name'] as String)
                .toList();
          } else {
            question['categories'] = <String>[];
          }
          
          // Remove the nested structure we don't need
          question.remove('question_categories');
          
                    // Get the current answer count from the results RPC
          question['votes'] = await _resultsService.fetchTotalCount(questionId);
          
          // Ensure consistent field naming
          if (question['prompt'] == null && question['title'] != null) {
            question['prompt'] = question['title'];
          }
          
          // print('Successfully fetched question: ${question['prompt']} with ${question['votes']} votes');  // Commented out excessive logging
          return question;

        } catch (e) {
          print('Error fetching question by ID: $e');
          return null;
        }
      },
      cacheDuration: Duration(minutes: 1), // Cache question data for 1 minute during initialization
    );
  }

  // Batch fetch multiple questions by IDs - optimized for subscribed questions
  Future<List<Map<String, dynamic>>> getQuestionsByIds(List<String> questionIds, {bool includeHidden = false}) async {
    if (questionIds.isEmpty) return [];
    
    // Use request deduplication with a sorted key for consistent caching
    final sortedIds = List<String>.from(questionIds)..sort();
    final requestKey = 'questions_batch_${sortedIds.join('_')}_hidden_$includeHidden';
    
    return _deduplicationService.deduplicateRequest<List<Map<String, dynamic>>>(
      requestKey,
      () async {
        try {
          print('🔄 Batch fetching ${questionIds.length} questions: $questionIds');
          print('DEBUG: getQuestionsByIds - includeHidden: $includeHidden');
          
          // Process in batches for very large lists to avoid query limits
          const batchSize = 100;
          List<Map<String, dynamic>> allQuestions = [];
          
          for (int i = 0; i < questionIds.length; i += batchSize) {
            final batch = questionIds.skip(i).take(batchSize).toList();
            print('DEBUG: getQuestionsByIds - Processing batch ${(i ~/ batchSize) + 1} with ${batch.length} IDs');
            
            // Fetch questions in current batch
            var queryBuilder = _supabase
                .from('questions')
                .select('''
                  *,
                  question_options (
                    id,
                    option_text,
                    sort_order
                  ),
                  question_categories (
                    categories (
                      name
                    )
                  )
                ''')
                .inFilter('id', batch);
            
            // Conditionally filter hidden questions
            if (!includeHidden) {
              queryBuilder = queryBuilder.eq('is_hidden', false);
            }
            
            final batchResponse = await queryBuilder;
            if (batchResponse != null && batchResponse.isNotEmpty) {
              allQuestions.addAll(batchResponse);
              print('DEBUG: getQuestionsByIds - Batch returned ${batchResponse.length} questions');
            }
          }
          
          final response = allQuestions;

          if (response == null || response.isEmpty) {
            print('❌ No questions found for IDs: $questionIds');
            return [];
          }

                    // Batch fetch vote counts for all questions (the service chunks)
          final Map<String, int> voteCounts =
              await _resultsService.fetchVoteCounts(questionIds);
          
          
          // Batch fetch comment counts for all questions (also process in batches)
          final Map<String, int> commentCounts = {};
          
          for (int i = 0; i < questionIds.length; i += batchSize) {
            final batch = questionIds.skip(i).take(batchSize).toList();
            
            final commentCountsQuery = await _supabase
                .from('comments')
                .select('question_id, id')
                .inFilter('question_id', batch)
                .eq('is_hidden', false);

            // Group comment counts by question_id for this batch
            if (commentCountsQuery != null) {
              for (final comment in commentCountsQuery) {
                final questionId = comment['question_id'] as String;
                commentCounts[questionId] = (commentCounts[questionId] ?? 0) + 1;
              }
            }
          }

          // Process all questions
          final questions = <Map<String, dynamic>>[];
          for (final item in response) {
            final question = Map<String, dynamic>.from(item);
            
            // Extract categories from the nested structure
            final categoriesData = question['question_categories'] as List<dynamic>?;
            if (categoriesData != null) {
              question['categories'] = categoriesData
                  .map((cat) => cat['categories']['name'] as String)
                  .toList();
            } else {
              question['categories'] = <String>[];  
            }
            
            // Remove the nested structure we don't need
            question.remove('question_categories');
            
            // Set vote count from our batch query
            final questionId = question['id'] as String;
            question['votes'] = voteCounts[questionId] ?? 0;
            
            // Set comment count from our batch query
            question['comment_count'] = commentCounts[questionId] ?? 0;
            
            // Ensure consistent field naming
            if (question['prompt'] == null && question['title'] != null) {
              question['prompt'] = question['title'];
            }
            
            questions.add(question);
          }
          
          print('✅ Successfully batch fetched ${questions.length} questions with vote and comment counts');
          return questions;

        } catch (e) {
          print('❌ Error batch fetching questions: $e');
          return [];
        }
      },
      cacheDuration: Duration(minutes: 1), // Cache batch data for 1 minute during initialization
    );
  }

  // Refresh the materialized view via Edge Function after successful question submission
  Future<void> refreshMaterializedView() async {
    try {
      print('🔄 Triggering materialized view refresh via Edge Function...');
      
      // Build Edge Function URL (same pattern as existing edge function calls)
      final baseUrl = _supabase.rest.url.replaceAll('/rest/v1', '');
      final uri = Uri.parse('$baseUrl/functions/v1/refresh_feed_mv-ts');
      
      // Get current user session token for authentication
      final session = _supabase.auth.currentSession;
      if (session == null) {
        print('⚠️ No auth session available for materialized view refresh');
        return;
      }
      
      // Use same authentication pattern as existing edge function calls
      final requestHeaders = <String, String>{
        'Authorization': 'Bearer ${session.accessToken}',
        'Content-Type': 'application/json',
      };
      
      print('🔗 Edge Function URL: $uri');
      
      // Make HTTP request to Edge Function
      final response = await http.post(uri, headers: requestHeaders);
      
      if (response.statusCode == 200) {
        print('✅ Materialized view refresh triggered successfully');
        
        // Clear feed cache to ensure fresh data on next load
        _feedCache.clear();
        _feedCacheTimestamps.clear();
        print('🗑️ Feed cache cleared to ensure fresh data');
      } else if (response.statusCode == 429) {
        print('⏳ Materialized view refresh debounced - please wait before triggering another refresh');
      } else {
        print('⚠️ Materialized view refresh failed: ${response.statusCode} - ${response.body}');
      }
    } catch (e) {
      print('❌ Error refreshing materialized view: $e');
      // Don't throw - this is a nice-to-have optimization, not critical
    }
  }

  /// Lean question search for pickers: the friend-chat forward picker and the
  /// comment composer's `?:` mention. One request, four fields per row.
  ///
  /// Reads `question_feed_scores` (every non-hidden, non-private question ever
  /// posted, seeds only after their QOTD debut) which carries a precomputed
  /// `vote_count`, so there is no per-row counts round trip. The old path went
  /// through the Archive's `searchQuestions`, which fetched up to 200 full
  /// rows and then made two sequential requests per row for counts the picker
  /// never showed — a hundred-plus round trips to display ten rows.
  ///
  /// Matches the prompt or description (case-insensitive substring), most
  /// answered first, newest breaking ties. [excludePrivate] is kept for the
  /// call sites' sake; the view never contains private questions.
  Future<List<Map<String, dynamic>>> searchQuestionsForAutocomplete(
    String query, {
    int limit = 10,
    bool includeNSFW = false,
    bool excludePrivate = false,
  }) async {
    final needle = query.trim();
    if (needle.isEmpty) return [];

    // PostgREST parses the `or=` filter itself, so the user's text is quoted
    // and stripped of the two characters that could end the quote early.
    // `%` and `_` are LIKE wildcards; matching a little loosely on those is
    // harmless in a picker.
    final safe = needle.replaceAll(RegExp(r'[\\"]'), '');
    if (safe.isEmpty) return [];
    final pattern = '"%$safe%"';

    try {
      var request = _supabase
          .from('question_feed_scores')
          .select('id, prompt, type, vote_count')
          .eq('is_hidden', false)
          .or('prompt.ilike.$pattern,description.ilike.$pattern');
      if (!includeNSFW) {
        request = request.eq('nsfw', false);
      }
      final response = await request
          .order('vote_count', ascending: false)
          .order('created_at', ascending: false)
          .limit(limit);

      return [
        for (final row in response)
          {
            'id': row['id'],
            'prompt': row['prompt'],
            'type': row['type'],
            'votes': (row['vote_count'] as num?)?.toInt() ?? 0,
          }
      ];
    } catch (e) {
      print('Autocomplete search failed: $e');
      return [];
    }
  }

  /// Remove duplicate questions by ID, keeping the first occurrence
  List<Map<String, dynamic>> _removeDuplicateQuestions(List<Map<String, dynamic>> questions) {
    final seenIds = <String>{};
    final uniqueQuestions = <Map<String, dynamic>>[];
    
    for (final question in questions) {
      final id = question['id']?.toString();
      if (id != null && !seenIds.contains(id)) {
        seenIds.add(id);
        uniqueQuestions.add(question);
      }
    }
    
    if (uniqueQuestions.length < questions.length) {
      print('🧹 Removed ${questions.length - uniqueQuestions.length} duplicate questions');
    }
    
    return uniqueQuestions;
  }
}

// Event notification system for vote count updates
class VoteCountUpdateEvent {
  static final List<Function(String)> _listeners = [];
  
  static void addListener(Function(String) listener) {
    _listeners.add(listener);
  }
  
  static void removeListener(Function(String) listener) {
    _listeners.remove(listener);
  }
  
  static void notifyAnswerSubmitted(String questionId) {
    for (final listener in _listeners) {
      listener(questionId);
    }
  }
  
  static void dispose() {
    _listeners.clear();
  }
}

// Event notification system for scroll position updates
class ScrollPositionEvent {
  static final List<Function(Map<String, dynamic>)> _listeners = [];
  
  static void addListener(Function(Map<String, dynamic>) listener) {
    _listeners.add(listener);
    print('ScrollPositionEvent: Added listener, total listeners: ${_listeners.length}');
  }
  
  static void removeListener(Function(Map<String, dynamic>) listener) {
    _listeners.remove(listener);
    print('ScrollPositionEvent: Removed listener, total listeners: ${_listeners.length}');
  }
  
  static void notifyScrollRequest(Map<String, dynamic> scrollInfo) {
    print('ScrollPositionEvent: Notifying ${_listeners.length} listeners with scroll info: $scrollInfo');
    for (final listener in _listeners) {
      listener(scrollInfo);
    }
  }
  
  static void dispose() {
    _listeners.clear();
  }
}

// Event notification system for streak updates
class StreakUpdateEvent {
  static final List<Function(int, int)> _listeners = [];
  
  static void addListener(Function(int, int) listener) {
    _listeners.add(listener);
  }
  
  static void removeListener(Function(int, int) listener) {
    _listeners.remove(listener);
  }
  
  static void notifyStreakExtended(int previousStreak, int newStreak) {
    for (final listener in _listeners) {
      listener(previousStreak, newStreak);
    }
  }
  
  static void dispose() {
    _listeners.clear();
  }
}

// Add FeedContext class at the top after imports
class FeedContext {
  final String feedType; // 'trending', 'popular', 'new', 'room'
  final Map<String, dynamic> filters;
  final List<dynamic> questions;
  final int currentQuestionIndex;
  final String? originalQuestionId; // Track the original question tapped for scroll position
  final int originalQuestionIndex; // Track the original question index for swipe boundary
  final String? roomId; // Room ID when feedType is 'room'

  FeedContext({
    required this.feedType,
    required this.filters,
    required this.questions,
    required this.currentQuestionIndex,
    this.originalQuestionId, // The question they originally tapped
    int? originalQuestionIndex, // The index they originally started from
    this.roomId, // Room ID for room feeds
  }) : originalQuestionIndex = originalQuestionIndex ?? currentQuestionIndex;

  // Find the next unanswered question in the feed
  Map<String, dynamic>? getNextUnansweredQuestion(UserService userService) {
    for (int i = currentQuestionIndex + 1; i < questions.length; i++) {
      final question = questions[i];
      
      // Apply the same filtering logic as in home screen
      if (question['is_nsfw'] == true && !userService.showNSFWContent) {
        continue;
      }
      
      if (userService.hasAnsweredQuestion(question['id'])) {
        continue;
      }
      
      if (userService.shouldHideReportedQuestion(question['id'].toString())) {
        continue;
      }
      
      if (userService.isQuestionDismissed(question['id'].toString())) {
        continue;
      }
      
      return question;
    }
    
    return null; // No more unanswered questions
  }

  // Find the previous unanswered question in the feed (respects original starting boundary)
  Map<String, dynamic>? getPreviousUnansweredQuestion(UserService userService) {
    // Don't go beyond the original starting question
    final minIndex = originalQuestionIndex;
    
    for (int i = currentQuestionIndex - 1; i >= minIndex; i--) {
      final question = questions[i];
      
      // Apply the same filtering logic as in home screen
      if (question['is_nsfw'] == true && !userService.showNSFWContent) {
        continue;
      }
      
      if (userService.hasAnsweredQuestion(question['id'])) {
        continue;
      }
      
      if (userService.shouldHideReportedQuestion(question['id'].toString())) {
        continue;
      }
      
      if (userService.isQuestionDismissed(question['id'].toString())) {
        continue;
      }
      
      return question;
    }
    
    return null; // No more previous unanswered questions within boundary
  }

  // Check if user is at the original starting question
  bool isAtOriginalStartingQuestion() {
    return currentQuestionIndex == originalQuestionIndex;
  }

  // Find the next question in search feed (answered or unanswered)
  Map<String, dynamic>? getNextQuestionInSearchFeed(UserService userService) {
    for (int i = currentQuestionIndex + 1; i < questions.length; i++) {
      final question = questions[i];
      
      // Apply basic filtering (but NOT answered status filtering)
      if (question['is_nsfw'] == true && !userService.showNSFWContent) {
        continue;
      }
      
      if (userService.shouldHideReportedQuestion(question['id'].toString())) {
        continue;
      }
      
      if (userService.isQuestionDismissed(question['id'].toString())) {
        continue;
      }
      
      return question;
    }
    
    return null; // No more questions
  }

  // Find the previous question in search feed (answered or unanswered, respects boundary)
  Map<String, dynamic>? getPreviousQuestionInSearchFeed(UserService userService) {
    // Don't go beyond the original starting question
    final minIndex = originalQuestionIndex;
    
    for (int i = currentQuestionIndex - 1; i >= minIndex; i--) {
      final question = questions[i];
      
      // Apply basic filtering (but NOT answered status filtering)
      if (question['is_nsfw'] == true && !userService.showNSFWContent) {
        continue;
      }
      
      if (userService.shouldHideReportedQuestion(question['id'].toString())) {
        continue;
      }
      
      if (userService.isQuestionDismissed(question['id'].toString())) {
        continue;
      }
      
      return question;
    }
    
    return null; // No more previous questions within boundary
  }
  
  // Find the next question in regular feed (answered or unanswered) - for natural navigation
  Map<String, dynamic>? getNextQuestion(UserService userService) {
    for (int i = currentQuestionIndex + 1; i < questions.length; i++) {
      final question = questions[i];
      
      // Apply basic filtering (but NOT answered status filtering)
      if (question['is_nsfw'] == true && !userService.showNSFWContent) {
        continue;
      }
      
      if (userService.shouldHideReportedQuestion(question['id'].toString())) {
        continue;
      }
      
      if (userService.isQuestionDismissed(question['id'].toString())) {
        continue;
      }
      
      return question;
    }
    
    return null; // No more questions
  }
  
  // Find the previous question in regular feed (answered or unanswered, respects boundary) - for natural navigation  
  Map<String, dynamic>? getPreviousQuestion(UserService userService) {
    // Don't go beyond the original starting question
    final minIndex = originalQuestionIndex;
    
    for (int i = currentQuestionIndex - 1; i >= minIndex; i--) {
      final question = questions[i];
      
      // Apply basic filtering (but NOT answered status filtering)
      if (question['is_nsfw'] == true && !userService.showNSFWContent) {
        continue;
      }
      
      if (userService.shouldHideReportedQuestion(question['id'].toString())) {
        continue;
      }
      
      if (userService.isQuestionDismissed(question['id'].toString())) {
        continue;
      }
      
      return question;
    }
    
    return null; // No more previous questions within boundary
  }
}