// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/friend_chat_service.dart';
import '../services/friend_service.dart';
import '../utils/friend_logic.dart';
import '../utils/haptic_utils.dart';
import 'chameleon_avatar.dart';
import 'friend_name_label.dart';

/// "Send to a friend" — the share-surface entry point for forwarding a
/// question (networks-update-design §5.4: forwards come from the share menu as
/// well as from inside the chat).
///
/// A list of accepted friends, with the viewer's private nicknames beside the
/// handles as on the friend list; one tap forwards and closes. Deliberately does
/// **not** touch the existing `Share.share` flow — this sits beside it as a
/// second action, because the two do different things: one hands the question
/// to the OS, the other sends it inside the app where a reply is possible.
class SendToFriendSheet {
  const SendToFriendSheet._();

  static Future<void> show({
    required BuildContext context,
    required String questionId,
    String source = 'share_menu',
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _SendToFriendSheet(
        questionId: questionId,
        source: source,
      ),
    );
  }
}

class _SendToFriendSheet extends StatefulWidget {
  const _SendToFriendSheet({required this.questionId, required this.source});

  final String questionId;
  final String source;

  @override
  State<_SendToFriendSheet> createState() => _SendToFriendSheetState();
}

class _SendToFriendSheetState extends State<_SendToFriendSheet> {
  /// Friends this sheet has already sent to, so a second tap is a no-op with a
  /// visible tick rather than a duplicate forward.
  final Set<String> _sent = <String>{};
  String? _sending;

  Future<void> _send(Friend friend) async {
    if (_sending != null || _sent.contains(friend.userId)) return;
    AppHaptics.lightImpact();
    setState(() => _sending = friend.userId);

    final chat = context.read<FriendChatService>();
    final result = await chat.forwardQuestion(
      friendId: friend.userId,
      questionId: widget.questionId,
      source: widget.source,
    );

    if (!mounted) return;
    setState(() {
      _sending = null;
      if (result.success) _sent.add(friend.userId);
    });

    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          result.success ? 'Sent to ${friend.displayHandle} 🦎' : result.message,
          style: const TextStyle(color: Colors.white),
        ),
        backgroundColor: Theme.of(context).primaryColor,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final friends = context.watch<FriendService>().friends;

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.7,
      ),
      decoration: BoxDecoration(
        color: theme.scaffoldBackgroundColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Center(
            child: Container(
              margin: const EdgeInsets.only(top: 12, bottom: 8),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey[400],
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 8, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Send to a friend',
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
                IconButton(
                  icon: Icon(Icons.close, color: Colors.grey[600]),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),
          if (friends.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
              child: Text(
                'Add a friend from the Community tab and you can pass '
                'questions straight to them.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(color: Colors.grey),
              ),
            )
          else
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                padding: const EdgeInsets.only(bottom: 24),
                itemCount: friends.length,
                itemBuilder: (context, index) {
                  final friend = friends[index];
                  final sent = _sent.contains(friend.userId);
                  final busy = _sending == friend.userId;
                  return ListTile(
                    leading: ChameleonAvatar(
                        avatarId: friend.avatarId,
                        size: 40,
                        closeFriend: friend.isClose),
                    title: FriendNameLabel(friend: friend),
                    trailing: busy
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Icon(
                            sent ? Icons.check_circle : Icons.send_outlined,
                            color: sent ? theme.primaryColor : Colors.grey[600],
                            size: 20,
                          ),
                    onTap: sent ? null : () => _send(friend),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

/// The "Send" action that opens [SendToFriendSheet], shaped like the `Share` /
/// `Report` buttons it sits between on every question screen.
///
/// Renders **nothing** when the viewer has no accepted friends: a share entry
/// whose only content is "you have no friends" is a dead end on six screens,
/// and the Community tab is where friends actually come from. It appears the
/// moment the first friendship is accepted, because it watches [FriendService].
class SendToFriendButton extends StatelessWidget {
  const SendToFriendButton({
    Key? key,
    required this.questionId,
    this.source = 'share_menu',
  }) : super(key: key);

  final String questionId;
  final String source;

  @override
  Widget build(BuildContext context) {
    bool hasFriends = false;
    try {
      hasFriends = context.watch<FriendService>().friends.isNotEmpty;
    } catch (_) {
      // No provider (tests, an early frame): behave as if there is nobody to
      // send to.
      hasFriends = false;
    }
    if (!hasFriends || questionId.isEmpty) return const SizedBox.shrink();

    return TextButton.icon(
      icon: const Icon(Icons.send_outlined),
      label: const Text('Send'),
      onPressed: () => SendToFriendSheet.show(
        context: context,
        questionId: questionId,
        source: source,
      ),
    );
  }
}
