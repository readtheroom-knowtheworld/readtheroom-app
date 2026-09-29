// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/analytics_service.dart';
import '../services/friend_chat_service.dart';
import '../services/friend_service.dart';
import '../utils/demo_friends_mode.dart';
import '../utils/friend_logic.dart';
import '../utils/haptic_utils.dart';
import '../widgets/add_friend_by_username_sheet.dart';
import '../widgets/demo_friends_banner.dart';
import '../widgets/email_signup_card.dart';
import '../widgets/friend_chat_overlay.dart';
import '../widgets/friend_list_tile.dart';
import '../widgets/friend_nickname_dialog.dart';
import '../widgets/friend_qr_dialog.dart';
import '../widgets/identity_card.dart';
import '../widgets/network_demo_card.dart';
import '../widgets/notification_permission_card.dart';
import 'join_beta_screen.dart';

/// The Community tab — the friend graph's home (networks-update-design §5.3).
///
/// Top → bottom: identity card, pending requests, close friends, friends,
/// empty state, email signup + the beta link. Guests see a sign-in prompt only
/// (§5.2): every
/// friend RPC is granted to `authenticated`, so there is nothing a guest could
/// usefully do here.
///
/// The Phase-1 "coming soon" + DEMO sneak peek this replaced is gone; the
/// working email-capture card at the bottom is kept verbatim, now shared with
/// the Join-the-beta screen as `EmailSignupCard`.
class CommunityScreen extends StatefulWidget {
  const CommunityScreen({Key? key}) : super(key: key);

  @override
  State<CommunityScreen> createState() => _CommunityScreenState();
}

class _CommunityScreenState extends State<CommunityScreen> {
  /// Friend ids with an RPC in flight, so a row's controls disable rather than
  /// letting a double tap fire two mutations.
  final Set<String> _busyFriendIds = <String>{};

  @override
  void initState() {
    super.initState();
    // The provider loads on construction and on auth changes; this refresh
    // covers coming back to the tab after a request arrived elsewhere.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final friends = context.read<FriendService>();
      if (friends.isAuthenticated) friends.refresh();
    });
  }


  void _snack(String message, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message, style: const TextStyle(color: Colors.white)),
        backgroundColor:
            error ? Colors.orange : Theme.of(context).primaryColor,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Friend actions
  // ---------------------------------------------------------------------------

  /// Opens the chat overlay (§5.4). Only accepted friends have a chat — a
  /// pending row's tile has no `onTap`, and there is nothing to say to a
  /// request anyway.
  void onFriendTap(Friend friend) {
    AppHaptics.lightImpact();
    FriendChatOverlay.show(context, friend);
  }

  Future<void> _handleAction(Friend friend, FriendAction action) async {
    if (_busyFriendIds.contains(friend.userId)) return;

    // Local only: no RPC, so no busy state and no optimistic row change.
    if (action == FriendAction.setNickname) {
      final message = await editFriendNickname(context, friend);
      if (message != null) _snack(message);
      return;
    }

    // Both destructive actions confirm first; nothing else does.
    if (action == FriendAction.unfriend) {
      final confirmed = await _confirmUnfriend(friend);
      if (confirmed != true) return;
    } else if (action == FriendAction.block) {
      final confirmed = await _confirmBlock(friend);
      if (confirmed != true) return;
    }

    if (!mounted) return;
    setState(() => _busyFriendIds.add(friend.userId));

    final friends = context.read<FriendService>();
    FriendResult result;
    switch (action) {
      case FriendAction.setNickname:
        return; // handled above
      case FriendAction.accept:
        result = await friends.respondToRequest(friend.userId, true);
        break;
      case FriendAction.decline:
        result = await friends.respondToRequest(friend.userId, false);
        break;
      case FriendAction.cancelRequest:
        result = await friends.cancelRequest(friend.userId);
        break;
      case FriendAction.setClose:
        result = await friends.setCloseFriend(friend.userId, true,
            surface: 'community_menu');
        break;
      case FriendAction.unsetClose:
        result = await friends.setCloseFriend(friend.userId, false,
            surface: 'community_menu');
        break;
      case FriendAction.unfriend:
        result = await friends.unfriend(friend.userId);
        break;
      case FriendAction.block:
        result = await friends.blockUser(friend.userId, surface: 'community');
        break;
    }

    if (!mounted) return;
    setState(() => _busyFriendIds.remove(friend.userId));

    // The chat goes with the friendship, both here and server-side (WP-F
    // replaced unfriend()/block_user() to delete the pair's friend_events).
    // Only a block suppresses the live feed: an unfriended pair can become
    // friends again in this same session, and a suppression they never asked
    // for would silently swallow the new chat.
    if (action == FriendAction.unfriend || action == FriendAction.block) {
      context
          .read<FriendChatService>()
          .dropFriend(friend.userId, suppress: action == FriendAction.block);
    }

    if (!result.success) {
      _snack(result.message, error: true);
      return;
    }

    final confirmation = _successCopy(friend, action);
    if (confirmation != null) _snack(confirmation);
  }

  static String? _successCopy(Friend friend, FriendAction action) {
    switch (action) {
      case FriendAction.accept:
        return "You're friends with ${friend.displayHandle} now 🦎";
      case FriendAction.setClose:
        return '${friend.displayHandle} is a close friend — sharing your '
            'answers with them.';
      case FriendAction.unsetClose:
        return '${friend.displayHandle} is no longer a close friend.';
      case FriendAction.unfriend:
        return 'Removed ${friend.displayHandle}.';
      case FriendAction.block:
        return 'Blocked ${friend.displayHandle}.';
      case FriendAction.setNickname:
      case FriendAction.decline:
      case FriendAction.cancelRequest:
        // Silent: §5.2 says nobody is told, and neither is the actor nagged.
        return null;
    }
  }

  Future<bool?> _confirmUnfriend(Friend friend) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove ${friend.displayHandle}?'),
        // Copy verbatim from networks-update-design §5.2.
        content: Text(
          "Remove ${friend.displayHandle}? They won't be notified, and you'll "
          'disappear from each other\'s networks.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
  }

  Future<bool?> _confirmBlock(Friend friend) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Block ${friend.displayHandle}?'),
        content: const Text(
          "They'll be removed from your friends and won't be able to send you "
          "another request. They won't be told.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Block'),
          ),
        ],
      ),
    );
  }


  Future<void> _openAddByUsername() async {
    AppHaptics.lightImpact();
    final sent = await AddFriendByUsernameSheet.show(context);
    if (!mounted) return;
    if (sent == true) _snack('Friend request sent 🦎');
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final friends = context.watch<FriendService>();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Community'),
        centerTitle: false,
      ),
      body: SafeArea(
        child: friends.isAuthenticated
            ? _buildAuthenticated(context, friends)
            : _buildGuest(context),
      ),
    );
  }

  /// §5.2: "all social features require full auth (passkey). Guests see a
  /// sign-in prompt on the Community tab."
  Widget _buildGuest(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.primaryColor;

    return SingleChildScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(24, 32, 24, 120),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  colors: [
                    primary.withOpacity(0.85),
                    primary.withOpacity(0.45),
                  ],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
              ),
              child: const Icon(Icons.groups_rounded,
                  color: Colors.white, size: 52),
            ),
          ),
          const SizedBox(height: 24),
          Text(
            'Bring your people to the room',
            textAlign: TextAlign.center,
            style: theme.textTheme.headlineSmall
                ?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          Text(
            'Add friends, see how your circle reads the room, and share '
            "questions — all while everyone's individual answers stay private.\n\n"
            'Friends need a verified account, so nobody can be added by a bot.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.textTheme.bodySmall?.color,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 28),
          ElevatedButton.icon(
            onPressed: () {
              AppHaptics.lightImpact();
              Navigator.pushNamed(context, '/authentication');
            },
            icon: const Icon(Icons.verified_user_outlined),
            label: const Text('Verify that you are a human'),
            style: ElevatedButton.styleFrom(
              backgroundColor: primary,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
          ),
          const SizedBox(height: 32),
          _buildFooter(context),
        ],
      ),
    );
  }

  Widget _buildAuthenticated(BuildContext context, FriendService friends) {
    // Watched so a lick arriving while the tab is open lights the row's dot
    // and opening the chat (markRead) clears it, without a manual refresh.
    final chat = context.watch<FriendChatService>();
    final sections = friends.sections;

    return RefreshIndicator(
      onRefresh: friends.refresh,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 120),
        children: [
          // Debug-only marker: while "Demo friends" mode is on, nothing below
          // is real. Builds to nothing otherwise, and always in release.
          const DemoFriendsBanner(),
          _buildIdentityCard(context),
          const SizedBox(height: 20),

          // §5.3 last paragraph: the notification promo moves here too, since
          // friend events want push. Its own dismissal key, so hiding it on
          // Activity does not hide it here.
          const NotificationPermissionCard(
            dismissedPrefsKey: 'community_notification_widget_dismissed',
            title: 'Turn on friend alerts',
            message: "Friend requests and accepts arrive as notifications. "
                "Without them you'll only see requests when you open this tab.",
            enabledSnackBarMessage:
                "Notifications on — you'll hear about friend requests.",
            deniedSnackBarMessage:
                'Enable notifications in your device settings to hear about '
                'friend requests.',
          ),

          // One "Friends" section (owner decision 2026-09-22): close friends
          // first, then the rest, each group ordered by latest chat activity.
          // Within close friends, mutual ("sharing with each other") rows lead
          // the one-sided ones (owner decision 2026-09-23).
          // The close-friend ring on the avatar carries the distinction.
          if (sections.acceptedCount > 0) ...[
            _sectionHeader(context, 'Friends', count: sections.acceptedCount),
            for (final friend in sections.allAccepted)
              FriendListTile(
                key: ValueKey('friend-${friend.userId}'),
                friend: friend,
                hasUnread: chat.unreadFor(friend.userId) > 0,
                onAction: (action) => _handleAction(friend, action),
                onTap: () => onFriendTap(friend),
              ),
            const SizedBox(height: 12),
          ],

          // One "Friend requests" section under the graph (owner decision
          // 2026-09-22): incoming first, newest at the top, then the sent
          // ones — so the graph never gets pushed down by pending rows, and
          // the actionable incoming requests still lead the section.
          if (sections.pendingCount > 0) ...[
            _sectionHeader(context, 'Friend requests',
                count: sections.pendingCount),
            for (final friend in sections.incoming)
              PendingRequestTile(
                key: ValueKey('incoming-${friend.userId}'),
                friend: friend,
                busy: _busyFriendIds.contains(friend.userId),
                onAction: (action) => _handleAction(friend, action),
              ),
            for (final friend in sections.outgoing)
              PendingRequestTile(
                key: ValueKey('outgoing-${friend.userId}'),
                friend: friend,
                busy: _busyFriendIds.contains(friend.userId),
                onAction: (action) => _handleAction(friend, action),
              ),
            const SizedBox(height: 12),
          ],

          if (sections.isEmpty)
            friends.isLoaded
                ? _buildEmptyState(context)
                : const Padding(
                    padding: EdgeInsets.symmetric(vertical: 48),
                    child: Center(child: CircularProgressIndicator()),
                  ),

          // Grow-your-circle nudge: the sample ego graph with a "N of 5"
          // progress line, until the viewer has kCircleFriendGoal friends.
          // Below the real rows so the actionable list stays on top; hidden
          // in demo-friends mode (the seeded graph is the sample there).
          if (friends.isLoaded &&
              friends.friendCount < kCircleFriendGoal &&
              !DemoFriendsMode.instance.enabled) ...[
            const SizedBox(height: 20),
            NetworkDemoCard(
              friendCount: friends.friendCount,
              onAddFriends: () {
                AnalyticsService().trackEvent('network_demo_cta_tapped', {
                  'surface': 'community',
                  'friend_count': friends.friendCount,
                });
                FriendQrDialog.show(context, surface: 'community_nudge');
              },
            ),
          ],

          const SizedBox(height: 32),
          _buildFooter(context),
        ],
      ),
    );
  }

  /// §5.3(1): who you are, and the two ways to add someone.
  /// Identity card (avatar + handle + My QR / Scan / Add). Shared with the
  /// home screen, where it renders non-editable.
  Widget _buildIdentityCard(BuildContext context) =>
      const IdentityCard(editable: true, surface: 'community');

  Widget _sectionHeader(BuildContext context, String title, {int? count}) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(left: 4, top: 8, bottom: 4),
      child: Row(
        children: [
          Text(
            title,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
              color: Colors.grey[600],
            ),
          ),
          if (count != null) ...[
            const SizedBox(width: 8),
            Text(
              '$count',
              style: theme.textTheme.titleSmall?.copyWith(color: Colors.grey),
            ),
          ],
        ],
      ),
    );
  }

  /// §5.3(4): explainer + the two add CTAs.
  Widget _buildEmptyState(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.primaryColor;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Column(
        children: [
          Icon(Icons.group_add_outlined,
              size: 56, color: primary.withOpacity(0.6)),
          const SizedBox(height: 16),
          Text(
            'No friends yet',
            style: theme.textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Text(
            'Scan a friend\'s QR code when you\'re together, or add them by '
            'their exact handle. Their individual answers stay private unless '
            'you both add each other as close friends.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: Colors.grey,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 20),
          // Why bother: the sample ego-network graph, clearly DEMO-badged.
          // The add CTAs sit right below it, so the card's own CTA is off.
          // Suppressed in demo-friends mode: the seeded graph already *is* the
          // sample, and two demo surfaces arguing on one screen reads as a bug.
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () {
                    AppHaptics.lightImpact();
                    FriendQrDialog.show(context);
                  },
                  icon: const Icon(Icons.qr_code_2_rounded, size: 18),
                  label: const Text('My QR'),
                  style: OutlinedButton.styleFrom(foregroundColor: primary),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _openAddByUsername,
                  icon: const Icon(Icons.alternate_email_rounded, size: 18),
                  label: const Text('Add by name'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: primary,
                    foregroundColor: Colors.white,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Bottom of the tab: the shared email card, then the door into the beta.
  ///
  /// `EmailSignupCard` hides itself once the user is on the list, so the link
  /// has to carry its own spacing rather than lean on the card above it.
  Widget _buildFooter(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // A rule closes the friends part of the page; what follows (keep in
        // touch, the beta) is about the app, not your circle.
        const Divider(height: 1),
        const SizedBox(height: 20),
        const EmailSignupCard(source: 'community_tab'),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: Theme.of(context).primaryColor,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            onPressed: () {
              AppHaptics.lightImpact();
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const JoinBetaScreen(source: 'community'),
                ),
              );
            },
            // Same rocket as the drawer's Join the beta entry.
            icon: const Icon(Icons.rocket_launch_outlined, size: 20),
            label: const Text(
              'Join the beta',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
        ),
      ],
    );
  }
}
