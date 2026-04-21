// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../services/question_service.dart';
import '../services/user_service.dart';
import '../services/location_service.dart';
import '../services/analytics_service.dart';
import 'approval_slider.dart';
import 'animated_submit_button.dart';
import 'authentication_dialog.dart';
import 'whats_new_dialog.dart';
import 'qotd_overlay_results_preview.dart';

class QotdOverlay {
  static bool _hasShownThisSession = false;

  static Future<void> checkAndShow(BuildContext context) async {
    if (_hasShownThisSession) return;
    if (WhatsNewDialog.wasShownThisSession) return;

    final supabase = Supabase.instance.client;
    if (supabase.auth.currentUser == null) return;

    final questionService = Provider.of<QuestionService>(context, listen: false);
    final userService = Provider.of<UserService>(context, listen: false);

    final showNSFW = userService.showNSFWContent;

    // QOTD may not be cached yet on cold start (async fetch in progress).
    // Wait briefly for it to become available.
    Map<String, dynamic>? qotd = await questionService.getQuestionOfTheDay(showNSFW: showNSFW);
    if (qotd == null) {
      // Wait up to 3 seconds for the QOTD fetch to complete
      for (int i = 0; i < 6; i++) {
        await Future.delayed(const Duration(milliseconds: 500));
        if (!context.mounted) return;
        qotd = await questionService.getQuestionOfTheDay(showNSFW: showNSFW);
        if (qotd != null) break;
      }
    }
    if (qotd == null) return;
    if (!context.mounted) return;
    final resolvedQotd = qotd;

    final hasAnswered = questionService.hasAnsweredQuestionOfTheDay(userService);

    AnalyticsService().trackEvent('qotd_overlay_shown', {
      'has_answered': hasAnswered,
      'question_type': resolvedQotd['type']?.toString() ?? 'unknown',
    });

    try {
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        isDismissible: true,
        enableDrag: true,
        useSafeArea: true,
        backgroundColor: Colors.transparent,
        builder: (context) => QotdOverlaySheet(
          question: resolvedQotd,
          hasAnswered: hasAnswered,
        ),
      );
      // Only mark as shown if showModalBottomSheet succeeded
      _hasShownThisSession = true;
    } catch (e) {
      print('QotdOverlay: Error showing overlay: $e');
      // Don't set _hasShownThisSession so another caller can retry
    }
  }
}

class QotdOverlaySheet extends StatefulWidget {
  final Map<String, dynamic> question;
  final bool hasAnswered;

  const QotdOverlaySheet({
    Key? key,
    required this.question,
    required this.hasAnswered,
  }) : super(key: key);

  @override
  State<QotdOverlaySheet> createState() => _QotdOverlaySheetState();
}

class _QotdOverlaySheetState extends State<QotdOverlaySheet> {
  late bool _showResults;
  bool _isSubmitting = false;
  bool _hasMap = false;
  double _sliderValue = 0.0;
  String? _selectedOption;
  final TextEditingController _textController = TextEditingController();

  final ScrollController _scrollController = ScrollController();
  bool _showScrollHint = false;
  int? _responseCount;
  int? _commentCount;

  @override
  void initState() {
    super.initState();
    _showResults = widget.hasAnswered;
    _scrollController.addListener(_updateScrollHint);
    _fetchCounts();
    // Check scroll hint after initial layout
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _updateScrollHint();
    });
  }

  Future<void> _fetchCounts() async {
    try {
      final questionId = widget.question['id'].toString();
      final supabase = Supabase.instance.client;
      final results = await Future.wait([
        supabase.from('responses').select('id').eq('question_id', questionId),
        supabase.from('comments').select('id').eq('question_id', questionId),
      ]);
      if (mounted) {
        setState(() {
          _responseCount = results[0].length;
          _commentCount = results[1].length;
        });
      }
    } catch (e) {
      print('QotdOverlay: Error fetching counts: $e');
    }
  }

  @override
  void dispose() {
    _textController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _updateScrollHint() {
    if (!_scrollController.hasClients) return;
    final pos = _scrollController.position;
    final canScroll = pos.maxScrollExtent > 0 &&
        (pos.maxScrollExtent - pos.pixels) > 80;
    if (canScroll != _showScrollHint) {
      setState(() => _showScrollHint = canScroll);
    }
  }

  String get _questionType {
    final type = widget.question['type']?.toString().toLowerCase() ?? 'text';
    return type;
  }

  String get _questionPrompt {
    return widget.question['prompt']?.toString() ?? '';
  }

  bool get _canSubmit {
    if (_isSubmitting) return false;
    switch (_questionType) {
      case 'approval_rating':
      case 'approval':
        return true;
      case 'multiplechoice':
      case 'multiple_choice':
        return _selectedOption != null;
      case 'text':
        return _textController.text.trim().isNotEmpty;
      default:
        return false;
    }
  }

  Future<void> _submit() async {
    if (!_canSubmit) return;

    final supabase = Supabase.instance.client;
    final locationService = Provider.of<LocationService>(context, listen: false);
    final questionService = Provider.of<QuestionService>(context, listen: false);
    final userService = Provider.of<UserService>(context, listen: false);

    if (!locationService.isInitialized) {
      await locationService.initialize();
    }

    final isAuthenticated = supabase.auth.currentUser != null;
    final hasCity = locationService.selectedCity != null;

    if (!isAuthenticated || !hasCity) {
      if (!context.mounted) return;
      await AuthenticationDialog.show(
        context,
        customMessage: 'To submit your response, you need to authenticate and set your city.',
        onComplete: () => _submit(),
      );
      return;
    }

    setState(() => _isSubmitting = true);

    final questionId = widget.question['id'].toString();
    final countryCode = locationService.selectedCountry ?? '';
    bool success = false;

    try {
      switch (_questionType) {
        case 'approval_rating':
        case 'approval':
          success = await questionService.submitApprovalResponse(
            questionId,
            _sliderValue,
            countryCode,
            locationService: locationService,
          );
          break;
        case 'multiplechoice':
        case 'multiple_choice':
          if (_selectedOption != null) {
            success = await questionService.submitMultipleChoiceResponse(
              questionId,
              _selectedOption!,
              countryCode,
              locationService: locationService,
            );
          }
          break;
        case 'text':
          success = await questionService.submitTextResponse(
            questionId,
            _textController.text.trim(),
            countryCode,
            locationService: locationService,
          );
          break;
      }

      if (success) {
        await userService.addAnsweredQuestion(widget.question, context: context);
        AnalyticsService().trackEvent('qotd_overlay_answered', {
          'question_type': _questionType,
        });
        if (mounted) {
          setState(() {
            _showResults = true;
            _isSubmitting = false;
          });
        }
      } else {
        if (mounted) setState(() => _isSubmitting = false);
      }
    } catch (e) {
      print('QotdOverlay: Error submitting response: $e');
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  void _dismiss({String method = 'x_button'}) {
    AnalyticsService().trackEvent('qotd_overlay_dismissed', {
      'method': method,
    });
    Navigator.of(context).pop();
  }

  Future<void> _seeMore() async {
    AnalyticsService().trackEvent('qotd_overlay_see_more_tapped', {});
    final questionService = Provider.of<QuestionService>(context, listen: false);
    final questionId = widget.question['id']?.toString();

    // Build FeedContext with QOTD + trending feed (same as deep link & home screen)
    FeedContext? feedContext;
    try {
      final trendingQuestions = await questionService.fetchOptimizedFeed(
        feedType: 'trending',
        limit: 50,
        useCache: true,
      ).catchError((_) => <Map<String, dynamic>>[]);

      if (trendingQuestions.isNotEmpty) {
        final deduped = trendingQuestions
            .where((q) => q['id']?.toString() != questionId)
            .toList();

        feedContext = FeedContext(
          feedType: 'trending',
          filters: {},
          questions: [widget.question, ...deduped],
          currentQuestionIndex: 0,
          originalQuestionId: questionId,
          originalQuestionIndex: 0,
        );
      }
    } catch (e) {
      print('QotdOverlay: Error building FeedContext: $e');
    }

    if (!mounted) return;

    // Grab the navigator before popping the modal
    final navigator = Navigator.of(context);
    navigator.pop();
    // Navigate to results after the modal dismissal completes
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (navigator.context.mounted) {
        questionService.navigateToResultsScreen(
          navigator.context,
          widget.question,
          feedContext: feedContext,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      height: MediaQuery.of(context).size.height * 0.9,
      decoration: BoxDecoration(
        color: theme.scaffoldBackgroundColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        children: [
          // Drag handle
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey[400],
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 16, 8, 0),
            child: Row(
              children: [
                IconButton(
                  onPressed: null,
                  icon: Icon(Icons.today, color: theme.primaryColor),
                  iconSize: 24,
                ),
                Expanded(
                  child: Text(
                    'Question of the Day',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: theme.primaryColor,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: () => _dismiss(method: 'x_button'),
                  icon: Icon(Icons.close, color: theme.primaryColor),
                  iconSize: 24,
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Divider(color: Colors.grey[400]),
          ),
          // Content
          Expanded(
            child: Stack(
              children: [
                NotificationListener<ScrollNotification>(
                  onNotification: (_) {
                    // Schedule hint update after frame to avoid build-during-build
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted) _updateScrollHint();
                    });
                    return false;
                  },
                  child: SingleChildScrollView(
                    controller: _scrollController,
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Question text
                        Text(
                          _questionPrompt,
                          style: theme.textTheme.headlineSmall?.copyWith(
                            fontWeight: FontWeight.w600,
                            height: 1.3,
                          ),
                        ),
                        if (widget.question['description'] != null) ...[
                          const SizedBox(height: 8),
                          Text(
                            widget.question['description'],
                            style: theme.textTheme.bodyMedium,
                          ),
                        ],
                        const SizedBox(height: 40),
                        // Answer input or results preview
                        if (_showResults) ...[
                          _buildResultsPreview(),
                          const SizedBox(height: 24),
                          // Vote and comment counts
                          Row(
                            children: [
                              Text(
                                '${_responseCount ?? widget.question['votes'] ?? 0}',
                                style: TextStyle(
                                  color: Colors.grey[600],
                                  fontSize: 14,
                                ),
                              ),
                              const SizedBox(width: 4),
                              Icon(Icons.people_outline, size: 16, color: Colors.grey[600]),
                              if ((_commentCount ?? widget.question['comment_count'] ?? 0) > 0) ...[
                                const Spacer(),
                                Text(
                                  '${_commentCount ?? widget.question['comment_count'] ?? 0}',
                                  style: TextStyle(
                                    color: Colors.grey[600],
                                    fontSize: 14,
                                  ),
                                ),
                                const SizedBox(width: 4),
                                Icon(Icons.chat_bubble_outline, size: 16, color: Colors.grey[600]),
                              ],
                            ],
                          ),
                          const SizedBox(height: 16),
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton(
                              onPressed: _seeMore,
                              style: ElevatedButton.styleFrom(
                                padding: const EdgeInsets.symmetric(vertical: 16),
                                backgroundColor: theme.primaryColor,
                                foregroundColor: Colors.white,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(8),
                                ),
                              ),
                              child: Text(
                                (_commentCount ?? widget.question['comment_count'] ?? 0) > 0
                                    ? 'See comments'
                                    : _hasMap
                                        ? 'View map'
                                        : 'Go to results',
                                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                          SizedBox(
                            width: double.infinity,
                            child: OutlinedButton(
                              onPressed: () => _dismiss(method: 'exit_button'),
                              style: OutlinedButton.styleFrom(
                                padding: const EdgeInsets.symmetric(vertical: 16),
                                side: BorderSide(color: theme.primaryColor),
                                foregroundColor: theme.primaryColor,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(8),
                                ),
                              ),
                              child: const Text(
                                'Exit',
                                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
                              ),
                            ),
                          ),
                        ] else ...[
                          _buildAnswerInput(),
                          const SizedBox(height: 24),
                          AnimatedSubmitButton(
                            onPressed: _canSubmit ? _submit : null,
                            isLoading: _isSubmitting,
                            buttonText: 'Submit response',
                            disabledText: _questionType == 'text'
                                ? 'Type your answer'
                                : 'Select an option',
                          ),
                          const SizedBox(height: 12),
                          SizedBox(
                            width: double.infinity,
                            child: OutlinedButton(
                              onPressed: () => _dismiss(method: 'exit_button'),
                              style: OutlinedButton.styleFrom(
                                padding: const EdgeInsets.symmetric(vertical: 16),
                                side: BorderSide(color: theme.primaryColor),
                                foregroundColor: theme.primaryColor,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(8),
                                ),
                              ),
                              child: const Text(
                                'Exit',
                                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                // Scroll hint pill
                if (_showResults && _showScrollHint)
                  Positioned(
                    bottom: 4,
                    left: 0,
                    right: 0,
                    child: IgnorePointer(
                      child: Center(
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          decoration: BoxDecoration(
                            color: Colors.black54,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.keyboard_arrow_down, color: Colors.white, size: 16),
                              SizedBox(width: 4),
                              Text(
                                'Scroll for more',
                                style: TextStyle(color: Colors.white, fontSize: 12),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAnswerInput() {
    switch (_questionType) {
      case 'approval_rating':
      case 'approval':
        return _buildApprovalInput();
      case 'multiplechoice':
      case 'multiple_choice':
        return _buildMultipleChoiceInput();
      case 'text':
        return _buildTextInput();
      default:
        return _buildTextInput();
    }
  }

  Widget _buildApprovalInput() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Drag the slider to respond',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: Theme.of(context).dividerColor,
            ),
          ),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Icon(Icons.thumb_down, color: Colors.red),
                  Icon(Icons.thumb_up, color: Colors.green),
                ],
              ),
              const SizedBox(height: 8),
              ApprovalSlider(
                initialValue: 0.0,
                onChanged: (value) {
                  setState(() => _sliderValue = value);
                },
              ),
            ],
          ),
        ),
      ],
    );
  }

  String _getApprovalLabel(double value) {
    if (value <= -0.8) return 'Strongly Disapprove';
    if (value <= -0.3) return 'Disapprove';
    if (value <= 0.3) return 'Neutral';
    if (value <= 0.8) return 'Approve';
    return 'Strongly Approve';
  }

  Color _getApprovalColor(double value) {
    if (value <= -0.3) return Colors.red;
    if (value <= 0.3) return Colors.grey;
    return Colors.green;
  }

  Widget _buildMultipleChoiceInput() {
    final options = widget.question['question_options'] as List<dynamic>? ?? [];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Select your answer',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            color: Colors.grey[600],
          ),
        ),
        const SizedBox(height: 16),
        ...options.map((option) {
          final optionText = option['option_text']?.toString() ?? '';
          final isSelected = _selectedOption == optionText;
          final theme = Theme.of(context);

          return Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Material(
              color: isSelected
                  ? theme.primaryColor.withOpacity(0.12)
                  : theme.cardColor,
              borderRadius: BorderRadius.circular(12),
              child: InkWell(
                onTap: () => setState(() => _selectedOption = optionText),
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: isSelected
                          ? theme.primaryColor
                          : Colors.grey.withOpacity(0.3),
                      width: isSelected ? 2 : 1,
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        isSelected
                            ? Icons.radio_button_checked
                            : Icons.radio_button_unchecked,
                        color: isSelected ? theme.primaryColor : Colors.grey,
                        size: 22,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          optionText,
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                            color: isSelected
                                ? theme.primaryColor
                                : theme.textTheme.bodyLarge?.color,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ],
    );
  }

  Widget _buildTextInput() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Type your answer',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            color: Colors.grey[600],
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _textController,
          maxLines: 5,
          minLines: 3,
          decoration: InputDecoration(
            hintText: 'Share your thoughts...',
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(
                color: Theme.of(context).primaryColor,
                width: 2,
              ),
            ),
          ),
          onChanged: (_) => setState(() {}),
        ),
      ],
    );
  }

  Widget _buildResultsPreview() {
    return QotdOverlayResultsPreview(
      question: widget.question,
      onSeeMore: _seeMore,
      onMapAvailable: (hasMap) {
        if (hasMap != _hasMap) {
          setState(() => _hasMap = hasMap);
        }
      },
    );
  }
}
