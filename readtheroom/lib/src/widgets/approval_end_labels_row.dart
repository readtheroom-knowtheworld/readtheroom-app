// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The thumb-down / thumb-up row that sits above an [ApprovalSlider], now
// captioned with the question's authored end labels (WP-B). Replaces the bare
// icon Row that answer_approval_screen, the QOTD hero and the new-question
// preview each had inline, so all four surfaces read the same.

import 'package:flutter/material.dart';
import '../utils/approval_labels.dart';

class ApprovalEndLabelsRow extends StatelessWidget {
  /// The question's end labels (defaults to "Disapprove" / "Approve").
  final ApprovalLabels labels;

  const ApprovalEndLabelsRow({
    Key? key,
    this.labels = ApprovalLabels.defaults,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodySmall?.copyWith(
          fontWeight: FontWeight.w600,
        );

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        const Icon(Icons.thumb_down, color: Colors.red),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            labels.low,
            style: style,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            labels.high,
            style: style,
            textAlign: TextAlign.right,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: 6),
        const Icon(Icons.thumb_up, color: Colors.green),
      ],
    );
  }
}
