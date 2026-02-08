// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:provider/provider.dart';
import 'package:posthog_flutter/posthog_flutter.dart';
import '../utils/time_utils.dart';
import 'question_type_badge.dart';
import '../services/deep_link_service.dart';
import '../services/guest_user_tracking_service.dart';
import '../services/user_service.dart';
import '../services/analytics_service.dart';

class QuestionCard extends StatelessWidget {
  final Map<String, dynamic> question;
  final VoidCallback onTap;

  const QuestionCard({
    Key? key,
    required this.question,
    required this.onTap,
  }) : super(key: key);

  // Helper method to safely get comment count
  int _getCommentCount(Map<String, dynamic> question) {
    return question['comment_count'] as int? ?? 0;
  }

  // Helper method to get the top emoji reaction
  String? _getTopEmojiReaction(Map<String, dynamic> question) {
    // First, try the pre-computed top_emoji field from materialized view
    final precomputedTopEmoji = question['top_emoji']?.toString();
    if (precomputedTopEmoji != null && precomputedTopEmoji.isNotEmpty) {
      return precomputedTopEmoji;
    }

    // Fallback to client-side calculation if top_emoji is not available
    final reactions = question['reactions'];
    
    if (reactions == null) return null;

    Map<String, dynamic>? reactionsMap;

    // Handle both Map and String (JSON) formats
    if (reactions is Map<String, dynamic>) {
      reactionsMap = reactions;
    } else if (reactions is String) {
      try {
        reactionsMap = json.decode(reactions) as Map<String, dynamic>;
      } catch (e) {
        return null;
      }
    }

    if (reactionsMap == null || reactionsMap.isEmpty) return null;

    // Find the emoji with the highest count
    String? topEmoji;
    int maxCount = 0;

    for (final entry in reactionsMap.entries) {
      final count = entry.value;
      if (count is int && count > maxCount) {
        maxCount = count;
        topEmoji = entry.key;
      }
    }

    // Only return emoji if it has at least 1 reaction
    return (maxCount > 0) ? topEmoji : null;
  }

  void _shareQuestion() {
    final questionId = question['id']?.toString();
    if (questionId == null) return;

    // Track question share
    AnalyticsService().trackEvent('question_shared', {
      'question_id': questionId,
      'question_type': question['type'] ?? 'unknown',
      'category': question['category'] ?? 'unknown',
      'share_method': 'native_share',
    });

    final shareLink = DeepLinkService.generateQuestionShareLink(questionId);
    final questionTitle = question['prompt'] ?? 'Check out this question';
    
    Share.share(
      'Check out this question on Read the Room:\n\n$questionTitle\n$shareLink',
      subject: 'Read the Room',
    );
  }
  
  void _trackQuestionViewed() {
    final questionId = question['id']?.toString();
    if (questionId == null) return;
    
    // Track question viewed in feed
    AnalyticsService().trackQuestionViewed(
      questionId,
      question['type'] ?? 'unknown',
      question['category'] ?? 'unknown',
      'feed',
      {
        'is_nsfw': question['is_nsfw'] ?? false,
        'vote_count': question['vote_count'] ?? 0,
        'comment_count': _getCommentCount(question),
        'location_scope': question['cities'] != null ? 'city' : 'country',
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    // Safe access to nested city data, handling null values
    final cityData = question['cities'];
    final String? cityName = cityData != null ? cityData['name']?.toString() : null;
    final String? countryCode = cityData != null ? cityData['country_code']?.toString() : question['country_code']?.toString();
    
    return Consumer<GuestUserTrackingService>(
      builder: (context, guestService, child) {
        return Consumer<UserService>(
          builder: (context, userService, child) {
            final questionId = question['id']?.toString();
            
            // Check if services are ready
            if (questionId == null) {
              return _buildCard(context, false, false, false);
            }
            
            // Always print debug info to see if this is being called
            print('DEBUG QuestionCard BUILD: questionId=$questionId, initialized=${guestService.isInitialized}');
            
            final wasViewedAsGuest = guestService.wasViewedAsGuest(questionId);
            final hasAnswered = userService.hasAnsweredQuestion(questionId);
            
            // Debug prints to understand what's happening
            print('DEBUG QuestionCard: questionId=$questionId, wasViewedAsGuest=$wasViewedAsGuest, hasAnswered=$hasAnswered, guestService.viewedQuestionIds=${guestService.viewedQuestionIds}');
            
            // Question is "voted" if user has answered OR if it was viewed as guest
            final isVoted = hasAnswered || wasViewedAsGuest;
            
            return _buildCard(context, isVoted, wasViewedAsGuest, hasAnswered);
          },
        );
      },
    );
  }

  Widget _buildCard(BuildContext context, bool isVoted, bool wasViewedAsGuest, bool hasAnswered) {
    // Safe access to nested city data, handling null values
    final cityData = question['cities'];
    final String? cityName = cityData != null ? cityData['name']?.toString() : null;
    final String? countryCode = cityData != null ? cityData['country_code']?.toString() : question['country_code']?.toString();
    
    final isDark = Theme.of(context).brightness == Brightness.dark;

    print('DEBUG _buildCard: questionId=${question['id']}, isVoted=$isVoted, opacity=${isVoted ? 0.6 : 1.0}');

    return Card(
          margin: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          elevation: isVoted && !isDark ? 0 : 2,
          color: isDark
              ? (isVoted ? Theme.of(context).scaffoldBackgroundColor : null)
              : (isVoted ? Theme.of(context).scaffoldBackgroundColor : Colors.white),
          child: InkWell(
            onTap: () {
              // Track question interaction
              _trackQuestionViewed();
              onTap();
            },
            child: Opacity(
              opacity: isVoted ? 0.6 : 1.0,
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        QuestionTypeBadge(type: question['type'] ?? 'unknown'),
                        SizedBox(width: 8),
                        // Show "Viewed" indicator for guest-viewed questions
                        if (wasViewedAsGuest && !hasAnswered)
                          Container(
                            padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.orange.withOpacity(0.2),
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(color: Colors.orange.withOpacity(0.4)),
                            ),
                            child: Text(
                              'Viewed',
                              style: TextStyle(
                                fontSize: 10,
                                color: Colors.orange[700],
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        if (countryCode != null) ...[
                          SizedBox(width: 8),
                          Text(
                            countryCode,
                            style: TextStyle(
                              color: Colors.grey[600],
                              fontSize: 12,
                            ),
                          ),
                        ],
                        Spacer(),
                        // Top emoji reaction
                        Builder(
                          builder: (context) {
                            final topEmoji = _getTopEmojiReaction(question);
                            print('🎭 UI DEBUG - Building reaction widget, topEmoji: $topEmoji');
                            if (topEmoji != null) {
                              return Container(
                                padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: Theme.of(context).primaryColor.withOpacity(0.1),
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                    color: Theme.of(context).primaryColor.withOpacity(0.3),
                                  ),
                                ),
                                child: Text(
                                  topEmoji,
                                  style: TextStyle(fontSize: 16),
                                ),
                              );
                            }
                            return SizedBox.shrink();
                          },
                        ),
                        if (_getTopEmojiReaction(question) != null) SizedBox(width: 8),
                        // Share button
                        IconButton(
                          icon: Icon(
                            Icons.share,
                            size: 20,
                            color: Colors.grey[600],
                          ),
                          onPressed: _shareQuestion,
                          constraints: BoxConstraints(),
                          padding: EdgeInsets.all(4),
                        ),
                        SizedBox(width: 8),
                        Text(
                          getTimeAgo(question['created_at']),
                          style: TextStyle(
                            color: Colors.grey[600],
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: 8),
                    Text(
                      question['prompt'] ?? 'No Title',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    if (question['description'] != null)
                      Padding(
                        padding: EdgeInsets.only(top: 4),
                        child: Text(
                          question['description'],
                          style: Theme.of(context).textTheme.bodyMedium,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    SizedBox(height: 8),
                    Row(
                      children: [
                        if (cityName != null)
                          Chip(
                            label: Text(
                              cityName,
                              style: TextStyle(fontSize: 12),
                            ),
                            backgroundColor: Colors.grey[200],
                            padding: EdgeInsets.zero,
                            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                        Spacer(),
                        // Display responses and comments
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              '${question['votes'] ?? 0} ${(question['votes'] ?? 0) == 1 ? 'response' : 'responses'}',
                              style: TextStyle(
                                color: Colors.grey[600],
                                fontSize: 12,
                              ),
                            ),
                            // Show comment count if there are comments
                            if (_getCommentCount(question) > 0) ...[
                              Text(
                                ' • ',
                                style: TextStyle(
                                  color: Colors.grey[600],
                                  fontSize: 12,
                                ),
                              ),
                              Text(
                                '${_getCommentCount(question)} ${_getCommentCount(question) == 1 ? 'comment' : 'comments'}',
                                style: TextStyle(
                                  color: Colors.grey[600],
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
  }
} 