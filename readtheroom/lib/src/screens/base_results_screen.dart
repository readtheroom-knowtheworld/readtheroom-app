// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/question_results.dart';
import '../services/user_service.dart';
import '../services/question_service.dart';
import '../services/analytics_service.dart';
import '../services/post_answer_prompts.dart';
import 'answer_approval_screen.dart';
import 'answer_multiple_choice_screen.dart';
import '../utils/results_surface.dart';
import '../widgets/swipe_navigation_wrapper.dart';

abstract class BaseResultsScreen extends StatefulWidget {
  final Map<String, dynamic> question;

  /// The server-computed results for this question.
  ///
  /// Replaces the old `responses` row list: since the answers read lockdown
  /// (2026-09-22) a results screen is handed counts, averages and histograms,
  /// never the answers behind them. Null means "not fetched yet" — the screen
  /// loads its own and shows an empty state meanwhile.
  final QuestionResults? results;

  final FeedContext? feedContext;
  final bool fromSearch;
  final bool fromUserScreen;
  final bool isGuestMode;

  const BaseResultsScreen({
    Key? key,
    required this.question,
    this.results,
    this.feedContext,
    this.fromSearch = false,
    this.fromUserScreen = false,
    this.isGuestMode = false,
  }) : super(key: key);
}

abstract class BaseResultsScreenState<T extends BaseResultsScreen> extends State<T> {
  /// The results this screen was handed, or an empty set when it was handed
  /// none — so every getter below can read a breakdown without a null check.
  QuestionResults get initialResults =>
      widget.results ??
      QuestionResults.emptyFor(
        widget.question['id']?.toString() ?? '',
        widget.question['type']?.toString() ?? '',
      );

  @override
  void initState() {
    super.initState();
    AnalyticsService().trackQuestionResultsViewed(
      widget.question['type']?.toString() ?? 'unknown',
    );

    // The post-answer notification ask for every answer that went through a full
    // answer screen — the Archive, a deep link, search, the user screen. Those
    // screens `pushReplacement` straight into this one, so the results reveal is
    // the first settled surface after the submit; showing the prompt in the
    // answer screen would have raced its own teardown.
    //
    // A no-op unless `addAnsweredQuestion` recorded a QOTD answer, so merely
    // revisiting an old result never prompts. `PostAnswerPrompts` adds its own
    // delay so the reveal is visible first.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      await PostAnswerPrompts.maybeShow(
        context,
        userService: Provider.of<UserService>(context, listen: false),
        source: 'results_screen',
      );
    });
  }

  // Use SwipeNavigationWrapper for consistent swipe behavior
  @override
  Widget build(BuildContext context) {
    return SwipeNavigationWrapper(
      feedContext: widget.feedContext,
      currentQuestion: widget.question,
      fromSearch: widget.fromSearch,
      fromUserScreen: widget.fromUserScreen,
      enableLeftSwipe: true, // Enable left swipe to next question from results screens
      enableRightSwipe: true, // Enable right swipe to previous question from results screens
      enablePullToGoBack: true, // Enable pull-down to go home
      // Every section on a results page shares one surface colour (see
      // results_surface.dart): in dark mode the cards take the ego graph's
      // tone. The Builder hands the subclass a context under that theme.
      child: Theme(
        data: resultsTheme(Theme.of(context)),
        child: Builder(builder: (inner) => buildResultsScreen(inner)),
      ),
    );
  }

  // Abstract method to be implemented by child classes
  Widget buildResultsScreen(BuildContext context);
} 