// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';

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

  static const _binColors = [
    Colors.red,
    Color(0xFFEF9A9A), // Colors.red[200]
    Color(0xFFE0E0E0), // Colors.grey[300]
    Color(0xFFA5D6A7), // Colors.green[200]
    Colors.green,
  ];

  static const _binIcons = [
    Icons.thumb_down,
    Icons.thumb_down,
    Icons.sentiment_neutral,
    Icons.thumb_up,
    Icons.thumb_up,
  ];

  @override
  Widget build(BuildContext context) {
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
                      color: _binColors[i],
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
            final iconColor = i < 2
                ? (i == 0 ? Colors.red : Colors.red[200])
                : i == 2
                    ? Colors.grey[600]
                    : (i == 3 ? Colors.green[200] : Colors.green);
            final iconSize = (i == 0 || i == 4) ? 16.0 : 18.0;
            return Expanded(
              child: Center(
                child: i == 0 || i == 4
                    ? Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(_binIcons[i], color: iconColor, size: iconSize),
                          const SizedBox(width: 1),
                          Icon(_binIcons[i], color: iconColor, size: iconSize),
                        ],
                      )
                    : Icon(_binIcons[i], color: iconColor, size: iconSize),
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
