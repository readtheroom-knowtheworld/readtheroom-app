// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Result of a `nominate_qotd` RPC call (Asker's Pick).
///
/// Mirrors the `BoostResult` pattern in `boost_service.dart`: a small,
/// dependency-free value object so the error → user-message mapping can be
/// unit tested without a live Supabase backend. The error vocabulary matches
/// the `nominate_qotd(p_question_id)` SQL RPC exactly.
enum NominationError {
  notAuthenticated,
  questionNotFound,
  ownQuestion,
  notEligible,
  alreadyNominated,
  dailyLimit,
  unknown,
}

class NominationResult {
  final bool success;
  final NominationError? error;

  const NominationResult({required this.success, this.error});

  const NominationResult.ok() : this(success: true);

  NominationResult.fail(NominationError error)
      : this(success: false, error: error);

  /// User-friendly message for a failed nomination. Empty on success.
  String get message {
    if (success) return 'Nice pick — thanks for helping choose!';
    switch (error) {
      case NominationError.notAuthenticated:
        return 'You must be signed in to help pick a question.';
      case NominationError.questionNotFound:
        return 'That question is no longer available.';
      case NominationError.ownQuestion:
        return "You can't pick your own question.";
      case NominationError.notEligible:
        return 'That question was a recent Question of the Day. Try another!';
      case NominationError.alreadyNominated:
        return "You've already picked this question.";
      case NominationError.dailyLimit:
        return "You've already helped pick a question today. Try again tomorrow!";
      case NominationError.unknown:
      default:
        return 'Something went wrong. Please try again.';
    }
  }

  /// Maps a server error code string to a [NominationError].
  static NominationError parseError(String? code) {
    switch (code) {
      case 'not_authenticated':
        return NominationError.notAuthenticated;
      case 'question_not_found':
        return NominationError.questionNotFound;
      case 'own_question':
        return NominationError.ownQuestion;
      case 'not_eligible':
        return NominationError.notEligible;
      case 'already_nominated':
        return NominationError.alreadyNominated;
      case 'daily_limit':
        return NominationError.dailyLimit;
      default:
        return NominationError.unknown;
    }
  }
}
