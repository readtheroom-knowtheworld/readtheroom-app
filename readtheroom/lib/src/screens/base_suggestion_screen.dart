// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import '../widgets/swipe_navigation_wrapper.dart';

// Context for suggestion feeds - similar to FeedContext for questions
class SuggestionFeedContext {
  final List<Map<String, dynamic>> suggestions;
  final String feedType;
  final String? searchQuery;
  final String? sortBy;
  
  const SuggestionFeedContext({
    required this.suggestions,
    required this.feedType,
    this.searchQuery,
    this.sortBy,
  });
}

abstract class BaseSuggestionScreen extends StatefulWidget {
  final Map<String, dynamic> suggestion;
  final SuggestionFeedContext? feedContext;
  final bool fromSearch;
  final bool fromUserScreen;
  final bool isGuestMode;

  const BaseSuggestionScreen({
    Key? key,
    required this.suggestion,
    this.feedContext,
    this.fromSearch = false,
    this.fromUserScreen = false,
    this.isGuestMode = false,
  }) : super(key: key);
}

abstract class BaseSuggestionScreenState<T extends BaseSuggestionScreen> extends State<T> {
  // Use SwipeNavigationWrapper for consistent swipe behavior if in feed context
  @override
  Widget build(BuildContext context) {
    if (widget.feedContext != null) {
      return SwipeNavigationWrapper(
        feedContext: null, // We'll handle suggestion navigation separately
        currentQuestion: null,
        fromSearch: widget.fromSearch,
        fromUserScreen: widget.fromUserScreen,
        enableLeftSwipe: true, // Enable left swipe to next suggestion
        enableRightSwipe: true, // Enable right swipe to previous suggestion
        enablePullToGoBack: true, // Enable pull-down to go back
        child: buildSuggestionScreen(context),
      );
    } else {
      return buildSuggestionScreen(context);
    }
  }

  // Abstract method to be implemented by child classes
  Widget buildSuggestionScreen(BuildContext context);
}