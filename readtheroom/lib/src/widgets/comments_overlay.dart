// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/achievement_service.dart';
import '../services/comment_service.dart';
import '../services/congratulations_service.dart';
import '../services/lizzy_vote_service.dart';
import '../services/post_answer_prompts.dart';
import '../services/profanity_filter_service.dart';
import '../services/question_service.dart';
import '../services/user_service.dart';
import '../services/watchlist_service.dart';
import 'comment_widget.dart';
import 'package:url_launcher/url_launcher.dart';


class CommentsOverlay {
  static Future<void> show({
    required BuildContext context,
    required String questionId,
    required String questionTitle,
    Map<String, dynamic>? question,
    bool isAuthor = false,
    List<Map<String, dynamic>>? initialComments,
    Function(Map<String, dynamic>)? onCommentAdded,
    VoidCallback? onRatingSubmitted,
    bool focusInput = false,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      isDismissible: true,
      enableDrag: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (context) => _CommentsOverlaySheet(
        questionId: questionId,
        questionTitle: questionTitle,
        question: question,
        isAuthor: isAuthor,
        initialComments: initialComments,
        onCommentAdded: onCommentAdded,
        onRatingSubmitted: onRatingSubmitted,
        focusInput: focusInput,
      ),
    );
  }
}

class _CommentsOverlaySheet extends StatefulWidget {
  final String questionId;
  final String questionTitle;
  final Map<String, dynamic>? question;
  final bool isAuthor;
  final List<Map<String, dynamic>>? initialComments;
  final Function(Map<String, dynamic>)? onCommentAdded;
  final VoidCallback? onRatingSubmitted;
  final bool focusInput;

  const _CommentsOverlaySheet({
    required this.questionId,
    required this.questionTitle,
    this.question,
    this.isAuthor = false,
    this.initialComments,
    this.onCommentAdded,
    this.onRatingSubmitted,
    this.focusInput = false,
  });

  @override
  State<_CommentsOverlaySheet> createState() => _CommentsOverlaySheetState();
}

class _CommentsOverlaySheetState extends State<_CommentsOverlaySheet> {
  // Comment list state
  List<Map<String, dynamic>> _comments = [];
  bool _isLoading = false;
  bool _hasMoreComments = false;
  int _currentPage = 0;
  final int _commentsPerPage = 20;
  Set<String> _expandedCommentIds = {};
  String _sortBy = 'chrono';
  final LizzyVoteService _lizzyVoteService = LizzyVoteService();
  final ScrollController _scrollController = ScrollController();

  // Comment input state
  final _formKey = GlobalKey<FormState>();
  final _contentController = TextEditingController();
  final _inputFocusNode = FocusNode();
  final _profanityFilter = ProfanityFilterService();
  bool _isSubmitting = false;
  bool _containsProfanity = false;
  bool _isNSFW = false;
  Timer? _nsfwAutoToggleTimer;

  // ?: question tagging state
  List<String> _linkedQuestionIds = [];
  Map<String, String> _questionIdToNumberMap = {};
  Map<String, Map<String, dynamic>> _questionCache = {};
  List<Map<String, dynamic>> _questionSearchResults = [];
  bool _isSearchingQuestions = false;
  bool _showQuestionDropdown = false;
  QuestionService? _questionService;

  // @ chameleon tagging state
  List<String> _taggedUsernames = [];
  List<String> _availableUsernames = [];
  bool _showUsernameDropdown = false;

  // Rating gate state
  bool _inputExpanded = false;

  @override
  void initState() {
    super.initState();
    _initializeLizzyService();
    _contentController.addListener(_checkForProfanity);
    _contentController.addListener(_parseLinkedQuestions);
    _contentController.addListener(_handleTextChange);
    _inputFocusNode.addListener(_onInputFocusChange);

    if (widget.initialComments != null) {
      _comments = List<Map<String, dynamic>>.from(widget.initialComments!);
      _sortComments();
      _hasMoreComments = _comments.length >= _commentsPerPage;
      _extractAvailableUsernames();
    } else {
      _loadComments();
    }

    // Don't auto-focus — let the user tap the input box to open the keyboard
  }


  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _questionService ??= Provider.of<QuestionService>(context, listen: false);
  }

  void _onInputFocusChange() {
    if (_inputFocusNode.hasFocus && !_inputExpanded) {
      setState(() => _inputExpanded = true);
    }
  }

  @override
  void dispose() {
    _nsfwAutoToggleTimer?.cancel();
    _contentController.removeListener(_checkForProfanity);
    _contentController.removeListener(_parseLinkedQuestions);
    _contentController.removeListener(_handleTextChange);
    _inputFocusNode.removeListener(_onInputFocusChange);
    _contentController.dispose();
    _inputFocusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  // ─── Comment list logic (ported from CommentsSection) ───

  Future<void> _initializeLizzyService() async {
    await _lizzyVoteService.init();
    if (mounted) {
      setState(() => _updateCommentsWithLizzyStates());
    }
  }

  Future<void> _loadComments({bool loadMore = false}) async {
    if (_isLoading) return;
    setState(() => _isLoading = true);

    try {
      final commentService = CommentService();
      final page = loadMore ? _currentPage + 1 : 0;

      final newComments = await commentService.getCommentsForQuestion(
        widget.questionId,
        page: page,
        limit: _commentsPerPage,
      );

      if (mounted) {
        setState(() {
          if (loadMore) {
            _comments.addAll(newComments);
            _currentPage = page;
          } else {
            _comments = newComments;
            _currentPage = 0;
          }
          _sortComments();
          _updateCommentsWithLizzyStates();
          _hasMoreComments = newComments.length >= _commentsPerPage;
          _isLoading = false;
        });
        _extractAvailableUsernames();
      }
    } catch (e) {
      print('Error loading comments: $e');
      if (mounted) {
        setState(() => _isLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to load comments. Please try again.'),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 3),
          ),
        );
      }
    }
  }

  void _updateCommentsWithLizzyStates() {
    for (final comment in _comments) {
      final commentId = comment['id']?.toString();
      if (commentId != null) {
        final dbState = comment['user_has_upvoted'] as bool? ?? false;
        final localState = _lizzyVoteService.hasUserLizzied(commentId);
        if (dbState != localState) {
          if (dbState) {
            _lizzyVoteService.addLizzy(commentId);
          } else {
            _lizzyVoteService.removeLizzy(commentId);
          }
        }
        comment['user_has_upvoted'] = dbState;
      }
    }
  }

  String? get _currentUserUsername {
    final currentUserId = Supabase.instance.client.auth.currentUser?.id;
    if (currentUserId == null) return null;
    for (final comment in _comments) {
      if (comment['author_id']?.toString() == currentUserId) {
        return comment['randomized_username']?.toString();
      }
    }
    return null;
  }

  void _extractAvailableUsernames() {
    final usernames = <String>{};
    for (final comment in _comments) {
      final username = comment['randomized_username']?.toString();
      if (username != null && username.isNotEmpty) {
        usernames.add(username);
      }
    }
    _availableUsernames = usernames.toList()..sort();
  }

  List<Map<String, dynamic>> get _visibleComments {
    return _comments.where((comment) {
      final isHidden = comment['is_hidden'] as bool? ?? false;
      return !isHidden;
    }).toList();
  }

  void _sortComments() {
    if (_sortBy == 'top') {
      _comments.sort((a, b) =>
          (b['upvote_lizard_count'] as int? ?? 0)
              .compareTo(a['upvote_lizard_count'] as int? ?? 0));
    } else {
      _comments.sort((a, b) {
        try {
          final aTime = DateTime.parse(a['created_at']?.toString() ?? '');
          final bTime = DateTime.parse(b['created_at']?.toString() ?? '');
          return aTime.compareTo(bTime);
        } catch (e) {
          return 0;
        }
      });
    }
  }

  void _toggleSort() {
    setState(() {
      _sortBy = _sortBy == 'top' ? 'chrono' : 'top';
      _sortComments();
    });
  }

  void _toggleCommentExpanded(String commentId) {
    setState(() {
      if (_expandedCommentIds.contains(commentId)) {
        _expandedCommentIds.remove(commentId);
      } else {
        _expandedCommentIds.add(commentId);
      }
    });
  }

  Future<void> _handleUpvoteLizard(String commentId) async {
    try {
      final commentService = CommentService();
      final commentIndex =
          _comments.indexWhere((c) => c['id']?.toString() == commentId);
      if (commentIndex == -1) return;

      final currentUserId = Supabase.instance.client.auth.currentUser?.id;
      final commentAuthorId = _comments[commentIndex]['author_id']?.toString();

      if (currentUserId != null && currentUserId == commentAuthorId) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('You can\'t lizzy your own comment \u{1F98E}'),
              backgroundColor: Colors.orange,
              duration: Duration(seconds: 2),
            ),
          );
        }
        return;
      }

      final currentState =
          _comments[commentIndex]['user_has_upvoted'] as bool? ?? false;

      if (!currentState) {
        await commentService.addUpvoteLizard(commentId);
      } else {
        await commentService.removeUpvoteLizard(commentId);
      }

      final newState = !currentState;
      if (newState) {
        await _lizzyVoteService.addLizzy(commentId);
      } else {
        await _lizzyVoteService.removeLizzy(commentId);
      }

      if (mounted) {
        setState(() {
          _comments[commentIndex]['user_has_upvoted'] = newState;
          final currentCount =
              _comments[commentIndex]['upvote_lizard_count'] as int? ?? 0;
          _comments[commentIndex]['upvote_lizard_count'] =
              newState ? currentCount + 1 : (currentCount - 1).clamp(0, 999999);
        });
      }
    } catch (e) {
      print('Error handling lizzy vote: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to lizzy comment. Please try again.'),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 2),
          ),
        );
      }
    }
  }

  Future<void> _handleReportComment(String commentId) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Report Comment'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Are you sure you want to report this comment?'),
            SizedBox(height: 8),
            RichText(
              text: TextSpan(
                style: DefaultTextStyle.of(context).style,
                children: [
                  TextSpan(text: 'Does it violate our '),
                  WidgetSpan(
                    child: GestureDetector(
                      onTap: () async {
                        final url = Uri.parse(
                            'https://readtheroom.site/about/#community-guidelines');
                        if (await canLaunchUrl(url)) {
                          await launchUrl(url,
                              mode: LaunchMode.externalApplication);
                        }
                      },
                      child: Text(
                        'community guidelines',
                        style: TextStyle(
                          color: Theme.of(context).primaryColor,
                        ),
                      ),
                    ),
                  ),
                  TextSpan(text: '?'),
                ],
              ),
            ),
          ],
        ),
        actions: [
          Center(
            child: TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              style: TextButton.styleFrom(
                foregroundColor: Colors.white,
                backgroundColor: Colors.orange,
                padding: EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              ),
              child: Text('Submit Report'),
            ),
          ),
        ],
      ),
    );

    if (result == true) {
      try {
        final commentService = CommentService();
        await commentService.reportComment(commentId, ['inappropriate_content']);
        if (mounted) {
          setState(() {
            _comments
                .removeWhere((c) => c['id']?.toString() == commentId);
          });
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                  'Comment reported. Thank you for helping keep our community safe.'),
              backgroundColor: Theme.of(context).primaryColor,
              duration: Duration(seconds: 3),
            ),
          );
        }
      } catch (e) {
        print('Error reporting comment: $e');
        if (mounted) {
          if (e
              .toString()
              .contains('duplicate key value violates unique constraint')) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('You have already reported this comment.'),
                backgroundColor: Colors.orange,
                duration: Duration(seconds: 3),
              ),
            );
          } else {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Failed to report comment. Please try again.'),
                backgroundColor: Colors.red,
                duration: Duration(seconds: 3),
              ),
            );
          }
        }
      }
    }
  }

  Future<void> _handleDeleteComment(String commentId) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete Comment'),
        content: Text(
            'Are you sure you want to delete this comment? This action cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: Text('Delete'),
          ),
        ],
      ),
    );

    if (result == true) {
      try {
        final commentService = CommentService();
        await commentService.deleteComment(commentId);
        if (mounted) {
          setState(() {
            _comments
                .removeWhere((c) => c['id']?.toString() == commentId);
          });
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Comment deleted successfully.'),
              backgroundColor: Theme.of(context).primaryColor,
              duration: Duration(seconds: 2),
            ),
          );
        }
      } catch (e) {
        print('Error deleting comment: $e');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Failed to delete comment. Please try again.'),
              backgroundColor: Colors.red,
              duration: Duration(seconds: 3),
            ),
          );
        }
      }
    }
  }


  // ─── Comment input logic ───

  void _checkForProfanity() {
    final hasProfanity =
        _profanityFilter.containsProfanity(_contentController.text);
    if (hasProfanity != _containsProfanity) {
      setState(() => _containsProfanity = hasProfanity);
    }

    _nsfwAutoToggleTimer?.cancel();
    if (hasProfanity && !_isNSFW && _shouldShowNSFWOption()) {
      _nsfwAutoToggleTimer = Timer(const Duration(seconds: 2), () {
        if (mounted && _containsProfanity && !_isNSFW) {
          setState(() => _isNSFW = true);
          _formKey.currentState?.validate();
        }
      });
    }
  }

  bool _shouldShowNSFWOption() {
    final userService = Provider.of<UserService>(context, listen: false);
    final questionIsNSFW = widget.question?['nsfw'] == true;
    return userService.showNSFWContent && !questionIsNSFW;
  }

  // ─── ?: question tagging logic ───

  void _parseLinkedQuestions() {
    final text = _contentController.text;
    final numberedRegex = RegExp(r'\[(\d+)\]');
    final uuidRegex = RegExp(r'\?:([a-f0-9-]{36})', caseSensitive: false);

    final numberedIds = <String>[];
    for (final match in numberedRegex.allMatches(text)) {
      final number = match.group(1)!;
      for (final entry in _questionIdToNumberMap.entries) {
        if (entry.value == '[$number]') {
          numberedIds.add(entry.key);
          break;
        }
      }
    }

    final uuidIds =
        uuidRegex.allMatches(text).map((m) => m.group(1)!).toList();
    final allLinkedIds = [...numberedIds, ...uuidIds].toSet().toList();

    if (!_listEquals(_linkedQuestionIds, allLinkedIds)) {
      setState(() {
        _linkedQuestionIds = allLinkedIds;
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
    for (final questionId in _linkedQuestionIds) {
      final questionData = _questionCache[questionId];
      if (questionData != null && questionData['nsfw'] == true) {
        if (!_isNSFW) _isNSFW = true;
        return;
      }
    }
  }

  // ─── @ chameleon tagging + ?: question tagging text handler ───

  void _handleTextChange() {
    final text = _contentController.text;
    final cursorPosition = _contentController.selection.baseOffset;
    if (cursorPosition < 0 || cursorPosition > text.length) return;

    final beforeCursor = text.substring(0, cursorPosition);

    // Check for ?: question tagging trigger
    final questionTriggerIndex = beforeCursor.lastIndexOf('?:');
    if (questionTriggerIndex >= 0) {
      final afterTrigger = beforeCursor.substring(questionTriggerIndex + 2);
      // Make sure there's no @ between ?: and cursor (avoid conflicts)
      if (!afterTrigger.contains(' ') && !afterTrigger.contains('@')) {
        if (afterTrigger.length >= 3) {
          _searchQuestions(afterTrigger);
          return;
        } else {
          setState(() {
            _showQuestionDropdown = true;
            _questionSearchResults = [];
            _isSearchingQuestions = false;
            _showUsernameDropdown = false;
          });
          return;
        }
      }
    }

    // Check for @ chameleon tagging trigger
    final atIndex = beforeCursor.lastIndexOf('@');
    if (atIndex >= 0) {
      // Make sure this @ is not part of ?: (i.e., not preceded by ?)
      final isPartOfQuestionTag =
          atIndex > 0 && beforeCursor[atIndex - 1] == '?';
      if (!isPartOfQuestionTag) {
        final afterAt = beforeCursor.substring(atIndex + 1);
        if (!afterAt.contains(' ')) {
          _filterUsernames(afterAt);
          return;
        }
      }
    }

    // Hide all dropdowns
    if (_showQuestionDropdown || _showUsernameDropdown) {
      setState(() {
        _showQuestionDropdown = false;
        _questionSearchResults = [];
        _showUsernameDropdown = false;
      });
    }
  }

  void _filterUsernames(String query) {
    final filtered = _availableUsernames
        .where((u) => u.toLowerCase().contains(query.toLowerCase()))
        .toList();
    setState(() {
      _showUsernameDropdown = true;
      _showQuestionDropdown = false;
      _taggedUsernames = filtered;
    });
  }

  void _selectUsername(String username) {
    final text = _contentController.text;
    final cursorPosition = _contentController.selection.baseOffset;
    final beforeCursor = text.substring(0, cursorPosition);
    final atIndex = beforeCursor.lastIndexOf('@');

    if (atIndex >= 0) {
      final afterCursor = text.substring(cursorPosition);
      final newText =
          text.substring(0, atIndex) + '@$username ' + afterCursor;
      final newCursorPosition = atIndex + username.length + 2; // @username + space

      _contentController.text = newText;
      _contentController.selection =
          TextSelection.collapsed(offset: newCursorPosition);

      setState(() {
        _showUsernameDropdown = false;
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
      final shouldIncludeNSFW = _isNSFW || questionIsNSFW;

      final results = await _questionService!.searchQuestionsForAutocomplete(
        query,
        limit: 5,
        includeNSFW: shouldIncludeNSFW,
        excludePrivate: true,
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
    final triggerIndex = beforeCursor.lastIndexOf('?:');

    if (triggerIndex >= 0) {
      final afterCursor = text.substring(cursorPosition);
      final questionId = question['id'].toString();
      final questionTitle = question['prompt'].toString();

      _questionCache[questionId] = question;

      if (!_questionIdToNumberMap.containsKey(questionId)) {
        final nextNumber = _questionIdToNumberMap.length + 1;
        _questionIdToNumberMap[questionId] = '[$nextNumber]';
      }

      final numberRef = _questionIdToNumberMap[questionId]!;
      final newText = text.substring(0, triggerIndex) + numberRef + afterCursor;
      final newCursorPosition = triggerIndex + numberRef.length;

      _contentController.text = newText;
      _contentController.selection =
          TextSelection.collapsed(offset: newCursorPosition);

      setState(() {
        _showQuestionDropdown = false;
        _questionSearchResults = [];
      });

      _parseLinkedQuestions();

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
              'Linked question $numberRef: ${questionTitle.length > 50 ? questionTitle.substring(0, 50) + '...' : questionTitle}'),
          duration: Duration(seconds: 2),
          backgroundColor: Theme.of(context).primaryColor,
        ),
      );
    }
  }

  // ─── Comment submission ───

  Future<void> _submitComment() async {
    final isValid = _formKey.currentState!.validate();
    if (!isValid || _isSubmitting) return;

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
    setState(() => _isSubmitting = true);

    final overlayContext = context;

    try {
      final commentService = CommentService();
      final watchlistService =
          Provider.of<WatchlistService>(overlayContext, listen: false);

      final newComment = await commentService.addComment(
        questionId: widget.questionId,
        content: _contentController.text.trim(),
        linkedQuestionIds:
            _linkedQuestionIds.isEmpty ? null : _linkedQuestionIds,
        isNSFW: _isNSFW,
      );

      // Auto-subscribe
      final isAlreadySubscribed =
          await watchlistService.isWatching(widget.questionId);
      String snackbarMessage = 'Nice comment!';
      if (!isAlreadySubscribed) {
        final currentVoteCount = widget.question?['vote_count'] as int? ?? 0;
        final currentCommentCount =
            widget.question?['comment_count'] as int? ?? 0;
        await watchlistService.subscribeToQuestion(
            widget.questionId, currentVoteCount, currentCommentCount);
        snackbarMessage = 'Nice comment! Subscribed to question.';
      }

      widget.onCommentAdded?.call(newComment);

      // Mark discussion questions as answered when user comments
      try {
        final userService =
            Provider.of<UserService>(overlayContext, listen: false);
        final questionType = widget.question?['type']?.toString();
        print('Discussion check: questionType=$questionType, questionId=${widget.questionId}, question=${widget.question != null}');
        if (questionType == 'text') {
          if (!userService.hasAnsweredQuestion(widget.questionId)) {
            print('Discussion: Marking question ${widget.questionId} as answered after comment');
            final answeredQuestion = <String, dynamic>{
              'id': widget.questionId,
              'prompt': widget.question?['prompt']?.toString() ?? widget.question?['title']?.toString() ?? 'Unknown question',
              'type': 'text',
              'timestamp': DateTime.now().toIso8601String(),
              'votes': widget.question?['votes'] ?? 0,
            };
            await userService.addAnsweredQuestion(answeredQuestion);
            print('Discussion: addAnsweredQuestion completed for ${widget.questionId}');
            // Commenting IS the answer for a discussion question, so this is an
            // answer path too — and when the discussion is today's QOTD it owes
            // the notification prompt like any other. No-op otherwise.
            if (overlayContext.mounted) {
              await PostAnswerPrompts.maybeShow(
                overlayContext,
                userService: userService,
                source: 'discussion_comment',
              );
            }
          } else {
            print('Discussion: Question ${widget.questionId} already answered');
          }
        }
      } catch (e) {
        print('Error marking discussion as answered: $e');
      }

      // Check for first comment achievement
      try {
        final userService =
            Provider.of<UserService>(overlayContext, listen: false);
        final achievementService = AchievementService(
          userService: userService,
          context: overlayContext,
        );
        await achievementService.init();
        final congratulationsService = CongratulationsService(
          userService: userService,
          achievementService: achievementService,
        );
        await congratulationsService.init();
        await congratulationsService.showCongratulationsIfEligible(
          overlayContext,
          AchievementType.firstComment,
        );
      } catch (e) {
        print('Error showing congratulations for first comment: $e');
      }

      if (mounted) {
        // Add comment to local list and reset input
        setState(() {
          _comments.add(newComment);
          _sortComments();
          _isSubmitting = false;
          _contentController.clear();
          _linkedQuestionIds = [];
          _questionIdToNumberMap = {};
          _questionCache = {};
          _isNSFW = false;
          _containsProfanity = false;
        });
        _extractAvailableUsernames();

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                Icon(Icons.check_circle, color: Colors.white, size: 20),
                SizedBox(width: 8),
                Expanded(child: Text(snackbarMessage)),
              ],
            ),
            backgroundColor: Theme.of(context).primaryColor,
            duration: Duration(seconds: 3),
          ),
        );
      }
    } catch (e) {
      print('Error adding comment: $e');
      if (mounted) {
        setState(() => _isSubmitting = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to add comment: ${e.toString()}'),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 4),
          ),
        );
      }
    }
  }

  // ─── Build methods ───

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: Container(
        height: MediaQuery.of(context).size.height * 0.9,
        decoration: BoxDecoration(
          color: Theme.of(context).scaffoldBackgroundColor,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(
        children: [
          _buildDragHandle(),
          _buildHeader(),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Divider(height: 1),
          ),
          Expanded(child: _buildCommentsList()),
          if (Supabase.instance.client.auth.currentUser != null)
            _buildInputBar(),
        ],
      ),
      ),
    );
  }

  Widget _buildDragHandle() {
    return Center(
      child: Container(
        margin: EdgeInsets.only(top: 12, bottom: 8),
        width: 40,
        height: 4,
        decoration: BoxDecoration(
          color: Colors.grey[400],
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              widget.questionTitle,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w500,
                  ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          IconButton(
            onPressed: () => Navigator.of(context).pop(),
            icon: Icon(Icons.close),
            style: IconButton.styleFrom(foregroundColor: Colors.grey[600]),
          ),
        ],
      ),
    );
  }

  Widget _buildCommentsListHeader() {
    final commentCount = _visibleComments.length;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Icon(Icons.comment, size: 18, color: Theme.of(context).primaryColor),
          SizedBox(width: 8),
          Text(
            'Comments',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  fontSize: 16,
                ),
          ),
          if (commentCount > 0) ...[
            SizedBox(width: 4),
            Text(
              '($commentCount)',
              style: TextStyle(
                fontSize: 14,
                color: Colors.grey[600],
              ),
            ),
          ],
          if (commentCount > 1) ...[
            SizedBox(width: 12),
            GestureDetector(
              onTap: _toggleSort,
              child: Container(
                padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Theme.of(context).primaryColor.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: Theme.of(context).primaryColor.withOpacity(0.3),
                    width: 1,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _sortBy == 'top' ? Icons.people : Icons.schedule,
                      size: 14,
                      color: Theme.of(context).primaryColor,
                    ),
                    SizedBox(width: 4),
                    Text(
                      _sortBy == 'top' ? 'Top' : 'Chrono',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: Theme.of(context).primaryColor,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildCommentsList() {
    if (_isLoading && _comments.isEmpty) {
      return Center(child: CircularProgressIndicator());
    }

    final visible = _visibleComments;

    if (visible.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.comment_outlined, size: 48, color: Colors.grey[400]),
            SizedBox(height: 12),
            Text(
              'No comments yet',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: Colors.grey[600],
                    fontWeight: FontWeight.w500,
                  ),
            ),
            SizedBox(height: 8),
            Text(
              'Be the first to share your thoughts!',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Colors.grey[500],
                  ),
            ),
          ],
        ),
      );
    }

    // +1 for the header row, +1 for load more if applicable
    final headerOffset = 1;
    final totalItems = headerOffset + visible.length + (_hasMoreComments ? 1 : 0);

    return ListView.builder(
      controller: _scrollController,
      padding: EdgeInsets.symmetric(vertical: 8),
      itemCount: totalItems,
      itemBuilder: (context, index) {
        if (index == 0) {
          return _buildCommentsListHeader();
        }

        final commentIndex = index - headerOffset;
        if (commentIndex == visible.length) {
          return Container(
            margin: EdgeInsets.symmetric(vertical: 8),
            width: double.infinity,
            child: TextButton(
              onPressed: _isLoading ? null : () => _loadComments(loadMore: true),
              style: TextButton.styleFrom(
                foregroundColor: Theme.of(context).primaryColor,
                padding: EdgeInsets.symmetric(vertical: 12),
              ),
              child: _isLoading
                  ? SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text('Load more comments',
                      style: TextStyle(fontWeight: FontWeight.w500)),
            ),
          );
        }

        final comment = visible[commentIndex];
        return CommentWidget(
          key: ValueKey(comment['id']),
          comment: comment,
          isExpanded:
              _expandedCommentIds.contains(comment['id']?.toString()),
          onExpandToggle: () =>
              _toggleCommentExpanded(comment['id']?.toString() ?? ''),
          onUpvoteLizardTap: () =>
              _handleUpvoteLizard(comment['id']?.toString() ?? ''),
          onReportTap: () =>
              _handleReportComment(comment['id']?.toString() ?? ''),
          onDeleteTap: () =>
              _handleDeleteComment(comment['id']?.toString() ?? ''),
          margin: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          questionContext: widget.question,
          currentUserUsername: _currentUserUsername,
        );
      },
    );
  }

  Widget _buildInputBar() {
    final isNSFWContext = _isNSFW || widget.question?['nsfw'] == true;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          child: Divider(height: 1),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_showUsernameDropdown) _buildUsernameDropdown(),
              if (_showQuestionDropdown) _buildQuestionDropdown(),
              if (_linkedQuestionIds.isNotEmpty) _buildLinkedQuestionsPreview(),
              if (_shouldShowNSFWOption() && _containsProfanity)
                _buildNSFWOption(),
              Padding(
                padding: EdgeInsets.only(bottom: 6),
                child: Text(
                  'Please remember to be respectful, kind, and curious.',
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).brightness == Brightness.dark
                        ? Colors.grey[400]
                        : Colors.grey[600],
                  ),
                ),
              ),
              Form(
                key: _formKey,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: _contentController,
                        focusNode: _inputFocusNode,
                        maxLines: _inputExpanded ? 5 : 1,
                        minLines: _inputExpanded ? 3 : 1,
                        maxLength: 500,
                        textCapitalization: TextCapitalization.sentences,
                        decoration: InputDecoration(
                          hintText: 'What are your thoughts?',
                          hintStyle: TextStyle(fontSize: 14),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(20),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(20),
                            borderSide: BorderSide(
                              color: (_containsProfanity && !isNSFWContext)
                                  ? Colors.red
                                  : Theme.of(context).primaryColor,
                            ),
                          ),
                          contentPadding:
                              EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                          counterText: '',
                          isDense: true,
                        ),
                        style: TextStyle(fontSize: 14),
                        validator: (value) {
                          if (value == null || value.trim().isEmpty) {
                            return 'Please enter a comment';
                          }
                          if (value.trim().length < 3) {
                            return 'Comment must be at least 3 characters';
                          }
                          final questionIsNSFW =
                              widget.question?['nsfw'] == true;
                          if (_containsProfanity &&
                              !_isNSFW &&
                              !questionIsNSFW) {
                            return 'Please remove inappropriate language';
                          }
                          return null;
                        },
                      ),
                    ),
                    SizedBox(width: 8),
                    IconButton(
                      onPressed: _isSubmitting ? null : _submitComment,
                      icon: _isSubmitting
                          ? SizedBox(
                              width: 20,
                              height: 20,
                              child:
                                  CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Icon(Icons.send,
                              color: Theme.of(context).primaryColor),
                      style: IconButton.styleFrom(
                        backgroundColor:
                            Theme.of(context).primaryColor.withOpacity(0.1),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildUsernameDropdown() {
    final usernames = _taggedUsernames.isEmpty && _showUsernameDropdown
        ? _availableUsernames
        : _taggedUsernames;

    if (usernames.isEmpty) {
      return Container(
        margin: EdgeInsets.only(bottom: 4),
        padding: EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Theme.of(context).cardColor,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: Theme.of(context).primaryColor.withOpacity(0.3),
          ),
        ),
        child: Text(
          'No chameleons found',
          style: TextStyle(color: Colors.grey[600], fontSize: 13),
        ),
      );
    }

    return Container(
      margin: EdgeInsets.only(bottom: 4),
      constraints: BoxConstraints(maxHeight: 150),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: Theme.of(context).primaryColor.withOpacity(0.3),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 8,
            offset: Offset(0, -2),
          ),
        ],
      ),
      child: ListView.builder(
        shrinkWrap: true,
        itemCount: usernames.length,
        itemBuilder: (context, index) {
          final username = usernames[index];
          return InkWell(
            onTap: () => _selectUsername(username),
            child: Container(
              padding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(
                    color: Theme.of(context).dividerColor.withOpacity(0.2),
                    width: index < usernames.length - 1 ? 0.5 : 0,
                  ),
                ),
              ),
              child: Row(
                children: [
                  Icon(Icons.person, size: 16,
                      color: Theme.of(context).primaryColor),
                  SizedBox(width: 8),
                  Text(
                    username,
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildQuestionDropdown() {
    return Container(
      margin: EdgeInsets.only(bottom: 4),
      constraints: BoxConstraints(maxHeight: 150),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: Theme.of(context).primaryColor.withOpacity(0.3),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 8,
            offset: Offset(0, -2),
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
                      child: CircularProgressIndicator(strokeWidth: 2)),
                  SizedBox(width: 8),
                  Text('Searching questions...'),
                ],
              ),
            )
          : _questionSearchResults.isEmpty
              ? _buildQuestionSearchHint()
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
                              color: Theme.of(context)
                                  .dividerColor
                                  .withOpacity(0.3),
                              width: index <
                                      _questionSearchResults.length - 1
                                  ? 0.5
                                  : 0,
                            ),
                          ),
                        ),
                        child: Row(
                          children: [
                            Icon(typeIcon,
                                size: 16,
                                color: Theme.of(context).primaryColor),
                            SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment:
                                    CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    prompt,
                                    style: TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w500),
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
                                              color: Colors.grey[600]),
                                        ),
                                        if (isNSFW) SizedBox(width: 8),
                                      ],
                                      if (isNSFW)
                                        Container(
                                          padding: EdgeInsets.symmetric(
                                              horizontal: 4, vertical: 1),
                                          decoration: BoxDecoration(
                                            color:
                                                Colors.red.withOpacity(0.1),
                                            borderRadius:
                                                BorderRadius.circular(3),
                                            border: Border.all(
                                                color: Colors.red
                                                    .withOpacity(0.3),
                                                width: 0.5),
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

  Widget _buildQuestionSearchHint() {
    final text = _contentController.text;
    final cursorPosition = _contentController.selection.baseOffset;
    if (cursorPosition < 0 || cursorPosition > text.length) {
      return SizedBox.shrink();
    }
    final beforeCursor = text.substring(0, cursorPosition);
    final triggerIndex = beforeCursor.lastIndexOf('?:');

    if (triggerIndex >= 0) {
      final afterTrigger = beforeCursor.substring(triggerIndex + 2);
      final remainingChars = 3 - afterTrigger.length;

      if (remainingChars > 0) {
        return Container(
          padding: EdgeInsets.all(12),
          child: Row(
            children: [
              Icon(Icons.search, size: 16, color: Colors.grey[500]),
              SizedBox(width: 8),
              Text(
                'Type $remainingChars more character${remainingChars > 1 ? 's' : ''} to search questions...',
                style: TextStyle(fontSize: 13, color: Colors.grey[600]),
              ),
            ],
          ),
        );
      }
    }

    return Container(
      padding: EdgeInsets.all(12),
      child: Text('No questions found',
          style: TextStyle(color: Colors.grey[600])),
    );
  }

  Widget _buildLinkedQuestionsPreview() {
    return Container(
      margin: EdgeInsets.only(bottom: 4),
      padding: EdgeInsets.all(8),
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
              Icon(Icons.link, size: 14, color: Theme.of(context).primaryColor),
              SizedBox(width: 4),
              Text(
                'Referenced Questions (${_linkedQuestionIds.length})',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  color: Theme.of(context).primaryColor,
                ),
              ),
            ],
          ),
          SizedBox(height: 4),
          ...(_linkedQuestionIds.map((questionId) {
            final numberRef = _questionIdToNumberMap[questionId] ?? '[?]';
            final questionData = _questionCache[questionId];
            final questionTitle =
                questionData?['prompt']?.toString() ?? 'Unknown question';
            return Padding(
              padding: EdgeInsets.only(bottom: 2),
              child: Row(
                children: [
                  Text(
                    numberRef,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: Theme.of(context).primaryColor,
                    ),
                  ),
                  SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      questionTitle.length > 40
                          ? questionTitle.substring(0, 40) + '...'
                          : questionTitle,
                      style: TextStyle(fontSize: 11, color: Colors.grey[600]),
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

  Widget _buildNSFWOption() {
    return Padding(
      padding: EdgeInsets.only(bottom: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 24,
            height: 24,
            child: Checkbox(
              value: _isNSFW,
              onChanged: (value) => setState(() => _isNSFW = value ?? false),
              activeColor: Theme.of(context).primaryColor,
            ),
          ),
          SizedBox(width: 4),
          GestureDetector(
            onTap: () => setState(() => _isNSFW = !_isNSFW),
            child: Text(
              'Mark as NSFW/18+',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}
