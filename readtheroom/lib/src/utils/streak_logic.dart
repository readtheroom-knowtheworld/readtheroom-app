// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Pure streak derivation (QOTD-first §Streak rule).
//
// A day extends the streak iff, on that day, the user EITHER answered a record
// that counts for the streak (the effective QOTD — see
// [answerCountsForStreak]) OR has an asked-credit record (they posted a
// question that day). Everything here is a pure function with an injectable
// [now] so the transition/grandfathering behaviour can be unit-tested
// deterministically. No I/O, no singletons.

/// Whether a single answered-question record counts toward the streak.
///
/// Rules (in order):
///  - A record with no `timestamp` never counts (guest-migration stubs, and
///    the pre-fix overlay bug both produced timestamp-less records).
///  - A record with no `counts_for_streak` key is grandfathered as counting.
///    ALL pre-update history lacks the key, so nobody's streak drops on update
///    day with zero migration.
///  - Otherwise the stored boolean is honoured (true = QOTD answer, false =
///    archive/other answer that must never credit the streak).
bool answerCountsForStreak(Map<String, dynamic> record) {
  if (record['timestamp'] == null) return false;
  if (!record.containsKey('counts_for_streak')) return true; // grandfathered
  return record['counts_for_streak'] == true;
}

/// Extract the local calendar day (midnight-normalized) from a record's
/// `timestamp`, or null if it is missing/unparseable.
DateTime? _dayOf(Map<String, dynamic> record) {
  final timestamp = record['timestamp'];
  if (timestamp == null) return null;
  try {
    final date = DateTime.parse(timestamp.toString());
    return DateTime(date.year, date.month, date.day);
  } catch (_) {
    return null;
  }
}

/// Build the set of calendar days that have streak credit, drawn from both
/// counting answers and asked-credit records.
Set<DateTime> _creditedDays(
  List<Map<String, dynamic>> answered,
  List<Map<String, dynamic>> askedCredits,
) {
  final days = <DateTime>{};

  for (final record in answered) {
    if (!answerCountsForStreak(record)) continue;
    final day = _dayOf(record);
    if (day != null) days.add(day);
  }

  // Any asked-credit record with a valid timestamp credits its day.
  for (final record in askedCredits) {
    final day = _dayOf(record);
    if (day != null) days.add(day);
  }

  return days;
}

/// The number of consecutive days (ending today, or yesterday-anchored if
/// nothing landed today yet) that have streak credit.
///
/// A day counts if any [answered] record passing [answerCountsForStreak] OR
/// any [askedCredits] record lands on it. The walk starts at today; if today
/// has no credit the streak is anchored at yesterday (grace so an unanswered
/// but not-yet-broken streak still displays) and walks back from there.
int calculateAnswerStreak(
  List<Map<String, dynamic>> answered, {
  List<Map<String, dynamic>> askedCredits = const [],
  DateTime? now,
}) {
  final creditedDays = _creditedDays(answered, askedCredits);
  if (creditedDays.isEmpty) return 0;

  final resolvedNow = now ?? DateTime.now();
  final today = DateTime(resolvedNow.year, resolvedNow.month, resolvedNow.day);

  DateTime checkDate = today;
  // If nothing today, anchor at yesterday (grace window).
  if (!creditedDays.contains(today)) {
    checkDate = today.subtract(const Duration(days: 1));
  }

  int streak = 0;
  while (creditedDays.contains(checkDate)) {
    streak++;
    checkDate = checkDate.subtract(const Duration(days: 1));
  }

  return streak;
}

/// Whether the streak has already been extended today — i.e. today has credit
/// from a counting answer or an asked-credit record.
bool hasExtendedStreakToday(
  List<Map<String, dynamic>> answered, {
  List<Map<String, dynamic>> askedCredits = const [],
  DateTime? now,
}) {
  final resolvedNow = now ?? DateTime.now();
  final today = DateTime(resolvedNow.year, resolvedNow.month, resolvedNow.day);
  return _creditedDays(answered, askedCredits).contains(today);
}
