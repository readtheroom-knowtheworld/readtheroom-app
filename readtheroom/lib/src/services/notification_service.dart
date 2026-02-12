// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'package:timezone/timezone.dart' as tz;
import 'analytics_service.dart';
import 'notification_log_service.dart';
import 'qotd_reminder_service.dart';
import 'home_widget_service.dart';
import '../models/notification_item.dart';

class NotificationService {
  // Singleton pattern
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal() {
    print('🦎 SINGLETON: Creating NotificationService instance ${identityHashCode(this)}');
  }
  
  final FirebaseMessaging _firebaseMessaging = FirebaseMessaging.instance;
  final FlutterLocalNotificationsPlugin _localNotifications = FlutterLocalNotificationsPlugin();
  final _supabase = Supabase.instance.client;
  final NotificationLogService _notificationLogService = NotificationLogService();
  
  // Store pending navigation for when app context becomes available
  String? _pendingQuestionNavigation;
  String? _pendingSuggestionNavigation;

  Future<void> initialize() async {
    try {
      // Initialize local notifications (without requesting permissions yet)
      const initializationSettingsAndroid = AndroidInitializationSettings('@mipmap/ic_launcher');
      const initializationSettingsIOS = DarwinInitializationSettings(
        requestAlertPermission: false,
        requestBadgePermission: false,
        requestSoundPermission: false,
        defaultPresentAlert: true,
        defaultPresentBadge: true,
        defaultPresentSound: true,
      );
      const initializationSettings = InitializationSettings(
        android: initializationSettingsAndroid,
        iOS: initializationSettingsIOS,
      );

      await _localNotifications.initialize(
        initializationSettings,
        onDidReceiveNotificationResponse: _onNotificationTap,
      );

      // Check if app was launched by tapping a local notification (cold start)
      await _checkAppLaunchNotification();

      // Create notification channels for Android
      await _createNotificationChannels();

      // Handle FCM token refresh
      _firebaseMessaging.onTokenRefresh.listen(_updateFCMToken);

      // Handle incoming messages when app is in foreground
      FirebaseMessaging.onMessage.listen(_handleForegroundMessage);

      // Handle notification tap when app is in background
      FirebaseMessaging.onMessageOpenedApp.listen(_handleBackgroundMessage);

      // Don't request permissions or get token automatically
      print('Notification service initialized (permissions not requested yet)');
      
      // ✅ Subscribe to topics in background (non-blocking)
      _subscribeToTopicsInBackground();
    } catch (e) {
      print('Error initializing notification service: $e');
      // Don't throw - allow app to continue without notifications
    }
  }

  // Check if the app was launched by tapping a local notification (cold start)
  Future<void> _checkAppLaunchNotification() async {
    try {
      final launchDetails = await _localNotifications.getNotificationAppLaunchDetails();
      if (launchDetails != null &&
          launchDetails.didNotificationLaunchApp &&
          launchDetails.notificationResponse != null) {
        final response = launchDetails.notificationResponse!;
        print('🦎 COLD START: App launched from local notification tap, payload: ${response.payload}');
        _onNotificationTap(response);
      }
    } catch (e) {
      print('🦎 COLD START: Error checking app launch notification: $e');
    }
  }

  // Check if the app was launched by tapping an FCM notification (cold start)
  Future<void> checkInitialFCMMessage() async {
    try {
      final initialMessage = await _firebaseMessaging.getInitialMessage();
      if (initialMessage != null) {
        print('🦎 COLD START: App launched from FCM notification tap, type: ${initialMessage.data['type']}');
        await _handleBackgroundMessage(initialMessage);
      }
    } catch (e) {
      print('🦎 COLD START: Error checking initial FCM message: $e');
    }
  }

  // Create notification channels for Android
  Future<void> _createNotificationChannels() async {
    if (Platform.isAndroid) {
      try {
        final AndroidFlutterLocalNotificationsPlugin? androidPlugin =
            _localNotifications.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();

        if (androidPlugin != null) {
          // QOTD Channel
          await androidPlugin.createNotificationChannel(
            const AndroidNotificationChannel(
              'qotd_channel',
              'Question of the Day',
              description: 'Notifications for new Question of the Day',
              importance: Importance.high,
              playSound: true,
              enableVibration: true,
            ),
          );

          // Comment Notification Channel
          await androidPlugin.createNotificationChannel(
            const AndroidNotificationChannel(
              'comment_notification_channel',
              'Comment Notifications',
              description: 'Notifications for new comments on subscribed questions',
              importance: Importance.high,
              playSound: true,
              enableVibration: true,
            ),
          );

          // Question Activity Channel (silent)
          await androidPlugin.createNotificationChannel(
            const AndroidNotificationChannel(
              'question_activity_channel',
              'Question Activity',
              description: 'Silent notifications for activity on subscribed questions',
              importance: Importance.high,
              playSound: false,
              enableVibration: false,
            ),
          );

          // Streak Reminder Channel
          await androidPlugin.createNotificationChannel(
            const AndroidNotificationChannel(
              'streak_reminder_channel',
              'Streak Reminders',
              description: 'Daily reminders to maintain your answer streak',
              importance: Importance.high,
              playSound: true,
              enableVibration: true,
            ),
          );

          // Test Channel for debugging
          await androidPlugin.createNotificationChannel(
            const AndroidNotificationChannel(
              'test_channel',
              'Test Notifications',
              description: 'Channel for testing notification functionality',
              importance: Importance.high,
              playSound: true,
              enableVibration: true,
            ),
          );

          // Streak Reminder Channel V2 - Fresh channel with guaranteed high importance
          await androidPlugin.createNotificationChannel(
            const AndroidNotificationChannel(
              'streak_reminder_v2_channel',
              'Streak Reminders V2',
              description: 'Daily reminders to maintain your answer streak (improved)',
              importance: Importance.high,
              playSound: true,
              enableVibration: true,
              enableLights: true,
              ledColor: Color(0xFF00897B), // Teal notification light
            ),
          );

          print('✅ Notification channels created successfully');
        }
      } catch (e) {
        print('❌ Error creating notification channels: $e');
      }
    }
  }

  // Subscribe to Firebase topics in background (non-blocking)
  void _subscribeToTopicsInBackground() {
    // Run topic subscriptions in background without blocking initialization
    Future.microtask(() async {
      try {
        // ✅ Auto-subscribe to mandatory system topic
        try {
          await _firebaseMessaging.subscribeToTopic('system');
          if (!kReleaseMode) {
            print("✅ Subscribed to system topic");
          }
        } catch (e) {
          if (!kReleaseMode) {
            print("❌ Failed to subscribe to system topic: $e");
          }
        }

        // ✅ Subscribe to user-specific topic if authenticated
        final user = _supabase.auth.currentUser;
        if (user != null) {
          try {
            await _firebaseMessaging.subscribeToTopic('user_${user.id}');
            if (!kReleaseMode) {
              print("✅ Subscribed to user topic: user_${user.id}");
            }
          } catch (e) {
            if (!kReleaseMode) {
              print("❌ Failed to subscribe to user topic: $e");
            }
          }
        }
      } catch (e) {
        if (!kReleaseMode) {
          print("❌ Error during background topic subscription: $e");
        }
      }
    });
  }

  Future<void> _updateFCMToken(String token) async {
    print('🦎 FCM: Updating token: ${token.substring(0, 20)}...');
    final user = _supabase.auth.currentUser;
    if (user != null) {
      try {
        await _supabase.from('user_fcm_tokens').upsert({
          'user_id': user.id,
          'fcm_token': token,
          'updated_at': DateTime.now().toIso8601String(),
        });
        print('✅ FCM token updated successfully for user: ${user.id}');
        print('🔑 FCM TOKEN: $token');
        print('📱 Copy this token for testing notifications!');
      } catch (e) {
        print('❌ Error updating FCM token: $e');
      }
    } else {
      print('🔑 FCM TOKEN (no user): $token');
      print('📱 Copy this token for testing notifications!');
    }
  }

  Future<void> _handleForegroundMessage(RemoteMessage message) async {
    print('🦎 FCM: Received foreground message - type: ${message.data['type']}');
    
    // Track notification received
    AnalyticsService().trackNotificationReceived(message.data['type'] ?? 'unknown', {
      'delivery_context': 'foreground',
      'question_id': message.data['question_id'] ?? message.data['questionId'],
    });
    
    // Always log to activity feed first, regardless of whether we show the notification
    final notificationTitle = message.notification?.title ?? 'Notification';
    final notificationBody = message.notification?.body ?? '';
    String? payload;
    
    // Check if it's a QOTD notification (now data-only — local notification handles display timing)
    if (message.data['type'] == 'qotd') {
      final questionId = message.data['questionId'] ?? message.data['question_id'];
      final body = message.data['body'] ?? 'Check out today\'s question!';

      // Log to activity feed
      await _logNotificationToInAppLog(
        '📆 Question of the Day',
        body,
        questionId != null ? 'question_$questionId' : null,
      );

      // Update today's scheduled local notification with actual question text
      if (questionId != null) {
        final qotdReminderService = QOTDReminderService();
        await qotdReminderService.updateTodayContent(body, questionId);

        // Update home screen widget with real question data
        await _updateQOTDWidgetWithFreshData(questionId, body);
      }
      return; // Don't show immediately — local notification fires at preferred time
    }
    // Check if it's a comment notification
    else if (message.data['type'] == 'comment') {
      final questionId = message.data['questionId'];
      if (questionId == null) {
        print('Comment notification missing questionId');
        // Still log to activity feed even if we can't process it
        await _logNotificationToInAppLog(
          notificationTitle,
          notificationBody,
          null,
        );
        return;
      }

      // Skip notification if the commenter is the current user
      final commenterId = message.data['commenterId'] ?? message.data['commenter_id'];
      final currentUserId = _supabase.auth.currentUser?.id;
      if (commenterId != null && currentUserId != null && commenterId == currentUserId) {
        print('🦎 FCM: Skipping comment notification — commenter is current user');
        return;
      }

      payload = 'question_$questionId';
      // Show local notification using FCM payload
      await _showLocalNotification(
        title: message.notification?.title ?? 'New Comment',
        body: message.notification?.body ?? 'Someone left a comment',
        payload: payload,
      );
    }
    // Check if it's a suggestion comment notification
    else if (message.data['type'] == 'suggestion_comment') {
      final suggestionId = message.data['suggestionId'];
      if (suggestionId == null) {
        print('Suggestion comment notification missing suggestionId');
        // Still log to activity feed even if we can't process it
        await _logNotificationToInAppLog(
          notificationTitle,
          notificationBody,
          null,
        );
        return;
      }
      
      payload = 'suggestion_$suggestionId';
      // Show local notification using FCM payload
      await _showLocalNotification(
        title: message.notification?.title ?? 'New Suggestion Comment',
        body: message.notification?.body ?? 'Someone commented on your suggestion',
        payload: payload,
      );
    }
    // Check if it's a vote activity notification (authors only)
    else if (message.data['type'] == 'vote_activity') {
      final questionId = message.data['questionId'];
      if (questionId == null) {
        print('Vote activity notification missing questionId');
        // Still log to activity feed even if we can't process it
        await _logNotificationToInAppLog(
          notificationTitle,
          notificationBody,
          null,
        );
        return;
      }
      
      payload = 'question_$questionId';
      // Show local notification using FCM payload
      await _showLocalNotification(
        title: message.notification?.title ?? 'Question Activity',
        body: message.notification?.body ?? 'Your question has new activity',
        payload: payload,
      );
    }
    // Check if it's a system notification
    else if (message.data['type'] == 'system') {
      // Check if this system notification relates to a specific question
      final questionId = message.data['questionId'] ?? message.data['question_id'];
      payload = questionId != null 
          ? 'question_$questionId' 
          : (message.data['action'] ?? 'system');
      
      // Show local notification for system messages
      await _showLocalNotification(
        title: message.notification?.title ?? 'System Update',
        body: message.notification?.body ?? 'Important system information',
        payload: payload,
      );
    }
    // Unknown notification type - still log it
    else {
      await _logNotificationToInAppLog(
        notificationTitle,
        notificationBody,
        null,
      );
    }
  }

  Future<void> _handleBackgroundMessage(RemoteMessage message) async {
    print('🦎 FCM: Received background message - type: ${message.data['type']}');
    print('🦎 SINGLETON: _handleBackgroundMessage called on instance ${identityHashCode(this)}');

    // Handle data-only QOTD messages in background — update scheduled local notification
    if (message.data['type'] == 'qotd') {
      final qotdQuestionId = message.data['questionId'] ?? message.data['question_id'];
      final body = message.data['body'] ?? 'Check out today\'s question!';

      if (qotdQuestionId != null) {
        final qotdReminderService = QOTDReminderService();
        await qotdReminderService.updateTodayContent(body, qotdQuestionId);
        _pendingQuestionNavigation = qotdQuestionId;

        // Update home screen widget with real question data
        await _updateQOTDWidgetWithFreshData(qotdQuestionId, body);
      }

      await _logNotificationToInAppLog(
        '📆 Question of the Day',
        body,
        qotdQuestionId != null ? 'question_$qotdQuestionId' : null,
      );
      return; // Don't show immediately — local notification fires at preferred time
    }

    // For background messages, the system already shows the notification
    // But we still want to log it to our in-app activity feed
    final notificationTitle = message.notification?.title ?? 'Notification';
    final notificationBody = message.notification?.body ?? '';

    // We just need to handle the tap action here
    final questionId = message.data['questionId'] ?? message.data['question_id'];
    final suggestionId = message.data['suggestionId'] ?? message.data['suggestion_id'];

    String? payload;
    if (questionId != null) {
      payload = 'question_$questionId';
      _pendingQuestionNavigation = questionId;
      print('🦎 FCM: Stored pending navigation for question: $questionId');
      print('🦎 SINGLETON: Stored on instance ${identityHashCode(this)}, _pendingQuestionNavigation = $_pendingQuestionNavigation');
    } else if (suggestionId != null) {
      payload = 'suggestion_$suggestionId';
      _pendingSuggestionNavigation = suggestionId;
      print('🦎 FCM: Stored pending navigation for suggestion: $suggestionId');
      print('🦎 SINGLETON: Stored on instance ${identityHashCode(this)}, _pendingSuggestionNavigation = $_pendingSuggestionNavigation');
    }

    // Log to activity feed
    await _logNotificationToInAppLog(
      notificationTitle,
      notificationBody,
      payload,
    );
  }

  // Handle comment notifications for subscribed questions
  Future<void> _handleCommentNotification(RemoteMessage message) async {
    final questionId = message.data['question_id'];
    final commentId = message.data['comment_id'];
    final commenterName = message.data['commenter_name'] ?? 'Someone';
    
    if (questionId == null) return;

    try {
      // Check if user is subscribed to this question using local watchlist
      final prefs = await SharedPreferences.getInstance();
      final watchlistJson = prefs.getString('question_watchlist');
      if (watchlistJson == null) return;

      final Map<String, dynamic> watchlist = json.decode(watchlistJson);
      final entry = watchlist[questionId];
      if (entry == null) return; // Not subscribed to this question

      // Check comment notification rate limiting (max 2 per hour per question)
      final commentRateLimitKey = 'comment_rate_limit_$questionId';
      final rateLimit = prefs.getString(commentRateLimitKey);
      final now = DateTime.now();
      
      if (rateLimit != null) {
        final Map<String, dynamic> rateLimitData = json.decode(rateLimit);
        final lastResetTime = DateTime.parse(rateLimitData['last_reset']);
        final notificationCount = rateLimitData['count'] ?? 0;
        
        // Reset counter if more than 1 hour has passed
        if (now.difference(lastResetTime).inHours >= 1) {
          await prefs.setString(commentRateLimitKey, json.encode({
            'count': 1,
            'last_reset': now.toIso8601String(),
          }));
        } else if (notificationCount >= 2) {
          // Rate limit exceeded - skip notification but still log to in-app activity
          print('🦎 Comment notification: Rate limit exceeded for question $questionId (${notificationCount}/2 this hour)');
          await _logNotificationToInAppLog(
            '💬 ${message.data['question_title'] ?? 'Your subscribed question'}',
            '$commenterName left a comment!',
            'question_$questionId',
          );
          return;
        } else {
          // Increment counter
          await prefs.setString(commentRateLimitKey, json.encode({
            'count': notificationCount + 1,
            'last_reset': lastResetTime.toIso8601String(),
          }));
        }
      } else {
        // First notification for this question - initialize rate limit counter
        await prefs.setString(commentRateLimitKey, json.encode({
          'count': 1,
          'last_reset': now.toIso8601String(),
        }));
      }

      // Track seen comments to avoid duplicate notifications
      final seenCommentsKey = 'seen_comments_$questionId';
      final seenCommentsJson = prefs.getString(seenCommentsKey) ?? '[]';
      final List<dynamic> seenComments = json.decode(seenCommentsJson);
      
      // Check if we've already notified about this comment
      if (commentId != null && seenComments.contains(commentId)) {
        print('🦎 Comment notification: Already seen comment $commentId for question $questionId');
        // Don't log duplicate comments to activity feed
        return;
      }

      // Fetch question text for notification
      String questionText = 'Your subscribed question';
      try {
        final response = await _supabase
            .from('questions')
            .select('prompt, title')
            .eq('id', questionId)
            .maybeSingle();
        
        if (response != null) {
          final fullText = response['prompt'] ?? response['title'] ?? 'Your subscribed question';
          // Truncate if too long for notification
          if (fullText.length > 40) {
            questionText = '${fullText.substring(0, 37)}...';
          } else {
            questionText = fullText;
          }
        }
      } catch (e) {
        print('Error fetching question text for comment notification: $e');
      }

      // Show local notification
      await _showLocalNotification(
        title: '💬 $questionText',
        body: '$commenterName left a comment!',
        payload: 'question_$questionId',
      );

      // Mark this comment as seen to avoid duplicate notifications
      if (commentId != null) {
        seenComments.add(commentId);
        // Keep only the last 100 seen comments to prevent unlimited growth
        if (seenComments.length > 100) {
          seenComments.removeRange(0, seenComments.length - 100);
        }
        await prefs.setString(seenCommentsKey, json.encode(seenComments));
        print('🦎 Comment notification: Marked comment $commentId as seen for question $questionId');
      }

      print('🦎 Comment notification: Showed notification for new comment on question $questionId');
    } catch (e) {
      print('Error handling comment notification: $e');
    }
  }

  // Privacy-preserving question update handler with milestone-based notifications
  Future<void> _handleQuestionUpdatePrivacyPreserving(RemoteMessage message) async {
    final questionId = message.data['question_id'];
    final newVoteCount = int.tryParse(message.data['vote_count'] ?? '') ?? 0;
    final newCommentCount = int.tryParse(message.data['comment_count'] ?? '') ?? 0;
    
    if (questionId == null) return;

    try {
      // Load watchlist from local storage (privacy-preserving)
      final prefs = await SharedPreferences.getInstance();
      final watchlistJson = prefs.getString('question_watchlist');
      if (watchlistJson == null) return;

      final Map<String, dynamic> watchlist = json.decode(watchlistJson);
      final entry = watchlist[questionId];
      if (entry == null) return; // Not subscribed to this question

      // Get the last notified vote count and time
      final lastVoteCount = entry['last_vote_count'] ?? 0;
      final lastNotifiedAt = entry['last_notified_at'] != null
          ? DateTime.parse(entry['last_notified_at'])
          : null;
      final neverNotified = lastNotifiedAt == null;

      // Calculate change
      final voteIncrease = newVoteCount - lastVoteCount;
      final percentChange = lastVoteCount > 0
          ? voteIncrease / lastVoteCount
          : (newVoteCount > 0 ? 1.0 : 0.0);

      // Notification conditions: 3hr cooldown AND (>10 new votes OR >30% change)
      final timeSince = lastNotifiedAt != null
          ? DateTime.now().difference(lastNotifiedAt)
          : Duration(hours: 4); // Treat never-notified as eligible
      final timeCondition = neverNotified || timeSince >= Duration(hours: 3);
      final significantPercentage = percentChange > 0.30;
      final meaningfulVoteIncrease = voteIncrease > 10;
      final activityCondition = significantPercentage || meaningfulVoteIncrease;

      final shouldNotify = voteIncrease > 0 && timeCondition && activityCondition;

      print('Q-Activity check for $questionId: shouldNotify=$shouldNotify [votes: $newVoteCount, lastVotes: $lastVoteCount, increase: $voteIncrease, change: ${(percentChange * 100).toStringAsFixed(1)}%, timeSince: ${timeSince.inMinutes}m]');

      if (shouldNotify) {
          // Fetch question text for notification
          String questionText = 'Your subscribed question';
          try {
            final response = await _supabase
                .from('questions')
                .select('prompt, title')
                .eq('id', questionId)
                .maybeSingle();

            if (response != null) {
              final fullText = response['prompt'] ?? response['title'] ?? 'Your subscribed question';
              if (fullText.length > 80) {
                questionText = '${fullText.substring(0, 77)}...';
              } else {
                questionText = fullText;
              }
            }
          } catch (e) {
            print('Error fetching question text: $e');
          }

          // Create notification body with vote increase info
          final notificationBody = 'Got $voteIncrease new responses ($newVoteCount total)! 🎉';

          // Show local notification with question text as title
          await _showLocalNotification(
            title: '🦎 $questionText',
            body: notificationBody,
            payload: 'question_$questionId',
            useAddOrUpdate: true,
            questionId: questionId,
          );

        // Update watchlist entry
        entry['last_vote_count'] = newVoteCount;
        entry['last_comment_count'] = newCommentCount;
        entry['last_notified_at'] = DateTime.now().toIso8601String();
        watchlist[questionId] = entry;

        await prefs.setString('question_watchlist', json.encode(watchlist));
        print('Updated watchlist entry for $questionId: $newVoteCount votes, +$voteIncrease increase');
      } else {
        // Debug logging for when no milestone notification is sent
        print('🦎 Q-activity: No notification for $questionId - votes: $newVoteCount, lastVotes: $lastVoteCount, change: ${(percentChange * 100).toStringAsFixed(1)}%');
        
        // Still update vote count in storage even if we don't notify
        entry['last_vote_count'] = newVoteCount;
        entry['last_comment_count'] = newCommentCount;
        watchlist[questionId] = entry;
        await prefs.setString('question_watchlist', json.encode(watchlist));
        
        // Still log to activity feed to show current activity
        if (newVoteCount > (entry['last_logged_count'] ?? 0)) {
          try {
            // Fetch question text for activity log
            String questionText = 'Your subscribed question';
            try {
              final response = await _supabase
                  .from('questions')
                  .select('prompt, title')
                  .eq('id', questionId)
                  .maybeSingle();
              
              if (response != null) {
                final fullText = response['prompt'] ?? response['title'] ?? 'Your subscribed question';
                if (fullText.length > 80) {
                  questionText = '${fullText.substring(0, 77)}...';
                } else {
                  questionText = fullText;
                }
              }
            } catch (e) {
              print('Error fetching question text for activity log: $e');
            }
            
            // Use the new addOrUpdateVoteActivityNotification method to update existing entries
            final activityDescription = 'Got $newVoteCount total ${newVoteCount == 1 ? 'response' : 'responses'}';
            
            await _notificationLogService.addOrUpdateVoteActivityNotification(
              questionId: questionId,
              title: '🦎 $questionText',
              body: activityDescription,
              type: 'vote_activity',
            );
            
            // Track that we logged this count to avoid excessive logging
            entry['last_logged_count'] = newVoteCount;
            watchlist[questionId] = entry;
            await prefs.setString('question_watchlist', json.encode(watchlist));
            
            print('🦎 NOTIFICATION LOG: Updated vote activity in feed for question $questionId');
          } catch (e) {
            print('Error logging activity to feed: $e');
          }
        }
      }
    } catch (e) {
      print('Error handling question update: $e');
    }
  }

  Future<void> _showLocalNotification({
    required String title,
    required String body,
    String? payload,
    bool useAddOrUpdate = false,
    String? questionId,
  }) async {
    // Log the notification to in-app notification log
    if (useAddOrUpdate && questionId != null) {
      // Use the update logic for vote activity notifications
      await _notificationLogService.addOrUpdateVoteActivityNotification(
        questionId: questionId,
        title: title,
        body: body,
        type: 'vote_activity',
      );
    } else {
      // Use the regular add logic for other notifications
      await _logNotificationToInAppLog(title, body, payload);
    }
    
    // Determine notification type based on title and payload
    final isQuestionActivity = payload != null && payload.startsWith('question_') && title.contains('🦎');
    final isCommentNotification = title.contains('💬');
    
    final androidDetails = AndroidNotificationDetails(
      isQuestionActivity ? 'question_activity_channel' :
      isCommentNotification ? 'comment_notification_channel' : 'qotd_channel',
      isQuestionActivity ? 'Question Activity' :
      isCommentNotification ? 'Comment Notifications' : 'Question of the Day',
      channelDescription: isQuestionActivity
          ? 'Silent notifications for activity on subscribed questions'
          : isCommentNotification
          ? 'Notifications for new comments on subscribed questions'
          : 'Notifications for new Question of the Day',
      importance: Importance.high,
      priority: Priority.high,
      icon: 'ic_stat_rtr_logo_aug2025',
      playSound: !isQuestionActivity, // No sound for question activity only
      enableVibration: !isQuestionActivity, // No vibration for question activity only
      silent: isQuestionActivity, // Silent for question activity only
    );

    final iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: !isQuestionActivity, // No sound for question activity only
    );

    final notificationDetails = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
    );

    await _localNotifications.show(
      DateTime.now().millisecond,
      title,
      body,
      notificationDetails,
      payload: payload,
    );
  }

  void _onNotificationTap(NotificationResponse response) {
    // Handle notification tap
    print('🦎 NOTIFICATION TAP: Received tap response');
    print('🦎 SINGLETON: _onNotificationTap called on instance ${identityHashCode(this)}');

    if (response.payload != null) {
      print('🦎 NOTIFICATION TAP: Payload received: ${response.payload}');

      // Check if it's a question notification
      if (response.payload!.startsWith('question_')) {
        final questionId = response.payload!.substring('question_'.length);
        print('🦎 NOTIFICATION TAP: ✅ Question ID extracted: $questionId');

        // Store the question ID for navigation when app context is available
        _pendingQuestionNavigation = questionId;
        print('🦎 NOTIFICATION TAP: ✅ Stored pending navigation for question: $questionId');

        // Also persist to SharedPreferences for cold-start reliability
        _persistPendingNavigation('question', questionId);
      }
      // Check if it's a suggestion notification
      else if (response.payload!.startsWith('suggestion_')) {
        final suggestionId = response.payload!.substring('suggestion_'.length);
        print('🦎 NOTIFICATION TAP: ✅ Suggestion ID extracted: $suggestionId');

        // Store the suggestion ID for navigation when app context is available
        _pendingSuggestionNavigation = suggestionId;
        print('🦎 NOTIFICATION TAP: ✅ Stored pending navigation for suggestion: $suggestionId');

        // Also persist to SharedPreferences for cold-start reliability
        _persistPendingNavigation('suggestion', suggestionId);
      } else {
        print('🦎 NOTIFICATION TAP: ❌ Payload does not start with "question_" or "suggestion_": ${response.payload}');
      }
    } else {
      print('🦎 NOTIFICATION TAP: ❌ No payload in notification response');
    }
  }

  // Persist pending navigation to SharedPreferences for cold-start scenarios
  // where the singleton might be recreated before the navigation is consumed
  void _persistPendingNavigation(String type, String id) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (type == 'question') {
        await prefs.setString('pending_question_navigation', id);
      } else if (type == 'suggestion') {
        await prefs.setString('pending_suggestion_navigation', id);
      }
      print('🦎 NOTIFICATION TAP: Persisted pending $type navigation: $id');
    } catch (e) {
      print('🦎 NOTIFICATION TAP: Error persisting navigation: $e');
    }
  }

  // Method to subscribe to QOTD notifications
  Future<void> subscribeToQOTD() async {
    try {
      await _firebaseMessaging.subscribeToTopic('qotd');
      print("✅ Subscribed to QOTD topic");
    } catch (e) {
      print("❌ Failed to subscribe to QOTD topic: $e");
    }
  }

  // Method to unsubscribe from QOTD notifications
  Future<void> unsubscribeFromQOTD() async {
    try {
      await _firebaseMessaging.unsubscribeFromTopic('qotd');
      print("✅ Unsubscribed from QOTD topic");
    } catch (e) {
      print("❌ Failed to unsubscribe from QOTD topic: $e");
    }
  }

  // Method to show QOTD achievement notification for user's own question
  Future<void> showQOTDAuthorNotification(Map<String, dynamic> question) async {
    try {
      final user = _supabase.auth.currentUser;
      if (user == null) {
        print("❌ Cannot show QOTD author notification: user not authenticated");
        return;
      }

      // Check if the user is the author of this question
      final authorId = question['author_id']?.toString() ?? question['user_id']?.toString();
      if (authorId != user.id) {
        print("❌ User is not the author of this QOTD question");
        return;
      }

      // Check if we've already notified the user about this specific QOTD
      final prefs = await SharedPreferences.getInstance();
      final questionId = question['id'].toString();
      final notificationKey = 'qotd_author_notified_$questionId';
      
      if (prefs.getBool(notificationKey) == true) {
        print("✅ User already notified about being QOTD author for question $questionId");
        return;
      }

      // Get question text for the notification
      String questionText = question['prompt']?.toString() ?? 'Your question';
      if (questionText.length > 50) {
        questionText = questionText.substring(0, 50) + '...';
      }

      // Show the achievement notification
      await _showLocalNotification(
        title: '🏆 Trend setter!',
        body: 'Your question is now question of the day, check it out!',
        payload: 'question_$questionId',
      );

      // Mark this notification as sent
      await prefs.setBool(notificationKey, true);
      
      print("✅ Showed QOTD author achievement notification for question $questionId");

    } catch (e) {
      print("❌ Error showing QOTD author notification: $e");
    }
  }

  // Method to subscribe to question activity notifications (topic-based system)
  Future<void> subscribeToQuestionActivity() async {
    try {
      final user = _supabase.auth.currentUser;
      if (user == null) {
        print("❌ Cannot subscribe to question activity: user not authenticated");
        return;
      }

      // 1. Subscribe to user's personal topic for vote activity notifications
      await _firebaseMessaging.subscribeToTopic('user_${user.id}');
      print("✅ Subscribed to personal topic: user_${user.id}");

      // 2. Update notification settings in database
      await _supabase.from('notification_settings').upsert({
        'user_id': user.id,
        'comments_on_watched_enabled': true,
        'comments_on_created_enabled': true,
        'votes_on_created_enabled': true,
      });
      print("✅ Updated notification settings for question activity");

    } catch (e) {
      print("❌ Failed to subscribe to question activity: $e");
    }
  }

  // Method to unsubscribe from question activity notifications
  Future<void> unsubscribeFromQuestionActivity() async {
    try {
      final user = _supabase.auth.currentUser;
      if (user == null) {
        print("❌ Cannot unsubscribe from question activity: user not authenticated");
        return;
      }

      // 1. Unsubscribe from user's personal topic for vote activity notifications
      await _firebaseMessaging.unsubscribeFromTopic('user_${user.id}');
      print("✅ Unsubscribed from personal topic: user_${user.id}");

      // 2. Update notification settings in database
      await _supabase.from('notification_settings').upsert({
        'user_id': user.id,
        'comments_on_watched_enabled': false,
        'comments_on_created_enabled': false,
        'votes_on_created_enabled': false,
      });
      print("✅ Updated notification settings to disable question activity");

    } catch (e) {
      print("❌ Failed to unsubscribe from question activity: $e");
    }
  }

  // Method to subscribe to system notifications (users cannot unsubscribe)
  Future<void> subscribeToSystem() async {
    try {
      await _firebaseMessaging.subscribeToTopic('system');
      if (!kReleaseMode) {
        print("✅ Subscribed to system topic");
      }
    } catch (e) {
      if (!kReleaseMode) {
        print("❌ Failed to subscribe to system topic: $e");
      }
    }
  }

  // New method to request permissions after user consent
  Future<bool> requestPermissions() async {
    try {
      // Request local notification permissions for Android 13+
      if (Platform.isAndroid) {
        final AndroidFlutterLocalNotificationsPlugin? androidPlugin =
            _localNotifications.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
        
        if (androidPlugin != null) {
          final bool? granted = await androidPlugin.requestNotificationsPermission();
          print('🔔 Android notification permission granted: $granted');
          
          if (granted == false) {
            print('❌ Local notification permissions denied on Android');
            return false;
          }
        }
      }
      
      // Request iOS local notification permissions
      if (Platform.isIOS) {
        final IOSFlutterLocalNotificationsPlugin? iosPlugin =
            _localNotifications.resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>();
        
        if (iosPlugin != null) {
          final bool? granted = await iosPlugin.requestPermissions(
            alert: true,
            badge: true,
            sound: true,
          );
          print('🔔 iOS local notification permission granted: $granted');
          
          if (granted == false) {
            print('❌ Local notification permissions denied on iOS');
            return false;
          }
        }
      }

      // Request permission for Firebase notifications
      final settings = await _firebaseMessaging.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );

      if (settings.authorizationStatus == AuthorizationStatus.authorized) {
        // Get initial FCM token with error handling
        try {
          final token = await _firebaseMessaging.getToken();
          if (token != null) {
            await _updateFCMToken(token);
            print('🚀 Notifications enabled! Device is ready for FCM.');
            
            // ✅ Auto-subscribe to mandatory system topic
            await _firebaseMessaging.subscribeToTopic('system');
            if (!kReleaseMode) {
              print("✅ Subscribed to system topic");
            }
            
            // ✅ Subscribe to user-specific topic if authenticated
            final user = _supabase.auth.currentUser;
            if (user != null) {
              await _firebaseMessaging.subscribeToTopic('user_${user.id}');
              if (!kReleaseMode) {
                print("✅ Subscribed to user topic: user_${user.id}");
              }
            }
            
            // Note: QOTD and question subscriptions are handled separately
            // This allows for individual toggle control after initial permission grant
          }
          return true;
        } catch (e) {
          print('Warning: Could not get FCM token (this is normal on iOS simulator): $e');
          // This is expected on iOS simulator - FCM tokens require a real device
          return true; // Still consider it successful for simulator
        }
      } else {
        print('Notification permissions denied');
        return false;
      }
    } catch (e) {
      print('Error requesting notification permissions: $e');
      return false;
    }
  }

  // Check if there's a pending question navigation from notification tap
  String? getPendingQuestionNavigation() {
    print('🦎 SINGLETON: getPendingQuestionNavigation called on instance ${identityHashCode(this)}');
    print('🦎 SINGLETON: Current _pendingQuestionNavigation value: $_pendingQuestionNavigation');
    
    final questionId = _pendingQuestionNavigation;
    if (questionId != null) {
      print('🦎 NOTIFICATION NAV: Retrieved pending question navigation: $questionId');
      _pendingQuestionNavigation = null; // Clear after retrieving
      print('🦎 NOTIFICATION NAV: Cleared pending navigation, will attempt deep link');
    } else {
      print('🦎 NOTIFICATION NAV: No pending question navigation found');
    }
    return questionId;
  }

  // Check if there's a pending suggestion navigation from notification tap
  String? getPendingSuggestionNavigation() {
    print('🦎 SINGLETON: getPendingSuggestionNavigation called on instance ${identityHashCode(this)}');
    print('🦎 SINGLETON: Current _pendingSuggestionNavigation value: $_pendingSuggestionNavigation');
    
    final suggestionId = _pendingSuggestionNavigation;
    if (suggestionId != null) {
      print('🦎 NOTIFICATION NAV: Retrieved pending suggestion navigation: $suggestionId');
      _pendingSuggestionNavigation = null; // Clear after retrieving
      print('🦎 NOTIFICATION NAV: Cleared pending navigation, will attempt deep link');
    } else {
      print('🦎 NOTIFICATION NAV: No pending suggestion navigation found');
    }
    return suggestionId;
  }

  // Check if notification permissions are already granted
  Future<bool> arePermissionsGranted() async {
    try {
      final settings = await _firebaseMessaging.getNotificationSettings();
      return settings.authorizationStatus == AuthorizationStatus.authorized;
    } catch (e) {
      print('Error checking notification permissions: $e');
      return false;
    }
  }

  // Get the current notification permission status
  // Returns AuthorizationStatus: authorized, denied, notDetermined, or provisional
  Future<AuthorizationStatus> getPermissionStatus() async {
    try {
      final settings = await _firebaseMessaging.getNotificationSettings();
      return settings.authorizationStatus;
    } catch (e) {
      print('Error getting notification permission status: $e');
      return AuthorizationStatus.notDetermined;
    }
  }

  // Handle subscribed activity ping - rebuild synthetic update messages for all watchlist questions
  Future<int> handleSubscribedActivityPing(RemoteMessage message) async {
    print('🦎 Q-activity: Received subscribed activity ping');
    try {
      final syntheticMessages = await _rebuildSyntheticUpdateMessages();
      int processedCount = 0;
      int notificationCount = 0;
      
      print('🦎 Q-activity: Processing ${syntheticMessages.length} synthetic messages');
      
      for (final syntheticMessage in syntheticMessages) {
        try {
          final questionId = syntheticMessage.data['question_id'];
          print('🦎 Q-activity: Processing synthetic message for $questionId');
          
          // Store the original notification count before processing
          final beforeCount = processedCount;
          
          await _handleQuestionUpdatePrivacyPreserving(syntheticMessage);
          processedCount++;
          
          // Check if a notification was actually shown (this is a bit hacky but works)
          // We can't directly track this, but we can infer from the debug logs
          print('🦎 Q-activity: Completed processing for $questionId');
        } catch (e) {
          print('Error processing synthetic message: $e');
        }
      }
      
      print('🦎 Q-activity: Completed processing $processedCount synthetic messages');
      return processedCount;
    } catch (e) {
      print('Error handling subscribed activity ping: $e');
      return 0;
    }
  }

  // Helper method to rebuild synthetic update messages for all questions in watchlist
  Future<List<RemoteMessage>> _rebuildSyntheticUpdateMessages() async {
    final syntheticMessages = <RemoteMessage>[];
    
    try {
      // Load watchlist from local storage
      final prefs = await SharedPreferences.getInstance();
      final watchlistJson = prefs.getString('question_watchlist');
      if (watchlistJson == null) {
        print('🦎 Q-activity: No watchlist found in local storage');
        return syntheticMessages;
      }

      final Map<String, dynamic> watchlist = json.decode(watchlistJson);
      print('🦎 Q-activity: Processing ${watchlist.length} subscribed questions');
      
      // Fetch current vote and comment counts for all subscribed questions
      for (final questionId in watchlist.keys) {
        try {
          // Get current vote count from responses table (same as getQuestionById)
          final responseCountQuery = await _supabase
              .from('responses')
              .select('id')
              .eq('question_id', questionId);
          
          final currentVoteCount = responseCountQuery?.length ?? 0;
          
          // Get current comment count from comments table
          final commentCountQuery = await _supabase
              .from('comments')
              .select('id')
              .eq('question_id', questionId)
              .eq('is_hidden', false);
          
          final currentCommentCount = commentCountQuery?.length ?? 0;
          
          // Create synthetic RemoteMessage with both vote and comment counts
          final syntheticMessage = RemoteMessage(
            data: {
              'type': 'question_update',
              'question_id': questionId,
              'vote_count': currentVoteCount.toString(),
              'comment_count': currentCommentCount.toString(),
            },
          );
          
          syntheticMessages.add(syntheticMessage);
          print('🦎 Q-activity: Created synthetic message for $questionId (${currentVoteCount} votes, ${currentCommentCount} comments)');
        } catch (e) {
          print('Error fetching vote/comment count for question $questionId: $e');
        }
      }
      
      print('🦎 Q-activity: Created ${syntheticMessages.length} synthetic messages');
    } catch (e) {
      print('Error rebuilding synthetic update messages: $e');
    }
    
    return syntheticMessages;
  }

  // Check for pending background pings and process them
  Future<void> _checkForPendingBackgroundPings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final lastPingTime = prefs.getString('last_subscribed_activity_ping');
      
      if (lastPingTime != null) {
        final pingTime = DateTime.parse(lastPingTime);
        final timeSincePing = DateTime.now().difference(pingTime);
        
        // Only process if ping was received within the last 5 minutes
        if (timeSincePing.inMinutes <= 5) {
          print('🦎 Q-activity: Found pending background ping from ${timeSincePing.inMinutes} minutes ago');
          
          // Create a synthetic message to trigger processing
          final syntheticMessage = RemoteMessage(
            data: {
              'type': 'q_subscribed_activity',
              'background_ping': 'true',
            },
          );
          
          final count = await handleSubscribedActivityPing(syntheticMessage);
          print("🦎 Q-activity: Processed pending background ping — $count questions had significant changes");
          
          // Clear the pending ping
          await prefs.remove('last_subscribed_activity_ping');
        } else {
          print('🦎 Q-activity: Found old background ping (${timeSincePing.inMinutes} minutes ago), ignoring');
          await prefs.remove('last_subscribed_activity_ping');
        }
      }
    } catch (e) {
      print('🦎 Q-activity: Error checking for pending background pings: $e');
    }
  }

  // Test method to verify basic notification functionality
  Future<void> testBasicNotification() async {
    try {
      print('🧪 Testing basic notification functionality...');
      
      await _localNotifications.show(
        999,
        '🧪 Test Notification',
        'If you see this, basic notifications are working! Current time: ${DateTime.now().toString().substring(11, 19)}',
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'test_channel',
            'Test Notifications',
            channelDescription: 'Channel for testing notification functionality',
            importance: Importance.high,
            priority: Priority.high,
            icon: 'ic_stat_rtr_logo_aug2025',
            playSound: true,
            enableVibration: true,
          ),
          iOS: DarwinNotificationDetails(
            presentAlert: true,
            presentBadge: true,
            presentSound: true,
          ),
        ),
      );
      
      print('✅ Test notification sent successfully');
    } catch (e) {
      print('❌ Error sending test notification: $e');
    }
  }

  // Test method for scheduled notifications
  Future<void> testScheduledNotification({int delayMinutes = 1}) async {
    try {
      print('🧪 Testing scheduled notification functionality...');
      
      final now = DateTime.now();
      final scheduledTime = now.add(Duration(minutes: delayMinutes));
      var tzScheduledTime = tz.TZDateTime.from(scheduledTime, tz.local);
      
      print('🧪 SCHEDULING TEST NOTIFICATION:');
      print('🕐 Current timezone: ${tz.local}');
      print('🕐 Current local time: ${tz.TZDateTime.now(tz.local)}');
      print('🕐 Target local time: ${tzScheduledTime}');
      print('🕐 Time until notification: ${tzScheduledTime.difference(tz.TZDateTime.now(tz.local)).inMinutes} minutes');
      
      // Try exact scheduling first, fall back to inexact if permission denied
      try {
        await _localNotifications.zonedSchedule(
          998,
          '🧪 Scheduled Test Notification',
          'This notification was scheduled for $delayMinutes minute(s) at ${scheduledTime.toString().substring(11, 19)}. Current time when created: ${now.toString().substring(11, 19)}',
          tzScheduledTime,
          const NotificationDetails(
            android: AndroidNotificationDetails(
              'test_channel',
              'Test Notifications',
              channelDescription: 'Channel for testing notification functionality',
              importance: Importance.high,
              priority: Priority.high,
              icon: 'ic_stat_rtr_logo_aug2025',
              playSound: true,
              enableVibration: true,
            ),
            iOS: DarwinNotificationDetails(
              presentAlert: true,
              presentBadge: true,
              presentSound: true,
            ),
          ),
          androidScheduleMode: AndroidScheduleMode.inexact,
        );
        print('✅ Scheduled with exact timing');
      } catch (e) {
        if (e.toString().contains('exact_alarms_not_permitted')) {
          print('⚠️ Exact alarms not permitted, trying inexact scheduling...');
          await _localNotifications.zonedSchedule(
            998,
            '🧪 Scheduled Test Notification (Inexact)',
            'This notification was scheduled for approximately $delayMinutes minute(s) at ${scheduledTime.toString().substring(11, 19)}. Current time when created: ${now.toString().substring(11, 19)}',
            tzScheduledTime,
            const NotificationDetails(
              android: AndroidNotificationDetails(
                'test_channel',
                'Test Notifications',
                channelDescription: 'Channel for testing notification functionality',
                importance: Importance.high,
                priority: Priority.high,
                playSound: true,
                enableVibration: true,
              ),
              iOS: DarwinNotificationDetails(
                presentAlert: true,
                presentBadge: true,
                presentSound: true,
              ),
            ),
            androidScheduleMode: AndroidScheduleMode.inexact,
          );
          print('✅ Scheduled with inexact timing (may be delayed by system)');
        } else {
          throw e; // Re-throw if it's a different error
        }
      }
      
      print('✅ Scheduled test notification successfully');
      print('🕐 AFTER SCHEDULING:');
      print('🕐 Notification ID: 998');
      print('🕐 Scheduled for: ${tzScheduledTime}');
      print('🕐 In ${delayMinutes} minute(s) from now');
      
      // Also schedule a 30-second test for quicker feedback
      if (delayMinutes >= 1) {
        await _testVeryShortScheduledNotification();
      }
    } catch (e) {
      print('❌ Error scheduling test notification: $e');
      print('❌ Error type: ${e.runtimeType}');
      print('❌ Error details: $e');
    }
  }

  // Test with 10-second delay for immediate debugging
  Future<void> testScheduledNotification10Seconds() async {
    try {
      print('⚡ Testing 10-second scheduled notification...');
      
      final now = tz.TZDateTime.now(tz.local);
      final scheduledTime = now.add(Duration(seconds: 10));
      
      print('⚡ SCHEDULING 10-SECOND TEST:');
      print('⚡ TIMEZONE DEBUG:');
      print('⚡ tz.local.name: ${tz.local.name}');
      print('⚡ System DateTime.now(): ${DateTime.now()}');
      print('⚡ System timezone offset: ${DateTime.now().timeZoneOffset}');
      print('⚡ Current timezone: ${tz.local}');
      print('⚡ Current time: ${now}');
      print('⚡ Scheduled for: ${scheduledTime}');
      print('⚡ Time diff: ${scheduledTime.difference(now).inSeconds} seconds');
      
      try {
        await _localNotifications.zonedSchedule(
          996,
          '⚡ 10-Second Test',
          'Ultra quick test! Should appear in 10 seconds at ${scheduledTime.toString().substring(11, 19)}',
          scheduledTime,
          const NotificationDetails(
            android: AndroidNotificationDetails(
              'test_channel',
              'Test Notifications',
              channelDescription: 'Channel for testing notification functionality',
              importance: Importance.high,
              priority: Priority.high,
              icon: 'ic_stat_rtr_logo_aug2025',
              playSound: true,
              enableVibration: true,
            ),
            iOS: DarwinNotificationDetails(
              presentAlert: true,
              presentBadge: true,
              presentSound: true,
            ),
          ),
          androidScheduleMode: AndroidScheduleMode.inexact,
        );
        print('⚡ 10-second test scheduled with exact timing');
      } catch (e) {
        if (e.toString().contains('exact_alarms_not_permitted')) {
          await _localNotifications.zonedSchedule(
            996,
            '⚡ 10-Second Test (Inexact)',
            'Ultra quick test! Should appear around ${scheduledTime.toString().substring(11, 19)}',
            scheduledTime,
            const NotificationDetails(
              android: AndroidNotificationDetails(
                'test_channel',
                'Test Notifications',
                importance: Importance.high,
                priority: Priority.high,
                icon: 'ic_stat_rtr_logo_aug2025',
                playSound: true,
                enableVibration: true,
              ),
              iOS: DarwinNotificationDetails(
                presentAlert: true,
                presentBadge: true,
                presentSound: true,
              ),
            ),
            androidScheduleMode: AndroidScheduleMode.inexact,
          );
          print('⚡ 10-second test scheduled with inexact timing');
        } else {
          throw e;
        }
      }
      
      print('⚡ 10-second notification scheduled successfully!');
    } catch (e) {
      print('❌ Error scheduling 10-second test: $e');
    }
  }

  // Test with very short delay (30 seconds) for quicker debugging
  Future<void> _testVeryShortScheduledNotification() async {
    try {
      print('🚀 Also scheduling 30-second test...');
      
      final now = tz.TZDateTime.now(tz.local);
      final scheduledTime = now.add(Duration(seconds: 30));
      
      try {
        await _localNotifications.zonedSchedule(
          997,
          '⚡ 30-Second Test',
          'Quick test! Scheduled at ${now.toString().substring(11, 19)}, should appear at ${scheduledTime.toString().substring(11, 19)}',
          scheduledTime,
          const NotificationDetails(
            android: AndroidNotificationDetails(
              'test_channel',
              'Test Notifications',
              channelDescription: 'Channel for testing notification functionality',
              importance: Importance.high,
              priority: Priority.high,
              icon: 'ic_stat_rtr_logo_aug2025',
              playSound: true,
              enableVibration: true,
            ),
            iOS: DarwinNotificationDetails(
              presentAlert: true,
              presentBadge: true,
              presentSound: true,
            ),
          ),
          androidScheduleMode: AndroidScheduleMode.inexact,
        );
      } catch (e) {
        if (e.toString().contains('exact_alarms_not_permitted')) {
          await _localNotifications.zonedSchedule(
            997,
            '⚡ 30-Second Test (Inexact)',
            'Quick test! Scheduled at ${now.toString().substring(11, 19)}, should appear around ${scheduledTime.toString().substring(11, 19)}',
            scheduledTime,
            const NotificationDetails(
              android: AndroidNotificationDetails(
                'test_channel',
                'Test Notifications',
                importance: Importance.high,
                priority: Priority.high,
                icon: 'ic_stat_rtr_logo_aug2025',
                playSound: true,
                enableVibration: true,
              ),
              iOS: DarwinNotificationDetails(
                presentAlert: true,
                presentBadge: true,
                presentSound: true,
              ),
            ),
            androidScheduleMode: AndroidScheduleMode.inexact,
          );
        } else {
          throw e;
        }
      }
      
      print('⚡ 30-second test notification scheduled for: ${scheduledTime}');
    } catch (e) {
      print('❌ Error scheduling 30-second test: $e');
    }
  }

  // Test immediate "scheduled" notification (scheduled for right now)
  Future<void> testImmediateScheduledNotification() async {
    try {
      print('🔥 Testing immediate scheduled notification...');
      
      final now = tz.TZDateTime.now(tz.local);
      final immediateTime = now.add(Duration(seconds: 1)); // 1 second from now
      
      print('🔥 IMMEDIATE TEST:');
      print('🔥 Current time: ${now}');
      print('🔥 Scheduled for: ${immediateTime} (1 second from now)');
      
      await _localNotifications.zonedSchedule(
        995,
        '🔥 Immediate Test',
        'This was scheduled for 1 second from now! Time: ${DateTime.now().toString().substring(11, 19)}',
        immediateTime,
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'test_channel',
            'Test Notifications',
            importance: Importance.high,
            priority: Priority.high,
            icon: 'ic_stat_rtr_logo_aug2025',
            playSound: true,
            enableVibration: true,
          ),
          iOS: DarwinNotificationDetails(
            presentAlert: true,
            presentBadge: true,
            presentSound: true,
          ),
        ),
        androidScheduleMode: AndroidScheduleMode.inexact, // Use inexact since exact is blocked
      );
      
      print('🔥 Immediate notification scheduled successfully!');
    } catch (e) {
      print('❌ Error scheduling immediate notification: $e');
    }
  }

  // Debug method to check pending scheduled notifications
  Future<void> checkPendingNotifications() async {
    try {
      print('🔍 Checking pending scheduled notifications...');
      
      final List<PendingNotificationRequest> pending = 
          await _localNotifications.pendingNotificationRequests();
      
      print('📋 Found ${pending.length} pending notifications:');
      
      if (pending.isEmpty) {
        print('   No pending notifications found');
      } else {
        for (final notification in pending) {
          print('   ID: ${notification.id}, Title: ${notification.title}, Body: ${notification.body}');
        }
      }
    } catch (e) {
      print('❌ Error checking pending notifications: $e');
    }
  }

  // Helper method to log notifications to in-app notification log
  Future<void> _logNotificationToInAppLog(String title, String body, String? payload) async {
    try {
      String? questionId;
      String? suggestionId;
      String notificationType = 'system';

      // Parse payload to extract IDs and determine type
      if (payload != null) {
        if (payload.startsWith('question_')) {
          questionId = payload.substring('question_'.length);
          if (title.contains('💬')) {
            notificationType = 'comment';
          } else if (title.contains('📆')) {
            notificationType = 'qotd';
          } else if (title.contains('🦎')) {
            notificationType = 'vote_activity';
          } else if (title.contains('❓')) {
            notificationType = 'qotd';
          }
        } else if (payload.startsWith('suggestion_')) {
          suggestionId = payload.substring('suggestion_'.length);
          notificationType = 'comment';
        }
      }


      final notification = NotificationLogService.createFromRemoteMessage(
        title: title,
        body: body,
        type: notificationType,
        questionId: questionId,
        suggestionId: suggestionId,
      );

      await _notificationLogService.addNotification(notification);
      print('🦎 NOTIFICATION LOG: Added notification to in-app log: $title');
    } catch (e) {
      print('🦎 NOTIFICATION LOG: Error logging notification: $e');
    }
  }

  /// Fetch real vote/comment counts and hasAnswered for a question, then update the home widget.
  Future<void> _updateQOTDWidgetWithFreshData(String questionId, String questionText) async {
    try {
      final voteCountQuery = await _supabase
          .from('responses')
          .select('id')
          .eq('question_id', questionId);
      final voteCount = voteCountQuery.length;

      final commentCountQuery = await _supabase
          .from('comments')
          .select('id')
          .eq('question_id', questionId);
      final commentCount = commentCountQuery.length;

      bool hasAnswered = false;
      final userId = _supabase.auth.currentUser?.id;
      if (userId != null) {
        final responseCheck = await _supabase
            .from('responses')
            .select('id')
            .eq('question_id', questionId)
            .eq('user_id', userId)
            .maybeSingle();
        hasAnswered = responseCheck != null;
      }

      await HomeWidgetService().updateQOTDWidget(
        questionText: questionText,
        voteCount: voteCount,
        commentCount: commentCount,
        hasAnswered: hasAnswered,
        questionId: questionId,
      );
    } catch (e) {
      print('🦎 Error updating QOTD widget with fresh data: $e');
    }
  }
}