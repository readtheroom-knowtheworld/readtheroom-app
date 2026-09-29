// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

/// A QOTD answer captured before the user had an account (WP-C3, decision D5).
///
/// Pure value object + JSON, so serialisation and expiry can be unit-tested
/// without SharedPreferences or Supabase.
///
/// ## Why it has to be held locally at all
///
/// The guest answer **cannot** be written to `responses` at the moment it is
/// given, for two independent reasons:
///
///  1. `QuestionService.submitApprovalResponse` / `submitMultipleChoiceResponse`
///     / `submitTextResponse` all bail out with `auth.currentUser == null`, and
///     the documented `responses` RLS posture is authenticated-INSERT-only
///     (DBarchitecture.md "RLS Policy Changes (2025-06-18)"; the only RPC
///     granted to `anon` anywhere is `subscribe_email`).
///  2. Every insert requires a non-null `city_id` from `LocationService`, and
///     in the new onboarding order the location step comes *after* the
///     question.
///
/// So the answer is stashed here and replayed once **both** conditions are
/// satisfied — that is, at the end of onboarding, after the passkey slide *and*
/// the location slide. Anonymity is unaffected: the replayed row is an ordinary
/// `responses` row with no `user_id`, exactly like every other answer.
library;

import 'dart:convert';

/// How long a stashed answer stays replayable. A QOTD is a *daily* question, so
/// a stash older than this is dropped rather than filed against a question that
/// is no longer today's.
const Duration kPendingAnswerMaxAge = Duration(hours: 24);

class PendingQotdAnswer {
  const PendingQotdAnswer({
    required this.questionId,
    required this.questionType,
    required this.capturedAt,
    this.sliderValue,
    this.selectedOption,
    this.text,
    this.displayAnswer,
    this.sharedWithCloseFriends = true,
  });

  final String questionId;

  /// Normalised question type, as [QotdAnswerValue.questionType] reports it.
  final String questionType;

  final DateTime capturedAt;

  /// Approval score in [-1.0, 1.0].
  final double? sliderValue;

  /// Selected multiple-choice option text.
  final String? selectedOption;

  /// Free-text answer.
  final String? text;

  /// Human-readable answer for the answered-state card and the local record.
  final String? displayAnswer;

  /// The per-answer close-friend flag as the guest set it on the onboarding
  /// slide (owner decision 2026-09-17). Default ON, exactly like every other
  /// answer surface, and carried through the stash so the deferred insert writes
  /// the choice the user actually made rather than the column default.
  final bool sharedWithCloseFriends;

  /// The value handed to the response-submit API for this question type —
  /// mirrors `QotdAnswerValue.submitValue`.
  dynamic get submitValue {
    switch (questionType) {
      case 'approval_rating':
      case 'approval':
        return sliderValue ?? 0.0;
      case 'multiplechoice':
      case 'multiple_choice':
        return selectedOption;
      case 'text':
        return text;
      default:
        return null;
    }
  }

  /// Whether this stash still holds enough to submit.
  bool get isSubmittable {
    switch (questionType) {
      case 'approval_rating':
      case 'approval':
        return sliderValue != null;
      case 'multiplechoice':
      case 'multiple_choice':
        return (selectedOption ?? '').isNotEmpty;
      case 'text':
        return (text ?? '').trim().isNotEmpty;
      default:
        return false;
    }
  }

  /// `true` once the stash is too old to be trusted as "today's" answer.
  bool isExpired(DateTime now) =>
      now.difference(capturedAt) > kPendingAnswerMaxAge;

  Map<String, dynamic> toJson() => {
        'question_id': questionId,
        'question_type': questionType,
        'captured_at': capturedAt.toIso8601String(),
        if (sliderValue != null) 'slider_value': sliderValue,
        if (selectedOption != null) 'selected_option': selectedOption,
        if (text != null) 'text': text,
        if (displayAnswer != null) 'display_answer': displayAnswer,
        'shared_with_close_friends': sharedWithCloseFriends,
      };

  String encode() => jsonEncode(toJson());

  /// Returns null for anything unparseable, so a corrupt/legacy stash is simply
  /// discarded rather than crashing onboarding.
  static PendingQotdAnswer? fromJson(Map<String, dynamic> json) {
    final questionId = json['question_id']?.toString();
    final questionType = json['question_type']?.toString();
    final capturedAt = DateTime.tryParse(json['captured_at']?.toString() ?? '');
    if (questionId == null || questionId.isEmpty) return null;
    if (questionType == null || questionType.isEmpty) return null;
    if (capturedAt == null) return null;

    return PendingQotdAnswer(
      questionId: questionId,
      questionType: questionType,
      capturedAt: capturedAt,
      sliderValue: (json['slider_value'] as num?)?.toDouble(),
      selectedOption: json['selected_option']?.toString(),
      text: json['text']?.toString(),
      displayAnswer: json['display_answer']?.toString(),
      // Absent (a stash written by an older build) means "not told otherwise",
      // and the default is ON — matching the column default. Only an explicit
      // `false` opts out.
      sharedWithCloseFriends: json['shared_with_close_friends'] != false,
    );
  }

  static PendingQotdAnswer? decode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      return fromJson(decoded);
    } catch (_) {
      return null;
    }
  }
}
