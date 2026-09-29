// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';

import '../utils/approval_labels.dart';
import '../utils/results_colors.dart';

/// The approval colour scale spelled out: low-end label, the five-band
/// gradient strip, high-end label (no end dots, owner 2026-09-28). First drawn under the network ego
/// graph (2026-09-25); now the one legend for every approval results surface
/// (response map, dot plot, network graph) so they all read the same, each
/// captioned with the question's own end labels (WP-B).
class ApprovalSpectrumLegend extends StatelessWidget {
  /// The question's end labels (defaults to "Disapprove" / "Approve").
  final ApprovalLabels labels;

  final EdgeInsetsGeometry padding;

  const ApprovalSpectrumLegend({
    Key? key,
    this.labels = ApprovalLabels.defaults,
    this.padding = const EdgeInsets.only(top: 6, left: 4, right: 4),
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final bins = ResultsColors.approvalBinColors(context);
    final style = Theme.of(context).textTheme.labelSmall?.copyWith(
          color: Colors.grey,
          fontWeight: FontWeight.w600,
        );
    return Padding(
      padding: padding,
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Each label gets at most ~a third of the row, so a 20-character
          // authored label ellipsises instead of squeezing the strip away.
          final labelMax = constraints.maxWidth * 0.34;
          Widget label(String text, TextAlign align) => ConstrainedBox(
                constraints: BoxConstraints(maxWidth: labelMax),
                child: Text(
                  text,
                  style: style,
                  textAlign: align,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              );
          return Row(
            children: [
              label(labels.low, TextAlign.left),
              const SizedBox(width: 10),
              Expanded(
                child: Container(
                  height: 4,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(2),
                    gradient: LinearGradient(colors: bins),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              label(labels.high, TextAlign.right),
            ],
          );
        },
      ),
    );
  }
}
