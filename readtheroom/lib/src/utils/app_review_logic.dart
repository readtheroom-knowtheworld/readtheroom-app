// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Pure decision logic for the native app-store review prompt
// (Apple `SKStoreReviewController` / Google Play In-App Review).
//
// Requirement: "show it after the second question the user answers, or again
// the following week."
//
// The platform prompt is a scarce resource, not a widget:
//   * iOS caps `SKStoreReviewController.requestReview` at **3 prompts per
//     365 days per user**, silently no-op'ing past that — and the OS, not the
//     app, owns that counter, so a burnt request cannot be reclaimed.
//   * Google Play In-App Review has its own quota-based throttle and also
//     fails quietly.
// Because the only signal either platform gives back is "nothing happened",
// the app has to ration the asks itself. Hence: a 7-day cooling-off between
// asks and a hard local cap of 3 asks per rolling 365 days, so the app never
// spends a request whose outcome it cannot observe.
//
// Kept free of Flutter/SharedPreferences/plugin imports so every branch is
// directly unit testable with an injected clock — same shape as
// `notification_reask_logic.dart`.

/// Answers the user must have on record before the *first* review prompt.
const int kAppReviewMinAnsweredQuestions = 2;

/// Minimum gap between two review prompts ("or again the following week").
const Duration kAppReviewReAskInterval = Duration(days: 7);

/// Hard local cap on prompts inside [kAppReviewQuotaWindow]. Matches Apple's
/// OS-level 3/365 limit so the app never burns an invisible request.
const int kAppReviewMaxRequestsPerWindow = 3;

/// The rolling window the cap is measured over.
const Duration kAppReviewQuotaWindow = Duration(days: 365);

/// The outcome of the review-prompt decision.
enum AppReviewDecision {
  /// Ask now.
  request,

  /// The gate is not open yet — too few answers, or inside the cooling-off
  /// week (a stamp in the future counts as "just asked").
  tooEarly,

  /// [kAppReviewMaxRequestsPerWindow] prompts already spent in the window.
  quotaExhausted,

  /// Nothing to decide: the user has no answer on record at all.
  none,
}

/// Whether to fire the native review prompt right now.
///
/// - [answeredCount]: `UserService.answeredQuestions.length` — the local record
///   of every answer, from any surface.
/// - [now] / [lastRequestedAt]: the clock and the persisted
///   `app_review_last_requested_at` stamp (null = never asked).
/// - [requestsInLastYear]: how many prompts were fired inside
///   [kAppReviewQuotaWindow] — see [countAppReviewRequestsInWindow].
///
/// Precedence is deliberate: the hard cap is checked first so the analytics
/// `reason` always names the most binding constraint.
AppReviewDecision shouldRequestAppReview({
  required int answeredCount,
  required DateTime now,
  DateTime? lastRequestedAt,
  int requestsInLastYear = 0,
}) {
  if (requestsInLastYear >= kAppReviewMaxRequestsPerWindow) {
    return AppReviewDecision.quotaExhausted;
  }
  if (answeredCount <= 0) {
    // No answer on record — nothing prompted this ask (cleared local data, or
    // a caller firing outside the answer path).
    return AppReviewDecision.none;
  }
  if (answeredCount < kAppReviewMinAnsweredQuestions) {
    return AppReviewDecision.tooEarly;
  }
  if (lastRequestedAt != null) {
    if (now.isBefore(lastRequestedAt)) {
      // Clock skew / a stamp from the future: treat as "just asked".
      return AppReviewDecision.tooEarly;
    }
    if (now.difference(lastRequestedAt) < kAppReviewReAskInterval) {
      return AppReviewDecision.tooEarly;
    }
  }
  return AppReviewDecision.request;
}

/// The stored prompt timestamps that still fall inside [kAppReviewQuotaWindow],
/// oldest first. Stamps in the future are kept: discarding them would hand a
/// user with a skewed clock an unlimited quota.
List<DateTime> pruneAppReviewTimestamps(
  Iterable<DateTime> timestamps,
  DateTime now,
) {
  final cutoff = now.subtract(kAppReviewQuotaWindow);
  final kept = timestamps.where((t) => t.isAfter(cutoff)).toList()
    ..sort((a, b) => a.compareTo(b));
  return kept;
}

/// How many prompts were fired inside [kAppReviewQuotaWindow].
int countAppReviewRequestsInWindow(
  Iterable<DateTime> timestamps,
  DateTime now,
) =>
    pruneAppReviewTimestamps(timestamps, now).length;
