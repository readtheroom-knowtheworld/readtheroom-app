// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:supabase_flutter/supabase_flutter.dart';
import 'dart:math';
import 'dart:math' as Math;
import 'package:read_the_room/src/services/watchlist_service.dart';

class CommentService {
  final SupabaseClient _supabase = Supabase.instance.client;
  WatchlistService? _watchlistService;
  
  /// Get comments for a specific question with pagination
  Future<List<Map<String, dynamic>>> getCommentsForQuestion(
    String questionId, {
    int page = 0,
    int limit = 20,
    String sortBy = 'created_at', // 'upvote_lizard_count', 'created_at'
    bool ascending = true, // true for chronological (oldest first), false for votes (highest first)
  }) async {
    try {
      final currentUserId = _supabase.auth.currentUser?.id;
      
      // Base query to get comments with upvote lizard counts and user's upvote status
      var query = _supabase
          .from('comments')
          .select('''
            id,
            content,
            randomized_username,
            upvote_lizard_count,
            created_at,
            updated_at,
            linked_question_ids,
            is_nsfw,
            author_id
          ''')
          .eq('question_id', questionId)
          .eq('is_hidden', false)
          .order(sortBy, ascending: ascending)
          .order('created_at', ascending: false) // Secondary sort by creation time
          .range(page * limit, (page + 1) * limit - 1);

      final response = await query;
      List<Map<String, dynamic>> comments = List<Map<String, dynamic>>.from(response);
      
      // Calculate actual upvote counts from reactions table if the stored count seems wrong
      if (comments.isNotEmpty) {
        final commentIds = comments.map((c) => c['id']).toList();
        
        // Get actual counts from the reactions table
        final countsResponse = await _supabase
            .from('comment_upvote_lizard_reactions')
            .select('comment_id')
            .inFilter('comment_id', commentIds);
        
        // Count reactions per comment
        final Map<String, int> actualCounts = {};
        for (final reaction in countsResponse) {
          final commentId = reaction['comment_id'].toString();
          actualCounts[commentId] = (actualCounts[commentId] ?? 0) + 1;
        }
        
        // Update comments with actual counts
        for (final comment in comments) {
          final commentId = comment['id'].toString();
          final actualCount = actualCounts[commentId] ?? 0;
          final storedCount = comment['upvote_lizard_count'] as int? ?? 0;
          
          // Use the actual count from reactions table
          comment['upvote_lizard_count'] = actualCount;
          
          if (actualCount != storedCount) {
            print('Comment $commentId: stored count=$storedCount, actual count=$actualCount - using actual');
          }
        }
      }

      // If user is authenticated, check which comments they've upvoted
      if (currentUserId != null && comments.isNotEmpty) {
        final commentIds = comments.map((c) => c['id']).toList();
        
        final upvotesResponse = await _supabase
            .from('comment_upvote_lizard_reactions')
            .select('comment_id')
            .eq('user_id', currentUserId)
            .inFilter('comment_id', commentIds);

        final upvotedCommentIds = Set<String>.from(
          upvotesResponse.map((r) => r['comment_id'].toString())
        );

        // Add user_has_upvoted field to each comment
        for (var comment in comments) {
          comment['user_has_upvoted'] = upvotedCommentIds.contains(comment['id'].toString());
        }
      } else {
        // If not authenticated, set all to false
        for (var comment in comments) {
          comment['user_has_upvoted'] = false;
        }
      }

      return comments;
    } catch (e) {
      print('Error fetching comments: $e');
      throw Exception('Failed to load comments: ${e.toString()}');
    }
  }

  /// Get comments for a specific suggestion with pagination
  Future<List<Map<String, dynamic>>> getCommentsForSuggestion(
    String suggestionId, {
    int page = 0,
    int limit = 20,
    String sortBy = 'created_at', // 'upvote_lizard_count', 'created_at'
    bool ascending = true, // true for chronological (oldest first), false for votes (highest first)
  }) async {
    try {
      final currentUserId = _supabase.auth.currentUser?.id;
      
      // Base query to get comments with upvote lizard counts and user's upvote status
      var query = _supabase
          .from('comments')
          .select('''
            id,
            content,
            randomized_username,
            upvote_lizard_count,
            created_at,
            updated_at,
            linked_suggestion_ids,
            linked_question_ids,
            is_nsfw,
            author_id
          ''')
          .eq('suggestion_id', suggestionId)
          .eq('is_hidden', false)
          .order(sortBy, ascending: ascending)
          .order('created_at', ascending: false) // Secondary sort by creation time
          .range(page * limit, (page + 1) * limit - 1);

      final response = await query;
      List<Map<String, dynamic>> comments = List<Map<String, dynamic>>.from(response);

      // Calculate actual upvote counts from reactions table if the stored count seems wrong
      if (comments.isNotEmpty) {
        final commentIds = comments.map((c) => c['id']).toList();
        
        // Get actual counts from the reactions table
        final countsResponse = await _supabase
            .from('comment_upvote_lizard_reactions')
            .select('comment_id')
            .inFilter('comment_id', commentIds);
        
        // Count reactions per comment
        final Map<String, int> actualCounts = {};
        for (final reaction in countsResponse) {
          final commentId = reaction['comment_id'].toString();
          actualCounts[commentId] = (actualCounts[commentId] ?? 0) + 1;
        }
        
        // Update comments with actual counts
        for (final comment in comments) {
          final commentId = comment['id'].toString();
          final actualCount = actualCounts[commentId] ?? 0;
          final storedCount = comment['upvote_lizard_count'] as int? ?? 0;
          
          // Use the actual count from reactions table
          comment['upvote_lizard_count'] = actualCount;
          
          if (actualCount != storedCount) {
            print('Comment $commentId: stored count=$storedCount, actual count=$actualCount - using actual');
          }
        }
      }

      // If user is authenticated, check which comments they've upvoted
      if (currentUserId != null && comments.isNotEmpty) {
        final commentIds = comments.map((c) => c['id']).toList();
        
        final upvotesResponse = await _supabase
            .from('comment_upvote_lizard_reactions')
            .select('comment_id')
            .eq('user_id', currentUserId)
            .inFilter('comment_id', commentIds);

        final upvotedCommentIds = Set<String>.from(
          upvotesResponse.map((r) => r['comment_id'].toString())
        );

        // Add user_has_upvoted field to each comment
        for (var comment in comments) {
          comment['user_has_upvoted'] = upvotedCommentIds.contains(comment['id'].toString());
        }
      } else {
        // If not authenticated, set all to false
        for (var comment in comments) {
          comment['user_has_upvoted'] = false;
        }
      }

      return comments;
    } catch (e) {
      print('Error fetching suggestion comments: $e');
      throw Exception('Failed to load suggestion comments: ${e.toString()}');
    }
  }

  /// Add a new comment to a question
  Future<Map<String, dynamic>> addComment({
    required String questionId,
    required String content,
    List<String>? linkedQuestionIds,
    bool isNSFW = false,
    WatchlistService? watchlistService,
  }) async {
    try {
      final currentUser = _supabase.auth.currentUser;
      if (currentUser == null) {
        throw Exception('User must be authenticated to add comments');
      }

      // Generate or get randomized username for this user on this question
      final randomizedUsername = await _getOrCreateRandomizedUsername(
        questionId, 
        currentUser.id
      );

      // Insert the comment
      final response = await _supabase
          .from('comments')
          .insert({
            'question_id': questionId,
            'author_id': currentUser.id,
            'content': content,
            'randomized_username': randomizedUsername,
            'linked_question_ids': linkedQuestionIds,
            'is_nsfw': isNSFW,
          })
          .select()
          .single();

      // Auto-subscribe commenter to question
      if (watchlistService != null) {
        try {
          // Get current vote and comment counts for the subscription
          final questionResponse = await _supabase
              .from('questions')
              .select('id')
              .eq('id', questionId)
              .single();
          
          if (questionResponse != null) {
            // Get vote count
            final voteCountResponse = await _supabase
                .from('responses')
                .select('id')
                .eq('question_id', questionId);
            final voteCount = voteCountResponse.length;
            
            // Get comment count (including this new comment)
            final commentCountResponse = await _supabase
                .from('comments')
                .select('id')
                .eq('question_id', questionId)
                .eq('is_hidden', false);
            final commentCount = commentCountResponse.length;
            
            await watchlistService.subscribeToQuestion(
              questionId,
              voteCount,
              commentCount,
              isAutoSubscribe: true,
              source: 'comment',
              showSnackbar: false,
            );
            print('\u2705 Auto-subscribed commenter to question $questionId');
          }
        } catch (e) {
          print('\u274c Error auto-subscribing commenter: $e');
          // Don't fail comment creation if subscription fails
        }
      }

      // Trigger notification Edge Function
      try {
        print('🔔 Calling send-comment-notification Edge Function for question $questionId');
        final notificationPayload = {
          'commentId': response['id'],
          'questionId': questionId,
          'commenterId': currentUser.id,
          'commenterName': randomizedUsername,
          'commentPreview': content.length > 50 ? content.substring(0, 50) : content,
        };
        print('📧 Notification payload: $notificationPayload');
        
        final result = await _supabase.functions.invoke('send-comment-notification', 
          body: notificationPayload,
        );
        
        print('\u2705 Comment notification Edge Function completed successfully');
        print('📊 Notification result: ${result.data}');
      } catch (e) {
        print('\u274c Error triggering comment notifications: $e');
        print('🔍 Error details: ${e.toString()}');
        // Don't fail comment creation if notification fails
      }

      // Create activity items for users subscribed to this question
      try {
        await _createCommentActivityItems(questionId, response['id'], randomizedUsername, content, currentUser.id);
        print('\u2705 Created comment activity items for question subscribers');
      } catch (e) {
        print('\u274c Error creating comment activity items: $e');
        // Don't fail comment creation if activity item creation fails
      }

      // Add user_has_upvoted field (false for new comment)
      response['user_has_upvoted'] = false;
      
      return response;
    } catch (e) {
      print('Error adding comment: $e');
      throw Exception('Failed to add comment: ${e.toString()}');
    }
  }

  /// Add a new comment to a suggestion
  Future<Map<String, dynamic>> addSuggestionComment({
    required String suggestionId,
    required String content,
    List<String>? linkedSuggestionIds,
    List<String>? linkedQuestionIds,
    bool isNSFW = false,
  }) async {
    try {
      final currentUser = _supabase.auth.currentUser;
      if (currentUser == null) {
        throw Exception('User must be authenticated to add comments');
      }

      // Generate or get randomized username for this user on this suggestion
      final randomizedUsername = await _getOrCreateRandomizedUsernameForSuggestion(
        suggestionId, 
        currentUser.id
      );

      // Insert the comment using proper suggestion comment schema
      final response = await _supabase
          .from('comments')
          .insert({
            'suggestion_id': suggestionId,
            'author_id': currentUser.id,
            'content': content,
            'randomized_username': randomizedUsername,
            'linked_suggestion_ids': linkedSuggestionIds,
            'linked_question_ids': linkedQuestionIds,
            'is_nsfw': isNSFW,
          })
          .select()
          .single();

      // Auto-subscribe commenter to suggestion
      try {
        await autoSubscribeToSuggestion(suggestionId, currentUser.id, 'comment');
        print('✅ Auto-subscribed commenter to suggestion $suggestionId');
      } catch (e) {
        print('❌ Error auto-subscribing commenter to suggestion: $e');
        // Don't fail comment creation if subscription fails
      }

      // Trigger notification Edge Function for suggestion comments
      try {
        print('🔔 Calling send-suggestion-comment-notification Edge Function for suggestion $suggestionId');
        final notificationPayload = {
          'commentId': response['id'],
          'suggestionId': suggestionId,
          'commenterId': currentUser.id,
          'commenterName': randomizedUsername,
          'commentPreview': content.length > 50 ? content.substring(0, 50) : content,
        };
        print('📧 Suggestion notification payload: $notificationPayload');
        
        final result = await _supabase.functions.invoke('send-suggestion-comment-notification', 
          body: notificationPayload,
        );
        
        print('✅ Suggestion comment notification Edge Function completed successfully');
        print('📊 Suggestion notification result: ${result.data}');
      } catch (e) {
        print('❌ Error triggering suggestion comment notifications: $e');
        print('🔍 Error details: ${e.toString()}');
        // Don't fail comment creation if notification fails
      }

      // Create activity items for users subscribed to this suggestion
      try {
        await _createSuggestionCommentActivityItems(suggestionId, response['id'], randomizedUsername, content, currentUser.id);
        print('✅ Created suggestion comment activity items for subscribers');
      } catch (e) {
        print('❌ Error creating suggestion comment activity items: $e');
        // Don't fail comment creation if activity item creation fails
      }

      // Add user_has_upvoted field (false for new comment)
      response['user_has_upvoted'] = false;
      
      return response;
    } catch (e) {
      print('Error adding suggestion comment: $e');
      throw Exception('Failed to add suggestion comment: ${e.toString()}');
    }
  }

  /// Update an existing comment (only by the author)
  Future<Map<String, dynamic>> updateComment({
    required String commentId,
    required String content,
    List<String>? linkedQuestionIds,
    bool? isNSFW,
  }) async {
    try {
      final currentUser = _supabase.auth.currentUser;
      if (currentUser == null) {
        throw Exception('User must be authenticated to update comments');
      }

      final updateData = <String, dynamic>{
        'content': content,
        'updated_at': DateTime.now().toIso8601String(),
      };

      if (linkedQuestionIds != null) {
        updateData['linked_question_ids'] = linkedQuestionIds;
      }
      
      if (isNSFW != null) {
        updateData['is_nsfw'] = isNSFW;
      }

      final response = await _supabase
          .from('comments')
          .update(updateData)
          .eq('id', commentId)
          .eq('author_id', currentUser.id) // Ensure only author can update
          .select()
          .single();

      return response;
    } catch (e) {
      print('Error updating comment: $e');
      throw Exception('Failed to update comment: ${e.toString()}');
    }
  }

  /// Delete a comment (only by the author)
  Future<void> deleteComment(String commentId) async {
    try {
      final currentUser = _supabase.auth.currentUser;
      if (currentUser == null) {
        throw Exception('User must be authenticated to delete comments');
      }

      await _supabase
          .from('comments')
          .delete()
          .eq('id', commentId)
          .eq('author_id', currentUser.id); // Ensure only author can delete

    } catch (e) {
      print('Error deleting comment: $e');
      throw Exception('Failed to delete comment: ${e.toString()}');
    }
  }

  /// Add an upvote lizard reaction to a comment
  Future<void> addUpvoteLizard(String commentId) async {
    try {
      final currentUser = _supabase.auth.currentUser;
      if (currentUser == null) {
        throw Exception('User must be authenticated to upvote comments');
      }

      await _supabase
          .from('comment_upvote_lizard_reactions')
          .insert({
            'comment_id': commentId,
            'user_id': currentUser.id,
          });

    } catch (e) {
      print('Error adding upvote lizard: $e');
      throw Exception('Failed to add upvote lizard: ${e.toString()}');
    }
  }

  /// Remove an upvote lizard reaction from a comment
  Future<void> removeUpvoteLizard(String commentId) async {
    try {
      final currentUser = _supabase.auth.currentUser;
      if (currentUser == null) {
        throw Exception('User must be authenticated to remove upvote');
      }

      await _supabase
          .from('comment_upvote_lizard_reactions')
          .delete()
          .eq('comment_id', commentId)
          .eq('user_id', currentUser.id);

    } catch (e) {
      print('Error removing upvote lizard: $e');
      throw Exception('Failed to remove upvote lizard: ${e.toString()}');
    }
  }

  /// Report a comment
  Future<void> reportComment(String commentId, List<String> reasons) async {
    try {
      final currentUser = _supabase.auth.currentUser;
      if (currentUser == null) {
        throw Exception('User must be authenticated to report comments');
      }

      await _supabase
          .from('comment_reports')
          .insert({
            'comment_id': commentId,
            'reporter_id': currentUser.id,
            'reasons': reasons,
          });

    } catch (e) {
      print('Error reporting comment: $e');
      throw Exception('Failed to report comment: ${e.toString()}');
    }
  }

  /// Get or create a randomized username for a user on a specific question
  Future<String> _getOrCreateRandomizedUsername(String questionId, String userId) async {
    try {
      // First, try to get existing username
      final existingResponse = await _supabase
          .from('question_comment_usernames')
          .select('randomized_username')
          .eq('question_id', questionId)
          .eq('user_id', userId)
          .maybeSingle();

      if (existingResponse != null) {
        return existingResponse['randomized_username'];
      }

      // Generate a new randomized username
      final randomizedUsername = _generateRandomizedUsername();

      // Store it in the database
      await _supabase
          .from('question_comment_usernames')
          .insert({
            'question_id': questionId,
            'user_id': userId,
            'randomized_username': randomizedUsername,
          });

      return randomizedUsername;
    } catch (e) {
      print('Error getting/creating randomized username: $e');
      // Fallback to a simple randomized username if database operation fails
      return _generateRandomizedUsername();
    }
  }

  /// Get or create a randomized username for a user on a specific suggestion
  Future<String> _getOrCreateRandomizedUsernameForSuggestion(String suggestionId, String userId) async {
    try {
      // First, try to get existing username
      final existingResponse = await _supabase
          .from('suggestion_comment_usernames')
          .select('randomized_username')
          .eq('suggestion_id', suggestionId)
          .eq('user_id', userId)
          .maybeSingle();
      if (existingResponse != null) {
        return existingResponse['randomized_username'];
      }
      
      // Generate a new randomized username
      final randomizedUsername = _generateRandomizedUsername();
      
      // Store it in the database
      await _supabase
          .from('suggestion_comment_usernames')
          .insert({
            'suggestion_id': suggestionId,
            'user_id': userId,
            'randomized_username': randomizedUsername,
          });
          
      return randomizedUsername;
    } catch (e) {
      print('Error getting/creating randomized username for suggestion: $e');
      // Fallback to a deterministic username if database operation fails
      final seed = '${userId}_$suggestionId'.hashCode;
      final random = Math.Random(seed);
      return _generateRandomizedUsernameWithSeed(random);
    }
  }

  /// Generate a randomized username
  String _generateRandomizedUsername() {
    final adjectives = [
      'Absurd', 'Antsy', 'Anxious', 'Awkward', 'Baroque', 'Based', 'Blushing', 'Boisterous',
      'Bold', 'Cheeky', 'Chill', 'Clouty', 'Clumsy', 'Cool', 'Cranky', 'Cringe',
      'Curious', 'Cursed', 'Dehydrated', 'Delulu', 'Deranged', 'Disheveled', 'Ditsy', 'Doomscrolling',
      'Doomed', 'Dreamy', 'Dusky', 'Envious', 'Erratic', 'Exploded', 'Forgetful', 'Feral',
      'Fizzy', 'Flaky', 'Flirty', 'Foggy', 'Funky', 'Ghostly', 'Giddy', 'Goofy',
      'Gremlin', 'Grumpy', 'Haunted', 'Hyper', 'Indignant', 'Lazy', 'Liminal', 'Loitering',
      'Loopy', 'Lurking', 'MainChar', 'Melodramatic', 'Moody', 'Naive', 'Nebulous', 'Oblivious',
      'Overstimulated', 'Pensive', 'Quirky', 'Rattled', 'Reckless', 'Salty', 'Sassy', 'Scatterbrained',
      'Serious', 'Shadowed', 'Shy', 'Skittish', 'Sleepy', 'Slinky', 'Slothful', 'Smirking',
      'Snappy', 'Snarky', 'Sneaky', 'Soggy', 'Spicy', 'Suspect', 'Talkative', 'Thirsty',
      'Timid', 'Tiresome', 'Twinkly', 'Unbothered', 'Unhinged', 'Unkempt', 'Unreachable', 'Unruly',
      'Wacky', 'Whimsical', 'Wiggly', 'Willowy', 'Wistful', 'Witty', 'Yappy', 'Zany',
      'Zesty', 'Zonked', 'Zooded', 'Panther', 'Jacksons', 'Parsons', 'Mellers', 'Oustalets',
      'Veiled', 'Four-Horned', 'Rhinoceros', 'Carpet', 'Dwarf', 'Flap-Necked', 'Short-Horned', 'Spectral-Pygmy', 'Tiger',
    ];

    final random = Random();
    final adjective = adjectives[random.nextInt(adjectives.length)];
    final number = random.nextInt(99) + 1; // 1-99
    
    return '${adjective.toLowerCase()}_chameleon$number';
  }

  /// Generate a randomized username with a specific seed for consistency
  String _generateRandomizedUsernameWithSeed(Random random) {
    final adjectives = [
      'Absurd', 'Antsy', 'Anxious', 'Awkward', 'Baroque', 'Based', 'Blushing', 'Boisterous',
      'Bold', 'Cheeky', 'Chill', 'Clouty', 'Clumsy', 'Cool', 'Cranky', 'Cringe',
      'Curious', 'Cursed', 'Dehydrated', 'Delulu', 'Deranged', 'Disheveled', 'Ditsy', 'Doomscrolling',
      'Doomed', 'Dreamy', 'Dusky', 'Envious', 'Erratic', 'Exploded', 'Forgetful', 'Feral',
      'Fizzy', 'Flaky', 'Flirty', 'Foggy', 'Funky', 'Ghostly', 'Giddy', 'Goofy',
      'Gremlin', 'Grumpy', 'Haunted', 'Hyper', 'Indignant', 'Lazy', 'Liminal', 'Loitering',
      'Loopy', 'Lurking', 'MainChar', 'Melodramatic', 'Moody', 'Naive', 'Nebulous', 'Oblivious',
      'Overstimulated', 'Pensive', 'Quirky', 'Rattled', 'Reckless', 'Salty', 'Sassy', 'Scatterbrained',
      'Serious', 'Shadowed', 'Shy', 'Skittish', 'Sleepy', 'Slinky', 'Slothful', 'Smirking',
      'Snappy', 'Snarky', 'Sneaky', 'Soggy', 'Spicy', 'Suspect', 'Talkative', 'Thirsty',
      'Timid', 'Tiresome', 'Twinkly', 'Unbothered', 'Unhinged', 'Unkempt', 'Unreachable', 'Unruly',
      'Wacky', 'Whimsical', 'Wiggly', 'Willowy', 'Wistful', 'Witty', 'Yappy', 'Zany',
      'Zesty', 'Zonked', 'Zooded', 'Panther', 'Jacksons', 'Parsons', 'Mellers', 'Oustalets',
      'Veiled', 'Four-Horned', 'Rhinoceros', 'Carpet', 'Dwarf', 'Flap-Necked', 'Short-Horned', 'Spectral-Pygmy', 'Tiger',
    ];
    final adjective = adjectives[random.nextInt(adjectives.length)];
    final number = random.nextInt(99) + 1; // 1-99
    
    return '${adjective.toLowerCase()}_chameleon$number';
  }

  /// Get comment count for a question
  Future<int> getCommentCount(String questionId) async {
    try {
      final response = await _supabase
          .from('comments')
          .select('id')
          .eq('question_id', questionId)
          .eq('is_hidden', false);

      return response.length;
    } catch (e) {
      print('Error getting comment count: $e');
      return 0;
    }
  }

  /// Check if user has commented on a question
  Future<bool> hasUserCommented(String questionId) async {
    try {
      final currentUser = _supabase.auth.currentUser;
      if (currentUser == null) return false;

      final response = await _supabase
          .from('comments')
          .select('id')
          .eq('question_id', questionId)
          .eq('author_id', currentUser.id)
          .eq('is_hidden', false)
          .limit(1);

      return response.isNotEmpty;
    } catch (e) {
      print('Error checking if user commented: $e');
      return false;
    }
  }

  /// Generate dummy comments for testing UI (TESTING ONLY)
  static List<Map<String, dynamic>> generateDummyComments({int count = 5}) {
    final random = Random();
    final now = DateTime.now();
    
    final sampleComments = [
      "This is such an interesting question! I've been thinking about this exact topic lately and honestly, I'm not sure what to think anymore. The world has changed so much.",
      "Great question! 🦎",
      "I completely disagree with most people here. This is actually a much more nuanced issue than people realize, and we should be considering the broader implications of our choices in today's society.",
      "Short and sweet comment.",
      "Has anyone else noticed that this kind of thing happens more often than we'd like to admit? I mean, just yesterday I was talking to my friend about exactly this topic and we couldn't come to a conclusion.",
      "This reminds me of a similar situation that happened to me last year...",
      "🤔 Making me think differently about this topic",
      "Really good point in the original question. I think we often overlook these details.",
      "This is exactly why I love this app - gets people thinking about real issues that matter to all of us in our daily lives.",
    ];
    
    return List.generate(count, (index) {
      final commentText = sampleComments[random.nextInt(sampleComments.length)];
      final createdAt = now.subtract(Duration(
        hours: random.nextInt(72), // 0-72 hours ago
        minutes: random.nextInt(60),
      ));
      
      return {
        'id': 'dummy_comment_$index',
        'content': commentText,
        'randomized_username': _generateDummyUsername(),
        'upvote_lizard_count': random.nextInt(15), // 0-14 upvotes
        'user_has_upvoted': random.nextBool(),
        'created_at': createdAt.toIso8601String(),
        'updated_at': createdAt.toIso8601String(),
        'linked_question_ids': random.nextDouble() > 0.8 
            ? [_generateRealisticQuestionId(random)] 
            : null, // 20% chance of having linked questions
        'is_nsfw': false,
      };
    });
  }

  /// Generate realistic question ID for testing
  static String _generateRealisticQuestionId(Random random) {
    // Use real question IDs for testing
    final questionIds = [
      'e4a3573a-5ffa-46b0-a60d-23b16c3ef2d8',
      '6c92b9e7-ee72-4d4d-b97f-3b1be7f1b163',
      '80f9a13a-71d6-4d20-8c5e-8b1b1f9b8ea0',
    ];
    return questionIds[random.nextInt(questionIds.length)];
  }

  /// Auto-subscribe user to suggestion (simple implementation)
  Future<void> autoSubscribeToSuggestion(String suggestionId, String userId, String source) async {
    try {
      // Check if user is already subscribed
      final existingSubscription = await _supabase
          .from('suggestion_subscriptions')
          .select('id')
          .eq('suggestion_id', suggestionId)
          .eq('user_id', userId)
          .maybeSingle();

      if (existingSubscription != null) {
        print('User already subscribed to suggestion $suggestionId');
        return;
      }

      // Create new subscription
      await _supabase
          .from('suggestion_subscriptions')
          .insert({
            'suggestion_id': suggestionId,
            'user_id': userId,
            'subscription_source': source,
            'subscribed_at': DateTime.now().toIso8601String(),
            'last_comment_count': 1, // This comment we just added
            'last_notified_at': DateTime.now().toIso8601String(),
            'muted': false,
          });

      print('✅ Created suggestion subscription for user $userId on suggestion $suggestionId');
    } catch (e) {
      print('Error creating suggestion subscription: $e');
      // Don't throw - this is a nice-to-have feature
    }
  }

  /// Generate dummy username for testing
  static String _generateDummyUsername() {
    final adjectives = [
      'Absurd', 'Antsy', 'Anxious', 'Awkward', 'Baroque', 'Based', 'Blushing', 'Boisterous',
      'Bold', 'Cheeky', 'Chill', 'Clouty', 'Clumsy', 'Cool', 'Cranky', 'Cringe',
      'Curious', 'Cursed', 'Dehydrated', 'Delulu', 'Deranged', 'Disheveled', 'Ditsy', 'Doomscrolling',
      'Doomed', 'Dreamy', 'Dusky', 'Envious', 'Erratic', 'Exploded', 'Forgetful', 'Feral',
      'Fizzy', 'Flaky', 'Flirty', 'Foggy', 'Funky', 'Ghostly', 'Giddy', 'Goofy',
      'Gremlin', 'Grumpy', 'Haunted', 'Hyper', 'Indignant', 'Lazy', 'Liminal', 'Loitering',
      'Loopy', 'Lurking', 'MainChar', 'Melodramatic', 'Moody', 'Naive', 'Nebulous', 'Oblivious',
      'Overstimulated', 'Pensive', 'Quirky', 'Rattled', 'Reckless', 'Salty', 'Sassy', 'Scatterbrained',
      'Serious', 'Shadowed', 'Shy', 'Skittish', 'Sleepy', 'Slinky', 'Slothful', 'Smirking',
      'Snappy', 'Snarky', 'Sneaky', 'Soggy', 'Spicy', 'Suspect', 'Talkative', 'Thirsty',
      'Timid', 'Tiresome', 'Twinkly', 'Unbothered', 'Unhinged', 'Unkempt', 'Unreachable', 'Unruly',
      'Wacky', 'Whimsical', 'Wiggly', 'Willowy', 'Wistful', 'Witty', 'Yappy', 'Zany',
      'Zesty', 'Zonked', 'Zooded'
    ];

    final random = Random();
    final adjective = adjectives[random.nextInt(adjectives.length)];
    final number = random.nextInt(99) + 1; // 1-99
    return '${adjective.toLowerCase()}_chameleon$number';
  }

  /// Create activity items for users subscribed to a question when a new comment is added
  Future<void> _createCommentActivityItems(String questionId, String commentId, String commenterName, String content, String commenterId) async {
    try {
      // Get the question details for the activity title
      final questionResponse = await _supabase
          .from('questions')
          .select('prompt, title')
          .eq('id', questionId)
          .single();

      final questionText = questionResponse['prompt'] ?? questionResponse['title'] ?? 'A question';
      final truncatedQuestionText = questionText.length > 50 
          ? '${questionText.substring(0, 47)}...' 
          : questionText;

      final commentPreview = content.length > 100 
          ? '${content.substring(0, 97)}...' 
          : content;

      // Create activity items via RPC function (this would need to be created on the backend)
      await _supabase.rpc('create_comment_activity_items', params: {
        'question_id': questionId,
        'comment_id': commentId,
        'commenter_id': commenterId,
        'commenter_name': commenterName,
        'question_text': truncatedQuestionText,
        'comment_preview': commentPreview,
      });

      print('✅ Created comment activity items via RPC for question $questionId');
    } catch (e) {
      print('❌ Error creating comment activity items: $e');
      // Fallback: create activity items for question subscribers manually
      await _createCommentActivityItemsFallback(questionId, commentId, commenterName, content, commenterId);
    }
  }

  /// Fallback method to create comment activity items manually
  Future<void> _createCommentActivityItemsFallback(String questionId, String commentId, String commenterName, String content, String commenterId) async {
    try {
      // For now, we'll skip the manual creation as it would require knowing all subscribers
      // In a real implementation, this would query the watchlist/subscription system
      print('⚠️ Comment activity items fallback not implemented - RPC function needed on backend');
    } catch (e) {
      print('❌ Error in comment activity items fallback: $e');
    }
  }

  /// Create activity items for users subscribed to a suggestion when a new comment is added
  Future<void> _createSuggestionCommentActivityItems(String suggestionId, String commentId, String commenterName, String content, String commenterId) async {
    try {
      // Get the suggestion details for the activity title
      final suggestionResponse = await _supabase
          .from('suggestions')
          .select('title, description')
          .eq('id', suggestionId)
          .single();

      final suggestionText = suggestionResponse['title'] ?? suggestionResponse['description'] ?? 'A suggestion';
      final truncatedSuggestionText = suggestionText.length > 50 
          ? '${suggestionText.substring(0, 47)}...' 
          : suggestionText;

      final commentPreview = content.length > 100 
          ? '${content.substring(0, 97)}...' 
          : content;

      // Create activity items via RPC function (this would need to be created on the backend)
      await _supabase.rpc('create_suggestion_comment_activity_items', params: {
        'suggestion_id': suggestionId,
        'comment_id': commentId,
        'commenter_id': commenterId,
        'commenter_name': commenterName,
        'suggestion_text': truncatedSuggestionText,
        'comment_preview': commentPreview,
      });

      print('✅ Created suggestion comment activity items via RPC for suggestion $suggestionId');
    } catch (e) {
      print('❌ Error creating suggestion comment activity items: $e');
      // For now, we'll skip the fallback as it would require backend RPC functions
      print('⚠️ Suggestion comment activity items fallback not implemented - RPC function needed on backend');
    }
  }
}