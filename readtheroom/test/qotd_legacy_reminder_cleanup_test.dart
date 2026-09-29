// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The upgrade chore that stops an upgrading device getting BOTH the drop push
// and the retired 7:30 PM local reminder
// (`lib/src/services/qotd_legacy_reminder_cleanup.dart`).
//
// This is the one piece of the notification-timing change that cannot be
// re-run: if the seven pending ids are not cancelled on the first launch of the
// new build, the old notifications keep firing for up to a week.

import 'package:flutter_test/flutter_test.dart';
import 'package:read_the_room/src/services/qotd_legacy_reminder_cleanup.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<SharedPreferences> prefsWith(Map<String, Object> values) async {
    SharedPreferences.setMockInitialValues(values);
    return SharedPreferences.getInstance();
  }

  test('cancels exactly the seven retired QOTD ids', () async {
    final cancelled = <int>[];
    final prefs = await prefsWith(<String, Object>{});

    final didWork = await QotdLegacyReminderCleanup.run(
      cancel: (id) async => cancelled.add(id),
      prefs: prefs,
    );

    expect(didWork, isTrue);
    expect(cancelled, <int>[2001, 2002, 2003, 2004, 2005, 2006, 2007]);
    // Streak reminders (1001–1007) belong to `StreakLegacyReminderCleanup`.
    expect(cancelled.where((id) => id < 2000), isEmpty);
  });

  test('forgets the custom reminder time and the rotating-copy cursor',
      () async {
    final prefs = await prefsWith(<String, Object>{
      'qotd_reminders_enabled': true,
      'qotd_reminder_time_hour': 19,
      'qotd_reminder_time_minute': 30,
      'qotd_reminder_message_index': 3,
      // Not ours: the streak chore clears this one.
      'streak_reminder_time_hour': 21,
      'notify_qotd': true,
    });

    await QotdLegacyReminderCleanup.run(cancel: (_) async {}, prefs: prefs);

    for (final key in QotdLegacyReminderCleanup.legacyPreferenceKeys) {
      expect(prefs.containsKey(key), isFalse, reason: '$key should be gone');
    }
    // The QOTD on/off switch survives — only the *time* is being removed.
    expect(prefs.getBool('notify_qotd'), isTrue);
    expect(prefs.getInt('streak_reminder_time_hour'), 21);
  });

  test('runs once: the second launch is a no-op', () async {
    final prefs = await prefsWith(<String, Object>{});
    var calls = 0;

    expect(
      await QotdLegacyReminderCleanup.run(
          cancel: (_) async => calls++, prefs: prefs),
      isTrue,
    );
    expect(prefs.getBool(QotdLegacyReminderCleanup.doneKey), isTrue);

    expect(
      await QotdLegacyReminderCleanup.run(
          cancel: (_) async => calls++, prefs: prefs),
      isFalse,
    );
    expect(calls, QotdLegacyReminderCleanup.legacyNotificationIds.length);
  });

  test('a failed cancel leaves the chore to be retried next launch', () async {
    final prefs = await prefsWith(<String, Object>{});

    final didWork = await QotdLegacyReminderCleanup.run(
      cancel: (_) async => throw Exception('plugin unavailable'),
      prefs: prefs,
    );

    expect(didWork, isFalse);
    expect(prefs.getBool(QotdLegacyReminderCleanup.doneKey), isNull);
  });
}
