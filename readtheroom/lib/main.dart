// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

// lib/main.dart
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'firebase_options.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'src/screens/main_screen.dart';
import 'src/screens/about_screen.dart';
import 'src/screens/authentication_screen.dart';
import 'src/screens/settings_screen.dart';
import 'src/screens/new_question_screen.dart';
import 'src/screens/feedback_screen.dart';
import 'src/screens/guide_screen.dart';
import 'src/screens/platform_stats_screen.dart';
import 'src/screens/onboarding_screen.dart';
import 'src/services/user_service.dart';
import 'src/services/location_service.dart';
import 'src/services/question_service.dart';
import 'src/services/notification_service.dart';
import 'src/services/streak_reminder_service.dart';
import 'src/services/qotd_reminder_service.dart';
import 'src/services/deep_link_service.dart';
import 'src/services/watchlist_service.dart';
import 'src/services/suggestion_watchlist_service.dart';
import 'src/services/theme_service.dart';
import 'src/services/temporary_category_filter_notifier.dart';
import 'src/services/temporary_review_filter_notifier.dart';
import 'src/services/navigation_visibility_notifier.dart';
import 'src/services/question_cache_service.dart';
import 'src/services/guest_user_tracking_service.dart';
import 'src/services/boost_service.dart';
import 'src/services/initialization_coordinator.dart';
import 'src/services/analytics_service.dart';
import 'src/services/analytics_navigation_observer.dart';
import 'src/services/home_widget_service.dart';
import 'src/services/qotd_background_service.dart';
import 'src/utils/haptic_utils.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:timezone/timezone.dart' as tz;
import 'package:flutter_timezone/flutter_timezone.dart';

// Background message handler - must be at top level
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  // Ensure Firebase is initialized
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  
  print('🦎 FCM: Received background message - type: ${message.data['type']}');
  
  if (message.data['type'] == 'q_subscribed_activity') {
    // Handle subscribed activity ping when app is in background
    await _processSubscribedActivityInBackground(message);
  }
}

// Process subscribed activity using only SharedPreferences (no Supabase needed)
Future<void> _processSubscribedActivityInBackground(RemoteMessage message) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    
    // Check if the Edge Function provided vote count data
    final voteCountData = message.data['response_counts'];
    
    if (voteCountData != null) {
      // Edge Function provided vote counts - process immediately
      print('🦎 Q-activity: Processing vote counts from Edge Function');
      await _processVoteCountsFromEdgeFunction(voteCountData);
    } else {
      // Fallback: store timestamp for foreground processing
      await prefs.setString('last_subscribed_activity_ping', DateTime.now().toIso8601String());
      print('🦎 Q-activity: Background ping received and timestamp stored');
      print('🦎 Q-activity: Processing will occur when app comes to foreground');
    }
  } catch (e) {
    print('🦎 Q-activity: Error in background processing: $e');
  }
}

// Process vote counts provided by Edge Function
Future<void> _processVoteCountsFromEdgeFunction(String voteCountData) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final watchlistJson = prefs.getString('question_watchlist');
    
    if (watchlistJson == null) {
      print('🦎 Q-activity: No watchlist found in background processing');
      return;
    }

    final Map<String, dynamic> watchlist = json.decode(watchlistJson);
    final Map<String, dynamic> voteCounts = json.decode(voteCountData);
    
    print('🦎 Q-activity: Processing ${watchlist.length} subscribed questions with ${voteCounts.length} vote counts');
    print('🦎 Q-activity: Vote counts from Edge Function: $voteCounts');
    
    int notificationsShown = 0;
    
    // Find the question with the largest vote increase
    String? bestQuestionId;
    int bestVoteIncrease = 0;
    String bestQuestionTitle = 'Your subscribed question';
    
    for (final questionId in watchlist.keys) {
      final entry = watchlist[questionId];
      final currentVoteCount = voteCounts[questionId] ?? 0;
      
      // Get last viewed vote count from SharedPreferences (same as user_screen.dart)
      final key = 'question_view_$questionId';
      final data = prefs.getString(key);
      int? lastViewedVotes;
      if (data != null) {
        final parts = data.split(':');
        if (parts.length == 2) {
          lastViewedVotes = int.tryParse(parts[1]);
        }
      }
      
      // Calculate vote increase based on last viewed (not last notified)
      final voteIncrease = (lastViewedVotes != null) ? (currentVoteCount - lastViewedVotes) : 0;
      
      print('🦎 Q-activity: Question $questionId - last viewed: $lastViewedVotes, current: $currentVoteCount, increase: $voteIncrease');
      
      if (voteIncrease > 0) {
        // Check if we should notify based on time since last notification
        final lastNotified = entry['last_notified_at'] != null 
            ? DateTime.parse(entry['last_notified_at'])
            : DateTime.now().subtract(Duration(hours: 3)); // Default to 3 hours ago if never notified
        final neverNotified = entry['never_notified'] == true;
        
        final timeSince = DateTime.now().difference(lastNotified);
        final percentChange = lastViewedVotes != null && lastViewedVotes > 0 
            ? voteIncrease / lastViewedVotes 
            : (currentVoteCount > 0 ? 1.0 : 0.0);
        
        // Notification conditions: 3hr cooldown AND (>10 new votes OR >30% change)
        final timeCondition = neverNotified || timeSince >= Duration(hours: 3);

        final significantPercentage = percentChange > 0.30; // 30% change from last viewed
        final meaningfulVoteIncrease = voteIncrease > 10; // More than 10 new votes

        final activityCondition = significantPercentage || meaningfulVoteIncrease;

        print('🦎 Q-activity: Background check for $questionId: time=$timeCondition (${timeSince.inMinutes}m), activity=$activityCondition (${(percentChange * 100).toStringAsFixed(1)}%, +$voteIncrease votes)');
        print('🦎 Q-activity: Conditions - significantPercentage(>30%): $significantPercentage, meaningfulVoteIncrease(>10): $meaningfulVoteIncrease');
        
        if (timeCondition && activityCondition) {
          // Track the best question (largest vote increase)
          if (voteIncrease > bestVoteIncrease) {
            bestVoteIncrease = voteIncrease;
            bestQuestionId = questionId;
            
            // Fetch question title for the best question
            try {
              final supabase = Supabase.instance.client;
              final response = await supabase
                  .from('questions')
                  .select('prompt, title')
                  .eq('id', questionId)
                  .maybeSingle();
              
              if (response != null) {
                bestQuestionTitle = response['title'] ?? response['prompt'] ?? 'Your subscribed question';
                // Truncate if too long for notification
                if (bestQuestionTitle.length > 50) {
                  bestQuestionTitle = bestQuestionTitle.substring(0, 47) + '...';
                }
              }
            } catch (e) {
              print('🦎 Q-activity: Error fetching question title: $e');
            }
          }
        } else {
          print('🦎 Q-activity: ❌ No notification for $questionId - timeCondition: $timeCondition, activityCondition: $activityCondition');
        }
      } else {
        print('🦎 Q-activity: No vote increase for question $questionId (increase: $voteIncrease)');
      }
    }
    
    // Show notification only for the best question (largest vote increase)
    if (bestQuestionId != null && bestVoteIncrease > 0) {
      print('🦎 Q-activity: 🏆 Best question for notification: $bestQuestionId with +$bestVoteIncrease votes');
      
      // Show local notification with real question title and vote count
      await _showLocalNotificationInBackground(
        title: '🦎 Chameleons are biting!',
        body: '$bestQuestionTitle got $bestVoteIncrease new responses!',
        payload: 'question_$bestQuestionId',
      );
      
      // Update the watchlist entry for the best question (keep track of notification timing)
      final bestEntry = watchlist[bestQuestionId];
      bestEntry['last_vote_count'] = voteCounts[bestQuestionId] ?? 0;
      bestEntry['last_notified_at'] = DateTime.now().toIso8601String();
      bestEntry['never_notified'] = false;
      
      notificationsShown++;
      print('🦎 Q-activity: ✅ Notification shown for best question $bestQuestionId');
    } else {
      print('🦎 Q-activity: No qualifying questions for notification');
    }
    
    // Save updated watchlist
    await prefs.setString('question_watchlist', json.encode(watchlist));
    
    print('🦎 Q-activity: Background processing completed - $notificationsShown notifications shown');
  } catch (e) {
    print('🦎 Q-activity: Error processing vote counts from Edge Function: $e');
  }
}

// Show local notification in background context
Future<void> _showLocalNotificationInBackground({
  required String title,
  required String body,
  required String payload,
}) async {
  try {
    // Initialize local notifications for background context
    const initializationSettingsAndroid = AndroidInitializationSettings('@mipmap/ic_launcher');
    const initializationSettingsIOS = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    const initializationSettings = InitializationSettings(
      android: initializationSettingsAndroid,
      iOS: initializationSettingsIOS,
    );

    final localNotifications = FlutterLocalNotificationsPlugin();
    await localNotifications.initialize(
      initializationSettings,
      onDidReceiveNotificationResponse: _onBackgroundNotificationTap,
    );
    
    // Show the notification
    const androidDetails = AndroidNotificationDetails(
      'question_activity_channel', // Match the channel used in notification service
      'Question Activity',
      channelDescription: 'Silent notifications for activity on subscribed questions',
      importance: Importance.low, // Silent: no buzz, just visual notification
      priority: Priority.high, // High priority: wakes screen, shows immediately
      icon: 'ic_stat_rtr_logo_aug2025',
      playSound: false, // No sound
      enableVibration: false, // No vibration
      silent: true, // Explicitly silent
      // Additional customization options:
      // sound: RawResourceAndroidNotificationSound('notification_sound'), // Custom sound
      // vibrationPattern: Int64List.fromList([0, 500, 200, 500]), // Custom vibration pattern
      // enableLights: true, // Enable LED light
      // ledColor: Color(0xFF00897B), // Custom LED color
    );
    
    const iosDetails = DarwinNotificationDetails(
      // iOS customization options:
      // presentAlert: true, // Show alert
      // presentBadge: true, // Show badge
      // presentSound: true, // Play sound
      // sound: 'notification_sound.aiff', // Custom sound
    );
    
    const details = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
    );
    
    await localNotifications.show(
      DateTime.now().millisecondsSinceEpoch ~/ 1000,
      title,
      body,
      details,
      payload: payload,
    );
    
    print('🦎 Q-activity: Background notification shown: $title');
  } catch (e) {
    print('🦎 Q-activity: Error showing background notification: $e');
  }
}

// Handle notification tap in background context
void _onBackgroundNotificationTap(NotificationResponse response) {
  // Handle notification tap
  if (response.payload != null) {
    print('🦎 Q-activity: Background notification tapped with payload: ${response.payload}');
    
    // Check if it's a question notification
    if (response.payload!.startsWith('question_')) {
      final questionId = response.payload!.substring('question_'.length);
      print('🦎 Q-activity: Opening question from background notification: $questionId');
      
      // Store the question ID for navigation when app context is available
      // This will be handled by the main app's _checkPendingNotificationNavigation method
      _storePendingQuestionNavigation(questionId);
    }
  }
}

// Store pending question navigation for background notifications
void _storePendingQuestionNavigation(String questionId) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('pending_question_navigation', questionId);
    print('🦎 Q-activity: Stored pending question navigation: $questionId');
  } catch (e) {
    print('🦎 Q-activity: Error storing pending question navigation: $e');
  }
}


void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Initialize timezone data for local notifications  
  tz.initializeTimeZones();
  
  // Get device timezone using flutter_timezone plugin
  try {
    print('🕐 MAIN: Getting device timezone...');
    print('🕐 MAIN: System timezone offset: ${DateTime.now().timeZoneOffset}');
    
    // Get the actual device timezone name (e.g., "Asia/Muscat", "America/New_York")
    final String deviceTimezoneName = await FlutterTimezone.getLocalTimezone();
    print('🕐 MAIN: Device timezone: $deviceTimezoneName');
    
    // Set the timezone location
    final location = tz.getLocation(deviceTimezoneName);
    tz.setLocalLocation(location);
    
    print('✅ MAIN: Timezone set to: $deviceTimezoneName');
    print('🕐 MAIN: Current local time: ${tz.TZDateTime.now(tz.local)}');
    print('🕐 MAIN: Timezone offset: ${tz.TZDateTime.now(tz.local).timeZoneOffset}');
    
  } catch (e) {
    print('❌ MAIN: Error getting device timezone: $e');
    print('🕐 MAIN: Falling back to UTC');
    // Keep UTC as absolute fallback - better than crashing
    try {
      tz.setLocalLocation(tz.UTC);
      print('✅ MAIN: Fallback timezone set to UTC');
    } catch (fallbackError) {
      print('❌ MAIN: Critical timezone error: $fallbackError');
    }
  }
  
  // Initialize Supabase
  await Supabase.initialize(
    url: const String.fromEnvironment('SUPABASE_URL'),
    anonKey: const String.fromEnvironment('SUPABASE_ANON_KEY'),
  );
  
  // Initialize Firebase with generated options
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  
  // Register background message handler
  FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
  
  // Initialize analytics
  final analyticsService = AnalyticsService();
  await analyticsService.initialize();

  // Initialize home widget service
  final homeWidgetService = HomeWidgetService();
  await homeWidgetService.initialize();

  // Initialize QOTD background refresh service (Android only)
  // iOS uses native BGTaskScheduler configured in AppDelegate.swift
  await QOTDBackgroundService.initialize();

  // Initialize haptic feedback (checks vibrator availability on Android)
  await AppHaptics.init();

  // Create services (but don't initialize them yet)
  final notificationService = NotificationService();
  print('🦎 MAIN: Created NotificationService instance ${identityHashCode(notificationService)}');
  final streakReminderService = StreakReminderService();
  final qotdReminderService = QOTDReminderService();
  print('🦎 MAIN: Created StreakReminderService and QOTDReminderService instances');
  final questionService = QuestionService();
  final watchlistService = WatchlistService();
  final suggestionWatchlistService = SuggestionWatchlistService();
  final userService = UserService();
  final themeService = ThemeService();
  final cacheService = QuestionCacheService();
  final locationService = LocationService(); // Create LocationService here to ensure initialization
  print('🦎 MAIN: Created LocationService instance ${identityHashCode(locationService)}');
  
  // Use initialization coordinator to sequence service startup
  final coordinator = InitializationCoordinator();
  await coordinator.initializeServices(
    initializeUserService: () async {
      await userService.waitForInitialization();
    },
    initializeLocationService: () async {
      await locationService.initialize();
    },
    initializeQuestionService: () async {
      // QuestionService is initialized via Provider, but cache service needs setup
      cacheService.initialize(questionService);
    },
    initializeWatchlistService: () async {
      await watchlistService.initialize();
      await suggestionWatchlistService.initialize();
    },
    initializeNotificationService: () async {
      await notificationService.initialize();
      await streakReminderService.initialize();
      await qotdReminderService.initialize();
    },
    initializeDeepLinkService: () async {
      // DeepLinkService is initialized in the widget tree
    },
  );
  
  // Verify all services are non-null before starting the app
  print('🦎 MAIN: Verifying services before starting app...');
  print('🦎 MAIN: locationService null? ${locationService == null}');
  print('🦎 MAIN: locationService type: ${locationService.runtimeType}');
  
  runApp(ReadTheRoomApp(
    questionService: questionService,
    watchlistService: watchlistService,
    suggestionWatchlistService: suggestionWatchlistService,
    userService: userService,
    themeService: themeService,
    locationService: locationService,
  ));
}

class ReadTheRoomApp extends StatefulWidget {
  final QuestionService questionService;
  final WatchlistService watchlistService;
  final SuggestionWatchlistService suggestionWatchlistService;
  final UserService userService;
  final ThemeService themeService;
  final LocationService? locationService; // Make nullable temporarily to debug
  
  const ReadTheRoomApp({
    Key? key, 
    required this.questionService,
    required this.watchlistService,
    required this.suggestionWatchlistService,
    required this.userService,
    required this.themeService,
    this.locationService, // Make optional temporarily
  }) : super(key: key);

  @override
  _ReadTheRoomAppState createState() => _ReadTheRoomAppState();
}

class _ReadTheRoomAppState extends State<ReadTheRoomApp> with WidgetsBindingObserver {
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  late DeepLinkService _deepLinkService;
  
  // BUG FIX: Cache onboarding status to prevent users being sent back to onboarding inappropriately
  // Issue: FutureBuilder re-checks SharedPreferences on every rebuild (e.g., when tapping home button)
  // If SharedPreferences read fails or returns unexpected false, user gets sent back to onboarding
  // Solution: Cache the result after first successful check to prevent repeated evaluations
  bool? _cachedOnboardingStatus;
  bool _hasCheckedOnboarding = false;

  @override
  void initState() {
    super.initState();
    _deepLinkService = DeepLinkService();
    
    // Add lifecycle observer to handle app state changes
    WidgetsBinding.instance.addObserver(this);
    
    // Track app opened
    AnalyticsService().trackAppOpened();
    
    // Initialize deep links after the widget tree is built
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_navigatorKey.currentContext != null) {
        _deepLinkService.initialize(_navigatorKey.currentContext!);
        // Check FCM initial message for cold-start notification taps
        NotificationService().checkInitialFCMMessage().then((_) {
          _checkPendingNotificationNavigation();
        });
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _deepLinkService.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);

    // Track app lifecycle events
    final analytics = AnalyticsService();
    switch (state) {
      case AppLifecycleState.resumed:
        analytics.trackAppResumed();
        print('🦎 MAIN APP: App resumed - checking for pending notification navigation');
        // Small delay to ensure context is ready
        Future.delayed(Duration(milliseconds: 100), () {
          _checkPendingNotificationNavigation();
        });
        // Refresh QOTD widget data on app resume
        _refreshQOTDWidgetOnResume();
        break;
      case AppLifecycleState.paused:
        analytics.trackAppBackgrounded();
        break;
      default:
        break;
    }
  }

  /// Refresh QOTD widget data when app resumes from background.
  /// This ensures the widget always shows current vote/comment counts
  /// when the user unlocks their phone, even if background refresh failed.
  void _refreshQOTDWidgetOnResume() async {
    try {
      print('🦎 MAIN APP: Refreshing QOTD widget on resume...');

      final supabase = Supabase.instance.client;
      final now = DateTime.now();
      final dateKey = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';

      // Fetch current QOTD from server
      final result = await supabase
          .from('question_of_the_day_history')
          .select('''
            question_id,
            questions!inner(
              id,
              prompt,
              is_hidden
            )
          ''')
          .eq('date', dateKey)
          .maybeSingle();

      if (result != null && result['questions'] != null) {
        final question = result['questions'];
        final questionId = question['id']?.toString();

        if (question['is_hidden'] != true && questionId != null) {
          // Fetch vote count from responses table
          final voteCountQuery = await supabase
              .from('responses')
              .select('id')
              .eq('question_id', questionId);
          final voteCount = voteCountQuery.length;

          // Fetch comment count from comments table
          final commentCountQuery = await supabase
              .from('comments')
              .select('id')
              .eq('question_id', questionId);
          final commentCount = commentCountQuery.length;

          // Check if user has answered this question
          bool hasAnswered = false;
          final userId = supabase.auth.currentUser?.id;
          if (userId != null) {
            final responseCheck = await supabase
                .from('responses')
                .select('id')
                .eq('question_id', questionId)
                .eq('user_id', userId)
                .maybeSingle();
            hasAnswered = responseCheck != null;
          }

          // Update widget with fresh data
          await HomeWidgetService().updateQOTDWidget(
            questionText: question['prompt']?.toString() ?? '',
            voteCount: voteCount,
            commentCount: commentCount,
            hasAnswered: hasAnswered,
            questionId: questionId,
          );

          print('🦎 MAIN APP: QOTD widget refreshed on resume: votes=$voteCount, comments=$commentCount');
        }
      }
    } catch (e) {
      print('🦎 MAIN APP: Error refreshing QOTD widget on resume: $e');
    }
  }

  void _checkPendingNotificationNavigation() {
    print('🦎 MAIN APP: Checking for pending notification navigation...');
    final notificationService = NotificationService(); // This now gets the singleton instance
    print('🦎 MAIN APP: Using NotificationService instance ${identityHashCode(notificationService)}');
    
    // Check for pending question navigation
    final pendingQuestionId = notificationService.getPendingQuestionNavigation();
    // Check for pending suggestion navigation  
    final pendingSuggestionId = notificationService.getPendingSuggestionNavigation();
    
    if (pendingQuestionId != null) {
      final context = _navigatorKey.currentContext;
      if (context != null) {
        print('🦎 MAIN APP: ✅ Handling pending notification navigation to question: $pendingQuestionId');
        print('🦎 MAIN APP: Context available, proceeding with deep link navigation');
        
        // Use deep link service to navigate to the question
        final uri = Uri.parse('readtheroom://question/$pendingQuestionId');
        print('🦎 MAIN APP: Created deep link URI: $uri');
        
        _deepLinkService.handleIncomingLink(context, uri).then((_) {
          print('🦎 MAIN APP: ✅ Deep link navigation completed successfully');
        }).catchError((e) {
          print('🦎 MAIN APP: ❌ Error navigating from notification: $e');
          print('🦎 MAIN APP: Error type: ${e.runtimeType}');
          print('🦎 MAIN APP: Error details: ${e.toString()}');
          
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Error opening question from notification: ${e.toString()}'),
                backgroundColor: Colors.red,
                duration: Duration(seconds: 5),
                action: SnackBarAction(
                  label: 'Retry',
                  onPressed: () {
                    print('🦎 MAIN APP: User requested retry for question: $pendingQuestionId');
                    _deepLinkService.handleIncomingLink(context, uri);
                  },
                ),
              ),
            );
          }
        });
      } else {
        print('🦎 MAIN APP: ❌ No context available for navigation, question will be lost: $pendingQuestionId');
        print('🦎 MAIN APP: This should not happen - context should be available after app initialization');
      }
    } else if (pendingSuggestionId != null) {
      final context = _navigatorKey.currentContext;
      if (context != null) {
        print('🦎 MAIN APP: ✅ Handling pending notification navigation to suggestion: $pendingSuggestionId');
        print('🦎 MAIN APP: Context available, proceeding with deep link navigation');
        
        // Use deep link service to navigate to the suggestion
        final uri = Uri.parse('readtheroom://suggestion/$pendingSuggestionId');
        print('🦎 MAIN APP: Created deep link URI: $uri');
        
        _deepLinkService.handleIncomingLink(context, uri).then((_) {
          print('🦎 MAIN APP: ✅ Deep link navigation completed successfully');
        }).catchError((e) {
          print('🦎 MAIN APP: ❌ Error navigating from notification: $e');
          print('🦎 MAIN APP: Error type: ${e.runtimeType}');
          print('🦎 MAIN APP: Error details: ${e.toString()}');
          
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Error opening suggestion from notification: ${e.toString()}'),
                backgroundColor: Colors.red,
                duration: Duration(seconds: 5),
                action: SnackBarAction(
                  label: 'Retry',
                  onPressed: () {
                    print('🦎 MAIN APP: User requested retry for suggestion: $pendingSuggestionId');
                    _deepLinkService.handleIncomingLink(context, uri);
                  },
                ),
              ),
            );
          }
        });
      } else {
        print('🦎 MAIN APP: ❌ No context available for navigation, suggestion will be lost: $pendingSuggestionId');
        print('🦎 MAIN APP: This should not happen - context should be available after app initialization');
      }
    } else {
      print('🦎 MAIN APP: No pending foreground notification navigation');
      // Check for background notification navigation
      _checkBackgroundNotificationNavigation();
    }
  }
  
  // Mark onboarding as completed (called from onboarding screen)
  // This updates the cache to prevent any future checks from returning false
  void markOnboardingCompleted() {
    print('🦎 MAIN: markOnboardingCompleted() - Updating cached status to true');
    _cachedOnboardingStatus = true;
    _hasCheckedOnboarding = true;
  }
  
  // Check if onboarding has been completed
  // BUG FIX: Uses caching to prevent repeated SharedPreferences reads that could cause
  // users to be inappropriately sent back to onboarding screen on app rebuilds
  Future<bool> _checkOnboardingCompleted() async {
    // Return cached value if we've already checked - this prevents repeated evaluations
    // that could fail and incorrectly send completed users back to onboarding
    if (_hasCheckedOnboarding && _cachedOnboardingStatus != null) {
      print('🦎 MAIN: _checkOnboardingCompleted() - Using cached value: $_cachedOnboardingStatus');
      return _cachedOnboardingStatus!;
    }
    
    try {
      print('🦎 MAIN: _checkOnboardingCompleted() - Getting SharedPreferences (first time check)...');
      final prefs = await SharedPreferences.getInstance();
      final result = prefs.getBool('onboarding_completed') ?? false;
      final completedAt = prefs.getString('onboarding_completed_at');
      
      print('🦎 MAIN: _checkOnboardingCompleted() - onboarding_completed = $result, completed_at = $completedAt');
      print('🦎 MAIN: _checkOnboardingCompleted() - SharedPreferences keys: ${prefs.getKeys()}');
      
      // Cache the result to prevent repeated checks that could cause inappropriate onboarding returns
      _cachedOnboardingStatus = result;
      _hasCheckedOnboarding = true;
      
      // If onboarding is completed, we should never show onboarding screen again in this session
      // This cache persists for the entire app session to prevent navigation bugs
      if (result) {
        print('🦎 MAIN: ✅ Onboarding completed - caching result to prevent future checks');
      } else {
        print('🦎 MAIN: ❌ Onboarding not completed - showing onboarding screen');
      }
      
      return result;
    } catch (e) {
      print('🦎 MAIN: ❌ Error checking onboarding completion: $e');
      print('🦎 MAIN: Error type: ${e.runtimeType}');
      print('🦎 MAIN: Error details: ${e.toString()}');
      
      // Cache false to prevent repeated errors, but don't mark as checked
      // This allows retry on next app restart while preventing error loops in current session
      _cachedOnboardingStatus = false;
      return false; // Default to showing onboarding if there's an error
    }
  }

  // Check for background notification navigation stored in SharedPreferences
  void _checkBackgroundNotificationNavigation() async {
    print('🦎 MAIN APP: Checking for background notification navigation...');
    try {
      final prefs = await SharedPreferences.getInstance();
      final pendingQuestionId = prefs.getString('pending_question_navigation');
      final pendingSuggestionId = prefs.getString('pending_suggestion_navigation');

      if (pendingQuestionId != null) {
        print('🦎 MAIN APP: ✅ Found background question navigation: $pendingQuestionId');
        await prefs.remove('pending_question_navigation');

        final context = _navigatorKey.currentContext;
        if (context != null) {
          final uri = Uri.parse('readtheroom://question/$pendingQuestionId');
          _deepLinkService.handleIncomingLink(context, uri).then((_) {
            print('🦎 MAIN APP: ✅ Background deep link navigation completed');
          }).catchError((e) {
            print('🦎 MAIN APP: ❌ Error navigating from background notification: $e');
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('Error opening question. Please try again.'),
                  backgroundColor: Colors.red,
                  duration: Duration(seconds: 5),
                  action: SnackBarAction(
                    label: 'Retry',
                    onPressed: () => _deepLinkService.handleIncomingLink(context, uri),
                  ),
                ),
              );
            }
          });
        }
      } else if (pendingSuggestionId != null) {
        print('🦎 MAIN APP: ✅ Found background suggestion navigation: $pendingSuggestionId');
        await prefs.remove('pending_suggestion_navigation');

        final context = _navigatorKey.currentContext;
        if (context != null) {
          final uri = Uri.parse('readtheroom://suggestion/$pendingSuggestionId');
          _deepLinkService.handleIncomingLink(context, uri).then((_) {
            print('🦎 MAIN APP: ✅ Background suggestion navigation completed');
          }).catchError((e) {
            print('🦎 MAIN APP: ❌ Error navigating from background suggestion: $e');
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('Error opening suggestion. Please try again.'),
                  backgroundColor: Colors.red,
                  duration: Duration(seconds: 5),
                  action: SnackBarAction(
                    label: 'Retry',
                    onPressed: () => _deepLinkService.handleIncomingLink(context, uri),
                  ),
                ),
              );
            }
          });
        }
      } else {
        print('🦎 MAIN APP: No background notification navigation found');
      }
    } catch (e) {
      print('🦎 MAIN APP: ❌ Error checking background notification navigation: $e');
    }
  }
  
  @override
  Widget build(BuildContext context) {
    // Debug the widget state
    print('🦎 MAIN: Build method called');
    print('🦎 MAIN: widget.locationService null? ${widget.locationService == null}');
    print('🦎 MAIN: widget.locationService type: ${widget.locationService?.runtimeType}');
    
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: widget.userService),
        ChangeNotifierProvider.value(value: widget.locationService ?? LocationService()),
        ChangeNotifierProvider.value(value: widget.questionService),
        ChangeNotifierProvider.value(value: widget.watchlistService),
        ChangeNotifierProvider.value(value: widget.suggestionWatchlistService),
        ChangeNotifierProvider.value(value: widget.themeService),
        ChangeNotifierProvider(create: (_) => TemporaryCategoryFilterNotifier()),
        ChangeNotifierProvider(create: (_) => TemporaryReviewFilterNotifier()),
        ChangeNotifierProvider(create: (_) => NavigationVisibilityNotifier()),
        ChangeNotifierProvider(create: (_) => GuestUserTrackingService()),
        ChangeNotifierProvider(create: (_) => BoostService()),
      ],
      child: Consumer<ThemeService>(
        builder: (context, themeService, child) {
          return MaterialApp(
            navigatorKey: _navigatorKey,
            navigatorObservers: [
              AnalyticsNavigationObserver(), // Custom observer with proper screen names
            ],
            debugShowCheckedModeBanner: false,
        title: '> read(the_room)',
        theme: ThemeData(
          brightness: Brightness.light,
          primarySwatch: Colors.teal,
          primaryColor: Color(0xFF00897B), // Medium teal
          scaffoldBackgroundColor: Color(0xFFF2F0EB), // Warm neutral paper tone
          colorScheme: ColorScheme.light(
            primary: Color(0xFF00897B), // Medium teal
            secondary: Colors.teal[600]!,
            surface: Colors.white, // Clean white for cards and surfaces
            background: Color(0xFFF2F0EB), // Warm neutral paper tone
          ),
          switchTheme: SwitchThemeData(
            thumbColor: MaterialStateProperty.resolveWith<Color>((Set<MaterialState> states) {
              if (states.contains(MaterialState.selected)) {
                return Color(0xFF00897B); // Medium teal
              }
              return Colors.grey;
            }),
            trackColor: MaterialStateProperty.resolveWith<Color>((Set<MaterialState> states) {
              if (states.contains(MaterialState.selected)) {
                return Colors.teal[200]!;
              }
              return Colors.grey[300]!;
            }),
            trackOutlineColor: MaterialStateProperty.all(Colors.black),
          ),
              snackBarTheme: SnackBarThemeData(
                contentTextStyle: TextStyle(color: Colors.white),
                actionTextColor: Colors.white,
              ),
            ),
            darkTheme: ThemeData(
              brightness: Brightness.dark,
              primarySwatch: Colors.teal,
              primaryColor: Color(0xFF00897B), // Use same teal as light mode
              colorScheme: ColorScheme.dark(
                primary: Color(0xFF00897B), // Use same teal as light mode
                secondary: Colors.teal[400]!, // Lighter teal for dark mode
                surface: Color(0xFF161616), // Medium dark surface
                background: Color(0xFF0E0E0E), // Medium dark background
                onSurface: Colors.white, // Ensure text is white on dark surfaces
                onBackground: Colors.white, // Ensure text is white on dark background
              ),
              switchTheme: SwitchThemeData(
                thumbColor: MaterialStateProperty.resolveWith<Color>((Set<MaterialState> states) {
                  if (states.contains(MaterialState.selected)) {
                    return Color(0xFF00897B); // Use same teal as light mode
                  }
                  return Colors.grey;
                }),
                trackColor: MaterialStateProperty.resolveWith<Color>((Set<MaterialState> states) {
                  if (states.contains(MaterialState.selected)) {
                    return Colors.teal[300]!.withOpacity(0.5); // Lighter teal with opacity
                  }
                  return Colors.grey[700]!;
                }),
                trackOutlineColor: MaterialStateProperty.all(Colors.white54),
              ),
              snackBarTheme: SnackBarThemeData(
                contentTextStyle: TextStyle(color: Colors.white),
                actionTextColor: Colors.white,
              ),
            ),
            // Use theme mode from ThemeService
            themeMode: themeService.themeMode,
        home: FutureBuilder<bool>(
          future: _checkOnboardingCompleted(),
          builder: (context, snapshot) {
            // BUG FIX SUMMARY: This FutureBuilder previously re-checked onboarding status on every rebuild,
            // causing users to be sent back to onboarding after completing it (e.g., when tapping home button).
            // Solution: Cache the result and add safety checks to prevent inappropriate onboarding returns.
            print('🦎 MAIN: FutureBuilder - connectionState: ${snapshot.connectionState}, hasData: ${snapshot.hasData}, data: ${snapshot.data}');
            print('🦎 MAIN: FutureBuilder - cachedStatus: $_cachedOnboardingStatus, hasChecked: $_hasCheckedOnboarding');
            print('🦎 MAIN: FutureBuilder - Current timestamp: ${DateTime.now().toIso8601String()}');
            
            if (snapshot.connectionState == ConnectionState.waiting) {
              // BUG FIX: If we have cached data, use it instead of showing loading screen
              // This prevents flickering and ensures completed users don't see loading during rebuilds
              if (_cachedOnboardingStatus != null) {
                print('🦎 MAIN: FutureBuilder - Using cached data during wait: $_cachedOnboardingStatus');
                if (_cachedOnboardingStatus!) {
                  return MainScreen();
                } else {
                  return OnboardingScreen(triggeredFrom: 'app_restart');
                }
              }
              
              print('🦎 MAIN: FutureBuilder - Showing loading screen');
              return Scaffold(
                body: Center(
                  child: CircularProgressIndicator(
                    valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF00897B)),
                  ),
                ),
              );
            }
            
            final isOnboardingCompleted = snapshot.data ?? false;
            print('🦎 MAIN: FutureBuilder - isOnboardingCompleted: $isOnboardingCompleted');
            
            // BUG FIX: Additional safety check to prevent inappropriate onboarding returns
            // If cache says completed but fresh read says not completed, trust the cache
            // This handles edge cases where SharedPreferences might temporarily fail or return stale data
            if (_cachedOnboardingStatus == true && !isOnboardingCompleted) {
              print('🦎 MAIN: 🛡️ SAFETY CHECK: Future returned false but cache is true - using cache to prevent inappropriate onboarding');
              return MainScreen();
            }
            
            if (isOnboardingCompleted) {
              print('🦎 MAIN: FutureBuilder - Returning MainScreen');
              return MainScreen();
            } else {
              print('🦎 MAIN: FutureBuilder - Returning OnboardingScreen');
              return OnboardingScreen(triggeredFrom: 'app_restart');
            }
          },
        ),
        onGenerateRoute: (settings) {
          // Add proper screen names for PostHog tracking
          Widget screen;
          String screenName;
          
          switch (settings.name) {
            case '/about':
              screen = AboutScreen();
              screenName = 'About Screen';
              break;
            case '/authentication':
              screen = AuthenticationScreen();
              screenName = 'Authentication Screen';
              break;
            case '/onboarding':
              screen = OnboardingScreen(
                triggeredFrom: settings.arguments as String? ?? 'direct',
              );
              screenName = 'Onboarding Screen';
              break;
            case '/new_question':
              screen = NewQuestionScreen();
              screenName = 'New Question Screen';
              break;
            case '/user':
              screen = MainScreen(initialIndex: 3);
              screenName = 'User Profile Screen';
              break;
            case '/settings':
              screen = SettingsScreen();
              screenName = 'Settings Screen';
              break;
            case '/feedback':
              screen = FeedbackScreen();
              screenName = 'Feedback Screen';
              break;
            case '/guide':
              screen = GuideScreen();
              screenName = 'Guide Screen';
              break;
            case '/platform_stats':
              screen = PlatformStatsScreen();
              screenName = 'Platform Stats Screen';
              break;
            default:
              return null;
          }
          
          return MaterialPageRoute(
            builder: (context) => screen,
            settings: RouteSettings(name: screenName),
          );
        },
          );
        },
      ),
    );
  }
}
