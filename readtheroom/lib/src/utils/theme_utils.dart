// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';

class ThemeUtils {
  /// Returns theme-aware shadow for dropdown containers and elevated elements
  /// More prominent in dark mode for better visibility
  static List<BoxShadow> getDropdownShadow(BuildContext context) {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    
    return [
      BoxShadow(
        color: isDarkMode ? Colors.black.withValues(alpha: 0.5) : Colors.black26,
        blurRadius: isDarkMode ? 4 : 4,
        offset: Offset(0, isDarkMode ? 2 : 2),
      ),
    ];
  }
  
  /// Returns theme-aware shadow for card elements
  /// Subtle but visible in both light and dark modes
  static List<BoxShadow> getCardShadow(BuildContext context) {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    
    return [
      BoxShadow(
        color: isDarkMode ? Colors.black.withValues(alpha: 0.6) : Colors.black12,
        blurRadius: isDarkMode ? 4 : 3,
        offset: Offset(0, isDarkMode ? 2 : 1),
      ),
    ];
  }
  
  /// Returns theme-aware shadow for floating elements like FABs
  /// Strong shadow for prominent elevation
  static List<BoxShadow> getFloatingShadow(BuildContext context) {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    
    return [
      BoxShadow(
        color: isDarkMode ? Colors.black.withValues(alpha: 0.9) : Colors.black26,
        blurRadius: isDarkMode ? 8 : 6,
        offset: Offset(0, isDarkMode ? 4 : 3),
      ),
    ];
  }
  
  /// Returns theme-aware background color for dropdown containers
  /// Darker than surface color in dark mode for better contrast
  static Color getDropdownBackgroundColor(BuildContext context) {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    
    if (isDarkMode) {
      // Use pure black for maximum contrast against the dark theme background
      return Color(0xFF0A0A0A);
    } else {
      // Use standard card color in light mode
      return Theme.of(context).cardColor;
    }
  }
} 