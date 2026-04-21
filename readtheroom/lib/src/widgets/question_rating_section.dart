// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../services/user_service.dart';
import '../services/question_rating_service.dart';
import '../utils/review_tag_navigation.dart';
import 'rating_distribution_chart.dart';

/// Displays the rating distribution + top review tags for a question.
/// Rating/tag *submission* lives in [AddCommentDialog]; this widget only
/// renders results, and only when the viewer is eligible to see them
/// (rated the question, is the author, or is unauthenticated).
class QuestionRatingSection extends StatefulWidget {
  final String questionId;
  final bool isAuthor;

  const QuestionRatingSection({
    Key? key,
    required this.questionId,
    required this.isAuthor,
  }) : super(key: key);

  @override
  State<QuestionRatingSection> createState() => _QuestionRatingSectionState();
}

class _QuestionRatingSectionState extends State<QuestionRatingSection> {
  final _ratingService = QuestionRatingService();
  bool _loading = true;
  Map<String, int> _distribution = {};
  Map<String, int> _tagCounts = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final results = await Future.wait([
      _ratingService.getRatingDistribution(widget.questionId),
      _ratingService.getReviewTagCounts(widget.questionId),
    ]);
    if (!mounted) return;
    setState(() {
      _distribution = results[0];
      _tagCounts = results[1];
      _loading = false;
    });
  }

  bool get _shouldShow {
    final isAuthenticated =
        Supabase.instance.client.auth.currentUser != null;
    if (widget.isAuthor || !isAuthenticated) return true;
    final userService = Provider.of<UserService>(context);
    return userService.hasRatedQuestion(widget.questionId);
  }

  @override
  Widget build(BuildContext context) {
    if (!_shouldShow) return const SizedBox.shrink();
    if (_loading) return const SizedBox.shrink();

    final total = _distribution.values.fold<int>(0, (a, b) => a + b);
    if (total == 0) return const SizedBox.shrink();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Question Rating',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            RatingDistributionChart(distribution: _distribution),
            if (_tagCounts.isNotEmpty) ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: _tagCounts.entries.take(3).map((entry) {
                  return ReviewTagNavigation.buildClickableReviewTagChip(
                    context,
                    entry.key,
                    entry.value,
                  );
                }).toList(),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
