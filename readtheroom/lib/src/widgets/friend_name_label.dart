// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';

import '../services/friend_nickname_service.dart';
import '../utils/friend_logic.dart';
import '../utils/friend_nickname_logic.dart';

/// A friend's handle, then the viewer's private nickname in light grey
/// parentheses: "@sam (Big Sis)".
///
/// Shared by the friend list, the chat overlay and the Send-to-a-friend sheet
/// so the three cannot drift. Do not use it on the network graphs or anywhere
/// an answer is revealed; see `friend_nickname_logic.dart`.
///
/// The nickname is the part that gives way when space is short, so the handle
/// stays readable.
class FriendNameLabel extends StatelessWidget {
  const FriendNameLabel({Key? key, required this.friend, this.style})
      : super(key: key);

  final Friend friend;

  /// Style of the handle. The nickname reuses it at normal weight in grey.
  final TextStyle? style;

  /// Key of the nickname text for [friendId], for widget tests.
  static String nicknameKeyFor(String friendId) => 'friend-nickname-$friendId';

  @override
  Widget build(BuildContext context) {
    final nickname = visibleFriendNickname(
      FriendNicknameService.maybeOf(context)?.nicknameFor(friend.userId),
      username: friend.username,
    );
    final handle = Text(
      friend.displayHandle,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: style,
    );
    if (nickname == null) return handle;
    return Row(
      children: [
        Flexible(child: handle),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            '($nickname)',
            key: ValueKey(nicknameKeyFor(friend.userId)),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: (style ?? const TextStyle()).copyWith(
              fontWeight: FontWeight.w400,
              color: Colors.grey,
            ),
          ),
        ),
      ],
    );
  }
}
