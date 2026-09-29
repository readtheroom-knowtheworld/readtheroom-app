// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Pure partition helpers backing the Archive default view's Answered /
/// Unanswered toggle — the Unanswered queue and the "Your answers" list — plus
/// the per-section sort flip (tapping the already-selected chip swaps that
/// section between Popular and New). Extracted from `SearchScreen` so the
/// subtraction / ordering / fresh-count merge / flip rules can be unit-tested
/// without pumping the screen (which needs Supabase + the full provider tree).

/// Filters a raw archive-queue candidate list down to questions the user has
/// **not** answered, preserving the input order (which the caller has already
/// sorted by vote count, most-answered first).
///
/// [answeredIds] is the set of the user's answered-question ids (as strings).
/// Candidates without an `id` are dropped.
List<Map<String, dynamic>> archiveQueueExcludingAnswered(
  List<Map<String, dynamic>> candidates,
  Set<String> answeredIds,
) {
  return candidates.where((q) {
    final id = q['id']?.toString();
    return id != null && id.isNotEmpty && !answeredIds.contains(id);
  }).toList();
}

/// Builds the "Answered" list from the user's answered-question records,
/// most-answered (highest vote count) first — mirroring the Unanswered queue's
/// ordering so the toggle reads consistently.
///
/// Records lacking a non-empty `prompt` are excluded — these are the
/// guest-migration stubs (design doc edge cases: "guest-migration
/// timestamp-less stubs excluded from … the answered view"). Ordering keys off
/// each record's `votes`, with a most-recently-answered tiebreak (answer
/// `timestamp`, falling back to the question's `created_at`) so ties are stable
/// and deterministic.
///
/// Callers should first pass records through [mergeAnsweredWithFreshCounts] so
/// the `votes` here reflect fresh server counts rather than the value frozen at
/// answer time.
List<Map<String, dynamic>> yourAnswersMostVotesFirst(
  List<Map<String, dynamic>> answered,
) {
  final withPrompt = answered.where((record) {
    final prompt = record['prompt'];
    return prompt != null && prompt.toString().trim().isNotEmpty;
  }).toList();

  withPrompt.sort((a, b) {
    final byVotes = _votesOf(b).compareTo(_votesOf(a));
    if (byVotes != 0) return byVotes;
    return _answeredAt(b).compareTo(_answeredAt(a)); // newest-answered tiebreak
  });
  return withPrompt;
}

/// Overlays fresh server vote counts onto the locally-stored answered records.
///
/// Each answered record carries a `votes` value frozen at answer time; the
/// Archive re-fetches live counts (keyed by question id) so the Answered view
/// can rank by current popularity. For every record whose id has an entry in
/// [freshCounts], returns a copy with `votes` replaced by the fresh count;
/// records with no fresh count (fetch missed the id, or the batch fetch failed
/// and passed an empty map) are returned unchanged, falling back to the stored
/// value. Input records are not mutated.
List<Map<String, dynamic>> mergeAnsweredWithFreshCounts(
  List<Map<String, dynamic>> answered,
  Map<String, int> freshCounts,
) {
  return answered.map((record) {
    final id = record['id']?.toString();
    final fresh = id == null ? null : freshCounts[id];
    if (fresh == null) return record;
    final updated = Map<String, dynamic>.from(record);
    updated['votes'] = fresh;
    return updated;
  }).toList();
}

// ---------------------------------------------------------------------------
// Sort flip — tapping the already-selected Unanswered / Answered chip swaps
// that section between Popular (most answered first) and New (newest first).
// ---------------------------------------------------------------------------

/// The sort applied to one Archive section.
///
/// [popular] = most answered first (vote count desc); [newest] = newest first
/// (`created_at` desc for the Unanswered queue, answered-at desc for "Your
/// answers"). [wireName] is the stable string used for both the
/// SharedPreferences value and the `archive_sort_changed` analytics property, so
/// renaming an enum value never silently rewrites a stored preference or a
/// dashboard breakdown.
enum ArchiveSort {
  popular,
  newest;

  String get wireName => this == ArchiveSort.popular ? 'popular' : 'new';

  /// The other sort — what a tap on the already-selected chip switches to.
  ArchiveSort get flipped =>
      this == ArchiveSort.popular ? ArchiveSort.newest : ArchiveSort.popular;

  /// Parses a stored [wireName], falling back to [fallback] for a missing or
  /// unrecognised value (first run, or a downgrade that wrote something else).
  static ArchiveSort fromWireName(
    String? value, {
    required ArchiveSort fallback,
  }) {
    switch (value) {
      case 'popular':
        return ArchiveSort.popular;
      case 'new':
        return ArchiveSort.newest;
      default:
        return fallback;
    }
  }
}

/// Section ids for the Archive toggle (also the analytics `section` property).
const String kArchiveUnansweredSection = 'unanswered';
const String kArchiveAnsweredSection = 'answered';

/// Default sort per section: the Unanswered queue opens on Popular, "Your
/// answers" on New.
ArchiveSort defaultArchiveSort(String section) => section == kArchiveAnsweredSection
    ? ArchiveSort.newest
    : ArchiveSort.popular;

/// What a tap on an Archive toggle chip resolves to.
class ArchiveToggleOutcome {
  const ArchiveToggleOutcome({
    required this.view,
    required this.sort,
    required this.viewChanged,
    required this.sortFlipped,
  });

  /// The section selected after the tap.
  final String view;

  /// The tapped section's sort after the tap.
  final ArchiveSort sort;

  /// True when the tap moved to the other section (first tap).
  final bool viewChanged;

  /// True when the tap flipped the already-selected section's sort.
  final bool sortFlipped;
}

/// Resolves a tap on the Unanswered / Answered toggle.
///
/// A tap on the other chip selects that section and leaves its sort alone;
/// tapping the chip that is already selected flips that section's sort between
/// Popular and New. The two outcomes are mutually exclusive, so a caller can
/// treat [ArchiveToggleOutcome.sortFlipped] as "re-sort + haptic + analytics"
/// and [ArchiveToggleOutcome.viewChanged] as "switch section".
ArchiveToggleOutcome archiveToggleTap({
  required String currentView,
  required String tappedView,
  required ArchiveSort tappedSectionSort,
}) {
  final bool sameSection = currentView == tappedView;
  return ArchiveToggleOutcome(
    view: tappedView,
    sort: sameSection ? tappedSectionSort.flipped : tappedSectionSort,
    viewChanged: !sameSection,
    sortFlipped: sameSection,
  );
}

/// The short sort name shown on the selected chip ("Popular" / "New").
String archiveSortChipLabel(ArchiveSort sort) =>
    sort == ArchiveSort.popular ? 'Popular' : 'New';

/// The section header under the toggle — "Unanswered — most answered first",
/// "Your answers — newest first" and so on — so the active sort reads as words
/// and not only as the chip's indicator.
String archiveSectionHeader(String section, ArchiveSort sort) {
  final String name =
      section == kArchiveAnsweredSection ? 'Your answers' : 'Unanswered';
  final String order =
      sort == ArchiveSort.popular ? 'most answered first' : 'newest first';
  return '$name — $order';
}

/// Sorts the user's answered questions for the requested [sort]. "Your answers"
/// is a local list, so both orders are applied client-side.
List<Map<String, dynamic>> sortYourAnswers(
  List<Map<String, dynamic>> answered,
  ArchiveSort sort,
) {
  return sort == ArchiveSort.popular
      ? yourAnswersMostVotesFirst(answered)
      : yourAnswersNewestFirst(answered);
}

/// Builds the "Your answers" list newest-answered first — the New sort's
/// counterpart to [yourAnswersMostVotesFirst].
///
/// Ordering keys off each record's answer `timestamp` (falling back to the
/// question's `created_at`, then the epoch — so undated records sort last), with
/// a votes-desc tiebreak to keep equal timestamps deterministic. Guest-migration
/// stubs (no non-empty `prompt`) are excluded, exactly as in the votes-first
/// ordering.
List<Map<String, dynamic>> yourAnswersNewestFirst(
  List<Map<String, dynamic>> answered,
) {
  final withPrompt = answered.where((record) {
    final prompt = record['prompt'];
    return prompt != null && prompt.toString().trim().isNotEmpty;
  }).toList();

  withPrompt.sort((a, b) {
    final byDate = _answeredAt(b).compareTo(_answeredAt(a));
    if (byDate != 0) return byDate;
    return _votesOf(b).compareTo(_votesOf(a)); // most-answered tiebreak
  });
  return withPrompt;
}

/// Reads a record's vote count tolerant of int / num / string shapes, defaulting
/// to 0 so malformed records sort last.
int _votesOf(Map<String, dynamic> record) {
  final v = record['votes'];
  if (v is int) return v;
  if (v is num) return v.toInt();
  return int.tryParse(v?.toString() ?? '') ?? 0;
}

/// Resolves the effective "answered at" instant for the ordering tiebreak,
/// tolerant of missing / malformed fields (returns the epoch so such records
/// sort last).
DateTime _answeredAt(Map<String, dynamic> record) {
  final ts = record['timestamp']?.toString();
  final created = record['created_at']?.toString();
  return DateTime.tryParse(ts ?? '') ??
      DateTime.tryParse(created ?? '') ??
      DateTime.fromMillisecondsSinceEpoch(0);
}
