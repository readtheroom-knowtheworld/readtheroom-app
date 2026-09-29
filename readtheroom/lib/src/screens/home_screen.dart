// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The QOTD-first "Today" home (v1.3, Phase 2). The feed is gone: home is now a
// single centered Question of the Day. This screen returns BODY CONTENT ONLY —
// MainScreen owns all chrome (Scaffold / AppBar / FAB / bottom nav). The visual
// weight and the full answer/submit flow live in [QotdHeroCard]; this widget
// owns QOTD acquisition (with the cold-start retry window + midnight-rollover
// listener), the header (logo left, drawer tagline right — the streak lives in
// the AppBar badge), pull-to-refresh, and the network demo card.

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../utils/approval_labels.dart';

import '../services/network_service.dart';
import '../services/analytics_service.dart';
import '../services/friend_service.dart';
import '../services/home_widget_service.dart';
import '../services/navigation_visibility_notifier.dart';
import '../services/question_service.dart';
import '../services/user_service.dart';
import '../utils/network_card_logic.dart';
import '../utils/qotd_home_state.dart';
import '../utils/streak_logic.dart' as streak_logic;
import '../widgets/friend_qr_dialog.dart';
import '../widgets/identity_card.dart';
import '../widgets/network_demo_card.dart';
import '../widgets/network_not_enough_card.dart';
import '../widgets/network_results_section.dart';
import '../widgets/qotd_hero_card.dart';
import 'search_screen.dart';

class HomeScreen extends StatefulWidget {
  /// Lets the friends teaser ask MainScreen to switch tabs (Community = 1).
  final ValueChanged<int>? onRequestTab;

  const HomeScreen({Key? key, this.onRequestTab}) : super(key: key);

  @override
  HomeScreenState createState() => HomeScreenState();
}

class HomeScreenState extends State<HomeScreen> {
  final ScrollController _scrollController = ScrollController();

  // Resolved QOTD + state-machine inputs.
  Map<String, dynamic>? _qotd;

  /// How many of the viewer's network answered today's question, as the server
  /// counted them — or null while it has not answered, or cannot. Null counts
  /// as zero in `networkCardState`, so the card degrades to the nudge rather
  /// than vanishing.
  int? _qotdNetworkAnswered;
  bool _qotdResolved = false;

  /// The "see how your circle reads the room" demo card under the friends
  /// teaser. Hidden for good once the user taps Hide (device-local), and never
  /// shown once they have a real friend.
  static const _kNetworkDemoSnoozedUntilKey = 'network_demo_snoozed_until';
  // Last friend count the circle nudge rendered with, for its analytics.
  int _networkDemoFriendCount = 0;
  static const _kNetworkDemoSnooze = Duration(days: 7);
  bool _networkDemoDismissed = true; // assume hidden until prefs are read
  bool _qotdExists = false;
  bool _isResolving = false;

  // Rollover detection: the raw service QOTD id we last resolved against.
  String? _lastServiceQotdId;

  // Saved reference so the listener can be removed in dispose.
  QuestionService? _questionService;

  // Analytics de-dupe: last `qotd_home_viewed` state value fired.
  String? _lastFiredAnalyticsState;

  @override
  void initState() {
    _loadNetworkDemoDismissed();
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;

      // No feed scroll exists to drive nav visibility — force it visible so the
      // AppBar / bottom nav can never stick hidden on this screen.
      context
          .read<NavigationVisibilityNotifier>()
          .showNavigation(reason: 'home_init');

      // Sync streak to server for the leaderboard rank (rainbow border).
      final userService = context.read<UserService>();
      userService.syncStreakToServer();

      // Update the Android streak home-widget with the current streak (distinct
      // from the QOTD widget updated on QOTD load).
      _updateStreakWidget(userService);

      // Listen for the midnight rollover: QuestionService notifies after it
      // swaps the QOTD, so answered→ask flips without a manual refresh.
      _questionService = context.read<QuestionService>();
      _lastServiceQotdId =
          _questionService!.questionOfTheDay?['id']?.toString();
      _questionService!.addListener(_onQuestionServiceChanged);

      _resolveQotd();
    });
  }

  @override
  void dispose() {
    _questionService?.removeListener(_onQuestionServiceChanged);
    _scrollController.dispose();
    super.dispose();
  }

  void _onQuestionServiceChanged() {
    if (!mounted || _isResolving) return;
    final currentId = _questionService?.questionOfTheDay?['id']?.toString();
    if (currentId != null && currentId != _lastServiceQotdId) {
      // The daily question changed under us — re-resolve (rollover).
      _resolveQotd();
    }
  }

  /// Acquire + enrich today's QOTD, with a bounded cold-start retry window
  /// (500ms × up to 20) so a null-QOTD window never shows a blank home.
  /// How long the last resolve took and how many retries it needed, for
  /// `qotd_home_viewed` (review 2026-09-22 F3). The retry loop is 20 x 500 ms,
  /// so `loading_timeout` could mean anything from half a second to ten.
  int? _qotdResolveMs;
  int _qotdResolveAttempts = 0;

  Future<void> _resolveQotd() async {
    if (!mounted || _isResolving) return;
    final resolveWatch = Stopwatch()..start();
    final questionService = context.read<QuestionService>();
    final userService = context.read<UserService>();
    final showNSFW = userService.showNSFWContent;

    setState(() {
      _isResolving = true;
      // Only fall back to the loading placeholder on the very first resolve;
      // a rollover re-resolve keeps the previous card until the new one lands.
      if (_qotd == null) _qotdResolved = false;
    });

    // The NSFW-day fallback prefers questions this user hasn't answered yet.
    bool alreadyAnswered(String id) => userService.hasAnsweredQuestion(id);

    Map<String, dynamic>? qotd = await questionService.getQuestionOfTheDay(
        showNSFW: showNSFW, hasAnswered: alreadyAnswered);
    int attempts = 0;
    while (qotd == null && attempts < 20) {
      await Future.delayed(const Duration(milliseconds: 500));
      if (!mounted) return;
      qotd = await questionService.getQuestionOfTheDay(
          showNSFW: showNSFW, hasAnswered: alreadyAnswered);
      attempts++;
    }

    if (qotd != null) {
      // Enrichment flow preserved from the old _getFilteredQuestionOfTheDay:
      // engagement data + accurate vote count + Android home-widget update.
      try {
        await questionService.enrichQuestionsWithEngagementData([qotd]);
        final id = qotd['id']?.toString();
        if (id != null) {
          final voteCount = await questionService.getAccurateVoteCount(
              id, qotd['type']?.toString());
          qotd['votes'] = voteCount;
        }
        final hasAnswered =
            questionService.hasAnsweredQuestionOfTheDay(userService);
        await HomeWidgetService().updateQOTDWidget(
          questionText: qotd['prompt']?.toString() ?? '',
          voteCount: qotd['votes'] as int? ?? 0,
          commentCount: qotd['comment_count'] as int? ?? 0,
          hasAnswered: hasAnswered,
          questionId: id ?? '',
        );
      } catch (e) {
        print('Home: Error enriching QOTD: $e');
      }
    }

    if (!mounted) return;
    resolveWatch.stop();
    setState(() {
      _qotd = qotd;
      _qotdExists = qotd != null;
      _qotdResolved = true;
      _isResolving = false;
      _qotdResolveMs = resolveWatch.elapsedMilliseconds;
      _qotdResolveAttempts = attempts;
      _lastServiceQotdId = questionService.questionOfTheDay?['id']?.toString();
    });
    _loadQotdNetworkCount();
  }

  /// The network respondent count for today's question, for the circle card.
  /// A count only — never who, and never on a surface that also carries an
  /// identity.
  Future<void> _loadQotdNetworkCount() async {
    final id = _qotd?['id']?.toString();
    if (id == null || id.isEmpty) {
      if (mounted && _qotdNetworkAnswered != null) {
        setState(() => _qotdNetworkAnswered = null);
      }
      return;
    }
    final count = await NetworkService.shared().getNetworkAnsweredCount(id);
    if (!mounted) return;
    setState(() => _qotdNetworkAnswered = count);
  }

  void _updateStreakWidget(UserService userService) {
    try {
      final streak = streak_logic.calculateAnswerStreak(
        userService.answeredQuestions,
        askedCredits: userService.askedStreakCredits,
      );
      final extendedToday = streak_logic.hasExtendedStreakToday(
        userService.answeredQuestions,
        askedCredits: userService.askedStreakCredits,
      );
      HomeWidgetService().updateWidget(
        streakCount: streak,
        hasExtendedToday: extendedToday,
      );
    } catch (e) {
      print('Home: Error updating streak widget: $e');
    }
  }

  /// Pull-to-refresh: re-resolve the QOTD (fresh vote/comment counts via the
  /// enrichment pass) and bump the hero nonce so its inline results and the
  /// reactions row re-fetch too — that is how new votes and emojis show up.
  int _heroRefreshNonce = 0;

  Future<void> _onRefresh() async {
    AnalyticsService().trackEvent('home_refreshed', const {'surface': 'home'});
    await _resolveQotd();
    if (!mounted) return;
    setState(() => _heroRefreshNonce++);
    await context.read<UserService>().syncStreakToServer();
  }

  /// Tell MainScreen whether the scroll sits within [_atBottomSlopPx] of its
  /// end (unscrollable content counts as "at bottom"): the new-question FAB
  /// only fades in there, so it never covers the hero card's buttons. Deferred
  /// to a post-frame callback because metrics notifications can arrive during
  /// layout, when notifying listeners is illegal.
  static const double _atBottomSlopPx = 24.0;
  bool? _reportedAtBottom;

  void _reportAtBottom(ScrollMetrics metrics) {
    final atBottom =
        metrics.pixels >= metrics.maxScrollExtent - _atBottomSlopPx;
    if (atBottom == _reportedAtBottom) return;
    _reportedAtBottom = atBottom;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        context.read<NavigationVisibilityNotifier>().setHomeAtBottom(atBottom);
      }
    });
  }

  /// Called by MainScreen (via GlobalKey) when Home is tapped while active.
  void scrollToTop() {
    if (mounted) {
      context
          .read<NavigationVisibilityNotifier>()
          .showNavigation(reason: 'scroll_to_top');
    }
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        0.0,
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeInOut,
      );
    }
  }

  void _openArchive() {
    // Phase 3 adds a dedicated `archive_opened` event; for now reuse
    // `search_opened` with the archive-icon source.
    AnalyticsService().trackEvent('search_opened', {'source': 'archive_icon'});
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            const SearchScreen(source: 'archive_icon', autofocus: false),
      ),
    );
  }

  QotdHomeState _currentState(UserService userService) {
    final hasAnswered =
        _qotd != null && userService.hasAnsweredQuestion(_qotd!['id']);
    return qotdHomeState(
      qotdResolved: _qotdResolved,
      qotdExists: _qotdExists,
      hasAnswered: hasAnswered,
    );
  }

  void _fireHomeViewedAnalytics(QotdHomeState state) {
    String? value;
    switch (state) {
      case QotdHomeState.ask:
        value = 'ask';
        break;
      case QotdHomeState.answered:
        value = 'answered';
        break;
      case QotdHomeState.unavailable:
        value = 'loading_timeout';
        break;
      case QotdHomeState.loading:
        value = null; // Transient — not a resolved state.
        break;
    }
    if (value != null && value != _lastFiredAnalyticsState) {
      _lastFiredAnalyticsState = value;
      AnalyticsService().trackEvent('qotd_home_viewed', {
        'state': value,
        // Review 2026-09-22 A4: closes the push -> ask -> answer funnel
        // without a second event. `direct` means an ordinary app open.
        'entry_source': AppEntry.consumeLastSource() ?? 'direct',
        // F3: how long the resolve took, and how many of the 20 retries it
        // burned. `loading_timeout` had no way to say "how long".
        if (_qotdResolveMs != null) 'ms_to_state': _qotdResolveMs,
        'attempts': _qotdResolveAttempts,
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final appBarHeight =
        AppBar().preferredSize.height + MediaQuery.of(context).padding.top;
    final bottomInset = MediaQuery.of(context).padding.bottom;

    return Consumer<UserService>(
      builder: (context, userService, _) {
        final state = _currentState(userService);
        // Fire once per resolved-state change (covers ask/answered/timeout).
        _fireHomeViewedAnalytics(state);

        return Stack(
          children: [
            RefreshIndicator(
              onRefresh: _onRefresh,
              // Both listeners feed the FAB's at-bottom fade: scroll updates
              // while the user drags, metrics changes when content resizes
              // (state flips, first layout) without any scrolling.
              child: NotificationListener<ScrollMetricsNotification>(
                onNotification: (n) {
                  _reportAtBottom(n.metrics);
                  return false;
                },
                child: NotificationListener<ScrollNotification>(
                  onNotification: (n) {
                    _reportAtBottom(n.metrics);
                    return false;
                  },
                  child: SingleChildScrollView(
                    controller: _scrollController,
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: EdgeInsets.only(
                      top: appBarHeight + 8,
                      bottom: bottomInset + 120,
                    ),
                    child: Column(
                      children: [
                        _buildHeader(context),
                        QotdHeroCard(
                          state: state,
                          question: _qotd,
                          userService: userService,
                          onRetry: _resolveQotd,
                          refreshNonce: _heroRefreshNonce,
                        ),
                        // "Your network" at the page's full width, under the
                        // question card: the real graph once the viewer has
                        // answered and earned one, else the circle card below
                        // (demo until 5 friends, then the lick nudge). Archive
                        // link last so it closes the page.
                        if (state == QotdHomeState.answered && _qotd != null)
                          NetworkResultsSection(
                            questionId: _qotd!['id']?.toString() ?? '',
                            questionType: _qotd!['type']?.toString() ?? '',
                            prompt: _qotd!['prompt']?.toString(),
                            emoji: _qotd!['emoji']?.toString(),
                            approvalLabels: approvalLabelsFrom(_qotd),
                            surface: 'home',
                            realOnly: true,
                            padding:
                                const EdgeInsets.fromLTRB(16, 0, 16, 16),
                          ),
                        _buildNetworkDemo(context),
                        _buildArchiveLink(context),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  // The streak moved to the AppBar badge (compact StreakCard in MainScreen,
  // replacing the old Camo Counter badge). Header: the app-drawer tagline
  // ("> read(the_room)" / "know the world") with the logo to its right, both
  // centered together.
  /// Header above the QOTD: for signed-in users, their identity card (avatar,
  /// handle, My QR / Scan / Add) — the same card as the Community tab but
  /// display-only (editing stays on Community / Me). Guests keep the logo.
  Widget _buildHeader(BuildContext context) {
    final theme = Theme.of(context);
    if (context.watch<FriendService>().isAuthenticated) {
      return const Padding(
        padding: EdgeInsets.fromLTRB(16, 4, 16, 12),
        child: IdentityCard(editable: false, surface: 'home_identity'),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Image.asset(
            'assets/images/RTR-logo_Aug2025.png',
            height: 72,
            fit: BoxFit.contain,
          ),
          const SizedBox(width: 12),
          Flexible(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    '> read(the_room)',
                    style: TextStyle(
                      color: theme.textTheme.bodyLarge?.color,
                      fontSize: 24,
                    ),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'know the world',
                  style: TextStyle(
                    color: theme.textTheme.bodyMedium?.color,
                    fontSize: 14,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Archive entry point — a text link beneath the hero, present in every state
  /// so archive access is never stranded (replaces the removed header icon).
  Widget _buildArchiveLink(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
      child: Center(
        child: TextButton.icon(
          onPressed: _openArchive,
          icon: const Icon(Icons.manage_search, size: 20),
          label: const Text('Browse the archive'),
          style: TextButton.styleFrom(
            foregroundColor: theme.primaryColor,
          ),
        ),
      ),
    );
  }

  /// Hide is a 7-day snooze, not a permanent dismissal: the home screen is the
  /// daily surface, so the nudge must be closable, but the goal (5 friends)
  /// is worth re-surfacing once a week until it is met.
  Future<void> _loadNetworkDemoDismissed() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final until = DateTime.tryParse(
          prefs.getString(_kNetworkDemoSnoozedUntilKey) ?? '');
      final snoozed = until != null && DateTime.now().isBefore(until);
      if (mounted) setState(() => _networkDemoDismissed = snoozed);
    } catch (_) {
      // Prefs unavailable: keep the card hidden rather than risk a nag.
    }
  }

  Future<void> _dismissNetworkDemo() async {
    setState(() => _networkDemoDismissed = true);
    // friend_count is the whole point of the nudge — without it a dismissal
    // rate cannot be read against "how close were they to the goal".
    AnalyticsService().trackEvent('network_demo_dismissed', {
      'surface': 'home',
      'friend_count': _networkDemoFriendCount,
    });
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kNetworkDemoSnoozedUntilKey,
          DateTime.now().add(_kNetworkDemoSnooze).toIso8601String());
    } catch (_) {}
  }

  /// Grow-your-circle nudge — the sample ego graph with a "N of 5" progress
  /// line, shown until the viewer has kCircleFriendGoal friends (and not
  /// while snoozed). Reads FriendService reactively so it updates the moment
  /// a friendship is accepted.
  Widget _buildNetworkDemo(BuildContext context) {
    if (_networkDemoDismissed) return const SizedBox.shrink();
    return Consumer<FriendService>(
      builder: (context, friends, _) {
        if (!friends.isLoaded) return const SizedBox.shrink();
        // Owner rule 2026-09-20 (utils/network_card_logic.dart): sample
        // network under 5 friends; with a circle, the real map needs 3+
        // network members to have answered this question. The count comes from
        // `get_network_answered_counts` for today's QOTD, and is null until it
        // answers — or on a project where the linkage RPCs are not deployed.
        final state = networkCardState(
          friendCount: friends.friendCount,
          networkAnswered: _qotdNetworkAnswered,
        );
        _networkDemoFriendCount = friends.friendCount;
        if (state == NetworkCardState.realMap) {
          // The real card lives inside the QOTD hero, right under the room's
          // own numbers — drawing a second one here would say the same thing
          // twice on one screen.
          return const SizedBox.shrink();
        }
        if (state == NetworkCardState.notEnoughAnswers) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: NetworkNotEnoughCard(
              onDismiss: _dismissNetworkDemo,
              onSendLick: () {
                AnalyticsService().trackEvent('network_not_enough_cta_tapped',
                    {'surface': 'home', 'friend_count': friends.friendCount});
                widget.onRequestTab?.call(1);
              },
            ),
          );
        }
        // Remembered so the dismiss handler (which has no Consumer above it)
        // can report the same count the card was showing.
        _networkDemoFriendCount = friends.friendCount;
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: NetworkDemoCard(
            friendCount: friends.friendCount,
            onDismiss: _dismissNetworkDemo,
            onAddFriends: () {
              AnalyticsService().trackEvent('network_demo_cta_tapped',
                  {'surface': 'home', 'friend_count': friends.friendCount});
              // Adding a friend starts with showing your code (the dialog also
              // offers Scan). Guests have no code yet — they get the Community
              // tab's sign-in pitch instead.
              if (friends.isAuthenticated) {
                FriendQrDialog.show(context, surface: 'home_nudge');
              } else {
                widget.onRequestTab?.call(1);
              }
            },
          ),
        );
      },
    );
  }

}
