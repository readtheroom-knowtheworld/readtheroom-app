// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The centered Question-of-the-Day hero — the heart of the QOTD-first "Today"
// home (Phase 2). Renders one of four states (loading / unavailable / ask /
// answered) as chosen by [QotdHomeState], and owns the full inline answer +
// submit flow (auth/city gate, the post-answer notification ask via
// PostAnswerPrompts, per-type
// response submit with the 2s min-animation, streak accrual via
// UserService.addAnsweredQuestion, analytics, and the push to the existing
// animated results screen with an Archive swipe context).
//
// The card has BuildContext + Provider access, so — like the overlay it
// replaces — it wires its own dependencies rather than routing everything
// through the parent. The parent (HomeScreen) supplies only the resolved
// [state]/[question], the [onRetry] re-resolve hook, and [onBrowseArchive].

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/analytics_service.dart';
import '../services/location_service.dart';
import '../services/post_answer_prompts.dart';
import '../services/profile_service.dart';
import '../services/question_service.dart';
import '../services/user_service.dart';
import '../utils/results_surface.dart';
import '../utils/haptic_utils.dart';
import '../utils/qotd_home_state.dart';
import '../utils/qotd_results_preview_logic.dart';
import '../utils/username_logic.dart';
import 'animated_submit_button.dart';
import 'authentication_dialog.dart';
import 'qotd_answer_input.dart';
import 'qotd_results_preview.dart';
import 'question_reactions_widget.dart';
import 'share_with_close_friends_toggle.dart';

class QotdHeroCard extends StatefulWidget {
  /// The resolved home state (computed by HomeScreen via [qotdHomeState]).
  final QotdHomeState state;

  /// The enriched QOTD map (null in loading/unavailable states).
  final Map<String, dynamic>? question;

  /// The live UserService (streak, answered lookup, NSFW pref).
  final UserService userService;

  /// Re-resolve the QOTD (retry from the unavailable state).
  final VoidCallback onRetry;

  /// Bumped by the home screen's pull-to-refresh. A change re-fetches the
  /// inline results preview and the reactions row even though the question id
  /// is unchanged (new votes / emojis since the card was built).
  final int refreshNonce;

  const QotdHeroCard({
    Key? key,
    required this.state,
    required this.question,
    required this.userService,
    required this.onRetry,
    this.refreshNonce = 0,
  }) : super(key: key);

  @override
  State<QotdHeroCard> createState() => _QotdHeroCardState();
}

class _QotdHeroCardState extends State<QotdHeroCard>
    with SingleTickerProviderStateMixin {
  QotdAnswerValue? _answerValue;
  bool _isSubmitting = false;

  /// The per-answer close-friend flag for *this* answer (owner decision
  /// 2026-09-17). Default ON, chosen above the answer controls, sent with the
  /// submit and then frozen onto the row — it is not a profile setting, so
  /// nothing loads or persists it.
  bool _shareWithCloseFriends = true;

  /// Lets a one-gesture answer (MC option tap / approval slider release) fire
  /// the submit button so it visibly plays its press + progress animation
  /// (WP-A), rather than duplicating the animation here.
  final AnimatedSubmitButtonController _submitButtonController =
      AnimatedSubmitButtonController();

  late final AnimationController _entryController;
  late final Animation<double> _fade;
  late final Animation<Offset> _slide;

  @override
  void initState() {
    super.initState();
    _entryController = AnimationController(
      duration: const Duration(milliseconds: 420),
      vsync: this,
    );
    _fade = CurvedAnimation(parent: _entryController, curve: Curves.easeOut);
    _slide = Tween<Offset>(
      begin: const Offset(0, 0.04),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _entryController, curve: Curves.easeOut));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _entryController.forward();
    });
  }

  @override
  void dispose() {
    _entryController.dispose();
    _submitButtonController.dispose();
    super.dispose();
  }

  String get _questionType =>
      widget.question?['type']?.toString().toLowerCase() ?? 'text';

  bool get _canSubmit => !_isSubmitting && (_answerValue?.canSubmit ?? false);

  // --- submit flow ----------------------------------------------------------

  Future<void> _onSubmitPressed() async {
    final value = _answerValue;
    if (value == null || !value.canSubmit || _isSubmitting) return;
    await _submit(value);
  }

  /// Tap-to-submit (WP-A): a committed one-gesture answer fires the submit
  /// button through its controller, so the identical submit path runs and the
  /// button animates. Gestures during an in-flight submission are ignored
  /// (here and inside the controller).
  void _onAnswerCommitted(QotdAnswerValue value) {
    if (_isSubmitting || !value.canSubmit) return;
    setState(() => _answerValue = value);
    // Let the setState land so the button's `onPressed` is non-null before we
    // fire it.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _submitButtonController.trigger();
    });
  }

  Future<void> _submit(QotdAnswerValue value) async {
    final question = widget.question;
    if (question == null) return;

    final supabase = Supabase.instance.client;
    final locationService = context.read<LocationService>();
    final questionService = context.read<QuestionService>();
    final userService = widget.userService;

    if (!locationService.isInitialized) {
      await locationService.initialize();
    }

    final isAuthenticated = supabase.auth.currentUser != null;
    final hasCity = locationService.selectedCity != null;

    // Auth + city gate, identical to the overlay (retry via onComplete).
    if (!isAuthenticated || !hasCity) {
      if (!mounted) return;
      await AuthenticationDialog.show(
        context,
        customMessage:
            'To submit your response, you need to authenticate and set your city.',
        onComplete: () => _submit(value),
      );
      return;
    }

    setState(() => _isSubmitting = true);

    final questionId = question['id'].toString();
    final countryCode = locationService.selectedCountry ?? '';
    final type = _questionType;

    Future<bool> doSubmit() async {
      switch (type) {
        case 'approval_rating':
        case 'approval':
          return questionService.submitApprovalResponse(
            questionId,
            (value.submitValue as double?) ?? 0.0,
            countryCode,
            locationService: locationService,
            sharedWithCloseFriends: _shareWithCloseFriends,
          );
        case 'multiplechoice':
        case 'multiple_choice':
          final option = value.submitValue as String?;
          if (option == null) return false;
          return questionService.submitMultipleChoiceResponse(
            questionId,
            option,
            countryCode,
            locationService: locationService,
            sharedWithCloseFriends: _shareWithCloseFriends,
          );
        case 'text':
          return questionService.submitTextResponse(
            questionId,
            (value.submitValue as String?) ?? '',
            countryCode,
            locationService: locationService,
            sharedWithCloseFriends: _shareWithCloseFriends,
          );
        default:
          return false;
      }
    }

    bool success = false;
    try {
      // Run the submit alongside a 2s floor so the submit animation plays out
      // (mirrors answer_approval_screen's Future.wait pattern).
      final results = await Future.wait<dynamic>([
        doSubmit(),
        Future.delayed(const Duration(seconds: 2)),
      ]);
      success = results[0] == true;
    } catch (e) {
      print('QotdHeroCard: Error submitting response: $e');
      success = false;
    }

    if (!mounted) return;
    setState(() => _isSubmitting = false);
    if (!success) {
      // Review 2026-09-22 C2 — see answer_multiple_choice_screen.
      AnalyticsService().trackAnswerSubmitFailed(type, source: 'qotd');
      return; // Failure keeps the ask state, no accrual.
    }

    // Streak accrual + bookkeeping (addAnsweredQuestion stamps timestamp and
    // counts_for_streak internally; QOTD answers credit the streak).
    await userService.addAnsweredQuestion(
      question,
      context: context,
      answer: _answerDisplayString(value),
    );
    AnalyticsService().trackQuestionAnswered(
      type,
      type,
      source: 'qotd',
      sharedWithCloseFriends: _shareWithCloseFriends,
    );
    await questionService.updateQuestionVoteCount(questionId);
    AppHaptics.mediumImpact();

    // Notification ask, right after a successful answer — the moment the daily
    // ritual just proved its value. Never blocks the answer itself (the old
    // flow intercepted the submit). The decision (first ask / weekly re-ask /
    // Settings nudge when OS-denied) lives in `PostAnswerPrompts`, which every
    // other answer path also calls — the debt was already recorded by
    // `addAnsweredQuestion` above.
    if (mounted) {
      await PostAnswerPrompts.maybeShow(
        context,
        userService: userService,
        source: 'home_hero',
      );
    }

    // Stay on home: the card flips to its answered state (results in-card)
    // via the UserService notify from addAnsweredQuestion. The results screen
    // is only pushed when the user explicitly taps the comments action.
  }

  /// Build the Archive swipe context and push the existing results screen.
  Future<void> _navigateToResults(Map<String, dynamic> question) async {
    final questionService = context.read<QuestionService>();
    final userService = widget.userService;
    final questionId = question['id']?.toString();

    FeedContext? feedContext;
    try {
      final queue = await questionService.fetchArchiveQueue(
        userService: userService,
        showNSFW: userService.showNSFWContent,
      );
      final deduped =
          queue.where((q) => q['id']?.toString() != questionId).toList();
      feedContext = FeedContext(
        feedType: 'archive',
        filters: const {},
        questions: [question, ...deduped],
        currentQuestionIndex: 0,
        originalQuestionId: questionId,
        originalQuestionIndex: 0,
      );
    } catch (e) {
      feedContext = null; // SwipeNavigationWrapper tolerates a null context.
    }

    if (!mounted) return;
    await questionService.navigateToResultsScreen(
      context,
      question,
      feedContext: feedContext,
    );
  }

  String? _answerDisplayString(QotdAnswerValue value) {
    switch (_questionType) {
      case 'text':
        final t = value.text.trim();
        return t.isEmpty ? null : t;
      case 'multiplechoice':
      case 'multiple_choice':
        return value.selectedOption;
      case 'approval_rating':
      case 'approval':
        final v = value.sliderValue;
        if (v > 0.33) return 'Approve';
        if (v < -0.33) return 'Disapprove';
        return 'Neutral';
      default:
        return null;
    }
  }

  /// The user's stored answer for today's QOTD, if the record carries one.
  String? _storedAnswer() {
    final id = widget.question?['id']?.toString();
    if (id == null) return null;
    for (final record in widget.userService.answeredQuestions) {
      if (record['id']?.toString() == id) {
        final a = record['answer'];
        if (a is String && a.trim().isNotEmpty) return a.trim();
      }
    }
    return null;
  }

  // --- helpers --------------------------------------------------------------

  static const List<String> _months = [
    'January', 'February', 'March', 'April', 'May', 'June',
    'July', 'August', 'September', 'October', 'November', 'December',
  ];

  String _todayLabel() {
    final now = DateTime.now();
    return '${now.day} ${_months[now.month - 1]} ${now.year}';
  }

  // --- build ----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    // Respect reduced-motion: jump the entry animation to its resting state.
    if (MediaQuery.of(context).disableAnimations) {
      _entryController.value = 1.0;
    }

    Widget child;
    switch (widget.state) {
      case QotdHomeState.loading:
        child = _buildLoading(context);
        break;
      case QotdHomeState.unavailable:
        child = _buildUnavailable(context);
        break;
      case QotdHomeState.ask:
        child = _buildAsk(context);
        break;
      case QotdHomeState.answered:
        child = _buildAnswered(context);
        break;
    }

    return FadeTransition(
      opacity: _fade,
      child: SlideTransition(position: _slide, child: child),
    );
  }

  Widget _buildLoading(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      padding: const EdgeInsets.all(16),
      constraints: const BoxConstraints(minHeight: 220),
      decoration: BoxDecoration(
        color: Colors.grey.withOpacity(0.1),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey.withOpacity(0.3)),
      ),
      child: const Center(
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
    );
  }

  Widget _buildUnavailable(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: theme.cardColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: theme.dividerColor.withOpacity(0.4)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.wb_sunny_outlined, size: 40, color: theme.primaryColor),
          const SizedBox(height: 16),
          Text(
            "Today's question is on its way",
            style: theme.textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.w600),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            "We couldn't load the Question of the Day just now. Give it a "
            'moment and try again.',
            style: theme.textTheme.bodyMedium?.copyWith(color: Colors.grey[600]),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: widget.onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('Try again'),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
                backgroundColor: theme.primaryColor,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAsk(BuildContext context) {
    final theme = Theme.of(context);
    final question = widget.question!;
    final prompt = question['prompt']?.toString() ?? '';
    final description = question['description']?.toString();

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            theme.primaryColor.withOpacity(0.10),
            theme.primaryColor.withOpacity(0.04),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: theme.primaryColor.withOpacity(0.30)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Label + date
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.today, size: 18, color: theme.primaryColor),
              const SizedBox(width: 6),
              Text(
                'Question of the Day',
                style: theme.textTheme.titleMedium?.copyWith(
                  color: theme.primaryColor,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Center(
            child: Text(
              _todayLabel(),
              style: theme.textTheme.bodySmall?.copyWith(color: Colors.grey[600]),
            ),
          ),
          const SizedBox(height: 20),
          // Prompt + description
          Text(
            prompt,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w600,
              height: 1.3,
            ),
          ),
          if (description != null && description.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(description, style: theme.textTheme.bodyMedium),
          ],
          const SizedBox(height: 24),
          // Inline per-type input (extracted, proven in the overlay).
          QotdAnswerInput(
            question: question,
            onChanged: (value) => setState(() => _answerValue = value),
            onCommit: _onAnswerCommitted,
          ),
          const SizedBox(height: 24),
          // Submit + the per-answer close-friend choice on one row. The toggle
          // renders nothing until the user has a close friend.
          Row(
            children: [
              Expanded(
                child: AnimatedSubmitButton(
                  controller: _submitButtonController,
                  onPressed: _canSubmit ? _onSubmitPressed : null,
                  isLoading: _isSubmitting,
                  buttonText: 'Submit response',
                  disabledText: _questionType == 'text'
                      ? 'Type your answer'
                      : 'Select an option',
                ),
              ),
              ShareWithCloseFriendsToggle(
                value: _shareWithCloseFriends,
                enabled: !_isSubmitting,
                onChanged: (v) => setState(() => _shareWithCloseFriends = v),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildAnswered(BuildContext context) {
    final theme = Theme.of(context);
    final question = widget.question!;
    final prompt = question['prompt']?.toString() ?? '';
    final description = question['description']?.toString();
    final storedAnswer = _storedAnswer();

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      padding: const EdgeInsets.all(20),
      // Shared with "Your network" below (results_surface.dart): teal outline
      // in dark mode, grey in light.
      decoration: homeCardDecoration(theme),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            prompt,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w600,
              height: 1.3,
            ),
            textAlign: TextAlign.center,
          ),
          if (description != null && description.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              description,
              style: theme.textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
          ],
          // No own-answer pill here — the results rows below already mark
          // "(your answer)" / the "you" chip.
          // Inline results + response dot map — no tap required, and each half
          // collapses to nothing on a fetch failure. Shared with the onboarding
          // QOTD slide, which shows the same view after a guest answers.
          QotdResultsPreview(
            question: question,
            storedAnswer: storedAnswer,
            refreshNonce: widget.refreshNonce,
          ),
          const SizedBox(height: 16),
          // Free-emoji reactions (WP-D): the compact control — top 3 + an add
          // affordance. Fetches once on mount; no polling.
          _buildReactions(context, question),
          const SizedBox(height: 16),
          _buildCommentButton(context, question),
          // No sharing switch here any more: the close-friend choice is made
          // per answer, before submitting (see ShareWithCloseFriendsToggle in
          // _buildAsk). The old profile-wide switch lived here and was both too
          // late and too broad.
          const SizedBox(height: 8),
          _buildThanksFooter(context),
          // "Your network" is drawn by the home screen, below this card, so
          // it gets the page's full width (owner, 2026-09-22).
        ],
      ),
    );
  }

  /// Compact reaction row for the answered card: the question's top reactions
  /// with counts plus the "add" affordance, reusing the results-screen control
  /// in compact mode (WP-D). Guests can see them; reacting prompts for auth via
  /// the service's own error path.
  Widget _buildReactions(BuildContext context, Map<String, dynamic> question) {
    final questionId = question['id']?.toString();
    if (questionId == null) return const SizedBox.shrink();
    return Align(
      alignment: Alignment.centerRight,
      child: QuestionReactionsWidget(
        // Keyed by question id (midnight rollover) and the refresh nonce
        // (pull-to-refresh) so both refetch.
        key: ValueKey('qotd-reactions-$questionId-${widget.refreshNonce}'),
        questionId: questionId,
        compact: true,
      ),
    );
  }

  /// Comment-aware primary action. Navigates to the same results screen that
  /// "See full results" did (where comments live); only the label + icon change
  /// with the QOTD's comment count.
  Widget _buildCommentButton(BuildContext context, Map<String, dynamic> question) {
    final theme = Theme.of(context);
    final spec = qotdCommentButtonSpec(commentCountOf(widget.question));
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        onPressed: () => _navigateToResults(question),
        icon: Icon(
          spec.hasComments ? Icons.mode_comment_outlined : Icons.add_comment_outlined,
          size: 20,
        ),
        label: Text(
          spec.label,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
        ),
        style: ElevatedButton.styleFrom(
          padding: const EdgeInsets.symmetric(vertical: 14),
          backgroundColor: theme.primaryColor,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
          ),
        ),
      ),
    );
  }

  Widget _buildThanksFooter(BuildContext context) {
    final theme = Theme.of(context);
    final style =
        theme.textTheme.bodyMedium?.copyWith(color: Colors.grey[600]);
    // Personalised when a chameleon name exists (backlog item 7), else the
    // original copy. The handle ALWAYS starts its own line after the comma
    // (2026-09-19), whatever its length; the heart stays inline after the name.
    // Rich text rather than a Row, so a very long handle still wraps instead of
    // overflowing the card.
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: thanksForContributingText(
              context.watch<ProfileService>().username,
              breakAfterComma: true,
            ),
          ),
          const TextSpan(text: ' '),
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: Icon(Icons.favorite, size: 15, color: Colors.grey[600]),
          ),
        ],
      ),
      textAlign: TextAlign.center,
      softWrap: true,
      style: style,
    );
  }

}
