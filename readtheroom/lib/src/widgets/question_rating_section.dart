// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../services/analytics_service.dart';
import '../services/user_service.dart';
import '../services/question_rating_service.dart';
import '../utils/review_tag_navigation.dart';
import 'approval_slider.dart';
import 'rating_distribution_chart.dart';

/// Question rating on the results screens — now the *only* place a rating is
/// collected (the mandatory pre-comment gate was removed on 2026-09-11).
///
/// Three stages, all voluntary:
///   1. **Slider** — signed-in, non-author viewers who haven't rated see an
///      optional "What did you think?" slider. Releasing it submits.
///   2. **Tags** — after a non-neutral rating, "What stood out?" chips with
///      Skip / Continue. Neutral ratings skip straight to results.
///   3. **Results** — distribution chart + top-3 clickable review tags, shown
///      to authors, signed-out viewers, and anyone who has rated. Hidden when
///      nobody has rated yet.
///
/// Ratings stay anonymous (no user_id on `question_ratings`); "has rated" is
/// tracked locally in [UserService], as before.
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

enum _Stage { slider, tags, results }

class _QuestionRatingSectionState extends State<QuestionRatingSection> {
  final _ratingService = QuestionRatingService();
  bool _loading = true;
  Map<String, int> _distribution = {};
  Map<String, int> _tagCounts = {};

  _Stage? _stage; // resolved lazily once providers are available
  double _ratingValue = 0.0;
  bool _isSubmittingRating = false;
  final Set<String> _selectedTags = {};

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

  bool get _isAuthenticated =>
      Supabase.instance.client.auth.currentUser != null;

  /// Whether this viewer may still leave a rating: signed in, not the author,
  /// and no local record of having rated.
  bool _canRate(BuildContext context) {
    if (widget.isAuthor || !_isAuthenticated) return false;
    final userService = Provider.of<UserService>(context, listen: false);
    return !userService.hasRatedQuestion(widget.questionId);
  }

  List<String> get _availableChips {
    if (_ratingValue <= -0.3) return ReviewTagNavigation.negativeChips;
    return ReviewTagNavigation.positiveChips;
  }

  Future<void> _onSliderReleased(double value) async {
    if (_isSubmittingRating) return;
    setState(() {
      _isSubmittingRating = true;
      _ratingValue = value;
    });

    final submitted =
        await _ratingService.submitRating(widget.questionId, _ratingValue);

    if (submitted && mounted) {
      final userService = Provider.of<UserService>(context, listen: false);
      await userService.setQuestionRating(widget.questionId, _ratingValue);
    }
    if (!mounted) return;

    if (!submitted) {
      // Server refused (network, RLS, duplicate). Stay on the slider so the
      // local "rated" flag never runs ahead of the server — see the 2026-02-09
      // rating-desync fix.
      setState(() => _isSubmittingRating = false);
      AnalyticsService().trackRpcFailed('submit_rating');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text("Couldn't save your rating. Try again."),
          backgroundColor: Theme.of(context).primaryColor,
        ),
      );
      return;
    }

    // Neutral ratings have no tag set worth asking about.
    final neutral = _ratingValue.abs() <= 0.3;
    AnalyticsService().trackQuestionRated(
      neutral ? 'neutral' : (_ratingValue > 0 ? 'positive' : 'negative'),
    );
    setState(() {
      _isSubmittingRating = false;
      _stage = neutral ? _Stage.results : _Stage.tags;
    });
    if (neutral) _load();
  }

  Future<void> _submitTags() async {
    if (_selectedTags.isNotEmpty) {
      await _ratingService.submitReviewTags(
        widget.questionId,
        _selectedTags.toList(),
      );
    }
    AnalyticsService()
        .trackReviewTags(skipped: false, tagCount: _selectedTags.length);
    if (!mounted) return;
    setState(() => _stage = _Stage.results);
    _load();
  }

  void _skipTags() {
    AnalyticsService().trackReviewTags(skipped: true);
    setState(() => _stage = _Stage.results);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    _stage ??= _canRate(context) ? _Stage.slider : _Stage.results;

    switch (_stage!) {
      case _Stage.slider:
        return _card(context, _buildSlider(context));
      case _Stage.tags:
        return _card(context, _buildTags(context));
      case _Stage.results:
        if (_loading) return const SizedBox.shrink();
        final total = _distribution.values.fold<int>(0, (a, b) => a + b);
        if (total == 0) return const SizedBox.shrink();
        return _card(context, _buildResults(context));
    }
  }

  Widget _card(BuildContext context, Widget child) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: child,
      ),
    );
  }

  Color? _mutedColor(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
          ? Colors.grey[400]
          : Colors.grey[600];

  // ─── Stage 1: optional slider ───

  Widget _buildSlider(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(
              child: Text('What did you think?',
                  style: theme.textTheme.titleMedium),
            ),
            Text(
              'optional',
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: _mutedColor(context)),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          'Ratings help others find good questions.',
          style: theme.textTheme.bodySmall?.copyWith(color: _mutedColor(context)),
        ),
        const SizedBox(height: 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: const [
            Icon(Icons.thumb_down, color: Colors.red),
            Icon(Icons.thumb_up, color: Colors.green),
          ],
        ),
        const SizedBox(height: 4),
        ApprovalSlider(
          initialValue: 0.0,
          onChanged: (value) => _ratingValue = value,
          onChangeEnd: _isSubmittingRating ? (_) {} : _onSliderReleased,
        ),
        if (_isSubmittingRating) ...[
          const SizedBox(height: 12),
          const Center(
            child: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        ],
      ],
    );
  }

  // ─── Stage 2: optional tags ───

  Widget _buildTags(BuildContext context) {
    final theme = Theme.of(context);
    final chips = _availableChips;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('What stood out?', style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          'Optional — pick any that fit.',
          style: theme.textTheme.bodySmall?.copyWith(color: _mutedColor(context)),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: chips.map((tag) {
            final selected = _selectedTags.contains(tag);
            return FilterChip(
              label: Text(ReviewTagNavigation.chipLabels[tag] ?? tag),
              selected: selected,
              showCheckmark: false,
              onSelected: (val) {
                setState(() {
                  if (val) {
                    _selectedTags.add(tag);
                  } else {
                    _selectedTags.remove(tag);
                  }
                });
              },
            );
          }).toList(),
        ),
        const SizedBox(height: 16),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            TextButton(onPressed: _skipTags, child: const Text('Skip')),
            ElevatedButton(
              onPressed: _submitTags,
              style: ElevatedButton.styleFrom(
                backgroundColor: theme.primaryColor,
                foregroundColor: Colors.white,
              ),
              child: const Text('Continue'),
            ),
          ],
        ),
      ],
    );
  }

  // ─── Stage 3: results ───

  Widget _buildResults(BuildContext context) {
    return Column(
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
    );
  }
}
