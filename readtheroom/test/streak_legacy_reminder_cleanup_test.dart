// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The upgrade chore that stops an upgrading device firing streak reminders for
// a feature that no longer exists
// (`lib/src/services/streak_legacy_reminder_cleanup.dart`).
//
// This is the one piece of the removal that cannot be re-run: if the seven
// pending ids are not cancelled on the first launch of the new build, the old
// notifications keep arriving for up to a week — from a setting the user can no
// longer see, let alone switch off.

import 'package:flutter_test/flutter_test.dart';
import 'package:read_the_room/src/services/streak_legacy_reminder_cleanup.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<SharedPreferences> prefsWith(Map<String, Object> values) async {
    SharedPreferences.setMockInitialValues(values);
    return SharedPreferences.getInstance();
  }

  test('cancels exactly the seven retired streak ids', () async {
    final cancelled = <int>[];
    final prefs = await prefsWith(<String, Object>{});

    final didWork = await StreakLegacyReminderCleanup.run(
      cancel: (id) async => cancelled.add(id),
      prefs: prefs,
    );

    expect(didWork, isTrue);
    expect(cancelled, <int>[1001, 1002, 1003, 1004, 1005, 1006, 1007]);
    // The retired QOTD reminders (2001–2007) belong to the other chore.
    expect(cancelled.where((id) => id >= 2000), isEmpty);
  });

  test('forgets the switch, the chosen time and the scheduling bookkeeping',
      () async {
    final prefs = await prefsWith(<String, Object>{
      'notify_streak_reminders': true,
      'streak_reminders_enabled': true,
      'streak_reminder_time_hour': 21,
      'streak_reminder_time_minute': 30,
      'streak_reminder_message_index': 4,
      'streak_reminder_last_scheduled': '2026-09-21T18:00:00.000',
      'streak_reminder_scheduled_for': '2026-09-22T21:30:00.000',
      // Not ours: streaks themselves stay, as do the other categories.
      'notify_qotd': true,
      'notify_friend_events': true,
      'qotd_reminder_time_hour': 19,
    });

    await StreakLegacyReminderCleanup.run(cancel: (_) async {}, prefs: prefs);

    for (final key in StreakLegacyReminderCleanup.legacyPreferenceKeys) {
      expect(prefs.containsKey(key), isFalse, reason: '$key should be gone');
    }
    expect(prefs.getBool('notify_qotd'), isTrue);
    expect(prefs.getBool('notify_friend_events'), isTrue);
    expect(prefs.getInt('qotd_reminder_time_hour'), 19);
  });

  test('runs once: the second launch is a no-op', () async {
    final prefs = await prefsWith(<String, Object>{});
    var calls = 0;

    expect(
      await StreakLegacyReminderCleanup.run(
          cancel: (_) async => calls++, prefs: prefs),
      isTrue,
    );
    expect(prefs.getBool(StreakLegacyReminderCleanup.doneKey), isTrue);

    expect(
      await StreakLegacyReminderCleanup.run(
          cancel: (_) async => calls++, prefs: prefs),
      isFalse,
    );
    expect(calls, StreakLegacyReminderCleanup.legacyNotificationIds.length);
  });

  test('a failed cancel leaves the chore to be retried next launch', () async {
    final prefs = await prefsWith(<String, Object>{
      'notify_streak_reminders': true,
    });

    final didWork = await StreakLegacyReminderCleanup.run(
      cancel: (_) async => throw Exception('plugin unavailable'),
      prefs: prefs,
    );

    expect(didWork, isFalse);
    expect(prefs.getBool(StreakLegacyReminderCleanup.doneKey), isNull);
    // Nothing was forgotten either, so the retry still has work to do.
    expect(prefs.getBool('notify_streak_reminders'), isTrue);
  });

  test('the two upgrade chores do not fight over ids or keys', () async {
    expect(
      StreakLegacyReminderCleanup.legacyNotificationIds
          .toSet()
          .intersection(<int>{2001, 2002, 2003, 2004, 2005, 2006, 2007}),
      isEmpty,
    );
  });
}
