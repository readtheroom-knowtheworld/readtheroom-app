// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// One-shot upgrade chore: cancel the local streak reminders the *previous*
// release scheduled, and forget the settings that drove them.
//
// Until this release `StreakReminderService` kept a rolling seven-day window of
// local notifications (ids 1001–1007) at the user's chosen time, rescheduling
// the whole window on startup, on resume and after every answer. Daily return
// is now driven by the QOTD Drop push, licks and chats, so the feature — the
// setting, the scheduler and every mention of it — is gone.
//
// Deleting the Dart does **not** unschedule what the OS already holds: an
// upgrading device that had reminders on would keep firing "🔥 Keep your streak
// going!" for up to a week, from a feature that no longer exists and that the
// user can no longer turn off. So the seven ids are cancelled here, once, at
// startup.
//
// Runs whatever the notification settings say (a user who turned reminders off
// long ago has no pending ids, and cancelling an id that is not scheduled is a
// no-op), is idempotent, and records itself in SharedPreferences so it costs
// one bool read on every later launch.
//
// Streaks themselves are untouched: the pill, the dialog, the celebration, the
// Me-screen card and `active_streaks` all stay. Only the reminder goes.

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

class StreakLegacyReminderCleanup {
  StreakLegacyReminderCleanup._();

  /// Ids `StreakReminderService` used for its 7-day rolling window
  /// (`_baseNotificationId` 1001 + day offset 0..6). The retired QOTD reminders
  /// own 2001–2007 and are cancelled by `QotdLegacyReminderCleanup`.
  static const List<int> legacyNotificationIds = <int>[
    1001,
    1002,
    1003,
    1004,
    1005,
    1006,
    1007,
  ];

  /// Preference keys the retired service and `UserService` wrote: the on/off
  /// switch (both copies of it), the user's chosen time, the rotating-copy
  /// cursor and the scheduling bookkeeping. Nothing reads them any more.
  static const List<String> legacyPreferenceKeys = <String>[
    'notify_streak_reminders',
    'streak_reminders_enabled',
    'streak_reminder_message_index',
    'streak_reminder_time_hour',
    'streak_reminder_time_minute',
    'streak_reminder_last_scheduled',
    'streak_reminder_scheduled_for',
  ];

  /// Set once the cancels have gone through.
  static const String doneKey = 'streak_legacy_reminders_cleared';

  /// Cancels the legacy ids and clears the legacy keys, unless a previous
  /// launch already did.
  ///
  /// [cancel] and [prefs] exist for tests; production passes neither.
  /// Returns true when work was actually done.
  static Future<bool> run({
    Future<void> Function(int id)? cancel,
    SharedPreferences? prefs,
  }) async {
    try {
      final store = prefs ?? await SharedPreferences.getInstance();
      if (store.getBool(doneKey) == true) return false;

      final cancelOne =
          cancel ?? (int id) => FlutterLocalNotificationsPlugin().cancel(id);
      for (final id in legacyNotificationIds) {
        await cancelOne(id);
      }
      for (final key in legacyPreferenceKeys) {
        await store.remove(key);
      }
      await store.setBool(doneKey, true);
      return true;
    } catch (e) {
      // A failed cleanup must never stop the app from starting; the next
      // launch tries again because the flag is only written on success.
      print('🔥 Streak legacy reminder cleanup failed: $e');
      return false;
    }
  }
}
