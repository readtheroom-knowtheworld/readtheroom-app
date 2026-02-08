// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

// lib/src/services/streak_reminder_service.dart
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:shared_preferences/shared_preferences.dart';
import 'notification_service.dart';

class StreakReminderService {
  static final StreakReminderService _instance = StreakReminderService._internal();
  factory StreakReminderService() => _instance;
  StreakReminderService._internal();

  final FlutterLocalNotificationsPlugin _localNotifications = FlutterLocalNotificationsPlugin();

  // Storage keys
  static const String _reminderEnabledKey = 'streak_reminders_enabled';
  static const String _messageIndexKey = 'streak_reminder_message_index';

  /// Get the correct timezone location for the device
  Future<tz.Location> _getLocalTimezone() async {
    try {
      final String deviceTimezoneName = await FlutterTimezone.getLocalTimezone();
      print('🔥 Device timezone: $deviceTimezoneName');
      return tz.getLocation(deviceTimezoneName);
    } catch (e) {
      print('🔥 Error getting device timezone: $e, falling back to tz.local');
      return tz.local;
    }
  }
  static const String _reminderTimeHourKey = 'streak_reminder_time_hour';
  static const String _reminderTimeMinuteKey = 'streak_reminder_time_minute';
  static const String _lastScheduledKey = 'streak_reminder_last_scheduled';
  static const String _scheduledForKey = 'streak_reminder_scheduled_for';

  // Notification IDs for 7 days (1001-1007)
  static const int _baseNotificationId = 1001;
  static const int _daysToSchedule = 7;

  // Rotating notification messages to keep them fresh
  // Note: These are for users who ALREADY have a streak and need a reminder to maintain it
  static const List<Map<String, String>> _notificationMessages = [
    {
      'title': '🔥 Keep your streak going!',
      'body': 'Your voice matters.',
    },
    {
      'title': '🔥 Your streak is waiting',
      'body': 'Got a take? The world\'s listening.',
    },
    {
      'title': '🔥 Don\'t break the chain',
      'body': 'Your perspective counts.',
    },
    {
      'title': '🔥 The world\'s weighing in',
      'body': 'Add your voice before the day ends.',
    },
    {
      'title': '🔥 Another day, another ask',
      'body': 'Keep your streak alive with a quick answer.',
    },
    {
      'title': '🔥 You\'re on a roll!',
      'body': 'Keep it going! New questions are live.',
    },
    {
      'title': '🔥 Don\'t leave us hanging',
      'body': 'Your answer helps paint the picture.',
    },
    {
      'title': '🔥 The polls are open',
      'body': 'Weigh in and keep your streak intact.',
    },
    {
      'title': '🔥 Your turn',
      'body': 'The world\'s talking. Add your voice.',
    },
  ];

  // Special message for users with streak of exactly 1
  static const Map<String, String> _newStreakMessage = {
    'title': '🔥 Welcome to the streak',
    'body': 'Your voice matters. Let\'s keep it going!',
  };

  /// Get the current message index for rotation
  Future<int> _getMessageIndex() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_messageIndexKey) ?? 0;
  }

  /// Save the next message index for rotation
  Future<void> _saveMessageIndex(int index) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_messageIndexKey, index % _notificationMessages.length);
  }

  /// Initialize the service and reschedule notifications if enabled
  /// This should be called on app startup
  Future<void> initialize() async {
    print('🔥 StreakReminderService initializing...');

    try {
      final enabled = await areRemindersEnabled();

      if (enabled) {
        // Get the stored custom time
        final customTime = await getStoredReminderTime();

        // Check if any notifications are pending
        final pendingCount = await _countPendingReminders();

        if (pendingCount < _daysToSchedule) {
          // Some or all notifications are missing, reschedule all
          print('🔥 Only $pendingCount streak reminders pending, rescheduling all $_daysToSchedule...');
          await _scheduleAllReminders(customTime);
        } else {
          print('🔥 All $_daysToSchedule streak reminder notifications already pending');
        }
      } else {
        print('🔥 Streak reminders are disabled');
      }

      print('🔥 StreakReminderService initialized');
    } catch (e) {
      print('🔥 Error initializing StreakReminderService: $e');
    }
  }

  /// Get whether streak reminders are enabled
  Future<bool> areRemindersEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_reminderEnabledKey) ?? false;
  }

  /// Get the stored reminder time from SharedPreferences
  Future<TimeOfDay> getStoredReminderTime() async {
    final prefs = await SharedPreferences.getInstance();
    final hour = prefs.getInt(_reminderTimeHourKey) ?? 21; // Default to 9 PM
    final minute = prefs.getInt(_reminderTimeMinuteKey) ?? 0;
    return TimeOfDay(hour: hour, minute: minute);
  }

  /// Set whether streak reminders are enabled
  Future<void> setRemindersEnabled(bool enabled, [TimeOfDay? customTime]) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_reminderEnabledKey, enabled);

    // Also store the custom time if provided
    if (customTime != null) {
      await prefs.setInt(_reminderTimeHourKey, customTime.hour);
      await prefs.setInt(_reminderTimeMinuteKey, customTime.minute);
    }

    if (enabled) {
      // Check notification permissions before scheduling
      final hasPermission = await NotificationService().arePermissionsGranted();
      if (!hasPermission) {
        print('🔥 Streak reminders enabled but notification permissions not granted - skipping scheduling');
        return;
      }

      final timeToUse = customTime ?? await getStoredReminderTime();
      await _scheduleAllReminders(timeToUse);
      print('🔥 Streak reminders enabled - scheduled $_daysToSchedule days of reminders');
    } else {
      await _cancelAllReminders();
      await _clearScheduledInfo();
      print('🔥 Streak reminders disabled - cancelled all pending reminders');
    }
  }

  /// Schedule reminders for the next 7 days
  /// If [skipToday] is true, always start from tomorrow (use when user already answered today)
  /// If [currentStreak] is 1, use the "Welcome to the streak" message for day 1
  Future<void> _scheduleAllReminders([TimeOfDay? customTime, bool skipToday = false, int? currentStreak]) async {
    // First cancel all existing reminders
    await _cancelAllReminders();

    final reminderTimeOfDay = customTime ?? await getStoredReminderTime();

    // Get the correct timezone for the device
    final tz.Location localTz = await _getLocalTimezone();
    final now = tz.TZDateTime.now(localTz);

    // Get the current message index for rotation (so daily users see different messages)
    final startingMessageIndex = await _getMessageIndex();

    print('🔥 Scheduling $_daysToSchedule days of streak reminders at ${reminderTimeOfDay.hour}:${reminderTimeOfDay.minute.toString().padLeft(2, '0')}');
    print('🔥 Timezone: ${localTz.name}');
    print('🔥 Current local time: $now');
    print('🔥 Timezone offset: ${now.timeZoneOffset}');
    print('🔥 Skip today: $skipToday');
    print('🔥 Starting message index: $startingMessageIndex');

    for (int dayOffset = 0; dayOffset < _daysToSchedule; dayOffset++) {
      final notificationId = _baseNotificationId + dayOffset;

      // Calculate the scheduled time for today at the reminder time
      final scheduledTime = tz.TZDateTime(
        localTz,
        now.year,
        now.month,
        now.day,
        reminderTimeOfDay.hour,
        reminderTimeOfDay.minute,
      );

      // Determine start date:
      // - If skipToday is true (user already answered), always start from tomorrow
      // - Otherwise, start from today if time hasn't passed, or tomorrow if it has
      final tz.TZDateTime startDate;
      if (skipToday) {
        startDate = scheduledTime.add(Duration(days: 1));
      } else if (now.isAfter(scheduledTime)) {
        startDate = scheduledTime.add(Duration(days: 1));
      } else {
        startDate = scheduledTime;
      }

      final reminderTime = startDate.add(Duration(days: dayOffset));

      // Calculate the message index for this day (rotating through all messages)
      final messageIndex = (startingMessageIndex + dayOffset) % _notificationMessages.length;

      await _scheduleSingleReminder(notificationId, reminderTime, dayOffset + 1, currentStreak, messageIndex);
    }

    // Save the next starting index for when we reschedule again
    // This ensures daily users see different messages each day
    await _saveMessageIndex(startingMessageIndex + 1);

    // Store info about the first scheduled notification
    final scheduledTimeToday = tz.TZDateTime(
      localTz,
      now.year,
      now.month,
      now.day,
      reminderTimeOfDay.hour,
      reminderTimeOfDay.minute,
    );

    final tz.TZDateTime firstReminderTime;
    if (skipToday) {
      firstReminderTime = scheduledTimeToday.add(Duration(days: 1));
    } else if (now.isAfter(scheduledTimeToday)) {
      firstReminderTime = scheduledTimeToday.add(Duration(days: 1));
    } else {
      firstReminderTime = scheduledTimeToday;
    }

    await _storeScheduledInfo(firstReminderTime);
    print('🔥 Successfully scheduled $_daysToSchedule streak reminders (first: $firstReminderTime)');
  }

  /// Schedule a single reminder notification
  /// [messageIndex] determines which rotating message to use
  Future<void> _scheduleSingleReminder(int notificationId, tz.TZDateTime reminderTime, int dayNumber, [int? currentStreak, int? messageIndex]) async {
    try {
      // Use special "Welcome" message for day 1 if user just started their streak (streak = 1)
      final Map<String, String> message;
      if (dayNumber == 1 && currentStreak == 1) {
        message = _newStreakMessage;
      } else {
        // Use the provided message index for rotation
        final idx = messageIndex ?? ((dayNumber - 1) % _notificationMessages.length);
        message = _notificationMessages[idx];
      }
      final title = message['title']!;
      final body = message['body']!;

      await _localNotifications.zonedSchedule(
        notificationId,
        title,
        body,
        reminderTime,
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'streak_reminder_v2_channel',
            'Streak Reminders',
            channelDescription: 'Daily reminders to maintain your answer streak',
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
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      );
      print('🔥 Scheduled reminder #$notificationId (day $dayNumber) for $reminderTime - "$title"');
    } catch (e) {
      print('🔥 Error scheduling reminder #$notificationId: $e');
    }
  }

  /// Cancel all streak reminder notifications (IDs 1001-1007)
  Future<void> _cancelAllReminders() async {
    try {
      for (int i = 0; i < _daysToSchedule; i++) {
        final notificationId = _baseNotificationId + i;
        await _localNotifications.cancel(notificationId);
      }
      print('🔥 Cancelled all $_daysToSchedule streak reminder notifications');
    } catch (e) {
      print('🔥 Error cancelling streak reminders: $e');
    }
  }

  /// Count how many of our reminder notifications are still pending
  Future<int> _countPendingReminders() async {
    try {
      final pendingNotifications = await _localNotifications.pendingNotificationRequests();
      int count = 0;
      for (int i = 0; i < _daysToSchedule; i++) {
        final notificationId = _baseNotificationId + i;
        if (pendingNotifications.any((n) => n.id == notificationId)) {
          count++;
        }
      }
      print('🔥 Found $count pending streak reminder notifications');
      return count;
    } catch (e) {
      print('🔥 Error counting pending notifications: $e');
      return 0;
    }
  }

  /// Call this when user answers a question to cancel today's reminder and reschedule
  /// IMPORTANT: Always pass the customTime to preserve user's reminder time preference
  /// Pass [currentStreak] to show "Welcome to the streak" message for new streakers
  Future<void> onQuestionAnswered([TimeOfDay? customTime, int? currentStreak]) async {
    final enabled = await areRemindersEnabled();
    if (!enabled) return;

    // If no custom time provided, get the stored time
    final timeToUse = customTime ?? await getStoredReminderTime();

    // Cancel all and reschedule for next 7 days, SKIPPING TODAY since user already answered
    await _scheduleAllReminders(timeToUse, true, currentStreak); // skipToday = true
    print('🔥 Question answered (streak: $currentStreak) - scheduled next $_daysToSchedule days starting tomorrow at ${timeToUse.hour}:${timeToUse.minute.toString().padLeft(2, '0')}');
  }

  /// Call this to check if reminder should be sent (only send if streak > 0 and no answer today)
  Future<bool> shouldSendReminder(int currentStreak, bool hasExtendedStreakToday) async {
    final enabled = await areRemindersEnabled();

    // Don't send reminder if:
    // - Reminders are disabled
    // - User has no streak (currentStreak == 0)
    // - User has already answered today
    if (!enabled || currentStreak == 0 || hasExtendedStreakToday) {
      return false;
    }

    return true;
  }

  /// Manually trigger reminder scheduling (call when reminders are enabled or app starts)
  Future<void> scheduleReminder([TimeOfDay? customTime]) async {
    final enabled = await areRemindersEnabled();
    if (enabled) {
      final timeToUse = customTime ?? await getStoredReminderTime();
      await _scheduleAllReminders(timeToUse);
    }
  }

  /// Verify notifications are scheduled and reschedule if missing
  /// Call this when app comes to foreground
  Future<void> verifyAndRescheduleIfNeeded([TimeOfDay? customTime]) async {
    final enabled = await areRemindersEnabled();
    if (!enabled) return;

    final pendingCount = await _countPendingReminders();
    if (pendingCount < _daysToSchedule) {
      print('🔥 Only $pendingCount streak reminders pending, rescheduling all...');
      final timeToUse = customTime ?? await getStoredReminderTime();
      await _scheduleAllReminders(timeToUse);
    } else {
      print('🔥 All $_daysToSchedule streak reminder notifications are pending');
    }
  }

  /// Store info about the scheduled notification for recovery
  Future<void> _storeScheduledInfo(DateTime scheduledFor) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_lastScheduledKey, DateTime.now().toIso8601String());
      await prefs.setString(_scheduledForKey, scheduledFor.toIso8601String());
      print('🔥 Stored scheduled info: first reminder at ${scheduledFor.toIso8601String()}');
    } catch (e) {
      print('🔥 Error storing scheduled info: $e');
    }
  }

  /// Clear stored scheduling info
  Future<void> _clearScheduledInfo() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_lastScheduledKey);
      await prefs.remove(_scheduledForKey);
    } catch (e) {
      print('🔥 Error clearing scheduled info: $e');
    }
  }

  /// Get when the notification is scheduled for (if stored)
  Future<DateTime?> getScheduledFor() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final scheduledForStr = prefs.getString(_scheduledForKey);
      if (scheduledForStr != null) {
        return DateTime.parse(scheduledForStr);
      }
    } catch (e) {
      print('🔥 Error getting scheduled for time: $e');
    }
    return null;
  }

  /// Debug method to print current state
  Future<void> debugPrintState() async {
    final enabled = await areRemindersEnabled();
    final time = await getStoredReminderTime();
    final pendingCount = await _countPendingReminders();
    final scheduledFor = await getScheduledFor();

    print('🔥 === Streak Reminder State ===');
    print('🔥 Enabled: $enabled');
    print('🔥 Time: ${time.hour}:${time.minute.toString().padLeft(2, '0')}');
    print('🔥 Pending Reminders: $pendingCount / $_daysToSchedule');
    print('🔥 First Scheduled For: $scheduledFor');
    print('🔥 ==============================');
  }
}
