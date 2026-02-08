// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/question_service.dart';
import '../services/user_service.dart';
import '../utils/theme_utils.dart';
import '../widgets/question_type_badge.dart';

class LinkedQuestionsSection extends StatefulWidget {
  final String questionId;
  final List<Map<String, dynamic>>? comments; // Get linked questions from comments
  final EdgeInsetsGeometry? margin;
  final bool useDummyData; // For testing UI
  final FeedContext? originalFeedContext; // Original feed context to preserve navigation
  final bool fromSearch; // Whether we came from search
  final bool fromUserScreen; // Whether we came from user screen

  const LinkedQuestionsSection({
    Key? key,
    required this.questionId,
    this.comments,
    this.margin,
    this.useDummyData = false,
    this.originalFeedContext,
    this.fromSearch = false,
    this.fromUserScreen = false,
  }) : super(key: key);

  @override
  State<LinkedQuestionsSection> createState() => _LinkedQuestionsSectionState();
}

class _LinkedQuestionsSectionState extends State<LinkedQuestionsSection> {
  List<Map<String, dynamic>> _linkedQuestions = [];
  bool _isLoading = false;
  bool _showAllLinkedQuestions = false;

  @override
  void initState() {
    super.initState();
    _extractLinkedQuestions();
  }

  @override
  void didUpdateWidget(LinkedQuestionsSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.comments != oldWidget.comments) {
      _extractLinkedQuestions();
    }
  }

  void _extractLinkedQuestions() {
    if (widget.useDummyData) {
      _linkedQuestions = _generateDummyLinkedQuestions();
      return;
    }

    if (widget.comments == null || widget.comments!.isEmpty) {
      setState(() {
        _linkedQuestions = [];
      });
      return;
    }

    // Extract linked questions from comments, sorted by upvote count
    final linkedQuestionIds = <String>{};
    final commentUpvotes = <String, int>{};
    
    // Sort comments by upvote count descending first
    final sortedComments = List<Map<String, dynamic>>.from(widget.comments!)
      ..sort((a, b) => (b['upvote_lizard_count'] as int? ?? 0).compareTo(a['upvote_lizard_count'] as int? ?? 0));
    
    // Extract linked question IDs from highest-upvoted comments first
    for (final comment in sortedComments) {
      final linkedIds = comment['linked_question_ids'] as List<dynamic>?;
      if (linkedIds != null && linkedIds.isNotEmpty) {
        final upvoteCount = comment['upvote_lizard_count'] as int? ?? 0;
        for (final id in linkedIds) {
          final questionId = id.toString();
          if (!linkedQuestionIds.contains(questionId)) {
            linkedQuestionIds.add(questionId);
            commentUpvotes[questionId] = upvoteCount;
          }
        }
      }
    }

    // Convert to list and sort by the upvote count of the comment that linked them
    final sortedLinkedQuestions = linkedQuestionIds.map((id) => {
      'id': id,
      'comment_upvotes': commentUpvotes[id] ?? 0,
    }).toList()
      ..sort((a, b) => (b['comment_upvotes'] as int).compareTo(a['comment_upvotes'] as int));

    _loadLinkedQuestionsData(sortedLinkedQuestions.map((q) => q['id'] as String).toList());
  }

  Future<void> _loadLinkedQuestionsData(List<String> questionIds) async {
    if (questionIds.isEmpty) {
      setState(() {
        _linkedQuestions = [];
      });
      return;
    }

    setState(() {
      _isLoading = true;
    });

    try {
      final questionService = Provider.of<QuestionService>(context, listen: false);
      final questions = <Map<String, dynamic>>[];

      for (String questionId in questionIds) {
        try {
          final question = await questionService.getQuestionById(questionId);
          if (question != null) {
            questions.add(question);
          }
        } catch (e) {
          print('Error loading linked question $questionId: $e');
          // Add a placeholder for failed loads
          questions.add({
            'id': questionId,
            'prompt': 'Question not found',
            'type': 'unknown',
            'votes': 0,
            'is_error': true,
          });
        }
      }

      if (mounted) {
        setState(() {
          _linkedQuestions = questions;
          _isLoading = false;
        });
      }
    } catch (e) {
      print('Error loading linked questions: $e');
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  List<Map<String, dynamic>> _generateDummyLinkedQuestions() {
    return [
      {
        'id': 'e4a3573a-5ffa-46b0-a60d-23b16c3ef2d8',
        'prompt': 'Should pineapple be allowed on pizza?',
        'type': 'approval_rating',
        'votes': 1247,
        'created_at': DateTime.now().subtract(Duration(days: 2)).toIso8601String(),
        'is_dummy': false, // Use real navigation now
      },
      {
        'id': '6c92b9e7-ee72-4d4d-b97f-3b1be7f1b163', 
        'prompt': 'What\'s your favorite programming language?',
        'type': 'multiple_choice',
        'votes': 892,
        'created_at': DateTime.now().subtract(Duration(days: 1)).toIso8601String(),
        'is_dummy': false,
      },
      {
        'id': '80f9a13a-71d6-4d20-8c5e-8b1b1f9b8ea0', 
        'prompt': 'Is remote work the future of employment?',
        'type': 'approval_rating',
        'votes': 2156,
        'created_at': DateTime.now().subtract(Duration(hours: 12)).toIso8601String(),
        'is_dummy': false,
      },
    ];
  }

  Future<void> _navigateToQuestion(Map<String, dynamic> question, int questionIndex) async {
    if (question['is_error'] == true) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('This question is no longer available'),
          backgroundColor: Colors.orange,
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }

    // Handle dummy questions (for testing UI)
    if (question['is_dummy'] == true) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('This is a dummy question for UI testing'),
          backgroundColor: Colors.blue,
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }

    try {
      final questionService = Provider.of<QuestionService>(context, listen: false);
      final userService = Provider.of<UserService>(context, listen: false);
      
      // Create FeedContext for linked questions that preserves navigation back to original context
      final feedContext = FeedContext(
        feedType: 'linked_questions',
        filters: {}, // No filters for linked questions
        questions: _linkedQuestions,
        currentQuestionIndex: questionIndex,
        originalQuestionId: question['id']?.toString(),
        originalQuestionIndex: questionIndex,
      );
      
      // Check if user has already answered this question
      final questionId = question['id']?.toString();
      if (questionId != null && userService.hasAnsweredQuestion(questionId)) {
        // User has answered - navigate to results screen
        await questionService.navigateToResultsScreen(
          context, 
          question, 
          feedContext: feedContext,
          fromSearch: widget.fromSearch,
          fromUserScreen: widget.fromUserScreen,
        );
      } else {
        // User hasn't answered - navigate to answer screen
        await questionService.navigateToAnswerScreen(
          context, 
          question, 
          feedContext: feedContext,
          fromSearch: widget.fromSearch,
          fromUserScreen: widget.fromUserScreen,
        );
      }
    } catch (e) {
      print('Error navigating to question: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to open question'),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 2),
          ),
        );
      }
    }
  }

  Widget _buildLinkedQuestionCard(Map<String, dynamic> question, int index) {
    final isError = question['is_error'] == true;
    final prompt = question['prompt']?.toString() ?? 'Untitled Question';
    final voteCount = question['votes'] as int? ?? 0;
    final questionType = question['type']?.toString() ?? 'unknown';
    final createdAt = question['created_at']?.toString() ?? DateTime.now().toIso8601String();
    final timeAgo = _getTimeAgo(createdAt);

    return ListTile(
      leading: QuestionTypeBadge(
        type: questionType,
        color: isError ? Colors.grey : Theme.of(context).primaryColor,
      ),
      title: Text(
        prompt,
        style: TextStyle(
          color: isError ? Colors.grey : null,
        ),
      ),
      subtitle: Text(
        '$timeAgo • $voteCount ${voteCount == 1 ? 'vote' : 'votes'}',
        style: Theme.of(context).textTheme.bodySmall,
      ),
      trailing: isError ? Icon(Icons.error_outline, color: Colors.grey, size: 18) : null,
      onTap: isError ? null : () => _navigateToQuestion(question, index),
    );
  }


  String _getTimeAgo(String timestamp) {
    try {
      final dateTime = DateTime.parse(timestamp);
      final now = DateTime.now();
      final difference = now.difference(dateTime);

      if (difference.inDays > 0) {
        return '${difference.inDays}d ago';
      } else if (difference.inHours > 0) {
        return '${difference.inHours}h ago';
      } else if (difference.inMinutes > 0) {
        return '${difference.inMinutes}m ago';
      } else {
        return 'now';
      }
    } catch (e) {
      return 'recently';
    }
  }

  List<Map<String, dynamic>> get _displayedLinkedQuestions {
    if (_showAllLinkedQuestions) {
      return _linkedQuestions;
    }
    return _linkedQuestions.take(2).toList(); // Show only top 2
  }


  Widget _buildHeader() {
    return Row(
      children: [
        Icon(
          Icons.link,
          size: 18,
          color: Theme.of(context).primaryColor,
        ),
        SizedBox(width: 8),
        Text(
          'Linked Questions',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w600,
            fontSize: 16,
          ),
        ),
      ],
    );
  }

  Widget _buildShowMoreButton() {
    if (_linkedQuestions.length <= 2) {
      return SizedBox.shrink();
    }

    return Container(
      margin: EdgeInsets.symmetric(vertical: 8),
      width: double.infinity,
      child: TextButton(
        onPressed: () {
          setState(() {
            _showAllLinkedQuestions = !_showAllLinkedQuestions;
          });
        },
        style: TextButton.styleFrom(
          foregroundColor: Theme.of(context).primaryColor,
          padding: EdgeInsets.symmetric(vertical: 12),
        ),
        child: Text(
          _showAllLinkedQuestions 
              ? 'Collapse' 
              : 'Show all ${_linkedQuestions.length} linked questions',
          style: TextStyle(fontWeight: FontWeight.w500),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_linkedQuestions.isEmpty && !_isLoading) {
      return SizedBox.shrink();
    }

    return Container(
      margin: widget.margin ?? EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: Theme.of(context).dividerColor.withOpacity(0.2),
          width: 0.5,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.all(16),
            child: _buildHeader(),
          ),
          
          if (_isLoading)
            Container(
              padding: EdgeInsets.all(24),
              child: Center(
                child: CircularProgressIndicator(),
              ),
            )
          else ...[
            ...(_displayedLinkedQuestions.asMap().entries.map((entry) => 
              _buildLinkedQuestionCard(entry.value, entry.key))),
            _buildShowMoreButton(),
            SizedBox(height: 8),
          ],
        ],
      ),
    );
  }
}