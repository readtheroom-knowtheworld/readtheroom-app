// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Utility class for home screen widget streak calculations.
///
/// Defines Curio emotion states and color logic based on streak status
/// and time remaining in the day.
library;

/// Curio emotion states for the home screen widget.
enum CurioState {
  happy,    // Answered today, streak safe
  neutral,  // Has streak, > 8 hours remaining, hasn't answered today
  sad,      // Has streak, 3-8 hours remaining
  angry,    // Has streak, 1-3 hours remaining
  critical, // Has streak, < 1 hour remaining (dread Curio, red background)
  dread,    // No streak (0 days)
}

/// Utility methods for widget streak calculations.
class StreakWidgetUtils {
  // Color constants matching home_screen.dart
  static const int colorTeal = 0xFF00897B;    // Primary - safe
  static const int colorOrange = 0xFFEA6D32;  // Warning - 3-8 hours
  static const int colorRed = 0xFF951414;     // Urgent - < 3 hours
  static const int colorGrey = 0xFF9E9E9E;    // No streak

  /// Determines the Curio emotion state based on streak status.
  ///
  /// Logic matches the streak card in home_screen.dart:
  /// - If no streak (0 days) → dread (grey)
  /// - If answered today → happy (teal)
  /// - If < 1 hour remaining → critical (dread Curio, red background)
  /// - If 1-3 hours remaining → angry (red)
  /// - If 3-8 hours remaining → sad (orange)
  /// - Otherwise → neutral (teal)
  static CurioState getCurioState({
    required int streakCount,
    required bool hasExtendedToday,
    required double hoursRemaining,
  }) {
    if (streakCount == 0) return CurioState.dread;
    if (hasExtendedToday) return CurioState.happy;
    if (hoursRemaining < 1) return CurioState.critical;
    if (hoursRemaining < 3) return CurioState.angry;
    if (hoursRemaining < 8) return CurioState.sad;
    return CurioState.neutral;
  }

  /// Returns the widget color hex value based on Curio state.
  ///
  /// Colors match _getStreakCardColor() in home_screen.dart.
  static int getWidgetColorHex(CurioState state) {
    switch (state) {
      case CurioState.happy:
      case CurioState.neutral:
        return colorTeal;
      case CurioState.sad:
        return colorOrange;
      case CurioState.angry:
      case CurioState.critical:
        return colorRed;
      case CurioState.dread:
        return colorGrey;
    }
  }

  /// Calculates hours remaining until end of day (11:59:59 PM local time).
  static double getHoursRemainingToday() {
    final now = DateTime.now();
    final endOfDay = DateTime(now.year, now.month, now.day, 23, 59, 59);
    return endOfDay.difference(now).inMinutes / 60.0;
  }

  /// Returns the asset name for the given Curio state.
  ///
  /// Asset names should match files in:
  /// - Android: res/drawable/curio_*.png
  /// - iOS: Assets.xcassets/Curio_*.imageset
  static String getCurioAssetName(CurioState state) {
    switch (state) {
      case CurioState.happy:
        return 'curio_happy';
      case CurioState.neutral:
        return 'curio_neutral';
      case CurioState.sad:
        return 'curio_sad';
      case CurioState.angry:
        return 'curio_angry';
      case CurioState.critical:
      case CurioState.dread:
        return 'curio_dread';
    }
  }
}
