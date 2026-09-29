// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';

import '../utils/demo_friends_mode.dart';
import 'network_demo_card.dart';

/// Slim amber marker pinned to the top of the Community tab while debug-only
/// "Demo friends" mode is on, so a screenshot of the seeded graph can never be
/// mistaken for real data.
///
/// Builds to nothing whenever the mode is off — which is *always* in a release
/// build, because [DemoFriendsMode.enabled] is clamped by `kDebugMode`.
///
/// Carries the same [DemoBadge] the sample-network card uses, so every demo
/// surface in the app wears one mark. The tooltip carries the one rule the demo
/// deliberately bends: the lick cooldown is shortened so the countdown can be
/// watched.
class DemoFriendsBanner extends StatelessWidget {
  const DemoFriendsBanner({Key? key, this.mode}) : super(key: key);

  /// Override for tests. Defaults to the app-wide gate.
  final DemoFriendsMode? mode;

  static const String label =
      'DEMO FRIENDS — sample data, notifications are simulated locally';

  static const String tooltip =
      'Sample friends, seeded on this device. Nothing is sent to the backend; '
      'friends "reply" on a local timer and their notifications are local '
      'notifications. The lick cooldown is shortened to 20 seconds (the real '
      'limit is 10 minutes) so the countdown can be tested.';

  @override
  Widget build(BuildContext context) {
    if (!(mode ?? DemoFriendsMode.instance).enabled) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);
    return Tooltip(
      message: tooltip,
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: DemoBadge.color.withOpacity(0.12),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: DemoBadge.color.withOpacity(0.6)),
        ),
        child: Row(
          children: [
            const DemoBadge(),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                label,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: DemoBadge.color,
                  fontWeight: FontWeight.w600,
                  height: 1.3,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
