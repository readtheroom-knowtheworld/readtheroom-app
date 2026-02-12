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
import '../utils/db_schema_check.dart';
import 'package:provider/provider.dart';
import 'dart:math' as Math;
import '../services/user_service.dart';
import '../services/notification_service.dart';
import '../services/achievement_service.dart';
import '../services/congratulations_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../widgets/notification_permission_dialog.dart';
import '../models/category.dart';
import '../screens/answer_approval_screen.dart';
import '../screens/answer_multiple_choice_screen.dart';
import '../screens/answer_text_screen.dart';
import '../screens/text_results_screen.dart';
import '../screens/multiple_choice_results_screen.dart';
import 'room_sharing_service.dart';
import 'room_service.dart';
import '../screens/approval_results_screen.dart';
import '../services/user_service.dart';
import '../services/location_service.dart';
import '../services/request_deduplication_service.dart';
import '../utils/seed_data.dart';

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
  late final SupabaseClient _serviceClient;
  final _roomSharingService = RoomSharingService();
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
  DateTime? _nsfwFallbackCacheTime;
  static const Duration _nsfwFallbackCacheDuration = Duration(hours: 1);
  
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
  
  // Enhanced method that handles NSFW filtering
  Future<Map<String, dynamic>?> getQuestionOfTheDay({bool showNSFW = true}) async {
    // Get the base question of the day
    final baseQotd = questionOfTheDay;
    if (baseQotd == null) return null;
    
    // Check if current QotD is NSFW and user doesn't want NSFW content
    final isNSFW = baseQotd['nsfw'] == true || baseQotd['is_nsfw'] == true;
    
    if (isNSFW && !showNSFW) {
      print('Current QotD is NSFW but user has NSFW disabled, fetching trending fallback...');
      
      // Check if we have a cached fallback that's still valid
      final now = DateTime.now();
      if (_nsfwFallbackQuestion != null && 
          _nsfwFallbackCacheTime != null && 
          now.difference(_nsfwFallbackCacheTime!) < _nsfwFallbackCacheDuration) {
        print('Using cached NSFW fallback question');
        return _nsfwFallbackQuestion;
      }
      
      try {
        // Get the top trending non-NSFW global question as fallback
        final fallbackQuestion = await _getTrendingNonNSFWFallback();
        if (fallbackQuestion != null) {
          // Cache the fallback
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
  
  // Get the top trending non-NSFW global question as fallback
  Future<Map<String, dynamic>?> _getTrendingNonNSFWFallback() async {
    try {
      print('Fetching top trending non-NSFW global question as QotD fallback...');
      
      // Use the optimized feed to get trending questions
      final trendingQuestions = await fetchOptimizedFeed(
        feedType: 'trending',
        limit: 10, // Get top 10 to have options
        filters: {
          'showNSFW': false, // Explicitly exclude NSFW
          'questionTypes': ['approval_rating', 'multiple_choice', 'text'], // All types
        },
        useCache: false, // Get fresh data for fallback
      );
      
      if (trendingQuestions.isEmpty) {
        print('No trending questions found for NSFW fallback');
        return null;
      }
      
      // Find the first global (not city/country targeted) question
      for (var question in trendingQuestions) {
        final targeting = question['targeting_type']?.toString().toLowerCase();
        if (targeting == 'globe' || targeting == 'global' || targeting == null) {
          // Make sure it's not NSFW
          final isNSFW = question['nsfw'] == true || question['is_nsfw'] == true;
          if (!isNSFW) {
            print('Selected trending non-NSFW global question as fallback: ${question['prompt']}');
            return question;
          }
        }
      }
      
      // If no global questions found, use the first non-NSFW question regardless of targeting
      for (var question in trendingQuestions) {
        final isNSFW = question['nsfw'] == true || question['is_nsfw'] == true;
        if (!isNSFW) {
          print('Selected trending non-NSFW question (any targeting) as fallback: ${question['prompt']}');
          return question;
        }
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
    
    // Initialize service client with service role key from environment (only once)
    if (!_serviceClientInitialized) {
      _serviceClientInitialized = true;
      try {
        final serviceKey = const String.fromEnvironment('SUPABASE_SERVICE_KEY');
        print('Service key provided: ${serviceKey.isNotEmpty}');
        
        if (serviceKey.isEmpty) {
          print('Service key not provided, seeding will be skipped');
          _serviceClient = _supabase; // Use regular client if no service key
        } else {
          print('Initializing service client...');
          _serviceClient = SupabaseClient(
            _supabase.rest.url,
            serviceKey,
          );
          print('Service client initialized successfully');
        }
      } catch (e) {
        print('Error initializing service client: $e');
        _serviceClient = _supabase; // Fallback to regular client
      }
      
      // Schedule periodic updates for Question of the Day
      _scheduleQuestionOfTheDayUpdates();
      // Seed initial questions (only for the first instance)
      seedInitialQuestions();
    } else {
      // For subsequent instances, just use the regular client
      _serviceClient = _supabase;
      print('🔄 QuestionService: Using existing service client configuration');
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
            final responses = await _supabase
                .from('responses')
                .select('id')
                .eq('question_id', question['id']);
            responseCount = responses?.length ?? 0;
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
      if (questionType == 'multiple_choice') {
        // For multiple choice, only count responses with valid option_ids
        final responses = await _supabase
            .from('responses')
            .select('option_id')
            .eq('question_id', questionId)
            .not('option_id', 'is', null);
        
        if (responses != null && responses.isNotEmpty) {
          // Get valid option IDs for this question
          final options = await _supabase
              .from('question_options')
              .select('id')
              .eq('question_id', questionId);
          
          final validOptionIds = Set<String>.from(
            (options ?? []).map((opt) => opt['id'].toString())
          );
          
          // Count only responses with valid option IDs
          final count = responses.where((response) {
            final optionId = response['option_id']?.toString();
            return optionId != null && validOptionIds.contains(optionId);
          }).length;
          
          return count;
        }
        return 0;
      } else if (questionType == 'approval_rating' || questionType == 'approval') {
        // For approval questions, only count responses with valid scores
        final responses = await _supabase
            .from('responses')
            .select('score')
            .eq('question_id', questionId)
            .not('score', 'is', null);
        
        return responses?.length ?? 0;
      } else if (questionType == 'text') {
        // For text questions, only count responses with valid text_response
        final responses = await _supabase
            .from('responses')
            .select('text_response')
            .eq('question_id', questionId)
            .not('text_response', 'is', null);
        
        return responses?.length ?? 0;
      } else {
        // For other question types, count all responses
        final response = await _supabase
            .from('responses')
            .select('id')
            .eq('question_id', questionId);
        
        return response?.length ?? 0;
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
      
      // Transform the data to include categories as a simple array and fetch response counts
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
        
        // Get accurate vote count for this question
        try {
          final voteCountResponse = await _supabase
              .from('responses')
              .select('id')
              .eq('question_id', question['id']);
          
          processedQuestion['votes'] = voteCountResponse?.length ?? 0;
        } catch (e) {
          print('Error fetching vote count for search result: $e');
          processedQuestion['votes'] = 0;
        }
        
        // Get comment count for this question
        try {
          final commentCountResponse = await _supabase
              .from('comments')
              .select('id')
              .eq('question_id', question['id'])
              .eq('is_hidden', false);
          
          processedQuestion['comment_count'] = commentCountResponse?.length ?? 0;
        } catch (e) {
          print('Error fetching comment count for search result: $e');
          processedQuestion['comment_count'] = 0;
        }
        
        processedQuestions.add(processedQuestion);
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

  Future<Map<String, dynamic>?> navigateToAnswerScreen(BuildContext context, Map<String, dynamic> question, {FeedContext? feedContext, bool fromSearch = false, bool fromUserScreen = false}) async {
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
    return await _proceedToAnswerScreen(context, question, feedContext: feedContext, fromSearch: fromSearch, fromUserScreen: fromUserScreen);
  }

  Future<Map<String, dynamic>?> _proceedToAnswerScreen(BuildContext context, Map<String, dynamic> question, {FeedContext? feedContext, bool fromSearch = false, bool fromUserScreen = false}) async {
    // Check if this is a QOTD and user should be prompted for QOTD notifications
    await checkQOTDSubscriptionPrompt(context, question);
    
    // Ensure question has all expected fields
    var enhancedQuestion = Map<String, dynamic>.from(question);
    
    // Fetch the current vote count from database
    try {
      final questionId = enhancedQuestion['id']?.toString();
      if (questionId != null) {
        final response = await _supabase
            .from('responses')
            .select('id')
            .eq('question_id', questionId);
        
        final currentVoteCount = response?.length ?? 0;
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
          builder: (context) => AnswerApprovalScreen(question: enhancedQuestion, feedContext: feedContext, fromSearch: fromSearch, fromUserScreen: fromUserScreen),
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
          builder: (context) => AnswerMultipleChoiceScreen(question: enhancedQuestion, feedContext: feedContext, fromSearch: fromSearch, fromUserScreen: fromUserScreen),
        ),
      );
      print('QuestionService: Multiple choice screen returned result: $result');
      return result as Map<String, dynamic>?;
    } else if (type == 'text') {
      print('QuestionService: Navigating to text screen for question ${enhancedQuestion['id']}');
      final result = await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => AnswerTextScreen(question: enhancedQuestion, feedContext: feedContext, fromSearch: fromSearch, fromUserScreen: fromUserScreen),
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
          builder: (context) => AnswerTextScreen(question: enhancedQuestion, feedContext: feedContext, fromSearch: fromSearch, fromUserScreen: fromUserScreen),
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
        final response = await _supabase
            .from('responses')
            .select('id')
            .eq('question_id', questionId);
        
        final currentVoteCount = response?.length ?? 0;
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
          // Get responses for approval questions
          List<Map<String, dynamic>> responses = [];
          try {
            responses = await _withErrorHandling(
              () => getCachedResponses(questionId, questionType),
              'Error loading responses'
            );
            
            // Cache responses for this viewed question
            if (responses.isNotEmpty) {
              _cacheViewedQuestionResponses(questionId, questionType, responses);
            }
          } catch (e) {
            print('Error loading approval responses: $e');
            responses = []; // Use empty responses if fetch fails
          }
          
          if (!context.mounted) return null;
          final result = await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => ApprovalResultsScreen(
                question: question,
                responses: responses,
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
          
          // Get individual responses for multiple choice questions (not country-summarized)
          List<Map<String, dynamic>> responses = [];
          try {
            responses = await _withErrorHandling(
              () => getMultipleChoiceIndividualResponses(questionId),
              'Error loading individual responses'
            );
            
            // Cache responses for this viewed question
            if (responses.isNotEmpty) {
              _cacheViewedQuestionResponses(questionId, questionType, responses);
            }
          } catch (e) {
            print('Error loading individual multiple choice responses: $e');
            responses = []; // Use empty responses if fetch fails
          }
          
          if (!context.mounted) return null;
          final result = await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => MultipleChoiceResultsScreen(
                question: question,
                responses: responses,
                feedContext: feedContext,
                fromSearch: fromSearch,
                fromUserScreen: fromUserScreen,
                isGuestMode: isGuestMode,
              ),
            ),
          );
          return result as Map<String, dynamic>?;
          
        case 'text':
          // For text questions, try to use preloaded responses or fetch fresh ones
          if (question['preloaded_text_responses'] == null) {
            try {
              final textResponses = await getCachedResponses(questionId, questionType);
              question['preloaded_text_responses'] = textResponses;
              
              // Cache responses for this viewed question
              if (textResponses.isNotEmpty) {
                _cacheViewedQuestionResponses(questionId, questionType, textResponses);
              }
              
              print('📄 Loaded ${textResponses.length} text responses for immediate display');
            } catch (e) {
              print('Error loading text responses: $e');
              // Continue without preloaded data
            }
          }
          
          if (!context.mounted) return null;
          final result = await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => TextResultsScreen(
                question: question,
                feedContext: feedContext,
                fromSearch: fromSearch,
                fromUserScreen: fromUserScreen,
                isGuestMode: isGuestMode,
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

  Future<List<Map<String, dynamic>>> getResponsesByCountry(String questionId) async {
    try {
      // Get responses from Supabase with country names instead of codes
      final response = await _supabase
          .from('responses')
          .select('''
            score,
            countries!responses_country_code_fkey(country_name_en)
          ''')
          .eq('question_id', questionId)
          .not('score', 'is', null);

      if (response == null || response.isEmpty) return [];

      // Group responses by country and calculate averages
      final Map<String, List<double>> countryScores = {};
      
      for (var r in response) {
        // Skip if essential data is missing
        if (r == null || r['countries']?['country_name_en'] == null || r['score'] == null) {
          print('Skipping response with missing data: $r');
          continue;
        }
        
        final countryName = r['countries']['country_name_en']; // Use full country name
        final score = (r['score'] as num).toDouble() / 100.0; // Convert from -100/100 to -1/1
        
        // Initialize country list if needed
        if (!countryScores.containsKey(countryName)) {
          countryScores[countryName] = [];
        }
        
        countryScores[countryName]!.add(score);
      }

      // If no valid responses found, return empty list
      if (countryScores.isEmpty) {
        return [];
      }

      // Calculate average score for each country
      final result = countryScores.entries.map((entry) {
        try {
          final scores = entry.value;
          
          if (scores.isEmpty) {
            return {'country': entry.key, 'answer': 0.0};
          }
          
          final avgScore = scores.reduce((a, b) => a + b) / scores.length;
          
          return {
            'country': entry.key,
            'answer': avgScore.clamp(-1.0, 1.0),
          };
        } catch (e) {
          print('Error calculating average score for country ${entry.key}: $e');
          return {
            'country': entry.key,
            'answer': 0.0,
          };
        }
      }).toList();
      
      // Smart prefetch: When user views a question, prefetch the next question while they're browsing
      _scheduleSmartPrefetch(questionId);
      
      return result;
    } catch (e) {
      print('Error fetching responses by country: $e');
      return [];
    }
  }

  Future<List<Map<String, dynamic>>> getMultipleChoiceResponsesByCountry(String questionId, List<String> options) async {
    try {
      // Get ALL responses for this question first (matching vote count logic)
      final responses = await _supabase
          .from('responses')
          .select('option_id, country_code')
          .eq('question_id', questionId)
          .not('option_id', 'is', null);

      if (responses == null || responses.isEmpty) {
        print('No responses found for question $questionId');
        return [];
      }

      print('Found ${responses.length} total responses for multiple choice question');

      // Get ALL options for this question (more reliable than looking up by response option_ids)
      Map<String, String> optionIdToText = {};
      try {
        final optionsData = await _supabase
            .from('question_options')
            .select('id, option_text')
            .eq('question_id', questionId)
            .order('sort_order');
        
        if (optionsData != null) {
          for (var option in optionsData) {
            optionIdToText[option['id']] = option['option_text'];
          }
          print('Found ${optionsData.length} options for question $questionId');
        }
      } catch (e) {
        print('Error fetching question options: $e');
      }

      // Get country names for the country codes
      final countryCodes = responses.map((r) => r['country_code']).where((code) => code != null).toSet().toList();
      
      Map<String, String> countryCodeToName = {};
      if (countryCodes.isNotEmpty) {
        try {
          print('DEBUG: Looking up country names for codes: $countryCodes');
          final countriesData = await _supabase
              .from('countries')
              .select('country_code, country_name_en')
              .filter('country_code', 'in', '(${countryCodes.map((code) => "'$code'").join(',')})');
          
          if (countriesData != null) {
            print('DEBUG: Found ${countriesData.length} countries in database');
            for (var country in countriesData) {
              countryCodeToName[country['country_code']] = country['country_name_en'];
              print('DEBUG: Mapped ${country['country_code']} -> ${country['country_name_en']}');
            }
          } else {
            print('DEBUG: No countries data returned from database');
          }
        } catch (e) {
          print('Error fetching country names: $e');
        }
      }

      // Group responses by country and option
      final Map<String, Map<String, int>> countryResponses = {};
      int validResponseCount = 0; // Track actual valid responses
      
      for (var r in responses) {
        // Skip if essential data is missing
        if (r == null || r['option_id'] == null || r['country_code'] == null) {
          print('Skipping response with missing data: $r');
          continue;
        }
        
        final optionId = r['option_id'].toString();
        final countryCode = r['country_code'].toString();
        
        // Get option text from our lookup (with fallback for data integrity issues)
        final optionText = optionIdToText[optionId] ?? 'Option $optionId';
        if (optionIdToText[optionId] == null) {
          print('Warning: Unknown option_id $optionId, using fallback text');
        }
        
        // Get country name from our lookup with better fallback
        String countryName;
        if (countryCodeToName.containsKey(countryCode)) {
          countryName = countryCodeToName[countryCode]!;
        } else {
          // Use a more user-friendly fallback than just the country code
          countryName = _getCountryNameFallback(countryCode);
          print('DEBUG: Using fallback country name for code $countryCode: $countryName');
        }
        
        // Initialize country map if needed
        if (!countryResponses.containsKey(countryName)) {
          countryResponses[countryName] = {};
        }
        
        // Increment count
        countryResponses[countryName]![optionText] = 
            (countryResponses[countryName]![optionText] ?? 0) + 1;
        
        // Count this as a valid response
        validResponseCount++;
      }

      print('Valid responses processed: $validResponseCount out of ${responses.length} total');

      // If no valid responses found, return empty list
      if (countryResponses.isEmpty) {
        return [];
      }

      // Convert to list format
      final result = countryResponses.entries.map((entry) {
        final responses = entry.value;
        
        // Skip if no options
        if (responses.isEmpty) {
          return {'country': entry.key, 'answer': options.isNotEmpty ? options[0] : ''};
        }
        
        try {
          final total = responses.values.reduce((a, b) => a + b);
          
          // Find the most common answer
          String mostCommonAnswer = responses.entries
              .reduce((a, b) => a.value > b.value ? a : b)
              .key;
          
          return {
            'country': entry.key,
            'answer': mostCommonAnswer,
          };
        } catch (e) {
          print('Error calculating most common answer for country ${entry.key}: $e');
          return {
            'country': entry.key,
            'answer': options.isNotEmpty ? options[0] : '',
          };
        }
      }).toList();
      
      // Store the valid response count for this question
      _storeValidResponseCount(questionId, validResponseCount);
      
      // Smart prefetch: When user views a question, prefetch the next question while they're browsing
      _scheduleSmartPrefetch(questionId);
      
      return result;
    } catch (e) {
      print('Error fetching multiple choice responses by country: $e');
      return [];
    }
  }

  /// Fetch approval responses with city-level location data for sub-national map views.
  /// Returns raw Supabase rows with city join data (lat, lng, admin1_code, etc.).
  Future<List<Map<String, dynamic>>> getApprovalResponsesWithCityData(String questionId) async {
    try {
      final response = await _supabase
          .from('responses')
          .select('''
            score,
            city_id,
            cities!responses_city_id_fkey(ascii_name, admin1_code, lat, lng, country_code)
          ''')
          .eq('question_id', questionId)
          .not('score', 'is', null)
          .not('city_id', 'is', null);

      if (response == null || response.isEmpty) return [];
      return List<Map<String, dynamic>>.from(response);
    } catch (e) {
      print('Error fetching approval responses with city data: $e');
      return [];
    }
  }

  /// Fetch multiple choice responses with city-level location data for sub-national map views.
  /// Returns raw Supabase rows with city join and option text.
  Future<List<Map<String, dynamic>>> getMultipleChoiceResponsesWithCityData(String questionId) async {
    try {
      final response = await _supabase
          .from('responses')
          .select('''
            option_id,
            city_id,
            cities!responses_city_id_fkey(ascii_name, admin1_code, lat, lng, country_code),
            question_options!responses_option_id_fkey(option_text)
          ''')
          .eq('question_id', questionId)
          .not('option_id', 'is', null)
          .not('city_id', 'is', null);

      if (response == null || response.isEmpty) return [];
      return List<Map<String, dynamic>>.from(response);
    } catch (e) {
      print('Error fetching MC responses with city data: $e');
      return [];
    }
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

  // Get individual multiple choice responses (not country-summarized) for results display
  Future<List<Map<String, dynamic>>> getMultipleChoiceIndividualResponses(String questionId) async {
    try {
      // Fetch individual responses from database with country information
      final response = await _supabase
          .from('responses')
          .select('''
            option_id,
            created_at,
            countries!responses_country_code_fkey(country_name_en),
            question_options!responses_option_id_fkey(option_text)
          ''')
          .eq('question_id', questionId)
          .not('option_id', 'is', null)
          .order('created_at', ascending: false);

      if (response == null || response.isEmpty) {
        print('No individual responses found for question $questionId');
        return [];
      }

      print('Found ${response.length} individual multiple choice responses');
      
      // Convert to the format expected by results screen
      final individualResponses = response.map((r) => {
        'answer': r['question_options']?['option_text'] ?? 'Unknown Option',
        'country': r['countries']?['country_name_en'] ?? 'Unknown',
        'created_at': r['created_at'],
      }).toList().cast<Map<String, dynamic>>();

      // Store the valid response count for this question
      _storeValidResponseCount(questionId, individualResponses.length);
      
      return individualResponses;
    } catch (e) {
      print('Error fetching individual multiple choice responses: $e');
      return [];
    }
  }

  // Get My Network responses by aggregating from all user's rooms
  Future<List<Map<String, dynamic>>> getMyNetworkResponses(String questionId, String questionType) async {
    try {
      final userId = _supabase.auth.currentUser?.id;
      if (userId == null) {
        print('User not authenticated for My Network responses');
        return [];
      }

      print('🔍 DEBUG: getMyNetworkResponses called with userId: $userId, questionId: $questionId');

      // Get all rooms the user is a member of using RoomService to avoid policy recursion
      final roomService = RoomService();
      final userRooms = await roomService.getUserRooms();

      if (userRooms.isEmpty) {
        print('User is not a member of any rooms');
        return [];
      }

      final roomIds = userRooms.map<String>((room) => room.id).toList();
      print('🎪 User is in ${roomIds.length} rooms, fetching My Network responses for question $questionId');

      // Get all shared responses from user's rooms for this question
      String responseSelect;
      if (questionType == 'multiple_choice') {
        responseSelect = '''
          responses!room_shared_responses_response_id_fkey(
            option_id,
            created_at,
            countries!responses_country_code_fkey(country_name_en),
            question_options!responses_option_id_fkey(option_text)
          )
        ''';
      } else if (questionType == 'approval_rating') {
        responseSelect = '''
          responses!room_shared_responses_response_id_fkey(
            score,
            created_at,
            countries!responses_country_code_fkey(country_name_en)
          )
        ''';
      } else {
        responseSelect = '''
          responses!room_shared_responses_response_id_fkey(
            text_response,
            created_at,
            countries!responses_country_code_fkey(country_name_en)
          )
        ''';
      }

      print('🔍 DEBUG: Querying room_shared_responses with roomIds: $roomIds, questionId: $questionId');

      final sharedResponsesData = await _supabase
          .from('room_shared_responses')
          .select(responseSelect)
          .eq('question_id', questionId)
          .inFilter('room_id', roomIds);

      print('🔍 DEBUG: Raw shared responses data: ${sharedResponsesData.length} items');
      
      if (sharedResponsesData.isEmpty) {
        print('No shared responses found in user\'s rooms for question $questionId');
        return [];
      }

      print('🎪 Found ${sharedResponsesData.length} shared responses from My Network');

      // Convert to the format expected by results screens
      final networkResponses = sharedResponsesData.map((shared) {
        final response = shared['responses'];
        if (response == null) {
          print('🔍 DEBUG: Null response found in shared data: $shared');
          return null;
        }

        if (questionType == 'multiple_choice') {
          return {
            'answer': response['question_options']?['option_text'] ?? 'Unknown Option',
            'country': response['countries']?['country_name_en'] ?? 'Unknown',
            'created_at': response['created_at'],
            'room_id': 'network', // Mark as network response
          };
        } else if (questionType == 'approval_rating') {
          return {
            'answer': ((response['score'] as int?) ?? 0).toDouble() / 100.0, // Convert to -1 to 1 range
            'country': response['countries']?['country_name_en'] ?? 'Unknown',
            'created_at': response['created_at'],
            'room_id': 'network', // Mark as network response
          };
        } else {
          return {
            'answer': response['text_response'] ?? '',
            'country': response['countries']?['country_name_en'] ?? 'Unknown', 
            'created_at': response['created_at'],
            'room_id': 'network', // Mark as network response
          };
        }
      }).where((r) => r != null).cast<Map<String, dynamic>>().toList();

      print('🎪 Converted ${networkResponses.length} My Network responses');
      print('🔍 DEBUG: Network responses raw count: ${sharedResponsesData.length}, converted count: ${networkResponses.length}');
      
      // Only return network responses if there are 5 or more for privacy/meaningful data
      // Note: Database now prevents duplicates with unique constraint (room_id, question_id, response_id)
      if (networkResponses.length < 5) {
        print('🎪 My Network has <5 responses (${networkResponses.length}), not displaying for privacy');
        print('🔍 DEBUG: First few responses for analysis: ${networkResponses.take(3).toList()}');
        return [];
      }
      
      return networkResponses;
    } catch (e) {
      print('Error fetching My Network responses: $e');
      return [];
    }
  }

  // Check if a room has enough responses (5+) for a specific question to enable filtering
  Future<bool> hasEnoughRoomResponses(String roomId, String questionId) async {
    try {
      final sharedResponsesCount = await _supabase
          .from('room_shared_responses')
          .select('id')
          .eq('room_id', roomId)
          .eq('question_id', questionId);

      final count = sharedResponsesCount.length;
      print('🎪 Room $roomId has $count shared responses for question $questionId');
      return count >= 5;
    } catch (e) {
      print('Error checking room response count: $e');
      return false;
    }
  }

  // Get room response count for a specific question
  Future<int> getRoomResponseCount(String roomId, String questionId) async {
    try {
      // Use regular client - RLS policies are now fixed to prevent recursion
      final sharedResponsesCount = await _supabase
          .from('room_shared_responses')
          .select('id')
          .eq('room_id', roomId)
          .eq('question_id', questionId);

      print('🔍 DEBUG: Room $roomId query result: ${sharedResponsesCount.length} responses');
      return sharedResponsesCount.length;
    } catch (e) {
      print('Error getting room response count: $e');
      return 0;
    }
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
  
  // Fresh data fetching methods that bypass cache for accurate prefetching
  Future<List<Map<String, dynamic>>> _getFreshResponsesByCountry(String questionId) async {
    try {
      // Direct database query, no cache
      final response = await _supabase
          .from('responses')
          .select('''
            score,
            created_at,
            countries!responses_country_code_fkey(country_name_en)
          ''')
          .eq('question_id', questionId)
          .not('score', 'is', null)
          .order('created_at', ascending: false);
      
      if (response != null && response.isNotEmpty) {
        return response.map((r) => {
          'country': r['countries']?['country_name_en'] ?? 'Unknown',
          'answer': (r['score'] as int).toDouble() / 100.0,
          'created_at': r['created_at'],
        }).toList();
      }
      return [];
    } catch (e) {
      print('Error fetching fresh approval responses: $e');
      return [];
    }
  }
  
  Future<List<Map<String, dynamic>>> _getFreshMultipleChoiceResponses(String questionId) async {
    try {
      // Use existing method but ensure it's fresh
      return await getMultipleChoiceIndividualResponses(questionId);
    } catch (e) {
      print('Error fetching fresh MC responses: $e');
      return [];
    }
  }
  
  Future<List<Map<String, dynamic>>> _getFreshTextResponses(String questionId) async {
    try {
      // Use existing method but ensure it's fresh
      return await getTextResponses(questionId);
    } catch (e) {
      print('Error fetching fresh text responses: $e');
      return [];
    }
  }

  // Get text responses for a question
  Future<List<Map<String, dynamic>>> getTextResponses(String questionId) async {
    try {
      final response = await _supabase
          .from('responses')
          .select('''
            text_response, 
            created_at,
            countries!responses_country_code_fkey(country_name_en)
          ''')
          .eq('question_id', questionId)
          .not('text_response', 'is', null)
          .order('created_at', ascending: false);
      
      if (response != null && response.isNotEmpty) {
        final result = response.map((r) => {
          'text_response': r['text_response'],
          'country': r['countries']?['country_name_en'] ?? 'Unknown',
          'created_at': r['created_at'],
        }).toList();
        
        // Smart prefetch: When user views a question, prefetch the next question while they're browsing
        _scheduleSmartPrefetch(questionId);
        
        return result;
      }
      
      return [];
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
      
      // Preload individual responses
      getMultipleChoiceIndividualResponses(questionId).catchError((e) {
        print('Failed to preload multiple choice responses for $questionId: $e');
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
        
        // Prefetch responses based on question type - ALWAYS fetch fresh data
        try {
          List<Map<String, dynamic>> responses = [];
          
          switch (questionType) {
            case 'approval_rating':
            case 'approval':
              // Always fetch fresh data, bypass cache for prefetch to ensure accuracy
              responses = await _getFreshResponsesByCountry(questionId);
              print('📦 Prefetched ${responses.length} fresh approval responses for $questionId');
              break;
              
            case 'multiple_choice':
            case 'multiplechoice':
              responses = await _getFreshMultipleChoiceResponses(questionId);
              print('📦 Prefetched ${responses.length} fresh MC responses for $questionId');
              break;
              
            case 'text':
              responses = await _getFreshTextResponses(questionId);
              print('📦 Prefetched ${responses.length} fresh text responses for $questionId');
              break;
          }
          
          // Cache the fresh responses
          if (responses.isNotEmpty) {
            _cacheViewedQuestionResponses(questionId, questionType, responses);
            
            // IMPORTANT: Update question's vote count to prevent false change detection
            final questionIndex = _questions.indexWhere((q) => q['id'].toString() == questionId);
            if (questionIndex != -1) {
              _questions[questionIndex]['votes'] = responses.length;
              print('🔄 Updated vote count for prefetched question $questionId: ${responses.length}');
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
      
      // Try to push sample questions to Supabase database
      try {
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

  // Submit a multiple choice response to the database
  Future<bool> submitMultipleChoiceResponse(String questionId, String selectedOption, String countryCode, {LocationService? locationService}) async {
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
      
      // Insert response directly without user_id (responses table is designed for anonymity)
      print('DEBUG: Inserting response into database: $responseData');
      
      bool responseInserted = false;
      
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
        
        final insertResult = await _supabase
            .from('responses')
            .insert(responseData)
            .select('id');
        
        print('SUCCESS: Response inserted into database');
        responseInserted = true;
        
        // Handle room sharing for successful response
        if (insertResult.isNotEmpty) {
          final responseId = insertResult.first['id'] as String;
          await _roomSharingService.handleResponseSubmission(
            questionId: questionId,
            responseId: responseId,
            selectedOption: selectedOption,
            questionType: 'multiple_choice',
          );
        }
        
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
          final testRead = await _supabase
              .from('responses')
              .select('id')
              .limit(1);
          print('DEBUG: Responses table is readable, found ${testRead?.length ?? 0} records');
        } catch (readError) {
          print('ERROR: Cannot even read from responses table: $readError');
        }
        
        rethrow;
      }
      
      // Only proceed if response was actually inserted
      if (!responseInserted) {
        throw Exception('Failed to insert response into database');
      }
      
      // Also increment the option count (this is needed for the UI to reflect changes immediately)
      await incrementOptionCount(questionId, optionId);
      
      // Update the vote count immediately after successful submission
      try {
        print('DEBUG: Updating vote count after successful response submission...');
        final updatedVoteCount = await getAccurateVoteCount(questionId, question['type']?.toString());
        
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
  Future<bool> submitApprovalResponse(String questionId, double score, String countryCode, {LocationService? locationService}) async {
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
      };

      // Insert response directly without user_id (responses table has no user_id for anonymity)
      print('Submitting approval response: $responseData');
      final insertResult = await _supabase
          .from('responses')
          .insert(responseData)
          .select('id');

      print('SUCCESS: Approval response inserted');

      // Handle room sharing for successful response
      if (insertResult.isNotEmpty) {
        final responseId = insertResult.first['id'] as String;
        await _roomSharingService.handleResponseSubmission(
          questionId: questionId,
          responseId: responseId,
          ratingScore: score,
          questionType: 'approval',
        );
      }
      
      // Update the average score for this question
      await updateQuestionAverageScore(questionId);
      
      // Update the vote count immediately after successful submission
      try {
        print('DEBUG: Updating vote count after successful approval response submission...');
        final updatedVoteCount = await getAccurateVoteCount(questionId, 'approval_rating');
        
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
      
      // Get all responses for this question from the database
      final response = await _supabase
          .from('responses')
          .select('score')
          .eq('question_id', questionId)
          .not('score', 'is', null);
          
      if (response == null || response.isEmpty) {
        print('No scored responses found for question');
        return false;
      }
      
      // Calculate the average score
      int sum = 0;
      for (var item in response) {
        if (item['score'] != null) {
          sum += item['score'] as int;
        }
      }
      
      final avgScore = sum / response.length;
      
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
  Future<bool> submitTextResponse(String questionId, String responseText, String countryCode, {LocationService? locationService}) async {
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
      };

      // Insert response directly without user_id (responses table has no user_id for anonymity)
      print('Submitting text response: $responseData');
      final insertResult = await _supabase
          .from('responses')
          .insert(responseData)
          .select('id');

      print('SUCCESS: Text response inserted');

      // Handle room sharing for successful response
      if (insertResult.isNotEmpty) {
        final responseId = insertResult.first['id'] as String;
        await _roomSharingService.handleResponseSubmission(
          questionId: questionId,
          responseId: responseId,
          responseText: responseText,
          questionType: 'text',
        );
      }
      
      // Update response counts for this question
      updateTextResponseCount(questionId);
      
      // Update the vote count immediately after successful submission
      try {
        print('DEBUG: Updating vote count after successful text response submission...');
        final updatedVoteCount = await getAccurateVoteCount(questionId, 'text');
        
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
      final response = await _supabase
          .from('responses')
          .select()
          .eq('question_id', questionId)
          .not('text_response', 'is', null);
          
      final count = response?.length ?? 0;
      
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

  // Load more questions for pagination using optimized Edge Function
  Future<List<Map<String, dynamic>>> loadMoreQuestions({
    required String feedType,
    Map<String, dynamic>? filters,
    UserService? userService,
    int currentOffset = 0,
  }) async {
    if (_isLoading) {
      print('⚠️  Already loading, skipping loadMoreQuestions');
      return [];
    }

    print('📄 Loading more questions with pagination (offset: $currentOffset)...');
    
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
      final questionIds = questions.map((q) => q['id']).where((id) => id != null).toList();
      if (questionIds.isEmpty) return;
      
      final voteCountResponse = await _supabase
          .from('responses')
          .select('question_id')
          .inFilter('question_id', questionIds);
      
      final voteCounts = <String, int>{};
      for (var response in voteCountResponse) {
        final questionId = response['question_id']?.toString();
        if (questionId != null) {
          voteCounts[questionId] = (voteCounts[questionId] ?? 0) + 1;
        }
      }
      
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
      const anonKey = String.fromEnvironment('SUPABASE_ANON_KEY', defaultValue: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InlncW5xZHJtbGRya3l1Z2hydmNnIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NDcwMTgxNDAsImV4cCI6MjA2MjU5NDE0MH0.csUnbJgJAlOx4seEi2hV-76t286q56-zGu307Mf0rQE');
      
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
      
      // Fallback to question_feed_scores materialized view
      print('🔄 Falling back to question_feed_scores materialized view...');
      try {
        return await _fetchFallbackFeed(feedType, limit, cursor, filters, userService, offset);
      } catch (fallbackError) {
        print('❌ Fallback also failed: $fallbackError');
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
        final questionIds = processedQuestions.map((q) => q['id']).where((id) => id != null).toList();
        if (questionIds.isNotEmpty) {
          final voteCountResponse = await _supabase
              .from('responses')
              .select('question_id')
              .filter('question_id', 'in', '(${questionIds.join(',')})');
          
          final voteCounts = <String, int>{};
          for (var response in voteCountResponse) {
            final questionId = response['question_id']?.toString();
            if (questionId != null) {
              voteCounts[questionId] = (voteCounts[questionId] ?? 0) + 1;
            }
          }
          
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
      for (var i = 0; i < questions.length; i++) {
        final questionId = questions[i]['id'];
        
        try {
          // Get all responses for this question and count them
          final response = await _supabase
              .from('responses')
              .select()
              .eq('question_id', questionId);
          
          // Count is just the length of the returned array
          final count = response.length;
          questions[i]['votes'] = count;
        } catch (e) {
          print('Error counting responses for question $questionId: $e');
          // If we can't get the count, default to 0
          questions[i]['votes'] = 0;
        }
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
          
          // Get current vote count from responses table
          final responseCountQuery = await _supabase
              .from('responses')
              .select('id')
              .eq('question_id', questionId);
          
          question['votes'] = responseCountQuery?.length ?? 0;
          
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

          // Batch fetch vote counts for all questions (also process in batches)
          final Map<String, int> voteCounts = {};
          
          for (int i = 0; i < questionIds.length; i += batchSize) {
            final batch = questionIds.skip(i).take(batchSize).toList();
            
            final responseCountsQuery = await _supabase
                .from('responses')
                .select('question_id, id')
                .inFilter('question_id', batch);

            // Group vote counts by question_id for this batch
            if (responseCountsQuery != null) {
              for (final resp in responseCountsQuery) {
                final questionId = resp['question_id'] as String;
                voteCounts[questionId] = (voteCounts[questionId] ?? 0) + 1;
              }
            }
          }
          
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

  /// Search questions by prompt for autocomplete functionality
  /// Uses the same search logic as the main search screen for consistency
  Future<List<Map<String, dynamic>>> searchQuestionsForAutocomplete(String query, {int limit = 10, bool includeNSFW = false, bool excludePrivate = false}) async {
    print('🔍 searchQuestionsForAutocomplete called with query: "$query", limit: $limit');
    
    if (query.trim().isEmpty) {
      print('❌ Empty query provided, returning empty list');
      return [];
    }

    try {
      // Use the same search method as the search screen but with minimal data needed for autocomplete
      final allResults = await searchQuestions(query.trim(), includeNSFW: includeNSFW, excludePrivate: excludePrivate);
      
      // Filter and limit results for autocomplete
      final limitedResults = allResults.take(limit).map((question) => {
        'id': question['id'],
        'prompt': question['prompt'],
        'type': question['type'],
        'votes': question['votes'] ?? 0,
      }).toList();
      
      print('✅ Autocomplete search successful - found ${limitedResults.length} results (from ${allResults.length} total)');
      print('📊 Results: ${limitedResults.map((r) => r['prompt']).toList()}');
      return limitedResults;
    } catch (e) {
      print('❌ Autocomplete search failed: $e');
      print('💀 Returning empty list due to search failure');
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
      
      final questionType = question['type']?.toString();
      if (questionType != null && !userService.isQuestionTypeEnabled(questionType)) {
        continue;
      }
      
      final questionCategories = question['categories'] as List<dynamic>?;
      if (questionCategories != null && questionCategories.isNotEmpty) {
        final hasEnabledCategory = questionCategories.any((category) {
          final categoryName = category.toString();
          return userService.enabledCategories.contains(categoryName);
        });
        if (!hasEnabledCategory) {
          continue;
        }
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
      
      final questionType = question['type']?.toString();
      if (questionType != null && !userService.isQuestionTypeEnabled(questionType)) {
        continue;
      }
      
      final questionCategories = question['categories'] as List<dynamic>?;
      if (questionCategories != null && questionCategories.isNotEmpty) {
        final hasEnabledCategory = questionCategories.any((category) {
          final categoryName = category.toString();
          return userService.enabledCategories.contains(categoryName);
        });
        if (!hasEnabledCategory) {
          continue;
        }
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
      
      final questionType = question['type']?.toString();
      if (questionType != null && !userService.isQuestionTypeEnabled(questionType)) {
        continue;
      }
      
      final questionCategories = question['categories'] as List<dynamic>?;
      if (questionCategories != null && questionCategories.isNotEmpty) {
        final hasEnabledCategory = questionCategories.any((category) {
          final categoryName = category.toString();
          return userService.enabledCategories.contains(categoryName);
        });
        if (!hasEnabledCategory) {
          continue;
        }
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
      
      final questionType = question['type']?.toString();
      if (questionType != null && !userService.isQuestionTypeEnabled(questionType)) {
        continue;
      }
      
      final questionCategories = question['categories'] as List<dynamic>?;
      if (questionCategories != null && questionCategories.isNotEmpty) {
        final hasEnabledCategory = questionCategories.any((category) {
          final categoryName = category.toString();
          return userService.enabledCategories.contains(categoryName);
        });
        if (!hasEnabledCategory) {
          continue;
        }
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
      
      final questionType = question['type']?.toString();
      if (questionType != null && !userService.isQuestionTypeEnabled(questionType)) {
        continue;
      }
      
      final questionCategories = question['categories'] as List<dynamic>?;
      if (questionCategories != null && questionCategories.isNotEmpty) {
        final hasEnabledCategory = questionCategories.any((category) {
          final categoryName = category.toString();
          return userService.enabledCategories.contains(categoryName);
        });
        if (!hasEnabledCategory) {
          continue;
        }
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
      
      final questionType = question['type']?.toString();
      if (questionType != null && !userService.isQuestionTypeEnabled(questionType)) {
        continue;
      }
      
      final questionCategories = question['categories'] as List<dynamic>?;
      if (questionCategories != null && questionCategories.isNotEmpty) {
        final hasEnabledCategory = questionCategories.any((category) {
          final categoryName = category.toString();
          return userService.enabledCategories.contains(categoryName);
        });
        if (!hasEnabledCategory) {
          continue;
        }
      }
      
      return question;
    }
    
    return null; // No more previous questions within boundary
  }
}