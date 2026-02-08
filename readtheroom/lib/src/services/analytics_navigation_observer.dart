// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'analytics_service.dart';

/// Custom navigation observer that tracks screen views with proper names
/// This replaces PostHog's generic observer to provide better event names
class AnalyticsNavigationObserver extends NavigatorObserver {
  final AnalyticsService _analytics = AnalyticsService();

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPush(route, previousRoute);
    _trackScreenView(route);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
    if (newRoute != null) {
      _trackScreenView(newRoute);
    }
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPop(route, previousRoute);
    if (previousRoute != null) {
      _trackScreenView(previousRoute);
    }
  }

  void _trackScreenView(Route<dynamic> route) {
    String screenName = _getScreenName(route);
    
    if (screenName.isNotEmpty) {
      _analytics.trackScreenView(screenName, {
        'route_name': route.settings.name ?? 'unnamed',
        'is_named_route': route.settings.name != null,
      });
    }
  }

  String _getScreenName(Route<dynamic> route) {
    // First, try to get the screen name from route settings
    if (route.settings.name != null && route.settings.name!.isNotEmpty) {
      return route.settings.name!;
    }

    // If no named route, try to infer from the widget type
    if (route is MaterialPageRoute) {
      try {
        final widget = route.builder(route.navigator!.context);
        return _getScreenNameFromWidget(widget);
      } catch (e) {
        // If we can't build the widget, fallback to a generic name
        return 'Unknown Screen';
      }
    }

    return 'Unknown Route';
  }

  String _getScreenNameFromWidget(Widget widget) {
    final widgetType = widget.runtimeType.toString();
    
    // Map widget types to user-friendly screen names
    switch (widgetType) {
      case 'AnswerTextScreen':
        return 'Answer Text Screen';
      case 'AnswerMultipleChoiceScreen':
        return 'Answer Multiple Choice Screen';
      case 'AnswerApprovalScreen':
        return 'Answer Approval Screen';
      case 'TextResultsScreen':
        return 'Text Results Screen';
      case 'MultipleChoiceResultsScreen':
        return 'Multiple Choice Results Screen';
      case 'ApprovalResultsScreen':
        return 'Approval Results Screen';
      case 'ReportQuestionScreen':
        return 'Report Question Screen';
      case 'QuestionPreviewScreen':
        return 'Question Preview Screen';
      case 'SuggestionDetailScreen':
        return 'Suggestion Detail Screen';
      case 'UserScreen':
        return 'User Profile Screen';
      case 'AuthenticationScreen':
        return 'Authentication Screen';
      case 'MainScreen':
        return 'Main Screen';
      case 'HomeScreen':
        return 'Home Screen';
      case 'NewQuestionScreen':
        return 'New Question Screen';
      case 'GuideScreen':
        return 'Guide Screen';
      case 'SettingsScreen':
        return 'Settings Screen';
      case 'FeedbackScreen':
        return 'Feedback Screen';
      case 'AboutScreen':
        return 'About Screen';
      case 'PlatformStatsScreen':
        return 'Platform Stats Screen';
      default:
        // Convert CamelCase to readable format
        return _camelCaseToReadable(widgetType);
    }
  }

  String _camelCaseToReadable(String camelCase) {
    // Convert CamelCase to "Camel Case Screen" format
    final result = camelCase.replaceAllMapped(
      RegExp(r'([A-Z])'),
      (match) => ' ${match.group(1)}',
    ).trim();
    
    // Ensure it ends with "Screen" if it doesn't already
    if (!result.endsWith('Screen')) {
      return '$result Screen';
    }
    
    return result;
  }
}