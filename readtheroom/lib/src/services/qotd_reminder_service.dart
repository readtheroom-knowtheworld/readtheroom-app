// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

// lib/src/services/qotd_reminder_service.dart
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:shared_preferences/shared_preferences.dart';
import 'notification_service.dart';

class QOTDReminderService {
  static final QOTDReminderService _instance = QOTDReminderService._internal();
  factory QOTDReminderService() => _instance;
  QOTDReminderService._internal();

  final FlutterLocalNotificationsPlugin _localNotifications = FlutterLocalNotificationsPlugin();

  // Storage keys
  static const String _reminderEnabledKey = 'qotd_reminders_enabled';
  static const String _messageIndexKey = 'qotd_reminder_message_index';
  static const String _reminderTimeHourKey = 'qotd_reminder_time_hour';
  static const String _reminderTimeMinuteKey = 'qotd_reminder_time_minute';

  // Notification IDs for 7 days (2001-2007, separate from streak's 1001-1007)
  static const int _baseNotificationId = 2001;
  static const int _daysToSchedule = 7;

  // Rotating notification messages
  static const List<Map<String, String>> _notificationMessages = [
    {
      'title': '📆 Question of the Day',
      'body': 'Have you weighed in on today\'s question?',
    },
    {
      'title': '📆 Question of the Day',
      'body': 'The room is waiting for your take.',
    },
    {
      'title': '📆 Question of the Day',
      'body': 'See what everyone\'s discussing today.',
    },
    {
      'title': '📆 Question of the Day',
      'body': 'Today\'s question is live — share your perspective.',
    },
    {
      'title': '📆 Question of the Day',
      'body': 'Your opinion matters. Jump in!',
    },
    {
      'title': '📆 Question of the Day',
      'body': 'A new question is waiting for you.',
    },
    {
      'title': '📆 Question of the Day',
      'body': 'Don\'t miss today\'s question!',
    },
  ];

  /// Get the correct timezone location for the device
  Future<tz.Location> _getLocalTimezone() async {
    try {
      final String deviceTimezoneName = await FlutterTimezone.getLocalTimezone();
      return tz.getLocation(deviceTimezoneName);
    } catch (e) {
      print('📆 Error getting device timezone: $e, falling back to tz.local');
      return tz.local;
    }
  }

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
    print('📆 QOTDReminderService initializing...');

    try {
      final enabled = await areRemindersEnabled();

      if (enabled) {
        final customTime = await getStoredReminderTime();
        final pendingCount = await _countPendingReminders();

        if (pendingCount < _daysToSchedule) {
          print('📆 Only $pendingCount QOTD reminders pending, rescheduling all $_daysToSchedule...');
          await _scheduleAllReminders(customTime);
        } else {
          print('📆 All $_daysToSchedule QOTD reminder notifications already pending');
        }
      } else {
        print('📆 QOTD reminders are disabled');
      }

      print('📆 QOTDReminderService initialized');
    } catch (e) {
      print('📆 Error initializing QOTDReminderService: $e');
    }
  }

  /// Get whether QOTD reminders are enabled
  Future<bool> areRemindersEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_reminderEnabledKey) ?? false;
  }

  /// Get the stored reminder time from SharedPreferences
  Future<TimeOfDay> getStoredReminderTime() async {
    final prefs = await SharedPreferences.getInstance();
    final hour = prefs.getInt(_reminderTimeHourKey) ?? 19; // Default to 7:30 PM
    final minute = prefs.getInt(_reminderTimeMinuteKey) ?? 30;
    return TimeOfDay(hour: hour, minute: minute);
  }

  /// Set whether QOTD reminders are enabled
  Future<void> setRemindersEnabled(bool enabled, [TimeOfDay? customTime]) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_reminderEnabledKey, enabled);

    if (customTime != null) {
      await prefs.setInt(_reminderTimeHourKey, customTime.hour);
      await prefs.setInt(_reminderTimeMinuteKey, customTime.minute);
    }

    if (enabled) {
      final hasPermission = await NotificationService().arePermissionsGranted();
      if (!hasPermission) {
        print('📆 QOTD reminders enabled but notification permissions not granted - skipping scheduling');
        return;
      }

      final timeToUse = customTime ?? await getStoredReminderTime();
      await _scheduleAllReminders(timeToUse);
      print('📆 QOTD reminders enabled - scheduled $_daysToSchedule days of reminders');
    } else {
      await _cancelAllReminders();
      print('📆 QOTD reminders disabled - cancelled all pending reminders');
    }
  }

  /// Update today's scheduled notification with actual QOTD content
  /// Called when FCM data arrives or when app fetches QOTD
  Future<void> updateTodayContent(String questionText, String questionId) async {
    final enabled = await areRemindersEnabled();
    if (!enabled) return;

    try {
      final tz.Location localTz = await _getLocalTimezone();
      final now = tz.TZDateTime.now(localTz);
      final reminderTime = await getStoredReminderTime();

      final scheduledTime = tz.TZDateTime(
        localTz,
        now.year,
        now.month,
        now.day,
        reminderTime.hour,
        reminderTime.minute,
      );

      // Only update if today's notification hasn't fired yet
      if (now.isBefore(scheduledTime)) {
        // Cancel today's notification (ID 2001 = first in the rolling window)
        // We need to find which ID corresponds to today
        await _localNotifications.cancel(_baseNotificationId);

        // Reschedule with actual question content
        await _localNotifications.zonedSchedule(
          _baseNotificationId,
          '📆 Question of the Day',
          questionText,
          scheduledTime,
          NotificationDetails(
            android: AndroidNotificationDetails(
              'qotd_channel',
              'Question of the Day',
              channelDescription: 'Notifications for new Question of the Day',
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
          payload: 'question_$questionId',
        );
        print('📆 Updated today\'s QOTD notification with question: $questionText');
      } else {
        print('📆 Today\'s QOTD notification time already passed, skipping update');
      }
    } catch (e) {
      print('📆 Error updating today\'s QOTD content: $e');
    }
  }

  /// Schedule reminders for the next 7 days
  Future<void> _scheduleAllReminders([TimeOfDay? customTime]) async {
    await _cancelAllReminders();

    final reminderTimeOfDay = customTime ?? await getStoredReminderTime();
    final tz.Location localTz = await _getLocalTimezone();
    final now = tz.TZDateTime.now(localTz);
    final startingMessageIndex = await _getMessageIndex();

    print('📆 Scheduling $_daysToSchedule days of QOTD reminders at ${reminderTimeOfDay.hour}:${reminderTimeOfDay.minute.toString().padLeft(2, '0')}');

    for (int dayOffset = 0; dayOffset < _daysToSchedule; dayOffset++) {
      final notificationId = _baseNotificationId + dayOffset;

      final scheduledTime = tz.TZDateTime(
        localTz,
        now.year,
        now.month,
        now.day,
        reminderTimeOfDay.hour,
        reminderTimeOfDay.minute,
      );

      // Start from today if time hasn't passed, or tomorrow if it has
      final tz.TZDateTime startDate;
      if (now.isAfter(scheduledTime)) {
        startDate = scheduledTime.add(Duration(days: 1));
      } else {
        startDate = scheduledTime;
      }

      final reminderTime = startDate.add(Duration(days: dayOffset));
      final messageIndex = (startingMessageIndex + dayOffset) % _notificationMessages.length;

      await _scheduleSingleReminder(notificationId, reminderTime, messageIndex);
    }

    await _saveMessageIndex(startingMessageIndex + 1);
    print('📆 Successfully scheduled $_daysToSchedule QOTD reminders');
  }

  /// Schedule a single reminder notification
  Future<void> _scheduleSingleReminder(int notificationId, tz.TZDateTime reminderTime, int messageIndex) async {
    try {
      final message = _notificationMessages[messageIndex];
      final title = message['title']!;
      final body = message['body']!;

      await _localNotifications.zonedSchedule(
        notificationId,
        title,
        body,
        reminderTime,
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'qotd_channel',
            'Question of the Day',
            channelDescription: 'Notifications for new Question of the Day',
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
      print('📆 Scheduled QOTD reminder #$notificationId for $reminderTime - "$title"');
    } catch (e) {
      print('📆 Error scheduling QOTD reminder #$notificationId: $e');
    }
  }

  /// Cancel all QOTD reminder notifications (IDs 2001-2007)
  Future<void> _cancelAllReminders() async {
    try {
      for (int i = 0; i < _daysToSchedule; i++) {
        final notificationId = _baseNotificationId + i;
        await _localNotifications.cancel(notificationId);
      }
      print('📆 Cancelled all $_daysToSchedule QOTD reminder notifications');
    } catch (e) {
      print('📆 Error cancelling QOTD reminders: $e');
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
      return count;
    } catch (e) {
      print('📆 Error counting pending QOTD notifications: $e');
      return 0;
    }
  }
}
