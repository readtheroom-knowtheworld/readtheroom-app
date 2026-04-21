// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/user_service.dart';
import '../services/question_service.dart';
import '../services/analytics_service.dart';
import 'answer_approval_screen.dart';
import 'answer_multiple_choice_screen.dart';
import '../widgets/swipe_navigation_wrapper.dart';

abstract class BaseResultsScreen extends StatefulWidget {
  final Map<String, dynamic> question;
  final List<Map<String, dynamic>> responses;
  final FeedContext? feedContext;
  final bool fromSearch;
  final bool fromUserScreen;
  final bool isGuestMode;

  const BaseResultsScreen({
    Key? key,
    required this.question,
    required this.responses,
    this.feedContext,
    this.fromSearch = false,
    this.fromUserScreen = false,
    this.isGuestMode = false,
  }) : super(key: key);
}

abstract class BaseResultsScreenState<T extends BaseResultsScreen> extends State<T> {
  @override
  void initState() {
    super.initState();
    AnalyticsService().trackQuestionResultsViewed(
      widget.question['type']?.toString() ?? 'unknown',
    );
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
      child: buildResultsScreen(context),
    );
  }

  // Abstract method to be implemented by child classes
  Widget buildResultsScreen(BuildContext context);
} 