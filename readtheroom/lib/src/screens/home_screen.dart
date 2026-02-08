// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

// lib/src/screens/home_screen.dart
import 'dart:convert';
import 'dart:async'; // Add this import for Timer
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../utils/time_utils.dart'; // Import our time utility (getTimeAgo)
import '../utils/theme_utils.dart';
import '../utils/haptic_utils.dart';
import '../services/user_service.dart';
import '../services/location_service.dart';
import '../services/guest_user_tracking_service.dart';
import '../services/analytics_service.dart';
import '../widgets/question_type_badge.dart';
import '../services/question_service.dart';
import '../models/category.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../widgets/notification_permission_dialog.dart';
import '../widgets/authentication_dialog.dart';
import '../widgets/curio_loading.dart';
import '../services/temporary_category_filter_notifier.dart';
import '../services/navigation_visibility_notifier.dart';
import '../widgets/temporary_category_filter_widget.dart';
import '../widgets/location_filter_dialog.dart';
import '../widgets/empty_city_feed_widget.dart';
import '../widgets/empty_country_feed_widget.dart';
import '../utils/location_persistence.dart';
import '../widgets/streak_celebration_animation.dart';
import '../services/question_service.dart' show StreakUpdateEvent;
import '../services/home_widget_service.dart';
import 'package:url_launcher/url_launcher.dart';

// Enum for feed settings (answered/unanswered filter)
enum FeedSetting {
  showAll,       // Show all questions (default)
  unanswered,    // Show only unanswered questions
  answered,      // Show only answered questions
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({Key? key}) : super(key: key);
  
  @override
  HomeScreenState createState() => HomeScreenState();
}

class HomeScreenState extends State<HomeScreen> with TickerProviderStateMixin, WidgetsBindingObserver {
  bool _isLoading = false;
  String _sortBy = 'trending'; // Default sort option
  // Removed old pagination variables - now using infinite scroll
  bool _isLoadingMore = false;
  bool _hasReachedEnd = false; // Track if we've reached the end of available questions
  final ScrollController _scrollController = ScrollController();
  
  // Progressive comment loading state
  bool _isLoadingComments = false;
  int _commentLoadingOffset = 0;
  List<String> _commentLoadingQueue = [];
  Set<String> _enrichedQuestions = {}; // Track which questions already have comment data
  
  // For scroll position memory
  final Map<String, double> _questionScrollPositions = {};
  
  // For feed mode switching
  int _currentFeedMode = 0; // 0=trending, 1=popular, 2=new
  final List<String> _feedModes = ['trending', 'popular', 'new'];
  
  // For pulsing animation when streak is urgent
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;
  
  // For QotD thanks message animation
  bool _hasShownThanksOnRefresh = false; // Track if we've shown thanks on this session

  // For background vote count polling
  Timer? _voteCountPollTimer;
  Map<String, int> _lastKnownVoteCounts = {}; // Track last known vote counts
  DateTime _lastVoteCountUpdate = DateTime.now();
  bool _isPollingPaused = false; // Track if polling is paused
  bool _hasLoggedPollingStart = false; // Track if we've logged polling start

  // For QotD refresh control
  final GlobalKey<QuestionOfTheDayWidgetState> _qotdKey = GlobalKey<QuestionOfTheDayWidgetState>();

  // For temporary category filter notifier (saved reference to avoid dispose issues)
  TemporaryCategoryFilterNotifier? _tempFilterNotifier;

  // Always use global filtering (show all posts)
  final LocationFilterType _locationFilter = LocationFilterType.global;
  
  // For feed settings (answered/unanswered filter)
  FeedSetting _feedSetting = FeedSetting.showAll;

  // For user gesture detection to prevent scroll conflicts
  bool _isUserScrolling = false;
  bool _isUserTouching = false; // Track if user finger is on screen
  bool _refreshHapticTriggered = false; // Track if refresh haptic was triggered for current pull
  double _cumulativeOverscroll = 0.0; // Track cumulative overscroll for Android haptic
  Timer? _scrollEndTimer;

  // For streak celebration animation
  late AnimationController _streakCardController;
  late Animation<double> _streakCardScaleAnimation;
  int? _animatingOldStreak;
  int? _animatingNewStreak;
  bool _isStreakAnimating = false;

  // For streak card attention animation (draws user to click on it)
  late AnimationController _streakAttentionController;
  late Animation<double> _streakAttentionAnimation;
  bool _isStreakAttentionAnimating = false;

  final supabase = Supabase.instance.client;

  // Helper method to build filters (now always global - shows all posts)
  Map<String, dynamic> _buildFiltersWithLocation(UserService userService, LocationService locationService) {
    return <String, dynamic>{
      'showNSFW': userService.showNSFWContent,
      'questionTypes': userService.enabledQuestionTypes,
      'excludePrivate': true, // Never show private questions in main feed
      'locationFilter': 'global', // Always show all posts regardless of targeting
    };
  }

  Future<void> _loadMoreQuestions() async {
    if (_isLoadingMore || _hasReachedEnd) return;
    
    // Capture services before async operations to avoid disposal issues
    final questionService = Provider.of<QuestionService>(context, listen: false);
    final userService = Provider.of<UserService>(context, listen: false);
    final locationService = Provider.of<LocationService>(context, listen: false);
    
    setState(() {
      _isLoadingMore = true;
    });

    try {
      
      // Build server-side filters with location filtering
      final filters = _buildFiltersWithLocation(userService, locationService);
      
      // Calculate current offset based on existing questions
      final currentQuestions = questionService.questions;
      final currentOffset = currentQuestions.length;
      
      print('📄 Loading more questions - current: ${currentQuestions.length}, offset: $currentOffset');
      
      // Load more questions using offset-based pagination
      final moreQuestions = await questionService.loadMoreQuestions(
        feedType: _sortBy,
        filters: filters,
        userService: userService,
        currentOffset: currentOffset,
      );
      
      print('📄 Loaded ${moreQuestions.length} more questions');
      
      // Handle end-of-data and update questions
      if (moreQuestions.isNotEmpty) {
        // Append to existing questions and remove duplicates
        final updatedQuestions = [...currentQuestions, ...moreQuestions];
        final uniqueQuestions = _removeDuplicateQuestions(updatedQuestions);
        questionService.updateQuestions(uniqueQuestions);
        
        // Add new questions to vote count tracking
        for (var question in moreQuestions) {
          final questionId = question['id']?.toString();
          final voteCount = question['votes'] ?? 0;
          if (questionId != null) {
            _lastKnownVoteCounts[questionId] = voteCount;
          }
        }
        print('📄 Added ${moreQuestions.length} new questions to vote count tracking');
      }
      
      // Update state: set loading to false and check if we've reached the end
      setState(() {
        _isLoadingMore = false;
        // Only set _hasReachedEnd when database is truly exhausted (returns empty results)
        if (moreQuestions.isEmpty) {
          _hasReachedEnd = true;
          print('📄 Database exhausted - _hasReachedEnd set to true');
        }
      });
      
      if (moreQuestions.isEmpty) {
        print('🔍 State after reaching true end: _hasReachedEnd=$_hasReachedEnd, _isLoadingMore=$_isLoadingMore');
      } else {
        print('📄 Loaded ${moreQuestions.length} more questions - continuing infinite scroll');
      }
      
    } catch (e) {
      print('❌ Error loading more questions: $e');
      setState(() {
        _isLoadingMore = false;
      });
    }
  }
  
  Future<void> _loadMoreComments() async {
    if (_isLoadingComments || _commentLoadingQueue.isEmpty) return;
    
    setState(() {
      _isLoadingComments = true;
    });
    
    try {
      // Get next batch of questions needing comment data (15 at a time)
      final batchSize = 15;
      final endIndex = (_commentLoadingOffset + batchSize).clamp(0, _commentLoadingQueue.length);
      final batch = _commentLoadingQueue.sublist(_commentLoadingOffset, endIndex);
      
      if (batch.isEmpty) {
        setState(() {
          _isLoadingComments = false;
        });
        return;
      }
      
      
      // Get the actual question objects for this batch
      final questionService = Provider.of<QuestionService>(context, listen: false);
      final allQuestions = questionService.questions;
      final questionsToEnrich = allQuestions
          .where((q) => batch.contains(q['id']?.toString()))
          .toList();
      
      if (questionsToEnrich.isNotEmpty) {
        // Enrich this batch silently in background
        await questionService.enrichQuestionsWithEngagementData(questionsToEnrich);
        
        // Mark these questions as enriched
        for (final question in questionsToEnrich) {
          final questionId = question['id']?.toString();
          if (questionId != null) {
            _enrichedQuestions.add(questionId);
          }
        }
        
      }
      
      _commentLoadingOffset = endIndex;
      
      // Update UI to show new comment counts
      if (mounted) {
        setState(() {});
      }
      
    } catch (e) {
      print('❌ Error loading comments batch: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isLoadingComments = false;
        });
      }
    }
  }

  // Removed old pagination methods - now using infinite scroll

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_scrollListener);
    
    // Initialize pulse animation controller
    _pulseController = AnimationController(
      duration: const Duration(milliseconds: 1000), // 1 second pulse
      vsync: this,
    );
    _pulseAnimation = Tween<double>(
      begin: 1.0,
      end: 1.105,
    ).animate(CurvedAnimation(
      parent: _pulseController,
      curve: Curves.easeInOut,
    ));
    _pulseController.repeat(reverse: true); // Pulse back and forth continuously
    
    // Initialize streak card animation controller
    _streakCardController = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    );
    _streakCardScaleAnimation = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween<double>(begin: 1.0, end: 1.1),
        weight: 30,
      ),
      TweenSequenceItem(
        tween: Tween<double>(begin: 1.1, end: 1.0),
        weight: 70,
      ),
    ]).animate(_streakCardController);

    // Initialize streak attention animation (glow effect to draw clicks)
    _streakAttentionController = AnimationController(
      duration: const Duration(milliseconds: 1200),
      vsync: this,
    );
    _streakAttentionAnimation = TweenSequence<double>([
      // Quick fade in
      TweenSequenceItem(
        tween: Tween<double>(begin: 0.0, end: 1.0),
        weight: 20,
      ),
      // Hold at peak
      TweenSequenceItem(
        tween: Tween<double>(begin: 1.0, end: 1.0),
        weight: 20,
      ),
      // Fade out
      TweenSequenceItem(
        tween: Tween<double>(begin: 1.0, end: 0.0),
        weight: 20,
      ),
      // Second pulse - fade in
      TweenSequenceItem(
        tween: Tween<double>(begin: 0.0, end: 0.8),
        weight: 20,
      ),
      // Fade out completely
      TweenSequenceItem(
        tween: Tween<double>(begin: 0.8, end: 0.0),
        weight: 20,
      ),
    ]).animate(_streakAttentionController);

    _streakAttentionController.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        setState(() {
          _isStreakAttentionAnimating = false;
        });
      }
    });

    // Add lifecycle observer to handle app state changes
    WidgetsBinding.instance.addObserver(this);
    
    // Add listener for vote count update events
    VoteCountUpdateEvent.addListener(_onAnswerSubmitted);
    
    // Add listener for scroll position events
    ScrollPositionEvent.addListener(_onScrollPositionRequested);
    
    // Add listener for streak update events
    StreakUpdateEvent.addListener(_onStreakExtended);
    
    // Load saved feed settings first, then load questions
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadSavedFeedSettings().then((_) {
        _loadOptimizedQuestionsWithPreload().then((_) {
          // Start vote count polling after questions are loaded
          print('Feed: Questions loaded, starting vote count polling...');
          _startVoteCountPolling();

          // Update home screen widget with current streak data
          _updateHomeWidget();

          // Sync streak to server to get leaderboard rank (for rainbow border)
          final userService = Provider.of<UserService>(context, listen: false);
          userService.syncStreakToServer();
        });
      });
      
      // Initialize location history with current location
      final userService = Provider.of<UserService>(context, listen: false);
      final locationService = Provider.of<LocationService>(context, listen: false);
      userService.initializeLocationHistory(locationService);
      
      // Set local boost based on location filter after providers are ready
      _setLocalBoostBasedOnLocationFilter(userService);
      print('🏠 Home initialized: Location filter = ${_locationFilter.name}, Local boost = ${userService.boostLocalActivity}');
      
      // Listen for temporary category filter changes
      _tempFilterNotifier = Provider.of<TemporaryCategoryFilterNotifier>(context, listen: false);
      _tempFilterNotifier!.addListener(_onCategoryFilterChanged);
    });
    
    // TEMPORARY: Removed auto-timer - now triggers on every answer
    
    print('Feed: Initialized');
  }

  void _onAnswerSubmitted(String questionId) {
    print('Feed: Received answer submitted notification for question $questionId, triggering immediate vote count update');
    triggerImmediateVoteCountUpdateForQuestion(questionId);
  }

  void _onCategoryFilterChanged() {
    // Category filter changed - scroll to top to show new filtered content
    // This makes sense because users expect to see fresh content when filtering
    _safeAnimateToTop(
      reason: 'category_filter_changed',
      duration: Duration(milliseconds: 300),
    );
  }

  void _onStreakExtended(int previousStreak, int newStreak) {
    if (!mounted) return;
    
    print('🎉 Streak extended! Previous: $previousStreak, New: $newStreak');
    
    // Set animation state
    setState(() {
      _animatingOldStreak = previousStreak;
      _animatingNewStreak = newStreak;
      _isStreakAnimating = true;
    });
    
    // Show celebration animation with streak values
    StreakCelebrationOverlay.show(
      context, 
      oldStreak: previousStreak, 
      newStreak: newStreak,
      onComplete: () {
        if (mounted) {
          // No need for streak card animation anymore - the overlay handles it
          setState(() {
            _isStreakAnimating = false;
            _animatingOldStreak = null;
            _animatingNewStreak = null;
          });
        }
      }
    );
  }

  void _animateStreakCard() async {
    if (!mounted) return;

    // Reset and start the animation
    _streakCardController.reset();
    await _streakCardController.forward();

    if (mounted) {
      setState(() {
        _isStreakAnimating = false;
        _animatingOldStreak = null;
        _animatingNewStreak = null;
      });
    }
  }

  /// Animate the streak card border to draw user attention
  /// Only triggers if streak reminders are not enabled
  void _triggerStreakAttentionAnimation(UserService userService) {
    if (!mounted) return;

    // Only animate if streak reminders are NOT enabled (to encourage enabling them)
    if (userService.notifyStreakReminders) {
      return;
    }

    // Don't interrupt if already animating
    if (_isStreakAttentionAnimating) return;

    setState(() {
      _isStreakAttentionAnimating = true;
    });

    _streakAttentionController.reset();
    _streakAttentionController.forward();

    print('🔥 Streak attention animation triggered');
  }

  void _onScrollPositionRequested(Map<String, dynamic> scrollInfo) {
    if (!mounted) return;
    
    // Don't restore position if user is currently scrolling
    if (_isUserScrolling) {
      print('Feed: Skipping scroll position restoration - user is scrolling');
      return;
    }
    
    // Simple approach: just restore to the original scroll position where the user started
    final targetQuestionId = scrollInfo['question_id']?.toString();
    
    if (targetQuestionId != null && _questionScrollPositions.containsKey(targetQuestionId)) {
      final originalPosition = _questionScrollPositions[targetQuestionId]!;
      
      if (_scrollController.hasClients) {
        // Ensure position is within bounds
        final maxScrollOffset = _scrollController.position.maxScrollExtent;
        final clampedPosition = originalPosition.clamp(0.0, maxScrollOffset);
        
        print('Feed: Restoring scroll position to $clampedPosition for question $targetQuestionId');
        
        // Smoothly animate back to the original position
        _scrollController.animateTo(
          clampedPosition,
          duration: Duration(milliseconds: 600),
          curve: Curves.easeInOut,
        );
      }
    }
  }

  // Load saved feed settings from SharedPreferences
  Future<void> _loadSavedFeedSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      
      // Load feed mode (default to trending)
      final savedFeedMode = prefs.getInt('feed_mode') ?? 0;
      final savedSortBy = prefs.getString('sort_by') ?? 'trending';
      final savedFeedSetting = prefs.getInt('feed_setting') ?? 0;
      
      setState(() {
        _currentFeedMode = savedFeedMode.clamp(0, _feedModes.length - 1);
        _sortBy = savedSortBy;
        // _locationFilter is now final and always global
        _feedSetting = FeedSetting.values[savedFeedSetting.clamp(0, FeedSetting.values.length - 1)];
      });
      
      // Note: Local boost setting will be handled in initState after providers are ready
      
      print('Feed: Loaded saved settings - mode: ${_feedModes[_currentFeedMode]}, sortBy: $_sortBy, locationFilter: ${_locationFilter.name}');
    } catch (e) {
      print('Error loading feed settings: $e');
      // Use defaults if loading fails
      setState(() {
        _currentFeedMode = 0;
        _sortBy = 'trending';
        // _locationFilter is now final and always global
        _feedSetting = FeedSetting.showAll;
      });
    }
  }

  // Save feed settings to SharedPreferences
  Future<void> _saveFeedSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('feed_mode', _currentFeedMode);
      await prefs.setString('sort_by', _sortBy);
      await prefs.setInt('feed_setting', _feedSetting.index);
      // Location filter is now always global, no need to save it
      print('Feed: Saved settings - mode: ${_feedModes[_currentFeedMode]}, sortBy: $_sortBy, locationFilter: ${_locationFilter.name}');
    } catch (e) {
      print('Error saving feed settings: $e');
    }
  }

  Future<void> _loadOptimizedQuestionsWithPreload() async {
    final userService = Provider.of<UserService>(context, listen: false);
    final locationService = Provider.of<LocationService>(context, listen: false);
    
    // Clear stored scroll positions when loading new questions
    _questionScrollPositions.clear();
    
    // Reset comment loading state for new feed
    _resetCommentLoadingState();
    
    // Build server-side filters with location filtering
    final filters = _buildFiltersWithLocation(userService, locationService);
    
    final questionService = context.read<QuestionService>();
    
    // Use optimized Edge Function with v3 materialized view (includes engagement data)
    final sortedQuestions = await questionService.fetchOptimizedFeed(
      feedType: _sortBy,
      filters: filters,
      userService: userService,
      useCache: true,
    );
    
    // Update questions list for immediate display
    questionService.updateQuestions(sortedQuestions);
    
    // Initialize vote count tracking
    _initializeVoteCountTracking(sortedQuestions);
    
    print('Feed: Loaded questions with optimized Edge Function v3 - mode: ${_feedModes[_currentFeedMode]}, questions: ${sortedQuestions.length}');
  }

  // Start optimized polling for vote count updates (Edge Function provides accurate counts)
  void _startVoteCountPolling() {
    // Prevent duplicate polling timers
    if (_voteCountPollTimer != null) {
      _voteCountPollTimer!.cancel();
    }
    
    // Execute first poll immediately to get fresh vote counts right away
    // This helps when users return from voting and expect to see updated tallies
    if (mounted) {
      _checkForVoteCountUpdates().then((_) {
        // Only log once per app session
        if (!_hasLoggedPollingStart && mounted) {
          print('Feed: Started optimized vote count polling immediately, then every 1 minute (reduced frequency for cost optimization)');
          _hasLoggedPollingStart = true;
        }
      });
    }
    
    // Set up periodic polling every 1 minute after the initial immediate check
    _voteCountPollTimer = Timer.periodic(Duration(minutes: 1), (timer) async {
      if (!mounted) {
        timer.cancel();
        return;
      }
      
      // Skip polling if paused
      if (_isPollingPaused) {
        return;
      }
      
      await _checkForVoteCountUpdates();
    });
  }

  // Public method to trigger immediate vote count update (called when users return from answering)
  void triggerImmediateVoteCountUpdate() {
    if (mounted && !_isPollingPaused) {
      print('Feed: Triggering immediate vote count update after user answered question');
      // Add small delay to prevent race conditions with widget disposal
      Future.delayed(Duration(milliseconds: 100), () {
        if (mounted) {
          _checkForVoteCountUpdates();
        }
      });
    }
  }

  // Public method to trigger immediate vote count update for a specific question
  void triggerImmediateVoteCountUpdateForQuestion(String questionId) {
    if (mounted && !_isPollingPaused) {
      print('Feed: Triggering immediate vote count update for specific question $questionId');
      // Add a small delay to allow database to be updated
      Future.delayed(Duration(milliseconds: 50), () {
        if (mounted) {
          _checkForSpecificQuestionVoteCount(questionId);
        }
      });
    }
  }

  // Public method to scroll to top of the feed (called by home button/icon)
  void scrollToTop() {
    _safeAnimateToTop(reason: 'user_requested');
  }

  // Pause vote count polling (e.g., when app goes to background)
  void _pauseVoteCountPolling() {
    _isPollingPaused = true;
    print('Feed: Paused vote count polling');
  }

  // Resume vote count polling (e.g., when app comes to foreground)
  void _resumeVoteCountPolling() {
    _isPollingPaused = false;
    print('Feed: Resumed vote count polling');
  }

  // Check for vote count updates on a specific question
  Future<void> _checkForSpecificQuestionVoteCount(String targetQuestionId) async {
    // Safety check: ensure widget is still mounted before accessing context
    if (!mounted) return;
    
    // Capture services before async operations to avoid disposal issues
    final questionService = Provider.of<QuestionService>(context, listen: false);
    
    try {
      final questions = questionService.questions;
      
      // Find the specific question in our list
      final questionIndex = questions.indexWhere((q) => q['id']?.toString() == targetQuestionId);
      if (questionIndex == -1) {
        print('Feed: Question $targetQuestionId not found in current feed');
        return;
      }
      
      final question = questions[questionIndex];
      final questionType = question['type']?.toString();
      
      try {
        print('Feed: Checking vote count for specific question $targetQuestionId');
        final currentCount = await questionService.getAccurateVoteCount(targetQuestionId, questionType);
        final lastKnownCount = _lastKnownVoteCounts[targetQuestionId] ?? question['votes'] ?? 0;
        
        if (currentCount != lastKnownCount) {
          print('Feed: Vote count updated for question $targetQuestionId: $lastKnownCount → $currentCount');
          
          // Update the question's vote count
          question['votes'] = currentCount;
          _lastKnownVoteCounts[targetQuestionId] = currentCount;
          
          // Notify QuestionService listeners so Consumer widgets rebuild
          questionService.notifyListeners();
          
          // Safety check before setState
          if (mounted) {
            setState(() {
              _lastVoteCountUpdate = DateTime.now();
            });
          }
          
          print('Feed: Successfully updated vote count for question $targetQuestionId');
        } else {
          print('Feed: No vote count change for question $targetQuestionId (still $currentCount)');
        }
      } catch (e) {
        print('Feed: Error checking vote count for question $targetQuestionId: $e');
      }
    } catch (e) {
      print('Feed: Error in specific question vote count check: $e');
    }
  }

  // Check for vote count updates on visible questions
  Future<void> _checkForVoteCountUpdates() async {
    // Safety check: ensure widget is still mounted before accessing context
    if (!mounted) return;
    
    // Capture services before async operations to avoid disposal issues
    final questionService = Provider.of<QuestionService>(context, listen: false);
    final userService = Provider.of<UserService>(context, listen: false);
    final locationService = Provider.of<LocationService>(context, listen: false);
    final tempFilterNotifier = Provider.of<TemporaryCategoryFilterNotifier>(context, listen: false);
    
    try {
      final questions = questionService.questions;
      if (questions.isEmpty) return;
      
      // Apply the same filtering logic as the main UI to get the actual visible questions
      final filteredQuestions = questions.where((question) {
        // Filter out current Question of the Day from regular feed to avoid duplication
        final qotd = questionService.questionOfTheDay;
        if (qotd != null && question['id'] == qotd['id']) {
          return false;
        }
        
        // Filter out private questions - they should never appear in main feed
        if (question['is_private'] == true) {
          return false;
        }
        
        // Filter out NSFW content if not enabled
        if (question['is_nsfw'] == true && !userService.showNSFWContent) {
          return false;
        }

        // Filter out answered questions if setting is enabled
        if (userService.hideAnsweredQuestions && userService.hasAnsweredQuestion(question['id'])) {
          return false;
        }

        // Filter out reported questions that should be hidden
        if (userService.shouldHideReportedQuestion(question['id'].toString())) {
          return false;
        }

        // Filter out dismissed questions
        if (userService.isQuestionDismissed(question['id'].toString())) {
          return false;
        }

        // Filter by enabled question types
        final questionType = question['type']?.toString();
        if (questionType != null && !userService.isQuestionTypeEnabled(questionType)) {
          return false;
        }

        // Filter by enabled categories (but allow questions without categories)
        final questionCategories = question['categories'] as List<dynamic>?;
        if (questionCategories != null && questionCategories.isNotEmpty) {
          // If there's a temporary category filter, only show questions from that category
          if (tempFilterNotifier.hasTemporaryCategoryFilter) {
            final hasTemporaryCategory = questionCategories.any((category) {
              final categoryName = category.toString();
              return categoryName == tempFilterNotifier.temporaryCategoryFilter;
            });
            if (!hasTemporaryCategory) {
              return false;
            }
          } else {
            // Normal filtering: check if at least one category is enabled
            final hasEnabledCategory = questionCategories.any((category) {
              final categoryName = category.toString(); // Categories are now just strings
              return userService.enabledCategories.contains(categoryName);
            });
            if (!hasEnabledCategory) {
              return false;
            }
          }
        } else {
          // If question has no categories and there's a temporary filter, don't show it
          if (tempFilterNotifier.hasTemporaryCategoryFilter) {
            return false;
          }
        }

        return true;
      }).toList();
      
      // Get currently visible questions (limit to first 10 for vote count polling)
      final visibleQuestions = filteredQuestions.take(10).toList();
      
      bool hasUpdates = false;
      
      // Check vote counts for visible questions (limit to first 10 to avoid too many DB calls)
      final questionsToCheck = visibleQuestions.take(10).toList();
      
      for (var question in questionsToCheck) {
        final questionId = question['id']?.toString();
        final questionType = question['type']?.toString();
        
        if (questionId == null) continue;
        
        try {
          final currentCount = await questionService.getAccurateVoteCount(questionId, questionType);
          final lastKnownCount = _lastKnownVoteCounts[questionId] ?? question['votes'] ?? 0;
          
          // Check if vote count changed significantly (more than 1 vote or >10% change)
          final voteChange = (currentCount - lastKnownCount).abs();
          final percentChange = lastKnownCount > 0 ? voteChange / lastKnownCount : (currentCount > 0 ? 1.0 : 0.0);
          
          if (voteChange > 0 && (voteChange >= 1 || percentChange > 0.1)) {
            question['votes'] = currentCount;
            _lastKnownVoteCounts[questionId] = currentCount;
            hasUpdates = true;
            
            print('Feed: Vote count updated for question $questionId: $lastKnownCount → $currentCount');
          }
        } catch (e) {
          print('Feed: Error checking vote count for question $questionId: $e');
        }
      }
      
      // Update UI if there were changes
      if (hasUpdates && mounted) {
        // Notify QuestionService listeners so Consumer widgets rebuild
        questionService.notifyListeners();
        
        setState(() {
          _lastVoteCountUpdate = DateTime.now();
        });
        print('Feed: Updated vote counts for ${questionsToCheck.length} visible questions');
        
        // Debug: Show updated vote counts
        for (var question in questionsToCheck.take(3)) {
          final questionId = question['id']?.toString();
          final voteCount = question['votes'];
          print('Feed: Question $questionId now has $voteCount votes');
        }
      }
    } catch (e) {
      print('Feed: Error in vote count polling: $e');
    }
  }



  // Update engagement data (votes, reacts, comments) sequentially starting with visible questions (used during manual refresh)
  void _updateVoteCountsSequentially(List<dynamic> questions, QuestionService questionService) async {
    if (questions.isEmpty) return;
    
    // Prioritize first 15 questions (what users see initially), then continue with rest
    final priorityQuestions = questions.take(15).toList();
    final remainingQuestions = questions.skip(15).toList();
    
    print('📊 Updating engagement data: ${priorityQuestions.length} priority + ${remainingQuestions.length} remaining');
    
    // Update priority questions quickly (visible ones)
    for (int i = 0; i < priorityQuestions.length; i++) {
      if (!mounted) return;
      
      final question = priorityQuestions[i];
      await _updateSingleQuestionVoteCount(question, questionService, i + 1, priorityQuestions.length, true);
      
      // Small delay between updates to avoid overwhelming UI
      if (i < priorityQuestions.length - 1) {
        await Future.delayed(Duration(milliseconds: 100));
      }
    }
    
    // Update remaining questions more slowly in background
    for (int i = 0; i < remainingQuestions.length; i++) {
      if (!mounted) return;
      
      final question = remainingQuestions[i];
      await _updateSingleQuestionVoteCount(question, questionService, i + 1, remainingQuestions.length, false);
      
      // Longer delay for background updates
      if (i < remainingQuestions.length - 1) {
        await Future.delayed(Duration(milliseconds: 300));
      }
    }
    
    print('✅ Completed sequential engagement updates for all ${questions.length} questions');
  }
  
  // Update engagement data (votes, reacts, comments) for a single question
  Future<void> _updateSingleQuestionVoteCount(
    Map<String, dynamic> question, 
    QuestionService questionService,
    int current,
    int total,
    bool isPriority
  ) async {
    final questionId = question['id']?.toString();
    final questionType = question['type']?.toString();
    
    if (questionId == null) return;
    
    try {
      // Get fresh vote count from database
      final freshVoteCount = await questionService.getAccurateVoteCount(questionId, questionType);
      final oldVoteCount = question['votes'] ?? 0;
      
      // Get fresh engagement data from the materialized view (same source as Edge Function)
      final engagementData = await questionService.getQuestionEngagementFromView(questionId);
      final oldReactionCount = _getReactionCount(question);
      final oldCommentCount = _getCommentCount(question);
      
      // Update the question's data
      question['votes'] = freshVoteCount;
      if (engagementData != null) {
        // Update only the counts, preserve existing reactions data structure
        question['reaction_count'] = engagementData['reaction_count'] ?? 0;
        question['comment_count'] = engagementData['comment_count'] ?? 0;
      }
      _lastKnownVoteCounts[questionId] = freshVoteCount;
      
      // Update UI immediately so users see the change
      if (mounted) {
        questionService.notifyListeners();
        setState(() {
          _lastVoteCountUpdate = DateTime.now();
        });
      }
      
      // Log significant changes
      final newReactionCount = engagementData?['reaction_count'] ?? 0;
      final newCommentCount = engagementData?['comment_count'] ?? 0;
      final hasChanges = freshVoteCount != oldVoteCount || 
                        newReactionCount != oldReactionCount ||
                        newCommentCount != oldCommentCount;
                        
      if (hasChanges) {
        final prefix = isPriority ? '🎯' : '📋';
        print('$prefix Updated engagement [$current/$total]: question ${questionId.substring(0, 8)}...');
        if (freshVoteCount != oldVoteCount) {
          print('  Votes: $oldVoteCount → $freshVoteCount');
        }
        if (newReactionCount != oldReactionCount) {
          print('  Reactions: $oldReactionCount → $newReactionCount');
        }
        if (newCommentCount != oldCommentCount) {
          print('  Comments: $oldCommentCount → $newCommentCount');
        }
      }
      
    } catch (e) {
      print('❌ Error updating vote count for question $questionId: $e');
    }
  }

  // Initialize vote counts tracking when questions are loaded
  void _initializeVoteCountTracking(List<dynamic> questions) {
    _lastKnownVoteCounts.clear();
    for (var question in questions) {
      final questionId = question['id']?.toString();
      final voteCount = question['votes'] ?? 0;
      if (questionId != null) {
        _lastKnownVoteCounts[questionId] = voteCount;
      }
    }
    print('Feed: Initialized vote count tracking for ${_lastKnownVoteCounts.length} questions');
    
    // Trigger immediate vote count update to ensure fresh data on app start
    if (mounted && !_isPollingPaused) {
      print('Feed: Triggering immediate vote count update after initialization');
      _checkForVoteCountUpdates();
    }
  }

  @override
  void dispose() {
    _scrollController.removeListener(_scrollListener);
    _scrollController.dispose();
    _voteCountPollTimer?.cancel(); // Cancel vote count polling timer
    _scrollEndTimer?.cancel(); // Cancel scroll end detection timer
    _pulseController.dispose(); // Dispose of pulse animation controller
    _streakCardController.dispose(); // Dispose of streak card animation controller
    _streakAttentionController.dispose(); // Dispose of streak attention animation controller

    // Remove lifecycle observer
    WidgetsBinding.instance.removeObserver(this);
    
    // Remove vote count update event listener
    VoteCountUpdateEvent.removeListener(_onAnswerSubmitted);
    
    // Remove streak update event listener
    StreakUpdateEvent.removeListener(_onStreakExtended);
    
    // Remove scroll position event listener
    ScrollPositionEvent.removeListener(_onScrollPositionRequested);
    
    // Remove temporary category filter listener
    _tempFilterNotifier?.removeListener(_onCategoryFilterChanged);
    
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    
    switch (state) {
      case AppLifecycleState.resumed:
        // App came to foreground - resume polling
        print('Feed: App resumed, resuming vote count polling');
        _resumeVoteCountPolling();
        break;
      case AppLifecycleState.paused:
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        // App went to background or was closed - pause polling
        print('Feed: App backgrounded/closed, pausing vote count polling');
        _pauseVoteCountPolling();
        break;
      case AppLifecycleState.hidden:
        // App is hidden but still running - pause polling
        print('Feed: App hidden, pausing vote count polling');
        _pauseVoteCountPolling();
        break;
    }
  }

  void _scrollListener() {
    // Track user scrolling
    _onUserScrollStart();
    
    // Update navigation visibility based on scroll position
    _updateNavigationVisibility();
    
    // Load more when user is near the end (80% scrolled)
    if (_scrollController.position.pixels >= _scrollController.position.maxScrollExtent * 0.8 && !_hasReachedEnd && !_isLoadingMore) {
      _loadMoreQuestions();
    }
    
    // Progressive comment loading - start loading comments as user scrolls down (60% scrolled)
    if (_scrollController.position.pixels >= _scrollController.position.maxScrollExtent * 0.6 && !_isLoadingComments && _commentLoadingQueue.isNotEmpty) {
      _loadMoreComments();
    }
  }

  // Update navigation visibility based on scroll position and user interaction
  void _updateNavigationVisibility() {
    if (!mounted || !_scrollController.hasClients) return;
    
    final navigationNotifier = Provider.of<NavigationVisibilityNotifier>(context, listen: false);
    
    // Update touch state first
    navigationNotifier.setUserTouching(_isUserTouching);
    
    // Update navigation visibility based on current scroll state
    navigationNotifier.updateScrollPosition(
      currentOffset: _scrollController.offset,
      maxScrollExtent: _scrollController.position.maxScrollExtent,
      isUserScrolling: _isUserScrolling,
    );
  }

  // Handle scroll notifications for precise touch detection
  bool _onScrollNotification(ScrollNotification notification) {
    if (notification is ScrollStartNotification) {
      // User started scrolling (finger down)
      _isUserTouching = true;
      _isUserScrolling = true;
      _refreshHapticTriggered = false; // Reset haptic flag for new scroll
      _cumulativeOverscroll = 0.0; // Reset cumulative overscroll for new gesture
      _scrollEndTimer?.cancel();
      _updateNavigationVisibility();
    } else if (notification is ScrollUpdateNotification) {
      // User is actively scrolling
      _isUserScrolling = true;
      _updateNavigationVisibility();

      // Check for overscroll at top (pull to refresh threshold) - iOS path
      // On iOS, elastic overscroll produces negative pixels
      if (notification.metrics.pixels < 0 && !_refreshHapticTriggered) {
        final overscrollAmount = notification.metrics.pixels.abs();
        if (overscrollAmount >= 80) {
          _refreshHapticTriggered = true;
          AppHaptics.mediumImpact();
        }
      }
    } else if (notification is OverscrollNotification) {
      // Android path: RefreshIndicator consumes overscroll, so pixels never
      // go negative. Instead, Android emits OverscrollNotification with the
      // overscroll amount. Track cumulative overscroll to match iOS threshold.
      if (notification.metrics.pixels <= 0 && !_refreshHapticTriggered) {
        _cumulativeOverscroll += notification.overscroll.abs();
        if (_cumulativeOverscroll >= 80) {
          _refreshHapticTriggered = true;
          AppHaptics.mediumImpact();
        }
      }
    } else if (notification is ScrollEndNotification) {
      _cumulativeOverscroll = 0.0; // Reset for next gesture
      // User lifted finger and scrolling has ended
      _isUserTouching = false;
      _refreshHapticTriggered = false; // Reset for next pull
      _scrollEndTimer?.cancel();
      _scrollEndTimer = Timer(Duration(milliseconds: 100), () {
        if (mounted) {
          _isUserScrolling = false;
          _updateNavigationVisibility();
        }
      });
    }
    return false; // Allow other listeners to process
  }

  // Legacy method - now simplified
  void _onUserScrollStart() {
    _isUserScrolling = true;
  }

  // Helper method to check if user is near top of feed (currently unused but kept for future use)
  bool _isNearTop() {
    if (!_scrollController.hasClients) return false;
    return _scrollController.offset < 200; // Within 200 pixels of top
  }

  // Helper method to check if user is near bottom of feed
  bool _isNearBottom() {
    if (!_scrollController.hasClients) return false;
    final maxScroll = _scrollController.position.maxScrollExtent;
    return _scrollController.offset > maxScroll * 0.8; // 80% down
  }

  // Safe method to animate to top only when appropriate
  void _safeAnimateToTop({required String reason, Duration? duration}) {
    if (!mounted || !_scrollController.hasClients) return;
    
    // Don't interrupt user scrolling unless they explicitly requested it
    if (_isUserScrolling && reason != 'user_requested') {
      print('Feed: Skipping auto-scroll to top - user is scrolling ($reason)');
      return;
    }
    
    print('Feed: Scrolling to top - $reason');
    
    // Show navigation when scrolling to top
    final navigationNotifier = Provider.of<NavigationVisibilityNotifier>(context, listen: false);
    navigationNotifier.showNavigation(reason: 'scroll_to_top');
    
    _scrollController.animateTo(
      0.0,
      duration: duration ?? Duration(milliseconds: 500),
      curve: Curves.easeInOut,
    );
  }

  void _showThanksMessageTemporarily() {
    // This method is no longer needed as we're not using animation
  }


  bool _isQuestionTargetedToUser(Map<String, dynamic> question, LocationService locationService) {
    final targeting = question['targeting_type']?.toString();
    
    if (targeting == 'city') {
      // Check if question is targeted to user's city or same county within same country
      final questionCityId = question['city_id']?.toString();
      final userCityId = locationService.selectedCity?['id']?.toString();
      
      if (questionCityId != null && userCityId != null) {
        // Same city - directly targeted
        if (questionCityId == userCityId) {
          return true;
        }
        
        // Different cities - check if same county and country
        final questionCountryCode = question['country_code']?.toString() ?? 
                                   question['city_country_code']?.toString();
        final questionAdmin2Code = question['admin2_code']?.toString();
        
        final userCountryCode = locationService.selectedCity?['country_code']?.toString();
        final userAdmin2Code = locationService.selectedCity?['admin2_code']?.toString();
        
        // Targeted if same country AND same admin2 (county/district)
        return questionCountryCode != null && userCountryCode != null && 
               questionAdmin2Code != null && userAdmin2Code != null &&
               questionCountryCode == userCountryCode && 
               questionAdmin2Code == userAdmin2Code;
      }
      
      return false;
    } else if (targeting == 'country') {
      // Check if question is targeted to user's country
      final questionCountryCode = question['country_code']?.toString();
      
      // User location stores country in 'country_code', selectedCity stores it in 'country_code'
      final userCountryCode = locationService.userLocation?['country_code']?.toString() ??
                              locationService.selectedCity?['country_code']?.toString();
      
      final isTargeted = questionCountryCode != null && userCountryCode != null && questionCountryCode == userCountryCode;
      return isTargeted;
    }
    
    // For globe targeting or any other targeting, check for mentioned countries
    final mentionedCountries = question['mentioned_countries'] as List<dynamic>?;
    if (mentionedCountries != null && mentionedCountries.isNotEmpty) {
      final userCountryName = locationService.userLocation?['country_name_en']?.toString();
      if (userCountryName != null) {
        final isTargeted = mentionedCountries.any((country) => 
          country.toString().toLowerCase() == userCountryName.toLowerCase());
        return isTargeted;
      }
    }
    
    return false; // Globe targeting or no match
  }

  Future<String> _getTargetingLabel(Map<String, dynamic> question, LocationService locationService) async {
    final targeting = question['targeting_type']?.toString();
    
    if (targeting == 'city') {
      // Show the city the question is addressed to, not the user's city
      // Try to get city name from the nested cities object (from JOIN query)
      String? questionCityName;
      
      // First try the nested cities data from JOIN
      final cities = question['cities'];
      if (cities != null) {
        if (cities is List && cities.isNotEmpty) {
          questionCityName = cities[0]['name']?.toString();
        } else if (cities is Map) {
          questionCityName = cities['name']?.toString();
        }
      }
      
      // Fallback to direct city_name field if available
      questionCityName ??= question['city_name']?.toString();
      
      if (questionCityName != null && questionCityName.isNotEmpty) {
        return questionCityName;
      }
      
      // If still no city name, fetch it from the database using city_id
      final questionCityId = question['city_id']?.toString();
      if (questionCityId != null) {
        try {
          final cityData = await supabase
              .from('cities')
              .select('name')
              .eq('id', questionCityId)
              .single();
          
          final fetchedCityName = cityData['name']?.toString();
          if (fetchedCityName != null && fetchedCityName.isNotEmpty) {
            // Cache the city name in the question object for future use
            question['city_name'] = fetchedCityName;
            return fetchedCityName;
          }
        } catch (e) {
          print('Error fetching city name for city_id $questionCityId: $e');
        }
      }
      
      // Last resort fallback - but this shouldn't happen for valid city-targeted questions
      return 'Unknown City';
    } else if (targeting == 'country') {
      // Show the country the question is addressed to, not the user's country
      final questionCountryCode = question['country_code']?.toString();
      if (questionCountryCode != null && questionCountryCode.isNotEmpty) {
        // Try to get country name from question or convert country code to name
        final questionCountryName = question['country_name']?.toString();
        if (questionCountryName != null && questionCountryName.isNotEmpty) {
          return questionCountryName;
        }
        // Convert country code to full country name
        return _getFullCountryName(questionCountryCode);
      }
      // Fallback to user's country if question country not available
      final userCountryName = locationService.selectedCountry;
      return userCountryName ?? 'Unknown Country';
    } else {
      // Check for mentioned countries
      final mentionedCountries = question['mentioned_countries'] as List<dynamic>?;
      if (mentionedCountries != null && mentionedCountries.isNotEmpty) {
        // Return the first mentioned country (this is the target)
        return mentionedCountries.first.toString();
      }
    }
    
    return 'World';
  }

  String _getFullCountryName(String countryCode) {
    // Map of common country codes to full names
    final countryNames = <String, String>{
      'US': 'United States',
      'CA': 'Canada',
      'GB': 'United Kingdom',
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
      'KR': 'South Korea',
      'NL': 'Netherlands',
      'BE': 'Belgium',
      'CH': 'Switzerland',
      'AT': 'Austria',
      'SE': 'Sweden',
      'NO': 'Norway',
      'DK': 'Denmark',
      'FI': 'Finland',
      'PL': 'Poland',
      'CZ': 'Czech Republic',
      'HU': 'Hungary',
      'GR': 'Greece',
      'PT': 'Portugal',
      'IE': 'Ireland',
      'NZ': 'New Zealand',
      'ZA': 'South Africa',
      'AR': 'Argentina',
      'CL': 'Chile',
      'CO': 'Colombia',
      'PE': 'Peru',
      'VE': 'Venezuela',
      'TH': 'Thailand',
      'SG': 'Singapore',
      'MY': 'Malaysia',
      'PH': 'Philippines',
      'ID': 'Indonesia',
      'VN': 'Vietnam',
      'TW': 'Taiwan',
      'HK': 'Hong Kong',
      'EG': 'Egypt',
      'SA': 'Saudi Arabia',
      'AE': 'United Arab Emirates',
      'IL': 'Israel',
      'TR': 'Turkey',
      'UA': 'Ukraine',
      'RO': 'Romania',
      'BG': 'Bulgaria',
      'HR': 'Croatia',
      'SI': 'Slovenia',
      'SK': 'Slovakia',
      'LT': 'Lithuania',
      'LV': 'Latvia',
      'EE': 'Estonia',
    };
    
    return countryNames[countryCode.toUpperCase()] ?? countryCode.toUpperCase();
  }

  String _getCountryFlagEmoji(String countryCode) {
    // Map of country codes to flag emojis
    final countryFlags = <String, String>{
      'US': '🇺🇸',
      'CA': '🇨🇦', 
      'GB': '🇬🇧',
      'AU': '🇦🇺',
      'DE': '🇩🇪',
      'FR': '🇫🇷',
      'IT': '🇮🇹',
      'ES': '🇪🇸',
      'JP': '🇯🇵',
      'CN': '🇨🇳',
      'IN': '🇮🇳',
      'BR': '🇧🇷',
      'MX': '🇲🇽',
      'RU': '🇷🇺',
      'KR': '🇰🇷',
      'NL': '🇳🇱',
      'BE': '🇧🇪',
      'CH': '🇨🇭',
      'AT': '🇦🇹',
      'SE': '🇸🇪',
      'NO': '🇳🇴',
      'DK': '🇩🇰',
      'FI': '🇫🇮',
      'PL': '🇵🇱',
      'CZ': '🇨🇿',
      'HU': '🇭🇺',
      'GR': '🇬🇷',
      'PT': '🇵🇹',
      'IE': '🇮🇪',
      'NZ': '🇳🇿',
      'ZA': '🇿🇦',
      'AR': '🇦🇷',
      'CL': '🇨🇱',
      'CO': '🇨🇴',
      'PE': '🇵🇪',
      'VE': '🇻🇪',
      'TH': '🇹🇭',
      'SG': '🇸🇬',
      'MY': '🇲🇾',
      'PH': '🇵🇭',
      'ID': '🇮🇩',
      'VN': '🇻🇳',
      'TW': '🇹🇼',
      'HK': '🇭🇰',
      'EG': '🇪🇬',
      'SA': '🇸🇦',
      'AE': '🇦🇪',
      'IL': '🇮🇱',
      'TR': '🇹🇷',
      'UA': '🇺🇦',
      'RO': '🇷🇴',
      'BG': '🇧🇬',
      'HR': '🇭🇷',
      'SI': '🇸🇮',
      'SK': '🇸🇰',
      'LT': '🇱🇹',
      'LV': '🇱🇻',
      'EE': '🇪🇪',
      // Middle East & Gulf Countries
      'OM': '🇴🇲', // Oman
      'QA': '🇶🇦', // Qatar
      'KW': '🇰🇼', // Kuwait
      'BH': '🇧🇭', // Bahrain
      'JO': '🇯🇴', // Jordan
      'LB': '🇱🇧', // Lebanon
      'SY': '🇸🇾', // Syria
      'IQ': '🇮🇶', // Iraq
      'IR': '🇮🇷', // Iran
      'YE': '🇾🇪', // Yemen
      // Africa
      'MA': '🇲🇦', // Morocco
      'DZ': '🇩🇿', // Algeria
      'TN': '🇹🇳', // Tunisia
      'LY': '🇱🇾', // Libya
      'SD': '🇸🇩', // Sudan
      'ET': '🇪🇹', // Ethiopia
      'KE': '🇰🇪', // Kenya
      'NG': '🇳🇬', // Nigeria
      'GH': '🇬🇭', // Ghana
      'CI': '🇨🇮', // Côte d'Ivoire
      'SN': '🇸🇳', // Senegal
      'ML': '🇲🇱', // Mali
      'BF': '🇧🇫', // Burkina Faso
      'NE': '🇳🇪', // Niger
      'TD': '🇹🇩', // Chad
      'CM': '🇨🇲', // Cameroon
      'CF': '🇨🇫', // Central African Republic
      'CD': '🇨🇩', // Democratic Republic of Congo
      'CG': '🇨🇬', // Republic of Congo
      'GA': '🇬🇦', // Gabon
      'GQ': '🇬🇶', // Equatorial Guinea
      'ST': '🇸🇹', // São Tomé and Príncipe
      'AO': '🇦🇴', // Angola
      'ZM': '🇿🇲', // Zambia
      'ZW': '🇿🇼', // Zimbabwe
      'BW': '🇧🇼', // Botswana
      'NA': '🇳🇦', // Namibia
      'LS': '🇱🇸', // Lesotho
      'SZ': '🇸🇿', // Eswatini
      'MG': '🇲🇬', // Madagascar
      'MU': '🇲🇺', // Mauritius
      'MZ': '🇲🇿', // Mozambique
      'MW': '🇲🇼', // Malawi
      'TZ': '🇹🇿', // Tanzania
      'UG': '🇺🇬', // Uganda
      'RW': '🇷🇼', // Rwanda
      'BI': '🇧🇮', // Burundi
      'DJ': '🇩🇯', // Djibouti
      'SO': '🇸🇴', // Somalia
      'ER': '🇪🇷', // Eritrea
      // Asia Pacific
      'AF': '🇦🇫', // Afghanistan
      'PK': '🇵🇰', // Pakistan
      'BD': '🇧🇩', // Bangladesh
      'LK': '🇱🇰', // Sri Lanka
      'MV': '🇲🇻', // Maldives
      'NP': '🇳🇵', // Nepal
      'BT': '🇧🇹', // Bhutan
      'MM': '🇲🇲', // Myanmar
      'LA': '🇱🇦', // Laos
      'KH': '🇰🇭', // Cambodia
      'BN': '🇧🇳', // Brunei
      'TL': '🇹🇱', // East Timor
      'FJ': '🇫🇯', // Fiji
      'PG': '🇵🇬', // Papua New Guinea
      'SB': '🇸🇧', // Solomon Islands
      'VU': '🇻🇺', // Vanuatu
      'NC': '🇳🇨', // New Caledonia
      'PF': '🇵🇫', // French Polynesia
      'WS': '🇼🇸', // Samoa
      'TO': '🇹🇴', // Tonga
      'TV': '🇹🇻', // Tuvalu
      'KI': '🇰🇮', // Kiribati
      'NR': '🇳🇷', // Nauru
      'FM': '🇫🇲', // Micronesia
      'MH': '🇲🇭', // Marshall Islands
      'PW': '🇵🇼', // Palau
      // Latin America
      'GT': '🇬🇹', // Guatemala
      'BZ': '🇧🇿', // Belize
      'SV': '🇸🇻', // El Salvador
      'HN': '🇭🇳', // Honduras
      'NI': '🇳🇮', // Nicaragua
      'CR': '🇨🇷', // Costa Rica
      'PA': '🇵🇦', // Panama
      'CU': '🇨🇺', // Cuba
      'JM': '🇯🇲', // Jamaica
      'HT': '🇭🇹', // Haiti
      'DO': '🇩🇴', // Dominican Republic
      'PR': '🇵🇷', // Puerto Rico
      'TT': '🇹🇹', // Trinidad and Tobago
      'BB': '🇧🇧', // Barbados
      'GD': '🇬🇩', // Grenada
      'LC': '🇱🇨', // Saint Lucia
      'VC': '🇻🇨', // Saint Vincent and the Grenadines
      'AG': '🇦🇬', // Antigua and Barbuda
      'KN': '🇰🇳', // Saint Kitts and Nevis
      'DM': '🇩🇲', // Dominica
      'GY': '🇬🇾', // Guyana
      'SR': '🇸🇷', // Suriname
      'UY': '🇺🇾', // Uruguay
      'PY': '🇵🇾', // Paraguay
      'BO': '🇧🇴', // Bolivia
      'EC': '🇪🇨', // Ecuador
      // Europe additions
      'IS': '🇮🇸', // Iceland
      'MT': '🇲🇹', // Malta
      'CY': '🇨🇾', // Cyprus
      'MD': '🇲🇩', // Moldova
      'BY': '🇧🇾', // Belarus
      'RS': '🇷🇸', // Serbia
      'ME': '🇲🇪', // Montenegro
      'BA': '🇧🇦', // Bosnia and Herzegovina
      'MK': '🇲🇰', // North Macedonia
      'AL': '🇦🇱', // Albania
      'XK': '🇽🇰', // Kosovo
      'LU': '🇱🇺', // Luxembourg
      'LI': '🇱🇮', // Liechtenstein
      'AD': '🇦🇩', // Andorra
      'MC': '🇲🇨', // Monaco
      'SM': '🇸🇲', // San Marino
      'VA': '🇻🇦', // Vatican City
      // Central Asia
      'KZ': '🇰🇿', // Kazakhstan
      'UZ': '🇺🇿', // Uzbekistan
      'TM': '🇹🇲', // Turkmenistan
      'TJ': '🇹🇯', // Tajikistan
      'KG': '🇰🇬', // Kyrgyzstan
      'MN': '🇲🇳', // Mongolia
      // Additional African Countries
      'CV': '🇨🇻', // Cape Verde
      'GM': '🇬🇲', // Gambia
      'GN': '🇬🇳', // Guinea
      'GW': '🇬🇼', // Guinea-Bissau
      'LR': '🇱🇷', // Liberia
      'SL': '🇸🇱', // Sierra Leone
      'TG': '🇹🇬', // Togo
      'BJ': '🇧🇯', // Benin
      'MR': '🇲🇷', // Mauritania
      'KM': '🇰🇲', // Comoros
      'SC': '🇸🇨', // Seychelles
      'SS': '🇸🇸', // South Sudan
      // Additional Caribbean
      'BS': '🇧🇸', // Bahamas
      'AI': '🇦🇮', // Anguilla
      'AW': '🇦🇼', // Aruba
      'BQ': '🇧🇶', // Bonaire
      'VG': '🇻🇬', // British Virgin Islands
      'KY': '🇰🇾', // Cayman Islands
      'CW': '🇨🇼', // Curaçao
      'GP': '🇬🇵', // Guadeloupe
      'MQ': '🇲🇶', // Martinique
      'MS': '🇲🇸', // Montserrat
      'SX': '🇸🇽', // Sint Maarten
      'TC': '🇹🇨', // Turks and Caicos
      'VI': '🇻🇮', // US Virgin Islands
      'MF': '🇲🇫', // Saint Martin
      'BL': '🇧🇱', // Saint Barthélemy
      'PM': '🇵🇲', // Saint Pierre and Miquelon
      // Additional Pacific
      'AS': '🇦🇸', // American Samoa
      'CK': '🇨🇰', // Cook Islands
      'GU': '🇬🇺', // Guam
      'MP': '🇲🇵', // Northern Mariana Islands
      'NU': '🇳🇺', // Niue
      'NF': '🇳🇫', // Norfolk Island
      'PN': '🇵🇳', // Pitcairn Islands
      'TK': '🇹🇰', // Tokelau
      'WF': '🇼🇫', // Wallis and Futuna
      // Additional Antarctic and Remote
      'AQ': '🇦🇶', // Antarctica
      'BV': '🇧🇻', // Bouvet Island
      'GS': '🇬🇸', // South Georgia and South Sandwich Islands
      'HM': '🇭🇲', // Heard Island and McDonald Islands
      'IO': '🇮🇴', // British Indian Ocean Territory
      'TF': '🇹🇫', // French Southern Territories
      'UM': '🇺🇲', // United States Minor Outlying Islands
      // Additional European Dependencies
      'AX': '🇦🇽', // Åland Islands
      'FO': '🇫🇴', // Faroe Islands
      'GI': '🇬🇮', // Gibraltar
      'GG': '🇬🇬', // Guernsey
      'IM': '🇮🇲', // Isle of Man
      'JE': '🇯🇪', // Jersey
      'SJ': '🇸🇯', // Svalbard and Jan Mayen
      // Additional Special Cases
      'EH': '🇪🇭', // Western Sahara
      'PS': '🇵🇸', // Palestine
      'TW': '🇹🇼', // Taiwan (already included but worth noting)
      'HK': '🇭🇰', // Hong Kong (already included)
      'MO': '🇲🇴', // Macao
      'FK': '🇫🇰', // Falkland Islands
      'SH': '🇸🇭', // Saint Helena
      'AC': '🇦🇨', // Ascension Island
      'TA': '🇹🇦', // Tristan da Cunha
      'RE': '🇷🇪', // Réunion
      'YT': '🇾🇹', // Mayotte
      'GL': '🇬🇱', // Greenland
      // Historical/Alternative Codes
      'EU': '🇪🇺', // European Union (not a country but commonly used)
      'UN': '🇺🇳', // United Nations (for international questions)
    };
    
    return countryFlags[countryCode.toUpperCase()] ?? '';
  }

  // Cache for background targeting data fetches
  final Set<String> _fetchingTargetingData = <String>{};

  // Fetch targeting data in background and update UI
  void _fetchAndCacheTargetingData(Map<String, dynamic> question) async {
    final questionId = question['id']?.toString();
    if (questionId == null || _fetchingTargetingData.contains(questionId)) return;
    
    _fetchingTargetingData.add(questionId);
    print('🔍 Fetching targeting data for question $questionId...');
    
    try {
      final targetingData = await supabase
          .from('questions')
          .select('targeting_type, country_code')
          .eq('id', questionId)
          .single();
      
      final targetingType = targetingData['targeting_type']?.toString();
      final questionCountryCode = targetingData['country_code']?.toString();
      
      print('✅ Fetched targeting data: targeting_type="$targetingType", country_code="$questionCountryCode"');
      
      // Cache the data in the question object for future use
      question['targeting_type'] = targetingType;
      question['country_code'] = questionCountryCode;
      
      // Trigger rebuild to show correct emoji
      if (mounted) {
        setState(() {});
      }
      
    } catch (e) {
      print('❌ Error fetching targeting data for question $questionId: $e');
    } finally {
      _fetchingTargetingData.remove(questionId);
    }
  }

  // Get sorted questions using cached feeds instead of complex algorithms
  Future<List<dynamic>> _getSortedQuestions(List<dynamic> questions, LocationService locationService, UserService userService) async {
    // If we're using the optimized feeds, just return the questions as-is
    // since they're already sorted by the materialized view
    return questions;
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<TemporaryCategoryFilterNotifier>(
      builder: (context, filterNotifier, child) {
        return Consumer<QuestionService>(
          builder: (context, questionService, child) {
        if (questionService.isLoading) {
          return CurioLoading();
        }

        final questions = questionService.questions;

        return NotificationListener<ScrollNotification>(
          onNotification: _onScrollNotification,
          child: RefreshIndicator(
            edgeOffset: AppBar().preferredSize.height + MediaQuery.of(context).padding.top,
            onRefresh: () async {
            print('User Action: Refreshing feed');

            // Show navigation during refresh
            final navigationNotifier = Provider.of<NavigationVisibilityNotifier>(context, listen: false);
            navigationNotifier.showNavigation(reason: 'pull_to_refresh');
            
            final userService = Provider.of<UserService>(context, listen: false);
            final locationService = Provider.of<LocationService>(context, listen: false);
            final tempFilterNotifier = Provider.of<TemporaryCategoryFilterNotifier>(context, listen: false);
            
            // Check if user is refreshing from a "No Questions Found" state due to filtering
            final currentQuestions = questionService.questions;
            final currentlyFiltered = questions.where((question) {
              // Apply same filtering logic to check if questions are being filtered out
              final qotd = questionService.questionOfTheDay;
              if (qotd != null && question['id'] == qotd['id']) return false;
              if (question['is_private'] == true) return false;
              if (question['is_nsfw'] == true && !userService.showNSFWContent) return false;
              if (userService.hideAnsweredQuestions && userService.hasAnsweredQuestion(question['id'])) return false;
              if (userService.shouldHideReportedQuestion(question['id'].toString())) return false;
              if (userService.isQuestionDismissed(question['id'].toString())) return false;
              
              // Apply feed setting filter
              final hasAnswered = userService.hasAnsweredQuestion(question['id']);
              switch (_feedSetting) {
                case FeedSetting.unanswered: if (hasAnswered) return false; break;
                case FeedSetting.answered: if (!hasAnswered) return false; break;
                case FeedSetting.showAll: break;
              }
              
              final questionType = question['type']?.toString();
              if (questionType != null && !userService.isQuestionTypeEnabled(questionType)) return false;
              
              final questionCategories = question['categories'] as List<dynamic>?;
              if (questionCategories != null && questionCategories.isNotEmpty) {
                if (tempFilterNotifier.hasTemporaryCategoryFilter) {
                  final hasTemporaryCategory = questionCategories.any((category) {
                    return category.toString() == tempFilterNotifier.temporaryCategoryFilter;
                  });
                  if (!hasTemporaryCategory) return false;
                } else {
                  final hasEnabledCategory = questionCategories.any((category) {
                    return userService.enabledCategories.contains(category.toString());
                  });
                  if (!hasEnabledCategory) return false;
                }
              } else {
                if (tempFilterNotifier.hasTemporaryCategoryFilter) return false;
              }
              return true;
            }).toList();
            
            // If user is refreshing from empty state and we have questions that are being filtered out
            final shouldResetFilters = currentlyFiltered.isEmpty && 
                                     currentQuestions.isNotEmpty && 
                                     (userService.hideAnsweredQuestions || 
                                      _feedSetting != FeedSetting.showAll || 
                                      userService.enabledCategories.isEmpty);
            
            if (shouldResetFilters) {
              // Reset filtering settings when user pulls to refresh from empty state
              userService.setHideAnsweredQuestions(false);
              tempFilterNotifier.setTemporaryCategoryFilter(null);
              
              // Enable all categories if none are enabled
              if (userService.enabledCategories.isEmpty) {
                userService.enableAllCategories();
              }
              
              setState(() {
                _sortBy = 'trending';
                _feedSetting = FeedSetting.showAll;
              });
              
              // Save the settings
              SharedPreferences.getInstance().then((prefs) {
                prefs.setString('sort_by', 'trending');
                prefs.setInt('feed_setting', FeedSetting.showAll.index);
              });
            }
            
            final filters = _buildFiltersWithLocation(userService, locationService);
            
            // Reset comment loading state before refresh
            _resetCommentLoadingState();
            
            // Use optimized Edge Function v3 for refresh (with engagement data)
            final refreshedQuestions = await questionService.getFeed(
              feedType: _sortBy,
              filters: filters,
              forceRefresh: true, // Force fresh data from Edge Function
              userService: userService,
            );
            
            // Update questions with fresh data first (no additional sorting needed - Edge Function already sorted)
            questionService.updateQuestions(refreshedQuestions, notify: false);
            
            // Then update state which will trigger rebuild
            setState(() {
              _hasReachedEnd = false;
            });
            
            // Refresh QotD during pull-to-refresh
            _qotdKey.currentState?.refreshQotD();
            
            // Reinitialize vote count tracking after refresh
            _initializeVoteCountTracking(refreshedQuestions);
            
            // TRIGGER SEQUENTIAL VOTE COUNT UPDATE
            // Update vote counts sequentially starting with visible questions
            print('🔄 Starting sequential engagement update for visible questions...');
            _updateVoteCountsSequentially(refreshedQuestions, questionService);

            // Sync streak to server and get leaderboard rank
            // This runs in background and doesn't block the refresh
            userService.syncStreakToServer();

            // Trigger attention animation on streak card to encourage clicking
            // Only shows if streak reminders are not enabled
            _triggerStreakAttentionAnimation(userService);

            print('Feed: Refreshed with Edge Function - mode: ${_feedModes[_currentFeedMode]}, questions: ${refreshedQuestions.length}');
            
            // Show appropriate snackbar message
            if (shouldResetFilters) {
              _showSafeSnackBar('Filters reset to show all questions 🔄', duration: Duration(seconds: 2));
            } else {
              _showSafeSnackBar('Feed Refreshed 🌱', duration: Duration(seconds: 1));
            }
            
            // Only scroll to top if user was near bottom when they refreshed
            // This prevents interrupting users who are browsing mid-feed
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted && _scrollController.hasClients && _isNearBottom()) {
                _safeAnimateToTop(reason: 'pull_to_refresh_from_bottom');
              }
            });
          },
          child: GestureDetector(
            // Remove the drawer opening gesture here since it's now handled by Dismissible widgets on questions
            child: Consumer<LocationService>(
              builder: (context, locationService, child) {
                return Consumer<UserService>(
                  builder: (context, userService, child) {
                    // Remove FutureBuilder for instant display
                    return _buildQuestionsList(questions, locationService, userService);
                  },
                );
              },
            ),
          ),
        ),
        );
        },
      );
      },
    );
  }

  // Set local boost (now always off since we show all posts globally)
  void _setLocalBoostBasedOnLocationFilter(UserService userService) {
    // Always turn OFF local boost since we're showing all posts globally
    userService.setBoostLocalActivity(false);
    print('Feed: Set local boost to ${userService.boostLocalActivity} for global feed');
  }


  // Get the background color for the feed setting button
  Color _getFeedSettingBackgroundColor() {
    switch (_feedSetting) {
      case FeedSetting.showAll:
        return Theme.of(context).primaryColor; // Full primary color
      case FeedSetting.unanswered:
        return Theme.of(context).primaryColor.withOpacity(0.1); // Primary color outline
      case FeedSetting.answered:
        return Colors.grey.withOpacity(0.1); // Grey background
    }
  }

  // Get the border color for the feed setting button
  Color _getFeedSettingBorderColor() {
    switch (_feedSetting) {
      case FeedSetting.showAll:
        return Theme.of(context).primaryColor; // Full primary color
      case FeedSetting.unanswered:
        return Theme.of(context).primaryColor; // Primary color outline
      case FeedSetting.answered:
        return Colors.grey.withOpacity(0.3); // Grey border
    }
  }

  // Get the icon color for the feed setting button
  Color _getFeedSettingIconColor() {
    switch (_feedSetting) {
      case FeedSetting.showAll:
        return Colors.white; // White icon on primary background
      case FeedSetting.unanswered:
        return Theme.of(context).primaryColor; // Primary color icon
      case FeedSetting.answered:
        return Colors.grey; // Grey icon
    }
  }

  // Refresh feed with current location filter
  Future<void> _refreshFeedWithNewFilter() async {
    final questionService = Provider.of<QuestionService>(context, listen: false);
    final userService = Provider.of<UserService>(context, listen: false);
    final locationService = Provider.of<LocationService>(context, listen: false);
    
    // Build filters with current location filter
    final filters = _buildFiltersWithLocation(userService, locationService);
    
    try {
      // Load fresh questions with new filter
      final refreshedQuestions = await questionService.getFeed(
        feedType: _sortBy,
        filters: filters,
        forceRefresh: true,
        userService: userService,
      );
      
      // Update questions
      questionService.updateQuestions(refreshedQuestions, notify: false);
      
      setState(() {
        _hasReachedEnd = false;
      });
      
      // Reinitialize vote count tracking
      _initializeVoteCountTracking(refreshedQuestions);
      
      print('Feed: Refreshed with location filter: ${_locationFilter.name}');
    } catch (e) {
      print('Error refreshing feed with new filter: $e');
    }
  }

  Widget _buildQuestionsList(List<dynamic> questions, LocationService locationService, UserService userService) {
    // Move Provider access outside of callbacks to avoid disposal issues
    if (!mounted) return SizedBox.shrink();
    
    // Calculate consistent padding to account for navigation bars
    final appBarHeight = AppBar().preferredSize.height + MediaQuery.of(context).padding.top;
    final bottomNavHeight = kBottomNavigationBarHeight + MediaQuery.of(context).padding.bottom;
    
    final tempFilterNotifier = Provider.of<TemporaryCategoryFilterNotifier>(context, listen: false);
    final questionService = Provider.of<QuestionService>(context, listen: false);
    final qotd = questionService.questionOfTheDay;
    
    final filteredQuestions = questions.where((question) {
      // Filter out current Question of the Day from regular feed to avoid duplication
      if (qotd != null && question['id'] == qotd['id']) {
        return false;
      }
      
      // Filter out private questions - they should never appear in main feed
      if (question['is_private'] == true) {
        return false;
      }
      
      // Filter out NSFW content if not enabled
      if (question['is_nsfw'] == true && !userService.showNSFWContent) {
        return false;
      }

      // Filter out answered questions if setting is enabled
      if (userService.hideAnsweredQuestions && userService.hasAnsweredQuestion(question['id'])) {
        return false;
      }

      // Filter out reported questions
      if (userService.shouldHideReportedQuestion(question['id'].toString())) {
        return false;
      }

      // Filter out dismissed questions
      if (userService.isQuestionDismissed(question['id'].toString())) {
        return false;
      }

      // Apply feed setting filter (answered/unanswered)
      final hasAnswered = userService.hasAnsweredQuestion(question['id']);
      switch (_feedSetting) {
        case FeedSetting.showAll:
          // Show all questions - no additional filtering
          break;
        case FeedSetting.unanswered:
          // Show only unanswered questions
          if (hasAnswered) {
            return false;
          }
          break;
        case FeedSetting.answered:
          // Show only answered questions
          if (!hasAnswered) {
            return false;
          }
          break;
      }

      // Filter by enabled question types
      final questionType = question['type']?.toString();
      if (questionType != null && !userService.isQuestionTypeEnabled(questionType)) {
        return false;
      }

      // Filter by enabled categories (but allow questions without categories)
      final questionCategories = question['categories'] as List<dynamic>?;
      
      if (questionCategories != null && questionCategories.isNotEmpty) {
        // If there's a temporary category filter, only show questions from that category
        if (tempFilterNotifier.hasTemporaryCategoryFilter) {
          final hasTemporaryCategory = questionCategories.any((category) {
            final categoryName = category.toString();
            return categoryName == tempFilterNotifier.temporaryCategoryFilter;
          });
          if (!hasTemporaryCategory) {
            return false;
          }
        } else {
          // Normal filtering: check if at least one category is enabled
          final hasEnabledCategory = questionCategories.any((category) {
            final categoryName = category.toString(); // Categories are now just strings
            return userService.enabledCategories.contains(categoryName);
          });
          if (!hasEnabledCategory) {
            return false;
          }
        }
      } else {
        // If question has no categories and there's a temporary filter, don't show it
        if (tempFilterNotifier.hasTemporaryCategoryFilter) {
          return false;
        }
      }

      // Show all questions regardless of targeting (global feed)
      return true;
    }).toList();

    // Note: Don't reset _hasReachedEnd here as it interferes with infinite scroll end detection
    // The end flag should only be reset during manual refresh or feed switching

    // Use all filtered questions for infinite scroll (no pagination limit)
    final paginatedQuestions = filteredQuestions;
    
    // Initialize comment loading queue for visible questions
    _initializeCommentLoadingQueue(filteredQuestions.cast<Map<String, dynamic>>().toList());

    if (filteredQuestions.isEmpty) {
      // Show empty state but don't auto-reset - only reset on pull-to-refresh
      
      
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.only(top: appBarHeight + 16),
        children: [
          // Header section (logo and location) - same as when there are questions
          Column(
            children: [
              // Logo and Answer Streak row (same as main content)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    // Logo moved to left
                    Image.asset(
                      'assets/images/RTR-logo_Aug2025.png',
                      height: 80,
                    ),
                    // Answer Streak card on right
                    Consumer<UserService>(
                      builder: (context, userService, child) {
                        final currentStreak = _calculateCurrentAnswerStreak(userService.answeredQuestions);
                        final hasExtendedStreakToday = _hasExtendedStreakToday(userService.answeredQuestions);
                        return FutureBuilder<int>(
                          future: _getLongestAnswerStreak(),
                          builder: (context, snapshot) {
                            final longestStreak = snapshot.data ?? 0;
                            final streakRank = userService.streakRank;
                            final isTopFive = streakRank >= 1 && streakRank <= 5;
                            final showRainbow = isTopFive || currentStreak > 100;
                            return AnimatedBuilder(
                              animation: _streakAttentionAnimation,
                              builder: (context, child) {
                                final glowOpacity = _isStreakAttentionAnimating ? _streakAttentionAnimation.value : 0.0;
                                return Container(
                                  width: 120,
                                  height: 104, // Logo height (80) + spacing (8) + text (~16)
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(8.0),
                                    boxShadow: glowOpacity > 0
                                        ? [
                                            BoxShadow(
                                              color: Theme.of(context).primaryColor.withOpacity(glowOpacity * 0.6),
                                              blurRadius: 16 * glowOpacity,
                                              spreadRadius: 3 * glowOpacity,
                                            ),
                                          ]
                                        : null,
                                  ),
                                  child: Container(
                                    decoration: _getStreakCardDecoration(context, currentStreak, isTopFive: isTopFive),
                                    padding: showRainbow ? EdgeInsets.all(2) : EdgeInsets.zero,
                                    child: Container(
                                      decoration: showRainbow ? BoxDecoration(
                                        color: Theme.of(context).scaffoldBackgroundColor,
                                        borderRadius: BorderRadius.circular(6.0),
                                      ) : null,
                                      child: InkWell(
                                        onTap: () {
                                          AnalyticsService().trackEvent('streak_card_tapped', {'current_streak': currentStreak, 'has_extended_today': hasExtendedStreakToday});
                                          _showAnswerStreakDialog(context, userService);
                                        },
                                        borderRadius: BorderRadius.circular(showRainbow ? 6 : 8),
                                        child: Padding(
                                          padding: EdgeInsets.all(12),
                                          child: AnimatedBuilder(
                                            animation: _pulseAnimation,
                                            builder: (context, child) {
                                              final shouldPulse = _shouldStreakCardPulse(context, hasExtendedStreakToday);
                                              final pulseScale = shouldPulse ? _pulseAnimation.value : 1.0;

                                              return AnimatedBuilder(
                                                animation: _streakCardController,
                                                builder: (context, child) {
                                                  final celebrationScale = _isStreakAnimating ? _streakCardScaleAnimation.value : 1.0;
                                                  final finalScale = pulseScale * celebrationScale;

                                                  // Determine colors for animation
                                                  Color iconColor;
                                                  Color textColor;
                                                  int displayStreak;

                                                  if (_isStreakAnimating) {
                                                    // During animation, show transition from old to new
                                                    final animationProgress = _streakCardController.value;
                                                    if (animationProgress < 0.5) {
                                                      // First half: show old streak with old color
                                                      iconColor = _getStreakCardColorForStreak(_animatingOldStreak ?? 0, false);
                                                      textColor = iconColor;
                                                      displayStreak = _animatingOldStreak ?? currentStreak;
                                                    } else {
                                                      // Second half: transition to new streak with primary color
                                                      final colorProgress = (animationProgress - 0.5) * 2;
                                                      final oldColor = _getStreakCardColorForStreak(_animatingOldStreak ?? 0, false);
                                                      final newColor = Theme.of(context).primaryColor;
                                                      iconColor = Color.lerp(oldColor, newColor, colorProgress) ?? newColor;
                                                      textColor = iconColor;
                                                      displayStreak = _animatingNewStreak ?? currentStreak;
                                                    }
                                                  } else {
                                                    // Normal state
                                                    iconColor = currentStreak > 0
                                                        ? _getStreakCardColor(context, hasExtendedStreakToday)
                                                        : Colors.grey;
                                                    textColor = currentStreak > 0
                                                        ? _getStreakCardColor(context, hasExtendedStreakToday)
                                                        : Colors.grey[600] ?? Colors.grey;
                                                    displayStreak = currentStreak;
                                                  }

                                                  // Show medal instead of flame icon for top 3
                                                  final showMedal = streakRank >= 1 && streakRank <= 3;

                                                  return Transform.scale(
                                                    scale: finalScale,
                                                    child: Row(
                                                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                                      children: [
                                                        if (showMedal)
                                                          Text(
                                                            streakRank == 1 ? '🥇' : streakRank == 2 ? '🥈' : '🥉',
                                                            style: TextStyle(fontSize: 36),
                                                          )
                                                        else
                                                          Icon(
                                                            Icons.local_fire_department,
                                                            color: iconColor,
                                                            size: 40,
                                                          ),
                                                        Text(
                                                          '$displayStreak',
                                                          style: Theme.of(context).textTheme.displayMedium?.copyWith(
                                                            color: textColor,
                                                            fontWeight: FontWeight.bold,
                                                          ),
                                                        ),
                                                      ],
                                                    ),
                                                  );
                                                },
                                              );
                                            },
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                );
                              },
                            );
                          },
                        );
                      },
                    ),
                  ],
                ),
              ),
              SizedBox(height: 16),
              // Show either temporary category filter or Question of the Day
              Consumer2<TemporaryCategoryFilterNotifier, UserService>(
                builder: (context, filterNotifier, userService, child) {
                  if (filterNotifier.hasTemporaryCategoryFilter) {
                    return TemporaryCategoryFilterWidget();
                  }
                  return QuestionOfTheDayWidget(
                    key: _qotdKey,
                    userService: userService,
                    onQOTDClick: _handleQOTDClick,
                  );
                },
              ),
              // Add filter bar for empty state
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0),
                child: Row(
                  children: [
                    Expanded(
                      child: GestureDetector(
                        onTap: () {
                          // Show feed selector popup
                          _showFeedSelectorDialog();
                        },
                        child: Container(
                          height: 50,
                          decoration: BoxDecoration(
                            color: Theme.of(context).primaryColor,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: Theme.of(context).primaryColor),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                _currentFeedMode == 0 ? Icons.trending_up :
                                _currentFeedMode == 1 ? Icons.people : Icons.local_fire_department,
                                color: Colors.white,
                              ),
                              SizedBox(width: 8),
                              Text(
                                _feedModes[_currentFeedMode].substring(0, 1).toUpperCase() + 
                                _feedModes[_currentFeedMode].substring(1),
                                style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              SizedBox(width: 4),
                              Icon(
                                Icons.expand_more,
                                color: Colors.white,
                                size: 20,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    
                    SizedBox(width: 12),
                    
                    // Feed setting (answered/unanswered) toggle as icon button
                    GestureDetector(
                      onTap: () {
                        // Cycle through the three states: showAll → unanswered → answered → showAll
                        setState(() {
                          switch (_feedSetting) {
                            case FeedSetting.showAll:
                              _feedSetting = FeedSetting.unanswered;
                              break;
                            case FeedSetting.unanswered:
                              _feedSetting = FeedSetting.answered;
                              break;
                            case FeedSetting.answered:
                              _feedSetting = FeedSetting.showAll;
                              break;
                          }
                        });
                        
                        // Save the new setting
                        _saveFeedSettings();
                        
                        // Show feedback to user
                        String message;
                        switch (_feedSetting) {
                          case FeedSetting.showAll:
                            message = 'Showing all questions';
                            break;
                          case FeedSetting.unanswered:
                            message = 'Showing unanswered questions only';
                            break;
                          case FeedSetting.answered:
                            message = 'Showing answered questions only';
                            break;
                        }
                        _showSafeSnackBar(message, duration: Duration(milliseconds: 1500));
                      },
                      child: Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: _getFeedSettingBackgroundColor(),
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: _getFeedSettingBorderColor(),
                          ),
                        ),
                        child: Icon(
                          Icons.task_alt,
                          size: 20,
                          color: _getFeedSettingIconColor(),
                        ),
                      ),
                    ),
                    
                    SizedBox(width: 12),
                    
                    // Categories toggle as icon button
                    GestureDetector(
                      onTap: () {
                        // Check if there's a temporary filter active
                        final tempFilterNotifier = Provider.of<TemporaryCategoryFilterNotifier>(context, listen: false);
                        if (tempFilterNotifier.hasTemporaryCategoryFilter) {
                          // Clear temporary filter to restore usual settings
                          tempFilterNotifier.setTemporaryCategoryFilter(null);
                        } else {
                          // Reset feed setting to show all questions when adjusting content filters
                          setState(() {
                            _feedSetting = FeedSetting.showAll;
                          });
                          _saveFeedSettings();
                          // No temporary filter, show categories dialog as usual
                          _showCategoriesDialog();
                        }
                      },
                      child: Consumer2<UserService, TemporaryCategoryFilterNotifier>(
                        builder: (context, userService, tempFilterNotifier, child) {
                          final hasTemporaryFilter = tempFilterNotifier.hasTemporaryCategoryFilter;
                          
                          // Check if all categories are enabled
                          final allCategories = Category.allCategories.map((c) => c.name).toSet();
                          final enabledCategories = userService.enabledCategories.toSet();
                          final allEnabled = allCategories.every((category) => enabledCategories.contains(category));
                          final noneEnabled = enabledCategories.isEmpty;
                          
                          // Determine icon and color based on state
                          IconData iconToShow;
                          Color bgColor;
                          Color borderColor;
                          Color iconColor;
                          
                          if (hasTemporaryFilter) {
                            // Temporary filter active - show grey
                            iconToShow = Icons.tune;
                            bgColor = Colors.grey.withOpacity(0.1);
                            borderColor = Colors.grey.withOpacity(0.3);
                            iconColor = Colors.grey;
                          } else if (!allEnabled && !noneEnabled) {
                            // Custom selection (not all, not none) - show outlined icon with primary color
                            iconToShow = Icons.tune;
                            bgColor = Theme.of(context).primaryColor.withOpacity(0.1);
                            borderColor = Theme.of(context).primaryColor;
                            iconColor = Theme.of(context).primaryColor;
                          } else {
                            // All enabled or none enabled - show filled icon
                            iconToShow = Icons.tune;
                            bgColor = Theme.of(context).primaryColor;
                            borderColor = Theme.of(context).primaryColor;
                            iconColor = Colors.white;
                          }
                          
                          return Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              color: bgColor,
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: borderColor,
                              ),
                            ),
                            child: Icon(
                              iconToShow,
                              size: 20,
                              color: iconColor,
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          // Empty state content
          SizedBox(height: 40),
          Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                // Search icon indicating no results found
                      Icon(Icons.search_off, size: 64, color: Colors.grey),
                      SizedBox(height: 16),
                      Text(
                  'No questions found!',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      SizedBox(height: 8),
                Text(
                  'Try adjusting the filters above or pull down to refresh.',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Colors.grey,
                  ),
                  textAlign: TextAlign.center,
                ),
                SizedBox(height: 32),
                // Curio mascot at the bottom
                Image.asset(
                  Theme.of(context).brightness == Brightness.dark
                      ? 'assets/images/Curio-trans.png'
                      : 'assets/images/Curio.png',
                  height: 120,
                  fit: BoxFit.contain,
                ),
              ],
            ),
          ),
        ],
      );
    }

    return ListView.builder(
      key: PageStorageKey('home_questions_list'),
      controller: _scrollController,
      physics: const AlwaysScrollableScrollPhysics(),
      padding: EdgeInsets.only(top: appBarHeight + 16, bottom: bottomNavHeight + 16),
      itemCount: paginatedQuestions.length + (_isLoadingMore || _hasReachedEnd ? 2 : 1), // +1 for header, +1 for loading/end indicator if needed
      itemBuilder: (context, index) {
        // Debug: Log itemCount and state when building items near the end
        final totalItems = paginatedQuestions.length + (_isLoadingMore || _hasReachedEnd ? 2 : 1);
        if (index == 0) {
          // Header section (logo, sort buttons)
          return Column(
            children: [
              // Logo + Location and Answer Streak row
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0),
                child: Row(
                  children: [
                    // Left half: Logo + Location
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Image.asset(
                            'assets/images/RTR-logo_Aug2025.png',
                            height: 80,
                          ),
                          SizedBox(height: 8),
                          Consumer<LocationService>(
                            builder: (context, locationService, child) {
                              final country = locationService.userLocation?['country_name_en'];
                              final city = locationService.selectedCity?['name'];
                              
                              if (country == null) return SizedBox.shrink();
                              
                              return GestureDetector(
                                onTap: () {
                                  _showLocationHistoryDialog();
                                },
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.center,
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    if (city != null) ...[
                                      // Check if city contains state/province (has comma)
                                      if (city.contains(',')) ...[
                                        // Split to two lines: "City, State" on top, "Country" on bottom
                                        Text(
                                          city,
                                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                            color: Theme.of(context).primaryColor,
                                            fontWeight: FontWeight.bold,
                                          ),
                                          textAlign: TextAlign.center,
                                        ),
                                        Text(
                                          country,
                                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                            color: Theme.of(context).primaryColor,
                                            fontWeight: FontWeight.bold,
                                          ),
                                          textAlign: TextAlign.center,
                                        ),
                                      ] else ...[
                                        // Single line: "City, Country"
                                        Text(
                                          '$city, $country',
                                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                            color: Theme.of(context).primaryColor,
                                            fontWeight: FontWeight.bold,
                                          ),
                                          textAlign: TextAlign.center,
                                        ),
                                      ],
                                    ] else ...[
                                      // No city, just show country
                                      Text(
                                        country,
                                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                          color: Theme.of(context).primaryColor,
                                          fontWeight: FontWeight.bold,
                                        ),
                                        textAlign: TextAlign.center,
                                      ),
                                    ],
                                  ],
                                ),
                              );
                            },
                          ),
                        ],
                      ),
                    ),
                    SizedBox(width: 16),
                    // Right half: Answer Streak card
                    Expanded(
                      child: Consumer<UserService>(
                        builder: (context, userService, child) {
                          final currentStreak = _calculateCurrentAnswerStreak(userService.answeredQuestions);
                          final hasExtendedStreakToday = _hasExtendedStreakToday(userService.answeredQuestions);
                          return FutureBuilder<int>(
                            future: _getLongestAnswerStreak(),
                            builder: (context, snapshot) {
                              final longestStreak = snapshot.data ?? 0;
                              final streakRank = userService.streakRank;
                              final isTopFive = streakRank >= 1 && streakRank <= 5;
                              final showRainbow = isTopFive || currentStreak > 100;
                              return AnimatedBuilder(
                                animation: _streakAttentionAnimation,
                                builder: (context, child) {
                                  final glowOpacity = _isStreakAttentionAnimating ? _streakAttentionAnimation.value : 0.0;
                                  return Container(
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(8.0),
                                      boxShadow: glowOpacity > 0
                                          ? [
                                              BoxShadow(
                                                color: Theme.of(context).primaryColor.withOpacity(glowOpacity * 0.6),
                                                blurRadius: 16 * glowOpacity,
                                                spreadRadius: 3 * glowOpacity,
                                              ),
                                            ]
                                          : null,
                                    ),
                                    child: Container(
                                      height: 104, // Logo height (80) + spacing (8) + text (~16)
                                      decoration: _getStreakCardDecoration(context, currentStreak, isTopFive: isTopFive),
                                      padding: showRainbow ? EdgeInsets.all(2) : EdgeInsets.zero,
                                      child: Container(
                                        decoration: showRainbow ? BoxDecoration(
                                          color: Theme.of(context).scaffoldBackgroundColor,
                                          borderRadius: BorderRadius.circular(6.0),
                                        ) : null,
                                        child: InkWell(
                                          onTap: () {
                                            AnalyticsService().trackEvent('streak_card_tapped', {'current_streak': currentStreak, 'has_extended_today': hasExtendedStreakToday});
                                            _showAnswerStreakDialog(context, userService);
                                          },
                                          borderRadius: BorderRadius.circular(showRainbow ? 6 : 8),
                                          child: Padding(
                                            padding: EdgeInsets.all(12),
                                            child: AnimatedBuilder(
                                              animation: _pulseAnimation,
                                              builder: (context, child) {
                                                final shouldPulse = _shouldStreakCardPulse(context, hasExtendedStreakToday);
                                                final pulseScale = shouldPulse ? _pulseAnimation.value : 1.0;

                                                return AnimatedBuilder(
                                                  animation: _streakCardController,
                                                  builder: (context, child) {
                                                    final celebrationScale = _isStreakAnimating ? _streakCardScaleAnimation.value : 1.0;
                                                    final finalScale = pulseScale * celebrationScale;

                                                    // Determine colors for animation
                                                    Color iconColor;
                                                    Color textColor;
                                                    int displayStreak;

                                                    if (_isStreakAnimating) {
                                                      // During animation, show transition from old to new
                                                      final animationProgress = _streakCardController.value;
                                                      if (animationProgress < 0.5) {
                                                        // First half: show old streak with old color
                                                        iconColor = _getStreakCardColorForStreak(_animatingOldStreak ?? 0, false);
                                                        textColor = iconColor;
                                                        displayStreak = _animatingOldStreak ?? currentStreak;
                                                      } else {
                                                        // Second half: transition to new streak with primary color
                                                        final colorProgress = (animationProgress - 0.5) * 2;
                                                        final oldColor = _getStreakCardColorForStreak(_animatingOldStreak ?? 0, false);
                                                        final newColor = Theme.of(context).primaryColor;
                                                        iconColor = Color.lerp(oldColor, newColor, colorProgress) ?? newColor;
                                                        textColor = iconColor;
                                                        displayStreak = _animatingNewStreak ?? currentStreak;
                                                      }
                                                    } else {
                                                      // Normal state
                                                      iconColor = currentStreak > 0
                                                          ? _getStreakCardColor(context, hasExtendedStreakToday)
                                                          : Colors.grey;
                                                      textColor = currentStreak > 0
                                                          ? _getStreakCardColor(context, hasExtendedStreakToday)
                                                          : Colors.grey[600] ?? Colors.grey;
                                                      displayStreak = currentStreak;
                                                    }

                                                    // Show medal instead of flame icon for top 3
                                                    final showMedal = streakRank >= 1 && streakRank <= 3;

                                                    return Transform.scale(
                                                      scale: finalScale,
                                                      child: Row(
                                                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                                        children: [
                                                          if (showMedal)
                                                            Text(
                                                              streakRank == 1 ? '🥇' : streakRank == 2 ? '🥈' : '🥉',
                                                              style: TextStyle(fontSize: 36),
                                                            )
                                                          else
                                                            Icon(
                                                              Icons.local_fire_department,
                                                              color: iconColor,
                                                              size: 40,
                                                            ),
                                                          Text(
                                                            '$displayStreak',
                                                            style: Theme.of(context).textTheme.displayMedium?.copyWith(
                                                              color: textColor,
                                                              fontWeight: FontWeight.bold,
                                                            ),
                                                          ),
                                                        ],
                                                      ),
                                                    );
                                                  },
                                                );
                                              },
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  );
                                },
                              );
                          }
                        );
                      },
                    ),
                  ),
                ],
                ),
              ),
              SizedBox(height: 16),
              // Show either temporary category filter or Question of the Day
              Consumer2<TemporaryCategoryFilterNotifier, UserService>(
                builder: (context, filterNotifier, userService, child) {
                  if (filterNotifier.hasTemporaryCategoryFilter) {
                    return TemporaryCategoryFilterWidget();
                  }
                  return QuestionOfTheDayWidget(
                    key: _qotdKey,
                    userService: userService,
                    onQOTDClick: _handleQOTDClick,
                  );
                },
              ),
              SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0),
                child: Row(
                  children: [
                    Expanded(
                      child: GestureDetector(
                        onTap: () {
                          // Show feed selector popup
                          _showFeedSelectorDialog();
                        },
                        child: Container(
                          height: 50,
                          decoration: BoxDecoration(
                            color: Theme.of(context).primaryColor,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: Theme.of(context).primaryColor),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                _currentFeedMode == 0 ? Icons.trending_up :
                                _currentFeedMode == 1 ? Icons.people : Icons.local_fire_department,
                                color: Colors.white,
                              ),
                              SizedBox(width: 8),
                              Text(
                                _feedModes[_currentFeedMode].substring(0, 1).toUpperCase() + 
                                _feedModes[_currentFeedMode].substring(1),
                                style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              SizedBox(width: 4),
                              Icon(
                                Icons.expand_more,
                                color: Colors.white,
                                size: 20,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    
                    SizedBox(width: 12),
                    
                    // Feed setting (answered/unanswered) toggle as icon button
                    GestureDetector(
                      onTap: () {
                        // Cycle through the three states: showAll → unanswered → answered → showAll
                        setState(() {
                          switch (_feedSetting) {
                            case FeedSetting.showAll:
                              _feedSetting = FeedSetting.unanswered;
                              break;
                            case FeedSetting.unanswered:
                              _feedSetting = FeedSetting.answered;
                              break;
                            case FeedSetting.answered:
                              _feedSetting = FeedSetting.showAll;
                              break;
                          }
                        });
                        
                        // Save the new setting
                        _saveFeedSettings();
                        
                        // Show feedback to user
                        String message;
                        switch (_feedSetting) {
                          case FeedSetting.showAll:
                            message = 'Showing all questions';
                            break;
                          case FeedSetting.unanswered:
                            message = 'Showing unanswered questions only';
                            break;
                          case FeedSetting.answered:
                            message = 'Showing answered questions only';
                            break;
                        }
                        _showSafeSnackBar(message, duration: Duration(milliseconds: 1500));
                      },
                      child: Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: _getFeedSettingBackgroundColor(),
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: _getFeedSettingBorderColor(),
                          ),
                        ),
                        child: Icon(
                          Icons.task_alt,
                          size: 20,
                          color: _getFeedSettingIconColor(),
                        ),
                      ),
                    ),
                    
                    SizedBox(width: 12),
                    
                    // Categories toggle as icon button
                    GestureDetector(
                      onTap: () {
                        // Check if there's a temporary filter active
                        final tempFilterNotifier = Provider.of<TemporaryCategoryFilterNotifier>(context, listen: false);
                        if (tempFilterNotifier.hasTemporaryCategoryFilter) {
                          // Clear temporary filter to restore usual settings
                          tempFilterNotifier.setTemporaryCategoryFilter(null);
                        } else {
                          // No temporary filter, show categories dialog as usual
                          _showCategoriesDialog();
                        }
                      },
                      child: Consumer2<UserService, TemporaryCategoryFilterNotifier>(
                        builder: (context, userService, tempFilterNotifier, child) {
                          final hasTemporaryFilter = tempFilterNotifier.hasTemporaryCategoryFilter;
                          
                          // Check if all categories are enabled
                          final allCategories = Category.allCategories.map((c) => c.name).toSet();
                          final enabledCategories = userService.enabledCategories.toSet();
                          final allEnabled = allCategories.every((category) => enabledCategories.contains(category));
                          final noneEnabled = enabledCategories.isEmpty;
                          
                          // Determine icon and color based on state
                          IconData iconToShow;
                          Color bgColor;
                          Color borderColor;
                          Color iconColor;
                          
                          if (hasTemporaryFilter) {
                            // Temporary filter active - show grey
                            iconToShow = Icons.tune;
                            bgColor = Colors.grey.withOpacity(0.1);
                            borderColor = Colors.grey.withOpacity(0.3);
                            iconColor = Colors.grey;
                          } else if (!allEnabled && !noneEnabled) {
                            // Custom selection (not all, not none) - show outlined icon with primary color
                            iconToShow = Icons.tune;
                            bgColor = Theme.of(context).primaryColor.withOpacity(0.1);
                            borderColor = Theme.of(context).primaryColor;
                            iconColor = Theme.of(context).primaryColor;
                          } else {
                            // All enabled or none enabled - show filled icon
                            iconToShow = Icons.tune;
                            bgColor = Theme.of(context).primaryColor;
                            borderColor = Theme.of(context).primaryColor;
                            iconColor = Colors.white;
                          }
                          
                          return Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              color: bgColor,
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: borderColor,
                              ),
                            ),
                            child: Icon(
                              iconToShow,
                              size: 20,
                              color: iconColor,
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(height: 12), // Add spacing before questions start
            ],
          );
        }

        // Note: Removed conflicting loading indicator logic that was preventing refresh button
 
        // Question items and loading indicator
        final questionIndex = index - 1;
        
        
        if (questionIndex >= paginatedQuestions.length) {
          // Loading indicator at the end
          if (_isLoadingMore) {
            return Padding(
              padding: EdgeInsets.all(16),
              child: Center(
                child: Column(
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 8),
                    Text(
                      'Loading more questions...',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Colors.grey,
                      ),
                    ),
                  ],
                ),
              ),
            );
          } else if (_hasReachedEnd) {
            // End of feed with refresh button
            return Padding(
              padding: EdgeInsets.all(32),
              child: Center(
                child: Column(
                  children: [
                    Text(
                      '🦎',
                      style: TextStyle(fontSize: 32),
                    ),
                    SizedBox(height: 8),
                    Text(
                      "You've seen all the questions!",
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Colors.grey,
                      ),
                    ),
                    SizedBox(height: 24),
                    ElevatedButton.icon(
                      onPressed: () async {
                        // Capture services and context objects before async operations to avoid disposal issues
                        final questionService = Provider.of<QuestionService>(context, listen: false);
                        final userService = Provider.of<UserService>(context, listen: false);
                        final locationService = Provider.of<LocationService>(context, listen: false);
                        final scaffoldMessenger = ScaffoldMessenger.of(context);
                        final theme = Theme.of(context);
                        
                        print('User Action: Refreshing feed via button');
                        
                        final filters = _buildFiltersWithLocation(userService, locationService);
                        
                        // Use optimized Edge Function v3 for refresh
                        final refreshedQuestions = await questionService.getFeed(
                          feedType: _sortBy,
                          filters: filters,
                          forceRefresh: true, // Force fresh data from Edge Function
                          userService: userService,
                        );
                        
                        // Update questions with fresh data first
                        questionService.updateQuestions(refreshedQuestions, notify: false);
                        
                        // Then update loading state which will trigger rebuild
                        setState(() {
                          _hasShownThanksOnRefresh = false;
                          _hasReachedEnd = false;
                        });
                        
                        // Refresh QotD during button refresh
                        _qotdKey.currentState?.refreshQotD();
                        
                        // Reinitialize vote count tracking after refresh
                        _initializeVoteCountTracking(refreshedQuestions);
                        
                        // TRIGGER SEQUENTIAL VOTE COUNT UPDATE
                        // Update vote counts sequentially starting with visible questions
                        print('🔄 Starting sequential engagement update for visible questions...');
                        _updateVoteCountsSequentially(refreshedQuestions, questionService);
                        
                        print('Feed: Button refreshed with Edge Function - mode: ${_feedModes[_currentFeedMode]}, questions: ${refreshedQuestions.length}');
                        
                        // Show success snackbar
                        if (mounted) {
                          scaffoldMessenger.showSnackBar(
                            SnackBar(
                              content: Text('Feed Refreshed 🌱'),
                              duration: Duration(seconds: 2),
                              backgroundColor: theme.primaryColor,
                            ),
                          );
                        }
                        
                        // Scroll to top after refresh - this is user initiated so always scroll
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          _safeAnimateToTop(reason: 'user_requested');
                        });
                      },
                      icon: Icon(Icons.refresh),
                      label: Text('Refresh Feed'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Theme.of(context).primaryColor,
                        foregroundColor: Colors.white,
                        padding: EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                      ),
                    ),
                  ],
                ),
              ),
            );
          }
          return SizedBox.shrink();
        }
        
        var question = paginatedQuestions[questionIndex];
  
        // Use the question timestamp for the time ago feature
        final String timeAgo = getTimeAgo(question['created_at'] ?? DateTime.now().toIso8601String());
        
        final isTargeted = _isQuestionTargetedToUser(question, locationService);
        final guestTrackingService = Provider.of<GuestUserTrackingService>(context, listen: false);
        final wasViewedAsGuest = guestTrackingService.wasViewedAsGuest(question['id']?.toString() ?? '');
        final hasAnswered = userService.hasAnsweredQuestion(question['id']) || wasViewedAsGuest;
        
        // Guest-viewed questions are treated as answered to prevent re-engagement
        
        // Determine targeting type for appropriate emoji - use cached data or show default
        final targetingType = question['targeting_type']?.toString();
        final questionCountryCode = question['country_code']?.toString();
        String? targetingEmoji;
        
        // Debug: Check what fields are actually available in the question
        if (questionIndex < 3) { // Only log first few questions to avoid spam
          print('DEBUG: Question ${question['id']} fields: ${question.keys.toList()}');
          // print('DEBUG: targeting_type = "$targetingType", country_code = "$questionCountryCode"');  // Commented out excessive logging
          
          // Also check if this is a specific type of targeting that should have country_code
          if (targetingType == 'country' && questionCountryCode == null) {
            print('WARNING: Question has country targeting but no country_code!');
          }
        }
        
        // Generate emoji based on available targeting data
        if (targetingType == 'city') {
          targetingEmoji = '🏙️';
        } else if (targetingType == 'country' && questionCountryCode != null && questionCountryCode.isNotEmpty) {
          // We have both targeting type and country code - show flag
          final flagEmoji = _getCountryFlagEmoji(questionCountryCode);
          targetingEmoji = flagEmoji.isNotEmpty ? flagEmoji : '🇺🇳';
          if (questionIndex < 3) print('✅ Using country flag: $targetingEmoji for $questionCountryCode');
        } else if (targetingType == 'globe' || targetingType == 'global') {
          targetingEmoji = '🌍';
        } else if (targetingType == 'country' && (questionCountryCode == null || questionCountryCode.isEmpty)) {
          // Country targeting but no country code - fetch it
          targetingEmoji = '🇺🇳'; // Show UN flag while we fetch
          _fetchAndCacheTargetingData(question);
          if (questionIndex < 3) print('⚠️ Country targeting missing country_code, fetching...');
        } else if (targetingType == null) {
          // No targeting data at all - fetch it
          targetingEmoji = '🌍'; // Show world while we fetch
          _fetchAndCacheTargetingData(question);
          if (questionIndex < 3) print('⚠️ No targeting data, fetching...');
        } else {
          // Unknown targeting type - default to world
          targetingEmoji = '🌍';
          if (questionIndex < 3) print('⚠️ Unknown targeting type: $targetingType');
        }
        
        // Allow swiping on all questions - both directions dismiss
        return Dismissible(
          key: Key('question_${question['id']}'),
          direction: DismissDirection.horizontal, // Allow both directions to dismiss
          confirmDismiss: (direction) async {
            // Dismiss logic for all questions (both swipe directions)
            final questionId = question['id'].toString();

            // Allow dismissal for both answered and unanswered questions
            userService.dismissQuestion(questionId);

            // Show snackbar with undo option
            if (mounted) {
              await ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                backgroundColor: Theme.of(context).primaryColor,
                duration: Duration(seconds: 4),
                content: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('Question dismissed'),
                    GestureDetector(
                      onTap: () {
                        ScaffoldMessenger.of(context).hideCurrentSnackBar();
                        userService.undismissQuestion(questionId);
                      },
                      child: Text(
                        'UNDO',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ).closed;
            }

            // Return true to confirm dismissal (remove from UI)
            return true;
          },
            background: Container(
              alignment: Alignment.centerLeft,
              padding: EdgeInsets.only(left: 20),
              color: Colors.grey,
              child: Icon(
                Icons.close,
                color: Colors.white,
                size: 24,
              ),
            ),
            secondaryBackground: Container(
              alignment: Alignment.centerRight,
              padding: EdgeInsets.only(right: 20),
              color: Colors.grey,
              child: Icon(
                Icons.close,
                color: Colors.white,
                size: 24,
              ),
            ),
            child: Container(
              margin: EdgeInsets.only(left: 16.0, right: 16.0, bottom: 12.0), // Add horizontal padding to match QOTD widget
              decoration: BoxDecoration(
                color: hasAnswered
                    ? null // Answered: transparent, blends into background
                    : (Theme.of(context).brightness == Brightness.dark ? null : Colors.white),
                border: Border.all(
                  color: hasAnswered
                      ? Theme.of(context).dividerColor.withOpacity(0.15)
                      : Theme.of(context).dividerColor.withOpacity(0.3),
                  width: 0.5,
                ),
                borderRadius: BorderRadius.circular(8.0),
                boxShadow: (!hasAnswered && Theme.of(context).brightness == Brightness.light)
                    ? [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.08),
                          blurRadius: 4,
                          offset: Offset(0, 2),
                        ),
                      ]
                    : null,
              ),
              child: Stack(
                children: [
                  ListTile(
                title: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    height: 60, // Fixed height to match ListTile content
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        if (targetingEmoji != null) ...[
                        Opacity(
                          opacity: hasAnswered ? 0.4 : 1.0,
                          child: Text(
                            targetingEmoji,
                            style: TextStyle(fontSize: 16),
                          ),
                        ),
                        SizedBox(height: 8),
                        ],
                        QuestionTypeBadge(
                          type: question['type'] ?? 'unknown',
                          color: hasAnswered ? Colors.grey : Theme.of(context).primaryColor,
                        ),
                      ],
                    ),
                  ),
                  SizedBox(width: 16),
                  Expanded(
                    child: Text(
                      question['prompt'] ?? 'No Title',
                      style: TextStyle(
                        color: hasAnswered ? Colors.grey : null,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  // Top emoji reaction display
                  Builder(
                    builder: (context) {
                      final topEmoji = _getTopEmojiReaction(question);
                      if (topEmoji != null) {
                        return Container(
                          margin: EdgeInsets.only(left: 8),
                          child: Text(
                            topEmoji,
                            style: TextStyle(fontSize: 20),
                          ),
                        );
                      }
                      return SizedBox.shrink();
                    },
                  ),
                ],
              ),
              subtitle: Consumer<QuestionService>(
                builder: (context, questionService, child) {
                  final displayVotes = question['votes'] ?? 0;
                  final reactionCount = _getReactionCount(question);
                  final commentCount = _getCommentCount(question);
                  
                  
                  // Calculate padding to align with question text 
                  // Since icons are stacked vertically, we only need: QuestionTypeBadge width + spacing
                  double leftPadding = 24.0 + 16.0; // Badge width + increased spacing after icons column
                  
                  // Build subtitle parts (time, votes - no reacts in main feed)
                  final parts = <String>[];
                  parts.add(timeAgo);
                  parts.add('$displayVotes ${displayVotes == 1 ? 'vote' : 'votes'}');
                  
                  // Build single line with comments on the right if there are comments
                  return Padding(
                    padding: EdgeInsets.only(left: leftPadding, top: 2.0),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            parts.join(' • '),
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: hasAnswered ? Colors.grey : null,
                            ),
                          ),
                        ),
                        // Show comment count if there are comments
                        if (commentCount > 0)
                          Text(
                            '$commentCount ${commentCount == 1 ? 'comment' : 'comments'}',
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: hasAnswered ? Colors.grey : null,
                            ),
                          ),
                      ],
                    ),
                  );
                },
              ),
              onTap: () async {
                if (!mounted) return; // Safety check
                final questionServiceRef = questionService; // Use already captured reference
                
                // Store current scroll position for this question
                final questionId = question['id']?.toString();
                if (questionId != null && _scrollController.hasClients) {
                  _questionScrollPositions[questionId] = _scrollController.offset;
                }
                
                // Create FeedContext for swipe navigation
                final filters = <String, dynamic>{
                  'showNSFW': userService.showNSFWContent,
                  'questionTypes': userService.enabledQuestionTypes,
                  'userCountry': locationService.userLocation?['country_code'],
                  'userCity': locationService.selectedCity?['id'],
                };
                
                final feedContext = FeedContext(
                  feedType: _sortBy,
                  filters: filters,
                  questions: paginatedQuestions,
                  currentQuestionIndex: questionIndex,
                  originalQuestionId: questionId, // Track the original question for scroll position
                );
                
                // Navigate and await result
                Map<String, dynamic>? result;
                if (hasAnswered) {
                  result = await questionServiceRef.navigateToResultsScreen(context, question, feedContext: feedContext);
                } else {
                  result = await questionServiceRef.navigateToAnswerScreen(context, question, feedContext: feedContext);
                }
                
                // Handle scroll position if user swiped right to come back
                if (result != null && result['type'] == 'scroll_to_question') {
                  final targetQuestionId = result['question_id']?.toString();
                  
                  print('HomeScreen: Received scroll request for questionId: $targetQuestionId');
                  
                  // Simple approach: just restore to the original scroll position
                  if (targetQuestionId != null && _questionScrollPositions.containsKey(targetQuestionId)) {
                    final originalPosition = _questionScrollPositions[targetQuestionId]!;
                    
                    if (_scrollController.hasClients && !_isUserScrolling) {
                      print('HomeScreen: Restoring to original position $originalPosition for question $targetQuestionId');
                      
                      // Ensure position is within bounds
                      final maxScrollOffset = _scrollController.position.maxScrollExtent;
                      final clampedPosition = originalPosition.clamp(0.0, maxScrollOffset);
                      
                      // Smoothly animate back to the original position
                      await _scrollController.animateTo(
                        clampedPosition,
                        duration: Duration(milliseconds: 600),
                        curve: Curves.easeInOut,
                      );
                      
                      print('HomeScreen: Restored to original position');
                    } else if (_isUserScrolling) {
                      print('HomeScreen: Skipping scroll restoration - user is scrolling');
                    }
                  }
                }
              },
              ),
                ],
              ),
            ),
          );
      },
    );
  }

  void _showFeedSelectorDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Feed Type'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildFeedOption(
              mode: 'trending',
              index: 0,
              icon: Icons.trending_up,
              title: 'Trending',
              description: 'Questions gaining momentum',
            ),
            _buildFeedOption(
              mode: 'popular',
              index: 1,
              icon: Icons.people,
              title: 'Popular',
              description: 'Top (past 30 days)',
            ),
            _buildFeedOption(
              mode: 'new',
              index: 2,
              icon: Icons.local_fire_department,
              title: 'New',
              description: 'The latest but not necessarily the greatest...',
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text('Cancel'),
          ),
        ],
      ),
    );
  }

  void _showCategoriesDialog() async {
    final userService = Provider.of<UserService>(context, listen: false);
    final locationService = Provider.of<LocationService>(context, listen: false);
    final questionService = Provider.of<QuestionService>(context, listen: false);
    final initialEnabledCategories = List<String>.from(userService.enabledCategories);
    
    // Get category counts from current feed
    final filters = <String, dynamic>{
      'showNSFW': userService.showNSFWContent,
      'questionTypes': userService.enabledQuestionTypes,
      'userCountry': locationService.userLocation?['country_code'],
      'userCity': locationService.selectedCity?['id'],
    };
    
    final categoryCounts = await questionService.getCurrentFeedCategoryCounts(
      feedType: _sortBy,
      filters: filters,
    );
    
    if (!mounted) return;
    
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.tune, color: Theme.of(context).primaryColor),
            SizedBox(width: 8),
            Text('Content Filters'),
          ],
        ),
        content: Container(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Consumer<UserService>(
              builder: (context, userService, child) {
                // Ensure NSFW is off for unauthenticated users
                if (supabase.auth.currentUser == null && userService.showNSFWContent) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    userService.setShowNSFWContent(false);
                  });
                }
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Question Types section
                    Row(
                      children: [
                        Icon(Icons.quiz, color: Theme.of(context).primaryColor, size: 20),
                        SizedBox(width: 8),
                        Text(
                          'Question Types',
                          style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: 8),
                    Text(
                      'Which question types would you like in your feed?',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Colors.grey[600],
                      ),
                    ),
                    SizedBox(height: 12),
                    Wrap(
                      spacing: 8.0,
                      runSpacing: 8.0,
                      children: UserService.allQuestionTypes.map((questionType) {
                        final typeId = questionType['id'] as String;
                        final typeName = questionType['name'] as String;
                        final typeIcon = questionType['icon'] as IconData;
                        final isEnabled = userService.enabledQuestionTypes.contains(typeId);
                        
                        return FilterChip(
                          avatar: Icon(
                            typeIcon,
                            size: 18,
                            color: isEnabled ? Theme.of(context).primaryColor : Colors.grey,
                          ),
                          label: Text(
                            typeName,
                            style: TextStyle(
                              color: isEnabled 
                                  ? Theme.of(context).colorScheme.onSurface
                                  : Theme.of(context).textTheme.bodyMedium?.color,
                            ),
                          ),
                          selected: isEnabled,
                          onSelected: (selected) {
                            if (typeId == 'text' && supabase.auth.currentUser == null) {
                              AuthenticationDialog.show(
                                context,
                                customMessage: 'To enable text questions, you need to authenticate as a real person.',
                                onComplete: () {
                                  userService.toggleQuestionType(typeId);
                                },
                              );
                              return;
                            }
                            userService.toggleQuestionType(typeId);
                          },
                          showCheckmark: false,
                          selectedColor: Theme.of(context).primaryColor.withOpacity(0.2),
                          checkmarkColor: Theme.of(context).primaryColor,
                        );
                      }).toList(),
                    ),
                    SizedBox(height: 24),
                    
                    // Categories section
                    Row(
                      children: [
                        Icon(Icons.category, color: Theme.of(context).primaryColor, size: 20),
                        SizedBox(width: 8),
                        Text(
                          'Topics',
                          style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: 8),
                    Text(
                      'What topics are you interested in?\n\nScroll down to see more.',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Colors.grey[600],
                      ),
                    ),
                    SizedBox(height: 16),
                    Wrap(
                      spacing: 8.0,
                      runSpacing: 8.0,
                      children: () {
                        // Get categories ordered by static usage (same as new question screen)
                        final orderedCategories = Category.getOrderedCategoriesByStaticUsage();
                        
                        final categoryItems = orderedCategories.map((category) {
                          final isEnabled = userService.enabledCategories.contains(category.name);
                          return {
                            'category': category,
                            'isEnabled': isEnabled,
                          };
                        }).toList();
                        
                        // Sort by enabled status first (enabled categories first), but preserve the usage-based order within each group
                        categoryItems.sort((a, b) {
                          // Sort by enabled status first (enabled categories first)
                          if (a['isEnabled'] != b['isEnabled']) {
                            return (a['isEnabled'] as bool) ? -1 : 1;
                          }
                          // Within each group (enabled/disabled), maintain the usage-based order
                          final indexA = orderedCategories.indexOf(a['category'] as Category);
                          final indexB = orderedCategories.indexOf(b['category'] as Category);
                          return indexA.compareTo(indexB);
                        });
                        
                        final chips = categoryItems.map((item) {
                          final category = item['category'] as Category;
                          final isEnabled = item['isEnabled'] as bool;
                          
                          return FilterChip(
                            label: Text(
                              category.name,
                              style: TextStyle(
                                color: isEnabled 
                                    ? Theme.of(context).colorScheme.onSurface
                                    : Theme.of(context).textTheme.bodyMedium?.color,
                              ),
                            ),
                            selected: isEnabled,
                            onSelected: (selected) {
                              userService.toggleCategory(category.name);
                            },
                            showCheckmark: false,
                            selectedColor: category.isNSFW 
                                ? Colors.red.withOpacity(0.2)
                                : Theme.of(context).primaryColor.withOpacity(0.2),
                            checkmarkColor: Theme.of(context).primaryColor,
                          );
                        }).toList();

                        return chips;
                      }(),
                    ),
                    
                    // Show 18+ indicator only for authenticated users who have previously enabled NSFW content
                    if (supabase.auth.currentUser != null && userService.hasEverEnabledNSFW) ...[
                      if (userService.showNSFWContent) ...[
                        SizedBox(height: 16),
                        GestureDetector(
                          onTap: () {
                            userService.setShowNSFWContent(false);
                          },
                          child: Container(
                            padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                            decoration: BoxDecoration(
                              color: Colors.orange.withOpacity(0.2),
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: Colors.orange.withOpacity(0.5),
                                width: 1,
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.warning,
                                  color: Colors.orange,
                                  size: 16,
                                ),
                                SizedBox(width: 6),
                                Text(
                                  '18+',
                                  style: TextStyle(
                                    color: Colors.orange,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ] else ...[
                        SizedBox(height: 16),
                        GestureDetector(
                          onTap: () {
                            userService.setShowNSFWContent(true);
                          },
                          child: Container(
                            padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                            decoration: BoxDecoration(
                              color: Colors.grey.withOpacity(0.1),
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: Colors.grey.withOpacity(0.3),
                                width: 1,
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.warning_outlined,
                                  color: Colors.grey,
                                  size: 16,
                                ),
                                SizedBox(width: 6),
                                Text(
                                  '18+',
                                  style: TextStyle(
                                    color: Colors.grey,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ],
                  ],
                );
              },
            ),
          ),
        ),
        actions: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Consumer<UserService>(
                builder: (context, userService, child) {
                  final allCategories = Category.allCategories.map((c) => c.name).toSet();
                  final enabledCategories = userService.enabledCategories.toSet();
                  final allEnabled = allCategories.every((category) => enabledCategories.contains(category));
                  
                  return TextButton(
                    onPressed: () {
                      // If all categories are enabled, disable all. Otherwise, enable all.
                      if (allEnabled) {
                        // Disable all categories
                        for (final category in allCategories) {
                          if (enabledCategories.contains(category)) {
                            userService.toggleCategory(category);
                          }
                        }
                      } else {
                        // Enable all categories
                        for (final category in allCategories) {
                          if (!enabledCategories.contains(category)) {
                            userService.toggleCategory(category);
                          }
                        }
                      }
                    },
                    style: TextButton.styleFrom(
                      backgroundColor: allEnabled 
                          ? Theme.of(context).primaryColor.withOpacity(0.2)
                          : Colors.transparent,
                      foregroundColor: allEnabled 
                          ? Theme.of(context).colorScheme.onSurface
                          : Theme.of(context).primaryColor,
                      side: allEnabled 
                          ? BorderSide(
                              color: Theme.of(context).primaryColor.withOpacity(0.3),
                              width: 1,
                            )
                          : BorderSide(
                              color: Theme.of(context).primaryColor.withOpacity(0.3),
                              width: 1,
                            ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    child: Text('All Topics'),
                  );
                },
              ),
              ElevatedButton(
                onPressed: () {
                  // Check if categories have changed before closing dialog
                  final currentEnabledCategories = userService.enabledCategories;
                  final hasChanges = !_listEquals(initialEnabledCategories, currentEnabledCategories);
                  
                  print('Category Save pressed - hasChanges: $hasChanges');
                  print('Initial categories: $initialEnabledCategories');
                  print('Current categories: $currentEnabledCategories');
                  
                  Navigator.of(context).pop();
                  
                  // Show snackbar safely if there were changes
                  if (hasChanges) {
                    _showSafeSnackBar('Category filters updated');
                  }
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: Theme.of(context).primaryColor,
                  foregroundColor: Colors.white,
                ),
                child: Text('Save'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildFeedOption({
    required String mode,
    required int index,
    required IconData icon,
    required String title,
    required String description,
  }) {
    final isSelected = _currentFeedMode == index;
    
    return InkWell(
      onTap: () async {
        print('Feed: Changed to $mode');
        
        // Close dialog first for better UX
        Navigator.of(context).pop();
        
        // Clear scroll position cache when switching feeds
        _questionScrollPositions.clear();
        
        // Update state with new values FIRST (before saving settings)
        setState(() {
          _currentFeedMode = index;
          _sortBy = mode;
          _hasReachedEnd = false;
          _isLoadingMore = false; // Reset loading state
        });
        
        // Reset comment loading state when changing feeds
        _resetCommentLoadingState();
        
        // Save the new feed settings with updated values
        await _saveFeedSettings();
        
        // Clear cache and force fresh data when switching feeds
        final userService = Provider.of<UserService>(context, listen: false);
        final locationService = Provider.of<LocationService>(context, listen: false);
        final questionService = Provider.of<QuestionService>(context, listen: false);
        
        final filters = _buildFiltersWithLocation(userService, locationService);
        
        // Always use cache since we're in global mode
        final useCache = true;
        
        print('Feed: Switching to $mode using optimized Edge Function (cache: $useCache, globalMode: true)...');
        
        // Use optimized Edge Function v3 for global question discovery
        final sortedQuestions = await questionService.fetchOptimizedFeed(
          feedType: mode,
          filters: filters,
          userService: userService,
          useCache: useCache, // Force fresh data in city mode
        );
        
        // Update the questions list
        questionService.updateQuestions(sortedQuestions);
        
        // In global mode, we should have plenty of questions, no need for auto-load more
        
        // Reinitialize vote count tracking for new feed
        _initializeVoteCountTracking(sortedQuestions);
        
        print('Feed: Successfully switched to $mode with ${sortedQuestions.length} questions');
        
        // Debug: Show first few question IDs to verify they're different
        if (sortedQuestions.isNotEmpty) {
          final firstFew = sortedQuestions.take(3).map((q) => q['id']).toList();
          print('Feed: $mode - First 3 question IDs: $firstFew');
          
          // Also show the vote counts to verify sorting
          final firstFewVotes = sortedQuestions.take(3).map((q) => q['votes']).toList();
          print('Feed: $mode - First 3 question votes: $firstFewVotes');
        }
      },
      child: Container(
        margin: EdgeInsets.symmetric(vertical: 4),
        padding: EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isSelected 
                ? Theme.of(context).primaryColor
                : Colors.grey.withOpacity(0.3),
          ),
        ),
        child: Row(
          children: [
            Icon(
              icon,
              color: isSelected 
                  ? Theme.of(context).primaryColor
                  : Colors.grey[600],
              size: 24,
            ),
            SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: isSelected 
                          ? Theme.of(context).primaryColor
                          : null,
                    ),
                  ),
                  SizedBox(height: 2),
                  Text(
                    description,
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.grey[600],
                    ),
                  ),
                ],
              ),
            ),
            if (isSelected)
              Icon(
                Icons.check_circle,
                color: Theme.of(context).primaryColor,
                size: 20,
              ),
          ],
        ),
      ),
    );
  }

  void _handleQOTDClick(BuildContext context, Map<String, dynamic> qotd) {
    final userService = Provider.of<UserService>(context, listen: false);
    final questionService = Provider.of<QuestionService>(context, listen: false);

    // Track QOTD click event
    AnalyticsService().trackQotdClicked(
      qotd['id']?.toString() ?? 'unknown',
      {
        'question_type': qotd['type']?.toString(),
        'category': qotd['category']?.toString(),
        'has_answered': questionService.hasAnsweredQuestionOfTheDay(userService),
        'user_authenticated': Supabase.instance.client.auth.currentUser != null,
      }
    );
    
    // Check if we should show the notification permission dialog first
    if (userService.shouldShowNotificationPermissionDialog()) {
      // Mark as shown immediately to prevent multiple dialogs
      userService.setNotificationPermissionShown(true);
      
      // Track QOTD notification permission request
      AnalyticsService().trackQotdNotificationPermissionRequested();
      
      // Show our custom dialog first
      NotificationPermissionDialog.show(
        context,
        onPermissionGranted: () async {
          print('User granted notification permissions');
          // Track permission result
          AnalyticsService().trackQotdNotificationPermissionResult(true);
          // Update UserService settings for both notification types
          await userService.onNotificationPermissionsGranted();
          // After permission dialog, navigate to the QOTD
          _navigateToQOTD(context, qotd, questionService);
        },
        onPermissionDenied: () async {
          print('User denied notification permissions');
          // Track permission result
          AnalyticsService().trackQotdNotificationPermissionResult(false);
          // Update UserService settings to disable both notification types
          await userService.onNotificationPermissionsDenied();
          // Still navigate to QOTD even if they denied permissions
          _navigateToQOTD(context, qotd, questionService);
        },
      );
    } else {
      // No dialog needed, go straight to QOTD
      _navigateToQOTD(context, qotd, questionService);
    }
  }

  void _navigateToQOTD(BuildContext context, Map<String, dynamic> qotd, QuestionService questionService) async {
    final userService = Provider.of<UserService>(context, listen: false);
    final locationService = Provider.of<LocationService>(context, listen: false);
    final hasAnswered = questionService.hasAnsweredQuestionOfTheDay(userService);
    
    // Get the current filtered questions from the feed for swipe navigation
    final tempFilterNotifier = Provider.of<TemporaryCategoryFilterNotifier>(context, listen: false);
    final allQuestions = questionService.questions;
    
    // Apply the same filtering logic as the main feed to get the actual questions users can swipe through
    final filteredQuestions = allQuestions.where((question) {
      // Filter out current Question of the Day from regular feed to avoid duplication
      if (question['id'] == qotd['id']) {
        return false;
      }
      
      // Filter out NSFW content if not enabled
      if (question['is_nsfw'] == true && !userService.showNSFWContent) {
        return false;
      }

      // Filter out answered questions if setting is enabled
      if (userService.hideAnsweredQuestions && userService.hasAnsweredQuestion(question['id'])) {
        return false;
      }

      // Filter out reported questions
      if (userService.shouldHideReportedQuestion(question['id'].toString())) {
        return false;
      }

      // Filter out dismissed questions
      if (userService.isQuestionDismissed(question['id'].toString())) {
        return false;
      }

      // Apply feed setting filter (answered/unanswered)
      final hasAnswered = userService.hasAnsweredQuestion(question['id']);
      switch (_feedSetting) {
        case FeedSetting.showAll:
          // Show all questions - no additional filtering
          break;
        case FeedSetting.unanswered:
          // Show only unanswered questions
          if (hasAnswered) {
            return false;
          }
          break;
        case FeedSetting.answered:
          // Show only answered questions
          if (!hasAnswered) {
            return false;
          }
          break;
      }

      // Filter by enabled question types
      final questionType = question['type']?.toString();
      if (questionType != null && !userService.isQuestionTypeEnabled(questionType)) {
        return false;
      }

      // Filter by enabled categories (but allow questions without categories)
      final questionCategories = question['categories'] as List<dynamic>?;
      if (questionCategories != null && questionCategories.isNotEmpty) {
        // If there's a temporary category filter, only show questions from that category
        if (tempFilterNotifier.hasTemporaryCategoryFilter) {
          final hasTemporaryCategory = questionCategories.any((category) {
            final categoryName = category.toString();
            return categoryName == tempFilterNotifier.temporaryCategoryFilter;
          });
          if (!hasTemporaryCategory) {
            return false;
          }
        } else {
          // Normal filtering: check if at least one category is enabled
          final hasEnabledCategory = questionCategories.any((category) {
            final categoryName = category.toString();
            return userService.enabledCategories.contains(categoryName);
          });
          if (!hasEnabledCategory) {
            return false;
          }
        }
      } else {
        // If question has no categories and there's a temporary filter, don't show it
        if (tempFilterNotifier.hasTemporaryCategoryFilter) {
          return false;
        }
      }

      // Apply location filter logic same as main feed
      final targeting = question['targeting_type']?.toString();
      bool shouldShowQuestion = true;
      
      switch (_locationFilter) {
        case LocationFilterType.global:
          shouldShowQuestion = true;
          break;
        case LocationFilterType.country:
          if (targeting == 'city' || targeting == 'globe' || targeting == null) {
            shouldShowQuestion = false;
          } else if (targeting == 'country') {
            final questionCountryCode = question['country_code']?.toString();
            final userCountryCode = locationService.userLocation?['country_code']?.toString() ??
                                    locationService.selectedCity?['country_code']?.toString();
            shouldShowQuestion = questionCountryCode != null && userCountryCode != null && 
                               questionCountryCode == userCountryCode;
          } else {
            shouldShowQuestion = false;
          }
          break;
        case LocationFilterType.city:
          if (targeting == 'globe' || targeting == 'country') {
            shouldShowQuestion = false;
          } else if (targeting == 'city') {
            final questionCityId = question['city_id']?.toString();
            final userCityId = locationService.selectedCity?['id']?.toString();
            
            if (questionCityId != null) {
              if (userCityId == null) {
                shouldShowQuestion = false;
              } else if (questionCityId == userCityId) {
                shouldShowQuestion = true;
              } else {
                final questionCountryCode = question['country_code']?.toString() ?? 
                                           question['city_country_code']?.toString();
                final questionAdmin2Code = question['admin2_code']?.toString();
                
                final userCountryCode = locationService.selectedCity?['country_code']?.toString();
                final userAdmin2Code = locationService.selectedCity?['admin2_code']?.toString();
                
                if (questionCountryCode != null && userCountryCode != null && 
                    questionCountryCode == userCountryCode) {
                  if (questionAdmin2Code != null && userAdmin2Code != null) {
                    shouldShowQuestion = questionAdmin2Code == userAdmin2Code;
                  } else {
                    shouldShowQuestion = true;
                  }
                } else {
                  shouldShowQuestion = false;
                }
              }
            }
          } else {
            shouldShowQuestion = false;
          }
          break;
      }
      
      return shouldShowQuestion;
    }).toList();
    
    // Create a combined questions list with QotD first, then filtered feed questions
    final combinedQuestions = [qotd, ...filteredQuestions];
    
    // Create FeedContext for swipe navigation, starting at index 0 (the QotD)
    final filters = _buildFiltersWithLocation(userService, locationService);
    final feedContext = FeedContext(
      feedType: _sortBy,
      filters: filters,
      questions: combinedQuestions,
      currentQuestionIndex: 0, // Start at QotD
      originalQuestionId: qotd['id']?.toString(), // Track QotD as the original question
      originalQuestionIndex: 0, // QotD is at index 0
    );
    
    // Navigate with SwipeNavigationWrapper context
    Map<String, dynamic>? result;
    if (hasAnswered) {
      result = await questionService.navigateToResultsScreen(context, qotd, feedContext: feedContext);
    } else {
      result = await questionService.navigateToAnswerScreen(context, qotd, feedContext: feedContext);
    }
    
    // Handle scroll position if user swiped right to come back
    // Note: For QOTD, we just scroll to the top since it's at the top of the feed
    if (result != null && result['type'] == 'scroll_to_question') {
      print('HomeScreen: QOTD navigation returned, scrolling to top');
      
      _safeAnimateToTop(
        reason: 'qotd_navigation_return',
        duration: Duration(milliseconds: 600),
      );
    }
  }

  Future<Map<String, dynamic>?> _getAlternativeQotd(QuestionService questionService, UserService userService) async {
    try {
      // Get questions from the last 24 hours, sorted by popularity
      final now = DateTime.now();
      final yesterday = now.subtract(Duration(hours: 24));
      
      // Use the trending feed to get popular recent questions
      final locationService = Provider.of<LocationService>(context, listen: false);
      final filters = <String, dynamic>{
        'showNSFW': userService.showNSFWContent,
        'questionTypes': userService.enabledQuestionTypes,
        'userCountry': locationService.userLocation?['country_code'],
        'userCity': locationService.selectedCity?['id'],
      };
      
      final recentQuestions = await questionService.getFeed(
        feedType: 'popular', // Get popular questions as alternatives
        filters: filters,
        userService: userService,
      );
      
      // Filter for questions from last 24 hours that user hasn't reported
      final validAlternatives = recentQuestions.where((question) {
        // Check if question is from last 24 hours
        final createdAt = DateTime.tryParse(question['created_at'] ?? '');
        if (createdAt == null || createdAt.isBefore(yesterday)) {
          return false;
        }
        
        // Check if user has reported this question
        if (userService.shouldHideReportedQuestion(question['id'].toString())) {
          return false;
        }
        
        // Make sure it's not the same as the original QOTD
        final originalQotd = questionService.questionOfTheDay;
        if (originalQotd != null && question['id'] == originalQotd['id']) {
          return false;
        }
        
        return true;
      }).toList();
      
      // Return the most popular valid alternative, or null if none found
      return validAlternatives.isNotEmpty ? validAlternatives.first : null;
    } catch (e) {
      print('Error fetching alternative QOTD: $e');
      return null;
    }
  }

  Widget _buildQotdDisplay(Map<String, dynamic> qotd, bool hasAnswered, bool isAlternative) {
    return Column(
      children: [
        Container(
          margin: EdgeInsets.fromLTRB(16, 4, 16, 12),
          padding: EdgeInsets.all(16),
          constraints: BoxConstraints(
            minHeight: 100,
          ),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: hasAnswered 
                  ? [
                      Colors.grey.withOpacity(0.1),
                      Colors.grey.withOpacity(0.05),
                    ]
                  : [
                      Theme.of(context).primaryColor.withOpacity(0.1),
                      Theme.of(context).primaryColor.withOpacity(0.05),
                    ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: hasAnswered 
                  ? Colors.grey.withOpacity(0.3)
                  : Theme.of(context).primaryColor.withOpacity(0.3),
              width: 1,
            ),
          ),
          child: InkWell(
            onTap: () {
              if (isAlternative) {
                // For alternative questions, use regular navigation
                final questionService = Provider.of<QuestionService>(context, listen: false);
                final userService = Provider.of<UserService>(context, listen: false);
                if (hasAnswered) {
                  questionService.navigateToResultsScreen(context, qotd);
                } else {
                  questionService.navigateToAnswerScreen(context, qotd);
                }
              } else {
                _handleQOTDClick(context, qotd);
              }
            },
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Icon(
                            isAlternative ? Icons.trending_up : Icons.today,
                            color: hasAnswered ? Colors.grey : Theme.of(context).primaryColor,
                            size: 16,
                          ),
                          SizedBox(width: 6),
                          Text(
                            isAlternative ? 'Trending question...' : 'Featured today',
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: hasAnswered ? Colors.grey : Theme.of(context).primaryColor,
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                      SizedBox(height: 8),
                      Text(
                        qotd['prompt'] ?? 'No question available',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w500,
                          color: hasAnswered ? Colors.grey : null,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                if (hasAnswered) ...[
                  SizedBox(width: 8),
                  Icon(
                    Icons.check_circle,
                    color: Colors.grey,
                    size: 18,
                  ),
                ],
              ],
            ),
          ),
        ),
        if (hasAnswered) ...[
          Center(
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    'Thanks for contributing today',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Colors.grey,
                      fontWeight: FontWeight.bold,
                      fontSize: 11,
                    ),
                  ),
                  SizedBox(width: 4),
                  Icon(
                    Icons.favorite,
                    color: Colors.grey,
                    size: 12,
                  ),
                ],
              ),
            ),
          ),
        ] else ...[
          Center(
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    'Answer a question to keep your streak going',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).primaryColor,
                      fontWeight: FontWeight.bold,
                      fontSize: 11,
                    ),
                  ),
                  SizedBox(width: 4),
                  Text(
                    '🔥',
                    style: TextStyle(fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }

  // Get Question of the Day with NSFW filtering
  Future<Map<String, dynamic>?> _getFilteredQuestionOfTheDay() async {
    final questionService = Provider.of<QuestionService>(context, listen: false);
    final userService = Provider.of<UserService>(context, listen: false);
    
    return await questionService.getQuestionOfTheDay(
      showNSFW: userService.showNSFWContent,
    );
  }

  void _showLocationHistoryDialog() {
    final userService = Provider.of<UserService>(context, listen: false);
    final locationService = Provider.of<LocationService>(context, listen: false);
    
    // Ensure current location is in history
    userService.initializeLocationHistory(locationService);
    
    final recentLocations = userService.locationHistory;
    
    if (recentLocations.isEmpty) {
      // Show message if no recent locations
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: Row(
            children: [
              Icon(Icons.place, color: Theme.of(context).primaryColor),
              SizedBox(width: 8),
              Text('Recent Cities'),
            ],
          ),
          content: Text('No recent cities found. Your city history will appear here as you change cities.'),
          actionsPadding: EdgeInsets.all(0),
          actions: [
            // Affiliation notice above buttons
            Container(
              width: double.maxFinite,
              padding: EdgeInsets.symmetric(horizontal: 24, vertical: 16),
              child: Text(
                'Please only set your location to places you are affiliated with in real life.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Colors.grey,
                  fontWeight: FontWeight.w500,
                ),
                textAlign: TextAlign.center,
              ),
            ),
            // Button row
            Container(
              width: double.maxFinite,
              padding: EdgeInsets.symmetric(horizontal: 24, vertical: 16),
              child: Center(
                child: ElevatedButton(
                  onPressed: () {
                    Navigator.of(context).pop();
                    Navigator.pushNamed(context, '/settings');
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Theme.of(context).primaryColor,
                    foregroundColor: Colors.white,
                  ),
                  child: Text('Set Location'),
                ),
              ),
            ),
          ],
        ),
      );
      return;
    }

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.place, color: Theme.of(context).primaryColor),
            SizedBox(width: 8),
            Text('Recent Cities'),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Recent locations list
              ...recentLocations.map((location) {
                final cityName = location['city'] ?? 'Unknown City';
                final countryName = location['country'] ?? 'Unknown Country';
                final isCurrentLocation = _isCurrentLocation(location, locationService);
                
                return Container(
                  margin: EdgeInsets.only(bottom: 8),
                  decoration: BoxDecoration(
                    border: isCurrentLocation ? Border.all(
                      color: Theme.of(context).primaryColor,
                      width: 2,
                    ) : null,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: ListTile(
                    leading: Icon(
                      isCurrentLocation ? Icons.location_on : Icons.place,
                      color: isCurrentLocation ? Theme.of(context).primaryColor : Colors.grey,
                    ),
                    title: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          cityName,
                          style: TextStyle(
                            fontWeight: isCurrentLocation ? FontWeight.bold : FontWeight.normal,
                            color: isCurrentLocation ? Theme.of(context).primaryColor : null,
                          ),
                        ),
                        Text(
                          countryName,
                          style: TextStyle(
                            fontSize: 14,
                            color: Colors.grey,
                            fontWeight: FontWeight.normal,
                          ),
                        ),
                      ],
                    ),
                  onTap: isCurrentLocation ? null : () async {
                    // Switch to this location
                    Navigator.of(context).pop();
                    
                    // Show loading indicator safely
                    _showSafeSnackBar('Switching to $cityName...', duration: Duration(seconds: 1));
                    
                    await userService.applyLocationSwitch(location, locationService);
                    
                    // Trigger feed refresh to show questions for the new location
                    await _refreshFeedAfterLocationChange();
                    
                    // Show confirmation safely
                    _showSafeSnackBar('Switched to $cityName', duration: Duration(seconds: 2));
                  },
                  ),
                );
                }).toList(),
            ],
          ),
        ),
        actionsPadding: EdgeInsets.all(0),
        actions: [
          // Affiliation notice above buttons
          Container(
            padding: EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            child: Text(
              'Please only set your location to places you are affiliated with.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Colors.grey,
                fontWeight: FontWeight.w500,
              ),
              textAlign: TextAlign.center,
            ),
          ),
          // Button row
          Container(
            padding: EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            child: Center(
              child: ElevatedButton(
                onPressed: () {
                  Navigator.of(context).pop();
                  Navigator.pushNamed(context, '/settings');
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: Theme.of(context).primaryColor,
                  foregroundColor: Colors.white,
                ),
                child: Text('Set New Location'),
              ),
            ),
          ),
        ],
      ),
    );
  }

  bool _isCurrentLocation(Map<String, dynamic> location, LocationService locationService) {
    final currentLocation = locationService.userLocation;
    if (currentLocation == null) return false;
    
    return location['country'] == currentLocation['country_name_en'] &&
           location['city'] == locationService.selectedCity?['name'];
  }

  // Helper method to compare two lists for equality
  bool _listEquals<T>(List<T> list1, List<T> list2) {
    if (list1.length != list2.length) return false;
    for (int i = 0; i < list1.length; i++) {
      if (list1[i] != list2[i]) return false;
    }
    return true;
  }

  // Safe method to show SnackBar without widget deactivation errors
  void _showSafeSnackBar(String message, {Duration duration = const Duration(seconds: 2)}) {
    if (!mounted) return;
    
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // Add a small delay to ensure any navigation is complete
      await Future.delayed(Duration(milliseconds: 100));
      
      if (mounted) {
        try {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                message,
                style: TextStyle(color: Colors.white),
              ),
              backgroundColor: Theme.of(context).primaryColor,
              duration: duration,
            ),
          );
        } catch (e) {
          // Silently handle any context issues
          print('Could not show SnackBar: $e');
        }
      }
    });
  }

  // Refresh feed after location change
  Future<void> _refreshFeedAfterLocationChange() async {
    if (!mounted) return;
    
    // Capture services before async operations to avoid disposal issues
    final questionService = Provider.of<QuestionService>(context, listen: false);
    final userService = Provider.of<UserService>(context, listen: false);
    final locationService = Provider.of<LocationService>(context, listen: false);
    
    try {
      setState(() {
        _isLoading = true;
        _hasReachedEnd = false;
      });

      // Build filters with new location
      final filters = <String, dynamic>{
        'showNSFW': userService.showNSFWContent,
        'questionTypes': userService.enabledQuestionTypes,
        'userCountry': locationService.userLocation?['country_code'],
        'userCity': locationService.selectedCity?['id'],
      };

      // Use Edge Function v3 for refresh with new location (includes engagement data)
      final refreshedQuestions = await questionService.getFeed(
        feedType: _sortBy,
        filters: filters,
        userService: userService,
        forceRefresh: true, // Force fresh data for new location
      );

      if (mounted) {
        questionService.updateQuestions(refreshedQuestions, notify: false);
        
        // Refresh QotD for new location
        _qotdKey.currentState?.refreshQotD();
        
        // Reinitialize vote count tracking
        _initializeVoteCountTracking(refreshedQuestions);
        _updateVoteCountsSequentially(refreshedQuestions, questionService);
        
        print('Feed: Refreshed after location change - questions: ${refreshedQuestions.length}');
        
        // Scroll to top after location change
        _safeAnimateToTop(
          reason: 'location_change',
          duration: Duration(milliseconds: 300),
        );
      }
    } catch (e) {
      print('Error refreshing feed after location change: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  // Check if user has answered any question today (extended their streak)
  bool _hasExtendedStreakToday(List<Map<String, dynamic>> questions) {
    if (questions.isEmpty) return false;
    
    // Get current date (today) and normalize to start of day
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    
    // Check if user has any answers today
    for (final question in questions) {
      try {
        final timestamp = question['timestamp'];
        if (timestamp != null) {
          final date = DateTime.parse(timestamp);
          final dateKey = DateTime(date.year, date.month, date.day);
          if (dateKey == today) {
            return true; // Found an answer today
          }
        }
      } catch (e) {
        print('Error parsing timestamp: $e');
        continue;
      }
    }
    return false; // No answers found today
  }

  // Calculate current answer streak for the home screen
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

  // Get hours remaining until end of day
  double _getHoursRemainingToday() {
    final now = DateTime.now();
    final endOfDay = DateTime(now.year, now.month, now.day, 23, 59, 59);
    final timeRemaining = endOfDay.difference(now);
    return timeRemaining.inMinutes / 60.0;
  }

  // Update home screen widget with current streak data
  void _updateHomeWidget() {
    try {
      final userService = Provider.of<UserService>(context, listen: false);
      final currentStreak = _calculateCurrentAnswerStreak(userService.answeredQuestions);
      final hasExtendedToday = _hasExtendedStreakToday(userService.answeredQuestions);

      HomeWidgetService().updateWidget(
        streakCount: currentStreak,
        hasExtendedToday: hasExtendedToday,
      );
    } catch (e) {
      print('Error updating home widget: $e');
    }
  }

  // Check if the streak card should pulse (when it's red/urgent)
  bool _shouldStreakCardPulse(BuildContext context, bool hasExtendedStreakToday) {
    if (!hasExtendedStreakToday) {
      final hoursRemaining = _getHoursRemainingToday();
      return hoursRemaining < 3; // Only pulse when less than 3 hours left
    }
    return false;
  }

  // Get streak card color based on time remaining and whether user has extended streak today
  Color _getStreakCardColor(BuildContext context, bool hasExtendedStreakToday) {
    if (!hasExtendedStreakToday) {
      final hoursRemaining = _getHoursRemainingToday();
      if (hoursRemaining < 3) {
        return Color(0xff951414); // Less than 3 hours left - red with pulsing
      } else if (hoursRemaining < 6) {
        return Color(0xffea6d32); // Less than 6 hours left - orange warning
      }
    }
    // Default: primary color if streak extended, grey if streak is 0
    return Theme.of(context).primaryColor;
  }

  // Get streak card color for a specific streak value (used in animation)
  Color _getStreakCardColorForStreak(int streak, bool hasExtendedToday) {
    if (streak == 0) {
      return Colors.grey;
    }
    if (!hasExtendedToday) {
      final hoursRemaining = _getHoursRemainingToday();
      if (hoursRemaining < 3) {
        return Color(0xff951414); // Red
      } else if (hoursRemaining < 6) {
        return Color(0xffea6d32); // Orange
      }
    }
    return Theme.of(context).primaryColor;
  }

  // Get decoration for streak card border (rainbow when top 5 or >100, regular otherwise)
  Decoration _getStreakCardDecoration(BuildContext context, int currentStreak, {bool isTopFive = false}) {
    // Rainbow border for top 5 leaderboard OR 100+ day streaks
    if (isTopFive || currentStreak > 100) {
      return BoxDecoration(
        borderRadius: BorderRadius.circular(8.0),
        gradient: LinearGradient(
          colors: [
            Colors.red,
            Colors.orange,
            Colors.yellow,
            Colors.green,
            Colors.blue,
            Colors.indigo,
            Colors.purple,
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      );
    } else {
      // Regular border
      return BoxDecoration(
        border: Border.all(
          color: Theme.of(context).dividerColor.withOpacity(0.3),
          width: 0.5,
        ),
        borderRadius: BorderRadius.circular(8.0),
      );
    }
  }

  // Get special dialog border decoration for top 5 or 100+ day streaks
  BoxDecoration? _getStreakDialogBorderDecoration(int currentStreak, {bool isTopFive = false}) {
    // Rainbow border for top 5 leaderboard OR 100+ day streaks
    if (isTopFive || currentStreak > 100) {
      return BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        gradient: LinearGradient(
          colors: [
            Colors.red,
            Colors.orange,
            Colors.yellow,
            Colors.green,
            Colors.blue,
            Colors.indigo,
            Colors.purple,
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      );
    }
    return null;
  }

  Future<int> _getLongestAnswerStreak() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt('longest_answer_streak') ?? 0;
  }

  Future<void> _saveLongestAnswerStreak(int streak) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('longest_answer_streak', streak);
  }

  Future<void> _showAnswerStreakDialog(BuildContext context, UserService userService) async {
    final currentStreak = _calculateCurrentAnswerStreak(userService.answeredQuestions);
    final longestStreak = await _getLongestAnswerStreak();
    final hasExtendedStreakToday = _hasExtendedStreakToday(userService.answeredQuestions);
    final streakRank = userService.streakRank;
    final isTopFive = streakRank >= 1 && streakRank <= 5;

    // Update longest streak if current is longer
    if (currentStreak > longestStreak) {
      await _saveLongestAnswerStreak(currentStreak);
    }

    final isRecord = currentStreak > 0 && currentStreak >= longestStreak;
    final showRainbow = isTopFive || currentStreak > 100;

    // Check if we should show urgent message
    final streakColor = _getStreakCardColor(context, hasExtendedStreakToday);
    final shouldShowUrgent = _shouldStreakCardPulse(context, hasExtendedStreakToday) ||
                            streakColor == Color(0xffea6d32); // Red or orange

    final dialogBorder = _getStreakDialogBorderDecoration(currentStreak, isTopFive: isTopFive);

    showDialog(
      context: context,
      builder: (context) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: Container(
          decoration: dialogBorder,
          padding: showRainbow ? EdgeInsets.all(3) : EdgeInsets.zero,
          child: Container(
            decoration: BoxDecoration(
              color: Theme.of(context).dialogBackgroundColor,
              borderRadius: BorderRadius.circular(showRainbow ? 9 : 12),
            ),
            padding: EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Title section
                Text(
                  'Answer Streak',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                  textAlign: TextAlign.center,
                ),
                SizedBox(height: 12),
                // Streak number with optional medal
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '$currentStreak',
                      style: Theme.of(context).textTheme.displayLarge?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: Theme.of(context).primaryColor,
                      ),
                    ),
                    if (streakRank >= 1 && streakRank <= 3) ...[
                      SizedBox(width: 8),
                      Text(
                        streakRank == 1 ? '🥇' : streakRank == 2 ? '🥈' : '🥉',
                        style: TextStyle(fontSize: 32),
                      ),
                    ],
                  ],
                ),
                // Leaderboard rank section
                if (streakRank > 0 && currentStreak > 0) ...[
                  SizedBox(height: 16),
                  Container(
                    padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: isTopFive
                          ? Theme.of(context).primaryColor.withOpacity(0.1)
                          : Theme.of(context).cardColor,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: isTopFive
                            ? Theme.of(context).primaryColor.withOpacity(0.3)
                            : Theme.of(context).dividerColor,
                      ),
                    ),
                    child: Text(
                      isTopFive
                          ? '🔥 #$streakRank among all active streaks!'
                          : 'Ranked #$streakRank among all active streaks',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: isTopFive ? Theme.of(context).primaryColor : null,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ],
                SizedBox(height: 20),
                // Longest streak info
                Text(
                  isRecord && currentStreak > 0
                      ? 'This is your longest streak ever, keep it up!'
                      : 'Your all-time longest streak was $longestStreak day${longestStreak == 1 ? '' : 's'}.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: isRecord ? Theme.of(context).primaryColor : null,
                    fontWeight: isRecord ? FontWeight.w600 : null,
                  ),
                  textAlign: TextAlign.center,
                ),
                if (shouldShowUrgent) ...[
                  SizedBox(height: 16),
                  Text(
                    'You\'re running out of time today! Answer any question to extend your streak.',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: streakColor,
                      fontWeight: FontWeight.w600,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
                SizedBox(height: 16),
                // Explanation text
                Text(
                  'A streak is the number of consecutive days that you\'ve answered at least one question.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Colors.grey[600],
                  ),
                  textAlign: TextAlign.center,
                ),
                SizedBox(height: 24),
                // Widget suggestion
                GestureDetector(
                  onTap: () async {
                    AnalyticsService().trackEvent('streak_dialog_widget_link_tapped');
                    final uri = Uri.parse('https://readtheroom.site/widgets/');
                    if (await canLaunchUrl(uri)) {
                      await launchUrl(uri, mode: LaunchMode.externalApplication);
                    }
                  },
                  child: Container(
                    padding: EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Theme.of(context).primaryColor.withOpacity(0.08),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: Theme.of(context).primaryColor.withOpacity(0.2),
                        width: 1,
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.widgets_outlined,
                          color: Theme.of(context).primaryColor,
                          size: 20,
                        ),
                        SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Did you know we have widgets? It\'s a quiet way to support the platform.',
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: Theme.of(context).primaryColor,
                            ),
                          ),
                        ),
                        Icon(
                          Icons.open_in_new,
                          color: Theme.of(context).primaryColor,
                          size: 14,
                        ),
                      ],
                    ),
                  ),
                ),
                // Only show streak reminders toggle if not already enabled
                Consumer<UserService>(
                  builder: (context, userService, child) {
                    if (userService.notifyStreakReminders) {
                      // Don't show toggle if reminders are already on
                      return SizedBox.shrink();
                    }

                    return Column(
                      children: [
                        SizedBox(height: 16),
                        // Streak reminders toggle
                        Container(
                          padding: EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Theme.of(context).cardColor,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: Theme.of(context).dividerColor,
                              width: 1,
                            ),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                Icons.local_fire_department_outlined,
                                color: Colors.grey,
                                size: 20,
                              ),
                              SizedBox(width: 8),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'Streak reminders',
                                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                    Text(
                                      'Reminder time can be customized in Settings.',
                                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                        color: Colors.grey[600],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Switch(
                                value: false,
                                onChanged: (value) {
                                  userService.setNotifyStreakReminders(value);
                                  AnalyticsService().trackEvent('streak_reminder_changed', {'enabled': true, 'source': 'streak_dialog'});

                                  // Show brief feedback
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text('Streak reminders enabled! Adjust reminder times in Settings.'),
                                      backgroundColor: Theme.of(context).primaryColor,
                                      duration: Duration(seconds: 3),
                                    ),
                                  );
                                },
                              ),
                            ],
                          ),
                        ),
                      ],
                    );
                  },
                ),
                SizedBox(height: 16),
                // Action button
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text('Got it'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // Helper method to get the top emoji reaction
  String? _getTopEmojiReaction(Map<String, dynamic> question) {
    // First, try the pre-computed top_emoji field from materialized view
    final precomputedTopEmoji = question['top_emoji']?.toString();
    if (precomputedTopEmoji != null && precomputedTopEmoji.isNotEmpty) {
      final questionId = question['id']?.toString();
      final shortId = questionId != null && questionId.length >= 8 ? questionId.substring(0, 8) : questionId;
      // print('🎭 DEBUG HOME - Question $shortId using pre-computed top_emoji: $precomputedTopEmoji');  // Commented out excessive logging
      return precomputedTopEmoji;
    }

    // Fallback to client-side calculation if top_emoji is not available
    final reactions = question['reactions'];
    
    // Debug print to see what data is available
    final questionId = question['id']?.toString();
    final shortId = questionId != null && questionId.length >= 8 ? questionId.substring(0, 8) : questionId;
    // print('🎭 DEBUG HOME - Question $shortId reactions data: $reactions (type: ${reactions.runtimeType}) - computing client-side');  // Commented out excessive logging
    
    if (reactions == null) return null;

    Map<String, dynamic>? reactionsMap;

    // Handle both Map and String (JSON) formats
    if (reactions is Map<String, dynamic>) {
      reactionsMap = reactions;
    } else if (reactions is String) {
      try {
        reactionsMap = json.decode(reactions) as Map<String, dynamic>;
      } catch (e) {
        return null;
      }
    }

    if (reactionsMap == null || reactionsMap.isEmpty) return null;

    // Find the emoji with the highest count
    String? topEmoji;
    int maxCount = 0;

    for (final entry in reactionsMap.entries) {
      final count = entry.value;
      if (count is int && count > maxCount) {
        maxCount = count;
        topEmoji = entry.key;
      }
    }

    // Only return emoji if it has at least 1 reaction
    final result = (maxCount > 0) ? topEmoji : null;
    if (result != null) {
      // print('🎭 DEBUG HOME - Question $shortId computed top emoji: $result (count: $maxCount)');  // Commented out excessive logging
    }
    return result;
  }

  int _getReactionCount(Map<String, dynamic> question) {
    // Check for reaction_count field first (from materialized view)
    if (question.containsKey('reaction_count')) {
      return question['reaction_count'] as int? ?? 0;
    }
    
    // Get total reaction count from reactions JSON
    final reactions = question['reactions'];
    if (reactions == null) return 0;
    
    // Handle both Map and potentially encoded JSON string
    if (reactions is Map<String, dynamic>) {
      int total = 0;
      for (final count in reactions.values) {
        if (count is int) total += count;
      }
      return total;
    } else if (reactions is String) {
      try {
        final decodedReactions = json.decode(reactions) as Map<String, dynamic>;
        int total = 0;
        for (final count in decodedReactions.values) {
          if (count is int) total += count;
        }
        return total;
      } catch (e) {
        print('Error decoding reactions JSON: $e');
        return 0;
      }
    }
    
    return 0;
  }

  int _getCommentCount(Map<String, dynamic> question) {
    // Get comment count from question data
    return question['comment_count'] as int? ?? 0;
  }
  
  void _initializeCommentLoadingQueue(List<Map<String, dynamic>> questions) {
    // Find questions that need enrichment
    final questionsNeedingEnrichment = <String>[];
    for (final question in questions) {
      final questionId = question['id']?.toString();
      if (questionId != null && 
          !_enrichedQuestions.contains(questionId) &&
          (!question.containsKey('comment_count') || question['comment_count'] == null)) {
        questionsNeedingEnrichment.add(questionId);
      }
    }
    
    // Only reinitialize if there are new questions to add
    if (questionsNeedingEnrichment.isEmpty) return;
    
    // Only reinitialize if the queue is significantly different
    final newQueueSet = questionsNeedingEnrichment.toSet();
    final currentQueueSet = _commentLoadingQueue.toSet();
    if (newQueueSet.difference(currentQueueSet).isEmpty) return;
    
    // Update the queue with new questions
    _commentLoadingQueue = questionsNeedingEnrichment;
    _commentLoadingOffset = 0;
    
    // Start loading first batch immediately (for questions in viewport)
    if (_commentLoadingQueue.isNotEmpty && !_isLoadingComments) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _loadMoreComments();
        }
      });
    }
  }
  
  void _resetCommentLoadingState() {
    _commentLoadingQueue.clear();
    _commentLoadingOffset = 0;
    _enrichedQuestions.clear();
    _isLoadingComments = false;
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
      print('🧹 UI: Removed ${questions.length - uniqueQuestions.length} duplicate questions during pagination');
    }
    
    return uniqueQuestions;
  }
}

// Standalone widget for Question of the Day with NSFW filtering
class QuestionOfTheDayWidget extends StatefulWidget {
  final UserService userService;
  final Function(BuildContext, Map<String, dynamic>) onQOTDClick;

  const QuestionOfTheDayWidget({
    Key? key,
    required this.userService,
    required this.onQOTDClick,
  }) : super(key: key);

  @override
  QuestionOfTheDayWidgetState createState() => QuestionOfTheDayWidgetState();
}

class QuestionOfTheDayWidgetState extends State<QuestionOfTheDayWidget> {
  Future<Map<String, dynamic>?>? _qotdFuture;

  @override
  void initState() {
    super.initState();
    _qotdFuture = _getFilteredQuestionOfTheDay();
  }

  // Check if user has answered any question today (extended their streak)
  bool _hasExtendedStreakToday(List<Map<String, dynamic>> questions) {
    if (questions.isEmpty) return false;
    
    // Get current date (today) and normalize to start of day
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    
    // Check if user has any answers today
    for (final question in questions) {
      try {
        final timestamp = question['timestamp'];
        if (timestamp != null) {
          final date = DateTime.parse(timestamp);
          final dateKey = DateTime(date.year, date.month, date.day);
          if (dateKey == today) {
            return true; // Found an answer today
          }
        }
      } catch (e) {
        print('Error parsing timestamp: $e');
        continue;
      }
    }
    return false; // No answers found today
  }

  // Helper method to safely get comment count
  int _getCommentCount(Map<String, dynamic> question) {
    // Debug: Print comment fields
    print('QOTD DEBUG - comment_count: ${question['comment_count']}, comments_count: ${question['comments_count']}, total_comments: ${question['total_comments']}');
    
    // Try different possible field names for comment count
    return question['comment_count'] as int? ?? 
           question['comments_count'] as int? ?? 
           question['total_comments'] as int? ?? 
           0;
  }

  // Helper method to safely get vote count
  int _getVoteCount(Map<String, dynamic> question) {
    // Debug: Print vote count after enrichment
    print('QOTD DEBUG - final votes field: ${question['votes']}');
    
    // The votes field should now be populated correctly by getAccurateVoteCount
    return question['votes'] as int? ?? 0;
  }

  // Method to enrich QOTD with engagement data
  Future<void> _enrichQOTDWithEngagement(Map<String, dynamic> qotd) async {
    try {
      final questionService = Provider.of<QuestionService>(context, listen: false);
      await questionService.enrichQuestionsWithEngagementData([qotd]);
    } catch (e) {
      print('Error enriching QOTD with engagement data: $e');
    }
  }

  // Method to refresh the QotD (can be called from parent)
  void refreshQotD() {
    setState(() {
      _qotdFuture = _getFilteredQuestionOfTheDay();
    });
  }

  Future<Map<String, dynamic>?> _getFilteredQuestionOfTheDay() async {
    final questionService = Provider.of<QuestionService>(context, listen: false);
    
    final qotd = await questionService.getQuestionOfTheDay(
      showNSFW: widget.userService.showNSFWContent,
    );
    
    // Enrich QOTD with engagement data before returning it
    if (qotd != null) {
      try {
        await questionService.enrichQuestionsWithEngagementData([qotd]);
        
        // Get accurate vote count using the same method as regular questions
        final questionId = qotd['id']?.toString();
        final questionType = qotd['type']?.toString();
        if (questionId != null) {
          final voteCount = await questionService.getAccurateVoteCount(questionId, questionType);
          qotd['votes'] = voteCount;
          print('QOTD enriched with accurate vote count: $voteCount');
        }
        
        print('QOTD enriched with engagement data: votes=${qotd['votes']}, comment_count=${qotd['comment_count']}');

        // Update QOTD home screen widget (Android only - iOS temporarily disabled)
        final hasAnswered = questionService.hasAnsweredQuestionOfTheDay(widget.userService);
        await HomeWidgetService().updateQOTDWidget(
          questionText: qotd['prompt']?.toString() ?? '',
          voteCount: qotd['votes'] as int? ?? 0,
          commentCount: qotd['comment_count'] as int? ?? 0,
          hasAnswered: hasAnswered,
          questionId: qotd['id']?.toString() ?? '',
        );
      } catch (e) {
        print('Error enriching QOTD: $e');
      }
    }

    return qotd;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Map<String, dynamic>?>(
      future: _qotdFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          // Show placeholder while loading
          return Container(
            margin: EdgeInsets.fromLTRB(16, 4, 16, 12),
            padding: EdgeInsets.all(16),
            constraints: BoxConstraints(minHeight: 100),
            decoration: BoxDecoration(
              color: Colors.grey.withOpacity(0.1),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: Colors.grey.withOpacity(0.3),
                width: 1,
              ),
            ),
            child: Center(
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          );
        }
        
        final qotd = snapshot.data;
        if (qotd == null) return SizedBox.shrink();
        
        final questionService = Provider.of<QuestionService>(context, listen: false);
        final hasAnsweredQOTD = questionService.hasAnsweredQuestionOfTheDay(widget.userService);
        final hasExtendedStreakToday = _hasExtendedStreakToday(widget.userService.answeredQuestions);
        
        return Column(
          children: [
            Container(
              margin: EdgeInsets.fromLTRB(16, 4, 16, 12),
              padding: EdgeInsets.all(16),
              constraints: BoxConstraints(
                minHeight: 100,
              ),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: hasAnsweredQOTD
                      ? [
                          Colors.grey.withOpacity(0.1),
                          Colors.grey.withOpacity(0.05),
                        ]
                      : [
                          Theme.of(context).primaryColor.withOpacity(0.1),
                          Theme.of(context).primaryColor.withOpacity(0.05),
                        ],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: hasAnsweredQOTD
                      ? Colors.grey.withOpacity(0.3)
                      : Theme.of(context).primaryColor.withOpacity(0.3),
                  width: 1,
                ),
              ),
              child: InkWell(
                onTap: () {
                  widget.onQOTDClick(context, qotd);
                },
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.today,
                                color: hasAnsweredQOTD
                                    ? Colors.grey.withOpacity(0.8)
                                    : Theme.of(context).primaryColor,
                                size: 16,
                              ),
                              SizedBox(width: 6),
                              Text(
                                'Question of the Day',
                                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                  color: hasAnsweredQOTD
                                      ? Colors.grey.withOpacity(0.8)
                                      : Theme.of(context).primaryColor,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 18,
                                ),
                              ),
                              SizedBox(width: 6),
                              Icon(
                                Icons.today,
                                color: hasAnsweredQOTD
                                    ? Colors.grey.withOpacity(0.8)
                                    : Theme.of(context).primaryColor,
                                size: 16,
                              ),
                            ],
                          ),
                          SizedBox(height: 12),
                          Text(
                            qotd['prompt'] ?? 'No question available',
                            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w500,
                              color: hasAnsweredQOTD
                                  ? Colors.grey.withOpacity(0.8)
                                  : Theme.of(context).primaryColor,
                              fontSize: 16,
                            ),
                            textAlign: TextAlign.center,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          SizedBox(height: 12),
                          // Display vote and comment counts with votes on left, comments on right
                          Row(
                            children: [
                              // Show vote count only if > 1
                              if (_getVoteCount(qotd) > 1)
                                Text(
                                  '${_getVoteCount(qotd)} votes',
                                  style: TextStyle(
                                    color: hasAnsweredQOTD
                                        ? Colors.grey
                                        : Theme.of(context).primaryColor,
                                    fontSize: 12,
                                  ),
                                ),
                              Spacer(),
                              // Show comment count only if > 1
                              if (_getCommentCount(qotd) > 1)
                                Text(
                                  '${_getCommentCount(qotd)} comments',
                                  style: TextStyle(
                                    color: hasAnsweredQOTD
                                        ? Colors.grey
                                        : Theme.of(context).primaryColor,
                                    fontSize: 12,
                                  ),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (!hasExtendedStreakToday) ...[
              Center(
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        'Answer any question to extend your streak',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).primaryColor,
                          fontWeight: FontWeight.bold,
                          fontSize: 12,
                        ),
                      ),
                      SizedBox(width: 4),
                      Icon(
                        Icons.local_fire_department,
                        color: Theme.of(context).primaryColor,
                        size: 12,
                      ),
                    ],
                  ),
                ),
              ),
            ] else ...[
              Center(
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        'Thank you for contributing today',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Colors.grey,
                          fontWeight: FontWeight.bold,
                          fontSize: 12,
                        ),
                      ),
                      SizedBox(width: 4),
                      Icon(
                        Icons.favorite,
                        color: Colors.grey,
                        size: 12,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

