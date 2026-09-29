// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'dart:async';

import '../../services/analytics_service.dart';
import '../../services/post_answer_prompts.dart';
import '../../services/pending_answer_service.dart';
import '../../services/question_service.dart';
import '../../services/user_service.dart';
import '../../utils/pending_qotd_answer.dart';
import '../animated_submit_button.dart';
import '../qotd_answer_input.dart';
import '../qotd_results_preview.dart';
import '../share_with_close_friends_toggle.dart';
import 'onboarding_notification_ask.dart';
import 'onboarding_slide.dart';

/// Onboarding slide 2 (WP-C3, decision D5): answer today's question *before*
/// signing up.
///
/// The answer cannot be written to `responses` here — the insert needs both an
/// authenticated user and a `city_id`, and neither exists yet (see
/// `pending_qotd_answer.dart`). So the submit stashes the answer via
/// [PendingAnswerService] and flips to the results view; the real insert
/// happens at the end of onboarding, once passkey and location are done.
///
/// After the answer the slide shows the *results* — the same inline
/// distribution, response map and count the home hero renders in its answered
/// state, via the shared [QotdResultsPreview]. Reading `responses` needs no
/// account (the results screens already render for guests), but the guest's own
/// answer is still only stashed, so the numbers are the world's **current**
/// results and do not yet include it; the copy says so, and the user's own
/// choice is marked with a "You: …" chip and highlighted in the distribution.
///
/// Beneath the results sits the one-tap notification ask
/// ([OnboardingNotificationAsk]) — the daily ritual has just been demonstrated,
/// which is the moment it is worth asking about the next drop. It is shown on
/// **every** answered path (there is one: [_submit] sets `_answered`, and the
/// answered branch of [_buildContent] always renders [_AnsweredResults], which
/// always includes the ask), it sits **above** the Continue button inside the
/// same scroll view, and it carries its own "Not now" — so getting past it is a
/// choice rather than an accidental tap. The copy explains why it matters: the
/// question drops at a random moment each day and the whole world answers it at
/// the same time, so there is no time to pick and nothing to schedule.
///
/// Skipping ("I'll answer later") is always allowed and never blocks the flow.
class QotdQuestionSlide extends StatefulWidget {
  const QotdQuestionSlide({
    Key? key,
    required this.onNext,
    this.retryDelay = const Duration(milliseconds: 500),
    this.maxAttempts = 20,
  }) : super(key: key);

  final VoidCallback onNext;

  /// Bounded retry for the cold-start null-QOTD window, mirroring HomeScreen.
  final Duration retryDelay;
  final int maxAttempts;

  @override
  State<QotdQuestionSlide> createState() => _QotdQuestionSlideState();
}

class _QotdQuestionSlideState extends State<QotdQuestionSlide> {
  Map<String, dynamic>? _question;
  bool _resolving = true;
  bool _unavailable = false;
  bool _submitting = false;
  bool _answered = false;
  String? _answerDisplay;
  QotdAnswerValue? _value;
  bool _notificationsEnabled = false;

  /// The per-answer close-friend flag for this answer (owner decision
  /// 2026-09-17). Default ON, and carried into the stash so the deferred insert
  /// at the end of onboarding writes the choice the guest actually made.
  bool _shareWithCloseFriends = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _resolve());
  }

  Future<void> _resolve() async {
    if (!mounted) return;
    setState(() {
      _resolving = true;
      _unavailable = false;
    });

    final questionService = context.read<QuestionService>();
    final userService = context.read<UserService>();

    Map<String, dynamic>? qotd;
    var attempts = 0;
    while (qotd == null && attempts < widget.maxAttempts) {
      qotd = await questionService.getQuestionOfTheDay(
        showNSFW: userService.showNSFWContent,
      );
      if (qotd != null) break;
      attempts++;
      await Future.delayed(widget.retryDelay);
      if (!mounted) return;
    }

    if (!mounted) return;
    setState(() {
      _question = qotd;
      _resolving = false;
      _unavailable = qotd == null;
    });

    // `qotd_prompted` is fired ONCE, by the page-mapped call in
    // `onboarding_screen._onPageChanged` (review 2026-09-22 P1-2). This slide
    // used to fire it a second time, doubling the funnel's widest step and
    // making every conversion rate below it look half as good as it is.
  }

  String _displayString(QotdAnswerValue value) {
    switch (value.questionType) {
      case 'approval_rating':
      case 'approval':
        final score = value.sliderValue;
        if (score > 0.3) return 'Approve';
        if (score < -0.3) return 'Disapprove';
        return 'Neutral';
      case 'multiplechoice':
      case 'multiple_choice':
        return value.selectedOption ?? '';
      case 'text':
        return value.text.trim();
      default:
        return '';
    }
  }

  Future<void> _submit() async {
    final value = _value;
    final question = _question;
    if (value == null || question == null || !value.canSubmit) return;

    setState(() => _submitting = true);
    final display = _displayString(value);

    // Stash + a short floor so the submit animation reads as an action.
    await Future.wait<void>([
      context.read<PendingAnswerService>().stash(
            PendingQotdAnswer(
              questionId: question['id'].toString(),
              questionType: value.questionType,
              capturedAt: DateTime.now(),
              sliderValue: value.sliderValue,
              selectedOption: value.selectedOption,
              text: value.text.trim(),
              displayAnswer: display,
              sharedWithCloseFriends: _shareWithCloseFriends,
            ),
          ),
      Future<void>.delayed(const Duration(milliseconds: 900)),
    ]);

    if (!mounted) return;
    setState(() {
      _submitting = false;
      _answered = true;
      _answerDisplay = display;
    });

    // No `question_id` (review 2026-09-19 P0-1): the guest who answers here
    // is merged into their account by the alias at sign-in, so an id on this
    // step is the same person<->answer join the answer events just lost.
    AnalyticsService().trackOnboardingStepCanonical(
      OnboardingStep.qotdAnswered,
      properties: {'question_type': value.questionType},
    );
    // The results view carries the notification ask, so it is prompted the
    // instant that view appears. `os_status` (review 2026-09-22 E1) makes this
    // step comparable with `post_answer_prompts`, which already sends it —
    // without it "the ask converts worse in onboarding" cannot be separated
    // from "more of those users had already granted".
    unawaited(_trackNotificationsPrompted());
  }

  Future<void> _trackNotificationsPrompted() async {
    String osStatus = 'unknown';
    try {
      osStatus = (await PostAnswerPrompts.osPermission()).name;
    } catch (e) {
      debugPrint('QotdQuestionSlide: could not read the OS status: $e');
    }
    await AnalyticsService().trackOnboardingStepCanonical(
      OnboardingStep.notificationsPrompted,
      properties: {'os_status': osStatus},
    );
  }

  /// The notification ask resolved. `notifications_skipped` is *not* fired here
  /// on a decline: the user may still flip the switch before advancing, so the
  /// skip is only recorded when the slide is actually left ([_advance]).
  void _onNotificationsResolved(bool enabled) {
    if (!enabled) return;
    _notificationsEnabled = true;
    AnalyticsService()
        .trackOnboardingStepCanonical(OnboardingStep.notificationsEnabled);
  }

  /// Leaving the answered slide. Records the notification outcome the user
  /// actually walked away with, then advances.
  void _advance() {
    if (!_notificationsEnabled) {
      AnalyticsService()
          .trackOnboardingStepCanonical(OnboardingStep.notificationsSkipped);
    }
    widget.onNext();
  }

  void _skip() {
    AnalyticsService()
        .trackOnboardingStepCanonical(OnboardingStep.qotdSkipped);
    widget.onNext();
  }

  @override
  Widget build(BuildContext context) {
    return OnboardingSlide(
      title: _answered ? 'Answer saved 🦎' : "Question of the Day",
      description: _answered
          ? "It'll be counted as soon as your account is ready — a few taps away."
          : 'Every day, a question drops at a random time worldwide. '
              "The first few who answer get to vote on tomorrow's question.",
      showCurio: false,
      // The advance button is the slide's own submit/continue control, so the
      // shared "Next" button is suppressed until there is nothing left to do.
      onNext: _answered ? _advance : null,
      buttonText: 'Continue',
      customContent: _buildContent(context),
    );
  }

  Widget _buildContent(BuildContext context) {
    final theme = Theme.of(context);

    if (_resolving) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 40),
        child: Center(child: CircularProgressIndicator()),
      );
    }

    if (_unavailable || _question == null) {
      // Never a dead end: a missing QOTD just moves the flow along.
      return Column(
        children: [
          Text(
            "Today's question is still waking up. You can answer it from the "
            'home screen in a moment.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(color: Colors.grey[600]),
          ),
          const SizedBox(height: 16),
          TextButton(onPressed: _resolve, child: const Text('Try again')),
          const SizedBox(height: 4),
          _skipButton(context, label: 'Continue'),
        ],
      );
    }

    final question = _question!;
    final prompt = question['prompt']?.toString() ?? '';

    if (_answered) {
      return _AnsweredResults(
        question: question,
        prompt: prompt,
        answer: _answerDisplay ?? '',
        onNotificationsResolved: _onNotificationsResolved,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: theme.primaryColor.withOpacity(0.07),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: theme.primaryColor.withOpacity(0.25)),
          ),
          child: Text(
            prompt,
            textAlign: TextAlign.center,
            style: theme.textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.w600, height: 1.4),
          ),
        ),
        // No close-friend toggle here: a guest has no close friends, so the
        // stashed answer simply carries the default (shared).
        const SizedBox(height: 20),
        QotdAnswerInput(
          question: question,
          onChanged: (value) => setState(() => _value = value),
        ),
        const SizedBox(height: 20),
        AnimatedSubmitButton(
          onPressed:
              (_value?.canSubmit ?? false) && !_submitting ? _submit : null,
          isLoading: _submitting,
          buttonText: 'Submit answer',
          disabledText: 'Pick your answer',
        ),
        const SizedBox(height: 8),
        _skipButton(context),
      ],
    );
  }

  Widget _skipButton(BuildContext context, {String label = "I'll answer later"}) {
    return TextButton(
      onPressed: _submitting ? null : _skip,
      child: Text(
        label,
        style: TextStyle(color: Colors.grey[600], fontWeight: FontWeight.w500),
      ),
    );
  }
}

/// The answered state: the question, the user's own answer, the world's
/// results so far, and the notification ask.
///
/// The results come from [QotdResultsPreview] — the same widget the home hero
/// renders — so the onboarding preview and the home card can never disagree
/// about how a distribution is drawn. The guest's own answer is *not* in those
/// numbers yet (it is stashed until the end of onboarding), which the footer
/// says plainly rather than quietly overstating the count by one.
class _AnsweredResults extends StatelessWidget {
  const _AnsweredResults({
    required this.question,
    required this.prompt,
    required this.answer,
    this.onNotificationsResolved,
  });

  final Map<String, dynamic> question;
  final String prompt;
  final String answer;
  final void Function(bool enabled)? onNotificationsResolved;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: theme.primaryColor.withOpacity(0.07),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: theme.primaryColor.withOpacity(0.25)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                prompt,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(height: 1.4),
              ),
              const SizedBox(height: 14),
              // The user's own answer, called out before the crowd's — the
              // distribution below also marks it, but only when it maps onto a
              // bucket/option (never for a free-text answer).
              Align(
                alignment: Alignment.center,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    color: theme.primaryColor,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    answer.isEmpty ? 'You: answered' : 'You: $answer',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              // "Results so far" + the distribution + the response map. Silent
              // (renders nothing) while loading, on failure, or with no answers.
              QotdResultsPreview(
                question: question,
                storedAnswer: answer,
                ownAnswerChipLabel: 'you',
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        OnboardingNotificationAsk(onResolved: onNotificationsResolved),
        const SizedBox(height: 12),
        Text(
          'These are the answers in so far — yours joins them as soon as your '
          'account is ready, a few taps away.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(color: Colors.grey[600]),
        ),
      ],
    );
  }
}
