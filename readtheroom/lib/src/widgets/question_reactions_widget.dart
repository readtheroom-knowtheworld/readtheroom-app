// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'dart:math';
import '../services/analytics_service.dart';
import '../services/question_reactions_service.dart';
import '../utils/reaction_logic.dart';
import 'emoji_picker_sheet.dart';

class QuestionReactionsWidget extends StatefulWidget {
  final String questionId;
  final Map<String, int>? initialReactions;
  final Set<String>? userReactions;
  final Function(String reaction, bool isAdding)? onReactionTap;
  final bool useDummyData;
  final EdgeInsetsGeometry? margin;

  /// Compact mode (WP-D): no "Reactions" header, at most [compactLimit]
  /// reactions, and nothing rendered while loading — for the home hero's
  /// answered card, where the control is a footnote rather than a section.
  final bool compact;

  /// How many reactions compact mode shows (highest count first).
  final int compactLimit;

  const QuestionReactionsWidget({
    Key? key,
    required this.questionId,
    this.initialReactions,
    this.userReactions,
    this.onReactionTap,
    this.useDummyData = false,
    this.margin,
    this.compact = false,
    this.compactLimit = 3,
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

  /// One-tap chips at the top of the picker — the pre-WP-D fixed set, kept as a
  /// shortcut now that the sheet offers the whole emoji keyboard.
  static const List<String> _quickReactions =
      QuestionReactionsService.quickReactions;

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
    for (final reaction in _quickReactions) {
      // 60% chance of having this reaction, with 0-25 count
      if (random.nextDouble() > 0.4) {
        _reactionCounts[reaction] = random.nextInt(26);
      }
    }
    
    // User has reacted to 20% of available reactions
    for (final reaction in _quickReactions) {
      if (random.nextDouble() > 0.8 && _reactionCounts.containsKey(reaction)) {
        _userReactions.add(reaction);
      }
    }
  }

  /// [emojiSource] records which control produced the tap for analytics:
  /// `chip` (an existing reaction chip) or, from the sheet, `quick` / `picker`.
  Future<void> _handleReactionTap(String reaction,
      {String emojiSource = 'chip'}) async {
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

      // Server accepted it, so this is a real reaction (the optimistic update
      // above can still be rolled back below).
      AnalyticsService().trackReaction(
        added: isAdding,
        emojiSource: emojiSource,
        questionId: widget.questionId,
      );

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

  /// Glyph box shared by the reaction chips and the add chip, so every chip in
  /// the row is the same height whatever is inside it (an emoji's line box is
  /// taller than an 18pt icon's).
  static const double _chipGlyphHeight = 20;

  Widget _buildAddReactionButton() {
    return GestureDetector(
      onTap: _showReactionPicker,
      child: Container(
        // Same padding, radius and border as a count-less reaction chip.
        padding: EdgeInsets.symmetric(horizontal: 6, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: Colors.grey.withOpacity(0.3),
            width: 1,
          ),
        ),
        child: SizedBox(
          height: _chipGlyphHeight,
          child: Center(
            widthFactor: 1,
            child: Icon(
              Icons.add_reaction_outlined,
              size: 18,
              color: Colors.grey[600],
            ),
          ),
        ),
      ),
    );
  }

  /// Reaction picker: the five original emoji as one-tap chips, then the full
  /// emoji keyboard (WP-D / decision D8 — any emoji, not a fixed set).
  ///
  /// The sheet itself lives in [EmojiPickerSheet] so the chat overlay's
  /// reactions (WP-F) reuse the same control instead of a second copy that can
  /// drift. Behaviour here is unchanged: pick, validate, apply.
  Future<void> _showReactionPicker() async {
    final emoji = await EmojiPickerSheet.show(
      context: context,
      highlighted: _userReactions,
      quickPicks: _quickReactions,
      onRejected: (_) => _showRejectedEmoji(),
    );
    if (emoji == null || !mounted) return;
    // The sheet returns only the emoji, so "was it a quick pick" is read back
    // off the quick list rather than threading a second return value through.
    _handleReactionTap(emoji,
        emojiSource: _quickReactions.contains(emoji) ? 'quick' : 'picker');
  }

  void _showRejectedEmoji() {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text(
          'That one can\'t be used as a reaction.',
          style: TextStyle(color: Colors.white),
        ),
        backgroundColor: Theme.of(context).primaryColor,
        duration: const Duration(seconds: 2),
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
            SizedBox(
              height: _chipGlyphHeight,
              child: Center(
                widthFactor: 1,
                child: Text(
                  reaction,
                  style: TextStyle(fontSize: 16, height: 1.0),
                ),
              ),
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
    if (_isLoading) {
      // Compact mode stays silent until the counts land — a spinner in the
      // hero's answered card reads as a broken section.
      if (widget.compact) return SizedBox.shrink();
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

    // Highest count first; compact mode caps the row and always keeps the
    // user's own reaction visible (see utils/reaction_logic.dart).
    final shown = widget.compact
        ? topReactions(
            _reactionCounts,
            limit: widget.compactLimit,
            alwaysInclude: _userReactions,
          )
        : topReactions(_reactionCounts, limit: _reactionCounts.length + 1);

    final chips = <Widget>[
      ...shown.map((tally) => _buildReactionButton(tally.emoji)),
      // The picker offers every emoji now, so the add affordance is always up.
      _buildAddReactionButton(),
    ];

    if (widget.compact) {
      return Container(
        margin: widget.margin ?? EdgeInsets.zero,
        // Right-aligned (2026-09-19): the row hugs the right edge and the add
        // button, last in the list, lands in the thumb-side corner.
        child: Wrap(
          alignment: WrapAlignment.end,
          spacing: 6,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: chips,
        ),
      );
    }

    return Container(
      margin: widget.margin ?? EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
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
          SizedBox(
            width: double.infinity,
            child: Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 6,
              children: chips,
            ),
          ),
        ],
      ),
    );
  }
}
