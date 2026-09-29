// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// "Your network" card for a viewer who HAS a circle (5+ friends) on a question
// too few of those friends have answered. Same frame as NetworkDemoCard so the
// slot on the page does not jump; the action is a nudge to lick friends, which
// happens from the Community tab's friend rows.

import 'package:flutter/material.dart';

import 'chameleon_lick_icon.dart';

class NetworkNotEnoughCard extends StatelessWidget {
  /// Opens wherever the viewer can lick a friend (the Community tab).
  final VoidCallback onSendLick;
  final VoidCallback? onDismiss;

  const NetworkNotEnoughCard({
    Key? key,
    required this.onSendLick,
    this.onDismiss,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.primaryColor;
    final isDark = theme.brightness == Brightness.dark;
    final muted = Colors.grey[isDark ? 400 : 600];

    return Container(
      decoration: BoxDecoration(
        color:
            isDark ? Colors.white.withOpacity(0.04) : primary.withOpacity(0.04),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: primary.withOpacity(0.18)),
      ),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.hub_outlined, size: 18, color: primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Your network',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: primary,
                  ),
                ),
              ),
              if (onDismiss != null)
                IconButton(
                  tooltip: 'Hide',
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 32, minHeight: 32),
                  icon: Icon(Icons.close_rounded, size: 18, color: muted),
                  onPressed: onDismiss,
                ),
            ],
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: Text(
              "Not enough of your friends have answered this one yet. "
              "Send them a lick?",
              style: theme.textTheme.bodyMedium?.copyWith(color: muted),
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: onSendLick,
              icon: const ChameleonLickIcon(size: 22, semanticsLabel: null),
              label: const Text('Send a lick'),
            ),
          ),
        ],
      ),
    );
  }
}
