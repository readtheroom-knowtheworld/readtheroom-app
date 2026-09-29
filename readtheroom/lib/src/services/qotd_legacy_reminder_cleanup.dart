// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// One-shot upgrade chore: cancel the local QOTD reminders the *previous*
// release scheduled, and forget the custom reminder time.
//
// Until this release the QOTD notification was timed by the device:
// `QOTDReminderService` scheduled seven days of local notifications (ids
// 2001–2007) at the user's chosen time (7:30 PM by default) and the data-only
// push merely rewrote today's text. The Drop makes the server's random minute
// the moment (`feature-documentation/qotd-drop-voting-2026-08-31.md` §2.2), so
// that service is gone.
//
// Those seven notifications are already in the OS's hands. Deleting the Dart
// that made them does **not** unschedule them: an upgrading device would keep
// firing a 7:30 PM "Question of the Day" for up to a week *on top of* the drop
// push — the exact double notification the cutover is supposed to prevent. So
// the ids are cancelled here, once, at startup.
//
// Runs whatever the notification settings say (a user who turned QOTD off still
// has pending ids if they were ever on), is idempotent, and records itself in
// SharedPreferences so it costs one bool read on every later launch.

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

class QotdLegacyReminderCleanup {
  QotdLegacyReminderCleanup._();

  /// Ids `QOTDReminderService` used for its 7-day rolling window. The retired
  /// streak reminders own 1001–1007 and are **not** touched here — they have
  /// their own chore, `StreakLegacyReminderCleanup`.
  static const List<int> legacyNotificationIds = <int>[
    2001,
    2002,
    2003,
    2004,
    2005,
    2006,
    2007,
  ];

  /// Preference keys the retired service and `UserService` wrote for the custom
  /// time and the rotating-copy cursor. Nothing reads them any more.
  static const List<String> legacyPreferenceKeys = <String>[
    'qotd_reminders_enabled',
    'qotd_reminder_message_index',
    'qotd_reminder_time_hour',
    'qotd_reminder_time_minute',
  ];

  /// Set once the cancels have gone through.
  static const String doneKey = 'qotd_legacy_reminders_cleared';

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

      final cancelOne = cancel ??
          (int id) => FlutterLocalNotificationsPlugin().cancel(id);
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
      print('📆 QOTD legacy reminder cleanup failed: $e');
      return false;
    }
  }
}
