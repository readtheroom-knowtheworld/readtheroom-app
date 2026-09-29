// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// "Your network" on a results screen — the one place the response linkage
// becomes something a person can look at.
//
// It draws whichever of three cards the viewer has earned, and the decision is
// the SERVER'S: `get_network_results` answers with `gated` and a `reason`, and
// this widget maps that onto a card. The client rule in `network_card_logic`
// is only the pre-check that picks a card before the payload lands.
//
//   under 5 friends / no answer yet  ->  nothing (owner, 2026-09-28: the
//                                        sample circle lives only on the home
//                                        and community screens, never on a
//                                        results screen)
//   a circle, too few answers        ->  NetworkNotEnoughCard ("send a lick?")
//   a circle and 3+ answers          ->  the real graph + aggregate + close friends
//
// What it will not do, in one list, because each of these is a privacy rule and
// not a styling choice:
//
//   * it never re-tallies the server's respondent count from the node list, and
//     never re-derives the average from the buckets;
//   * a node with no answer is grey, whoever it is, with no badge saying an
//     answer was withheld — otherwise opting out would itself be visible;
//   * it does not make a friend-of-friend tappable: those nodes carry no handle
//     and no account id, and there is nothing to open;
//   * text questions get a count and a graph, never a body, not even for close
//     friends (owner decision D-1);
//   * its analytics are aggregate-only. No event here carries a question id,
//     because the question↔user link now exists server-side and PostHog must
//     not be handed a second copy of it.
//
// Docs: feature-documentation/networks-client-2026-09-22.md

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../utils/approval_labels.dart';

import '../models/network_results.dart';
import '../utils/results_surface.dart';
import '../services/analytics_service.dart';
import '../services/friend_service.dart';
import '../services/network_service.dart';
import '../utils/demo_friends_mode.dart';
import '../utils/main_tab_requests.dart';
import '../utils/network_card_logic.dart';
import 'network_graph_preview.dart';
import 'network_not_enough_card.dart';
import 'network_results_sharing_toggle.dart';

class NetworkResultsSection extends StatefulWidget {
  const NetworkResultsSection({
    Key? key,
    required this.questionId,
    this.questionType = '',
    this.surface = 'results',
    this.padding = const EdgeInsets.fromLTRB(16, 8, 16, 16),
    this.service,
    this.realOnly = false,
    this.prompt,
    this.emoji,
    this.approvalLabels = ApprovalLabels.defaults,
  }) : super(key: key);

  /// End labels for the approval legend under the graph.
  final ApprovalLabels approvalLabels;

  final String questionId;
  final String questionType;

  /// Named in the analytics events, so the same card can be told apart on a
  /// results screen and on the QOTD hero.
  final String surface;

  final EdgeInsets padding;

  /// Test seam.
  final NetworkService? service;

  /// When true the section draws only the real graph and nothing in any gated
  /// state — for surfaces that already draw their own sample / nudge card
  /// (the home screen's circle card, with its 7-day snooze).
  final bool realOnly;

  /// The question the colours refer to, quoted above the graph the way the
  /// demo card does it (owner, 2026-09-22). Nothing is drawn without it.
  final String? prompt;
  final String? emoji;

  @override
  State<NetworkResultsSection> createState() => _NetworkResultsSectionState();
}

class _NetworkResultsSectionState extends State<NetworkResultsSection> {
  NetworkService get _service => widget.service ?? NetworkService.shared();

  NetworkResults? _results;
  bool _loading = true;

  /// Reported once per mount, so a rebuild does not inflate the count.
  bool _reported = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(NetworkResultsSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.questionId != widget.questionId) {
      _reported = false;
      _load();
    }
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() => _loading = true);
    final results = await _service.getNetworkResults(
      widget.questionId,
      questionType: widget.questionType,
    );
    // Close-friend answers are a second call because they are a different
    // consent gate — reciprocity, not k-anonymity — and are worth nothing
    // without the graph above them.
    // The close-friends row is not rendered (owner, 2026-09-22), so its RPC
    // is not called; the graph's coloured close-friend nodes carry the same
    // information.
    if (!mounted) return;
    setState(() {
      _results = results;
      _loading = false;
    });
  }

  /// `network_card_shown` means SHOWN (review 2026-09-22 B1).
  ///
  /// It used to fire from `_load()`, before `build()` had decided whether to
  /// draw anything — and `build()` returns `SizedBox.shrink()` for a missing
  /// provider, an unauthenticated viewer, and (on home, where `realOnly` is
  /// true) every gated state. So every gated home load logged an impression
  /// for a card nobody saw. It is now called from the render path, immediately
  /// before each `Padding(` that actually returns a card, still guarded by
  /// `_reported` so a rebuild cannot inflate the count.
  void _report(NetworkResults results, int friendCount) {
    if (_reported) return;
    // Fabricated demo data must never be reported as a real network — see the
    // kill switch in AnalyticsService. Belt and braces: this guard states the
    // rule where a reader of this widget will look for it.
    if (DemoFriendsMode.instance.enabled) return;
    _reported = true;
    AnalyticsService().trackEventAnonymous('network_card_shown', {
      'state': _stateName(results),
      'respondents_bucket': respondentsBucket(results.respondents),
      'question_type': widget.questionType,
      'friend_count_bucket': friendCountBucket(friendCount),
      'surface': widget.surface,
    });
  }

  String _stateName(NetworkResults results) {
    if (results.hasGraph) return 'network';
    if (!results.available) return 'unavailable';
    switch (results.reason) {
      case NetworkGateReason.notEnoughFriends:
        return 'demo';
      case NetworkGateReason.notEnoughAnswers:
        return 'not_enough';
      case NetworkGateReason.unavailable:
      case null:
        return 'unavailable';
    }
  }

  void _openCommunity() {
    // Review 2026-09-22 B5: the identical card on home already fires this
    // (home_screen.dart), so one insight now covers both surfaces and the
    // nudge -> lick funnel is joinable.
    AnalyticsService().trackEventAnonymous('network_not_enough_cta_tapped', {
      'surface': widget.surface,
      'friend_count': _lastFriendCount,
    });
    Navigator.of(context).popUntil((route) => route.isFirst);
    MainTabRequests.instance.goTo(MainTab.community);
  }

  /// The friend count from the most recent build, so `_openCommunity` (which
  /// has no access to the provider read) can report it.
  int _lastFriendCount = 0;

  @override
  Widget build(BuildContext context) {
    // Nothing at all while the first call is in flight: a skeleton here would
    // promise a card the viewer may not be entitled to.
    if (_loading) return const SizedBox.shrink();
    final results = _results;
    if (results == null) return const SizedBox.shrink();

    // Watched, not required: a surface pumped without the provider (a widget
    // test, a screen reached before the app tree is built) simply shows nothing
    // rather than throwing.
    final FriendService? friends = _friends(context);
    if (friends == null || !friends.isAuthenticated) {
      return const SizedBox.shrink();
    }

    // The server's reason first; the local friend count only where it declined
    // to answer at all.
    final state = networkCardStateFor(results,
        localFriendCount: friends.friendCount);
    final friendCount = results.friendCount > 0
        ? results.friendCount
        : friends.friendCount;
    _lastFriendCount = friendCount;

    if (state == NetworkCardState.realMap) {
      _report(results, friendCount);
      return Padding(
        padding: widget.padding,
        child: _buildNetwork(context, results),
      );
    }
    if (widget.realOnly) return const SizedBox.shrink();
    if (state == NetworkCardState.notEnoughAnswers) {
      _report(results, friendCount);
      return Padding(
        padding: widget.padding,
        child: NetworkNotEnoughCard(onSendLick: _openCommunity),
      );
    }
    // Under 5 friends / no answer yet: the demo circle is shown on the home
    // and community screens only, so a results screen draws nothing here.
    return const SizedBox.shrink();
  }

  FriendService? _friends(BuildContext context) {
    try {
      return context.watch<FriendService>();
    } on ProviderNotFoundException {
      return null;
    }
  }

  Widget _buildNetwork(BuildContext context, NetworkResults results) {
    final theme = Theme.of(context);
    final primary = theme.primaryColor;
    final graph = results.graph!;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          // Results pages: the page's section colour (white in light mode,
          // the shared dark tone in dark mode) with an outline only in dark
          // mode, like every other section there. Home: the question card's
          // frame, so the two match (owner, 2026-09-22).
          decoration: widget.surface == 'results'
              ? BoxDecoration(
                  color: resultsSectionColor(theme),
                  borderRadius: BorderRadius.circular(16),
                  border: resultsSectionBorder(theme),
                )
              : homeCardDecoration(theme),
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.hub_rounded, size: 18, color: primary),
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
                ],
              ),
              if (widget.prompt != null && widget.prompt!.trim().isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  _quotedPrompt(),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    height: 1.3,
                  ),
                ),
                const SizedBox(height: 12),
              ] else
                const SizedBox(height: 6),
              NetworkGraphPreview(
                data: graph,
                surface: widget.surface,
                approvalLegend: widget.questionType.contains('approval'),
                approvalLabels: widget.approvalLabels,
              ),
              // Same blank-line gap as the demo card.
              const SizedBox(height: 26),
              // The demo card's explainer, word for word, centred under the
              // graph (owner, 2026-09-22).
              SizedBox(
                width: double.infinity,
                child: Text(
                  _graphCaption(results),
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: Colors.grey, height: 1.35),
                ),
              ),
              // The share toggle lives inside the card, under the caption
              // (owner, 2026-09-22). The aggregate card and the close-friends
              // row are built but not shown: the graph carries both.
              NetworkResultsSharingToggle(
                questionId: widget.questionId,
                answered: graph.self.answered,
                service: widget.service,
                surface: widget.surface,
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// Quoted, with the emoji inside the quotes after the prompt — the demo
  /// card's exact styling.
  String _quotedPrompt() {
    final p = widget.prompt!.trim();
    final e = (widget.emoji ?? '').trim();
    return e.isEmpty ? '“$p”' : '“$p $e”';
  }

  /// The demo card's line, so the real graph reads exactly like the sample.
  String _graphCaption(NetworkResults results) {
    final overflow = results.friendOverflow;
    final tail = overflow > 0 ? ' $overflow more friends not shown.' : '';
    return 'Friends keep their answers private — only close friends and '
        'anonymous friends-of-friends share answers.$tail';
  }
}

/// The respondent buckets the analytics events carry instead of a raw count.
/// Coarse on purpose: in a small network the exact number is itself a signal.
String respondentsBucket(int respondents) {
  if (respondents <= 2) return '0-2';
  if (respondents <= 5) return '3-5';
  if (respondents <= 10) return '6-10';
  return '11+';
}

/// Friend-count buckets, straddling the 5-friend gate so the demo -> network
/// progression is readable without keeping a per-person property (B1).
String friendCountBucket(int friends) {
  if (friends <= 4) return '0-4';
  if (friends <= 9) return '5-9';
  return '10+';
}
