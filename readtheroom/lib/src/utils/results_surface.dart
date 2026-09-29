// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// One surface colour for every section of a results page (owner, 2026-09-22):
//
//   light — the theme's card colour (white), so the ego graph sits on the same
//           white as the numbers, the map and the comments;
//   dark  — the ego graph's tone (4 % white over the page background), so the
//           other sections match the graph instead of the other way round.
//
// `resultsTheme` re-points the card colour in dark mode so every plain `Card`
// on a results page picks the tone up without touching each screen.

import 'package:flutter/material.dart';

/// The colour every results-page section is painted in.
Color resultsSectionColor(ThemeData theme) {
  if (theme.brightness == Brightness.dark) {
    return Color.alphaBlend(
        Colors.white.withOpacity(0.04), theme.scaffoldBackgroundColor);
  }
  return theme.cardColor;
}

/// The section outline: the ego graph's thin teal line in dark mode, none in
/// light mode — so every section on a results page matches the graph exactly
/// (owner, 2026-09-22).
BoxBorder? resultsSectionBorder(ThemeData theme) {
  if (theme.brightness != Brightness.dark) return null;
  return Border.all(color: theme.primaryColor.withOpacity(0.18));
}

/// [theme] with its cards painted like the ego graph in dark mode (tone +
/// teal outline); unchanged in light mode (cards are already white and
/// borderless there).
ThemeData resultsTheme(ThemeData theme) {
  if (theme.brightness != Brightness.dark) return theme;
  final tone = resultsSectionColor(theme);
  return theme.copyWith(
    cardColor: tone,
    cardTheme: theme.cardTheme.copyWith(
      color: tone,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: theme.primaryColor.withOpacity(0.18)),
      ),
    ),
  );
}

/// The frame every card on the HOME page shares, so "Your network" matches the
/// answered question card above it (owner, 2026-09-22): the question card's
/// grey gradient in both modes; a grey outline in light mode, the ego graph's
/// teal outline in dark mode.
BoxDecoration homeCardDecoration(ThemeData theme) {
  final isDark = theme.brightness == Brightness.dark;
  return BoxDecoration(
    gradient: LinearGradient(
      colors: [
        Colors.grey.withOpacity(0.12),
        Colors.grey.withOpacity(0.05),
      ],
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
    ),
    borderRadius: BorderRadius.circular(16),
    border: Border.all(
      color: isDark
          ? theme.primaryColor.withOpacity(0.18)
          : Colors.grey.withOpacity(0.3),
    ),
  );
}
