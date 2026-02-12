// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../services/user_service.dart';
import '../services/question_rating_service.dart';
import '../utils/review_tag_navigation.dart';
import 'approval_slider.dart';
import 'rating_distribution_chart.dart';

enum _RatingPhase { loading, slider, chips, finalView }

class QuestionRatingSection extends StatefulWidget {
  final String questionId;
  final bool isAuthor;
  final VoidCallback onRatingComplete;

  const QuestionRatingSection({
    Key? key,
    required this.questionId,
    required this.isAuthor,
    required this.onRatingComplete,
  }) : super(key: key);

  @override
  State<QuestionRatingSection> createState() => _QuestionRatingSectionState();
}

class _QuestionRatingSectionState extends State<QuestionRatingSection> {
  _RatingPhase _phase = _RatingPhase.loading;
  final _ratingService = QuestionRatingService();
  double _ratingValue = 0.0;
  final Set<String> _selectedTags = {};
  Map<String, int> _distribution = {};
  Map<String, int> _tagCounts = {};

  static const _negativeChips = ReviewTagNavigation.negativeChips;
  static const _positiveChips = ReviewTagNavigation.positiveChips;
  static const _chipLabels = ReviewTagNavigation.chipLabels;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    final userService = Provider.of<UserService>(context, listen: false);
    final isAuthenticated =
        Supabase.instance.client.auth.currentUser != null;

    print('⭐ RatingSection[${widget.questionId}]: isAuthor=${widget.isAuthor}, isAuthenticated=$isAuthenticated, hasRated=${userService.hasRatedQuestion(widget.questionId)}');

    // Authors, unauthenticated users, and returning users skip to final view
    if (widget.isAuthor || !isAuthenticated) {
      await _loadDistribution();
      print('⭐ RatingSection[${widget.questionId}]: author/unauth → finalView, distribution total=${_distribution.values.fold<int>(0, (a, b) => a + b)}, tagCounts=$_tagCounts');
      if (mounted) {
        setState(() => _phase = _RatingPhase.finalView);
        widget.onRatingComplete();
      }
      return;
    }

    if (userService.hasRatedQuestion(widget.questionId)) {
      await _loadDistribution();
      final total = _distribution.values.fold<int>(0, (a, b) => a + b);
      print('⭐ RatingSection[${widget.questionId}]: already rated → distribution total=$total, tagCounts=$_tagCounts');
      if (total == 0) {
        // Local state says rated but server has no data — clear local and re-prompt
        print('⭐ RatingSection[${widget.questionId}]: desync detected, resetting to slider');
        await userService.clearQuestionRating(widget.questionId);
        if (mounted) {
          setState(() => _phase = _RatingPhase.slider);
        }
        return;
      }
      if (mounted) {
        setState(() => _phase = _RatingPhase.finalView);
        widget.onRatingComplete();
      }
      return;
    }

    print('⭐ RatingSection[${widget.questionId}]: new rater → slider');
    // Show slider for new raters
    if (mounted) {
      setState(() => _phase = _RatingPhase.slider);
    }
  }

  Future<void> _loadDistribution() async {
    final results = await Future.wait([
      _ratingService.getRatingDistribution(widget.questionId),
      _ratingService.getReviewTagCounts(widget.questionId),
    ]);
    if (mounted) {
      setState(() {
        _distribution = results[0];
        _tagCounts = results[1];
      });
    }
  }

  Future<void> _onSliderReleased(double value) async {
    _ratingValue = value;

    // Submit rating to server
    final submitted = await _ratingService.submitRating(
      widget.questionId,
      _ratingValue,
    );

    // Only save locally if server submit succeeded
    if (submitted) {
      final userService = Provider.of<UserService>(context, listen: false);
      await userService.setQuestionRating(widget.questionId, _ratingValue);
    } else {
      print('⭐ RatingSection[${widget.questionId}]: submitRating FAILED, skipping local save');
    }

    // Load distribution for display
    await _loadDistribution();

    if (!mounted) return;

    if (_ratingValue <= -0.3 || _ratingValue > 0.3) {
      setState(() => _phase = _RatingPhase.chips);
    } else {
      setState(() => _phase = _RatingPhase.finalView);
      widget.onRatingComplete();
    }
  }

  Future<void> _submitTags() async {
    if (_selectedTags.isNotEmpty) {
      await _ratingService.submitReviewTags(
        widget.questionId,
        _selectedTags.toList(),
      );
      // Reload tag counts
      final counts =
          await _ratingService.getReviewTagCounts(widget.questionId);
      if (mounted) {
        setState(() => _tagCounts = counts);
      }
    }
    if (mounted) {
      setState(() => _phase = _RatingPhase.finalView);
      widget.onRatingComplete();
    }
  }

  List<String> get _availableChips {
    if (_ratingValue <= -0.3) return _negativeChips;
    if (_ratingValue > 0.3) return _positiveChips;
    return [];
  }

  @override
  Widget build(BuildContext context) {
    switch (_phase) {
      case _RatingPhase.loading:
        return const SizedBox(
          height: 80,
          child: Center(child: CircularProgressIndicator()),
        );

      case _RatingPhase.slider:
        return _buildSliderPhase(context);

      case _RatingPhase.chips:
        return _buildChipsPhase(context);

      case _RatingPhase.finalView:
        return _buildFinalView(context);
    }
  }

  Widget _buildSliderPhase(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            Text(
              'How would you rate this question?',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Icon(Icons.thumb_down, color: Colors.red),
                Icon(Icons.thumb_up, color: Colors.green),
              ],
            ),
            const SizedBox(height: 4),
            ApprovalSlider(
              initialValue: 0.0,
              onChanged: (value) {
                _ratingValue = value;
              },
              onChangeEnd: _onSliderReleased,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildChipsPhase(BuildContext context) {
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
            const SizedBox(height: 16),
            Text(
              'What stood out?',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _availableChips.map((tag) {
                final selected = _selectedTags.contains(tag);
                return FilterChip(
                  label: Text(_chipLabels[tag] ?? tag),
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
            Align(
              alignment: Alignment.centerRight,
              child: ElevatedButton(
                onPressed: _submitTags,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Theme.of(context).primaryColor,
                  foregroundColor: Colors.white,
                ),
                child: const Text('Continue'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFinalView(BuildContext context) {
    final total = _distribution.values.fold<int>(0, (a, b) => a + b);
    print('⭐ RatingSection[${widget.questionId}]: _buildFinalView total=$total, distribution=$_distribution');
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
