// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../utils/pending_qotd_answer.dart';
import 'analytics_service.dart';
import 'location_service.dart';
import 'post_answer_prompts.dart';
import 'question_service.dart';
import 'user_service.dart';

/// Holds the guest's onboarding QOTD answer and replays it once an account and
/// a city exist (WP-C3, decision D5).
///
/// See the header of `pending_qotd_answer.dart` for why an anonymous insert is
/// impossible: both the client submit path and the documented `responses` RLS
/// require an authenticated user, and every insert needs a `city_id` that only
/// the (later) location step provides. [submitIfReady] is therefore called at
/// the *end* of onboarding, not straight after passkey registration.
class PendingAnswerService extends ChangeNotifier {
  PendingAnswerService({SupabaseClient? client}) : _client = client;

  static const String _key = 'pending_qotd_answer';

  final SupabaseClient? _client;

  PendingQotdAnswer? _pending;
  bool _loaded = false;

  PendingQotdAnswer? get pending => _pending;
  bool get hasPending => _pending != null;

  bool get _isAuthenticated {
    try {
      return (_client ?? Supabase.instance.client).auth.currentUser != null;
    } catch (_) {
      return false;
    }
  }

  /// Reads the stash, dropping anything expired or unparseable.
  Future<PendingQotdAnswer?> load({DateTime? now}) async {
    final prefs = await SharedPreferences.getInstance();
    final decoded = PendingQotdAnswer.decode(prefs.getString(_key));
    if (decoded == null || decoded.isExpired(now ?? DateTime.now())) {
      if (prefs.getString(_key) != null) await prefs.remove(_key);
      _pending = null;
    } else {
      _pending = decoded;
    }
    _loaded = true;
    notifyListeners();
    return _pending;
  }

  Future<void> stash(PendingQotdAnswer answer) async {
    _pending = answer;
    _loaded = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, answer.encode());
    notifyListeners();
  }

  Future<void> clear() async {
    _pending = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
    notifyListeners();
  }

  /// Submits the stashed answer if — and only if — everything it needs is in
  /// place: a stash, an authenticated user, and a selected city.
  ///
  /// Returns `true` when a response was actually written. Missing
  /// prerequisites are a no-op returning `false` (the stash is kept, so a later
  /// call can still succeed); a *failed* submit also keeps the stash. Only a
  /// success or an expiry clears it.
  Future<bool> submitIfReady({
    required QuestionService questionService,
    required LocationService locationService,
    required UserService userService,
    DateTime? now,
  }) async {
    if (!_loaded) await load(now: now);
    final answer = _pending;
    if (answer == null) return false;

    if (answer.isExpired(now ?? DateTime.now())) {
      await clear();
      return false;
    }
    if (!answer.isSubmittable) {
      await clear();
      return false;
    }
    if (!_isAuthenticated) return false;
    if (locationService.selectedCity?['id'] == null) return false;

    final countryCode = locationService.selectedCountry ?? '';
    bool success = false;
    try {
      switch (answer.questionType) {
        case 'approval_rating':
        case 'approval':
          success = await questionService.submitApprovalResponse(
            answer.questionId,
            (answer.submitValue as double?) ?? 0.0,
            countryCode,
            locationService: locationService,
            sharedWithCloseFriends: answer.sharedWithCloseFriends,
          );
          break;
        case 'multiplechoice':
        case 'multiple_choice':
          success = await questionService.submitMultipleChoiceResponse(
            answer.questionId,
            (answer.submitValue as String?) ?? '',
            countryCode,
            locationService: locationService,
            sharedWithCloseFriends: answer.sharedWithCloseFriends,
          );
          break;
        case 'text':
          success = await questionService.submitTextResponse(
            answer.questionId,
            (answer.submitValue as String?) ?? '',
            countryCode,
            locationService: locationService,
            sharedWithCloseFriends: answer.sharedWithCloseFriends,
          );
          break;
        default:
          success = false;
      }
    } catch (e) {
      print('PendingAnswerService: submit failed: $e');
      success = false;
    }

    // The replay is the last step of a brand-new user's first answer. A
    // failure here loses that answer silently, so it is counted: no other
    // event distinguishes "never answered" from "answered and we dropped it".
    AnalyticsService().trackPendingAnswerReplayed(success: success);

    if (!success) return false;

    // The replayed answer owes the notification pre-prompt exactly like a live
    // one — and this is the most important case of all, because it is the *first*
    // QOTD answer of a brand-new user. It cannot be shown here: this runs at the
    // end of onboarding, while `OnboardingScreen` is being replaced, so the debt
    // is recorded and `MainScreen` drains it on its first frame.
    //
    // Recorded explicitly rather than relying on `addAnsweredQuestion` below: the
    // stash is a QOTD answer by construction (it came from the onboarding QOTD
    // slide), and the bookkeeping that would otherwise record it is inside a
    // best-effort try/catch that a failed `getQuestionById` skips entirely.
    try {
      await PostAnswerPrompts.markQotdAnswered();
    } catch (e) {
      print('PendingAnswerService: could not record notification prompt: $e');
    }

    // Same bookkeeping the home hero does after a successful submit: local
    // answered record (stamps timestamp + counts_for_streak), analytics, and
    // the vote-count refresh.
    try {
      final question =
          await questionService.getQuestionById(answer.questionId) ?? {};
      if (question.isNotEmpty) {
        await userService.addAnsweredQuestion(
          question,
          answer: answer.displayAnswer,
        );
      }
      // It *is* a QOTD answer, so it keeps the `qotd` source and the
      // kill/keep metric stays comparable; the onboarding funnel view comes
      // from the `onboarding_step` events instead of a new source value.
      AnalyticsService().trackQuestionAnswered(
        answer.questionType,
        answer.questionType,
        source: 'qotd',
        sharedWithCloseFriends: answer.sharedWithCloseFriends,
      );
      await questionService.updateQuestionVoteCount(answer.questionId);
    } catch (e) {
      // The response is already recorded server-side; bookkeeping failures
      // must not resurrect the stash and cause a double submit.
      print('PendingAnswerService: post-submit bookkeeping failed: $e');
    }

    await clear();
    return true;
  }
}
