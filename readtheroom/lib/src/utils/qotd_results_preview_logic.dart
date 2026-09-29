// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Pure, widget-free helpers for the QOTD answered-state inline results preview
// (v1.3). Extracted from [QotdHeroCard] so the own-answer matching and the copy
// are unit-testable without a live Supabase or a pumped widget tree.
//
// The bucket/option COUNTING that used to live here went away with the answers
// read lockdown (2026-09-22): the preview no longer holds answer rows to count,
// it draws the server's `ResultsBreakdown` (models/question_results.dart), whose
// bin boundaries the database owns (_rtr_score_bin in
// scripts/responses_lockdown_01_results_rpcs.sql). What is left is the label
// order, the own-answer highlight and the copy.

/// Approval bucket labels in display order (approve → disapprove), matching
/// ApprovalResultsScreen's histogram order.
const List<String> kApprovalBucketLabels = <String>[
  'Strongly Approve',
  'Approve',
  'Neutral',
  'Disapprove',
  'Strongly Disapprove',
];

/// The coarse approval labels a client stores as its own answer
/// (QotdHeroCard._answerDisplayString emits only these three).
const List<String> kApprovalOwnAnswerLabels = <String>[
  'Approve',
  'Neutral',
  'Disapprove',
];

/// The bucket label to highlight for the user's own approval answer, or null
/// when the stored answer is absent or not one of the coarse labels. The stored
/// answer is a display string ('Approve'/'Neutral'/'Disapprove').
String? ownApprovalBucket(String? storedAnswer) {
  if (storedAnswer == null) return null;
  final trimmed = storedAnswer.trim();
  return kApprovalOwnAnswerLabels.contains(trimmed) ? trimmed : null;
}

/// The option to highlight for the user's own MC answer, or null when the
/// stored answer is absent or not among [options].
String? ownOption(String? storedAnswer, List<String> options) {
  if (storedAnswer == null) return null;
  final trimmed = storedAnswer.trim();
  return options.contains(trimmed) ? trimmed : null;
}

/// The "N responses" label above the inline distribution. Singular at one, so
/// the first answerer of the day is never told there is "1 responses".
String qotdResponseCountLabel(int n) => n == 1 ? '1 response' : '$n responses';

// --- answered-card comment button ----------------------------------------

/// Read a question map's `comment_count`, treating an absent, null, or
/// unparseable value as 0. The enriched QOTD map carries `comment_count` as an
/// int, but tolerate num/String shapes from other feed paths defensively.
int commentCountOf(Map<String, dynamic>? question) {
  final v = question?['comment_count'];
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v.trim()) ?? 0;
  return 0;
}

/// The label + mode for the answered-card comment button. When the QOTD already
/// has comments the button invites joining in ("Join the conversation (N)");
/// with none it invites the first ("Start the conversation"). Either variant
/// navigates to the same results screen — the widget picks the icon from
/// [hasComments].
class QotdCommentButtonSpec {
  final String label;
  final bool hasComments;
  const QotdCommentButtonSpec(this.label, this.hasComments);

  @override
  bool operator ==(Object other) =>
      other is QotdCommentButtonSpec &&
      other.label == label &&
      other.hasComments == hasComments;

  @override
  int get hashCode => Object.hash(label, hasComments);

  @override
  String toString() => 'QotdCommentButtonSpec($label, hasComments: $hasComments)';
}

/// Decide the comment button's copy/mode from a raw comment count. A negative or
/// zero count collapses to the "Start the conversation" (no comments yet)
/// variant.
QotdCommentButtonSpec qotdCommentButtonSpec(int commentCount) {
  if (commentCount > 0) {
    return QotdCommentButtonSpec('Join the conversation ($commentCount)', true);
  }
  return const QotdCommentButtonSpec('Start the conversation', false);
}
