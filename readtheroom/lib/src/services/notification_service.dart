// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'package:timezone/timezone.dart' as tz;
import 'analytics_service.dart';
import 'notification_log_service.dart';
import 'results_service.dart';
import 'user_service.dart';
import '../utils/qotd_push_payload.dart';
import 'home_widget_service.dart';
import '../models/notification_item.dart';

class NotificationService {
  // Singleton pattern
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;

  /// Fires with the event type (`friend_accepted`, `friend_request`) when a
  /// friend-graph push lands while the app is in the foreground. `MainScreen`
  /// answers with `FriendService.refresh()`.
  Stream<String> get friendGraphChanged => _friendGraphChanged.stream;
  final StreamController<String> _friendGraphChanged =
      StreamController<String>.broadcast();
  NotificationService._internal() {
    print('🦎 SINGLETON: Creating NotificationService instance ${identityHashCode(this)}');
  }
  
  final FirebaseMessaging _firebaseMessaging = FirebaseMessaging.instance;
  final FlutterLocalNotificationsPlugin _localNotifications = FlutterLocalNotificationsPlugin();
  final _supabase = Supabase.instance.client;
  final NotificationLogService _notificationLogService = NotificationLogService();
  
  // Store pending navigation for when app context becomes available
  String? _pendingQuestionNavigation;

  /// Set by a tapped QOTD push (either payload shape): the tap opens the app on
  /// home, never the question (owner decision 2026-09-22). Drained by
  /// `main.dart` into `readtheroom://home`.
  bool _pendingHomeNavigation = false;

  /// Friend id whose chat overlay a tapped friend-event push should open
  /// (WP-F, deep link `readtheroom://friend/{userId}`).
  String? _pendingFriendNavigation;

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

          // QOTD Drop Channel — the Drop push names `qotd_drop` and a push
          // cannot create a channel, so it has to exist before the first drop
          // ever lands (drop spec §10.2, backend doc O-4). Max importance: the
          // drop is the one notification of the day that is the event itself.
          await androidPlugin.createNotificationChannel(
            const AndroidNotificationChannel(
              'qotd_drop',
              'The Daily Drop',
              description:
                  'The moment the day\'s question drops — one a day, at a different time each day',
              importance: Importance.max,
              playSound: true,
              enableVibration: true,
              enableLights: true,
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

        // Re-assert the `qotd` topic on every launch while the setting is on.
        // The setting defaults to on, but the topic used to be joined only when
        // the user accepted the notification ask or flipped the Settings
        // toggle — a fresh install that skipped the ask, or a grant that landed
        // before the push token existed, was never subscribed while Settings
        // said it was (drop-push-review-2026-09-22.md). Subscribing is
        // idempotent on FCM, so a repeat costs nothing. Not user-scoped: a
        // guest can hold the subscription too.
        try {
          final prefs = await SharedPreferences.getInstance();
          if (prefs.getBool('notify_qotd') ?? true) {
            await _firebaseMessaging.subscribeToTopic('qotd');
            if (!kReleaseMode) {
              print("✅ Subscribed to QOTD topic (launch re-assert)");
            }
            // Review 2026-09-22 A3: drop-push-review C3 — "is this device even
            // on the topic?" — is the one cause we cannot rule out from data.
            // This is the denominator under A1's delivery denominator.
            AnalyticsService().trackPushTopicSubscription(
                topic: 'qotd', result: 'ok', trigger: 'launch');
            AnalyticsService()
                .setUserProperties({'qotd_topic_subscribed': true});
          }
        } catch (e) {
          if (!kReleaseMode) {
            print("❌ Failed to re-assert QOTD topic: $e");
          }
          AnalyticsService().trackPushTopicSubscription(
              topic: 'qotd', result: 'failed', trigger: 'launch');
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
        // Review 2026-09-19 P0-4: a device whose token never lands is
        // unreachable by push for good, and nothing else reports it.
        AnalyticsService()
            .trackRpcFailed('fcm_token_upsert', reason: analyticsRpcReason(e));
      }
    } else {
      print('🔑 FCM TOKEN (no user): $token');
      print('📱 Copy this token for testing notifications!');
    }
  }

  Future<void> _handleForegroundMessage(RemoteMessage message) async {
    print('🦎 FCM: Received foreground message - type: ${message.data['type']}');
    
    // Track notification received.
    //
    // Review 2026-09-22 §4.4: the `question_id` that used to ride here went
    // against an identified person — the same join the answer events just had
    // removed. `drop_date` is the aggregate-safe replacement, and matches what
    // the background receipts (A1) report.
    final foregroundPush = QotdPushPayload.parse(message.data);
    AnalyticsService().trackNotificationReceived(
      message.data['type']?.toString() ?? 'unknown',
      {
        'delivery_context': 'foreground',
        if (foregroundPush != null) 'push_kind': foregroundPush.kind.name,
        if (foregroundPush != null) 'is_drop': foregroundPush.isDrop,
        if (foregroundPush?.publishedAt != null)
          'drop_date': foregroundPush!.publishedAt!
              .toUtc()
              .toIso8601String()
              .substring(0, 10),
      },
    );
    
    // Always log to activity feed first, regardless of whether we show the notification
    final notificationTitle = message.notification?.title ?? 'Notification';
    final notificationBody = message.notification?.body ?? '';
    String? payload;
    
    // QOTD: the Drop. Both payload shapes (`qotd_drop` and the legacy data-only
    // `qotd`) are shown the instant they arrive — the server's random minute IS
    // the moment, so there is nothing left to schedule. Neither Android nor iOS
    // renders a notification block while the app is in front, so in the
    // foreground we always show it ourselves, drop mode included.
    final qotdPush = QotdPushPayload.parse(
      message.data,
      notificationTitle: message.notification?.title,
      notificationBody: message.notification?.body,
    );
    if (qotdPush != null) {
      await _showQotdNotification(qotdPush);

      // Keep the home-screen widget in step with the question that just landed.
      if (qotdPush.questionId != null) {
        await _updateQOTDWidgetWithFreshData(
            qotdPush.questionId!, qotdPush.body);
      }
      return;
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
    // Friend graph: requests and acceptances (WP-E), licks / forwards /
    // reactions (WP-F). All of them open the sender's chat, so the payload
    // carries the actor, never the forwarded question — routing to the
    // question would skip past the conversation the push is about.
    else if (message.data['type'] == 'friend_event') {
      final actorId = message.data['senderId'] ??
          message.data['actorId'] ??
          message.data['actor_id'];
      payload = actorId != null ? 'friend_$actorId' : null;

      // A graph change while the app is open: let the friend list reload so
      // the scanned phone gets its "you're friends now" moment (a QR add
      // arrives as friend_accepted) and a new request appears without a
      // manual refresh.
      final eventType = (message.data['event_type'] ??
              message.data['friendEventType'])
          ?.toString();
      if (eventType == 'friend_accepted' || eventType == 'friend_request') {
        _friendGraphChanged.add(eventType!);
      }

      await _showLocalNotification(
        title: message.notification?.title ?? '🦎 Friends',
        body: message.notification?.body ?? 'Something happened in your network',
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

    // QOTD (both payload shapes). This handler runs on a TAP
    // (onMessageOpenedApp / getInitialMessage), so the notification the user
    // tapped has already been displayed — by the OS for a drop-mode push, or by
    // `_firebaseMessagingBackgroundHandler` for a legacy data-only one. Showing
    // another here would be the double notification. All that is left is the
    // navigation, the widget refresh and the log line.
    //
    // Parsed BEFORE the analytics call (review 2026-09-22 A2) so the open can
    // carry the Drop's own metadata.
    final qotdPush = QotdPushPayload.parse(
      message.data,
      notificationTitle: message.notification?.title,
      notificationBody: message.notification?.body,
    );

    // §4.2 fix: this handler runs on a notification TAP (onMessageOpenedApp /
    // getInitialMessage), so record notification_opened with the precise type
    // (makes the received→opened funnel real; QOTD effectiveness measurable).
    //
    // A2: `seconds_since_publish` is the single number the Drop launch is
    // judged on — median seconds from drop to open — and `push_kind` says
    // whether drop-mode outperforms legacy-mode when the server flips. No
    // question id and no history id: the metadata is about the Drop, not about
    // who opened it.
    AnalyticsService().trackNotificationOpened(
      message.data['type']?.toString() ?? 'unknown',
      {
        'delivery': 'fcm',
        if (qotdPush != null) 'push_kind': qotdPush.kind.name,
        if (qotdPush != null) 'is_drop': qotdPush.isDrop,
        if (qotdPush?.publishedAt != null)
          'seconds_since_publish': DateTime.now()
              .toUtc()
              .difference(qotdPush!.publishedAt!.toUtc())
              .inSeconds,
      },
    );
    if (qotdPush != null) {
      // The tap lands on home, where today's question already sits at the
      // top — not on the question screen (owner decision 2026-09-22).
      _pendingHomeNavigation = true;
      _persistPendingNavigation('home', 'qotd');
      print('🦎 FCM: QOTD tap — pending navigation to home');

      final qotdQuestionId = qotdPush.questionId;
      if (qotdQuestionId != null) {
        // Update home screen widget with real question data
        await _updateQOTDWidgetWithFreshData(qotdQuestionId, qotdPush.body);
      }

      await _logNotificationToInAppLog(
        qotdPush.title,
        qotdPush.body,
        qotdPush.navigationPayload,
      );
      return;
    }

    // For background messages, the system already shows the notification
    // But we still want to log it to our in-app activity feed
    final notificationTitle = message.notification?.title ?? 'Notification';
    final notificationBody = message.notification?.body ?? '';

    // Friend events are checked FIRST: a forward's push does carry the
    // forwarded question's id (as `forwardQuestionId`, deliberately not
    // `questionId`), but the tap belongs to the chat, not the question.
    if (message.data['type'] == 'friend_event') {
      final actorId = message.data['senderId'] ??
          message.data['actorId'] ??
          message.data['actor_id'];
      if (actorId != null) {
        _pendingFriendNavigation = actorId;
        // `_persistPendingNavigation` is a fire-and-forget `void` async, as
        // the question path uses it.
        _persistPendingNavigation('friend', actorId);
        print('🦎 FCM: Stored pending navigation for friend: $actorId');
      }
      await _logNotificationToInAppLog(
        notificationTitle,
        notificationBody,
        actorId != null ? 'friend_$actorId' : null,
      );
      return;
    }

    // We just need to handle the tap action here
    final questionId = message.data['questionId'] ?? message.data['question_id'];

    String? payload;
    if (questionId != null) {
      payload = 'question_$questionId';
      _pendingQuestionNavigation = questionId;
      print('🦎 FCM: Stored pending navigation for question: $questionId');
      print('🦎 SINGLETON: Stored on instance ${identityHashCode(this)}, _pendingQuestionNavigation = $_pendingQuestionNavigation');
    }

    // Log to activity feed
    await _logNotificationToInAppLog(
      notificationTitle,
      notificationBody,
      payload,
    );
  }

  // Check if current user is tagged (@username) in a comment
  Future<bool> _isUserTaggedInComment(String questionId, String commentContent) async {
    if (!commentContent.contains('@')) return false;

    try {
      final currentUserId = _supabase.auth.currentUser?.id;
      if (currentUserId == null) return false;

      final response = await _supabase
          .from('question_comment_usernames')
          .select('randomized_username')
          .eq('question_id', questionId)
          .eq('user_id', currentUserId)
          .maybeSingle();

      if (response == null) return false;
      final username = response['randomized_username'] as String?;
      if (username == null) return false;

      return commentContent.contains('@$username');
    } catch (e) {
      print('Error checking user tag in comment: $e');
      return false;
    }
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

      // Determine question type and tag status for rate limiting
      final questionType = message.data['question_type'] ?? message.data['questionType'] ?? '';
      final commentContent = message.data['commentContent'] ?? message.data['comment_content'] ?? '';
      final isDiscussion = questionType == 'text';

      // Check if user is tagged in this comment (only worth checking if comment has @)
      bool isTagged = false;
      if (commentContent.contains('@')) {
        isTagged = await _isUserTaggedInComment(questionId, commentContent);
      }

      // Tagged users always get immediate notification — skip rate limiting
      if (!isTagged) {
        // Determine rate limit based on question type
        // Discussion: 1 per 3 hours for regular subscribers, 1 per hour for author
        // Other types: 2 per hour (existing behavior)
        int maxNotifications;
        int windowHours;

        if (isDiscussion) {
          // Check if current user is the question author
          final currentUserId = _supabase.auth.currentUser?.id;
          final isAuthor = entry['subscription_source'] == 'author';

          if (isAuthor) {
            maxNotifications = 1;
            windowHours = 1;
          } else {
            maxNotifications = 1;
            windowHours = 3;
          }
        } else {
          maxNotifications = 2;
          windowHours = 1;
        }

        final commentRateLimitKey = 'comment_rate_limit_$questionId';
        final rateLimit = prefs.getString(commentRateLimitKey);
        final now = DateTime.now();

        if (rateLimit != null) {
          final Map<String, dynamic> rateLimitData = json.decode(rateLimit);
          final lastResetTime = DateTime.parse(rateLimitData['last_reset']);
          final notificationCount = rateLimitData['count'] ?? 0;

          // Reset counter if window has passed
          if (now.difference(lastResetTime).inHours >= windowHours) {
            await prefs.setString(commentRateLimitKey, json.encode({
              'count': 1,
              'last_reset': now.toIso8601String(),
            }));
          } else if (notificationCount >= maxNotifications) {
            // Rate limit exceeded - skip notification but still log to in-app activity
            print('🦎 Comment notification: Rate limit exceeded for question $questionId ($notificationCount/$maxNotifications per ${windowHours}h)');
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
      } else {
        print('🦎 Comment notification: User tagged in comment, bypassing rate limit for question $questionId');
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

  /// Shows a QOTD push the instant it arrives, on its own channel.
  ///
  /// Kept separate from [_showLocalNotification] because the Drop needs the
  /// max-importance `qotd_drop` channel (and, for the legacy payload, the old
  /// `qotd_channel`) rather than that method's title-sniffing channel choice.
  ///
  /// Nothing here decides *when* the notification appears: the server's random
  /// drop minute already did that. Call it and it shows.
  Future<void> _showQotdNotification(QotdPushPayload push) async {
    await _logNotificationToInAppLog(
      push.title,
      push.body,
      push.navigationPayload,
    );

    final androidDetails = AndroidNotificationDetails(
      push.androidChannelId,
      push.isDrop ? 'The Daily Drop' : 'Question of the Day',
      channelDescription: push.isDrop
          ? 'The moment the day\'s question drops — one a day, at a different time each day'
          : 'Notifications for new Question of the Day',
      importance: push.isDrop ? Importance.max : Importance.high,
      priority: Priority.high,
      icon: 'ic_stat_rtr_logo_aug2025',
      playSound: true,
      enableVibration: true,
      // A second drop notification should replace the first, never stack —
      // matching the server's `collapse_key: qotd_drop`.
      tag: push.isDrop ? 'qotd_drop' : null,
    );

    final iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
      // Only the drop claims time-sensitive (and only once the entitlement is
      // filed — O-4; until then iOS ignores the level rather than failing).
      interruptionLevel:
          push.isDrop ? InterruptionLevel.timeSensitive : InterruptionLevel.active,
    );

    await _localNotifications.show(
      // Same id for every drop, so a re-delivery replaces rather than stacks.
      _qotdNotificationId,
      push.title,
      push.body,
      NotificationDetails(android: androidDetails, iOS: iosDetails),
      payload: push.navigationPayload,
    );
    print('📆 QOTD notification shown immediately (${push.kind.name})');
  }

  /// Fixed local-notification id for the day's QOTD, so a re-sent drop replaces
  /// the one already on screen.
  static const int _qotdNotificationId = 2100;

  /// Debug-only: shows a local notification carrying the exact copy the
  /// `send-friend-event-notifications` edge function would have sent, with the
  /// same `friend_{actorId}` payload a real friend push carries — so a tap
  /// routes through [_onNotificationTap] → `_pendingFriendNavigation` →
  /// `readtheroom://friend/{actorId}` just like the real thing.
  ///
  /// Used by "Demo friends" mode (`lib/src/services/demo/`), which is itself
  /// gated on [kDebugMode]; nothing in a release build calls this.
  Future<void> showDemoFriendNotification({
    required String title,
    required String body,
    required String actorId,
  }) {
    return _showLocalNotification(
      title: title,
      body: body,
      payload: 'friend_$actorId',
    );
  }

  void _onNotificationTap(NotificationResponse response) {
    // Handle notification tap
    print('🦎 NOTIFICATION TAP: Received tap response');
    print('🦎 SINGLETON: _onNotificationTap called on instance ${identityHashCode(this)}');

    if (response.payload != null) {
      print('🦎 NOTIFICATION TAP: Payload received: ${response.payload}');

      // §4.2 fix: wire notification_opened for local-notification taps. The
      // local payload carries no finer type than "this is a question"; precise
      // types arrive via the FCM open path.
      final openedType = QotdPushPayload.isQotdNavigationPayload(response.payload!)
          ? 'qotd'
          : response.payload!.startsWith('question_')
              ? 'question'
              : 'unknown';
      AnalyticsService().trackNotificationOpened(openedType, {'delivery': 'local'});

      // QOTD (the Drop or the legacy push, shown locally): open on home, not
      // the question (owner decision 2026-09-22).
      if (QotdPushPayload.isQotdNavigationPayload(response.payload!)) {
        print('🦎 NOTIFICATION TAP: ✅ QOTD tapped — pending navigation to home');
        _pendingHomeNavigation = true;
        _persistPendingNavigation('home', 'qotd');
      }
      // Check if it's a question notification
      else if (response.payload!.startsWith('question_')) {
        final questionId = response.payload!.substring('question_'.length);
        print('🦎 NOTIFICATION TAP: ✅ Question ID extracted: $questionId');

        // Store the question ID for navigation when app context is available
        _pendingQuestionNavigation = questionId;
        print('🦎 NOTIFICATION TAP: ✅ Stored pending navigation for question: $questionId');

        // Also persist to SharedPreferences for cold-start reliability
        _persistPendingNavigation('question', questionId);
      }
      // Friend event (WP-F): open that friend's chat overlay.
      else if (response.payload!.startsWith('friend_')) {
        final friendId = response.payload!.substring('friend_'.length);
        print('🦎 NOTIFICATION TAP: ✅ Friend ID extracted: $friendId');

        _pendingFriendNavigation = friendId;
        _persistPendingNavigation('friend', friendId);
      } else {
        print('🦎 NOTIFICATION TAP: ❌ Payload is not a qotd, "question_" or "friend_" payload: ${response.payload}');
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
      } else if (type == 'friend') {
        await prefs.setString('pending_friend_navigation', id);
      } else if (type == 'home') {
        await prefs.setBool('pending_home_navigation', true);
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
      AnalyticsService().trackPushTopicSubscription(
          topic: 'qotd', result: 'ok', trigger: 'settings');
      AnalyticsService().setUserProperties({'qotd_topic_subscribed': true});
    } catch (e) {
      print("❌ Failed to subscribe to QOTD topic: $e");
      AnalyticsService().trackPushTopicSubscription(
          topic: 'qotd', result: 'failed', trigger: 'settings');
    }
  }

  // Method to unsubscribe from QOTD notifications
  Future<void> unsubscribeFromQOTD() async {
    try {
      await _firebaseMessaging.unsubscribeFromTopic('qotd');
      print("✅ Unsubscribed from QOTD topic");
      AnalyticsService().trackPushTopicSubscription(
          topic: 'qotd', result: 'ok', trigger: 'unsubscribe');
      AnalyticsService().setUserProperties({'qotd_topic_subscribed': false});
    } catch (e) {
      print("❌ Failed to unsubscribe from QOTD topic: $e");
      AnalyticsService().trackPushTopicSubscription(
          topic: 'qotd', result: 'failed', trigger: 'unsubscribe');
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
      }, onConflict: 'user_id');
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
      }, onConflict: 'user_id');
      print("✅ Updated notification settings to disable question activity");

    } catch (e) {
      print("❌ Failed to unsubscribe from question activity: $e");
    }
  }

  /// Master toggle for friend-graph pushes: requests and acceptances (WP-E),
  /// licks / forwards / reactions (WP-F). Writes
  /// `notification_settings.friend_events_enabled`, which
  /// `send-friend-event-notifications` checks before every send.
  ///
  /// Turning it **on** also subscribes to the personal `user_{id}` topic,
  /// because that is the topic friend pushes are sent to — and a user who
  /// turned "Comments & Activity" off has been unsubscribed from it, so without
  /// this the switch would appear to work and deliver nothing.
  ///
  /// Turning it **off** does *not* unsubscribe: the same topic carries vote and
  /// comment activity, which this switch has no business disabling. The
  /// server-side flag is what suppresses friend pushes.
  Future<void> setFriendEventsEnabled(bool enabled) async {
    try {
      final user = _supabase.auth.currentUser;
      if (user == null) {
        print("❌ Cannot set friend event notifications: user not authenticated");
        return;
      }

      if (enabled) {
        await _firebaseMessaging.subscribeToTopic('user_${user.id}');
      }

      await _supabase.from('notification_settings').upsert({
        'user_id': user.id,
        'friend_events_enabled': enabled,
      }, onConflict: 'user_id');
      print("✅ friend_events_enabled = $enabled");
    } catch (e) {
      print("❌ Failed to set friend event notifications: $e");
    }
  }

  /// Writes `notification_settings.qotd_enabled`.
  ///
  /// QOTD push is delivered to the `qotd` FCM topic, so the subscription is what
  /// actually gates delivery — but this column existed from the start and the
  /// client never wrote it, leaving every row at its `true` default regardless
  /// of what the user chose. Called from `UserService.setNotifyQOTD`.
  Future<void> setQotdEnabled(bool enabled) async {
    await _upsertNotificationSettings({'qotd_enabled': enabled});
  }

  /// Writes the quiet-hours window (and the timezone it is interpreted in).
  ///
  /// `null` start/end clears the window. The send-side edge functions defer a
  /// push that lands inside it, so this is server-authoritative — there is no
  /// local equivalent.
  Future<void> setQuietHours({
    required String? start,
    required String? end,
    String? timezone,
  }) async {
    await _upsertNotificationSettings({
      'quiet_hours_start': start,
      'quiet_hours_end': end,
      if (timezone != null) 'timezone': timezone,
    });
  }

  /// Reads the caller's `notification_settings` row, or null when there is none
  /// (a user who has never changed a setting) or the read fails.
  Future<Map<String, dynamic>?> fetchNotificationSettings() async {
    try {
      final user = _supabase.auth.currentUser;
      if (user == null) return null;
      final rows = await _supabase
          .from('notification_settings')
          .select()
          .eq('user_id', user.id)
          .limit(1);
      if (rows.isNotEmpty) {
        return Map<String, dynamic>.from(rows.first);
      }
      return null;
    } catch (e) {
      print("❌ Failed to read notification settings: $e");
      return null;
    }
  }

  /// One merge-on-`user_id` write for `notification_settings`.
  ///
  /// `onConflict: 'user_id'` is load-bearing: the table's primary key is `id`
  /// (uuid, defaulted), so a plain upsert infers the PK, never finds a conflict,
  /// and the INSERT fails on the separate `unique(user_id)` for every user who
  /// already has a row — silently, because the caller swallows the error.
  Future<void> _upsertNotificationSettings(Map<String, dynamic> values) async {
    try {
      final user = _supabase.auth.currentUser;
      if (user == null) {
        print("❌ Cannot write notification settings: user not authenticated");
        return;
      }
      await _supabase.from('notification_settings').upsert({
        'user_id': user.id,
        ...values,
      }, onConflict: 'user_id');
      print("✅ notification_settings updated: ${values.keys.join(', ')}");
    } catch (e) {
      print("❌ Failed to write notification settings: $e");
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

      // `provisional` is iOS "deliver quietly": notifications ARE delivered, to
      // Notification Centre rather than as banners. Treating it as a denial used
      // to hand the caller `false`, which ran the denied branch and unsubscribed
      // a user who could in fact be reached.
      if (settings.authorizationStatus == AuthorizationStatus.authorized ||
          settings.authorizationStatus == AuthorizationStatus.provisional) {
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

  /// Pending home navigation from a tapped QOTD push (owner decision
  /// 2026-09-22: the Drop opens the app on home, not the question).
  ///
  /// Cleared on read and drained in `main.dart` into `readtheroom://home`.
  /// Also drains the SharedPreferences copy, which is what survives a cold
  /// start where the singleton is rebuilt before anyone asks.
  Future<bool> getPendingHomeNavigation() async {
    var pending = _pendingHomeNavigation;
    _pendingHomeNavigation = false;

    try {
      final prefs = await SharedPreferences.getInstance();
      pending = pending || (prefs.getBool('pending_home_navigation') ?? false);
      await prefs.remove('pending_home_navigation');
    } catch (e) {
      print('🦎 NOTIFICATION NAV: Error reading pending home navigation: $e');
    }

    if (pending) {
      print('🦎 NOTIFICATION NAV: Retrieved pending home navigation (QOTD)');
    }
    return pending;
  }

  /// Pending friend-chat navigation from a tapped friend-event push (WP-F).
  ///
  /// Cleared on read, like the question equivalent, and drained
  /// in `main.dart` into `readtheroom://friend/{userId}`. Also drains the
  /// SharedPreferences copy, which is what survives a cold start where the
  /// singleton is rebuilt before anyone asks.
  Future<String?> getPendingFriendNavigation() async {
    var friendId = _pendingFriendNavigation;
    _pendingFriendNavigation = null;

    try {
      final prefs = await SharedPreferences.getInstance();
      friendId ??= prefs.getString('pending_friend_navigation');
      await prefs.remove('pending_friend_navigation');
    } catch (e) {
      print('🦎 NOTIFICATION NAV: Error reading pending friend navigation: $e');
    }

    if (friendId != null) {
      print('🦎 NOTIFICATION NAV: Retrieved pending friend navigation: $friendId');
    }
    return friendId;
  }

  // Check if notification permissions are already granted
  Future<bool> arePermissionsGranted() async {
    try {
      final settings = await _firebaseMessaging.getNotificationSettings();
      // Provisional counts as granted — see requestPermissions().
      return settings.authorizationStatus == AuthorizationStatus.authorized ||
          settings.authorizationStatus == AuthorizationStatus.provisional;
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
                    // Get current answer count from the results RPC
          final currentVoteCount =
              await ResultsService().fetchTotalCount(questionId);
          
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
      String notificationType = 'system';

      // Parse payload to extract IDs and determine type
      if (payload != null) {
        if (QotdPushPayload.isQotdNavigationPayload(payload)) {
          // Either QOTD shape. The tap lands on home, but the log entry still
          // links to the question when the push named one.
          notificationType = 'qotd';
          questionId = QotdPushPayload.questionIdFromNavigationPayload(payload);
        } else if (payload.startsWith('question_')) {
          questionId = payload.substring('question_'.length);
          if (title.contains('💬')) {
            notificationType = 'comment';
          } else if (title.contains('📆')) {
            notificationType = 'qotd';
          } else if (title.contains('🦎')) {
            notificationType = 'vote_activity';
          } else if (title.contains('❓') || title.contains('⚡')) {
            // '⚡' is the Drop's own title ("⚡ Today's question just
            // dropped" / "⚡ N spots left ..."), composed server-side.
            notificationType = 'qotd';
          }
        }
      }


      final notification = NotificationLogService.createFromRemoteMessage(
        title: title,
        body: body,
        type: notificationType,
        questionId: questionId,
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
            final voteCount = await ResultsService().fetchTotalCount(questionId);

      final commentCountQuery = await _supabase
          .from('comments')
          .select('id')
          .eq('question_id', questionId);
      final commentCount = commentCountQuery.length;

      // Local state: `responses` is anonymous (no user column), so the
      // server cannot say whether THIS user answered.
      final hasAnswered = await UserService.hasAnsweredLocally(questionId);

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