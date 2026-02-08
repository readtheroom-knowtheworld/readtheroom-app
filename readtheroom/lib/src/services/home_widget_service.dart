// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

// lib/src/services/home_widget_service.dart
import 'package:home_widget/home_widget.dart';
import '../utils/streak_widget_utils.dart';
import 'analytics_service.dart';

/// Service for managing the home screen widget.
///
/// Updates the native home screen widget with streak data on iOS and Android.
/// Uses App Groups on iOS and SharedPreferences on Android for data sharing.
class HomeWidgetService {
  static final HomeWidgetService _instance = HomeWidgetService._internal();
  factory HomeWidgetService() => _instance;
  HomeWidgetService._internal();

  // App Group ID - must match iOS entitlements and Android config
  static const String _appGroupId = 'group.com.readtheroom.app';

  // Widget names - must match native widget identifiers
  static const String _androidWidgetName = 'StreakWidgetProvider';
  static const String _iOSWidgetName = 'StreakWidget';
  static const String _iOSLockScreenWidgetName = 'StreakLockScreenWidget';

  // QOTD Widget names (iOS uses StreakWidget for both - size-based layout)
  static const String _androidQOTDWidgetName = 'QOTDWidgetProvider';

  bool _isInitialized = false;

  /// Initialize the home widget service.
  /// Call this on app startup.
  Future<void> initialize() async {
    if (_isInitialized) return;

    try {
      await HomeWidget.setAppGroupId(_appGroupId);
      await HomeWidget.registerInteractivityCallback(backgroundCallback);
      _isInitialized = true;
      print('HomeWidgetService initialized');
    } catch (e) {
      print('Error initializing HomeWidgetService: $e');
    }
  }

  /// Update the widget with current streak data.
  ///
  /// Call this:
  /// - On app launch
  /// - After user answers a question
  /// - On home screen refresh
  Future<void> updateWidget({
    required int streakCount,
    required bool hasExtendedToday,
  }) async {
    try {
      if (!_isInitialized) {
        await initialize();
      }

      final hoursRemaining = StreakWidgetUtils.getHoursRemainingToday();
      final curioState = StreakWidgetUtils.getCurioState(
        streakCount: streakCount,
        hasExtendedToday: hasExtendedToday,
        hoursRemaining: hoursRemaining,
      );
      final colorHex = StreakWidgetUtils.getWidgetColorHex(curioState);

      // Save data to shared storage for native widget to read
      await HomeWidget.saveWidgetData('streak_count', streakCount);
      await HomeWidget.saveWidgetData('has_extended_today', hasExtendedToday);
      await HomeWidget.saveWidgetData('hours_remaining', hoursRemaining);
      await HomeWidget.saveWidgetData('curio_state', curioState.name);
      await HomeWidget.saveWidgetData('color_hex', colorHex);
      await HomeWidget.saveWidgetData(
        'last_updated',
        DateTime.now().toIso8601String(),
      );

      // Trigger widget update on both platforms
      await HomeWidget.updateWidget(
        androidName: _androidWidgetName,
        iOSName: _iOSWidgetName,
      );
      await HomeWidget.updateWidget(
        iOSName: _iOSLockScreenWidgetName,
      );

      print(
        'Widget updated: streak=$streakCount, state=${curioState.name}, '
        'hours=$hoursRemaining, color=0x${colorHex.toRadixString(16)}',
      );

      // Track widget uptake
      AnalyticsService().trackWidgetUpdated('streak', {
        'streak_count': streakCount,
        'has_extended_today': hasExtendedToday,
        'curio_state': curioState.name,
      });
    } catch (e) {
      print('Error updating home widget: $e');
    }
  }

  /// Background callback for widget interactions.
  /// This is called when the widget is tapped.
  @pragma('vm:entry-point')
  static Future<void> backgroundCallback(Uri? uri) async {
    if (uri?.host == 'openapp' || uri?.host == 'home') {
      // Widget was tapped - the deep link handler will open the app
      print('Widget tapped: $uri');
    }
  }

  /// Force refresh the widget.
  /// Useful when the app resumes from background.
  Future<void> refreshWidget() async {
    try {
      await HomeWidget.updateWidget(
        androidName: _androidWidgetName,
        iOSName: _iOSWidgetName,
      );
      await HomeWidget.updateWidget(
        iOSName: _iOSLockScreenWidgetName,
      );
    } catch (e) {
      print('Error refreshing home widget: $e');
    }
  }

  /// Update the QOTD widget with current question data.
  Future<void> updateQOTDWidget({
    required String questionText,
    required int voteCount,
    required int commentCount,
    required bool hasAnswered,
    required String questionId,
  }) async {
    try {
      if (!_isInitialized) {
        await initialize();
      }

      // Save data to shared storage for native widget to read
      await HomeWidget.saveWidgetData('qotd_question_text', questionText);
      await HomeWidget.saveWidgetData('qotd_vote_count', voteCount);
      await HomeWidget.saveWidgetData('qotd_comment_count', commentCount);
      await HomeWidget.saveWidgetData('qotd_has_answered', hasAnswered);
      await HomeWidget.saveWidgetData('qotd_question_id', questionId);
      await HomeWidget.saveWidgetData(
        'qotd_last_updated',
        DateTime.now().toIso8601String(),
      );

      // Update widgets on both platforms
      // iOS: StreakWidget handles QOTD in medium size (size-based layout)
      await HomeWidget.updateWidget(
        androidName: _androidQOTDWidgetName,
        iOSName: _iOSWidgetName,
      );

      print(
        'QOTD Widget updated: question=${questionText.substring(0, questionText.length > 30 ? 30 : questionText.length)}..., '
        'votes=$voteCount, comments=$commentCount, answered=$hasAnswered',
      );

      // Track widget uptake
      AnalyticsService().trackWidgetUpdated('qotd', {
        'question_id': questionId,
        'has_answered': hasAnswered,
      });
    } catch (e) {
      print('Error updating QOTD widget: $e');
    }
  }

  /// Force refresh the QOTD widget.
  Future<void> refreshQOTDWidget() async {
    try {
      // iOS: StreakWidget handles QOTD in medium size
      await HomeWidget.updateWidget(
        androidName: _androidQOTDWidgetName,
        iOSName: _iOSWidgetName,
      );
    } catch (e) {
      print('Error refreshing QOTD widget: $e');
    }
  }
}
