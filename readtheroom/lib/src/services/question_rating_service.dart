// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:supabase_flutter/supabase_flutter.dart';

class QuestionRatingService {
  final _supabase = Supabase.instance.client;

  /// Submit an anonymous rating for a question
  Future<bool> submitRating(
    String questionId,
    double ratingValue,
  ) async {
    try {
      await _supabase.from('question_ratings').insert({
        'question_id': questionId,
        'rating_value': ratingValue,
      });
      return true;
    } catch (e) {
      print('Error submitting question rating: $e');
      return false;
    }
  }

  /// Submit review tags for a question (multiple rows)
  Future<bool> submitReviewTags(
    String questionId,
    List<String> tags,
  ) async {
    if (tags.isEmpty) return true;
    try {
      final rows = tags
          .map((tag) => {
                'question_id': questionId,
                'review_tag': tag,
              })
          .toList();
      await _supabase.from('question_reviews').insert(rows);
      return true;
    } catch (e) {
      print('Error submitting review tags: $e');
      return false;
    }
  }

  /// Fetch all ratings and bin them into 5 sentiment categories.
  /// Returns a map like {'strongly_disapprove': 3, 'disapprove': 5, ...}
  Future<Map<String, int>> getRatingDistribution(String questionId) async {
    try {
      final response = await _supabase
          .from('question_ratings')
          .select('rating_value')
          .eq('question_id', questionId);

      final distribution = <String, int>{
        'strongly_disapprove': 0,
        'disapprove': 0,
        'neutral': 0,
        'approve': 0,
        'strongly_approve': 0,
      };

      for (final row in response) {
        final value = (row['rating_value'] as num).toDouble();
        if (value <= -0.8) {
          distribution['strongly_disapprove'] =
              distribution['strongly_disapprove']! + 1;
        } else if (value <= -0.3) {
          distribution['disapprove'] = distribution['disapprove']! + 1;
        } else if (value <= 0.3) {
          distribution['neutral'] = distribution['neutral']! + 1;
        } else if (value <= 0.8) {
          distribution['approve'] = distribution['approve']! + 1;
        } else {
          distribution['strongly_approve'] =
              distribution['strongly_approve']! + 1;
        }
      }

      return distribution;
    } catch (e) {
      print('Error fetching rating distribution: $e');
      return {
        'strongly_disapprove': 0,
        'disapprove': 0,
        'neutral': 0,
        'approve': 0,
        'strongly_approve': 0,
      };
    }
  }

  /// Fetch review tag counts grouped by tag, sorted descending
  Future<Map<String, int>> getReviewTagCounts(String questionId) async {
    try {
      final response = await _supabase
          .from('question_reviews')
          .select('review_tag')
          .eq('question_id', questionId);

      final counts = <String, int>{};
      for (final row in response) {
        final tag = row['review_tag'] as String;
        counts[tag] = (counts[tag] ?? 0) + 1;
      }

      // Sort by count descending
      final sorted = Map.fromEntries(
        counts.entries.toList()..sort((a, b) => b.value.compareTo(a.value)),
      );

      return sorted;
    } catch (e) {
      print('Error fetching review tag counts: $e');
      return {};
    }
  }

  /// Fetch question IDs where any of the given tags appear in the top 3 review tags.
  Future<Set<String>> getQuestionIdsForTopTags(List<String> tags) async {
    if (tags.isEmpty) return {};
    try {
      // Query 1: get candidate question IDs that have at least one of the target tags
      final candidateRows = await _supabase
          .from('question_reviews')
          .select('question_id')
          .inFilter('review_tag', tags);

      final candidateIds = candidateRows
          .map((r) => r['question_id'].toString())
          .toSet()
          .toList();

      if (candidateIds.isEmpty) return {};

      // Query 2: get ALL review data for those candidate questions
      final allRows = await _supabase
          .from('question_reviews')
          .select('question_id, review_tag')
          .inFilter('question_id', candidateIds);

      // Group by question_id and count each tag
      final Map<String, Map<String, int>> grouped = {};
      for (final row in allRows) {
        final qid = row['question_id'].toString();
        final tag = row['review_tag'] as String;
        grouped.putIfAbsent(qid, () => {});
        grouped[qid]![tag] = (grouped[qid]![tag] ?? 0) + 1;
      }

      // For each question, sort tags by count desc and check if any target tag is in top 3
      final Set<String> result = {};
      for (final entry in grouped.entries) {
        final sorted = entry.value.entries.toList()
          ..sort((a, b) => b.value.compareTo(a.value));
        final top3Keys = sorted.take(3).map((e) => e.key).toSet();
        if (top3Keys.any((k) => tags.contains(k))) {
          result.add(entry.key);
        }
      }

      return result;
    } catch (e) {
      print('Error fetching question IDs for top tags: $e');
      return {};
    }
  }

  /// Convenience wrapper for a single tag.
  Future<Set<String>> getQuestionIdsForTopTag(String tag) {
    return getQuestionIdsForTopTags([tag]);
  }
}
