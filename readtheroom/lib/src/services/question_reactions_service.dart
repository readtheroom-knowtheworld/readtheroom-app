// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:supabase_flutter/supabase_flutter.dart';

class QuestionReactionsService {
  final _supabase = Supabase.instance.client;
  
  static const List<String> _availableReactions = ['❤️', '🤔', '😡', '😂', '🤯'];

  /// Get current reactions for a question
  Future<Map<String, dynamic>> getQuestionReactions(String questionId) async {
    try {
      final response = await _supabase
          .from('question_reactions')
          .select('reaction_type, user_id')
          .eq('question_id', questionId);

      // Count reactions by type
      final Map<String, int> reactionCounts = {};
      final Set<String> userReactions = {};
      final String? currentUserId = _supabase.auth.currentUser?.id;

      for (final reaction in response) {
        final reactionType = reaction['reaction_type'] as String;
        final userId = reaction['user_id'] as String;

        // Count reactions
        reactionCounts[reactionType] = (reactionCounts[reactionType] ?? 0) + 1;

        // Track current user's reactions
        if (currentUserId != null && userId == currentUserId) {
          userReactions.add(reactionType);
        }
      }

      return {
        'reactionCounts': reactionCounts,
        'userReactions': userReactions,
      };
    } catch (e) {
      print('Error fetching question reactions: $e');
      return {
        'reactionCounts': <String, int>{},
        'userReactions': <String>{},
      };
    }
  }

  /// Add or update a user's reaction to a question
  /// Users can only have one reaction per question, so this replaces any existing reaction
  Future<Map<String, dynamic>> updateReaction(String questionId, String reactionType) async {
    final String? currentUserId = _supabase.auth.currentUser?.id;
    if (currentUserId == null) {
      throw Exception('User must be authenticated to react');
    }

    if (!_availableReactions.contains(reactionType)) {
      throw Exception('Invalid reaction type: $reactionType');
    }

    try {
      // First, remove any existing reaction by this user for this question
      await _supabase
          .from('question_reactions')
          .delete()
          .eq('question_id', questionId)
          .eq('user_id', currentUserId);

      // Then add the new reaction
      await _supabase
          .from('question_reactions')
          .insert({
            'question_id': questionId,
            'user_id': currentUserId,
            'reaction_type': reactionType,
          });

      // Return updated reaction state
      return await getQuestionReactions(questionId);
    } catch (e) {
      print('Error updating reaction: $e');
      rethrow;
    }
  }

  /// Remove a user's reaction from a question
  Future<Map<String, dynamic>> removeReaction(String questionId, String reactionType) async {
    final String? currentUserId = _supabase.auth.currentUser?.id;
    if (currentUserId == null) {
      throw Exception('User must be authenticated to remove reaction');
    }

    try {
      await _supabase
          .from('question_reactions')
          .delete()
          .eq('question_id', questionId)
          .eq('user_id', currentUserId)
          .eq('reaction_type', reactionType);

      // Return updated reaction state
      return await getQuestionReactions(questionId);
    } catch (e) {
      print('Error removing reaction: $e');
      rethrow;
    }
  }

  /// Toggle a reaction - if user has this reaction, remove it; if not, add it (replacing any existing reaction)
  Future<Map<String, dynamic>> toggleReaction(String questionId, String reactionType) async {
    final currentReactions = await getQuestionReactions(questionId);
    final Set<String> userReactions = currentReactions['userReactions'] as Set<String>;
    
    if (userReactions.contains(reactionType)) {
      // User already has this reaction, remove it
      return await removeReaction(questionId, reactionType);
    } else {
      // User doesn't have this reaction, add it (replacing any existing reaction)
      return await updateReaction(questionId, reactionType);
    }
  }

  /// Get total reaction count for a question (for feed display)
  Future<int> getTotalReactionCount(String questionId) async {
    try {
      final reactions = await getQuestionReactions(questionId);
      final Map<String, int> reactionCounts = reactions['reactionCounts'] as Map<String, int>;
      
      return reactionCounts.values.fold<int>(0, (sum, count) => sum + count);
    } catch (e) {
      print('Error getting total reaction count: $e');
      return 0;
    }
  }
}