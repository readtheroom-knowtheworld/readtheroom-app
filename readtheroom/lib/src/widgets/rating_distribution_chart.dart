// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import '../utils/results_colors.dart';

class RatingDistributionChart extends StatelessWidget {
  final Map<String, int> distribution;
  final double height;

  const RatingDistributionChart({
    Key? key,
    required this.distribution,
    this.height = 120,
  }) : super(key: key);

  static const _binKeys = [
    'strongly_disapprove',
    'disapprove',
    'neutral',
    'approve',
    'strongly_approve',
  ];

  static const _binLabels = [
    'Strongly Disapprove',
    'Disapprove',
    'Neutral',
    'Approve',
    'Strongly Approve',
  ];

  @override
  Widget build(BuildContext context) {
    final binColors = ResultsColors.approvalBinColors(context);
    final counts = _binKeys.map((k) => distribution[k] ?? 0).toList();
    final maxCount = counts.fold<int>(0, (a, b) => a > b ? a : b);
    final total = counts.fold<int>(0, (a, b) => a + b);

    return Column(
      children: [
        SizedBox(
          height: height,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: List.generate(5, (i) {
              final fraction =
                  maxCount > 0 ? counts[i] / maxCount : 0.0;
              return Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 500),
                    curve: Curves.easeOutCubic,
                    height: fraction * height,
                    decoration: BoxDecoration(
                      color: binColors[i],
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ),
              );
            }),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: List.generate(5, (i) {
            final iconSize = (i == 0 || i == 4) ? 16.0 : 18.0;
            return Expanded(
              child: Center(
                child: ResultsColors.iconForApprovalLabel(
                    context, _binLabels[i], size: iconSize),
              ),
            );
          }),
        ),
        if (total > 0) ...[
          const SizedBox(height: 4),
          Text(
            '$total ${total == 1 ? 'rating' : 'ratings'}',
            style: TextStyle(
              fontSize: 12,
              color: Colors.grey[600],
            ),
          ),
        ],
      ],
    );
  }
}
