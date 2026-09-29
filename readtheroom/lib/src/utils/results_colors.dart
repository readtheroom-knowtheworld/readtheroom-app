// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';

/// Centralised colour definitions for all results views (approval histograms,
/// average bars, choropleth maps, multiple-choice bars and maps).
///
/// All colours are fully opaque so they render correctly in both light and
/// dark mode — no `withOpacity()` is used.
class ResultsColors {
  ResultsColors._();

  // ---------------------------------------------------------------------------
  // Approval sentiment – discrete colours
  // ---------------------------------------------------------------------------

  static Color stronglyDisapprove(BuildContext context) =>
      const Color(0xFFD32F2F);

  static Color disapprove(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return isDark ? const Color(0xFFE57373) : const Color(0xFFEF5350);
  }

  static Color neutral(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // Light mode: shade300 was near-invisible on light surfaces (a neutral
    // dot read as a hollow ring); shade500 keeps it clearly a filled dot.
    return isDark ? Colors.grey.shade600 : Colors.grey.shade500;
  }

  static Color approve(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primary = Theme.of(context).primaryColor;
    // Opaque mid-teal: lerp between a light tint and full primary
    return isDark
        ? Color.lerp(primary, const Color(0xFF80CBC4), 0.50)!
        : Color.lerp(const Color(0xFFB2DFDB), primary, 0.45)!;
  }

  static Color stronglyApprove(BuildContext context) =>
      Theme.of(context).primaryColor;

  /// Look up a discrete approval colour by label string.
  static Color forApprovalLabel(BuildContext context, String label) {
    switch (label) {
      case 'Strongly Disapprove':
        return stronglyDisapprove(context);
      case 'Disapprove':
        return disapprove(context);
      case 'Neutral':
        return neutral(context);
      case 'Approve':
        return approve(context);
      case 'Strongly Approve':
        return stronglyApprove(context);
      default:
        return neutral(context);
    }
  }

  // ---------------------------------------------------------------------------
  // Approval sentiment – continuous interpolation for average bars / maps
  // ---------------------------------------------------------------------------

  /// Returns an opaque colour for a continuous approval value in [-1, 1].
  static Color forApprovalValue(BuildContext context, double value) {
    if (value <= -0.3) {
      final t = ((value - (-1)) / ((-0.3) - (-1))).clamp(0.0, 1.0);
      return Color.lerp(stronglyDisapprove(context), disapprove(context), t)!;
    } else if (value <= 0.3) {
      return neutral(context);
    } else {
      final t = ((value - 0.3) / (1.0 - 0.3)).clamp(0.0, 1.0);
      return Color.lerp(approve(context), stronglyApprove(context), t)!;
    }
  }

  /// Discrete 5-bucket version used by maps and simple charts.
  static Color forApprovalBucket(BuildContext context, double value) {
    if (value <= -0.8) return stronglyDisapprove(context);
    if (value <= -0.3) return disapprove(context);
    if (value <= 0.3) return neutral(context);
    if (value <= 0.8) return approve(context);
    return stronglyApprove(context);
  }

  /// Ordered list of 5 bin colours matching the order:
  /// strongly_disapprove, disapprove, neutral, approve, strongly_approve.
  static List<Color> approvalBinColors(BuildContext context) => [
        stronglyDisapprove(context),
        disapprove(context),
        neutral(context),
        approve(context),
        stronglyApprove(context),
      ];

  // ---------------------------------------------------------------------------
  // Approval sentiment – icons
  // ---------------------------------------------------------------------------

  static Widget iconForApprovalLabel(
    BuildContext context,
    String label, {
    double size = 20,
  }) {
    switch (label) {
      case 'Strongly Disapprove':
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.thumb_down, color: stronglyDisapprove(context), size: size),
            SizedBox(width: 2),
            Icon(Icons.thumb_down, color: stronglyDisapprove(context), size: size),
          ],
        );
      case 'Disapprove':
        return Icon(Icons.thumb_down, color: disapprove(context), size: size);
      case 'Neutral':
        return Icon(Icons.sentiment_neutral, color: Colors.grey[600], size: size);
      case 'Approve':
        return Icon(Icons.thumb_up, color: approve(context), size: size);
      case 'Strongly Approve':
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.thumb_up, color: stronglyApprove(context), size: size),
            SizedBox(width: 2),
            Icon(Icons.thumb_up, color: stronglyApprove(context), size: size),
          ],
        );
      default:
        return Icon(Icons.sentiment_neutral, color: neutral(context), size: size);
    }
  }

  // ---------------------------------------------------------------------------
  // Multiple choice colours
  // ---------------------------------------------------------------------------

  static List<Color> multipleChoiceColors(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return isDark
        ? const [
            Color(0xFF42A5F5), // Blue
            Color(0xFFFFB74D), // Amber
            Color(0xFFCE93D8), // Purple
            Color(0xFF4DD0E1), // Cyan
            Color(0xFFEF5350), // Red
            Color(0xFF9CCC65), // Lime
            Color(0xFFBCAAA4), // Brown
            Color(0xFF90A4AE), // Blue Grey
          ]
        : const [
            Color(0xFF1976D2), // Blue
            Color(0xFFF57C00), // Amber
            Color(0xFF7B1FA2), // Purple
            Color(0xFF00838F), // Cyan
            Color(0xFFC62828), // Red
            Color(0xFF558B2F), // Lime
            Color(0xFF4E342E), // Brown
            Color(0xFF37474F), // Blue Grey
          ];
  }

  static Color forOptionIndex(BuildContext context, int index) {
    final colors = multipleChoiceColors(context);
    return colors[index % colors.length];
  }
}
