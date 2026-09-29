// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Every branch of the native app-store review gate (pure logic, injected clock).

import 'package:flutter_test/flutter_test.dart';
import 'package:read_the_room/src/utils/app_review_logic.dart';

void main() {
  final now = DateTime(2026, 9, 11, 12, 0);

  group('shouldRequestAppReview — first ask', () {
    test('no answers on record is none, not tooEarly', () {
      expect(
        shouldRequestAppReview(answeredCount: 0, now: now),
        AppReviewDecision.none,
      );
    });

    test('a negative count (corrupt local state) is also none', () {
      expect(
        shouldRequestAppReview(answeredCount: -3, now: now),
        AppReviewDecision.none,
      );
    });

    test('one answer is too early', () {
      expect(
        shouldRequestAppReview(answeredCount: 1, now: now),
        AppReviewDecision.tooEarly,
      );
    });

    test('the second answer asks', () {
      expect(
        shouldRequestAppReview(answeredCount: 2, now: now),
        AppReviewDecision.request,
      );
    });

    test('a user well past the threshold who has never been asked still asks',
        () {
      expect(
        shouldRequestAppReview(answeredCount: 97, now: now),
        AppReviewDecision.request,
      );
    });
  });

  group('shouldRequestAppReview — the weekly re-ask', () {
    test('same day as the last ask is too early', () {
      expect(
        shouldRequestAppReview(
          answeredCount: 5,
          now: now,
          lastRequestedAt: now.subtract(const Duration(hours: 3)),
          requestsInLastYear: 1,
        ),
        AppReviewDecision.tooEarly,
      );
    });

    test('one minute short of a week is too early', () {
      expect(
        shouldRequestAppReview(
          answeredCount: 5,
          now: now,
          lastRequestedAt:
              now.subtract(const Duration(days: 7)).add(const Duration(minutes: 1)),
          requestsInLastYear: 1,
        ),
        AppReviewDecision.tooEarly,
      );
    });

    test('exactly a week later asks (boundary is inclusive)', () {
      expect(
        shouldRequestAppReview(
          answeredCount: 5,
          now: now,
          lastRequestedAt: now.subtract(kAppReviewReAskInterval),
          requestsInLastYear: 1,
        ),
        AppReviewDecision.request,
      );
    });

    test('months later asks', () {
      expect(
        shouldRequestAppReview(
          answeredCount: 40,
          now: now,
          lastRequestedAt: now.subtract(const Duration(days: 120)),
          requestsInLastYear: 1,
        ),
        AppReviewDecision.request,
      );
    });

    test('a stamp in the future (clock skew) is treated as just-asked', () {
      expect(
        shouldRequestAppReview(
          answeredCount: 5,
          now: now,
          lastRequestedAt: now.add(const Duration(days: 30)),
          requestsInLastYear: 1,
        ),
        AppReviewDecision.tooEarly,
      );
    });

    test('the answer floor still applies when a stamp exists', () {
      // Local answer history cleared but the prompt stamp survived.
      expect(
        shouldRequestAppReview(
          answeredCount: 1,
          now: now,
          lastRequestedAt: now.subtract(const Duration(days: 400)),
        ),
        AppReviewDecision.tooEarly,
      );
    });
  });

  group('shouldRequestAppReview — the 3-per-365-days cap', () {
    test('two spent still asks', () {
      expect(
        shouldRequestAppReview(
          answeredCount: 9,
          now: now,
          lastRequestedAt: now.subtract(const Duration(days: 10)),
          requestsInLastYear: 2,
        ),
        AppReviewDecision.request,
      );
    });

    test('three spent is exhausted', () {
      expect(
        shouldRequestAppReview(
          answeredCount: 9,
          now: now,
          lastRequestedAt: now.subtract(const Duration(days: 10)),
          requestsInLastYear: kAppReviewMaxRequestsPerWindow,
        ),
        AppReviewDecision.quotaExhausted,
      );
    });

    test('the cap outranks every other reason', () {
      // Too few answers AND inside the week — the cap is still the reason
      // reported, so analytics names the binding constraint.
      expect(
        shouldRequestAppReview(
          answeredCount: 0,
          now: now,
          lastRequestedAt: now,
          requestsInLastYear: 4,
        ),
        AppReviewDecision.quotaExhausted,
      );
    });
  });

  group('pruneAppReviewTimestamps', () {
    test('drops stamps older than the window and sorts the rest', () {
      final stamps = [
        now.subtract(const Duration(days: 10)),
        now.subtract(const Duration(days: 366)),
        now.subtract(const Duration(days: 200)),
      ];
      final kept = pruneAppReviewTimestamps(stamps, now);
      expect(kept, [
        now.subtract(const Duration(days: 200)),
        now.subtract(const Duration(days: 10)),
      ]);
    });

    test('a stamp exactly at the window edge is dropped', () {
      final kept = pruneAppReviewTimestamps(
        [now.subtract(kAppReviewQuotaWindow)],
        now,
      );
      expect(kept, isEmpty);
    });

    test('future stamps are kept so skew cannot reset the quota', () {
      final future = now.add(const Duration(days: 5));
      expect(pruneAppReviewTimestamps([future], now), [future]);
    });

    test('empty in, empty out', () {
      expect(pruneAppReviewTimestamps(const [], now), isEmpty);
    });
  });

  group('countAppReviewRequestsInWindow', () {
    test('counts only what is inside the window', () {
      expect(
        countAppReviewRequestsInWindow([
          now.subtract(const Duration(days: 1)),
          now.subtract(const Duration(days: 300)),
          now.subtract(const Duration(days: 500)),
        ], now),
        2,
      );
    });
  });

  group('the full arc of one user', () {
    test('2nd answer asks, week 1 quiet, week 2 asks, 3 spent then silence',
        () {
      DateTime? lastRequestedAt;
      var spent = 0;
      var day = DateTime(2026, 1, 1);

      AppReviewDecision step(int answeredCount, DateTime at) {
        final decision = shouldRequestAppReview(
          answeredCount: answeredCount,
          now: at,
          lastRequestedAt: lastRequestedAt,
          requestsInLastYear: spent,
        );
        if (decision == AppReviewDecision.request) {
          lastRequestedAt = at;
          spent++;
        }
        return decision;
      }

      expect(step(1, day), AppReviewDecision.tooEarly);
      expect(step(2, day.add(const Duration(days: 1))), AppReviewDecision.request);
      // Answering every day for the next week says nothing.
      for (var i = 2; i <= 7; i++) {
        expect(step(i + 1, day.add(Duration(days: i))), AppReviewDecision.tooEarly);
      }
      expect(step(20, day.add(const Duration(days: 8))), AppReviewDecision.request);
      expect(step(40, day.add(const Duration(days: 30))), AppReviewDecision.request);
      expect(spent, kAppReviewMaxRequestsPerWindow);
      // Fourth ask inside the year: never.
      day = day.add(const Duration(days: 200));
      expect(step(90, day), AppReviewDecision.quotaExhausted);
    });
  });
}
