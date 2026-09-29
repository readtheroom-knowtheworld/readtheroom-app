// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// "My Network" aggregate card — design doc §5.5A.
//
// Shows the distribution of a network's answers (friends + friends-of-friends,
// mixed together per spec) for a single question. NEVER any per-person
// attribution: only a respondent count and an aggregate visualization, reusing
// the app's existing small-sample dot idioms (ApprovalDotPlot / McDotRow).
//
// The k-anonymity gate (k = 3, §9 P-1) is part of the design: below three
// network respondents the card withholds the aggregate and shows the "invite
// friends" prompt instead.
//
// The named constructors take the shape `get_network_results(question_id)`
// returns. `.approvalBuckets` and `.multipleChoice` are the live ones; the
// older `.approval` (one value per respondent) is what the fabricated demo
// dataset still hands over, since it has individual values and the server
// never does.
//
// THE SERVER'S NUMBERS ARE THE SERVER'S. `respondentCount`, the bucket counts
// and `average` all arrive quantised — floored to multiples of k, with the
// average derived from the published buckets — so that a single new answer can
// never move a published number. Nothing here re-tallies or re-derives them.
// [hiddenCount] is the remainder quantisation withheld, rendered as "+N more".

import 'package:flutter/material.dart';
import '../models/network_graph.dart';
import '../utils/results_colors.dart';
import 'approval_dot_plot.dart';
import 'mc_dot_row.dart';

/// K-anonymity minimum for network aggregates (design doc §9, decision log).
const int kNetworkAnonymityThreshold = 3;

enum _AggregateMode { approval, multipleChoice }

class NetworkAggregateCard extends StatelessWidget {
  /// Number of network members (friends + friends-of-friends) who answered.
  final int respondentCount;

  /// K-anonymity gate; below this the aggregate is withheld (default 3).
  final int kThreshold;

  /// Optional invite CTA shown in the gated state.
  final VoidCallback? onInvite;

  /// Respondents quantisation withheld from [respondentCount]. Rendered as
  /// "+N more" so the number the reader sees is never quietly wrong.
  final int hiddenCount;

  // Approval mode.
  final List<double> _approvalValues;
  final double _approvalAverage;

  // Multiple-choice mode.
  final List<String> _mcOptionLabels;
  final List<int> _mcOptionVotes;

  /// The question's own 0-based option indices, which is what the shared
  /// palette colours by. Empty means "this list IS the question's order", as it
  /// is in the demo; the server orders by votes, so it sends them explicitly.
  final List<int> _mcOptionIndices;

  final _AggregateMode _mode;

  /// One value per respondent — what the fabricated demo dataset has. The
  /// server sends buckets; use [NetworkAggregateCard.approvalBuckets] for it.
  const NetworkAggregateCard.approval({
    Key? key,
    required this.respondentCount,
    required List<double> values,
    required double average,
    this.kThreshold = kNetworkAnonymityThreshold,
    this.onInvite,
    this.hiddenCount = 0,
  })  : _approvalValues = values,
        _approvalAverage = average,
        _mcOptionLabels = const [],
        _mcOptionVotes = const [],
        _mcOptionIndices = const [],
        _mode = _AggregateMode.approval,
        super(key: key);

  /// The server's five quantised approval counts, strongly-disapprove first,
  /// and the average it derived from them.
  ///
  /// The dot plot draws one dot per answer, so the buckets are expanded to
  /// their band MIDPOINTS — the same five numbers the server averaged. That is
  /// the most the published data supports: the exact positions were never sent,
  /// and inventing a spread inside a band would draw a precision that is not
  /// there.
  factory NetworkAggregateCard.approvalBuckets({
    Key? key,
    required int respondentCount,
    required List<int> buckets,
    double? average,
    int kThreshold = kNetworkAnonymityThreshold,
    VoidCallback? onInvite,
    int hiddenCount = 0,
  }) {
    final values = <double>[];
    for (var i = 0;
        i < buckets.length && i < kNetworkApprovalBandMidpoints.length;
        i++) {
      for (var n = 0; n < buckets[i]; n++) {
        values.add(kNetworkApprovalBandMidpoints[i]);
      }
    }
    return NetworkAggregateCard.approval(
      key: key,
      respondentCount: respondentCount,
      values: values,
      average: average ?? 0,
      kThreshold: kThreshold,
      onInvite: onInvite,
      hiddenCount: hiddenCount,
    );
  }

  const NetworkAggregateCard.multipleChoice({
    Key? key,
    required this.respondentCount,
    required List<String> optionLabels,
    required List<int> optionVotes,
    this.kThreshold = kNetworkAnonymityThreshold,
    this.onInvite,
    this.hiddenCount = 0,
    List<int> optionIndices = const [],
  })  : _mcOptionLabels = optionLabels,
        _mcOptionVotes = optionVotes,
        _mcOptionIndices = optionIndices,
        _approvalValues = const [],
        _approvalAverage = 0,
        _mode = _AggregateMode.multipleChoice,
        super(key: key);

  bool get _gated => respondentCount < kThreshold;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.primaryColor;
    final isDark = theme.brightness == Brightness.dark;

    return Container(
      decoration: BoxDecoration(
        color: isDark ? Colors.white.withOpacity(0.04) : primary.withOpacity(0.04),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: primary.withOpacity(0.18)),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.hub_rounded, size: 18, color: primary),
              const SizedBox(width: 8),
              Text(
                'My Network',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: primary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _gated ? _buildGated(context) : _buildAggregate(context),
        ],
      ),
    );
  }

  // --- Gated (fewer than k respondents) ---------------------------------------

  Widget _buildGated(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.primaryColor;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.lock_clock_rounded,
                size: 20, color: theme.textTheme.bodySmall?.color),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Not enough of your network has answered yet — invite friends',
                style: theme.textTheme.bodyMedium?.copyWith(height: 1.35),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: onInvite,
            icon: const Icon(Icons.person_add_alt_1_rounded, size: 18),
            style: OutlinedButton.styleFrom(
              foregroundColor: primary,
              side: BorderSide(color: primary.withOpacity(0.5)),
              shape:
                  RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            label: const Text('Invite friends'),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'Aggregates unlock once at least $kThreshold people in your network answer, '
          'so no single answer is ever identifiable.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: Colors.grey,
            height: 1.35,
          ),
        ),
      ],
    );
  }

  // --- Aggregate (>= k respondents) -------------------------------------------

  Widget _buildAggregate(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          hiddenCount > 0
              ? '$respondentCount+ answers from your network'
              : '$respondentCount answers from your network',
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'Friends and friends-of-friends, mixed together.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: Colors.grey,
            height: 1.35,
          ),
        ),
        const SizedBox(height: 16),
        if (_mode == _AggregateMode.approval)
          ApprovalDotPlot(
            values: _approvalValues,
            average: _approvalAverage,
          )
        else
          _buildMcRows(context),
      ],
    );
  }

  Widget _buildMcRows(BuildContext context) {
    final total = _mcOptionVotes.fold<int>(0, (a, b) => a + b);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < _mcOptionLabels.length; i++)
          McDotRow(
            label: _mcOptionLabels[i],
            voteCount: i < _mcOptionVotes.length ? _mcOptionVotes[i] : 0,
            totalResponses: total,
            color: ResultsColors.forOptionIndex(
                context, i < _mcOptionIndices.length ? _mcOptionIndices[i] : i),
          ),
      ],
    );
  }
}
