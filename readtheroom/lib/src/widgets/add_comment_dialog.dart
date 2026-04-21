// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:flutter/material.dart';

import '../services/achievement_service.dart';
import '../services/comment_service.dart';
import '../services/congratulations_service.dart';
import '../services/profanity_filter_service.dart';
import '../services/question_rating_service.dart';
import '../services/question_service.dart';
import '../services/user_service.dart';
import '../services/watchlist_service.dart';
import '../utils/review_tag_navigation.dart';
import 'approval_slider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:provider/provider.dart';

enum _CommentDialogStage { ratingSlider, ratingChips, comment }

class AddCommentDialog extends StatefulWidget {
  final String questionId;
  final String questionTitle;
  final Map<String, dynamic>? question;
  final bool isAuthor;
  final Function(Map<String, dynamic>)? onCommentAdded;
  final VoidCallback? onRatingSubmitted;

  const AddCommentDialog({
    Key? key,
    required this.questionId,
    required this.questionTitle,
    this.question,
    this.isAuthor = false,
    this.onCommentAdded,
    this.onRatingSubmitted,
  }) : super(key: key);

  @override
  State<AddCommentDialog> createState() => _AddCommentDialogState();

  /// Static method to show the dialog
  static Future<Map<String, dynamic>?> show({
    required BuildContext context,
    required String questionId,
    required String questionTitle,
    Map<String, dynamic>? question,
    bool isAuthor = false,
    Function(Map<String, dynamic>)? onCommentAdded,
    VoidCallback? onRatingSubmitted,
  }) {
    return showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => AddCommentDialog(
        questionId: questionId,
        questionTitle: questionTitle,
        question: question,
        isAuthor: isAuthor,
        onCommentAdded: onCommentAdded,
        onRatingSubmitted: onRatingSubmitted,
      ),
    );
  }
}

class _AddCommentDialogState extends State<AddCommentDialog> {
  final _formKey = GlobalKey<FormState>();
  final _contentController = TextEditingController();
  final _profanityFilter = ProfanityFilterService();
  bool _isSubmitting = false;
  bool _containsProfanity = false;
  bool _isNSFW = false;
  Timer? _nsfwAutoToggleTimer;
  List<String> _linkedQuestionIds = [];
  Map<String, String> _questionIdToNumberMap = {}; // Maps UUID to [1], [2] etc
  Map<String, Map<String, dynamic>> _questionCache = {}; // Cache question data
  List<Map<String, dynamic>> _questionSearchResults = [];
  bool _isSearchingQuestions = false;
  bool _showQuestionDropdown = false;
  QuestionService? _questionService;

  // Rating-gate state
  _CommentDialogStage _stage = _CommentDialogStage.comment;
  final _ratingService = QuestionRatingService();
  double _ratingValue = 0.0;
  final Set<String> _selectedTags = {};
  bool _isSubmittingRating = false;

  @override
  void initState() {
    super.initState();
    _contentController.addListener(_checkForProfanity);
    _contentController.addListener(_parseLinkedQuestions);
    _contentController.addListener(_handleTextChange);
    _determineInitialStage();
  }

  void _determineInitialStage() {
    final isAuthenticated =
        Supabase.instance.client.auth.currentUser != null;
    if (widget.isAuthor || !isAuthenticated) {
      _stage = _CommentDialogStage.comment;
      return;
    }
    // Read userService without listening — we only need a snapshot at open.
    final userService = Provider.of<UserService>(context, listen: false);
    _stage = userService.hasRatedQuestion(widget.questionId)
        ? _CommentDialogStage.comment
        : _CommentDialogStage.ratingSlider;
  }

  List<String> get _availableChips {
    if (_ratingValue <= -0.3) return ReviewTagNavigation.negativeChips;
    if (_ratingValue > 0.3) return ReviewTagNavigation.positiveChips;
    return [];
  }

  Future<void> _onSliderReleased(double value) async {
    if (_isSubmittingRating) return;
    setState(() {
      _isSubmittingRating = true;
      _ratingValue = value;
    });

    final submitted =
        await _ratingService.submitRating(widget.questionId, _ratingValue);

    if (submitted && mounted) {
      final userService = Provider.of<UserService>(context, listen: false);
      await userService.setQuestionRating(widget.questionId, _ratingValue);
      widget.onRatingSubmitted?.call();
    }

    if (!mounted) return;

    final nextStage = (_ratingValue <= -0.3 || _ratingValue > 0.3)
        ? _CommentDialogStage.ratingChips
        : _CommentDialogStage.comment;

    setState(() {
      _isSubmittingRating = false;
      _stage = nextStage;
    });
  }

  Future<void> _submitTags() async {
    if (_selectedTags.isNotEmpty) {
      await _ratingService.submitReviewTags(
        widget.questionId,
        _selectedTags.toList(),
      );
    }
    if (!mounted) return;
    setState(() => _stage = _CommentDialogStage.comment);
  }

  void _skipTags() {
    setState(() => _stage = _CommentDialogStage.comment);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _questionService ??= Provider.of<QuestionService>(context, listen: false);
  }

  @override
  void dispose() {
    _nsfwAutoToggleTimer?.cancel();
    _contentController.removeListener(_checkForProfanity);
    _contentController.removeListener(_parseLinkedQuestions);
    _contentController.removeListener(_handleTextChange);
    _contentController.dispose();
    super.dispose();
  }

  int _getCommentCount(Map<String, dynamic>? question) {
    return question?['comment_count'] as int? ?? 0;
  }

  void _checkForProfanity() {
    final hasProfanity = _profanityFilter.containsProfanity(_contentController.text);
    if (hasProfanity != _containsProfanity) {
      setState(() {
        _containsProfanity = hasProfanity;
      });
    }

    // Auto-toggle NSFW after 2s of idle typing when profanity is detected
    _nsfwAutoToggleTimer?.cancel();
    if (hasProfanity && !_isNSFW && _shouldShowNSFWOption()) {
      _nsfwAutoToggleTimer = Timer(const Duration(seconds: 2), () {
        if (mounted && _containsProfanity && !_isNSFW) {
          setState(() {
            _isNSFW = true;
          });
          _formKey.currentState?.validate();
        }
      });
    }
  }

  void _parseLinkedQuestions() {
    final text = _contentController.text;
    // Look for both numbered references [1], [2] etc and direct UUIDs during editing
    final numberedRegex = RegExp(r'\[(\d+)\]');
    final uuidRegex = RegExp(r'@([a-f0-9-]{36})', caseSensitive: false);
    
    final numberedMatches = numberedRegex.allMatches(text);
    final uuidMatches = uuidRegex.allMatches(text);
    
    // Extract question IDs from numbered references
    final numberedIds = <String>[];
    for (final match in numberedMatches) {
      final number = match.group(1)!;
      // Find the UUID that corresponds to this number
      for (final entry in _questionIdToNumberMap.entries) {
        if (entry.value == '[$number]') {
          numberedIds.add(entry.key);
          break;
        }
      }
    }
    
    // Extract question IDs from UUIDs (during editing phase)
    final uuidIds = uuidMatches.map((match) => match.group(1)!).toList();
    
    final allLinkedIds = [...numberedIds, ...uuidIds].toSet().toList();
    
    if (!_listEquals(_linkedQuestionIds, allLinkedIds)) {
      setState(() {
        _linkedQuestionIds = allLinkedIds;
        // Auto-mark comment as NSFW if linking to any NSFW questions
        _checkAndMarkNSFWForLinkedQuestions();
      });
    }
  }

  bool _listEquals(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  void _checkAndMarkNSFWForLinkedQuestions() {
    // Check if any of the linked questions are NSFW
    bool hasNSFWLinkedQuestions = false;
    
    for (final questionId in _linkedQuestionIds) {
      final questionData = _questionCache[questionId];
      if (questionData != null && questionData['nsfw'] == true) {
        hasNSFWLinkedQuestions = true;
        break;
      }
    }
    
    // Auto-mark comment as NSFW if linking to NSFW questions
    if (hasNSFWLinkedQuestions && !_isNSFW) {
      _isNSFW = true;
    }
  }

  void _handleTextChange() {
    final text = _contentController.text;
    final cursorPosition = _contentController.selection.baseOffset;
    
    // Check if user is typing after an @ symbol
    final beforeCursor = text.substring(0, cursorPosition);
    final atIndex = beforeCursor.lastIndexOf('@');
    
    if (atIndex >= 0) {
      final afterAt = beforeCursor.substring(atIndex + 1);
      final hasSpaceAfterAt = afterAt.contains(' ');
      
      if (!hasSpaceAfterAt) {
        if (afterAt.length >= 3) {
          // User is typing a question search query
          _searchQuestions(afterAt);
          return;
        } else {
          // Show search hint for first 1-2 characters
          setState(() {
            _showQuestionDropdown = true;
            _questionSearchResults = [];
            _isSearchingQuestions = false;
          });
          return;
        }
      }
    }
    
    // Hide dropdown if no @ or if there's a space after @
    if (_showQuestionDropdown) {
      setState(() {
        _showQuestionDropdown = false;
        _questionSearchResults = [];
      });
    }
  }

  Future<void> _searchQuestions(String query) async {
    if (query.length < 3) {
      setState(() {
        _showQuestionDropdown = false;
        _questionSearchResults = [];
      });
      return;
    }

    setState(() {
      _isSearchingQuestions = true;
      _showQuestionDropdown = true;
    });

    try {
      final questionIsNSFW = widget.question?['nsfw'] == true;
      final shouldIncludeNSFW = _isNSFW || questionIsNSFW; // Include NSFW questions when comment is marked as NSFW OR when current question is NSFW
      
      final results = await _questionService!.searchQuestionsForAutocomplete(
        query, 
        limit: 5,
        includeNSFW: shouldIncludeNSFW,
        excludePrivate: true, // Never show private questions in comment tagging autocomplete
      );
      if (mounted) {
        setState(() {
          _questionSearchResults = results;
          _isSearchingQuestions = false;
        });
      }
    } catch (e) {
      print('Error searching questions: $e');
      if (mounted) {
        setState(() {
          _questionSearchResults = [];
          _isSearchingQuestions = false;
          _showQuestionDropdown = false;
        });
      }
    }
  }

  void _selectQuestion(Map<String, dynamic> question) {
    final text = _contentController.text;
    final cursorPosition = _contentController.selection.baseOffset;
    final beforeCursor = text.substring(0, cursorPosition);
    final atIndex = beforeCursor.lastIndexOf('@');
    
    if (atIndex >= 0) {
      final afterCursor = text.substring(cursorPosition);
      final questionId = question['id'].toString();
      final questionTitle = question['prompt'].toString();
      
      // Cache the question data
      _questionCache[questionId] = question;
      
      // Assign a number if this is a new question
      if (!_questionIdToNumberMap.containsKey(questionId)) {
        final nextNumber = _questionIdToNumberMap.length + 1;
        _questionIdToNumberMap[questionId] = '[$nextNumber]';
      }
      
      final numberRef = _questionIdToNumberMap[questionId]!;
      
      // Replace @query with numbered reference
      final newText = text.substring(0, atIndex) + numberRef + afterCursor;
      final newCursorPosition = atIndex + numberRef.length;
      
      _contentController.text = newText;
      _contentController.selection = TextSelection.collapsed(offset: newCursorPosition);
      
      setState(() {
        _showQuestionDropdown = false;
        _questionSearchResults = [];
      });
      
      // Manually trigger parsing to update linked questions
      _parseLinkedQuestions();
      
      // Show feedback to user
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Linked question $numberRef: ${questionTitle.length > 50 ? questionTitle.substring(0, 50) + '...' : questionTitle}'),
          duration: Duration(seconds: 2),
          backgroundColor: Theme.of(context).primaryColor,
        ),
      );
    }
  }

  String _getHintText() {
    final questionIsNSFW = widget.question?['nsfw'] == true;
    
    if (questionIsNSFW) {
      return 'What are your thoughts?';
    } else {
      return 'What are your thoughts?';
    }
  }

  Future<void> _submitComment() async {
    print('Submit comment called');
    final isValid = _formKey.currentState!.validate();
    print('Form validation result: $isValid');
    if (!isValid || _isSubmitting) {
      print('Validation failed or already submitting. isValid: $isValid, _isSubmitting: $_isSubmitting');
      return;
    }

    final currentUser = Supabase.instance.client.auth.currentUser;
    if (currentUser == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('You must be logged in to add comments'),
            backgroundColor: Colors.orange,
          ),
        );
      }
      return;
    }

    if (!mounted) return;
    
    setState(() {
      _isSubmitting = true;
    });

    // Store the context and navigator to avoid accessing them after dispose
    final dialogContext = context;
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final theme = Theme.of(context);

    try {
      final commentService = CommentService();
      final watchlistService = Provider.of<WatchlistService>(dialogContext, listen: false);
      
      // Add the comment
      final newComment = await commentService.addComment(
        questionId: widget.questionId,
        content: _contentController.text.trim(),
        linkedQuestionIds: _linkedQuestionIds.isEmpty ? null : _linkedQuestionIds,
        isNSFW: _isNSFW,
      );

      // Check if user is already subscribed to this question
      final isAlreadySubscribed = await watchlistService.isWatching(widget.questionId);
      
      String snackbarMessage = 'Nice comment!';
      
      // If not already subscribed, subscribe them to the question
      if (!isAlreadySubscribed) {
        // Get current vote count and comment count for the subscription
        final currentVoteCount = widget.question?['vote_count'] as int? ?? 0;
        final currentCommentCount = _getCommentCount(widget.question);
        
        // Subscribe the user to the question
        await watchlistService.subscribeToQuestion(widget.questionId, currentVoteCount, currentCommentCount);
        snackbarMessage = 'Nice comment! Subscribed to question.';
      }

      // Call the callback before closing dialog to avoid context issues
      if (widget.onCommentAdded != null) {
        widget.onCommentAdded!(newComment);
      }

      // Check for first comment congratulations
      try {
        final userService = Provider.of<UserService>(dialogContext, listen: false);
        final achievementService = AchievementService(
          userService: userService,
          context: dialogContext,
        );
        await achievementService.init();
        final congratulationsService = CongratulationsService(
          userService: userService,
          achievementService: achievementService,
        );
        await congratulationsService.init();
        await congratulationsService.showCongratulationsIfEligible(
          dialogContext,
          AchievementType.firstComment,
        );
      } catch (e) {
        print('Error showing congratulations for first comment: $e');
      }

      print('About to close dialog');
      // Close the dialog first
      navigator.pop(newComment);

      // Show success message after dialog is closed
      messenger.showSnackBar(
        SnackBar(
          content: Row(
            children: [
              Icon(Icons.check_circle, color: Colors.white, size: 20),
              SizedBox(width: 8),
              Expanded(child: Text(snackbarMessage)),
            ],
          ),
          backgroundColor: theme.primaryColor,
          duration: Duration(seconds: 3),
        ),
      );

    } catch (e) {
      print('Error adding comment: $e');
      if (mounted) {
        setState(() {
          _isSubmitting = false;
        });
        
        messenger.showSnackBar(
          SnackBar(
            content: Text('Failed to add comment: ${e.toString()}'),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 4),
          ),
        );
      }
    }
  }

  Widget _buildStageContent(BuildContext context) {
    switch (_stage) {
      case _CommentDialogStage.ratingSlider:
        return _buildRatingSliderStage(context);
      case _CommentDialogStage.ratingChips:
        return _buildRatingChipsStage(context);
      case _CommentDialogStage.comment:
        return _buildCommentStage(context);
    }
  }

  Widget _buildRatingSliderStage(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text(
          'Before commenting, thoughts on the question itself?',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Colors.grey[600],
              ),
          textAlign: TextAlign.center,
        ),
        SizedBox(height: 20),
        Text(
          'How would you rate this question?',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: const [
            Icon(Icons.thumb_down, color: Colors.red),
            Icon(Icons.thumb_up, color: Colors.green),
          ],
        ),
        const SizedBox(height: 4),
        ApprovalSlider(
          initialValue: 0.0,
          onChanged: (value) {
            _ratingValue = value;
          },
          onChangeEnd: _isSubmittingRating ? (_) {} : _onSliderReleased,
        ),
        if (_isSubmittingRating) ...[
          const SizedBox(height: 16),
          const SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ],
      ],
    );
  }

  Widget _buildRatingChipsStage(BuildContext context) {
    final chips = _availableChips;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'What stood out?',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 4),
        Text(
          'Optional — pick any that fit.',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Colors.grey[600],
              ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: chips.map((tag) {
            final selected = _selectedTags.contains(tag);
            return FilterChip(
              label: Text(ReviewTagNavigation.chipLabels[tag] ?? tag),
              selected: selected,
              showCheckmark: false,
              onSelected: (val) {
                setState(() {
                  if (val) {
                    _selectedTags.add(tag);
                  } else {
                    _selectedTags.remove(tag);
                  }
                });
              },
            );
          }).toList(),
        ),
        const SizedBox(height: 20),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            TextButton(
              onPressed: _skipTags,
              child: const Text('Skip'),
            ),
            ElevatedButton(
              onPressed: _submitTags,
              style: ElevatedButton.styleFrom(
                backgroundColor: Theme.of(context).primaryColor,
                foregroundColor: Colors.white,
              ),
              child: const Text('Continue'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildCommentStage(BuildContext context) {
    return Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(
            'Please be respectful, thoughtful, and kind in your comments \u{1F98E}',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Colors.grey[600],
                ),
            textAlign: TextAlign.center,
          ),
          SizedBox(height: 24),
          Column(
            children: [
              if (_showQuestionDropdown) _buildQuestionDropdown(),
              _buildContentField(),
            ],
          ),
          _buildLinkedQuestionsPreview(),
          if (_shouldShowNSFWOption()) _buildNSFWOption(),
          SizedBox(height: 24),
          Align(
            alignment: Alignment.centerRight,
            child: ElevatedButton(
              onPressed: _isSubmitting ? null : _submitComment,
              style: ElevatedButton.styleFrom(
                backgroundColor: Theme.of(context).primaryColor,
                foregroundColor: Colors.white,
                padding:
                    EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              ),
              child: _isSubmitting
                  ? SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor:
                            AlwaysStoppedAnimation<Color>(Colors.white),
                      ),
                    )
                  : Text('Post comment'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContentField() {
    final isNSFWContext = _isNSFW || widget.question?['nsfw'] == true;
    return TextFormField(
      controller: _contentController,
      maxLines: 5,
      maxLength: 500,
      textCapitalization: TextCapitalization.sentences,
      decoration: InputDecoration(
        hintText: _getHintText(),
        border: OutlineInputBorder(),
        focusedBorder: OutlineInputBorder(
          borderSide: BorderSide(
            color: (_containsProfanity && !isNSFWContext)
                ? Colors.red
                : Theme.of(context).primaryColor,
          ),
        ),
        errorBorder: OutlineInputBorder(
          borderSide: BorderSide(color: Colors.red),
        ),
        counterStyle: TextStyle(
          color: (_containsProfanity && !isNSFWContext) ? Colors.red : null,
        ),
      ),
      validator: (value) {
        if (value == null || value.trim().isEmpty) {
          return 'Please enter a comment';
        }
        if (value.trim().length < 3) {
          return 'Comment must be at least 3 characters long';
        }
        final questionIsNSFW = widget.question?['nsfw'] == true;
        if (_containsProfanity && !_isNSFW && !questionIsNSFW) {
          return 'Please remove inappropriate language';
        }
        return null;
      },
    );
  }

  Widget _buildQuestionDropdown() {
    return Container(
      margin: EdgeInsets.only(top: 4),
      constraints: BoxConstraints(maxHeight: 150), // Reduced height
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: Theme.of(context).primaryColor.withOpacity(0.3),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.2),
            blurRadius: 12,
            offset: Offset(0, -4), // Shadow above instead of below
          ),
        ],
      ),
      child: _isSearchingQuestions
          ? Container(
              padding: EdgeInsets.all(16),
              child: Row(
                children: [
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(width: 8),
                  Text('Searching questions...'),
                ],
              ),
            )
          : _questionSearchResults.isEmpty
              ? _buildSearchHint()
              : ListView.builder(
                  shrinkWrap: true,
                  itemCount: _questionSearchResults.length,
                  itemBuilder: (context, index) {
                    final question = _questionSearchResults[index];
                    final prompt = question['prompt'].toString();
                    final questionType = question['type'].toString();
                    final voteCount = question['vote_count'] as int? ?? 0;
                    final isNSFW = question['nsfw'] == true;

                    IconData typeIcon;
                    switch (questionType) {
                      case 'approval_rating':
                        typeIcon = Icons.thumbs_up_down;
                        break;
                      case 'multiple_choice':
                        typeIcon = Icons.check_box;
                        break;
                      case 'text':
                        typeIcon = Icons.text_fields;
                        break;
                      default:
                        typeIcon = Icons.help_outline;
                    }

                    return InkWell(
                      onTap: () => _selectQuestion(question),
                      child: Container(
                        padding: EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          border: Border(
                            bottom: BorderSide(
                              color: Theme.of(context).dividerColor.withOpacity(0.3),
                              width: index < _questionSearchResults.length - 1 ? 0.5 : 0,
                            ),
                          ),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              typeIcon,
                              size: 16,
                              color: Theme.of(context).primaryColor,
                            ),
                            SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    prompt,
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w500,
                                    ),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  SizedBox(height: 2),
                                  Row(
                                    children: [
                                      if (voteCount > 0) ...[
                                        Text(
                                          '$voteCount ${voteCount == 1 ? 'vote' : 'votes'}',
                                          style: TextStyle(
                                            fontSize: 12,
                                            color: Colors.grey[600],
                                          ),
                                        ),
                                        if (isNSFW) SizedBox(width: 8),
                                      ],
                                      if (isNSFW) ...[
                                        Container(
                                          padding: EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                                          decoration: BoxDecoration(
                                            color: Colors.red.withOpacity(0.1),
                                            borderRadius: BorderRadius.circular(3),
                                            border: Border.all(color: Colors.red.withOpacity(0.3), width: 0.5),
                                          ),
                                          child: Text(
                                            'NSFW',
                                            style: TextStyle(
                                              fontSize: 10,
                                              fontWeight: FontWeight.bold,
                                              color: Colors.red[700],
                                            ),
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
    );
  }

  Widget _buildSearchHint() {
    final text = _contentController.text;
    final cursorPosition = _contentController.selection.baseOffset;
    final beforeCursor = text.substring(0, cursorPosition);
    final atIndex = beforeCursor.lastIndexOf('@');
    
    if (atIndex >= 0) {
      final afterAt = beforeCursor.substring(atIndex + 1);
      final remainingChars = 3 - afterAt.length;
      
      if (remainingChars > 0) {
        return Container(
          padding: EdgeInsets.all(16),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.edit, size: 32, color: Colors.orange),
              SizedBox(height: 8),
              Text(
                'Type $remainingChars more character${remainingChars > 1 ? 's' : ''}...',
                style: TextStyle(
                  fontSize: 14,
                  color: Colors.grey[600],
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        );
      }
    }
    
    return Container(
      padding: EdgeInsets.all(16),
      child: Text(
        'No questions found',
        style: TextStyle(color: Colors.grey[600]),
      ),
    );
  }

  Widget _buildLinkedQuestionsPreview() {
    if (_linkedQuestionIds.isEmpty) return SizedBox.shrink();

    return Container(
      margin: EdgeInsets.only(top: 8),
      padding: EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).primaryColor.withOpacity(0.05),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: Theme.of(context).primaryColor.withOpacity(0.3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.link,
                size: 16,
                color: Theme.of(context).primaryColor,
              ),
              SizedBox(width: 4),
              Text(
                'Referenced Questions (${_linkedQuestionIds.length})',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: Theme.of(context).primaryColor,
                ),
              ),
            ],
          ),
          SizedBox(height: 8),
          ...(_linkedQuestionIds.map((questionId) {
            final numberRef = _questionIdToNumberMap[questionId] ?? '[?]';
            final questionData = _questionCache[questionId];
            final questionTitle = questionData?['prompt']?.toString() ?? 'Unknown question';
            
            return Padding(
              padding: EdgeInsets.only(bottom: 4),
              child: Row(
                children: [
                  Text(
                    numberRef,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: Theme.of(context).primaryColor,
                    ),
                  ),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      questionTitle.length > 40 ? questionTitle.substring(0, 40) + '...' : questionTitle,
                      style: TextStyle(
                        fontSize: 11,
                        color: Colors.grey[600],
                      ),
                    ),
                  ),
                ],
              ),
            );
          })),
        ],
      ),
    );
  }

  bool _shouldShowNSFWOption() {
    final userService = Provider.of<UserService>(context, listen: false);
    final questionIsNSFW = widget.question?['nsfw'] == true;
    final userHasNSFWEnabled = userService.showNSFWContent;
    
    // Only show if user has NSFW enabled AND question is not already NSFW
    return userHasNSFWEnabled && !questionIsNSFW;
  }

  Widget _buildNSFWOption() {
    return Row(
      children: [
        Checkbox(
          value: _isNSFW,
          onChanged: (value) {
            setState(() {
              _isNSFW = value ?? false;
            });
          },
          activeColor: Theme.of(context).primaryColor,
        ),
        Expanded(
          child: GestureDetector(
            onTap: () {
              setState(() {
                _isNSFW = !_isNSFW;
              });
            },
            child: Text(
              'Mark as NSFW/18+',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
      ),
      child: Container(
        constraints: BoxConstraints(
          maxWidth: 500,
          maxHeight: MediaQuery.of(context).size.height * 0.8,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header
            Container(
              padding: EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Theme.of(context).primaryColor.withOpacity(0.05),
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(16),
                  topRight: Radius.circular(16),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.add_comment,
                    color: Theme.of(context).primaryColor,
                  ),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      widget.questionTitle,
                      style: Theme.of(context).textTheme.bodyMedium,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: Icon(Icons.close),
                    style: IconButton.styleFrom(
                      foregroundColor: Colors.grey[600],
                    ),
                  ),
                ],
              ),
            ),

            // Content
            Flexible(
              child: SingleChildScrollView(
                padding: EdgeInsets.all(16),
                child: _buildStageContent(context),
              ),
            ),
          ],
        ),
      ),
    );
  }
}