// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// "Help pick an upcoming Question of the Day" — offered right after the user
// answers TODAY's QOTD, to the first kQotdPickSpots answerers (interim,
// client-judged; see utils/qotd_pick_logic.dart). Driven by
// PostAnswerPrompts.maybeShow, so every QOTD answer path (home hero, answer
// screens, onboarding replay) reaches it: resolveOffer runs during the settle
// delay, then either the first-answerer celebration or (when the notification
// prompt took that slot) a rank headline introduces present's sheet.
//
// Candidates come from QuestionService.fetchQotdCandidates (not-yet-shown
// questions, recent window, most-voted first, zero-vote allowed); the pick
// itself is nominate_qotd (server enforces eligibility + 1/user/day).

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../utils/qotd_pick_logic.dart';
import '../widgets/qotd_nomination_sheet.dart';
import 'analytics_service.dart';
import 'question_service.dart';

class QotdPickPrompt {
  static const String _offeredKeyPrefix = 'qotd_pick_offered_';
  static bool _showing = false;
  static bool get isShowing => _showing;

  /// Last decision, for debugging/tests.
  static QotdPickDecision? debugLastDecision;

  /// Resolves whether this user is among today's first answerers and hasn't
  /// been offered the pick for this QOTD yet, and prefetches the candidates so
  /// nothing is promised that cannot be shown. Null = no offer. Stamps the
  /// offer (one per QOTD) as soon as it resolves, so a dismissed sheet is not
  /// re-offered on the next surface that drains the post-answer prompts.
  /// Never throws.
  static Future<QotdPickOffer?> resolveOffer(BuildContext context) async {
    try {
      final questionService = context.read<QuestionService>();
      final qotd = questionService.questionOfTheDay;
      final qotdId = qotd?['id']?.toString();
      if (qotdId == null || qotdId.isEmpty) return null;

      final client = Supabase.instance.client;
      final userId = client.auth.currentUser?.id;

      final prefs = await SharedPreferences.getInstance();
      final offeredKey = '$_offeredKeyPrefix$qotdId';
      final alreadyOffered = prefs.getBool(offeredKey) ?? false;

      // "Which answerer was I?" — count responses on today's QOTD (one cheap
      // request). Includes the user's own answer.
      int? answerRank;
      if (userId != null && !alreadyOffered) {
        final rows = await client.rpc('get_question_counts', params: {
          'p_question_ids': [qotdId]
        });
        final counts = rows is Map ? rows[qotdId] : null;
        final total =
            counts is Map ? (counts['total'] as num?)?.toInt() ?? 0 : 0;
        answerRank = total;
      }

      final decision = qotdPickDecision(
        answerRank: answerRank,
        alreadyOffered: alreadyOffered,
        authenticated: userId != null,
      );
      debugLastDecision = decision;
      if (decision != QotdPickDecision.offer) return null;

      await prefs.setBool(offeredKey, true);

      // Always three options: people-asked first, then the QOTD bank fills
      // the rest (fetchQotdCandidates pages until the slots are full).
      final candidates = await questionService.fetchQotdCandidates(
        excludeAuthorId: userId ?? '',
        count: 3,
      );
      if (candidates.isEmpty) return null;
      return QotdPickOffer(rank: answerRank!, candidates: candidates);
    } catch (e) {
      // Never let the pick step interrupt the answer moment.
      debugPrint('Non-critical: QOTD pick offer failed: $e');
      return null;
    }
  }

  /// Shows the pick sheet for a resolved [offer]. [title] overrides the sheet
  /// headline (used when the notification prompt displaced the celebration
  /// and the sheet has to say why it appeared). Never throws.
  static Future<void> present(
    BuildContext context,
    QotdPickOffer offer, {
    required String source,
    String? title,
  }) async {
    if (_showing || !context.mounted) return;
    _showing = true;
    try {
      final questionService = context.read<QuestionService>();
      final outcome = await QotdNominationSheet.show(
        context,
        candidates: offer.candidates,
        title: title,
        onNominate: (id) async {
          final result = await questionService.nominateQotd(id);
          // A refused nomination is a dead end the user sees; count it, or
          // `qotd_nomination {action: picked}` overstates the pick rate.
          if (!result.success) {
            AnalyticsService()
                .trackRpcFailed('nominate_qotd', reason: result.error?.name);
          }
          return result;
        },
      );
      AnalyticsService().trackEvent('qotd_nomination', {
        'action': outcome.action == QotdNominationAction.picked
            ? 'picked'
            : 'skipped',
        'candidates_shown': outcome.candidatesShown,
        'source': source,
        'answer_rank': offer.rank,
      });
    } catch (e) {
      debugPrint('Non-critical: QOTD pick prompt failed: $e');
    } finally {
      _showing = false;
    }
  }
}

/// A resolved first-answerer offer: the user's answer rank and the
/// already-fetched candidates.
class QotdPickOffer {
  final int rank;
  final List<Map<String, dynamic>> candidates;
  const QotdPickOffer({required this.rank, required this.candidates});
}
