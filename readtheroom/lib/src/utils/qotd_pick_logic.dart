// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Interim "pick tomorrow's question" gate (2026-09-16).
//
// Until the Drop ships (server-issued ballot spots, qotd-ballot-live-window
// spec §1), the pick sheet is offered to the FIRST [kQotdPickSpots] answerers
// of today's QOTD, judged client-side from the response count right after the
// user's own answer landed. Approximate on purpose — it is a nudge, not a
// gate: the nominate_qotd RPC still enforces eligibility and one nomination
// per user per day.

/// How many of today's answerers get to pick (interim; the Drop's
/// `qotd_config.spots` replaces this).
const int kQotdPickSpots = 10;

enum QotdPickDecision { offer, notInFirstSpots, alreadyOffered, notEligible }

/// [answerRank] is the number of responses on today's QOTD INCLUDING the
/// user's own (i.e. "you were answerer #N"); null when it could not be read.
QotdPickDecision qotdPickDecision({
  required int? answerRank,
  required bool alreadyOffered,
  required bool authenticated,
  int spots = kQotdPickSpots,
}) {
  if (!authenticated) return QotdPickDecision.notEligible;
  if (alreadyOffered) return QotdPickDecision.alreadyOffered;
  if (answerRank == null || answerRank <= 0) return QotdPickDecision.notEligible;
  if (answerRank > spots) return QotdPickDecision.notInFirstSpots;
  return QotdPickDecision.offer;
}

/// English ordinal for a positive answer rank: 1st, 2nd, 3rd, 4th … 11th,
/// 12th, 13th … 21st, 22nd, 23rd, 101st, 111th.
String ordinal(int n) {
  final mod100 = n % 100;
  if (mod100 >= 11 && mod100 <= 13) return '${n}th';
  switch (n % 10) {
    case 1:
      return '${n}st';
    case 2:
      return '${n}nd';
    case 3:
      return '${n}rd';
    default:
      return '${n}th';
  }
}

/// Curio's line on the first-answerer celebration (replaces the streak +1 for
/// the first [kQotdPickSpots] answerers). The handle, when set, follows the
/// rank the same way the thanks copy carries it.
String firstAnswererCelebrationText(int rank, String? username) {
  final handle = username?.trim();
  final who = (handle == null || handle.isEmpty) ? '' : ', $handle';
  return "You're the ${ordinal(rank)} to answer today$who — "
      "you get to pick tomorrow's Question of the Day!";
}

/// Pick-sheet headline when the notification prompt took the celebration's
/// slot (the sheet then has to say why it appeared).
String firstAnswererSheetTitle(int rank) =>
    "You're the ${ordinal(rank)} to answer today — "
    "pick tomorrow's Question of the Day!";

/// Which celebration, if any, follows a QOTD answer.
enum PostAnswerCelebration { none, streak, firstAnswerer }

/// The notification dialog outranks every celebration (it is shown instead of
/// one, never on top of one). Otherwise a first-answerer pick offer replaces
/// the streak +1; the streak celebration plays only for everyone else.
PostAnswerCelebration postAnswerCelebration({
  required bool notificationDialogShown,
  required bool pickOffered,
  required bool streakExtended,
}) {
  if (notificationDialogShown) return PostAnswerCelebration.none;
  if (pickOffered) return PostAnswerCelebration.firstAnswerer;
  if (streakExtended) return PostAnswerCelebration.streak;
  return PostAnswerCelebration.none;
}
