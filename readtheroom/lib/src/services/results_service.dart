// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The only way this app reads answers.
//
// Before 2026-09-22 the client selected raw rows out of `responses` in sixty-odd
// places and did the maths on the phone. Every one of those rows carried
// `city_id`, `generation`, a second-resolution `created_at` and the per-answer
// close-friend flag — far more than a results screen needs.
//
// Now every read goes through a SECURITY DEFINER function that returns RESULTS.
// The table's client SELECT grant is revoked on the server, so there is no
// other path:
// if you need a number about answers, add it to an RPC, not to a query here.
//
// Server contracts: scripts/responses_lockdown_01_results_rpcs.sql
// Docs:            feature-documentation/responses-lockdown-2026-09-22.md

import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/question_results.dart';
import 'analytics_service.dart';

class ResultsService {
  static final ResultsService _instance = ResultsService._internal();
  factory ResultsService() => _instance;
  ResultsService._internal();

  SupabaseClient get _supabase => Supabase.instance.client;

  /// The server clamps this too; the client chunks so it never has to be told.
  static const int kMaxCountIds = 100;

  /// A short-lived cache of results, keyed by question id. The results screens
  /// poll for fresh numbers and several widgets ask for the same question in the
  /// same frame; without this the QOTD hero, its map and the pick sheet would
  /// each make their own round trip.
  final Map<String, _Cached<QuestionResults>> _resultsCache = {};
  final Map<String, _Cached<QuestionMapCells>> _cellsCache = {};
  static const Duration _cacheDuration = Duration(seconds: 45);

  void clearCache([String? questionId]) {
    if (questionId == null) {
      _resultsCache.clear();
      _cellsCache.clear();
      return;
    }
    _resultsCache.remove(questionId);
    _cellsCache.remove(questionId);
  }

  /// Every number the results screens draw for one question.
  ///
  /// Returns an empty result rather than null when the question is unknown or
  /// the call fails, so callers render their "no answers yet" state instead of
  /// a crash. [forceRefresh] skips the short cache (the polling paths use it).
  Future<QuestionResults> fetchResults(
    String questionId, {
    String questionType = '',
    bool forceRefresh = false,
  }) async {
    if (questionId.isEmpty) {
      return QuestionResults.emptyFor(questionId, questionType);
    }
    // Review 2026-09-22 C1: every results screen renders an RPC failure as
    // "No responses yet", so by the time the exception reaches a screen the
    // code is gone. These four catches are the only live sites, and they are
    // what makes the responses lockdown observable at all.
    if (!forceRefresh) {
      final cached = _resultsCache[questionId];
      if (cached != null && cached.isFresh(_cacheDuration)) return cached.value;
    }
    try {
      final raw = await _supabase
          .rpc('get_question_results', params: {'p_question_id': questionId});
      if (raw is! Map) {
        AnalyticsService()
            .trackRpcFailed('get_question_results', reason: 'bad_shape');
        return QuestionResults.emptyFor(questionId, questionType);
      }
      final results = QuestionResults.fromJson(Map<String, dynamic>.from(raw));
      _resultsCache[questionId] = _Cached(results);
      return results;
    } catch (e) {
      print('ResultsService.fetchResults($questionId) failed: $e');
      AnalyticsService().trackRpcFailed('get_question_results',
          reason: analyticsRpcReason(e));
      return QuestionResults.emptyFor(questionId, questionType);
    }
  }

  /// One cell per place for the response map. Never a row per answer.
  Future<QuestionMapCells> fetchMapCells(
    String questionId, {
    bool forceRefresh = false,
  }) async {
    if (questionId.isEmpty) return QuestionMapCells.empty;
    if (!forceRefresh) {
      final cached = _cellsCache[questionId];
      if (cached != null && cached.isFresh(_cacheDuration)) return cached.value;
    }
    try {
      final raw = await _supabase
          .rpc('get_question_map_cells', params: {'p_question_id': questionId});
      if (raw is! Map) {
        AnalyticsService()
            .trackRpcFailed('get_question_map_cells', reason: 'bad_shape');
        return QuestionMapCells.empty;
      }
      final cells = QuestionMapCells.fromJson(Map<String, dynamic>.from(raw));
      _cellsCache[questionId] = _Cached(cells);
      return cells;
    } catch (e) {
      print('ResultsService.fetchMapCells($questionId) failed: $e');
      AnalyticsService().trackRpcFailed('get_question_map_cells',
          reason: analyticsRpcReason(e));
      return QuestionMapCells.empty;
    }
  }

  /// Public text answers, newest first, carrying the hour they were given.
  ///
  /// [before] is a cursor from a previous page's [TextAnswerPage.nextBefore];
  /// paging is hour-aligned server-side, so a page may come back slightly
  /// larger than [limit] and no answer is ever skipped or repeated.
  Future<TextAnswerPage> fetchTextAnswers(
    String questionId, {
    int limit = 100,
    DateTime? before,
  }) async {
    if (questionId.isEmpty) return TextAnswerPage.empty;
    try {
      final raw = await _supabase.rpc('get_question_text_answers', params: {
        'p_question_id': questionId,
        'p_limit': limit,
        if (before != null) 'p_before': before.toUtc().toIso8601String(),
      });
      if (raw is! Map) {
        AnalyticsService()
            .trackRpcFailed('get_question_text_answers', reason: 'bad_shape');
        return TextAnswerPage.empty;
      }
      return TextAnswerPage.fromJson(Map<String, dynamic>.from(raw));
    } catch (e) {
      print('ResultsService.fetchTextAnswers($questionId) failed: $e');
      AnalyticsService().trackRpcFailed('get_question_text_answers',
          reason: analyticsRpcReason(e));
      return TextAnswerPage.empty;
    }
  }

  /// Counts for a batch of questions. Chunks at [kMaxCountIds] and merges, so
  /// callers can hand over a whole feed. Questions with no answers (or that do
  /// not exist) are absent from the map.
  Future<Map<String, QuestionCounts>> fetchCounts(
      List<String> questionIds) async {
    final ids = questionIds.where((id) => id.isNotEmpty).toSet().toList();
    if (ids.isEmpty) return <String, QuestionCounts>{};

    final merged = <String, QuestionCounts>{};
    for (var start = 0; start < ids.length; start += kMaxCountIds) {
      final chunk = ids.sublist(
          start, start + kMaxCountIds > ids.length ? ids.length : start + kMaxCountIds);
      try {
        final raw = await _supabase
            .rpc('get_question_counts', params: {'p_question_ids': chunk});
        if (raw is! Map) {
          AnalyticsService()
              .trackRpcFailed('get_question_counts', reason: 'bad_shape');
        }
        if (raw is Map) {
          raw.forEach((key, value) {
            if (value is Map) {
              merged[key.toString()] =
                  QuestionCounts.fromJson(Map<String, dynamic>.from(value));
            }
          });
        }
      } catch (e) {
        print('ResultsService.fetchCounts chunk failed: $e');
        AnalyticsService()
            .trackRpcFailed('get_question_counts', reason: analyticsRpcReason(e));
      }
    }
    return merged;
  }

  /// The counts for a single question, zeroed when it has none.
  Future<QuestionCounts> fetchCountsFor(String questionId) async {
    final all = await fetchCounts(<String>[questionId]);
    return all[questionId] ?? QuestionCounts.zero;
  }

  /// The plain "how many answers" number: every answer row for the question.
  Future<int> fetchTotalCount(String questionId) async =>
      (await fetchCountsFor(questionId)).total;

  /// The type-aware answer count — what the app has always called the vote
  /// count. Multiple choice ignores answers pointing at a foreign option;
  /// approval ignores unscored rows.
  Future<int> fetchAnsweredCount(String questionId) async =>
      (await fetchCountsFor(questionId)).answered;

  /// How many text answers a question has.
  Future<int> fetchTextCount(String questionId) async =>
      (await fetchCountsFor(questionId)).text;

  /// Vote counts for a batch of questions, in the `{questionId: n}` shape the
  /// feed paths have always used.
  Future<Map<String, int>> fetchVoteCounts(List<String> questionIds) async {
    final counts = await fetchCounts(questionIds);
    return counts.map((id, c) => MapEntry(id, c.total));
  }
}

class _Cached<T> {
  final T value;
  final DateTime at;
  _Cached(this.value) : at = DateTime.now();
  bool isFresh(Duration d) => DateTime.now().difference(at) < d;
}
