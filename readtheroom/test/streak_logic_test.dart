// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Release-gating tests for the QOTD-first streak rule (§Streak rule).
//
// The whole point of the update: a day extends the streak iff the user
// answered the effective QOTD OR asked a question that day; archive/other
// answers never count; and ALL pre-update history is grandfathered so nobody's
// current streak number drops on update day with zero migration.
//
// Everything is driven by an injectable `now` so the transition cases are
// deterministic and do not depend on the wall clock.

import 'package:flutter_test/flutter_test.dart';
import 'package:read_the_room/src/utils/streak_logic.dart';

void main() {
  // A stable "today" for all tests.
  final now = DateTime(2026, 8, 28, 12, 0);
  final today = DateTime(now.year, now.month, now.day);

  String iso(DateTime day) => day.toIso8601String();

  // A record for `day`, with an explicit counts_for_streak flag.
  Map<String, dynamic> answer(DateTime day, {required bool counts}) =>
      {'id': 'q-${day.toIso8601String()}', 'timestamp': iso(day), 'counts_for_streak': counts};

  // A pre-update record: has a timestamp but NO counts_for_streak key.
  Map<String, dynamic> legacy(DateTime day) =>
      {'id': 'legacy-${day.toIso8601String()}', 'timestamp': iso(day)};

  // An asked-question streak credit.
  Map<String, dynamic> asked(DateTime day) => {'timestamp': iso(day)};

  DateTime daysAgo(int n) => today.subtract(Duration(days: n));

  // A grandfathered legacy streak of [length] consecutive days ending yesterday.
  List<Map<String, dynamic>> legacyStreakEndingYesterday(int length) => [
        for (int i = 1; i <= length; i++) legacy(daysAgo(i)),
      ];

  group('answerCountsForStreak', () {
    test('null timestamp never counts (guest stub / pre-fix overlay bug)', () {
      expect(answerCountsForStreak({'id': 'x'}), isFalse);
      expect(answerCountsForStreak({'id': 'x', 'timestamp': null}), isFalse);
    });

    test('missing counts_for_streak key is grandfathered as counting', () {
      expect(answerCountsForStreak({'timestamp': iso(today)}), isTrue);
    });

    test('explicit counts_for_streak is honoured', () {
      expect(
          answerCountsForStreak(
              {'timestamp': iso(today), 'counts_for_streak': true}),
          isTrue);
      expect(
          answerCountsForStreak(
              {'timestamp': iso(today), 'counts_for_streak': false}),
          isFalse);
    });
  });

  group('calculateAnswerStreak', () {
    test('legacy record (no key) counts', () {
      final answered = [legacy(today)];
      expect(calculateAnswerStreak(answered, now: now), 1);
    });

    test('counts_for_streak:false never credits its day', () {
      final answered = [answer(today, counts: false)];
      expect(calculateAnswerStreak(answered, now: now), 0);
      expect(hasExtendedStreakToday(answered, now: now), isFalse);
    });

    test('QOTD-flagged answer credits today', () {
      final answered = [answer(today, counts: true)];
      expect(calculateAnswerStreak(answered, now: now), 1);
      expect(hasExtendedStreakToday(answered, now: now), isTrue);
    });

    test('an asked-credit alone credits its day', () {
      expect(
        calculateAnswerStreak([], askedCredits: [asked(today)], now: now),
        1,
      );
      expect(
        hasExtendedStreakToday([], askedCredits: [asked(today)], now: now),
        isTrue,
      );
    });

    test('a day with ONLY a non-counting answer does not extend', () {
      final answered = [answer(today, counts: false)];
      expect(hasExtendedStreakToday(answered, now: now), isFalse);
      expect(calculateAnswerStreak(answered, now: now), 0);
    });

    test('yesterday-QOTD + nothing today keeps the streak (grace anchor)', () {
      final answered = [answer(daysAgo(1), counts: true)];
      expect(calculateAnswerStreak(answered, now: now), 1);
      expect(hasExtendedStreakToday(answered, now: now), isFalse);
    });

    test('guest stub (no timestamp) is ignored', () {
      final answered = [
        {'id': 'guest-1'}, // no timestamp
        answer(today, counts: true),
      ];
      expect(calculateAnswerStreak(answered, now: now), 1);
    });

    test('empty inputs yield zero', () {
      expect(calculateAnswerStreak([], now: now), 0);
      expect(hasExtendedStreakToday([], now: now), isFalse);
    });
  });

  group('transition cases (update-day, grandfathering)', () {
    test('5-day legacy streak + today archive-only answer → still 5, not extended', () {
      final answered = [
        ...legacyStreakEndingYesterday(5),
        answer(today, counts: false), // an archive answer today
      ];
      expect(calculateAnswerStreak(answered, now: now), 5);
      expect(hasExtendedStreakToday(answered, now: now), isFalse);
    });

    test('5-day legacy streak + today QOTD answer → 6, extended', () {
      final answered = [
        ...legacyStreakEndingYesterday(5),
        answer(today, counts: true),
      ];
      expect(calculateAnswerStreak(answered, now: now), 6);
      expect(hasExtendedStreakToday(answered, now: now), isTrue);
    });

    test('5-day legacy streak + today asked a question → 6, extended', () {
      final answered = legacyStreakEndingYesterday(5);
      final credits = [asked(today)];
      expect(
        calculateAnswerStreak(answered, askedCredits: credits, now: now),
        6,
      );
      expect(
        hasExtendedStreakToday(answered, askedCredits: credits, now: now),
        isTrue,
      );
    });

    test('mixed sources on separate days chain into one streak', () {
      // asked 2 days ago, QOTD yesterday, asked today → 3.
      final answered = [answer(daysAgo(1), counts: true)];
      final credits = [asked(daysAgo(2)), asked(today)];
      expect(
        calculateAnswerStreak(answered, askedCredits: credits, now: now),
        3,
      );
    });

    test('a broken day stops the walk-back', () {
      // today counts, yesterday counts, gap at day-2, then day-3 counts.
      final answered = [
        answer(today, counts: true),
        answer(daysAgo(1), counts: true),
        // no credit on daysAgo(2)
        answer(daysAgo(3), counts: true),
      ];
      expect(calculateAnswerStreak(answered, now: now), 2);
    });
  });
}
