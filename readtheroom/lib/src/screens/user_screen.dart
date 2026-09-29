// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:async';
import 'dart:convert';
import '../services/user_service.dart';
import '../utils/time_utils.dart';
import '../utils/theme_utils.dart';
import 'approval_results_screen.dart';
import 'multiple_choice_results_screen.dart';
import 'text_results_screen.dart';
import 'answer_approval_screen.dart';
import 'answer_multiple_choice_screen.dart';
import 'answer_text_screen.dart';
import 'authentication_screen.dart';
import '../widgets/answer_streak_dialog.dart';
import '../widgets/profile_header.dart';
import '../widgets/question_type_badge.dart';
import '../services/question_service.dart';
import '../services/watchlist_service.dart';
import '../services/question_cache_service.dart';
import '../services/notification_service.dart';
import '../widgets/question_activity_permission_dialog.dart';
import '../services/device_id_provider.dart';
import '../services/passkeys_service.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'dart:io';
import '../services/achievement_service.dart';
import '../services/congratulations_service.dart';
import '../services/friend_service.dart';
import '../utils/badge_logic.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class UserScreen extends StatefulWidget {
  final bool fromAuthentication;
  
  const UserScreen({Key? key, this.fromAuthentication = false}) : super(key: key);
  
  @override
  _UserScreenState createState() => _UserScreenState();
}

class _UserScreenState extends State<UserScreen> with WidgetsBindingObserver {
  // Camo Collection: server-side badge stats, loaded by _loadBadgeData().
  _BadgeData? _badgeData;
  bool _badgeLoading = false;
  bool _badgeForcedReloadQueued = false;
  String? _badgeLoadedForKey;

  // Cache the subscribed questions future to prevent multiple calls
  Future<List<Map<String, dynamic>>>? _cachedSubscribedQuestionsFuture;

  // Delayed removal system for unsubscribed questions
  Set<String> _pendingRemovals = {};
  Timer? _removalTimer;
  List<String> _recentlyUnsubscribed = [];
  bool _showingUndoSnackbar = false;
  
  // Progressive comment loading state
  bool _isLoadingComments = false;
  int _commentLoadingOffset = 0;
  List<String> _commentLoadingQueue = [];
  Set<String> _enrichedQuestions = {}; // Track which questions already have comment data
  
  // Vote count tracking state
  Timer? _voteCountPollTimer;
  Map<String, int> _lastKnownVoteCounts = {}; // Track last known vote counts
  bool _isPollingPaused = false; // Track if polling is paused

  @override
  void initState() {
    super.initState();
    // Add lifecycle observer to detect when user returns from viewing questions
    WidgetsBinding.instance.addObserver(this);
    
    // Force refresh of subscribed questions cache when screen loads
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _refreshSubscribedQuestionsCache();
        _loadBadgeData();
        // Start vote count polling for user questions
        _startVoteCountPolling();
        // Disabled aggressive cleanup - was causing subscribed questions to disappear
        // _cleanupStaleQuestionViewPreferences();
      }
    });
  }
  
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _removalTimer?.cancel();
    _voteCountPollTimer?.cancel(); // Cancel vote count polling timer
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    
    switch (state) {
      case AppLifecycleState.resumed:
        // App came to foreground - resume polling and refresh cache
        print('UserScreen: App resumed, resuming vote count polling');
        _resumeVoteCountPolling();
        // Fallback: Refresh subscribed questions cache when app comes back to foreground
        // Primary refresh happens when user returns from navigation (see onTap handlers)
        _refreshSubscribedQuestionsCache();
        break;
      case AppLifecycleState.paused:
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        // App went to background or was closed - pause polling
        print('UserScreen: App backgrounded/closed, pausing vote count polling');
        _pauseVoteCountPolling();
        break;
      case AppLifecycleState.hidden:
        // App is hidden but still running - pause polling
        print('UserScreen: App hidden, pausing vote count polling');
        _pauseVoteCountPolling();
        break;
    }
  }


  @override
  Widget build(BuildContext context) {
    return Consumer<UserService>(
      builder: (context, userService, child) {
        return Scaffold(
          appBar: AppBar(title: Text('Me')),
          body: GestureDetector(
            onHorizontalDragEnd: (details) {
              // Check if swipe is from left to right with sufficient velocity
              if (details.primaryVelocity != null && details.primaryVelocity! > 300) {
                Scaffold.of(context).openDrawer();
              }
            },
            child: RefreshIndicator(
              onRefresh: () async {
                // Refresh engagement ranking when user pulls to refresh
                final userService = Provider.of<UserService>(context, listen: false);
                await userService.refreshEngagementRanking();

                // Refresh subscribed questions cache
                _refreshSubscribedQuestionsCache();

                // Refresh badges, bypassing their caches
                await _loadBadgeData(forceRefresh: true);
              },
                  child: SingleChildScrollView(
                    physics: AlwaysScrollableScrollPhysics(), // Enable pull-to-refresh even when content is short
                    child: Padding(
                    padding: EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Chameleon identity header (avatar + handle + edit).
                        if (Supabase.instance.client.auth.currentUser != null)
                          const ProfileHeader(),

                        // Authentication message for non-authenticated users - show first
                        if (Supabase.instance.client.auth.currentUser == null)
                          Container(
                            margin: EdgeInsets.only(bottom: 20),
                            padding: EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: Theme.of(context).brightness == Brightness.dark
                                  ? Colors.orange.shade900.withOpacity(0.3)
                                  : Colors.orange.shade50,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: Theme.of(context).brightness == Brightness.dark
                                    ? Colors.orange.shade700.withOpacity(0.6)
                                    : Colors.orange.shade300,
                              ),
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.security,
                                  color: Colors.orange,
                                  size: 20,
                                ),
                                SizedBox(width: 12),
                                Expanded(
                                  child: RichText(
                                    text: TextSpan(
                                      style: Theme.of(context).textTheme.bodyMedium,
                                      children: [
                                        TextSpan(
                                          text: 'Verify that you are a human',
                                          style: TextStyle(
                                            color: Colors.orange,
                                            decoration: TextDecoration.none,
                                            fontWeight: FontWeight.bold,
                                          ),
                                          recognizer: TapGestureRecognizer()
                                            ..onTap = () {
                                              Navigator.push(
                                                context,
                                                MaterialPageRoute(
                                                  builder: (context) => AuthenticationScreen(),
                                                ),
                                              );
                                            },
                                        ),
                                        TextSpan(
                                          text: ' for full access to the app',
                                          style: TextStyle(
                                            color: Theme.of(context).textTheme.bodyMedium?.color,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),

                        // Stats section with integrated question dropdowns
                        if (Supabase.instance.client.auth.currentUser != null)
                          _buildStatsSection(userService),
                        
                      ],
                    ),
                  ),
                  ),
            ),
          ),
        );
      },
    );
  }

  // Enhanced device ID display methods
  Widget _buildEnhancedDeviceIdDisplay() {
    return FutureBuilder<Map<String, dynamic>>(
      future: _getEnhancedDeviceIdInfo(),
      builder: (context, snapshot) {
        if (snapshot.hasData) {
          final info = snapshot.data!;
          final deviceId = info['device_id'] as String;
          final platform = info['platform'] as String;
          final isLegacy = info['is_legacy'] as bool;
          final label = info['label'] as String;
          final labelColor = info['label_color'] as Color;
          final isClickable = info['is_clickable'] as bool;
          
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '$label (for debugging):',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: labelColor,
                  fontWeight: FontWeight.w500,
                ),
              ),
              SizedBox(height: 4),
              GestureDetector(
                onTap: () {
                  if (isClickable && isLegacy) {
                    _performDeviceIdMigration();
                  } else {
                    // Copy to clipboard
                    Clipboard.setData(ClipboardData(text: deviceId));
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('Device ID copied to clipboard'),
                        duration: Duration(seconds: 2),
                        backgroundColor: isLegacy ? Colors.orange : Colors.teal,
                      ),
                    );
                  }
                },
                child: Text(
                  deviceId,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: isLegacy ? Colors.orange : Colors.grey[500],
                    fontStyle: FontStyle.italic,
                    fontSize: 10,
                    decoration: TextDecoration.underline,
                    decorationStyle: isLegacy ? TextDecorationStyle.solid : TextDecorationStyle.dotted,
                    decorationColor: isLegacy ? Colors.orange : Colors.grey[500],
                  ),
                ),
              ),
              if (isLegacy) ...[
                SizedBox(height: 4),
                Row(
                  children: [
                    Icon(
                      Icons.touch_app,
                      size: 12,
                      color: Colors.orange,
                    ),
                    SizedBox(width: 4),
                    Text(
                      'Tap to migrate to enhanced privacy',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Colors.orange,
                        fontSize: 9,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ],
                ),
              ],
            ],
          );
        } else if (snapshot.hasError) {
          return Text(
            'Device ID: Error loading',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Colors.grey[500],
              fontStyle: FontStyle.italic,
              fontSize: 10,
            ),
          );
        } else {
          return Text(
            'Device ID: Loading...',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Colors.grey[500],
              fontStyle: FontStyle.italic,
              fontSize: 10,
            ),
          );
        }
      },
    );
  }

  Future<Map<String, dynamic>> _getEnhancedDeviceIdInfo() async {
    final deviceId = await _getDeviceId() ?? 'Unknown';
    final platform = Platform.isAndroid ? 'android' : Platform.isIOS ? 'ios' : 'unknown';
    final isLegacy = Platform.isAndroid ? await DeviceIdProvider.isLegacyAndroidId() : false;
    
    String label;
    Color labelColor;
    bool isClickable = false;
    
    if (platform == 'android') {
      if (isLegacy) {
        label = 'Android ID (legacy)';
        labelColor = Colors.orange;
        isClickable = true;
      } else {
        label = 'Android ID';
        labelColor = Theme.of(context).primaryColor;
      }
    } else if (platform == 'ios') {
      label = 'iOS ID';
      labelColor = Theme.of(context).primaryColor;
    } else {
      label = 'Device ID';
      labelColor = Colors.grey[600]!;
    }
    
    return {
      'device_id': deviceId,
      'platform': platform,
      'is_legacy': isLegacy,
      'label': label,
      'label_color': labelColor,
      'is_clickable': isClickable,
    };
  }

  Future<void> _performDeviceIdMigration() async {
    try {
      // Show loading dialog
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text('Migrating Android ID...'),
            ],
          ),
        ),
      );
      
      final passkeysService = PasskeysService();
      final success = await passkeysService.migrateDeviceId();
      
      // Close loading dialog
      if (mounted) {
        Navigator.of(context).pop();
      }
      
      if (success) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('✅ Android ID migration successful!'),
              backgroundColor: Colors.green,
              duration: Duration(seconds: 3),
            ),
          );
          // Trigger rebuild to update the display
          setState(() {});
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('❌ Migration failed. Please try again later.'),
              backgroundColor: Colors.red,
              duration: Duration(seconds: 3),
            ),
          );
        }
      }
    } catch (e) {
      // Close loading dialog if still open
      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('❌ Migration error: ${e.toString()}'),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 3),
          ),
        );
      }
    }
  }

  Widget _buildQuestionSection(String title, List<Map<String, dynamic>> questions, IconData icon, {bool isSubscribedSection = false}) {
    // Enrich questions with engagement data if needed (fire and forget)
    // This will update the UI when data is loaded
    _enrichQuestionsIfNeeded(questions);
    
    List<Map<String, dynamic>> sortedQuestions;
    
    // Sort all questions by created_at (most recent first) for consistency
    sortedQuestions = List<Map<String, dynamic>>.from(questions)
      ..sort((a, b) {
        try {
          // Try different timestamp fields in order of preference
          String? aTimeStr = a['created_at'] ?? a['timestamp'] ?? a['created_at_timestamp'];
          String? bTimeStr = b['created_at'] ?? b['timestamp'] ?? b['created_at_timestamp'];
          
          if (aTimeStr == null || bTimeStr == null) {
            return 0; // Keep original order if no dates available
          }
          
          final aDateTime = DateTime.parse(aTimeStr);
          final bDateTime = DateTime.parse(bTimeStr);
          return bDateTime.compareTo(aDateTime); // Most recent first
        } catch (e) {
          print('Error parsing timestamps for sorting: $e');
          return 0; // Keep original order if parsing fails
        }
      });

    final isAuthenticated = Supabase.instance.client.auth.currentUser != null;
    
    // Calculate total deltas for subscribed questions (comments only)
    int totalCommentDelta = 0;
    if (isSubscribedSection) {
      totalCommentDelta = questions.fold(0, (sum, question) => sum + (question['commentDelta'] as int? ?? 0));
    }
    
    // Format title with count when > 1
    String displayTitle = title;
    if (questions.length > 1) {
      final baseTitle = title.split(' ')[0]; // Get first word (Posted/Answered/Saved)
      final countText = _formatCount(questions.length);
      displayTitle = '$baseTitle ($countText)';
    }
    
    // Remove comment deltas from title for subscribed section
    // (comment deltas are now shown individually on each question)
    
    return Card(
      margin: EdgeInsets.only(bottom: 16),
      color: ThemeUtils.getDropdownBackgroundColor(context),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12.0),
      ),
      child: ExpansionTile(
        leading: Icon(icon),
        title: Text(displayTitle),
        onExpansionChanged: (expanded) {
          // If user is not authenticated and trying to expand, navigate to auth screen
          if (expanded && !isAuthenticated) {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => AuthenticationScreen(),
              ),
            );
          }
        },
        children: !isAuthenticated
            ? [
                ListTile(
                  title: Text(
                    'Authentication required',
                    style: TextStyle(
                      color: Colors.grey[600],
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                  subtitle: Text(
                    'Please authenticate to view this section',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Colors.grey[500],
                    ),
                  ),
                ),
              ]
            : sortedQuestions.isEmpty
                ? [ListTile(title: Text('No questions yet'))]
                : sortedQuestions.map((question) => _buildQuestionTile(question, sortedQuestions, title, isSubscribedSection: isSubscribedSection)).toList(),
      ),
    );
  }

  String _formatCount(int count) {
    if (count >= 10000) {
      return '${(count / 1000).round()}K+';
    } else {
      return count.toString();
    }
  }

  Widget _buildQuestionTile(Map<String, dynamic> question, List<Map<String, dynamic>> allQuestions, String sectionTitle, {bool isSubscribedSection = false}) {
    final voteDelta = question['voteDelta'] as int? ?? 0;
    final currentVotes = question['votes'] as int? ?? 0;
    final currentComments = _getCommentCount(question);
    
    return Consumer2<UserService, WatchlistService>(
      builder: (context, userService, watchlistService, child) {
        final isSubscribed = watchlistService.isWatching(question['id'].toString());
        
        // Create a safe time ago string with error handling
        String timeAgoString = 'Unknown';
        try {
          // Try multiple possible timestamp field names
          final timestamp = question['timestamp'] ?? question['created_at'];
          if (timestamp != null) {
            timeAgoString = getTimeAgo(timestamp);
          }
        } catch (e) {
          print('Error getting time ago: $e');
        }
        
        return StatefulBuilder(
          builder: (context, setState) {
            final listTile = ListTile(
              leading: QuestionTypeBadge(type: question['type'] ?? 'text'),
              title: Text(question['prompt'] ?? question['title'] ?? 'No Title'),
              subtitle: _buildSubtitle(context, question, timeAgoString, voteDelta, isSubscribedSection),
              trailing: isSubscribedSection
                  ? IconButton(
                      icon: Icon(
                        _pendingRemovals.contains(question['id'].toString()) 
                            ? Icons.notifications_off
                            : (isSubscribed ? Icons.notifications_active : Icons.notifications_off),
                        color: _pendingRemovals.contains(question['id'].toString())
                            ? Colors.grey
                            : (isSubscribed ? Theme.of(context).primaryColor : Colors.grey),
                      ),
                      onPressed: () async {
                        if (isSubscribed && !_pendingRemovals.contains(question['id'].toString())) {
                          // Schedule removal instead of immediate unsubscribe
                          _scheduleRemoval(question['id'].toString());
                          
                          // Force rebuild of this specific tile
                          setState(() {});
                          
                          // Show snackbar with batch undo
                          if (!_showingUndoSnackbar) {
                            _showingUndoSnackbar = true;
                            final scaffoldMessenger = ScaffoldMessenger.of(context);
                            final primaryColor = Theme.of(context).primaryColor;
                            
                            scaffoldMessenger.showSnackBar(
                              SnackBar(
                                content: Row(
                                  children: [
                                    Icon(Icons.notifications_off, color: Colors.white, size: 20),
                                    SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        _recentlyUnsubscribed.length == 1 
                                            ? 'Unsubscribed from question'
                                            : 'Unsubscribed from ${_recentlyUnsubscribed.length} questions'
                                      ),
                                    ),
                                    TextButton(
                                      onPressed: () {
                                        _undoRecentUnsubscriptions();
                                        _showingUndoSnackbar = false;
                                      },
                                      style: TextButton.styleFrom(
                                        padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                        minimumSize: Size(0, 0),
                                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                      ),
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
                                backgroundColor: primaryColor,
                                duration: Duration(seconds: 4),
                                onVisible: () {
                                  // Reset flag when snackbar is dismissed
                                  Future.delayed(Duration(seconds: 4), () {
                                    _showingUndoSnackbar = false;
                                  });
                                },
                              ),
                            );
                          }
                        } else if (_pendingRemovals.contains(question['id'].toString())) {
                          // Cancel removal for this specific question
                          _pendingRemovals.remove(question['id'].toString());
                          _recentlyUnsubscribed.remove(question['id'].toString());
                          
                          // Force rebuild of this specific tile
                          setState(() {});
                          
                          _clearSubscribedQuestionsCache();
                          
                          // If no more pending removals, cancel the timer
                          if (_pendingRemovals.isEmpty) {
                            _removalTimer?.cancel();
                          }
                        } else {
                          // Subscribe to question - check permissions first
                          final notificationService = NotificationService();
                          
                          // Check if notification permissions are granted AND user has enabled notifications
                          final permissionsGranted = await notificationService.arePermissionsGranted();
                          final notificationsEnabled = userService.notifyResponses;
                          
                          if (!permissionsGranted || !notificationsEnabled) {
                            // Show the q-activity permission dialog
                            await QuestionActivityPermissionDialog.show(
                              context,
                              onPermissionGranted: () async {
                                // Permission granted - enable notifications and subscribe to the question
                                userService.setNotifyResponses(true);
                                
                                await watchlistService.subscribeToQuestion(question['id'].toString(), currentVotes, currentComments);
                                _clearSubscribedQuestionsCache();
                                
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Row(
                                      children: [
                                        Icon(Icons.notifications_active, color: Colors.white, size: 20),
                                        SizedBox(width: 8),
                                        Expanded(child: Text('Subscribed! You\'ll be notified when there is new activity.')),
                                      ],
                                    ),
                                    backgroundColor: Theme.of(context).primaryColor,
                                    duration: Duration(seconds: 3),
                                  ),
                                );
                              },
                              onPermissionDenied: () async {
                                // Permission denied - don't subscribe
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Row(
                                      children: [
                                        Icon(Icons.notifications_off, color: Colors.white, size: 20),
                                        SizedBox(width: 8),
                                        Expanded(child: Text('Notifications are disabled. You can enable them in Settings.')),
                                      ],
                                    ),
                                    backgroundColor: Colors.orange,
                                    duration: Duration(seconds: 4),
                                  ),
                                );
                              },
                            );
                          } else {
                            // Permissions already granted - subscribe directly
                            await watchlistService.subscribeToQuestion(question['id'].toString(), currentVotes, currentComments);
                            _clearSubscribedQuestionsCache();
                          }
                        }
                      },
                    )
                  : null,
              onTap: () async {
                // Fetch complete question data with priority caching
                final questionService = Provider.of<QuestionService>(context, listen: false);
                final userService = Provider.of<UserService>(context, listen: false);
                
                try {
                  // Check cache first for instant navigation
                  final cacheService = QuestionCacheService();
                  cacheService.initialize(questionService);
                  
                  final questionId = question['id'].toString();
                  var completeQuestion = cacheService.getCachedQuestionWithResponses(questionId);
                  bool showedLoading = false;
                  
                  if (completeQuestion == null) {
                    // Show loading indicator only if not cached
                    showedLoading = true;
                    showDialog(
                      context: context,
                      barrierDismissible: false,
                      builder: (context) => Center(
                        child: CircularProgressIndicator(),
                      ),
                    );
                    
                    // Priority prefetch this question and next 3
                    final currentIndex = allQuestions.indexWhere((q) => q['id'] == questionId);
                    final nextIds = cacheService.getNextQuestionIds(allQuestions, currentIndex, count: 3);
                    final prefetchIds = [questionId, ...nextIds];
                    
                    await cacheService.prefetchQuestions(prefetchIds, priority: true);
                    
                    // Get from cache after priority fetch
                    completeQuestion = cacheService.getCachedQuestionWithResponses(questionId);
                    
                    // If still null, fallback to direct fetch
                    completeQuestion ??= await questionService.getQuestionById(questionId);
                  }
                  
                  // Hide loading indicator only if we showed it
                  if (showedLoading) {
                    Navigator.of(context).pop();
                  }
                  
                  if (completeQuestion != null) {
                    // Create FeedContext for this section to enable swipe navigation
                    final currentQuestionIndex = allQuestions.indexWhere((q) => q['id'] == completeQuestion!['id']);
                    final feedContext = FeedContext(
                      feedType: sectionTitle.toLowerCase().replaceAll(' ', '_'), // e.g., "answered_questions"
                      filters: {}, // No filters for user sections
                      questions: allQuestions,
                      currentQuestionIndex: currentQuestionIndex >= 0 ? currentQuestionIndex : 0,
                      originalQuestionId: completeQuestion['id'], // Set as original for boundary checking
                      originalQuestionIndex: currentQuestionIndex >= 0 ? currentQuestionIndex : 0, // Start boundary is this question
                    );
                    
                    // Use complete question data for navigation with FeedContext and fromUserScreen = true
                    final hasAnswered = userService.hasAnsweredQuestion(completeQuestion['id']);
                    
                    // Navigate and refresh cache when user returns
                    dynamic result;
                    if (hasAnswered) {
                      result = await questionService.navigateToResultsScreen(
                        context, 
                        completeQuestion, 
                        feedContext: feedContext, 
                        fromUserScreen: true
                      );
                    } else {
                      result = await questionService.navigateToAnswerScreen(
                        context, 
                        completeQuestion, 
                        feedContext: feedContext, 
                        fromUserScreen: true
                      );
                    }
                    
                    // Refresh subscribed questions cache when user returns from viewing a question
                    if (mounted && isSubscribedSection) {
                      print('Debug: User returned from viewing question, refreshing subscribed questions cache');
                      _refreshSubscribedQuestionsCache();
                    }
                  } else {
                    // Question not found in database (might be deleted)
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('Question not found. It may have been deleted.'),
                        backgroundColor: Colors.orange,
                      ),
                    );
                  }
                } catch (e) {
                  // Hide loading indicator if still showing
                  if (Navigator.of(context).canPop()) {
                    Navigator.of(context).pop();
                  }
                  
                  print('Error fetching question: $e');
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Error loading question. Please try again.'),
                      backgroundColor: Colors.red,
                    ),
                  );
                }
              },
            );

            // Wrap with Dismissible only for subscribed questions with comment delta indicators
            if (isSubscribedSection && (question['commentDelta'] as int? ?? 0) > 0) {
              return Dismissible(
                key: ValueKey('dismissible_question_${question['id']}'),
                direction: DismissDirection.endToStart, // Only allow swipe from right to left
                background: Container(), // Required when using secondaryBackground
                secondaryBackground: Container(
                  alignment: Alignment.centerRight,
                  padding: EdgeInsets.symmetric(horizontal: 20),
                  color: Theme.of(context).primaryColor.withOpacity(0.8),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Text(
                        'Mark as viewed',
                        style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                      ),
                      SizedBox(width: 8),
                      Icon(Icons.visibility, color: Colors.white),
                    ],
                  ),
                ),
                confirmDismiss: (direction) async {
                  // Clear the delta indicators
                  final votes = question['votes'] ?? 0;
                  final commentCount = _getCommentCount(question);
                  await _clearQuestionDeltaIndicators(
                    question['id'].toString(),
                    votes,
                    commentCount,
                  );
                  
                  // Refresh the UI to show cleared deltas
                  _refreshSubscribedQuestionsCache();
                  
                  // Show feedback
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Row(
                        children: [
                          Icon(Icons.visibility, color: Colors.white, size: 20),
                          SizedBox(width: 8),
                          Text('Marked as viewed'),
                        ],
                      ),
                      backgroundColor: Theme.of(context).primaryColor,
                      duration: Duration(seconds: 2),
                    ),
                  );
                  
                  // Return false to prevent actual dismissal (keep item in list)
                  return false;
                },
                child: listTile,
              );
            } else {
              return listTile;
            }
          },
        );
      },
    );
  }

  String _formatPopulation(int population) {
    if (population >= 1000000) {
      return '${(population / 1000000).toStringAsFixed(1)}M';
    } else if (population >= 1000) {
      return '${(population / 1000).toStringAsFixed(0)}K';
    } else {
      return population.toString();
    }
  }

  Widget _buildStatsSection(UserService userService) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(height: 8),
        
        // Engagement section (moved to top)
        Padding(
          padding: EdgeInsets.symmetric(horizontal: 4),
          child: Text(
            'Engagement',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w600,
              color: Theme.of(context).textTheme.titleLarge?.color,
            ),
          ),
        ),
        SizedBox(height: 8),
        
        // Row 1: Camo Counter and Quality
        Row(
          children: [
            Expanded(
              child: FutureBuilder<List<Map<String, dynamic>>>(
                future: userService.getFilteredPostedQuestions(Provider.of<QuestionService>(context, listen: false)),
                builder: (context, snapshot) {
                  final questions = snapshot.data ?? userService.postedQuestions;
                  return _buildCamoCounterTile(questions);
                },
              ),
            ),
            SizedBox(width: 8),
            Expanded(
              child: _buildCamoQualityTile(),
            ),
          ],
        ),
        
        SizedBox(height: 8),
        
        // Top Question Card (moved here, above streaks)
        FutureBuilder<List<Map<String, dynamic>>>(
          future: userService.getFilteredPostedQuestions(Provider.of<QuestionService>(context, listen: false)),
          builder: (context, snapshot) {
            final questions = snapshot.data ?? userService.postedQuestions;
            return _buildMostPopularQuestionCard(questions);
          },
        ),
        
        SizedBox(height: 8),
        
        // Row 2: Answer Streak and Post Streak
        Row(
          children: [
            Expanded(
              child: FutureBuilder<int>(
                future: _getLongestAnswerStreak(),
                builder: (context, snapshot) {
                  final longestStreak = snapshot.data ?? 0;
                  return _buildStreakTile(
                    title: 'Answer Streak',
                    streak: _calculateCurrentStreak(userService.answeredQuestions),
                    icon: Icons.local_fire_department,
                    onTap: () => _showAnswerStreakDialog(userService),
                    subtitle: 'All-time: $longestStreak',
                  );
                },
              ),
            ),
            SizedBox(width: 8),
            Expanded(
              child: FutureBuilder<int>(
                future: _getLongestPostStreak(),
                builder: (context, snapshot) {
                  final longestStreak = snapshot.data ?? 0;
                  return _buildStreakTile(
                    title: 'Post Streak',
                    streak: _calculateCurrentStreak(userService.postedQuestions),
                    icon: Icons.create,
                    onTap: () => _showPostStreakDialog(userService),
                    subtitle: 'All-time: $longestStreak',
                  );
                },
              ),
            ),
          ],
        ),
        
        SizedBox(height: 16),

        // My Questions - Expandable section containing all question lists
        Card(
          margin: EdgeInsets.only(bottom: 16),
          color: ThemeUtils.getDropdownBackgroundColor(context),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12.0),
          ),
          child: ExpansionTile(
            leading: Icon(Icons.folder_outlined),
            title: Text(
              'My Questions',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            onExpansionChanged: (isExpanded) {
              if (isExpanded) {
                // Initialize progressive comment loading when My Stuff section is expanded
                final allQuestions = <Map<String, dynamic>>[];
                allQuestions.addAll(userService.postedQuestions);
                allQuestions.addAll(userService.answeredQuestions);
                _initializeCommentLoadingQueue(allQuestions);
              }
            },
            children: [
              // Question lists inside the expandable section
              Consumer<WatchlistService>(
                builder: (context, watchlistService, child) {
                  return FutureBuilder<List<Map<String, dynamic>>>(
                    future: _getCachedSubscribedQuestions(),
                    builder: (context, snapshot) {
                      final questions = snapshot.data ?? [];
                      return _buildQuestionSection(
                        'Subscribed Questions',
                        questions,
                        Icons.notifications_active,
                        isSubscribedSection: true,
                      );
                    },
                  );
                },
              ),
              // Private-links section - shows private questions the user has answered
              FutureBuilder<List<Map<String, dynamic>>>(
                future: _getAnsweredPrivateQuestions(),
                builder: (context, snapshot) {
                  final questions = snapshot.data ?? [];
                  return _buildQuestionSection(
                    'Private-links',
                    questions,
                    Icons.lock,
                  );
                },
              ),
              FutureBuilder<List<Map<String, dynamic>>>(
                future: userService.getFilteredPostedQuestions(Provider.of<QuestionService>(context, listen: false)),
                builder: (context, snapshot) {
                  final questions = snapshot.data ?? userService.postedQuestions;
                  return _buildQuestionSection(
                    'Posted Questions',
                    questions,
                    Icons.create,
                  );
                },
              ),
              FutureBuilder<List<Map<String, dynamic>>>(
                future: userService.getFilteredCommentedQuestions(Provider.of<QuestionService>(context, listen: false)),
                builder: (context, snapshot) {
                  final questions = snapshot.data ?? [];
                  return _buildQuestionSection(
                    'Commented Questions',
                    questions,
                    Icons.comment,
                  );
                },
              ),
              FutureBuilder<List<Map<String, dynamic>>>(
                future: userService.getFilteredAnsweredQuestions(Provider.of<QuestionService>(context, listen: false)),
                builder: (context, snapshot) {
                  final questions = snapshot.data ?? userService.answeredQuestions;
                  return _buildQuestionSection(
                    'Answered Questions',
                    questions,
                    Icons.task_alt,
                  );
                },
              ),
              FutureBuilder<List<Map<String, dynamic>>>(
                future: userService.getFilteredDismissedQuestions(Provider.of<QuestionService>(context, listen: false)),
                builder: (context, snapshot) {
                  final questions = snapshot.data ?? [];
                  return _buildQuestionSection(
                    'Dismissed Questions',
                    questions,
                    Icons.visibility_off,
                  );
                },
              ),
            ],
          ),
        ),

        SizedBox(height: 16),

        // Achievements section ("Camo Collection"). Grid and counter render
        // the same catalog, see utils/badge_logic.dart.
        ..._buildBadgeCollection(userService),

        SizedBox(height: 80),
      ],
    );
  }

  Widget _buildStreakCard({
    required String title,
    required int streak,
    required IconData icon,
    required VoidCallback onTap,
    required String subtitle,
  }) {
    return Container(
      margin: EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: ThemeUtils.getDropdownBackgroundColor(context),
        borderRadius: BorderRadius.circular(12.0),
        boxShadow: ThemeUtils.getDropdownShadow(context),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: streak > 0 
                      ? Theme.of(context).primaryColor.withOpacity(0.1)
                      : Colors.grey.withOpacity(0.1),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  icon,
                  color: streak > 0 
                      ? Theme.of(context).primaryColor
                      : Colors.grey,
                  size: 24,
                ),
              ),
              SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Colors.grey[600],
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: streak > 0 
                      ? Theme.of(context).primaryColor
                      : Colors.grey.withOpacity(0.3),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  '$streak',
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    color: streak > 0 ? Colors.white : Colors.grey[600],
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCamoCounterTile(List<Map<String, dynamic>> questions) {
    final userService = Provider.of<UserService>(context, listen: false);
    
    return FutureBuilder<Map<String, dynamic>>(
      future: userService.getUserEngagementRanking(forceRefresh: true),
      builder: (context, snapshot) {
        final int totalEngagement;
        if (snapshot.hasData && snapshot.data != null) {
          totalEngagement = snapshot.data!['userEngagement'] as int? ?? 0;
        } else {
          totalEngagement = _calculateTotalEngagement(questions);
        }
        
        return Container(
          decoration: BoxDecoration(
            color: ThemeUtils.getDropdownBackgroundColor(context),
            borderRadius: BorderRadius.circular(12.0),
            boxShadow: ThemeUtils.getDropdownShadow(context),
          ),
          child: InkWell(
            onTap: () => _showTotalEngagementDialog(questions),
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Icon(
                        Icons.favorite,
                        color: totalEngagement > 0 
                            ? Theme.of(context).primaryColor
                            : Colors.grey,
                        size: 20,
                      ),
                      Text(
                        _formatCount(totalEngagement),
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          color: totalEngagement > 0 
                              ? Theme.of(context).primaryColor
                              : Colors.grey[600],
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: 8),
                  Text(
                    'Camo Counter',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  SizedBox(height: 2),
                  Text(
                    () {
                      if (snapshot.hasData && snapshot.data != null) {
                        final rank = snapshot.data!['rank'] as int? ?? 0;
                        final totalChameleons = snapshot.data!['totalChameleons'] as int? ?? 0;
                        if (totalEngagement > 0 && rank > 0) {
                          return rank <= 100 
                              ? 'Ranked #$rank (all-time)'
                              : '${_getPercentileText(rank, totalChameleons)}';
                        }
                      }
                      return 'Tap for details';
                    }(),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Colors.grey[600],
                      fontSize: 11,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildCamoQualityTile() {
    final userService = Provider.of<UserService>(context, listen: false);
    
    return FutureBuilder<Map<String, dynamic>>(
      future: userService.getUserEngagementRankingWithCamoQuality(forceRefresh: true),
      builder: (context, snapshot) {
        final camoQuality = snapshot.data?['camoQuality'] as double? ?? 0.0;
        final cqiRank = snapshot.data?['cqiRank'] as int? ?? 0;
        final hasCamoQuality = snapshot.data?['hasCqi'] as bool? ?? false;
        
        return Container(
          decoration: BoxDecoration(
            color: ThemeUtils.getDropdownBackgroundColor(context),
            borderRadius: BorderRadius.circular(12.0),
            boxShadow: ThemeUtils.getDropdownShadow(context),
          ),
          child: InkWell(
            onTap: () => _showCamoQualityDialog(camoQuality, cqiRank),
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Icon(
                        Icons.insights,
                        color: hasCamoQuality 
                            ? Theme.of(context).primaryColor
                            : Colors.grey,
                        size: 20,
                      ),
                      Text(
                        hasCamoQuality ? camoQuality.toStringAsFixed(1) : '--',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          color: hasCamoQuality
                              ? Theme.of(context).primaryColor
                              : Colors.grey[600],
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: 8),
                  Text(
                    'Camo Quality',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  SizedBox(height: 2),
                  Text(
                    (hasCamoQuality && cqiRank > 0)
                        ? (cqiRank <= 100
                            ? 'Ranked #$cqiRank'
                            : '${_getPercentileText(cqiRank, snapshot.data?['totalChameleons'] as int? ?? 0)}')
                        : 'Tap for details',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Colors.grey[600],
                      fontSize: 11,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildStreakTile({
    required String title,
    required int streak,
    required IconData icon,
    required VoidCallback onTap,
    required String subtitle,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: ThemeUtils.getDropdownBackgroundColor(context),
        borderRadius: BorderRadius.circular(12.0),
        boxShadow: ThemeUtils.getDropdownShadow(context),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Icon(
                    icon,
                    color: streak > 0 
                        ? Theme.of(context).primaryColor
                        : Colors.grey,
                    size: 20,
                  ),
                  Text(
                    '$streak',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      color: streak > 0 
                          ? Theme.of(context).primaryColor
                          : Colors.grey[600],
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              SizedBox(height: 8),
              Text(
                title,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              SizedBox(height: 2),
              Text(
                subtitle,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Colors.grey[600],
                  fontSize: 11,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTotalEngagementCard(List<Map<String, dynamic>> questions) {
    final userService = Provider.of<UserService>(context, listen: false);
    
    return FutureBuilder<Map<String, dynamic>>(
      future: userService.getUserEngagementRanking(forceRefresh: true), // Always fetch fresh data
      builder: (context, snapshot) {
        // Get engagement score from DB or calculate from questions as fallback
        final int totalEngagement;
        if (snapshot.hasData && snapshot.data != null) {
          totalEngagement = snapshot.data!['userEngagement'] as int? ?? 0;
        } else {
          // Fallback to calculating from questions only while loading
          totalEngagement = _calculateTotalEngagement(questions);
        }
        
        return Container(
          margin: EdgeInsets.only(bottom: 8),
          decoration: BoxDecoration(
            color: ThemeUtils.getDropdownBackgroundColor(context),
            borderRadius: BorderRadius.circular(12.0),
            boxShadow: ThemeUtils.getDropdownShadow(context),
          ),
          child: InkWell(
            onTap: () => _showTotalEngagementDialog(questions),
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Row(
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: totalEngagement > 0 
                          ? Theme.of(context).primaryColor.withOpacity(0.1)
                          : Colors.grey.withOpacity(0.1),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.favorite,
                      color: totalEngagement > 0 
                          ? Theme.of(context).primaryColor
                          : Colors.grey,
                      size: 24,
                    ),
                  ),
                  SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Camo Counter',
                          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        SizedBox(height: 4),
                        FutureBuilder<Map<String, dynamic>>(
                          future: userService.getUserEngagementRanking(forceRefresh: true),
                          builder: (context, snapshot) {
                            if (snapshot.hasData && snapshot.data != null) {
                              final rank = snapshot.data!['recent_30d_rank'] as int? ?? 0;
                              final totalChameleons = snapshot.data!['totalChameleons'] as int? ?? 0;
                              final userEngagement = snapshot.data!['userEngagement'] as int? ?? 0;
                              
                              if (userEngagement > 0 && rank > 0) {
                                return Text(
                                  rank <= 100 
                                      ? 'You are ranked #$rank !'
                                      : 'You are in the ${_getPercentileText(rank, totalChameleons)} :D',
                                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: Colors.grey[600],
                                  ),
                                );
                              }
                            }
                            return Text(
                              'Tap for details',
                              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: Colors.grey[600],
                              ),
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    decoration: BoxDecoration(
                      color: totalEngagement > 0 
                          ? Theme.of(context).primaryColor
                          : Colors.grey.withOpacity(0.3),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (snapshot.connectionState == ConnectionState.waiting) ...[
                          SizedBox(
                            width: 12,
                            height: 12,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation<Color>(
                                totalEngagement > 0 ? Colors.white : Colors.grey[600]!,
                              ),
                            ),
                          ),
                          SizedBox(width: 6),
                        ],
                        Text(
                          _formatCount(totalEngagement),
                          style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                            color: totalEngagement > 0 ? Colors.white : Colors.grey[600],
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildMostPopularQuestionCard(List<Map<String, dynamic>> questions) {
    final hasQuestions = questions.isNotEmpty;
    final mostPopularQuestionData = _findMostPopularQuestionData(questions);
    final responseCount = mostPopularQuestionData['votes'] as int? ?? 0;
    final hasSignificantEngagement = responseCount > 3;
    
    return Container(
      margin: EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: ThemeUtils.getDropdownBackgroundColor(context),
        borderRadius: BorderRadius.circular(12.0),
        boxShadow: ThemeUtils.getDropdownShadow(context),
      ),
      child: InkWell(
        onTap: () async {
          // Show the top questions dialog and handle navigation result
          final result = await _showTopQuestionsDialog(questions);
          if (result != null && result is Map<String, dynamic> && result['action'] == 'navigate') {
            _handleQuestionNavigation(result['questionId']);
          }
        },
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Row(
            children: [
              Icon(
                Icons.star,
                color: hasSignificantEngagement 
                    ? Theme.of(context).primaryColor
                    : Colors.grey,
                size: 24,
              ),
              SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Top Questions',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    SizedBox(height: 4),
                    Text(
                      hasQuestions 
                          ? (mostPopularQuestionData['question'] != null 
                              ? (mostPopularQuestionData['question']['prompt']?.toString() ?? mostPopularQuestionData['question']['title']?.toString() ?? 'No title')
                              : 'Nothing has really stuck yet...')
                          : 'Nothing has really stuck yet...',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Colors.grey[600],
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              if (hasQuestions && mostPopularQuestionData['question'] != null)
                Text(
                  _formatCount(responseCount),
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    color: hasSignificantEngagement 
                        ? Theme.of(context).primaryColor
                        : Colors.grey[600],
                    fontWeight: FontWeight.bold,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCamoQualityCard() {
    final userService = Provider.of<UserService>(context, listen: false);
    
    return FutureBuilder<Map<String, dynamic>>(
      future: userService.getUserEngagementRankingWithCamoQuality(forceRefresh: true),
      builder: (context, snapshot) {
        final camoQuality = snapshot.data?['camoQuality'] as double? ?? 0.0;
        final cqiRank = snapshot.data?['cqiRank'] as int? ?? 0;
        final hasCamoQuality = snapshot.data?['hasCqi'] as bool? ?? false;
        
        return Container(
          margin: EdgeInsets.only(bottom: 8),
          decoration: BoxDecoration(
            color: ThemeUtils.getDropdownBackgroundColor(context),
            borderRadius: BorderRadius.circular(12.0),
            boxShadow: ThemeUtils.getDropdownShadow(context),
          ),
          child: InkWell(
            onTap: () => _showCamoQualityDialog(camoQuality, cqiRank),
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Row(
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: hasCamoQuality 
                          ? Theme.of(context).primaryColor.withOpacity(0.1)
                          : Colors.grey.withOpacity(0.1),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.insights,
                      color: hasCamoQuality 
                          ? Theme.of(context).primaryColor
                          : Colors.grey,
                      size: 24,
                    ),
                  ),
                  SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Camo Quality',
                          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        SizedBox(height: 4),
                        if (hasCamoQuality && cqiRank > 0)
                          Text(
                            cqiRank <= 100
                                ? 'You are ranked #$cqiRank !'
                                : 'You are in the ${_getPercentileText(cqiRank, snapshot.data?['totalChameleons'] as int? ?? 0)} :D',
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: Colors.grey[600],
                            ),
                          )
                        else
                          Text(
                            'Tap for details',
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: Colors.grey[600],
                            ),
                          ),
                      ],
                    ),
                  ),
                  Container(
                    padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    decoration: BoxDecoration(
                      color: hasCamoQuality 
                          ? Theme.of(context).primaryColor
                          : Colors.grey.withOpacity(0.3),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (snapshot.connectionState == ConnectionState.waiting) ...[
                          SizedBox(
                            width: 12,
                            height: 12,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation<Color>(
                                hasCamoQuality ? Colors.white : Colors.grey[600]!,
                              ),
                            ),
                          ),
                          SizedBox(width: 6),
                        ],
                        Text(
                          hasCamoQuality ? camoQuality.toStringAsFixed(1) : '--',
                          style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                            color: hasCamoQuality ? Colors.white : Colors.grey[600],
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  List<Widget> _buildBadgeCollection(UserService userService) {
    _maybeReloadBadges(userService);
    final friendCount = Provider.of<FriendService>(context).friendCount;
    final sections = buildBadgeSections(_badgeStats(userService, friendCount));
    final collected = countCollectedBadges(sections);
    final loading = _badgeData == null;

    return [
      Padding(
        padding: EdgeInsets.symmetric(horizontal: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(height: 8),
            Text(
              'Camo Collection',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w600,
                color: Theme.of(context).textTheme.titleLarge?.color,
              ),
            ),
            SizedBox(height: 2),
            Text(
              loading
                  ? 'Counting badges...'
                  : (collected == 1 ? '1 badge collected' : '$collected badges collected'),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).textTheme.bodySmall?.color?.withOpacity(0.7),
              ),
            ),
          ],
        ),
      ),
      SizedBox(height: 8),
      if (loading)
        Container(
          padding: EdgeInsets.all(16),
          child: Center(child: CircularProgressIndicator()),
        )
      else
        for (final section in sections) ...[
          _buildAchievementSubsection(
            section.title,
            section.badges.map(_buildBadgeChip).toList(),
          ),
          SizedBox(height: 12),
        ],
    ];
  }

  Widget _buildAchievementSubsection(String title, List<Widget> chips) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Text(
            title,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
              color: Theme.of(context).textTheme.bodyMedium?.color?.withOpacity(0.8),
              fontSize: 13,
            ),
          ),
        ),
        SizedBox(height: 4),
        GridView.count(
          shrinkWrap: true,
          physics: NeverScrollableScrollPhysics(),
          crossAxisCount: 4,
          childAspectRatio: 1.3,
          mainAxisSpacing: 6,
          crossAxisSpacing: 6,
          children: chips,
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Camo Collection (badges)
  //
  // Every unlock rule lives in utils/badge_logic.dart. This screen only gathers
  // the numbers: local state is read live in build(), and everything that needs
  // Supabase is fetched here into [_badgeData] (cached for an hour, forced on
  // pull-to-refresh). The grid and the "N badges collected" line both render
  // the same buildBadgeSections() output, so they always agree.

  // Every badge cache and high-water mark is keyed by user id, so switching
  // accounts on one device never carries badges across.
  static const Duration _badgeServerCacheTtl = Duration(hours: 1);
  static String _badgeKey(String userId, String name) => 'badge_${userId}_$name';

  static const List<String> _stickyBadgeFlags = [
    BadgeFlags.alphaTester,
    BadgeFlags.betaTester,
    BadgeFlags.birthdayBuddy,
    BadgeFlags.qotdStar,
    BadgeFlags.firstLizzy,
    BadgeFlags.dragonLizzy,
    BadgeFlags.dinoLizzy,
    BadgeFlags.popcornTime,
    BadgeFlags.plantingSeed,
    BadgeFlags.communityBuilding,
    BadgeFlags.localLegend,
    BadgeFlags.globalSeed,
    BadgeFlags.globalCommunity,
  ];

  /// Reloads badge data when the inputs it was built from have changed
  /// (a new post or answer). Cheap: the server half is served from cache.
  void _maybeReloadBadges(UserService userService) {
    final key = _badgeInputsKey(userService);
    if (key == _badgeLoadedForKey || _badgeLoading) return;
    _badgeLoadedForKey = key;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _loadBadgeData();
    });
  }

  String _badgeInputsKey(UserService userService) =>
      '${Supabase.instance.client.auth.currentUser?.id}|'
      '${userService.postedQuestions.length}|'
      '${userService.answeredQuestions.length}';

  Future<void> _loadBadgeData({bool forceRefresh = false}) async {
    if (_badgeLoading) {
      // A pull-to-refresh during a load must not be dropped.
      if (forceRefresh) _badgeForcedReloadQueued = true;
      return;
    }
    _badgeLoading = true;
    try {
      final userService = Provider.of<UserService>(context, listen: false);
      final questionService = Provider.of<QuestionService>(context, listen: false);
      final prefs = await SharedPreferences.getInstance();
      final userId = Supabase.instance.client.auth.currentUser?.id;
      final signedIn = userId != null;
      _badgeLoadedForKey = _badgeInputsKey(userService);

      // Same filtered count as the "Answered" list, recomputed on every load
      // (the old grid cached it for a whole day while the counter did not).
      int answered;
      try {
        answered = (await userService.getFilteredAnsweredQuestions(questionService)).length;
      } catch (e) {
        answered = userService.answeredQuestions.length;
      }

      DateTime? createdAt;
      int qotdCount = 0;
      Map<String, int> server = const {};
      if (signedIn) {
        final results = await Future.wait<dynamic>([
          _getUserCreationDate(forceRefresh: forceRefresh),
          _getQotdData(forceRefresh: forceRefresh),
          _fetchBadgeServerStats(prefs, userService, forceRefresh: forceRefresh),
        ]);
        createdAt = (results[0] as Map<String, dynamic>)['created_at'] as DateTime?;
        qotdCount = ((results[1] as Map<String, dynamic>)['count'] as int?) ?? 0;
        server = results[2] as Map<String, int>;
      }

      // High-water marks: deleting a comment, removing a reaction or
      // unfriending someone never takes a badge back.
      int hwm(String name, int? value) {
        if (userId == null) return value ?? 0;
        final key = _badgeKey(userId, 'hwm_$name');
        final previous = prefs.getInt(key) ?? 0;
        if (value != null && value > previous) {
          prefs.setInt(key, value);
          return value;
        }
        return previous;
      }

      final flags = <String>{
        for (final flag in _stickyBadgeFlags)
          if (prefs.getBool('achievement_$flag') ?? false) flag,
      };

      // Persist the tester flags so they survive an offline load.
      if (createdAt != null) {
        if (createdAt.isBefore(kAlphaTesterCutoff) && flags.add(BadgeFlags.alphaTester)) {
          prefs.setBool('achievement_${BadgeFlags.alphaTester}', true);
        }
        if (createdAt.isBefore(kBetaTesterCutoff) && flags.add(BadgeFlags.betaTester)) {
          prefs.setBool('achievement_${BadgeFlags.betaTester}', true);
        }
      }
      if (_checkBirthdayBuddy(userService) && flags.add(BadgeFlags.birthdayBuddy)) {
        prefs.setBool('achievement_${BadgeFlags.birthdayBuddy}', true);
      }
      final firstQotd = qotdCount > 0 && !flags.contains(BadgeFlags.qotdStar);
      if (firstQotd) {
        flags.add(BadgeFlags.qotdStar);
        await prefs.setBool('achievement_${BadgeFlags.qotdStar}', true);
      }

      final data = _BadgeData(
        answeredCount: answered,
        qotdCount: qotdCount,
        accountCreatedAt: createdAt,
        commentCount: hwm('comments', server['comment_count']),
        maxLizzies: hwm('max_lizzies', server['max_lizzies']),
        popcornCount: hwm('popcorn', server['popcorn']),
        reactionsGiven: hwm('reactions_given', server['reactions_given']),
        reactionsReceived: hwm('reactions_received', server['reactions_received']),
        legacyCityQuestions: server['legacy_city_questions'] ?? 0,
        legacyCountryQuestions: server['legacy_country_questions'] ?? 0,
        legacyUniqueCities: server['legacy_unique_cities'] ?? 0,
        userId: userId,
        friendHwm: userId == null ? 0 : (prefs.getInt(_badgeKey(userId, 'hwm_friends')) ?? 0),
        flags: flags,
      );

      if (!mounted) return;
      setState(() => _badgeData = data);
      if (firstQotd) _showQotdCongratulations();
    } catch (e) {
      print('Error loading badges: $e');
    } finally {
      _badgeLoading = false;
      if (_badgeForcedReloadQueued && mounted) {
        _badgeForcedReloadQueued = false;
        _loadBadgeData(forceRefresh: true);
      }
    }
  }

  /// Everything that needs a query. Each stat is fetched on its own so one
  /// failing query (an RLS change, a missing table) only blanks that stat.
  Future<Map<String, int>> _fetchBadgeServerStats(
    SharedPreferences prefs,
    UserService userService, {
    bool forceRefresh = false,
  }) async {
    final client = Supabase.instance.client;
    final userId = client.auth.currentUser?.id;
    if (userId == null) return {};
    final cacheKey = _badgeKey(userId, 'server_stats_v1');
    final cacheTimeKey = _badgeKey(userId, 'server_stats_v1_time');
    final popcornIdsKey = _badgeKey(userId, 'popcorn_question_ids');

    if (!forceRefresh) {
      final cached = prefs.getString(cacheKey);
      final cachedAt = DateTime.tryParse(prefs.getString(cacheTimeKey) ?? '');
      if (cached != null &&
          cachedAt != null &&
          DateTime.now().difference(cachedAt) < _badgeServerCacheTtl) {
        try {
          return (jsonDecode(cached) as Map).map(
              (k, v) => MapEntry(k.toString(), (v as num).toInt()));
        } catch (_) {
          // Corrupt cache: fall through to a fresh fetch.
        }
      }
    }

    final postedIds = userService.postedQuestions
        .map((q) => q['id']?.toString() ?? '')
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList();
    final stats = <String, int>{};

    Future<void> guard(String name, Future<void> Function() body) async {
      try {
        await body();
      } catch (e) {
        print('Badge stat "$name" failed: $e');
      }
    }

    List<List<String>> chunks(List<String> ids, int size) => [
          for (var i = 0; i < ids.length; i += size)
            ids.sublist(i, i + size > ids.length ? ids.length : i + size),
        ];

    await Future.wait([
      // Comments the user posted. RLS hides shadow-banned comments.
      guard('comment_count', () async {
        stats['comment_count'] =
            await client.from('comments').count().eq('author_id', userId);
      }),
      // Best single comment, by 🦎 lizzies.
      guard('max_lizzies', () async {
        final rows = await client
            .from('comments')
            .select('upvote_lizard_count')
            .eq('author_id', userId)
            .order('upvote_lizard_count', ascending: false)
            .limit(1);
        stats['max_lizzies'] = rows.isEmpty
            ? 0
            : ((rows.first['upvote_lizard_count'] as num?)?.toInt() ?? 0);
      }),
      // Emoji reactions the user left on questions.
      guard('reactions_given', () async {
        stats['reactions_given'] =
            await client.from('question_reactions').count().eq('user_id', userId);
      }),
      // Emoji reactions other people left on the user's questions.
      guard('reactions_received', () async {
        var total = 0;
        for (final chunk in chunks(postedIds, 100)) {
          total += await client
              .from('question_reactions')
              .count()
              .inFilter('question_id', chunk)
              .neq('user_id', userId);
        }
        stats['reactions_received'] = total;
      }),
      // Questions with 5+ comments. A question that qualified once is
      // remembered, so only the rest are re-counted on later loads.
      guard('popcorn', () async {
        final known = (prefs.getStringList(popcornIdsKey) ?? const <String>[]).toSet();
        final toCheck = postedIds.where((id) => !known.contains(id)).toList();
        for (final batch in chunks(toCheck, 10)) {
          await Future.wait(batch.map((id) async {
            final n = await client.from('comments').count().eq('question_id', id);
            if (n >= 5) known.add(id);
          }));
        }
        await prefs.setStringList(popcornIdsKey, known.toList());
        stats['popcorn'] = known.length;
      }),
      // Retired city/country badges: only questions from before retirement.
      guard('legacy_local', () async {
        final rows = await client
            .from('questions')
            .select('city_id, country_code, targeting_type')
            .eq('author_id', userId)
            .lt('created_at', kLocalBadgesRetiredAt.toIso8601String());
        var city = 0;
        var country = 0;
        final cities = <String>{};
        for (final row in rows) {
          if (row['targeting_type'] == 'city' && row['city_id'] != null) {
            city++;
            cities.add(row['city_id'].toString());
          } else if (row['targeting_type'] == 'country' && row['country_code'] != null) {
            country++;
          }
        }
        stats['legacy_city_questions'] = city;
        stats['legacy_country_questions'] = country;
        stats['legacy_unique_cities'] = cities.length;
      }),
    ]);

    await prefs.setString(cacheKey, jsonEncode(stats));
    await prefs.setString(cacheTimeKey, DateTime.now().toIso8601String());
    return stats;
  }

  Future<void> _showQotdCongratulations() async {
    try {
      final userService = Provider.of<UserService>(context, listen: false);
      final achievementService = AchievementService(userService: userService, context: context);
      await achievementService.init();
      final congratulationsService = CongratulationsService(
        userService: userService,
        achievementService: achievementService,
      );
      await congratulationsService.init();
      if (!mounted) return;
      await congratulationsService.showCongratulationsIfEligible(
        context,
        AchievementType.qotdBadge,
      );
    } catch (e) {
      print('Error showing congratulations for QOTD achievement: $e');
    }
  }

  /// The stats snapshot the catalog is built from: live local state merged
  /// with the last server load.
  BadgeStats _badgeStats(UserService userService, int liveFriendCount) {
    var popular = 0;
    var viral = 0;
    for (final question in userService.postedQuestions) {
      final votes = (question['votes'] as num?)?.toInt() ?? 0;
      if (votes >= 500) {
        viral++;
      } else if (votes >= 100) {
        popular++;
      }
    }

    // Friend count is live; remember the best seen so unfriending is harmless.
    // Ignore a snapshot loaded for a different account.
    final currentUserId = Supabase.instance.client.auth.currentUser?.id;
    final data = (_badgeData?.userId == currentUserId) ? _badgeData : null;
    var friends = liveFriendCount;
    if (data != null && currentUserId != null) {
      if (liveFriendCount > data.friendHwm) {
        data.friendHwm = liveFriendCount;
        SharedPreferences.getInstance().then((prefs) =>
            prefs.setInt(_badgeKey(currentUserId, 'hwm_friends'), liveFriendCount));
      }
      friends = data.friendHwm;
    }

    return BadgeStats(
      isSignedIn: Supabase.instance.client.auth.currentUser != null,
      postedCount: userService.postedQuestions.length,
      answeredCount: data?.answeredCount ?? userService.answeredQuestions.length,
      popularQuestionCount: popular,
      viralQuestionCount: viral,
      qotdCount: data?.qotdCount ?? 0,
      accountCreatedAt: data?.accountCreatedAt,
      postedInNovember: _checkBirthdayBuddy(userService),
      qotdNotificationsOn: userService.notifyQOTD,
      friendCount: friends,
      commentCount: data?.commentCount ?? 0,
      maxLizziesOnOneComment: data?.maxLizzies ?? 0,
      popcornQuestionCount: data?.popcornCount ?? 0,
      reactionsGiven: data?.reactionsGiven ?? 0,
      reactionsReceived: data?.reactionsReceived ?? 0,
      legacyCityQuestions: data?.legacyCityQuestions ?? 0,
      legacyCountryQuestions: data?.legacyCountryQuestions ?? 0,
      legacyUniqueCities: data?.legacyUniqueCities ?? 0,
      earnedFlags: data?.flags ?? const <String>{},
    );
  }

  Widget _buildBadgeChip(BadgeView badge) {
    return _buildAchievementChip(
      badge.emoji,
      badge.title,
      badge.description,
      badge.unlocked,
      progress: badge.progress,
      count: (badge.stack ?? 0) > 1 ? badge.stack : null,
      customOnTap: badge.id == 'qotd_star' && badge.unlocked ? _showQotdHistoryDialog : null,
    );
  }

  /// Any question posted in November (RTR's birthday month).
  bool _checkBirthdayBuddy(UserService userService) {
    for (final question in userService.postedQuestions) {
      final createdAt = DateTime.tryParse(question['created_at']?.toString() ?? '');
      if (createdAt != null && createdAt.month == 11) return true;
    }
    return false;
  }


  // Helper method to get user creation date from database with daily caching
  Future<Map<String, dynamic>> _getUserCreationDate({bool forceRefresh = false}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final cacheKey = 'user_creation_date';
      final cacheTimeKey = 'user_creation_date_last_checked';
      
      // Check cache first (unless force refresh)
      if (!forceRefresh) {
        final cachedData = prefs.getString(cacheKey);
        final lastChecked = prefs.getString(cacheTimeKey);
        
        if (cachedData != null && lastChecked != null) {
          final lastCheckedDate = DateTime.parse(lastChecked);
          final now = DateTime.now();
          
          // Use cache if checked today (same day)
          if (lastCheckedDate.year == now.year && 
              lastCheckedDate.month == now.month && 
              lastCheckedDate.day == now.day) {
            print('Using cached user creation date');
            return {
              'created_at': DateTime.parse(cachedData),
            };
          }
        }
      }
      
      print('Fetching user creation date from database');
      final userId = Supabase.instance.client.auth.currentUser?.id;
      if (userId == null) return {};
      
      final response = await Supabase.instance.client
          .from('users')
          .select('created_at')
          .eq('id', userId)
          .single();
      
      if (response['created_at'] != null) {
        final createdAt = DateTime.parse(response['created_at']);
        
        // Cache the result
        await prefs.setString(cacheKey, response['created_at']);
        await prefs.setString(cacheTimeKey, DateTime.now().toIso8601String());
        
        return {
          'created_at': createdAt,
        };
      }
    } catch (e) {
      print('Error fetching user creation date: $e');
    }
    return {};
  }

  Future<Map<String, dynamic>> _getQotdData({bool forceRefresh = false}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final cacheKey = 'qotd_data_check';
      final cacheTimeKey = 'qotd_data_check_last_checked';
      
      // Check cache first (unless force refresh)
      if (!forceRefresh) {
        final cachedResultString = prefs.getString(cacheKey);
        final lastChecked = prefs.getString(cacheTimeKey);
        
        if (cachedResultString != null && lastChecked != null) {
          final lastCheckedDate = DateTime.parse(lastChecked);
          final now = DateTime.now();
          
          // Use cache if checked today (same day)
          if (lastCheckedDate.year == now.year && 
              lastCheckedDate.month == now.month && 
              lastCheckedDate.day == now.day) {
            final cachedResult = jsonDecode(cachedResultString);
            print('Using cached QOTD data: count=${cachedResult['count']}');
            return cachedResult;
          }
        }
      }
      
      // print('Checking database for user QOTD data');  // Commented out excessive logging
      final userId = Supabase.instance.client.auth.currentUser?.id;
      if (userId == null) return {'count': 0, 'qotds': []};
      
      // Query question_of_the_day_history table to get all of user's featured questions
      final qotdResponse = await Supabase.instance.client
          .from('question_of_the_day_history')
          .select('question_id, date, questions!inner(author_id, prompt, type)')
          .eq('questions.author_id', userId)
          .order('date', ascending: false);
      
      final qotdCount = qotdResponse.length;
      final qotdList = qotdResponse as List<dynamic>;
      
      final result = {
        'count': qotdCount,
        'qotds': qotdList,
      };
      
      // Cache the result with daily expiration
      await prefs.setString(cacheKey, jsonEncode(result));
      await prefs.setString(cacheTimeKey, DateTime.now().toIso8601String());
      
      print('QOTD data result: count=$qotdCount, qotds=${qotdList.length}');
      
      // Debug logging: Show details of each QOTD found
      for (int i = 0; i < qotdList.length; i++) {
        final qotd = qotdList[i];
        final question = qotd['questions'];
        final featuredDate = qotd['date'];
        final questionTitle = question?['prompt']?.toString() ?? 
                            question?['title']?.toString() ?? 
                            'No Title';
        print('QOTD #${i + 1}: \"$questionTitle\" featured on $featuredDate');
      }
      
      return result;
    } catch (e) {
      print('Error checking QOTD data: $e');
      return {'count': 0, 'qotds': []}; // Default to empty if there's an error
    }
  }

  Widget _buildAchievementChip(String emoji, String title, String description, bool isUnlocked, {String? progress, VoidCallback? customOnTap, int? count}) {
    return GestureDetector(
      onTap: customOnTap ?? (() => _showAchievementDialog(emoji, title, description, isUnlocked, progress: progress)),
      child: Container(
        decoration: isUnlocked 
            ? BoxDecoration(
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
              )
            : BoxDecoration(
                color: Colors.grey.withOpacity(0.1),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: Colors.grey.withOpacity(0.3),
                  width: 1,
                ),
              ),
        child: Container(
          margin: isUnlocked ? EdgeInsets.all(2) : EdgeInsets.zero,
          decoration: BoxDecoration(
            color: isUnlocked 
                ? Theme.of(context).primaryColor.withOpacity(0.1)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(isUnlocked ? 10 : 12),
          ),
          child: count != null && count > 0
              ? Stack(
                  children: [
                    Center(
                      child: Text(
                        emoji,
                        style: TextStyle(
                          fontSize: 24,
                          color: isUnlocked ? Colors.white : Colors.grey,
                        ),
                      ),
                    ),
                    Positioned(
                      top: 4,
                      right: 4,
                      child: Container(
                        padding: EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                        decoration: BoxDecoration(
                          color: Colors.red.withOpacity(0.8),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          'x$count',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                  ],
                )
              : Center(
                  child: Text(
                    emoji,
                    style: TextStyle(
                      fontSize: 24,
                      color: isUnlocked ? Colors.white : Colors.grey,
                    ),
                  ),
                ),
        ),
      ),
    );
  }

  void _showAchievementDialog(String emoji, String title, String description, bool isUnlocked, {String? progress}) {
    final dialogBorder = _getAchievementDialogBorderDecoration(isUnlocked);
    
    showDialog(
      context: context,
      builder: (context) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: Container(
          decoration: dialogBorder,
          padding: isUnlocked ? EdgeInsets.all(3) : EdgeInsets.zero, // 3px padding for rainbow gradient border
          child: Container(
            decoration: BoxDecoration(
              color: Theme.of(context).dialogBackgroundColor,
              borderRadius: BorderRadius.circular(isUnlocked ? 9 : 12),
            ),
            padding: EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: isUnlocked ? CrossAxisAlignment.center : CrossAxisAlignment.start,
              children: [
                // Title section
                Row(
                  mainAxisAlignment: isUnlocked ? MainAxisAlignment.center : MainAxisAlignment.start,
                  children: [
                    Text(
                      emoji,
                      style: TextStyle(
                        fontSize: 32,
                        color: isUnlocked ? null : Colors.grey,
                      ),
                    ),
                    SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: isUnlocked ? CrossAxisAlignment.center : CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                              color: isUnlocked ? null : Colors.grey[600],
                            ),
                            textAlign: isUnlocked ? TextAlign.center : TextAlign.start,
                          ),
                          if (isUnlocked)
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  Icons.check_circle,
                                  size: 16,
                                  color: Theme.of(context).primaryColor,
                                ),
                                SizedBox(width: 4),
                                Text(
                                  'Unlocked',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Theme.of(context).primaryColor,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ],
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
                
                SizedBox(height: 16),
                
                // Description
                Text(
                  description,
                  style: TextStyle(
                    color: isUnlocked ? null : Colors.grey[600],
                  ),
                  textAlign: isUnlocked ? TextAlign.center : TextAlign.start,
                ),
                
                // Progress section
                if (progress != null) ...[
                  SizedBox(height: 12),
                  Container(
                    padding: EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Theme.of(context).primaryColor.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: isUnlocked 
                      ? Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.celebration,
                              size: 20,
                              color: Theme.of(context).primaryColor,
                            ),
                            SizedBox(width: 8),
                            Text(
                              progress,
                              style: TextStyle(
                                fontWeight: FontWeight.w500,
                                color: Theme.of(context).primaryColor,
                              ),
                            ),
                          ],
                        )
                      : Row(
                          mainAxisAlignment: MainAxisAlignment.start,
                          children: [
                            Icon(
                              Icons.trending_up,
                              size: 20,
                              color: Theme.of(context).primaryColor,
                            ),
                            SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                progress,
                                style: TextStyle(
                                  fontWeight: FontWeight.w500,
                                  color: Theme.of(context).primaryColor,
                                ),
                                textAlign: TextAlign.start,
                              ),
                            ),
                          ],
                        ),
                  ),
                ],
                
                SizedBox(height: 20),
                
                // Close button - always centered
                Align(
                  alignment: Alignment.center,
                  child: TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(
                      'Close',
                      style: TextStyle(
                        color: Theme.of(context).primaryColor,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  int _calculateCurrentStreak(List<Map<String, dynamic>> questions) {
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

  int _calculateTotalEngagement(List<Map<String, dynamic>> postedQuestions) {
    int totalEngagement = 0;
    for (final question in postedQuestions) {
      final votes = question['votes'] as int? ?? 0;
      totalEngagement += votes;
    }
    return totalEngagement;
  }

  Future<void> _showAnswerStreakDialog(UserService userService) async {
    // The same dialog the top bar's streak pill opens (answer_streak_dialog.dart).
    final currentStreak = _calculateCurrentStreak(userService.answeredQuestions);
    final hasExtendedStreakToday =
        _hasExtendedStreakToday(userService.answeredQuestions);
    final streakColor = _getStreakCardColor(context, hasExtendedStreakToday);
    await showAnswerStreakDialog(
      context,
      currentStreak: currentStreak,
      streakRank: userService.streakRank,
      streakColor: streakColor,
      shouldShowUrgent: _shouldStreakCardPulse(hasExtendedStreakToday) ||
          streakColor == const Color(0xffea6d32),
    );
  }


  Future<void> _showPostStreakDialog(UserService userService) async {
    final currentStreak = _calculateCurrentStreak(userService.postedQuestions);
    final longestStreak = await _getLongestPostStreak();

    // Update longest streak if current is longer
    if (currentStreak > longestStreak) {
      await _saveLongestPostStreak(currentStreak);
    }

    final isRecord = currentStreak > 0 && currentStreak >= longestStreak;

    showDialog(
      context: context,
      builder: (context) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: Container(
          padding: EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Title section
              Text(
                'Post Streak',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
              ),
              SizedBox(height: 12),
              // Streak number
              Text(
                '$currentStreak',
                style: Theme.of(context).textTheme.displayLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: Theme.of(context).primaryColor,
                ),
                textAlign: TextAlign.center,
              ),
              SizedBox(height: 12),
              // Longest streak info
              Text(
                isRecord && currentStreak > 0
                    ? 'This is your longest streak ever, keep it up!'
                    : 'Your all-time longest streak was $longestStreak day${longestStreak == 1 ? '' : 's'}.',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: isRecord ? Theme.of(context).primaryColor : null,
                  fontWeight: isRecord ? FontWeight.w600 : null,
                ),
                textAlign: TextAlign.center,
              ),
              SizedBox(height: 16),
              // Explanation text at bottom
              Text(
                'A streak is the number of consecutive days that you\'ve posted at least one question.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Colors.grey[600],
                ),
                textAlign: TextAlign.center,
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
    );
  }

  void _showCamoQualityDialog(double camoQuality, int cqiRank) async {
    if (!mounted) return;
    
    final userService = Provider.of<UserService>(context, listen: false);
    
    // Get fresh data including total users count
    final rankingData = await userService.getUserEngagementRanking(forceRefresh: true);
    
    if (!mounted) return;
    
    final totalUsers = rankingData['totalUsers'] as int? ?? 0;
    final totalChameleons = rankingData['totalChameleons'] as int? ?? 0;
    final questionsPosted = rankingData['questionsPosted'] as int? ?? 0;
    final hasCqi = rankingData['hasCqi'] as bool? ?? false;
    
    final dialogBorder = _getDialogBorderDecoration(cqiRank);
    
    showDialog(
      context: context,
      builder: (context) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: Container(
          decoration: dialogBorder,
          padding: (cqiRank >= 1 && cqiRank <= 10) ? EdgeInsets.all(3) : EdgeInsets.zero,
          child: Container(
            decoration: BoxDecoration(
              color: Theme.of(context).dialogBackgroundColor,
              borderRadius: BorderRadius.circular((cqiRank >= 1 && cqiRank <= 10) ? 9 : 12),
            ),
            padding: EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Title
                Text(
                  'Camo Quality Index',
                  style: Theme.of(context).textTheme.titleLarge,
                  textAlign: TextAlign.center,
                ),
                SizedBox(height: 12),
                // Centered number
                Text(
                  hasCqi ? camoQuality.toStringAsFixed(1) : '--',
                  style: Theme.of(context).textTheme.displayLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: hasCqi ? Theme.of(context).primaryColor : Colors.grey,
                  ),
                  textAlign: TextAlign.center,
                ),
                SizedBox(height: 20),
                // Content
                Text(
                  'This is the average number of answers your questions get.',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                SizedBox(height: 16),
                if (questionsPosted < 3) ...[
                  Container(
                    width: double.infinity,
                    padding: EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.grey.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: Colors.grey.withOpacity(0.3),
                      ),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.sentiment_dissatisfied,
                          color: Colors.grey[600],
                          size: 20,
                        ),
                        SizedBox(height: 8),
                        Text(
                          'Post at least 3 questions to get a CQI!',
                          style: TextStyle(
                            color: Colors.grey[600],
                            fontWeight: FontWeight.w600,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                ] else if (hasCqi && cqiRank > 0 && totalChameleons > 0) ...[
                  Container(
                    width: double.infinity,
                    padding: EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: (cqiRank > 0 && cqiRank <= 100) 
                          ? Theme.of(context).primaryColor.withOpacity(0.1)
                          : Colors.grey.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: (cqiRank > 0 && cqiRank <= 100) 
                            ? Theme.of(context).primaryColor.withOpacity(0.3)
                            : Colors.grey.withOpacity(0.3),
                      ),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.insights,
                          color: (cqiRank > 0 && cqiRank <= 100) 
                              ? Theme.of(context).primaryColor
                              : Colors.grey,
                          size: 20,
                        ),
                        SizedBox(height: 8),
                        Text(
                          cqiRank > 0 
                            ? (cqiRank <= 100 
                                ? 'CQI Rank #$cqiRank !'
                                : 'CQI ${_getPercentileText(cqiRank, totalChameleons)} !')
                            : 'Keep asking engaging questions!',
                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: (cqiRank > 0 && cqiRank <= 100) 
                                ? Theme.of(context).primaryColor
                                : Colors.grey,
                            fontWeight: FontWeight.w600,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                ],
                SizedBox(height: 16),
                // camo_quality = average responses per question asked
                // (DBarchitecture.md, user_engagement_rankings) — a count, not
                // the old -1..1 rating, so the praise tiers are counts too.
                if (hasCqi && camoQuality >= 10) ...[
                  Text(
                    'Your questions draw a crowd!',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).primaryColor,
                      fontWeight: FontWeight.w600,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  SizedBox(height: 16),
                ] else if (hasCqi && camoQuality > 0.0) ...[
                  Text(
                    'Chameleons are answering your questions!',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).primaryColor,
                      fontWeight: FontWeight.w600,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  SizedBox(height: 16),
                ],
                Text(
                  'The CQI is the average number of answers across the questions you\'ve asked. The more chameleons answer, the higher it goes.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Colors.grey[600],
                  ),
                ),
                if (totalUsers > 0) ...[
                  SizedBox(height: 16),
                  Text(
                    'There are currently $totalUsers chameleons on RTR.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Colors.grey[600],
                    ),
                  ),
                ],
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

  Future<int> _getLongestAnswerStreak() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt('longest_answer_streak') ?? 0;
  }

  Future<void> _saveLongestAnswerStreak(int streak) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('longest_answer_streak', streak);
  }

  Future<int> _getLongestPostStreak() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt('longest_post_streak') ?? 0;
  }

  Future<void> _saveLongestPostStreak(int streak) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('longest_post_streak', streak);
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
        continue;
      }
    }
    return false; // No answers found today
  }

  // Get hours remaining until end of day
  double _getHoursRemainingToday() {
    final now = DateTime.now();
    final endOfDay = DateTime(now.year, now.month, now.day, 23, 59, 59);
    final timeRemaining = endOfDay.difference(now);
    return timeRemaining.inMinutes / 60.0;
  }

  // Check if the streak card should pulse (when it's red/urgent)
  bool _shouldStreakCardPulse(bool hasExtendedStreakToday) {
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

  Future<String> _getAnswerStreakSubtitle(UserService userService) async {
    final currentStreak = _calculateCurrentStreak(userService.answeredQuestions);
    final longestStreak = await _getLongestAnswerStreak();
    
    // Update longest streak if current is longer
    if (currentStreak > longestStreak) {
      await _saveLongestAnswerStreak(currentStreak);
    }
    
    final actualLongestStreak = currentStreak > longestStreak ? currentStreak : longestStreak;
    
    if (currentStreak == 0) {
      return 'Tap for details';
    } else if (currentStreak >= actualLongestStreak && currentStreak > 0) {
      return 'This is your longest streak ever!';
    } else {
      return 'Your longest streak was $actualLongestStreak days';
    }
  }

  Future<String> _getPostStreakSubtitle(UserService userService) async {
    final currentStreak = _calculateCurrentStreak(userService.postedQuestions);
    final longestStreak = await _getLongestPostStreak();
    
    // Update longest streak if current is longer
    if (currentStreak > longestStreak) {
      await _saveLongestPostStreak(currentStreak);
    }
    
    final actualLongestStreak = currentStreak > longestStreak ? currentStreak : longestStreak;
    
    if (currentStreak == 0) {
      return 'Tap for details';
    } else if (currentStreak >= actualLongestStreak && currentStreak > 0) {
      return 'This is your longest streak ever!';
    } else {
      return 'Your longest streak was $actualLongestStreak days';
    }
  }

  // Get special dialog border decoration for top performers
  BoxDecoration? _getDialogBorderDecoration(int rank) {
    if (rank >= 1 && rank <= 10) {
      // Rainbow gradient border for ranks 1-10
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
    return null; // No special border for ranks >10
  }

  // Rainbow border for unlocked achievements
  BoxDecoration? _getAchievementDialogBorderDecoration(bool isUnlocked) {
    if (isUnlocked) {
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
    return null; // No special border for locked achievements
  }

  // Calculate percentile rounded to nearest 5%
  String _getPercentileText(int rank, int totalChameleons) {
    if (rank <= 0 || totalChameleons <= 0) return "Unranked";
    
    // Calculate what percentile group they're in (rank position as percentage)
    final percentilePosition = (rank / totalChameleons) * 100;
    
    // Round to nearest 5%
    final roundedPercentile = (percentilePosition / 5).round() * 5;
    
    // Ensure it's between 5 and 100 (don't show "Top 0%")
    final clampedPercentile = roundedPercentile.clamp(5, 100);
    
    return "Top $clampedPercentile%";
  }

  Future<void> _showTotalEngagementDialog(List<Map<String, dynamic>> questions) async {
    if (!mounted) return;
    
    final userService = Provider.of<UserService>(context, listen: false);
    
    // Force refresh to get fresh data from DB instead of cached
    final rankingData = await userService.getUserEngagementRanking(forceRefresh: true);
    
    // Check if widget is still mounted before showing dialog
    if (!mounted) return;
    
    final rank = rankingData['recent_30d_rank'] ?? 0;
    final totalUsers = rankingData['totalUsers'] ?? 0;
    final totalChameleons = rankingData['totalChameleons'] ?? 0;
    final userEngagement = rankingData['userEngagement'] ?? 0;
    
    // Use engagement score from materialized view (most accurate) - same as main screen
    final totalEngagement = userEngagement;
    
    print('Debug ranking data in user screen: rank=$rank, totalUsers=$totalUsers, totalChameleons=$totalChameleons, userEngagement=$userEngagement, displayedEngagement=$totalEngagement');
    
    final dialogBorder = _getDialogBorderDecoration(rank);
    
    showDialog(
      context: context,
      builder: (context) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: Container(
          decoration: dialogBorder,
          padding: (rank >= 1 && rank <= 10) ? EdgeInsets.all(3) : EdgeInsets.zero, // 3px padding for rainbow gradient border
          child: Container(
            decoration: BoxDecoration(
              color: Theme.of(context).dialogBackgroundColor,
              borderRadius: BorderRadius.circular((rank >= 1 && rank <= 10) ? 9 : 12),
            ),
            padding: EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Title
                Text(
                  'Camo Counter 🦎',
                  style: Theme.of(context).textTheme.titleLarge,
                  textAlign: TextAlign.center,
                ),
                SizedBox(height: 12),
                // Centered number
                Text(
                  _formatCount(totalEngagement),
                  style: Theme.of(context).textTheme.displayLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: Theme.of(context).primaryColor,
                  ),
                  textAlign: TextAlign.center,
                ),
                SizedBox(height: 20),
                // Content
                Text(
                  'The total number of responses to your questions (excluding your own)\n',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                SizedBox(height: 16),
                if (questions.isEmpty || totalEngagement == 0) ...[
                  Container(
                    width: double.infinity,
                    padding: EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.grey.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: Colors.grey.withOpacity(0.3),
                      ),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.sentiment_dissatisfied,
                          color: Colors.grey[600],
                          size: 20,
                        ),
                        SizedBox(height: 8),
                        Text(
                          questions.isEmpty 
                              ? 'You haven\'t asked a question yet...'
                              : 'Your questions haven\'t received responses yet...',
                          style: TextStyle(
                            color: Colors.grey[600],
                            fontWeight: FontWeight.w600,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                ] else if (totalChameleons > 0) ...[
                  Container(
                    width: double.infinity,
                    padding: EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: (rank > 0 && rank <= 100) 
                          ? Theme.of(context).primaryColor.withOpacity(0.1)
                          : Colors.grey.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: (rank > 0 && rank <= 100) 
                            ? Theme.of(context).primaryColor.withOpacity(0.3)
                            : Colors.grey.withOpacity(0.3),
                      ),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.emoji_events,
                          color: (rank > 0 && rank <= 100) 
                              ? Theme.of(context).primaryColor
                              : Colors.grey,
                          size: 20,
                        ),
                        SizedBox(height: 8),
                        Text(
                          rank > 0 
                            ? (rank <= 100 
                                ? 'You are ranked #$rank !'
                                : 'You are in the ${_getPercentileText(rank, totalChameleons)} :D')
                            : 'Post a question to get started!',
                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: (rank > 0 && rank <= 100) 
                                ? Theme.of(context).primaryColor
                                : Colors.grey,
                            fontWeight: FontWeight.w600,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        if (rank > 0) ...[
                          SizedBox(height: 8),
                          Text(
                            'Based on your last 30 days of questions',
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: Colors.grey[600],
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
                SizedBox(height: 16),
                if (totalEngagement > 10) ...[
                  Text(
                    (rank > 0 && rank <= 100) 
                        ? 'You seem to be asking the right questions!'
                        : 'Generating some interest...',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).primaryColor,
                      fontWeight: FontWeight.w600,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  SizedBox(height: 16),
                ],
                if (totalUsers > 0) ...[
                  Text(
                    'There are currently $totalUsers chameleons on RTR.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Colors.grey[600],
                    ),
                  ),
                  SizedBox(height: 16),
                ],
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

  Map<String, dynamic> _findMostPopularQuestionData(List<Map<String, dynamic>> questions) {
    if (questions.isEmpty) {
      return {
        'question': null,
        'hasTie': false,
        'tiedQuestions': <Map<String, dynamic>>[],
        'votes': 0,
      };
    }
    
    // Find the highest vote count
    int highestVotes = 0;
    for (final question in questions) {
      final votes = question['votes'] as int? ?? 0;
      if (votes > highestVotes) {
        highestVotes = votes;
      }
    }
    
    // Find all questions with the highest vote count
    List<Map<String, dynamic>> topQuestions = [];
    for (final question in questions) {
      final votes = question['votes'] as int? ?? 0;
      if (votes == highestVotes) {
        topQuestions.add(question);
      }
    }
    
    return {
      'question': topQuestions.isNotEmpty ? topQuestions.first : null,
      'hasTie': topQuestions.length > 1,
      'tiedQuestions': topQuestions,
      'votes': highestVotes,
    };
  }

  List<Map<String, dynamic>> _getTop10Questions(List<Map<String, dynamic>> questions) {
    if (questions.isEmpty) {
      return [];
    }
    
    // Sort questions by vote count in descending order
    List<Map<String, dynamic>> sortedQuestions = List.from(questions);
    sortedQuestions.sort((a, b) {
      final votesA = a['votes'] as int? ?? 0;
      final votesB = b['votes'] as int? ?? 0;
      return votesB.compareTo(votesA);
    });
    
    // Return top 10 (or all if less than 10)
    return sortedQuestions.take(10).toList();
  }

  Future<dynamic> _showTopQuestionsDialog(List<Map<String, dynamic>> allQuestions) {
    final top10Questions = _getTop10Questions(allQuestions);
    
    if (top10Questions.isEmpty) {
      // Show explanation for no questions
      return showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Top Questions'),
          content: Text(
            'You haven\'t posted any questions yet. Start asking great questions to see them ranked here!',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text('Got it!'),
            ),
          ],
        ),
      );
    }
    
    final topVoteCount = top10Questions.first['votes'] as int? ?? 0;
    
    return showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Top Questions'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Your ${top10Questions.length == 1 ? 'question' : '${top10Questions.length} most popular questions'} ranked by votes:',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            SizedBox(height: 16),
            Container(
              constraints: BoxConstraints(maxHeight: 400),
              child: SingleChildScrollView(
                child: Column(
                  children: top10Questions.asMap().entries.map((entry) {
                    final index = entry.key;
                    final question = entry.value;
                    final questionTitle = question['prompt']?.toString() ?? 
                                        question['title']?.toString() ?? 
                                        'No Title';
                    final voteCount = question['votes'] as int? ?? 0;
                    
                    return InkWell(
                      onTap: () async {
                        try {
                          print('DEBUG: Starting navigation to question with ID: ${question['id']}');
                          
                          final questionId = question['id'];
                          if (questionId == null) {
                            throw Exception('Question ID is null');
                          }
                          
                          // Use Navigator.pop with a result to trigger navigation
                          Navigator.of(context).pop({
                            'action': 'navigate',
                            'questionId': questionId.toString(),
                          });
                          
                        } catch (e) {
                          print('DEBUG: Error in navigation setup: $e');
                          Navigator.of(context).pop();
                        }
                      },
                      child: Container(
                        width: double.infinity,
                        padding: EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                        margin: EdgeInsets.only(bottom: 8),
                        decoration: BoxDecoration(
                          color: Theme.of(context).primaryColor.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: Theme.of(context).primaryColor.withOpacity(0.3),
                          ),
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 24,
                              height: 24,
                              decoration: BoxDecoration(
                                color: Theme.of(context).primaryColor,
                                shape: BoxShape.circle,
                              ),
                              child: Center(
                                child: Text(
                                  '${index + 1}',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ),
                            SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    questionTitle,
                                    style: TextStyle(
                                      color: Theme.of(context).primaryColor,
                                      fontWeight: FontWeight.w500,
                                    ),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  SizedBox(height: 2),
                                  Text(
                                    '${_formatCount(voteCount)} votes',
                                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                      color: Colors.grey[600],
                                      fontSize: 11,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Icon(
                              Icons.open_in_new,
                              size: 16,
                              color: Theme.of(context).primaryColor,
                            ),
                          ],
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ),
            ),
            SizedBox(height: 8),
            Text(
              'Tap any question to view its results',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Colors.grey[600],
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text('Close'),
          ),
        ],
      ),
    );
  }

  void _handleQuestionNavigation(String questionId) async {
    try {
      print('DEBUG: Handling navigation for question ID: $questionId');
      
      final questionService = Provider.of<QuestionService>(context, listen: false);
      final userService = Provider.of<UserService>(context, listen: false);
      
      final completeQuestion = await questionService.getQuestionById(questionId);
      
      if (completeQuestion != null) {
        print('DEBUG: Question data fetched successfully');
        
        // Check if user has answered this question
        final hasAnswered = userService.hasAnsweredQuestion(completeQuestion['id']);
        print('DEBUG: User has answered question: $hasAnswered');
        
        // Navigate based on whether user has answered
        if (hasAnswered) {
          print('DEBUG: Navigating to results screen');
          await questionService.navigateToResultsScreen(context, completeQuestion, fromUserScreen: true);
        } else {
          print('DEBUG: Navigating to answer screen');
          await questionService.navigateToAnswerScreen(context, completeQuestion, fromUserScreen: true);
        }
        print('DEBUG: Navigation completed');
      } else {
        print('DEBUG: Question not found');
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Question not found. It may have been deleted.'),
              backgroundColor: Colors.orange,
            ),
          );
        }
      }
    } catch (e) {
      print('DEBUG: Error in navigation: $e');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error loading question. Please try again.'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  void _showTiedQuestionsDialog(List<Map<String, dynamic>> tiedQuestions) {
    final voteCount = tiedQuestions.isNotEmpty ? (tiedQuestions.first['votes'] as int? ?? 0) : 0;
    
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Top Questions'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'It\'s a tie! These are your most popular questions (${_formatCount(voteCount)} votes each):',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            SizedBox(height: 16),
            Container(
              constraints: BoxConstraints(maxHeight: 300),
              child: SingleChildScrollView(
                child: Column(
                  children: tiedQuestions.map((question) {
                    final questionTitle = question['prompt']?.toString() ?? 
                                        question['title']?.toString() ?? 
                                        'No Title';
                    return InkWell(
                      onTap: () async {
                        // Fetch complete question data before navigation
                        final questionService = Provider.of<QuestionService>(context, listen: false);
                        
                        try {
                          final completeQuestion = await questionService.getQuestionById(question['id'].toString());
                          if (completeQuestion != null) {
                            // Close dialog first before navigation
                            Navigator.of(context).pop();
                            
                            // Check if user has answered this question to navigate to appropriate screen
                            final userService = Provider.of<UserService>(context, listen: false);
                            final hasAnswered = userService.hasAnsweredQuestion(completeQuestion['id']);
                            
                            if (hasAnswered) {
                              await questionService.navigateToResultsScreen(context, completeQuestion, fromUserScreen: true);
                            } else {
                              await questionService.navigateToAnswerScreen(context, completeQuestion, fromUserScreen: true);
                            }
                          } else {
                            // Close dialog before showing error
                            Navigator.of(context).pop();
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text('Question not found. It may have been deleted.'),
                                  backgroundColor: Colors.orange,
                                ),
                              );
                            }
                          }
                        } catch (e) {
                          print('Error fetching question: $e');
                          // Close dialog before showing error
                          Navigator.of(context).pop();
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text('Error loading question. Please try again.'),
                                backgroundColor: Colors.red,
                              ),
                            );
                          }
                        }
                      },
                      child: Container(
                        width: double.infinity,
                        padding: EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                        margin: EdgeInsets.only(bottom: 8),
                        decoration: BoxDecoration(
                          color: Theme.of(context).primaryColor.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: Theme.of(context).primaryColor.withOpacity(0.3),
                          ),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.open_in_new,
                              size: 16,
                              color: Theme.of(context).primaryColor,
                            ),
                            SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                questionTitle,
                                style: TextStyle(
                                  color: Theme.of(context).primaryColor,
                                  fontWeight: FontWeight.w500,
                                ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ),
            ),
            SizedBox(height: 8),
            Text(
              'Tap any question to view its results',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Colors.grey[600],
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text('Close'),
          ),
        ],
      ),
    );
  }

  void _showQotdHistoryDialog() async {
    try {
      final qotdData = await _getQotdData(forceRefresh: false);
      final qotdCount = qotdData['count'] as int;
      final qotdList = qotdData['qotds'] as List<dynamic>;
      
      if (qotdCount == 0) {
        // Show explanation for no QOTDs
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: Text('Question of the Day'),
            content: Text(
              'You haven\'t had any questions featured as Question of the Day yet. Keep posting great questions and you might be featured!',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text('Got it!'),
              ),
            ],
          ),
        );
        return;
      }
      
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Question of the Day'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Congratulations! You\'ve had ${qotdCount == 1 ? '1 question' : '$qotdCount questions'} featured as Question of the Day:',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              SizedBox(height: 16),
              Container(
                constraints: BoxConstraints(maxHeight: 300),
                child: SingleChildScrollView(
                  child: Column(
                    children: qotdList.map<Widget>((qotdItem) {
                      final question = qotdItem['questions'];
                      final featuredDate = qotdItem['date'];
                      final questionTitle = question['prompt']?.toString() ?? 
                                          question['title']?.toString() ?? 
                                          'No Title';
                      
                      // Format the featured date
                      String formattedDate = 'Unknown date';
                      try {
                        if (featuredDate != null) {
                          final date = DateTime.parse(featuredDate.toString());
                          formattedDate = '${date.month}/${date.day}/${date.year}';
                        }
                      } catch (e) {
                        print('Error parsing featured date: $e');
                      }
                      
                      return InkWell(
                        onTap: () async {
                          // Fetch complete question data before navigation
                          final questionService = Provider.of<QuestionService>(context, listen: false);
                          
                          try {
                            final completeQuestion = await questionService.getQuestionById(qotdItem['question_id'].toString());
                            if (completeQuestion != null) {
                              // Close dialog first before navigation
                              Navigator.of(context).pop();
                              
                              // Check if user has answered this question to navigate to appropriate screen
                              final userService = Provider.of<UserService>(context, listen: false);
                              final hasAnswered = userService.hasAnsweredQuestion(completeQuestion['id']);
                              
                              if (hasAnswered) {
                                await questionService.navigateToResultsScreen(context, completeQuestion, fromUserScreen: true);
                              } else {
                                await questionService.navigateToAnswerScreen(context, completeQuestion, fromUserScreen: true);
                              }
                            } else {
                              // Close dialog before showing error
                              Navigator.of(context).pop();
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text('Question not found. It may have been deleted.'),
                                    backgroundColor: Colors.orange,
                                  ),
                                );
                              }
                            }
                          } catch (e) {
                            print('Error fetching question: $e');
                            // Close dialog before showing error
                            Navigator.of(context).pop();
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text('Error loading question. Please try again.'),
                                  backgroundColor: Colors.red,
                                ),
                              );
                            }
                          }
                        },
                        child: Container(
                          width: double.infinity,
                          padding: EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                          margin: EdgeInsets.only(bottom: 8),
                          decoration: BoxDecoration(
                            color: Theme.of(context).primaryColor.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: Theme.of(context).primaryColor.withOpacity(0.3),
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Icon(
                                    Icons.star,
                                    size: 16,
                                    color: Theme.of(context).primaryColor,
                                  ),
                                  SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      questionTitle,
                                      style: TextStyle(
                                        color: Theme.of(context).primaryColor,
                                        fontWeight: FontWeight.w500,
                                      ),
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                              ),
                              SizedBox(height: 4),
                              Text(
                                'Featured on $formattedDate',
                                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                  color: Colors.grey[600],
                                  fontSize: 11,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ),
              ),
              SizedBox(height: 8),
              Text(
                'Tap any question to view its results',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Colors.grey[600],
                  fontStyle: FontStyle.italic,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text('Close'),
            ),
          ],
        ),
      );
    } catch (e) {
      print('Error showing QOTD history: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error loading QOTD history. Please try again.'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  // Get questions that the user has answered that were private (for Private-links section)
  Future<List<Map<String, dynamic>>> _getAnsweredPrivateQuestions() async {
    final userService = Provider.of<UserService>(context, listen: false);
    final questionService = Provider.of<QuestionService>(context, listen: false);
    
    // Get all answered questions from user service
    final answeredQuestions = userService.answeredQuestions;
    
    if (answeredQuestions.isEmpty) {
      return [];
    }
    
    // Extract question IDs
    final questionIds = answeredQuestions
        .map((q) => q['id']?.toString())
        .where((id) => id != null)
        .cast<String>()
        .toList();
    
    if (questionIds.isEmpty) {
      return [];
    }
    
    try {
      // Get hidden and existing question IDs to filter out hidden questions
      final hiddenIds = await questionService.getHiddenQuestionIds(questionIds);
      final existingIds = await questionService.getExistingQuestionIds(questionIds);
      
      // Batch fetch complete question data to check if they are private
      final completeQuestions = await questionService.getQuestionsByIds(questionIds);
      
      // Filter FOR private questions only AND exclude hidden/deleted questions
      final privateQuestions = completeQuestions.where((question) {
        final questionId = question['id']?.toString();
        return questionId != null &&
               question['is_private'] == true &&
               existingIds.contains(questionId) &&
               !hiddenIds.contains(questionId);
      }).toList();
      
      // Sort by when the user answered them (most recent first)
      // Use the timestamp from answeredQuestions which tracks when user answered
      privateQuestions.sort((a, b) {
        try {
          // Find the corresponding answered question to get the answer timestamp
          final aAnswered = answeredQuestions.firstWhere(
            (answered) => answered['id'] == a['id'],
            orElse: () => <String, dynamic>{},
          );
          final bAnswered = answeredQuestions.firstWhere(
            (answered) => answered['id'] == b['id'],
            orElse: () => <String, dynamic>{},
          );
          
          // Use answer timestamp first, fall back to question creation time
          final aTime = aAnswered['timestamp'] != null 
              ? DateTime.parse(aAnswered['timestamp']) 
              : (a['created_at'] != null ? DateTime.parse(a['created_at']) : DateTime.now());
          final bTime = bAnswered['timestamp'] != null 
              ? DateTime.parse(bAnswered['timestamp']) 
              : (b['created_at'] != null ? DateTime.parse(b['created_at']) : DateTime.now());
          
          return bTime.compareTo(aTime); // Most recent first
        } catch (e) {
          print('Error parsing date for private question sorting: $e');
          return 0; // Keep original order if parsing fails
        }
      });
      
      return privateQuestions;
    } catch (e) {
      print('Error filtering private questions: $e');
      return []; // Return empty list if filtering fails
    }
  }

  // Get cached subscribed questions future
  Future<List<Map<String, dynamic>>> _getCachedSubscribedQuestions() {
    _cachedSubscribedQuestionsFuture ??= _getSubscribedQuestionsWithDelta();
    return _cachedSubscribedQuestionsFuture!;
  }


  Future<List<Map<String, dynamic>>> _getSubscribedQuestionsWithDelta() async {
    final watchlistService = Provider.of<WatchlistService>(context, listen: false);
    final questionService = Provider.of<QuestionService>(context, listen: false);
    final prefs = await SharedPreferences.getInstance();
    final subscribedIds = watchlistService.getWatchedQuestionIds();
    
    print('Debug: Found ${subscribedIds.length} subscribed question IDs: $subscribedIds');
    
    // Use batch fetching instead of individual calls for better performance
    final batchQuestions = await questionService.getQuestionsByIds(subscribedIds);
    final subscribedQuestions = <Map<String, dynamic>>[];
    
    // Process each question from the batch result
    for (final question in batchQuestions) {
      try {
        final questionId = question['id']?.toString();
        if (questionId != null) {
          // print('Debug: Successfully fetched question $questionId: ${question['title'] ?? question['prompt']}');  // Commented out excessive logging
          // Get last seen vote count and comment count
          final key = 'question_view_$questionId';
          final data = prefs.getString(key);
          int? lastSeenVotes;
          int? lastSeenComments;
          bool shouldSetBaseline = false;
          
          if (data != null) {
            final parts = data.split(':');
            if (parts.length >= 2) {
              lastSeenVotes = int.tryParse(parts[1]);
            }
            if (parts.length >= 3) {
              lastSeenComments = int.tryParse(parts[2]);
            }
          } else {
            // No baseline exists for this subscribed question - we should set one
            shouldSetBaseline = true;
          }
          
          final currentVotes = question['votes'] as int? ?? 0;
          final currentComments = _getCommentCount(question);
          
          // Calculate deltas
          int voteDelta = (lastSeenVotes != null) ? (currentVotes - lastSeenVotes) : 0;
          int commentDelta = (lastSeenComments != null) ? (currentComments - lastSeenComments) : 0;
          
          // If no baseline exists, set one now so future visits can show deltas
          if (shouldSetBaseline) {
            try {
              final timestamp = DateTime.now().millisecondsSinceEpoch;
              final viewData = '$timestamp:$currentVotes:$currentComments';
              await prefs.setString(key, viewData);
              print('🦎 Set baseline for subscribed question $questionId: $currentVotes votes, $currentComments comments');
            } catch (e) {
              print('Error setting baseline for question $questionId: $e');
            }
          }
          
          question['voteDelta'] = voteDelta;
          question['commentDelta'] = commentDelta;
          question['lastSeenVotes'] = lastSeenVotes;
          question['lastSeenComments'] = lastSeenComments;
          subscribedQuestions.add(question);
        }
      } catch (e) {
        // Don't remove questions on errors - they might be temporary issues
        print('Error processing subscribed question ${question['id'] ?? 'unknown'}: $e - skipping without removal');
      }
    }
    
    // Check for any missing questions (not returned by batch fetch) and log them
    final fetchedIds = batchQuestions.map((q) => q['id']?.toString()).where((id) => id != null).toSet();
    final missingIds = subscribedIds.where((id) => !fetchedIds.contains(id)).toList();
    if (missingIds.isNotEmpty) {
      print('Debug: ${missingIds.length} subscribed questions were not fetched (might be hidden or deleted): $missingIds');
    }
    
    print('Debug: Returning ${subscribedQuestions.length} subscribed questions');
    
    // Enrich questions with engagement data if needed
    await _enrichQuestionsIfNeeded(subscribedQuestions);
    
    // Sort by highest delta, but maintain stable order for questions with same delta
    subscribedQuestions.sort((a, b) {
      final deltaA = a['voteDelta'] as int;
      final deltaB = b['voteDelta'] as int;
      
      // If deltas are equal, maintain original order (stable sort)
      if (deltaA == deltaB) {
        return 0;
      }
      
      // Sort by highest delta first
      return deltaB.compareTo(deltaA);
    });
    
    return subscribedQuestions;
  }

  // Delayed removal system methods
  void _scheduleRemoval(String questionId) {
    // Only update the pending removals set, don't trigger full rebuild
    _pendingRemovals.add(questionId);
    _recentlyUnsubscribed.add(questionId);
    
    // Cancel existing timer
    _removalTimer?.cancel();
    
    // Start new timer
    _removalTimer = Timer(Duration(seconds: 3), () async {
      if (mounted) {
        // Actually unsubscribe from all pending questions
        final watchlistService = Provider.of<WatchlistService>(context, listen: false);
        for (final id in _pendingRemovals) {
          await watchlistService.unsubscribeFromQuestion(id);
        }
        
        setState(() {
          _pendingRemovals.clear();
          _recentlyUnsubscribed.clear();
        });
        _clearSubscribedQuestionsCache();
      }
    });
  }

  void _cancelRemoval() {
    _removalTimer?.cancel();
    setState(() {
      _pendingRemovals.clear();
      _recentlyUnsubscribed.clear();
    });
    _clearSubscribedQuestionsCache();
  }

  void _undoRecentUnsubscriptions() async {
    final watchlistService = Provider.of<WatchlistService>(context, listen: false);
    
    // Re-subscribe to all recently unsubscribed questions
    for (final questionId in _recentlyUnsubscribed) {
      try {
        final questionService = Provider.of<QuestionService>(context, listen: false);
        final question = await questionService.getQuestionById(questionId);
        if (question != null) {
          final currentVotes = question['votes'] as int? ?? 0;
          final currentComments = _getCommentCount(question);
          await watchlistService.subscribeToQuestion(questionId, currentVotes, currentComments);
        }
      } catch (e) {
        print('Error re-subscribing to question $questionId: $e');
      }
    }
    
    // Clear the lists and cache
    setState(() {
      _pendingRemovals.clear();
      _recentlyUnsubscribed.clear();
    });
    _clearSubscribedQuestionsCache();
    
    // Show confirmation
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(Icons.notifications_active, color: Colors.white, size: 20),
            SizedBox(width: 8),
            Text('Re-subscribed to ${_recentlyUnsubscribed.length} question${_recentlyUnsubscribed.length == 1 ? '' : 's'}'),
          ],
        ),
        backgroundColor: Theme.of(context).primaryColor,
        duration: Duration(seconds: 2),
      ),
    );
  }

  // Clear cache when needed (e.g., when user subscribes/unsubscribes)
  void _clearSubscribedQuestionsCache() {
    _cachedSubscribedQuestionsFuture = null;
  }

  // Refresh cache to get latest subscribed questions
  void _refreshSubscribedQuestionsCache() {
    _cachedSubscribedQuestionsFuture = _getSubscribedQuestionsWithDelta();
  }

  // Clean up stale question_view_ preferences for deleted questions
  // This should only be called manually or very infrequently to avoid removing valid subscriptions
  Future<void> _cleanupStaleQuestionViewPreferences({bool manualTrigger = false}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      
      // Only run cleanup if manually triggered or if it's been more than 7 days
      if (!manualTrigger) {
        final lastCleanup = prefs.getString('last_watchlist_cleanup');
        if (lastCleanup != null) {
          final lastCleanupDate = DateTime.tryParse(lastCleanup);
          if (lastCleanupDate != null && DateTime.now().difference(lastCleanupDate).inDays < 7) {
            print('Debug: Skipping cleanup - last run was less than 7 days ago');
            return;
          }
        }
      }
      
      final allKeys = prefs.getKeys();
      
      // Find all question_view_ keys
      final questionViewKeys = allKeys.where((key) => key.startsWith('question_view_')).toList();
      
      if (questionViewKeys.isEmpty) {
        print('Debug: No question_view_ preferences found to clean up');
        return;
      }
      
      print('Debug: Found ${questionViewKeys.length} question_view_ preferences to validate');
      
      final questionService = Provider.of<QuestionService>(context, listen: false);
      final watchlistService = Provider.of<WatchlistService>(context, listen: false);
      final staleKeys = <String>[];
      final staleWatchlistIds = <String>[];
      
      // Check each question_view_ key in batches to avoid overwhelming the database
      for (int i = 0; i < questionViewKeys.length; i += 10) {
        final batch = questionViewKeys.skip(i).take(10);
        final batchResults = await Future.wait(
          batch.map((key) async {
            final questionId = key.substring('question_view_'.length);
            
            // Skip if question is in watchlist - we don't want to remove subscribed questions
            if (watchlistService.isWatching(questionId)) {
              print('Debug: Skipping $questionId - it is in watchlist');
              return {'key': key, 'exists': true, 'questionId': questionId};
            }
            
            try {
              final question = await questionService.getQuestionById(questionId);
              return {'key': key, 'exists': question != null, 'questionId': questionId};
            } catch (e) {
              // Only mark as non-existent if we get a specific "not found" error
              if (e.toString().contains('PGRST116') || e.toString().contains('0 rows')) {
                return {'key': key, 'exists': false, 'questionId': questionId};
              }
              // For any other error (network, timeout, etc), assume question exists
              print('Debug: Error checking $questionId, assuming it exists: $e');
              return {'key': key, 'exists': true, 'questionId': questionId};
            }
          })
        );
        
        // Collect keys for questions that definitely don't exist
        for (final result in batchResults) {
          if (result['exists'] == false) {
            staleKeys.add(result['key'] as String);
            final questionId = result['questionId'] as String;
            // Also check if this non-existent question is in watchlist
            if (watchlistService.isWatching(questionId)) {
              staleWatchlistIds.add(questionId);
            }
          }
        }
      }
      
      // Remove stale preference keys
      if (staleKeys.isNotEmpty) {
        print('Debug: Removing ${staleKeys.length} stale question_view_ preferences');
        
        for (final key in staleKeys) {
          await prefs.remove(key);
          print('Debug: Removed stale preference: $key');
        }
        
        // Also remove from watchlist if manually triggered
        if (manualTrigger && staleWatchlistIds.isNotEmpty) {
          print('Debug: Removing ${staleWatchlistIds.length} deleted questions from watchlist');
          for (final questionId in staleWatchlistIds) {
            await watchlistService.unsubscribeFromQuestion(questionId);
          }
        }
        
        print('Debug: Cleaned up ${staleKeys.length} stale question view preferences');
      } else {
        print('Debug: No stale question_view_ preferences found');
      }
      
      // Update last cleanup timestamp
      await prefs.setString('last_watchlist_cleanup', DateTime.now().toIso8601String());
    } catch (e) {
      print('Error cleaning up stale question view preferences: $e');
    }
  }

  // Clear delta indicators by recording current question view state
  Future<void> _clearQuestionDeltaIndicators(String questionId, int currentVotes, int currentComments) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final viewData = '$timestamp:$currentVotes:$currentComments';
      await prefs.setString('question_view_$questionId', viewData);
      print('🦎 Cleared delta indicators for question $questionId');
    } catch (e) {
      print('Error clearing question delta indicators: $e');
    }
  }

  Widget _buildSubtitle(BuildContext context, Map<String, dynamic> question, String timeAgoString, int voteDelta, bool isSubscribedSection) {
    final votes = question['votes'] ?? 0;
    final commentCount = _getCommentCount(question);
    final commentDelta = question['commentDelta'] as int? ?? 0;
    final userService = Provider.of<UserService>(context, listen: false);
    final hasAnswered = userService.hasAnsweredQuestion(question['id']);
    final isPrivate = question['is_private'] == true;
    
    // Build subtitle parts (excluding comments for separate display)
    final parts = <String>[];
    parts.add(timeAgoString);
    
    // Don't show vote counts for private questions since we can't accurately query them
    // Also don't show vote counts when they are 0
    if (!isPrivate && votes > 0) {
      parts.add('$votes ${votes == 1 ? 'vote' : 'votes'}');
    }
    
    final baseText = parts.join(' • ');
    final baseStyle = Theme.of(context).textTheme.bodySmall?.copyWith(
      color: hasAnswered ? Colors.grey : null,
    );
    
    // Subscribed section now uses the same layout as regular sections
    // (comment deltas removed from individual questions)
    
    // Regular layout with comment count on the right - show comments for both private and public questions
    return Row(
      children: [
        Expanded(
          child: Text(
            baseText,
            style: baseStyle,
          ),
        ),
        if (commentCount > 0)
          Text(
            '$commentCount ${commentCount == 1 ? 'comment' : 'comments'}',
            style: baseStyle,
          ),
      ],
    );
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
  
  Future<void> _loadMoreComments() async {
    if (_isLoadingComments || _commentLoadingQueue.isEmpty) return;
    
    setState(() {
      _isLoadingComments = true;
    });
    
    try {
      // Get next batch of questions needing comment data (10 at a time for Me page)
      final batchSize = 10;
      final endIndex = (_commentLoadingOffset + batchSize).clamp(0, _commentLoadingQueue.length);
      final batch = _commentLoadingQueue.sublist(_commentLoadingOffset, endIndex);
      
      if (batch.isEmpty) {
        setState(() {
          _isLoadingComments = false;
        });
        return;
      }
      
      // Get the actual question objects for this batch from all sections
      final questionService = Provider.of<QuestionService>(context, listen: false);
      final userService = Provider.of<UserService>(context, listen: false);
      
      // Collect all questions from various sources
      final allQuestions = <Map<String, dynamic>>[];
      
      // Add questions from different user sections
      allQuestions.addAll(userService.answeredQuestions);
      allQuestions.addAll(userService.postedQuestions);
      
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
      
      // Comment counts are updated in the question objects themselves
      // No need for full rebuild - the FutureBuilder widgets will automatically
      // refresh when the underlying data changes
      
    } catch (e) {
      print('❌ Error loading comments batch for Me page: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isLoadingComments = false;
        });
      }
    }
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
    
    // Start loading first batch immediately when a section is expanded
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
  
  // Vote count polling methods (similar to home_screen.dart but optimized for user questions)
  void _startVoteCountPolling() {
    // Prevent duplicate polling timers
    if (_voteCountPollTimer != null) {
      _voteCountPollTimer!.cancel();
    }
    
    // Execute first poll immediately to get fresh vote counts
    if (mounted) {
      _checkForVoteCountUpdates().then((_) {
        print('UserScreen: Started vote count polling for user questions');
      });
    }
    
    // Set up periodic polling every 2 minutes (less frequent than home screen)
    _voteCountPollTimer = Timer.periodic(Duration(minutes: 2), (timer) async {
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
  
  // Pause vote count polling
  void _pauseVoteCountPolling() {
    _isPollingPaused = true;
  }
  
  // Resume vote count polling
  void _resumeVoteCountPolling() {
    _isPollingPaused = false;
  }
  
  // Check for vote count updates on user questions
  Future<void> _checkForVoteCountUpdates() async {
    if (!mounted) return;
    
    try {
      final userService = Provider.of<UserService>(context, listen: false);
      final questionService = Provider.of<QuestionService>(context, listen: false);
      
      // Collect all user questions that might need vote count updates
      final allUserQuestions = <Map<String, dynamic>>[];
      allUserQuestions.addAll(userService.postedQuestions);
      allUserQuestions.addAll(userService.answeredQuestions);
      
      if (allUserQuestions.isEmpty) return;
      
      bool hasUpdates = false;
      
      // Check vote counts for first 10 questions to avoid too many DB calls
      final questionsToCheck = allUserQuestions.take(10).toList();
      
      for (var question in questionsToCheck) {
        final questionId = question['id']?.toString();
        final questionType = question['type']?.toString();
        
        if (questionId == null) continue;
        
        try {
          final currentCount = await questionService.getAccurateVoteCount(questionId, questionType);
          final lastKnownCount = _lastKnownVoteCounts[questionId] ?? question['votes'] ?? 0;
          
          // Check if vote count changed
          if (currentCount != lastKnownCount) {
            question['votes'] = currentCount;
            _lastKnownVoteCounts[questionId] = currentCount;
            hasUpdates = true;
            
            print('UserScreen: Vote count updated for question $questionId: $lastKnownCount → $currentCount');
          }
        } catch (e) {
          print('UserScreen: Error checking vote count for question $questionId: $e');
        }
      }
      
      // Update UI if there were changes
      if (hasUpdates && mounted) {
        setState(() {});
        print('UserScreen: Updated vote counts for user questions');
      }
    } catch (e) {
      print('UserScreen: Error in vote count polling: $e');
    }
  }
  
  // Initialize vote count tracking for user questions
  void _initializeVoteCountTracking(List<Map<String, dynamic>> questions) {
    for (var question in questions) {
      final questionId = question['id']?.toString();
      final voteCount = question['votes'] ?? 0;
      if (questionId != null) {
        _lastKnownVoteCounts[questionId] = voteCount;
      }
    }
    print('UserScreen: Initialized vote count tracking for ${_lastKnownVoteCounts.length} questions');
  }
  
  Future<void> _enrichQuestionsIfNeeded(List<Map<String, dynamic>> questions) async {
    if (questions.isEmpty) return;
    
    // Initialize vote count tracking for these questions
    _initializeVoteCountTracking(questions);
    
    // Initialize comment loading queue instead of doing enrichment directly
    _initializeCommentLoadingQueue(questions);
  }

  // Helper method to get device ID
  Future<String?> _getDeviceId() async {
    try {
      if (Platform.isAndroid) {
        // Use DeviceIdProvider to get the current device ID (whether legacy or migrated)
        return await DeviceIdProvider.getOrCreateDeviceId();
      } else if (Platform.isIOS) {
        final deviceInfo = DeviceInfoPlugin();
        final iosInfo = await deviceInfo.iosInfo;
        return iosInfo.identifierForVendor; // iOS identifier for vendor
      } else {
        return 'Unsupported platform';
      }
    } catch (e) {
      print('Error getting device ID: $e');
      return null;
    }
  }

}

/// Server-side badge stats for the Camo Collection, from the last load.
class _BadgeData {
  _BadgeData({
    required this.answeredCount,
    required this.qotdCount,
    required this.accountCreatedAt,
    required this.commentCount,
    required this.maxLizzies,
    required this.popcornCount,
    required this.reactionsGiven,
    required this.reactionsReceived,
    required this.legacyCityQuestions,
    required this.legacyCountryQuestions,
    required this.legacyUniqueCities,
    required this.userId,
    required this.friendHwm,
    required this.flags,
  });

  final int answeredCount;
  final int qotdCount;
  final DateTime? accountCreatedAt;
  final int commentCount;
  final int maxLizzies;
  final int popcornCount;
  final int reactionsGiven;
  final int reactionsReceived;
  final int legacyCityQuestions;
  final int legacyCountryQuestions;
  final int legacyUniqueCities;

  /// The account this snapshot was loaded for (null for guests).
  final String? userId;

  /// Most friends ever seen; bumped from build() as the live count grows.
  int friendHwm;
  final Set<String> flags;
}
