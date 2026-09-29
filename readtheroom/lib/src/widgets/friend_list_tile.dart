// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';

import '../utils/friend_logic.dart';
import '../utils/haptic_utils.dart';
import 'chameleon_avatar.dart';
import 'friend_name_label.dart';

/// One row in the Community tab's Close friends / Friends lists (§5.3(3)):
/// avatar + handle (+ the viewer's private nickname in light grey), with the
/// streak flair, unread dot and overflow menu at the far right.
/// An unread dot sits left of the menu when the friend has sent something the
/// viewer has not opened yet (owner request 2026-09-23), so the row that
/// needs opening is obvious without reading the whole list.
///
/// Streak is the only flair shown, per OQ-3's proposal ("streak only, with a
/// toggle later if requested") — it is the one activity signal `get_friends()`
/// returns, and deliberately the only one.
class FriendListTile extends StatelessWidget {
  const FriendListTile({
    Key? key,
    required this.friend,
    required this.onAction,
    this.onTap,
    this.hasUnread = false,
  }) : super(key: key);

  final Friend friend;

  /// True when this friend has unread chat events. Draws the dot beside the
  /// overflow menu, in the same primary colour and size as the Community
  /// tab's badge so the two read as one signal.
  final bool hasUnread;

  /// Invoked with the chosen overflow action.
  final void Function(FriendAction action) onAction;

  /// Tapping the row. WP-F replaces this with the chat overlay; until then the
  /// Community tab wires it to a "Chat is coming next" SnackBar.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final actions = availableActions(friend);

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      leading: ChameleonAvatar(
          avatarId: friend.avatarId, size: 44, closeFriend: friend.isClose),
      title: _buildTitle(context),
      subtitle: _buildSubtitle(context),
      trailing: _buildTrailing(context, actions),
      onTap: onTap,
    );
  }

  Widget _buildTitle(BuildContext context) => FriendNameLabel(
        friend: friend,
        style: Theme.of(context)
            .textTheme
            .titleSmall
            ?.copyWith(fontWeight: FontWeight.w600),
      );

  /// Key of the nickname label on [friendId]'s row, for widget tests.
  static String nicknameKeyFor(String friendId) =>
      FriendNameLabel.nicknameKeyFor(friendId);

  /// Streak flair, then the unread dot, then the overflow menu, all at the
  /// far right. The dot still shows when the friend has no legal actions, so
  /// the signal never depends on the menu being there.
  Widget? _buildTrailing(BuildContext context, Set<FriendAction> actions) {
    final streak = friend.hasStreakFlair
        ? Tooltip(
            message: '${friend.streak}-day answer streak',
            child: _StreakFlair(streak: friend.streak!),
          )
        : null;

    final dot = hasUnread
        ? Semantics(
            label: 'Unread messages',
            child: Container(
              key: ValueKey(unreadDotKeyFor(friend.userId)),
              width: 8,
              height: 8,
              margin: const EdgeInsets.only(right: 4),
              decoration: BoxDecoration(
                color: Theme.of(context).primaryColor,
                shape: BoxShape.circle,
              ),
            ),
          )
        : null;

    final menu = actions.isEmpty
        ? null
        : PopupMenuButton<FriendAction>(
            icon: const Icon(Icons.more_vert),
            tooltip: 'Friend options',
            onSelected: (action) {
              AppHaptics.lightImpact();
              onAction(action);
            },
            itemBuilder: (_) => [
              for (final action in _menuOrder)
                if (actions.contains(action))
                  PopupMenuItem<FriendAction>(
                    value: action,
                    child: Row(
                      children: [
                        Icon(_iconFor(action), size: 18),
                        const SizedBox(width: 10),
                        // Flexible, not a bare Text: the menu is anchored at
                        // the row's right edge, so on a narrow screen the
                        // available width is less than the longest label.
                        Flexible(
                          child: Text(
                            _labelFor(action),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
            ],
          );

    final children = <Widget>[
      if (streak != null) streak,
      if (dot != null) ...[
        if (streak != null) const SizedBox(width: 8),
        dot,
      ],
      if (menu != null) menu,
    ];
    if (children.isEmpty) return null;
    if (menu == null) {
      return Padding(
        padding: const EdgeInsets.only(right: 12),
        child: Row(mainAxisSize: MainAxisSize.min, children: children),
      );
    }
    if (children.length == 1) return menu;
    return Row(mainAxisSize: MainAxisSize.min, children: children);
  }

  /// Key of the unread dot on [friendId]'s row, for widget tests.
  static String unreadDotKeyFor(String friendId) => 'friend-unread-$friendId';

  Widget? _buildSubtitle(BuildContext context) {
    final theme = Theme.of(context);
    // Only close friends get a subtitle, and only to tell the honest story
    // about reciprocity (§5.2) — a one-sided "close" shares nothing.
    if (!friend.isClose) return null;
    final text = friend.mutualClose
        ? 'Sharing answers'
        : 'Sharing your answers';
    return Text(
      text,
      style: theme.textTheme.bodySmall?.copyWith(
        color: friend.mutualClose ? theme.primaryColor : Colors.grey,
      ),
    );
  }

  /// Menu order is fixed so the destructive items are always last.
  static const List<FriendAction> _menuOrder = [
    FriendAction.accept,
    FriendAction.decline,
    FriendAction.cancelRequest,
    FriendAction.setNickname,
    FriendAction.setClose,
    FriendAction.unsetClose,
    FriendAction.unfriend,
    FriendAction.block,
  ];

  static String _labelFor(FriendAction action) {
    switch (action) {
      case FriendAction.accept:
        return 'Accept';
      case FriendAction.decline:
        return 'Decline';
      case FriendAction.cancelRequest:
        return 'Cancel request';
      case FriendAction.setNickname:
        return 'Set nickname';
      case FriendAction.setClose:
        return 'Set as close friend';
      case FriendAction.unsetClose:
        return 'Remove as close friend';
      case FriendAction.unfriend:
        return 'Remove friend';
      case FriendAction.block:
        return 'Block';
    }
  }

  static IconData _iconFor(FriendAction action) {
    switch (action) {
      case FriendAction.accept:
        return Icons.check_rounded;
      case FriendAction.decline:
        return Icons.close_rounded;
      case FriendAction.cancelRequest:
        return Icons.undo_rounded;
      case FriendAction.setNickname:
        return Icons.edit_outlined;
      case FriendAction.setClose:
        return Icons.favorite_rounded;
      case FriendAction.unsetClose:
        return Icons.favorite_border_rounded;
      case FriendAction.unfriend:
        return Icons.person_remove_outlined;
      case FriendAction.block:
        return Icons.block_rounded;
    }
  }
}

/// Streak flair — the same 🔥 + count idiom the streak card uses.
class _StreakFlair extends StatelessWidget {
  const _StreakFlair({required this.streak});

  final int streak;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.orange.withOpacity(0.14),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        '🔥 $streak',
        style: theme.textTheme.labelSmall?.copyWith(
          fontWeight: FontWeight.w700,
          color: Colors.orange[800],
        ),
      ),
    );
  }
}

/// A pending-request row: avatar + handle, plus either accept/decline buttons
/// (incoming) or a "Sent" label with a cancel button (outgoing) — §5.3(2).
class PendingRequestTile extends StatelessWidget {
  const PendingRequestTile({
    Key? key,
    required this.friend,
    required this.onAction,
    this.busy = false,
  }) : super(key: key);

  final Friend friend;
  final void Function(FriendAction action) onAction;

  /// Disables the controls while an RPC is in flight.
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.primaryColor;
    final incoming = friend.isIncomingRequest;

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      leading: ChameleonAvatar(avatarId: friend.avatarId, size: 44),
      title: Text(
        friend.displayHandle,
        overflow: TextOverflow.ellipsis,
        style:
            theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        incoming ? 'Wants to be friends' : 'Request sent',
        style: theme.textTheme.bodySmall?.copyWith(color: Colors.grey),
      ),
      trailing: incoming
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: 'Decline',
                  icon: const Icon(Icons.close_rounded),
                  color: Colors.grey,
                  onPressed:
                      busy ? null : () => onAction(FriendAction.decline),
                ),
                IconButton(
                  tooltip: 'Accept',
                  icon: const Icon(Icons.check_circle_rounded),
                  color: primary,
                  onPressed: busy ? null : () => onAction(FriendAction.accept),
                ),
              ],
            )
          : TextButton(
              onPressed:
                  busy ? null : () => onAction(FriendAction.cancelRequest),
              child: const Text('Cancel'),
            ),
    );
  }
}
