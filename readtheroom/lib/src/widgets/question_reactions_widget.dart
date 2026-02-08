// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'dart:math';
import '../services/question_reactions_service.dart';

class QuestionReactionsWidget extends StatefulWidget {
  final String questionId;
  final Map<String, int>? initialReactions;
  final Set<String>? userReactions;
  final Function(String reaction, bool isAdding)? onReactionTap;
  final bool useDummyData;
  final EdgeInsetsGeometry? margin;

  const QuestionReactionsWidget({
    Key? key,
    required this.questionId,
    this.initialReactions,
    this.userReactions,
    this.onReactionTap,
    this.useDummyData = false,
    this.margin,
  }) : super(key: key);

  @override
  State<QuestionReactionsWidget> createState() => _QuestionReactionsWidgetState();
}

class _QuestionReactionsWidgetState extends State<QuestionReactionsWidget> {
  Map<String, int> _reactionCounts = {};
  Set<String> _userReactions = {};
  bool _isProcessing = false;
  bool _isLoading = true;
  final _reactionsService = QuestionReactionsService();

  static const List<String> _availableReactions = ['❤️', '🤔', '😡', '😂', '🤯'];

  @override
  void initState() {
    super.initState();
    
    if (widget.useDummyData) {
      _generateDummyData();
      setState(() {
        _isLoading = false;
      });
    } else {
      _loadReactions();
    }
  }

  Future<void> _loadReactions() async {
    try {
      final reactions = await _reactionsService.getQuestionReactions(widget.questionId);
      
      if (mounted) {
        setState(() {
          _reactionCounts = Map<String, int>.from(reactions['reactionCounts'] as Map<String, int>);
          _userReactions = Set<String>.from(reactions['userReactions'] as Set<String>);
          _isLoading = false;
        });
      }
    } catch (e) {
      print('Error loading reactions: $e');
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  /// Public method to refresh reactions from the server
  Future<void> refreshReactions() async {
    if (!widget.useDummyData) {
      await _loadReactions();
    }
  }

  void _generateDummyData() {
    final random = Random();
    
    // Generate random reaction counts
    for (final reaction in _availableReactions) {
      // 60% chance of having this reaction, with 0-25 count
      if (random.nextDouble() > 0.4) {
        _reactionCounts[reaction] = random.nextInt(26);
      }
    }
    
    // User has reacted to 20% of available reactions
    for (final reaction in _availableReactions) {
      if (random.nextDouble() > 0.8 && _reactionCounts.containsKey(reaction)) {
        _userReactions.add(reaction);
      }
    }
  }

  Future<void> _handleReactionTap(String reaction) async {
    if (_isProcessing) return;

    setState(() {
      _isProcessing = true;
    });

    // Store previous state for rollback
    final previousCounts = Map<String, int>.from(_reactionCounts);
    final previousUserReactions = Set<String>.from(_userReactions);

    try {
      final isCurrentlyReacted = _userReactions.contains(reaction);
      final isAdding = !isCurrentlyReacted;

      // Optimistic update - allow only one reaction per user
      setState(() {
        if (isAdding) {
          // Remove any existing reaction first
          final currentUserReaction = _userReactions.isNotEmpty ? _userReactions.first : null;
          if (currentUserReaction != null) {
            _userReactions.remove(currentUserReaction);
            _reactionCounts[currentUserReaction] = (_reactionCounts[currentUserReaction] ?? 1) - 1;
            if (_reactionCounts[currentUserReaction]! <= 0) {
              _reactionCounts.remove(currentUserReaction);
            }
          }
          // Add new reaction
          _userReactions.add(reaction);
          _reactionCounts[reaction] = (_reactionCounts[reaction] ?? 0) + 1;
        } else {
          // Remove current reaction
          _userReactions.remove(reaction);
          _reactionCounts[reaction] = (_reactionCounts[reaction] ?? 1) - 1;
          if (_reactionCounts[reaction]! <= 0) {
            _reactionCounts.remove(reaction);
          }
        }
      });

      // Make API call
      Map<String, dynamic> result;
      if (widget.useDummyData) {
        // Simulate network delay for testing
        await Future.delayed(Duration(milliseconds: 500));
        result = {
          'reactionCounts': _reactionCounts,
          'userReactions': _userReactions,
        };
      } else {
        result = await _reactionsService.toggleReaction(widget.questionId, reaction);
      }

      // Update with server response
      if (mounted) {
        setState(() {
          _reactionCounts = Map<String, int>.from(result['reactionCounts'] as Map<String, int>);
          _userReactions = Set<String>.from(result['userReactions'] as Set<String>);
        });
      }

      // Call the callback if provided
      if (widget.onReactionTap != null) {
        widget.onReactionTap!(reaction, isAdding);
      }

    } catch (e) {
      print('Error updating reaction: $e');
      
      // Revert optimistic update on error
      if (mounted) {
        setState(() {
          _reactionCounts = previousCounts;
          _userReactions = previousUserReactions;
        });

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to update reaction. Please try again.'),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 2),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isProcessing = false;
        });
      }
    }
  }

  List<String> _getUnusedReactions() {
    return _availableReactions.where((reaction) => 
      !_reactionCounts.containsKey(reaction) || _reactionCounts[reaction]! <= 0
    ).toList();
  }

  Widget _buildAddReactionButton() {
    return GestureDetector(
      onTap: _showReactionPicker,
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: Colors.grey.withOpacity(0.3),
            width: 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.add,
              size: 18,
              color: Colors.grey[600],
            ),
            SizedBox(width: 2),
            Icon(
              Icons.mood,
              size: 18,
              color: Colors.grey[600],
            ),
          ],
        ),
      ),
    );
  }

  void _showReactionPicker() {
    final unusedReactions = _getUnusedReactions();
    if (unusedReactions.isEmpty) return;

    showModalBottomSheet(
      context: context,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => Container(
        padding: EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Add a reaction',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            SizedBox(height: 16),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: unusedReactions.map((reaction) {
                return GestureDetector(
                  onTap: () {
                    Navigator.of(context).pop();
                    _handleReactionTap(reaction);
                  },
                  child: Container(
                    padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: Theme.of(context).primaryColor.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: Theme.of(context).primaryColor.withOpacity(0.3),
                        width: 1,
                      ),
                    ),
                    child: Text(
                      reaction,
                      style: TextStyle(fontSize: 20),
                    ),
                  ),
                );
              }).toList(),
            ),
            SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Widget _buildReactionButton(String reaction) {
    final count = _reactionCounts[reaction] ?? 0;
    final hasUserReacted = _userReactions.contains(reaction);
    final showCount = count > 0;

    return GestureDetector(
      onTap: () => _handleReactionTap(reaction),
      child: AnimatedContainer(
        duration: Duration(milliseconds: 200),
        padding: EdgeInsets.symmetric(
          horizontal: showCount ? 8 : 6,
          vertical: 6,
        ),
        decoration: BoxDecoration(
          color: hasUserReacted
              ? Theme.of(context).primaryColor.withOpacity(0.1)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: hasUserReacted
                ? Theme.of(context).primaryColor
                : Colors.grey.withOpacity(0.3),
            width: hasUserReacted ? 1.5 : 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              reaction,
              style: TextStyle(fontSize: 16),
            ),
            if (showCount) ...[
              SizedBox(width: 4),
              Text(
                count.toString(),
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: hasUserReacted
                      ? Theme.of(context).primaryColor
                      : Colors.grey[600],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Show loading state
    if (_isLoading) {
      return Container(
        margin: widget.margin ?? EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            Icon(
              Icons.mood,
              size: 16,
              color: Theme.of(context).primaryColor,
            ),
            SizedBox(width: 6),
            Text(
              'Reactions',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
                fontSize: 16,
              ),
            ),
            SizedBox(width: 8),
            SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(
                strokeWidth: 1.5,
                valueColor: AlwaysStoppedAnimation<Color>(Colors.grey[400]!),
              ),
            ),
          ],
        ),
      );
    }

    // Only show if there are reactions or user can add reactions
    final hasReactions = _reactionCounts.isNotEmpty;
    final canAddReactions = true; // Could be based on authentication

    if (!hasReactions && !canAddReactions) {
      return SizedBox.shrink();
    }

    return Container(
      margin: widget.margin ?? EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (hasReactions || canAddReactions) ...[
            Row(
              children: [
                Icon(
                  Icons.mood,
                  size: 16,
                  color: Theme.of(context).primaryColor,
                ),
                SizedBox(width: 6),
                Text(
                  'Reactions',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    fontSize: 16,
                  ),
                ),
              ],
            ),
            SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                // Show reactions that have been used (have counts > 0), sorted by count descending
                ...(_reactionCounts.entries
                    .where((entry) => entry.value > 0)
                    .toList()
                    ..sort((a, b) => b.value.compareTo(a.value)))
                    .map((entry) => _buildReactionButton(entry.key))
                    .toList(),
                // Show + button for unused reactions
                if (_getUnusedReactions().isNotEmpty)
                  _buildAddReactionButton(),
              ],
            ),
          ],
        ],
      ),
    );
  }
}