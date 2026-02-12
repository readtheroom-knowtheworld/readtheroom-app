// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/question_rating_service.dart';
import '../services/temporary_review_filter_notifier.dart';
import '../services/temporary_category_filter_notifier.dart';

class ReviewTagNavigation {
  static const chipLabels = {
    'unclear_phrasing': 'unclear phrasing',
    'biased': 'biased',
    'repetitive': 'repetitive',
    'bad_answer_options': 'bad answer options',
    'thought_provoking': 'thought-provoking',
    'well_posed': 'well-posed',
    'relatable': 'relatable',
    'original': 'original',
  };

  static const positiveChips = [
    'thought_provoking',
    'well_posed',
    'relatable',
    'original',
  ];

  static const negativeChips = [
    'unclear_phrasing',
    'biased',
    'repetitive',
    'bad_answer_options',
  ];

  static Future<void> onReviewTagChipTap(BuildContext context, String tagKey) async {
    // Show loading dialog
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );

    try {
      final ratingService = QuestionRatingService();
      final ids = await ratingService.getQuestionIdsForTopTag(tagKey);

      if (!context.mounted) return;

      // Dismiss loading dialog
      Navigator.of(context).pop();

      // Clear any active category filter (mutually exclusive)
      final categoryNotifier = Provider.of<TemporaryCategoryFilterNotifier>(context, listen: false);
      categoryNotifier.setTemporaryCategoryFilter(null);

      // Set review filter
      final reviewNotifier = Provider.of<TemporaryReviewFilterNotifier>(context, listen: false);
      reviewNotifier.setTemporaryReviewFilter(tagKey, questionIds: ids);

      // Navigate back to home
      Navigator.popUntil(context, (route) => route.isFirst);
    } catch (e) {
      if (!context.mounted) return;
      Navigator.of(context).pop(); // dismiss loading
      print('Error navigating to review tag filter: $e');
    }
  }

  static Widget buildClickableReviewTagChip(
    BuildContext context,
    String tagKey,
    int count,
  ) {
    final primaryColor = Theme.of(context).primaryColor;

    return GestureDetector(
      onTap: () => onReviewTagChipTap(context, tagKey),
      child: Chip(
        label: Text(
          '${chipLabels[tagKey] ?? tagKey} ($count)',
          style: const TextStyle(fontSize: 12),
        ),
        backgroundColor: primaryColor.withOpacity(0.1),
        side: BorderSide(color: primaryColor.withOpacity(0.3)),
        visualDensity: VisualDensity.compact,
      ),
    );
  }
}
