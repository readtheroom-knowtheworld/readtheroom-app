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
import '../widgets/my_rooms_section.dart';
import '../services/achievement_service.dart';
import '../services/congratulations_service.dart';
import '../services/room_service.dart';
import '../models/room.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

class UserScreen extends StatefulWidget {
  final bool fromAuthentication;
  
  const UserScreen({Key? key, this.fromAuthentication = false}) : super(key: key);
  
  @override
  _UserScreenState createState() => _UserScreenState();
}

class _UserScreenState extends State<UserScreen> with WidgetsBindingObserver {
  late AchievementService _achievementService;
  bool _achievementServiceInitialized = false;
  bool _forceRefreshAchievements = false;
  final GlobalKey<MyRoomsSectionState> _myRoomsKey = GlobalKey<MyRoomsSectionState>();
  
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
        _initAchievementService();
        // Start vote count polling for user questions
        _startVoteCountPolling();
        // Disabled aggressive cleanup - was causing subscribed questions to disappear
        // _cleanupStaleQuestionViewPreferences();
      }
    });
  }
  
  Future<void> _initAchievementService() async {
    final userService = Provider.of<UserService>(context, listen: false);
    _achievementService = AchievementService(userService: userService, context: context);
    await _achievementService.init();
    if (mounted) {
      setState(() {
        _achievementServiceInitialized = true;
      });
    }
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
                // Set force refresh flag for achievements
                setState(() {
                  _forceRefreshAchievements = true;
                });
                
                // Refresh engagement ranking when user pulls to refresh
                final userService = Provider.of<UserService>(context, listen: false);
                await userService.refreshEngagementRanking();
                
                // Refresh subscribed questions cache
                _refreshSubscribedQuestionsCache();
                
                // Refresh room data and member counts
                await _myRoomsKey.currentState?.refreshRooms();
                
                // Refresh achievement data
                if (_achievementServiceInitialized) {
                  await _achievementService.refreshAllAchievements();
                }
                
                // Reset force refresh flag after refresh
                if (mounted) {
                  setState(() {
                    _forceRefreshAchievements = false;
                  });
                }
              },
                  child: SingleChildScrollView(
                    physics: AlwaysScrollableScrollPhysics(), // Enable pull-to-refresh even when content is short
                    child: Padding(
                    padding: EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
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
        final isSaved = userService.savedQuestions.any((q) => q['id'] == question['id']);
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
                  : (isSaved && userService.savedQuestions.contains(question)
                      ? IconButton(
                          icon: Icon(Icons.bookmark, color: Theme.of(context).primaryColor),
                          onPressed: () {
                            userService.removeSavedQuestion(question['id']);
                            final scaffoldMessenger = ScaffoldMessenger.of(context);
                            final primaryColor = Theme.of(context).primaryColor;
                            scaffoldMessenger.showSnackBar(
                              SnackBar(
                                content: Row(
                                  children: [
                                    Icon(Icons.bookmark_border, color: Colors.white, size: 20),
                                    SizedBox(width: 8),
                                    Expanded(child: Text('Question removed from saved')),
                                    TextButton(
                                      onPressed: () {
                                        userService.addSavedQuestion(question);
                                        scaffoldMessenger.showSnackBar(
                                          SnackBar(
                                            content: Row(
                                              children: [
                                                Icon(Icons.bookmark, color: Colors.white, size: 20),
                                                SizedBox(width: 8),
                                                Text('Question re-saved'),
                                              ],
                                            ),
                                            backgroundColor: primaryColor,
                                            duration: Duration(seconds: 1),
                                          ),
                                        );
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
                              ),
                            );
                          },
                        )
                      : null),
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
                allQuestions.addAll(userService.savedQuestions);
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
              // Saved Questions section
              FutureBuilder<List<Map<String, dynamic>>>(
                future: userService.getFilteredSavedQuestions(Provider.of<QuestionService>(context, listen: false)),
                builder: (context, snapshot) {
                  final questions = snapshot.data ?? userService.savedQuestions;
                  return _buildQuestionSection(
                    'Saved Questions',
                    questions,
                    Icons.bookmark,
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

        SizedBox(height: 8),

        // My Rooms - Expandable section for room management
        MyRoomsSection(key: _myRoomsKey),

        SizedBox(height: 16),

        // Achievements section
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
              FutureBuilder<int>(
                future: _getUnlockedAchievementsCountAsync(),
                builder: (context, snapshot) {
                  final count = snapshot.data ?? 0;
                  return Text(
                    count == 1 ? '$count badge collected' : '$count badges collected',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).textTheme.bodySmall?.color?.withOpacity(0.7),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
        SizedBox(height: 8),
        
        // Question & Response Achievements
        FutureBuilder<List<Widget>>(
          future: _getProgressiveQuestionAchievementsAsync(userService, forceRefresh: _forceRefreshAchievements),
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return Container(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            final questionHunterAchievements = snapshot.data ?? [];
            return _buildAchievementSubsection('Question Hunter', questionHunterAchievements);
          },
        ),
        
        SizedBox(height: 12),
        
        // Community Achievements
        FutureBuilder<List<Widget>>(
          future: _getCommunityAchievementsAsync(forceRefresh: _forceRefreshAchievements),
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return Container(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            final communityAchievements = snapshot.data ?? [];
            return _buildAchievementSubsection('RTR Community', communityAchievements);
          },
        ),
        
        SizedBox(height: 12),
        
        // Local Community Achievements
        FutureBuilder<List<Widget>>(
          future: _getLocalCommunityAchievementsAsync(forceRefresh: _forceRefreshAchievements),
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return Container(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            final localCommunityAchievements = snapshot.data ?? [];
            return _buildAchievementSubsection('Local Community', localCommunityAchievements);
          },
        ),
        
        SizedBox(height: 12),
        
        // Room Achievements
        FutureBuilder<List<Widget>>(
          future: _getRoomAchievementsAsync(forceRefresh: _forceRefreshAchievements),
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return Container(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            final roomAchievements = snapshot.data ?? [];
            return _buildAchievementSubsection('Rooms and Networks', roomAchievements);
          },
        ),
        
        SizedBox(height: 12),
        
        // Social Achievements - COMMENTED OUT (not working well)
        // FutureBuilder<List<Widget>>(
        //   future: _getSocialAchievementsAsync(forceRefresh: true),
        //   builder: (context, snapshot) {
        //     if (snapshot.connectionState == ConnectionState.waiting) {
        //       return Container(
        //         padding: EdgeInsets.all(16),
        //         child: Center(child: CircularProgressIndicator()),
        //       );
        //     }
        //     final socialAchievements = snapshot.data ?? [];
        //     return _buildAchievementSubsection('Social Butterfly', socialAchievements);
        //   },
        // ),
        
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

  Future<List<Widget>> _getProgressiveQuestionAchievementsAsync(UserService userService, {bool forceRefresh = false}) async {
    // Check if we have cached data from today
    final prefs = await SharedPreferences.getInstance();
    final cacheKey = 'progressive_question_achievements_cache';
    final cacheTimeKey = 'progressive_question_achievements_cache_time';
    final cacheAnsweredCountKey = 'progressive_question_achievements_answered_count';
    
    if (!forceRefresh) {
      final cacheTime = prefs.getString(cacheTimeKey);
      final cachedAnsweredCount = prefs.getInt(cacheAnsweredCountKey);
      
      if (cacheTime != null && cachedAnsweredCount != null) {
        final cacheDateTime = DateTime.parse(cacheTime);
        final now = DateTime.now();
        
        // Use cache if from today
        if (cacheDateTime.year == now.year && 
            cacheDateTime.month == now.month && 
            cacheDateTime.day == now.day) {
          print('Using cached progressive question achievements');
          return await _buildProgressiveQuestionAchievements(userService, cachedAnsweredCount);
        }
      }
    }
    
    print('Building fresh progressive question achievements');
    final List<Widget> unlockedAchievements = [];
    final List<Widget> lockedAchievements = [];
    
    // Use the same filtered count that appears in My Questions "Answered" section
    // This excludes hidden/deleted/private questions to match what users see
    final filteredAnsweredQuestions = await userService.getFilteredAnsweredQuestions(Provider.of<QuestionService>(context, listen: false));
    final answeredCount = filteredAnsweredQuestions.length;
    
    // Cache the answered count for today
    await prefs.setInt(cacheAnsweredCountKey, answeredCount);
    await prefs.setString(cacheTimeKey, DateTime.now().toIso8601String());
    final votedCount = answeredCount; // Using answered as proxy for voted
    final hasFirstQuestion = userService.postedQuestions.isNotEmpty;
    
    // Sort into unlocked and locked lists
    
    // First question achievement
    final postedCount = userService.postedQuestions.length;
    if (hasFirstQuestion) {
      unlockedAchievements.add(_buildAchievementChip('❓', 'Not a lurker!', 'Posted a question', true,
          progress: 'Total posted: $postedCount questions', count: postedCount > 1 ? postedCount : null));
    } else {
      lockedAchievements.add(_buildAchievementChip('❓', 'Not a lurker!', 'Posted a question', false,
          progress: 'Post your first question to unlock'));
    }
    
    // Answer achievements (progressive) - Only show these, not vote achievements since they're the same
    if (answeredCount >= 1000) {
      unlockedAchievements.add(_buildAchievementChip('✅🏆', 'Answer Champion', 'Answered 1000+ questions', true,
          progress: 'Current: ${answeredCount} answers'));
    } else if (answeredCount >= 100) {
      unlockedAchievements.add(_buildAchievementChip('💯✅', 'Century Club', 'Answered 100+ questions', true,
          progress: 'Current: ${answeredCount} answers'));
      lockedAchievements.add(_buildAchievementChip('✅🏆', 'Answer Champion', 'Answered 1000+ questions', false,
          progress: 'Progress: ${answeredCount}/1000 answers'));
    } else if (answeredCount >= 10) {
      unlockedAchievements.add(_buildAchievementChip('10✅', 'Getting Started', 'Answered 10+ questions', true,
          progress: 'Current: ${answeredCount} answers'));
      lockedAchievements.add(_buildAchievementChip('💯✅', 'Century Club', 'Answered 100+ questions', false,
          progress: 'Progress: ${answeredCount}/100 answers'));
    }
    
    // Count achievements for questions that can be achieved multiple times
    int popularQuestionCount = 0;
    int viralQuestionCount = 0;
    
    for (var question in userService.postedQuestions) {
      final votes = question['votes'] ?? 0;
      if (votes >= 500) {
        viralQuestionCount++;
      } else if (votes >= 100) {
        popularQuestionCount++;
      }
    }
    
    // Store achievements with counts for sorting
    List<Map<String, dynamic>> countedAchievements = [];
    
    // Popular Question achievement (100+ responses)
    if (popularQuestionCount > 0) {
      countedAchievements.add({
        'count': popularQuestionCount,
        'widget': _buildAchievementChip('🎤', 'Popular Question', 'Your question reached 100+ responses', true,
            progress: popularQuestionCount == 1 ? 'Achievement unlocked!' : 'Achieved $popularQuestionCount times', 
            count: popularQuestionCount)
      });
    } else {
      lockedAchievements.add(_buildAchievementChip('🎤', 'Popular Question', 'Your question reached 100+ responses', false,
          progress: 'Get 100+ responses on a question'));
    }
    
    // Viral Question achievement (500+ responses)
    if (viralQuestionCount > 0) {
      countedAchievements.add({
        'count': viralQuestionCount,
        'widget': _buildAchievementChip('🧿', 'Viral Question', 'Your question reached 500+ responses', true,
            progress: viralQuestionCount == 1 ? 'Achievement unlocked!' : 'Achieved $viralQuestionCount times', 
            count: viralQuestionCount)
      });
    } else {
      lockedAchievements.add(_buildAchievementChip('🧿', 'Viral Question', 'Your question reached 500+ responses', false,
          progress: 'Get 500+ responses on a question'));
    }
    
    // QOTD Star achievement (check if user has had a question as Question of the Day)
    final qotdStarUnlocked = await _isAchievementUnlocked('qotd_star');
    final hasBeenQotd = await _hasQuestionBeenQotd();
    final qotdCount = hasBeenQotd ? await _getQotdCount() : 0;
    
    if (qotdStarUnlocked || hasBeenQotd) {
      if (!qotdStarUnlocked && hasBeenQotd) {
        await _setAchievementUnlocked('qotd_star');
        
        // Show congratulations for QOTD achievement if eligible
        try {
          final userService = Provider.of<UserService>(context, listen: false);
          final achievementService = AchievementService(
            userService: userService,
            context: context,
          );
          await achievementService.init();
          
          final congratulationsService = CongratulationsService(
            userService: userService,
            achievementService: achievementService,
          );
          await congratulationsService.init();
          
          await congratulationsService.showCongratulationsIfEligible(
            context,
            AchievementType.qotdBadge,
          );
        } catch (e) {
          print('Error showing congratulations for QOTD achievement: $e');
          // Don't let this error interrupt the normal flow
        }
      }
      
      // Add QOTD to counted achievements for sorting
      final progressText = qotdCount == 1 ? 'You have had 1 QOTD' : 'You have had $qotdCount QOTDs';
      countedAchievements.add({
        'count': qotdCount,
        'widget': _buildAchievementChip('📅⭐', 'QOTD Star', 'Your post became Question of the Day', true,
            progress: progressText, customOnTap: _showQotdHistoryDialog, count: qotdCount)
      });
    } else {
      lockedAchievements.add(_buildAchievementChip('📅⭐', 'QOTD Star', 'Your post became Question of the Day', false,
          progress: 'Get your question featured as QOTD'));
    }
    
    // Sort counted achievements by count (highest first) and add to unlocked list
    countedAchievements.sort((a, b) => (b['count'] as int).compareTo(a['count'] as int));
    for (var achievement in countedAchievements) {
      unlockedAchievements.add(achievement['widget']);
    }
    
    // COMMENTED OUT - achievements we can't verify yet
    // lockedAchievements.add(_buildAchievementChip('🌍', 'Globetrotter', 'Your question got responses from 10+ countries', false));
    // lockedAchievements.add(_buildAchievementChip('🗓️', '365 Club', 'Answered a question daily for 1 year', false));
    // lockedAchievements.add(_buildAchievementChip('⚡', 'First Responder', 'First to answer 100+ times', false));
    
    // Combine lists: unlocked first, then locked
    final List<Widget> achievements = [];
    achievements.addAll(unlockedAchievements);
    achievements.addAll(lockedAchievements);
    
    return achievements;
  }

  // Helper method to build progressive question achievements using cached data (no DB calls)
  Future<List<Widget>> _buildProgressiveQuestionAchievements(UserService userService, int answeredCount) async {
    final List<Widget> unlockedAchievements = [];
    final List<Widget> lockedAchievements = [];
    
    final hasFirstQuestion = userService.postedQuestions.isNotEmpty;
    
    // First question achievement
    final postedCount = userService.postedQuestions.length;
    if (hasFirstQuestion) {
      unlockedAchievements.add(_buildAchievementChip('❓', 'Not a lurker!', 'Posted a question', true,
          progress: 'Total posted: $postedCount questions', count: postedCount > 1 ? postedCount : null));
    } else {
      lockedAchievements.add(_buildAchievementChip('❓', 'Not a lurker!', 'Posted a question', false,
          progress: 'Post your first question to unlock'));
    }
    
    // Answer achievements (progressive) - Only show these, not vote achievements since they're the same
    if (answeredCount >= 1000) {
      unlockedAchievements.add(_buildAchievementChip('✅🏆', 'Answer Champion', 'Answered 1000+ questions', true,
          progress: 'Current: ${answeredCount} answers'));
    } else if (answeredCount >= 100) {
      unlockedAchievements.add(_buildAchievementChip('💯✅', 'Century Club', 'Answered 100+ questions', true,
          progress: 'Current: ${answeredCount} answers'));
      lockedAchievements.add(_buildAchievementChip('✅🏆', 'Answer Champion', 'Answered 1000+ questions', false,
          progress: 'Progress: ${answeredCount}/1000 answers'));
    } else if (answeredCount >= 10) {
      unlockedAchievements.add(_buildAchievementChip('10✅', 'Getting Started', 'Answered 10+ questions', true,
          progress: 'Current: ${answeredCount} answers'));
      lockedAchievements.add(_buildAchievementChip('💯✅', 'Century Club', 'Answered 100+ questions', false,
          progress: 'Progress: ${answeredCount}/100 answers'));
    }
    
    // Count achievements for questions that can be achieved multiple times (using cached data)
    int popularQuestionCount = 0;
    int viralQuestionCount = 0;
    
    for (var question in userService.postedQuestions) {
      final votes = question['votes'] ?? 0;
      if (votes >= 500) {
        viralQuestionCount++;
      } else if (votes >= 100) {
        popularQuestionCount++;
      }
    }
    
    // Store achievements with counts for sorting
    List<Map<String, dynamic>> countedAchievements = [];
    
    // Popular Question achievement (100+ responses)
    if (popularQuestionCount > 0) {
      countedAchievements.add({
        'count': popularQuestionCount,
        'widget': _buildAchievementChip('🎤', 'Popular Question', 'Your question reached 100+ responses', true,
            progress: popularQuestionCount == 1 ? 'Achievement unlocked!' : 'Achieved $popularQuestionCount times', 
            count: popularQuestionCount)
      });
    } else {
      lockedAchievements.add(_buildAchievementChip('🎤', 'Popular Question', 'Your question reached 100+ responses', false,
          progress: 'Get 100+ responses on a question'));
    }
    
    // Viral Question achievement (500+ responses) - using cached data
    if (viralQuestionCount > 0) {
      countedAchievements.add({
        'count': viralQuestionCount,
        'widget': _buildAchievementChip('🧿', 'Viral Question', 'Your question reached 500+ responses', true,
            progress: viralQuestionCount == 1 ? 'Achievement unlocked!' : 'Achieved $viralQuestionCount times', 
            count: viralQuestionCount)
      });
    } else {
      lockedAchievements.add(_buildAchievementChip('🧿', 'Viral Question', 'Your question reached 500+ responses', false,
          progress: 'Get 500+ responses on a question'));
    }
    
    // QOTD Star achievement (using cached check)
    final qotdStarUnlocked = await _isAchievementUnlocked('qotd_star');
    final hasBeenQotd = await _hasQuestionBeenQotd(); // This method has its own caching
    final qotdCount = hasBeenQotd ? await _getQotdCount() : 0;
    
    if (qotdStarUnlocked || hasBeenQotd) {
      final progressText = qotdCount == 1 ? 'You have had 1 QOTD' : 'You have had $qotdCount QOTDs';
      countedAchievements.add({
        'count': qotdCount,
        'widget': _buildAchievementChip('📅⭐', 'QOTD Star', 'Your post became Question of the Day', true,
            progress: progressText, customOnTap: _showQotdHistoryDialog, count: qotdCount)
      });
    } else {
      lockedAchievements.add(_buildAchievementChip('📅⭐', 'QOTD Star', 'Your post became Question of the Day', false,
          progress: 'Get your question featured as QOTD'));
    }
    
    // Sort counted achievements by count (highest first) and add to unlocked list
    countedAchievements.sort((a, b) => (b['count'] as int).compareTo(a['count'] as int));
    for (var achievement in countedAchievements) {
      unlockedAchievements.add(achievement['widget']);
    }
    
    // Combine lists: unlocked first, then locked
    final List<Widget> achievements = [];
    achievements.addAll(unlockedAchievements);
    achievements.addAll(lockedAchievements);
    
    return achievements;
  }

  // Helper method to check Birthday Buddy achievement
  bool _checkBirthdayBuddy(UserService userService) {
    print('Checking birthday buddy for ${userService.postedQuestions.length} posted questions');
    for (var question in userService.postedQuestions) {
      if (question['created_at'] != null) {
        try {
          final createdAt = DateTime.parse(question['created_at']);
          print('Question posted on: ${createdAt.month}/${createdAt.day}/${createdAt.year}');
          // Check if posted in November (any day, any year) - RTR's birthday month
          if (createdAt.month == 11) {
            print('Found November question! Birthday Buddy achieved!');
            return true;
          }
        } catch (e) {
          print('Error parsing date for question: $e');
          // Skip if date parsing fails
          continue;
        }
      }
    }
    print('No November questions found');
    return false;
  }

  // Get room achievements based on actual room data
  Future<List<Widget>> _getRoomAchievementsAsync({bool forceRefresh = false}) async {
    try {
      final data = await _getRoomAchievementData(forceRefresh: forceRefresh);
      final roomCount = data['roomCount'] ?? 0;
      final hasJoinedRoom = data['hasJoinedRoom'] ?? false;
      final hasCreatedRoom = data['hasCreatedRoom'] ?? false;
      final hasTurnedTheKey = data['hasTurnedTheKey'] ?? false;
      final isNetworker = data['isNetworker'] ?? false;

      final List<Widget> unlockedAchievements = [];
      final List<Widget> lockedAchievements = [];

      // Check SharedPreferences for permanently unlocked achievements
      final prefs = data['prefs'];
      
      // Room achievements (progressive - show based on user's progress)
      final youreInvitedUnlocked = prefs?.getBool('achievement_youre_invited') ?? false;
      final roomFounderUnlocked = prefs?.getBool('achievement_room_founder') ?? false;
      final turnedTheKeyUnlocked = prefs?.getBool('achievement_turned_the_key') ?? false;
      
      // Set unlocked flags if conditions are met
      if (hasJoinedRoom && !youreInvitedUnlocked) {
        prefs?.setBool('achievement_youre_invited', true);
      }
      if (hasCreatedRoom && !roomFounderUnlocked) {
        prefs?.setBool('achievement_room_founder', true);
      }
      if (hasTurnedTheKey && !turnedTheKeyUnlocked) {
        prefs?.setBool('achievement_turned_the_key', true);
      }

      // Progressive display logic
      if (roomCount == 0) {
        // No rooms yet - show basic invitation achievements
        lockedAchievements.add(_buildAchievementChip('🎪🎉', 'You\'re Invited!!', 'Joined your first room', false,
            progress: 'Join or create your first room'));
      } else {
        // Has rooms - show You're Invited as unlocked
        unlockedAchievements.add(_buildAchievementChip('🎪🎉', 'You\'re Invited!!', 'Joined your first room', true,
            progress: 'In $roomCount room${roomCount != 1 ? 's' : ''}'));
        
        // Show Room Founder if created or next logical step
        if (roomFounderUnlocked || hasCreatedRoom) {
          unlockedAchievements.add(_buildAchievementChip('🎪🌱', 'Room Founder', 'Created your first room', true,
              progress: 'Achievement unlocked!'));
          
          // Show Turned the Key if unlocked/achieved or as next step
          if (turnedTheKeyUnlocked || hasTurnedTheKey) {
            unlockedAchievements.add(_buildAchievementChip('🎪🔑', 'Turned the Key', 'Room unlocked with 5+ members', true,
                progress: 'Achievement unlocked!'));
          } else {
            unlockedAchievements.add(_buildAchievementChip('🎪🔑', 'Turned the Key', 'Room unlocked with 5+ members', false,
                progress: 'Get a room to 5+ members'));
          }
        } else {
          // Show Room Founder as next step
          lockedAchievements.add(_buildAchievementChip('🎪🌱', 'Room Founder', 'Created your first room', false,
              progress: 'Create a room to unlock'));
        }
        
        // Show Networker if in 3+ rooms (approaching the 5+ requirement)
        // This achievement shows dynamic progress that can decrease if user leaves rooms
        if (roomCount >= 3) {
          if (isNetworker) {
            // Currently in 5+ rooms - show as unlocked with current count
            unlockedAchievements.add(_buildAchievementChip('🎪🤝', 'Networker', 'You\'ve been in 5+ rooms', true,
                progress: 'In $roomCount rooms'));
          } else {
            // Approaching 5 rooms but not there yet - show progress
            lockedAchievements.add(_buildAchievementChip('🎪🤝', 'Networker', 'You\'ve been in 5+ rooms', false,
                progress: 'Progress: $roomCount/5 rooms'));
          }
        }
      }

      // Check for room ranking achievements using actual room data
      final roomRankings = await _checkRoomRankings();
      final hasTop10Room = roomRankings['hasTop10Room'] ?? false;
      final hasRank1Room = roomRankings['hasRank1Room'] ?? false;
      final hasRank2Room = roomRankings['hasRank2Room'] ?? false;
      final hasRank3Room = roomRankings['hasRank3Room'] ?? false;
      final bestRank = roomRankings['bestRank'] as int?;

      // Room Oracles (Top 10)
      if (hasTop10Room) {
        unlockedAchievements.add(_buildAchievementChip('🎪🔮', 'Room Oracles', 'A room you are in was ranked in top 10', true,
            progress: 'Best rank: #$bestRank'));
      } else {
        lockedAchievements.add(_buildAchievementChip('🎪🔮', 'Room Oracles', 'A room you are in was ranked in top 10', false,
            progress: 'Get your room ranked in top 10'));
      }

      // Room ranking achievements (1st, 2nd, 3rd)
      if (hasRank1Room) {
        unlockedAchievements.add(_buildAchievementChip('🎪🏆', 'Room Champions', 'Your room ranked #1 globally', true,
            progress: 'Achievement unlocked!'));
      } else {
        lockedAchievements.add(_buildAchievementChip('🎪🏆', 'Room Champions', 'Your room ranked #1 globally', false,
            progress: 'Get your room to #1 rank'));
      }

      if (hasRank2Room) {
        unlockedAchievements.add(_buildAchievementChip('🎪🥈', 'Silver Room', 'Your room ranked #2 globally', true,
            progress: 'Achievement unlocked!'));
      } else {
        lockedAchievements.add(_buildAchievementChip('🎪🥈', 'Silver Room', 'Your room ranked #2 globally', false,
            progress: 'Get your room to #2 rank'));
      }

      if (hasRank3Room) {
        unlockedAchievements.add(_buildAchievementChip('🎪🥉', 'Bronze Room', 'Your room ranked #3 globally', true,
            progress: 'Achievement unlocked!'));
      } else {
        lockedAchievements.add(_buildAchievementChip('🎪🥉', 'Bronze Room', 'Your room ranked #3 globally', false,
            progress: 'Get your room to #3 rank'));
      }

      // Other room achievements
      lockedAchievements.add(_buildAchievementChip('🎪🔥', 'Boiler Room', 'Members of your room have given 10,000+ responses collectively', false,
          progress: 'Get 10,000+ responses in a room'));
      lockedAchievements.add(_buildAchievementChip('🌐🐉', 'Networking Dragon', 'Your network size is 100+', false,
          progress: 'Build a large network'));
      
      // Combine lists: unlocked first, then locked
      final List<Widget> achievements = [];
      achievements.addAll(unlockedAchievements);
      achievements.addAll(lockedAchievements);
      
      return achievements;
    } catch (e) {
      // Return empty list if there's an error
      return [];
    }
  }

  // Helper method to get all room achievement data with daily caching
  Future<Map<String, dynamic>> _getRoomAchievementData({bool forceRefresh = false}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final cacheKey = 'room_achievement_data';
      final cacheTimeKey = 'room_achievement_data_last_checked';
      
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
            print('Using cached room achievement data');
            final Map<String, dynamic> cached = Map<String, dynamic>.from(
              Uri.splitQueryString(cachedData).map((k, v) => MapEntry(k, v == 'true'))
            );
            // Add numeric values back
            if (prefs.containsKey('cached_room_count')) {
              cached['roomCount'] = prefs.getInt('cached_room_count') ?? 0;
            }
            cached['prefs'] = prefs;
            return cached;
          }
        }
      }
      
      print('Fetching room achievement data from services');
      final rooms = await RoomService().getUserRooms();
      final roomCount = rooms.length;
      final hasJoinedRoom = roomCount > 0;
      final isNetworker = roomCount >= 5;
      
      bool hasCreatedRoom = false;
      bool hasTurnedTheKey = false;
      
      for (var room in rooms) {
        if (room.isUnlocked) {
          hasTurnedTheKey = true;
        }
      }

      // Check room creation
      hasCreatedRoom = await _checkIfUserCreatedAnyRoom(rooms);

      final data = {
        'prefs': prefs,
        'roomCount': roomCount,
        'hasJoinedRoom': hasJoinedRoom,
        'hasCreatedRoom': hasCreatedRoom,
        'hasTurnedTheKey': hasTurnedTheKey,
        'isNetworker': isNetworker,
      };
      
      // Cache the boolean results
      final cacheData = {
        'hasJoinedRoom': hasJoinedRoom.toString(),
        'hasCreatedRoom': hasCreatedRoom.toString(),
        'hasTurnedTheKey': hasTurnedTheKey.toString(),
        'isNetworker': isNetworker.toString(),
      };
      await prefs.setString(cacheKey, Uri(queryParameters: cacheData).query);
      await prefs.setInt('cached_room_count', roomCount);
      await prefs.setString(cacheTimeKey, DateTime.now().toIso8601String());
      
      return data;
    } catch (e) {
      print('Error fetching room achievement data: $e');
      return {};
    }
  }

  // Helper method to check if user has created any rooms
  Future<bool> _checkIfUserCreatedAnyRoom(List<Room> rooms) async {
    final roomService = RoomService();
    for (var room in rooms) {
      try {
        if (await roomService.isRoomAdmin(room.id)) {
          return true;
        }
      } catch (e) {
        // Continue checking other rooms if one fails
        continue;
      }
    }
    return false;
  }

  // Helper method to check room ranking achievements
  Future<Map<String, dynamic>> _checkRoomRankings() async {
    try {
      final rooms = await RoomService().getUserRooms();
      
      bool hasTop10Room = false;
      bool hasRank1Room = false;
      bool hasRank2Room = false;
      bool hasRank3Room = false;
      int? bestRank;

      for (var room in rooms) {
        final rank = room.globalRank;
        if (rank != null && rank > 0) {
          // Track the best (lowest) rank
          if (bestRank == null || rank < bestRank) {
            bestRank = rank;
          }

          // Check specific ranking achievements
          if (rank <= 10) {
            hasTop10Room = true;
          }
          if (rank == 1) {
            hasRank1Room = true;
          }
          if (rank == 2) {
            hasRank2Room = true;
          }
          if (rank == 3) {
            hasRank3Room = true;
          }
        }
      }

      return {
        'hasTop10Room': hasTop10Room,
        'hasRank1Room': hasRank1Room,
        'hasRank2Room': hasRank2Room,
        'hasRank3Room': hasRank3Room,
        'bestRank': bestRank,
      };
    } catch (e) {
      print('Error checking room rankings: $e');
      return {
        'hasTop10Room': false,
        'hasRank1Room': false,
        'hasRank2Room': false,
        'hasRank3Room': false,
        'bestRank': null,
      };
    }
  }

  // Get community achievements including Alpha/Beta tester badges
  Future<List<Widget>> _getCommunityAchievementsAsync({bool forceRefresh = false}) async {
    final userService = Provider.of<UserService>(context, listen: false);
    final List<Widget> unlockedAchievements = [];
    final List<Widget> lockedAchievements = [];
    
    try {
      final prefs = await SharedPreferences.getInstance();
      
      // Check user creation date from database
      final userCreationData = await _getUserCreationDate(forceRefresh: forceRefresh);
      final userCreatedAt = userCreationData['created_at'] as DateTime?;
      
      if (userCreatedAt != null) {
        // Format date for Hatchling achievement
        final formattedDate = '${userCreatedAt.day}/${userCreatedAt.month}/${userCreatedAt.year}';
        
        // Alpha Tester: joined before July 21, 2025 (only show if unlocked)
        final alphaDate = DateTime(2025, 7, 21);
        final alphaTesterUnlocked = prefs.getBool('achievement_alpha_tester') ?? false;
        final isAlphaTester = userCreatedAt.isBefore(alphaDate);
        
        if (alphaTesterUnlocked || isAlphaTester) {
          if (!alphaTesterUnlocked && isAlphaTester) {
            prefs.setBool('achievement_alpha_tester', true);
          }
          unlockedAchievements.add(_buildAchievementChip('🧪🐣', 'Alpha Tester', 'User created before July 21 2025', true,
              progress: 'Achievement unlocked!'));
        }
        
        // Beta Tester: joined before September 1, 2025 (only show if unlocked)
        final betaDate = DateTime(2025, 9, 1);
        final betaTesterUnlocked = prefs.getBool('achievement_beta_tester') ?? false;
        final isBetaTester = userCreatedAt.isBefore(betaDate);
        
        if (betaTesterUnlocked || isBetaTester) {
          if (!betaTesterUnlocked && isBetaTester) {
            prefs.setBool('achievement_beta_tester', true);
          }
          unlockedAchievements.add(_buildAchievementChip('🐝🔧', 'Beta Tester', 'User created before Sept 1 2025', true,
              progress: 'Achievement unlocked!'));
        }
        
        // Hatchling: authenticated as human (always unlocked for any user with creation date)
        final hatchlingUnlocked = prefs.getBool('achievement_hatchling') ?? false;
        
        if (!hatchlingUnlocked) {
          prefs.setBool('achievement_hatchling', true);
        }
        unlockedAchievements.add(_buildAchievementChip('🐣', 'Hatchling', 'Authenticated as human on $formattedDate', true,
            progress: 'Achievement unlocked!'));
      }
      
      // Birthday Buddy achievement (check posted questions) - permanently unlock once achieved
      final birthdayBuddyUnlocked = await _isAchievementUnlocked('birthday_buddy');
      final hasBirthdayPost = _checkBirthdayBuddy(userService);
      
      if (birthdayBuddyUnlocked || hasBirthdayPost) {
        // Permanently unlock if condition is met
        if (!birthdayBuddyUnlocked && hasBirthdayPost) {
          await _setAchievementUnlocked('birthday_buddy');
        }
        unlockedAchievements.add(_buildAchievementChip('🎂', 'Birthday Buddy', 'Posted a question during RTR\'s birthday month', true,
            progress: 'Achievement unlocked!'));
      } else {
        lockedAchievements.add(_buildAchievementChip('🎂', 'Birthday Buddy', 'Posted a question during RTR\'s birthday month', false,
            progress: 'Post a question in November'));
      }
      
    } catch (e) {
      print('Error loading community achievements: $e');
      // Fallback to just birthday buddy if user creation check fails
      final birthdayBuddyUnlocked = await _isAchievementUnlocked('birthday_buddy');
      final hasBirthdayPost = _checkBirthdayBuddy(userService);
      
      if (birthdayBuddyUnlocked || hasBirthdayPost) {
        if (!birthdayBuddyUnlocked && hasBirthdayPost) {
          await _setAchievementUnlocked('birthday_buddy');
        }
        unlockedAchievements.add(_buildAchievementChip('🎂', 'Birthday Buddy', 'Posted a question during RTR\'s birthday month', true,
            progress: 'Achievement unlocked!'));
      } else {
        lockedAchievements.add(_buildAchievementChip('🎂', 'Birthday Buddy', 'Posted a question during RTR\'s birthday month', false,
            progress: 'Post a question in November'));
      }
    }
    
    // Notification enablement achievement
    final notificationsEnabled = userService.notifyResponses;
    if (notificationsEnabled) {
      unlockedAchievements.add(_buildAchievementChip('🦎📡', 'Call me, beep me', 'Enabled notifications for new Questions of the Day', true,
          progress: 'Achievement unlocked!'));
    } else {
      lockedAchievements.add(_buildAchievementChip('🦎📡', 'Call me, beep me', 'Enabled notifications for new Questions of the Day', false,
          progress: 'Enable notifications in settings'));
    }
    
    // Streak reminder enablement achievement
    final streakRemindersEnabled = userService.notifyStreakReminders;
    if (streakRemindersEnabled) {
      unlockedAchievements.add(_buildAchievementChip('🔒🎯', 'Locked-in', 'Your streak reminders are on!', true,
          progress: 'Achievement unlocked!'));
    } else {
      lockedAchievements.add(_buildAchievementChip('🔒🎯', 'Locked-in', 'Your streak reminders are on!', false,
          progress: 'Enable streak reminders in settings'));
    }
    
    // Combine lists: unlocked first, then locked
    final List<Widget> achievements = [];
    achievements.addAll(unlockedAchievements);
    achievements.addAll(lockedAchievements);
    
    return achievements;
  }

  // Get social achievements based on lizzy and comment data from database
  Future<List<Widget>> _getSocialAchievementsAsync({bool forceRefresh = false}) async {
    final userService = Provider.of<UserService>(context, listen: false);
    final List<Widget> unlockedAchievements = [];
    final List<Widget> lockedAchievements = [];
    
    try {
      final prefs = await SharedPreferences.getInstance();
      
      // Check social data from database with daily caching
      final socialData = await _getSocialAchievementData(forceRefresh: forceRefresh);
      final maxLizzies = socialData['max_lizzies'] ?? 0;
      final totalLizzies = socialData['total_lizzies'] ?? 0;
      final commentsWithLizzies = socialData['comments_with_lizzies'] ?? 0;
      final questionsWithComments = socialData['questions_with_comments'] ?? 0;
      
      // Lizzy achievements (progressive - only show highest tier + next tier)
      final firstLizzyUnlocked = prefs.getBool('achievement_first_lizzy') ?? false;
      final dragonLizzyUnlocked = prefs.getBool('achievement_dragon_lizzy') ?? false;
      final dinoLizzyUnlocked = prefs.getBool('achievement_dino_lizzy') ?? false;
      
      final hasFirstLizzy = commentsWithLizzies > 0;
      final hasDragonLizzy = maxLizzies >= 10;
      final hasDinoLizzy = maxLizzies >= 50;
      
      // Set unlocked flags if conditions are met
      if (hasFirstLizzy && !firstLizzyUnlocked) {
        prefs.setBool('achievement_first_lizzy', true);
      }
      if (hasDragonLizzy && !dragonLizzyUnlocked) {
        prefs.setBool('achievement_dragon_lizzy', true);
      }
      if (hasDinoLizzy && !dinoLizzyUnlocked) {
        prefs.setBool('achievement_dino_lizzy', true);
      }
      
      // Progressive display: show highest unlocked + next tier
      if (dinoLizzyUnlocked || hasDinoLizzy) {
        // Show Dino Lizzy (highest tier)
        unlockedAchievements.add(_buildAchievementChip('🦎🦕', 'Dino Lizzy', 'Your comment got 50+ lizzies', true,
            progress: 'Highest: $maxLizzies lizzies'));
      } else if (dragonLizzyUnlocked || hasDragonLizzy) {
        // Show Dragon Lizzy (middle tier) and next tier
        unlockedAchievements.add(_buildAchievementChip('🦎🐉', 'Dragon Lizzy', 'Your comment got 10+ lizzies', true,
            progress: 'Highest: $maxLizzies lizzies'));
        unlockedAchievements.add(_buildAchievementChip('🦎🦕', 'Dino Lizzy', 'Your comment got 50+ lizzies', false,
            progress: 'Progress: $maxLizzies/50 lizzies'));
      } else if (firstLizzyUnlocked || hasFirstLizzy) {
        // Show First Lizzy (lowest tier) and next tier
        unlockedAchievements.add(_buildAchievementChip('🦎💬', 'First Lizzy', 'Your comment got lizzied', true,
            progress: 'Total lizzies: $totalLizzies'));
        unlockedAchievements.add(_buildAchievementChip('🦎🐉', 'Dragon Lizzy', 'Your comment got 10+ lizzies', false,
            progress: 'Progress: $maxLizzies/10 lizzies'));
      } else {
        // Show first tier only
        unlockedAchievements.add(_buildAchievementChip('🦎💬', 'First Lizzy', 'Your comment got lizzied', false,
            progress: 'Get your first lizzy on a comment'));
      }
      
      // Popcorn Time achievement (question received 5+ comments)
      final popcornTimeUnlocked = prefs.getBool('achievement_popcorn_time') ?? false;
      final hasPopcornTime = questionsWithComments > 0;
      
      if (popcornTimeUnlocked || hasPopcornTime) {
        if (!popcornTimeUnlocked && hasPopcornTime) {
          prefs.setBool('achievement_popcorn_time', true);
        }
        unlockedAchievements.add(_buildAchievementChip('🍿', 'Popcorn Time!', 'Your question received 5+ comments', true,
            progress: 'Achievement unlocked!'));
      } else {
        lockedAchievements.add(_buildAchievementChip('🍿', 'Popcorn Time!', 'Your question received 5+ comments', false,
            progress: 'Get 5+ comments on a question'));
      }
      
    } catch (e) {
      print('Error loading social achievements: $e');
      // Fallback to locked achievements if database check fails
      lockedAchievements.add(_buildAchievementChip('🦎💬', 'First Lizzy', 'Your comment got lizzied', false));
      lockedAchievements.add(_buildAchievementChip('🦎🐉', 'Dragon Lizzy', 'Your comment got 10+ lizzies', false));
      lockedAchievements.add(_buildAchievementChip('🦎🦕', 'Dino Lizzy', 'Your comment got 50+ lizzies', false));
      lockedAchievements.add(_buildAchievementChip('🍿', 'Popcorn Time!', 'Your question received 5+ comments', false));
    }
    
    // Combine lists: unlocked first, then locked
    final List<Widget> achievements = [];
    achievements.addAll(unlockedAchievements);
    achievements.addAll(lockedAchievements);
    
    return achievements;
  }

  // Get local community achievements based on city/country targeting data from database
  Future<List<Widget>> _getLocalCommunityAchievementsAsync({bool forceRefresh = false}) async {
    final userService = Provider.of<UserService>(context, listen: false);
    final List<Widget> unlockedAchievements = [];
    final List<Widget> lockedAchievements = [];
    
    // Get local community achievement data from database
    final localData = await _getLocalCommunityAchievementData(forceRefresh: forceRefresh);
    
    final cityQuestions = localData['city_questions'] ?? 0;
    final countryQuestions = localData['country_questions'] ?? 0;
    final uniqueCities = localData['unique_cities'] ?? 0;
    final uniqueCountries = localData['unique_countries'] ?? 0;
    
    // Planting the Seed: Posted first city-targeted question
    final plantingSeedUnlocked = await _isAchievementUnlocked('planting_seed') || cityQuestions > 0;
    if (plantingSeedUnlocked) {
      await _setAchievementUnlocked('planting_seed');
    }
    if (plantingSeedUnlocked) {
      unlockedAchievements.add(_buildAchievementChip('🏠', 'Asking My Neighbours', 'Posted your first city-targeted question', true,
          progress: 'Achievement unlocked!'));
    } else {
      lockedAchievements.add(_buildAchievementChip('🏠', 'Asking My Neighbours', 'Posted your first city-targeted question', false,
          progress: 'Post a city-targeted question'));
    }
    
    // Community Building: Posted 5+ city-targeted questions
    final communityBuildingUnlocked = await _isAchievementUnlocked('community_building') || cityQuestions >= 5;
    if (communityBuildingUnlocked) {
      await _setAchievementUnlocked('community_building');
    }
    if (plantingSeedUnlocked) {
      if (communityBuildingUnlocked) {
        unlockedAchievements.add(_buildAchievementChip('🏘️', 'Community Building', 'Posted 5+ city-targeted questions', true,
            progress: 'Achievement unlocked!'));
      } else {
        lockedAchievements.add(_buildAchievementChip('🏘️', 'Community Building', 'Posted 5+ city-targeted questions', false,
            progress: 'Post 5+ city-targeted questions'));
      }
    }
    
    // Local Legend: Posted questions in 3+ different cities
    final localLegendUnlocked = await _isAchievementUnlocked('local_legend') || uniqueCities >= 3;
    if (localLegendUnlocked) {
      await _setAchievementUnlocked('local_legend');
    }
    if (communityBuildingUnlocked) {
      if (localLegendUnlocked) {
        unlockedAchievements.add(_buildAchievementChip('🏆', 'Local Legend', 'Posted questions in 3+ different cities', true,
            progress: 'Achievement unlocked!'));
      } else {
        lockedAchievements.add(_buildAchievementChip('🏆', 'Local Legend', 'Posted questions in 3+ different cities', false,
            progress: 'Post questions in 3+ different cities'));
      }
    }
    
    // Country-targeted achievements (equivalent to city-targeted ones)
    
    // Global Seed: Posted first country-targeted question
    final globalSeedUnlocked = await _isAchievementUnlocked('global_seed') || countryQuestions > 0;
    if (globalSeedUnlocked) {
      await _setAchievementUnlocked('global_seed');
    }
    if (globalSeedUnlocked) {
      unlockedAchievements.add(_buildAchievementChip('🗺️', 'Global Seed', 'Posted your first country-targeted question', true,
          progress: 'Achievement unlocked!'));
    } else {
      lockedAchievements.add(_buildAchievementChip('🗺️', 'Global Seed', 'Posted your first country-targeted question', false,
          progress: 'Post a country-targeted question'));
    }
    
    // Global Community: Posted 5+ country-targeted questions
    final globalCommunityUnlocked = await _isAchievementUnlocked('global_community') || countryQuestions >= 5;
    if (globalCommunityUnlocked) {
      await _setAchievementUnlocked('global_community');
    }
    if (globalSeedUnlocked) {
      if (globalCommunityUnlocked) {
        unlockedAchievements.add(_buildAchievementChip('🇺🇳', 'Global Community', 'Posted 5+ country-targeted questions', true,
            progress: 'Achievement unlocked!'));
      } else {
        lockedAchievements.add(_buildAchievementChip('🇺🇳', 'Global Community', 'Posted 5+ country-targeted questions', false,
            progress: 'Post 5+ country-targeted questions'));
      }
    }
    
    // Combine lists: unlocked first, then locked
    final List<Widget> achievements = [];
    achievements.addAll(unlockedAchievements);
    achievements.addAll(lockedAchievements);
    
    return achievements;
  }

  // Helper method to get social achievement data from database with daily caching
  Future<Map<String, dynamic>> _getSocialAchievementData({bool forceRefresh = false}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final cacheKey = 'social_achievement_data';
      final cacheTimeKey = 'social_achievement_data_last_checked';
      
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
            print('Using cached social achievement data');
            final Map<String, dynamic> cached = Map<String, dynamic>.from(
              Uri.splitQueryString(cachedData).map((k, v) => MapEntry(k, int.tryParse(v) ?? 0))
            );
            return cached;
          }
        }
      }
      
      print('Fetching social achievement data from database');
      final userId = Supabase.instance.client.auth.currentUser?.id;
      if (userId == null) return {};
      
      // Query comments table for user's comments and their lizzy counts
      final commentsResponse = await Supabase.instance.client
          .from('comments')
          .select('id, upvote_lizard_count')
          .eq('author_id', userId);
      
      int maxLizzies = 0;
      int totalLizzies = 0;
      int commentsWithLizzies = 0;
      
      for (var comment in commentsResponse) {
        final lizzyCount = (comment['upvote_lizard_count'] ?? 0) as int;
        if (lizzyCount > 0) {
          commentsWithLizzies++;
          totalLizzies += lizzyCount;
          if (lizzyCount > maxLizzies) {
            maxLizzies = lizzyCount;
          }
        }
      }
      
      // Query for questions with 5+ comments
      int questionsWithComments = 0;
      for (var question in Provider.of<UserService>(context, listen: false).postedQuestions) {
        final questionId = question['id'];
        if (questionId != null) {
          final commentCountResponse = await Supabase.instance.client
              .from('comments')
              .select('id')
              .eq('question_id', questionId)
              .count(CountOption.exact);
          
          final commentCount = commentCountResponse.count ?? 0;
          if (commentCount >= 5) {
            questionsWithComments++;
          }
        }
      }
      
      final data = {
        'max_lizzies': maxLizzies,
        'total_lizzies': totalLizzies,
        'comments_with_lizzies': commentsWithLizzies,
        'questions_with_comments': questionsWithComments,
      };
      
      // Cache the results
      final cacheData = data.map((k, v) => MapEntry(k, v.toString()));
      await prefs.setString(cacheKey, Uri(queryParameters: cacheData).query);
      await prefs.setString(cacheTimeKey, DateTime.now().toIso8601String());
      
      return data;
    } catch (e) {
      print('Error fetching social achievement data: $e');
      return {};
    }
  }

  // Helper method to get local community achievement data from database with daily caching
  Future<Map<String, dynamic>> _getLocalCommunityAchievementData({bool forceRefresh = false}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final cacheKey = 'local_community_achievement_data';
      final cacheTimeKey = 'local_community_achievement_data_last_checked';
      
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
            print('Using cached local community achievement data');
            final parsedData = Uri.splitQueryString(cachedData);
            return parsedData.map((k, v) => MapEntry(k, int.tryParse(v) ?? 0));
          }
        }
      }
      
      print('Fetching local community achievement data from database');
      final userId = Supabase.instance.client.auth.currentUser?.id;
      if (userId == null) return {};
      
      // Query user's posted questions for city/country targeting data
      final questionsResponse = await Supabase.instance.client
          .from('questions')
          .select('id, city_id, country_code, targeting_type')
          .eq('author_id', userId);
      
      final questions = questionsResponse as List<dynamic>? ?? [];
      
      int cityQuestions = 0;
      int countryQuestions = 0;
      Set<String> uniqueCities = {};
      Set<String> uniqueCountries = {};
      
      for (var question in questions) {
        final cityId = question['city_id'];
        final countryCode = question['country_code'];
        final targetingType = question['targeting_type'];
        
        if (targetingType == 'city' && cityId != null) {
          cityQuestions++;
          uniqueCities.add(cityId.toString());
        } else if (targetingType == 'country' && countryCode != null) {
          countryQuestions++;
          uniqueCountries.add(countryCode.toString());
        }
      }
      
      final data = {
        'city_questions': cityQuestions,
        'country_questions': countryQuestions,
        'unique_cities': uniqueCities.length,
        'unique_countries': uniqueCountries.length,
      };
      
      // Cache the results
      final cacheData = data.map((k, v) => MapEntry(k, v.toString()));
      await prefs.setString(cacheKey, Uri(queryParameters: cacheData).query);
      await prefs.setString(cacheTimeKey, DateTime.now().toIso8601String());
      
      return data;
    } catch (e) {
      print('Error fetching local community achievement data: $e');
      return {};
    }
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

  Future<int> _getUnlockedAchievementsCountAsync() async {
    final userService = Provider.of<UserService>(context, listen: false);
    int count = 0;
    List<String> unlockedAchievements = []; // Debug list
    
    // Count only achievements we can actually verify
    
    // Question achievements
    if (userService.postedQuestions.isNotEmpty) {
      count++; // Not a lurker!
      unlockedAchievements.add('Not a lurker!');
    }
    
    // Answer achievements (progressive - only count highest achieved)
    // Use the same filtered count that appears in My Questions "Answered" section
    try {
      final questionService = Provider.of<QuestionService>(context, listen: false);
      final filteredAnsweredQuestions = await userService.getFilteredAnsweredQuestions(questionService);
      final answeredCount = filteredAnsweredQuestions.length;
      
      if (answeredCount >= 1000) {
        count++; // Answer Champion (1000+)
        unlockedAchievements.add('Answer Champion (1000+)');
      } else if (answeredCount >= 100) {
        count++; // Century Club (100+) 
        unlockedAchievements.add('Century Club (100+)');
      } else if (answeredCount >= 10) {
        count++; // Getting Started (10+)
        unlockedAchievements.add('Getting Started (10+)');
      }
    } catch (e) {
      // Fallback to raw count if filtering fails
      final answeredCount = userService.answeredQuestions.length;
      if (answeredCount >= 1000) {
        count++; // Answer Champion (1000+)
        unlockedAchievements.add('Answer Champion (1000+)');
      } else if (answeredCount >= 100) {
        count++; // Century Club (100+) 
        unlockedAchievements.add('Century Club (100+)');
      } else if (answeredCount >= 10) {
        count++; // Getting Started (10+)
        unlockedAchievements.add('Getting Started (10+)');
      }
    }
    
    // Question Hunter achievements - count each achievement by frequency
    int popularQuestionCount = 0;
    int viralQuestionCount = 0;
    
    for (var question in userService.postedQuestions) {
      final votes = question['votes'] ?? 0;
      if (votes >= 500) {
        viralQuestionCount++;
      } else if (votes >= 100) {
        popularQuestionCount++;
      }
    }
    
    count += popularQuestionCount; // Add each Popular Question achievement
    count += viralQuestionCount;   // Add each Viral Question achievement
    if (popularQuestionCount > 0) unlockedAchievements.add('Popular Question x$popularQuestionCount');
    if (viralQuestionCount > 0) unlockedAchievements.add('Viral Question x$viralQuestionCount');
    
    // Birthday Buddy (check if any question posted in November or permanently unlocked)
    if (await _isAchievementUnlocked('birthday_buddy') || _checkBirthdayBuddy(userService)) {
      count++; // Birthday Buddy
      unlockedAchievements.add('Birthday Buddy');
    }
    
    // Room achievements (check SharedPreferences for permanently unlocked ones)
    // Use the actual SharedPreferences keys with 'achievement_' prefix
    if (await _isAchievementUnlocked('youre_invited')) {
      count++;
    }
    if (await _isAchievementUnlocked('room_founder')) {
      count++;
    }
    if (await _isAchievementUnlocked('turned_the_key')) {
      count++;
    }
    if (await _isAchievementUnlocked('networker')) {
      count++;
    }
    
    // Room ranking achievements
    try {
      final roomRankings = await _checkRoomRankings();
      if (roomRankings['hasRank1Room'] == true) count++;
      if (roomRankings['hasRank2Room'] == true) count++;
      if (roomRankings['hasRank3Room'] == true) count++;
      if (roomRankings['hasTop10Room'] == true) count++;
    } catch (e) {
      // Skip room ranking if check fails
    }
    
    // Community achievements (Alpha, Beta, Hatchling always unlocked if authenticated)
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId != null) {
      count++; // Hatchling (always unlocked)
      
      // Check cached Alpha/Beta status
      if (await _isAchievementUnlocked('alpha_tester')) {
        count++;
      }
      if (await _isAchievementUnlocked('beta_tester')) {
        count++;
      }
    }
    
    // Local Community achievements
    final localAchievements = ['planting_seed', 'community_building', 'local_legend', 'global_seed', 'global_community', 'international_legend'];
    for (var achievement in localAchievements) {
      if (await _isAchievementUnlocked(achievement)) {
        count++;
      }
    }
    
    // Social achievements (progressive - only count highest lizzy tier)
    if (await _isAchievementUnlocked('dino_lizzy')) {
      count++; // Dino Lizzy (highest tier)
    } else if (await _isAchievementUnlocked('dragon_lizzy')) {
      count++; // Dragon Lizzy (middle tier)
    } else if (await _isAchievementUnlocked('first_lizzy')) {
      count++; // First Lizzy (lowest tier)
    }
    
    // Popcorn Time (separate achievement)
    if (await _isAchievementUnlocked('popcorn_time')) {
      count++;
    }
    
    // QOTD Star achievement - count each QOTD
    if (await _isAchievementUnlocked('qotd_star')) {
      try {
        final qotdCount = await _getQotdCount();
        count += qotdCount; // Add each QOTD achievement
        unlockedAchievements.add('QOTD Star x$qotdCount');
      } catch (e) {
        count++; // Fallback to 1 if count fails
        unlockedAchievements.add('QOTD Star (fallback)');
      }
    }
    
    // Notification badge ("Call me, beep me")
    if (userService.notifyResponses) {
      count++;
    }
    
    // Debug logging: Print all counted achievements
    // print('DEBUG: Badge count calculation:');  // Commented out excessive logging
    // print('Total count: $count');  // Commented out excessive logging
    // print('Unlocked achievements: ${unlockedAchievements.join(', ')}');  // Commented out excessive logging
    
    return count;
  }

  // Helper method to check if an achievement is unlocked in SharedPreferences
  Future<bool> _isAchievementUnlocked(String achievementKey) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool('achievement_$achievementKey') ?? false;
  }

  // Helper method to set an achievement as unlocked in SharedPreferences
  Future<void> _setAchievementUnlocked(String achievementKey) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('achievement_$achievementKey', true);
  }

  // Helper method to check if user has had a question as Question of the Day
  Future<bool> _hasQuestionBeenQotd({bool forceRefresh = false}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final cacheKey = 'qotd_achievement_check';
      final cacheTimeKey = 'qotd_achievement_check_last_checked';
      
      // Check cache first (unless force refresh)
      if (!forceRefresh) {
        final cachedResult = prefs.getBool(cacheKey);
        final lastChecked = prefs.getString(cacheTimeKey);
        
        if (cachedResult != null && lastChecked != null) {
          final lastCheckedDate = DateTime.parse(lastChecked);
          final now = DateTime.now();
          
          // Use cache if checked today (same day)
          if (lastCheckedDate.year == now.year && 
              lastCheckedDate.month == now.month && 
              lastCheckedDate.day == now.day) {
            print('Using cached QOTD achievement check: $cachedResult');
            return cachedResult;
          }
        }
      }
      
      print('Checking database for user QOTD history');
      final userId = Supabase.instance.client.auth.currentUser?.id;
      if (userId == null) return false;
      
      // Query question_of_the_day_history table to see if any of user's questions were featured
      final qotdResponse = await Supabase.instance.client
          .from('question_of_the_day_history')
          .select('question_id, questions!inner(author_id)')
          .eq('questions.author_id', userId)
          .limit(1);
      
      final hasBeenQotd = qotdResponse.isNotEmpty;
      
      // Cache the result with daily expiration
      await prefs.setBool(cacheKey, hasBeenQotd);
      await prefs.setString(cacheTimeKey, DateTime.now().toIso8601String());
      
      print('QOTD achievement check result: $hasBeenQotd');
      return hasBeenQotd;
    } catch (e) {
      print('Error checking QOTD achievement: $e');
      return false; // Default to locked if there's an error
    }
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

  Future<int> _getQotdCount({bool forceRefresh = false}) async {
    final qotdData = await _getQotdData(forceRefresh: forceRefresh);
    return qotdData['count'] as int;
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
    final currentStreak = _calculateCurrentStreak(userService.answeredQuestions);
    final longestStreak = await _getLongestAnswerStreak();
    final hasExtendedStreakToday = _hasExtendedStreakToday(userService.answeredQuestions);
    final streakRank = userService.streakRank;
    final isTopTen = userService.isTopTenStreak;

    // Update longest streak if current is longer
    if (currentStreak > longestStreak) {
      await _saveLongestAnswerStreak(currentStreak);
    }

    final isRecord = currentStreak > 0 && currentStreak >= longestStreak;
    final showRainbow = isTopTen || currentStreak > 100;

    // Check if we should show urgent message
    final streakColor = _getStreakCardColor(context, hasExtendedStreakToday);
    final shouldShowUrgent = _shouldStreakCardPulse(hasExtendedStreakToday) ||
                            streakColor == Color(0xffea6d32); // Red or orange

    final dialogBorder = _getStreakDialogBorderDecoration(currentStreak, isTopTen: isTopTen);

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
                  SizedBox(height: 8),
                  Container(
                    padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: isTopTen
                          ? Theme.of(context).primaryColor.withOpacity(0.1)
                          : Theme.of(context).cardColor,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: isTopTen
                            ? Theme.of(context).primaryColor.withOpacity(0.3)
                            : Theme.of(context).dividerColor,
                      ),
                    ),
                    child: Text(
                      isTopTen
                          ? '🔥 #$streakRank among all active streaks!'
                          : 'Ranked #$streakRank among all active streaks',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        fontWeight: isTopTen ? FontWeight.w600 : null,
                        color: isTopTen ? Theme.of(context).primaryColor : null,
                      ),
                    ),
                  ),
                ],
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
                                      'Get reminded if you haven\'t answered today. Reminder time can be customized in Settings.',
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

                                  // Show brief feedback
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text('Streak reminders enabled! 🔥 Adjust reminder times in Settings.'),
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
                // Explanation text at bottom
                Text(
                  'A streak is the number of consecutive days that you\'ve answered at least one question.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Colors.grey[600],
                  ),
                  textAlign: TextAlign.center,
                ),
                SizedBox(height: 16),
                // Widget suggestion
                GestureDetector(
                  onTap: () async {
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
                            'Did you know? You can add the Curio widget to your home screen to quietly support the platform.',
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
                  'This is the average rating chameleons give your questions.',
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
                if (hasCqi && camoQuality > 0.5) ...[
                  Text(
                    'Your questions are highly rated!',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).primaryColor,
                      fontWeight: FontWeight.w600,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  SizedBox(height: 16),
                ] else if (hasCqi && camoQuality > 0.0) ...[
                  Text(
                    'Your questions are well-received!',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).primaryColor,
                      fontWeight: FontWeight.w600,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  SizedBox(height: 16),
                ],
                Text(
                  'The CQI measures how chameleons rate your questions on average, from -1 (negative) to 1 (positive).',
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

  // Get special dialog border decoration for top 10 or 100+ day streaks
  BoxDecoration? _getStreakDialogBorderDecoration(int currentStreak, {bool isTopTen = false}) {
    // Rainbow border for top 10 leaderboard OR 100+ day streaks
    if (isTopTen || currentStreak > 100) {
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
      allQuestions.addAll(userService.savedQuestions);
      
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
      allUserQuestions.addAll(userService.savedQuestions);
      
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
