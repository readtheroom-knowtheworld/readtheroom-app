// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// "Why connect?" demo card — the ego-network graph from the Phase-1 sneak peek
// (networks-update-design §5.2 / §5.5 / §9), reframed as an acquisition nudge
// for users who have no friends yet. Shown on the home screen under the
// friends teaser and inside the Community tab's empty state.
//
// Best-practice guardrails, in order of importance:
//   • It is unmistakably sample data: an amber DEMO badge in the header and a
//     "Sample data" caption under the graph. Nothing here is ever mistaken for
//     the viewer's real circle.
//   • It only exists while the viewer has zero accepted friends. The moment a
//     real graph exists, the demo is gone (callers gate on
//     `FriendService.hasAnyFriends`).
//   • One clear next step — a single CTA that lands on the add-friend flow.
//     Surfaces that already show the add CTAs (Community empty state) pass
//     `showCta: false` so the card never competes with them.
//   • Dismissible on the home screen (`onDismiss`), because a promo that can't
//     be closed is a nag. Community keeps it undismissable — it *is* the
//     explainer there.
//   • (2026-09-19) The chip legend was removed: the one-line explainer under
//     the graph carries the privacy model on its own — grey friends are
//     private, close friends and anonymous friends-of-friends show answers.
//     Motion is handled by the graph widget (reduced-motion aware).

import 'package:flutter/material.dart';
import '../utils/demo_network_data.dart';
import 'network_graph_preview.dart';

/// How many accepted friends make a "circle". The demo/nudge card shows until
/// the viewer reaches it (the network aggregate needs several answerers to be
/// anonymous, and a circle below this is too small to read anything from).
const int kCircleFriendGoal = 5;

class NetworkDemoCard extends StatelessWidget {
  /// Tapping the CTA (or the graph itself) — typically opens the Community
  /// tab or the add-friend flow.
  final VoidCallback? onAddFriends;

  /// Present ⇒ a small "Hide" affordance is rendered in the header.
  final VoidCallback? onDismiss;

  /// Render the "Add your first friend" button. Pass false where the
  /// surrounding surface already offers the add CTAs.
  final bool showCta;

  /// Which sample question drives the node colours. Null ⇒ the first headline
  /// demo question (approval kind), so home and Community show one picture.
  final DemoNetworkQuestion? question;

  /// The viewer's accepted-friend count. Above zero the header turns into a
  /// "N of 5" progress line so the card reads as a goal, not a sales pitch.
  final int friendCount;

  const NetworkDemoCard({
    Key? key,
    this.onAddFriends,
    this.onDismiss,
    this.showCta = true,
    this.question,
    this.friendCount = 0,
  }) : super(key: key);

  int get _remaining => (kCircleFriendGoal - friendCount).clamp(0, kCircleFriendGoal);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.primaryColor;
    final isDark = theme.brightness == Brightness.dark;
    final muted = Colors.grey[isDark ? 400 : 600];
    final question = this.question ?? kDemoNetworkQuestions.first;

    return Semantics(
      container: true,
      label: 'Sample network preview. Shows how your circle would read the '
          'room once you add friends. Sample data, not your real friends.',
      child: Container(
        decoration: BoxDecoration(
          color: isDark
              ? Colors.white.withOpacity(0.04)
              : primary.withOpacity(0.04),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: primary.withOpacity(0.18)),
        ),
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header: title + DEMO badge (+ optional Hide).
            Row(
              children: [
                Icon(Icons.hub_outlined, size: 18, color: primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    friendCount > 0
                        ? 'Your network'
                        : 'See how your circle reads the room',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: primary,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                const DemoBadge(),
                if (onDismiss != null) ...[
                  const SizedBox(width: 4),
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
              ],
            ),
            if (friendCount > 0) ...[
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: (friendCount / kCircleFriendGoal).clamp(0.0, 1.0),
                  minHeight: 6,
                  backgroundColor: primary.withOpacity(0.12),
                  valueColor: AlwaysStoppedAnimation<Color>(primary),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                _remaining == 1
                    ? 'Add 1 more friend to explore what your community thinks!'
                    : 'Add $_remaining more friends to explore what your community thinks!',
                style: theme.textTheme.bodySmall?.copyWith(color: muted),
              ),
            ],
            const SizedBox(height: 8),
            // The sample question the colours refer to.
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Quoted, with the emoji inside the quotes after the question
                // mark — where a person texting it would put it.
                Expanded(
                  child: Text(
                    '“${question.prompt} ${question.emoji}”',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      height: 1.3,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            // The graph. Tapping nodes shows tooltips (handled inside); a tap
            // on the surrounding area is deliberately NOT a CTA so exploring
            // the picture never yanks the user to another tab.
            NetworkGraphPreview(
              key: ValueKey('network-demo-${question.id}'),
              data: buildDemoNetworkGraph(question),
            ),
            // A blank line's worth of space between the graph and the caption
            // (owner, 2026-09-28).
            const SizedBox(height: 26),
            // Full width + centred, so the lines centre under the graph rather
            // than hugging the card's left edge.
            SizedBox(
              width: double.infinity,
              child: Text(
                'Friends keep their answers private — only '
                'close friends and anonymous friends-of-friends share answers.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: muted,
                  height: 1.35,
                ),
              ),
            ),
            if (showCta) ...[
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: onAddFriends,
                  icon: const Icon(Icons.person_add_alt_1_rounded, size: 18),
                  label: Text(friendCount > 0 ? 'Add a friend' : 'Add your first friend'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: primary,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Amber "DEMO" pill — reads as "not real data" at a glance. Shared so every
/// demo surface uses the same mark.
class DemoBadge extends StatelessWidget {
  const DemoBadge({Key? key}) : super(key: key);

  static const Color color = Color(0xFFF57C00);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withOpacity(0.7)),
      ),
      child: Text(
        'DEMO',
        style: theme.textTheme.labelSmall?.copyWith(
          color: color,
          fontWeight: FontWeight.w800,
          letterSpacing: 1.0,
        ),
      ),
    );
  }
}

