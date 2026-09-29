// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';

import '../utils/friend_logic.dart';
import '../utils/haptic_utils.dart';
import 'chameleon_avatar.dart';

/// "You're friends now" — the moment a QR scan lands, shown on the phone that
/// was scanned (owner request 2026-09-23). The scanning phone gets the same
/// story from `FriendScannerScreen`'s full-page success state.
///
/// Shown by `MainScreen` from `FriendService.qrFriendAdded`, over whatever is
/// open — usually the My QR dialog, which stays underneath so the next friend
/// can scan straight away.
class NewFriendDialog extends StatelessWidget {
  const NewFriendDialog({Key? key, required this.friend}) : super(key: key);

  final Friend friend;

  /// Haptic first, then the dialog. Root navigator so it sits above the My QR
  /// dialog rather than inside a tab's navigator.
  static Future<void> show(BuildContext context, Friend friend) {
    AppHaptics.mediumImpact();
    return showDialog<void>(
      context: context,
      useRootNavigator: true,
      builder: (_) => NewFriendDialog(friend: friend),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ChameleonAvatar(avatarId: friend.avatarId, size: 84),
          const SizedBox(height: 16),
          Text(
            friend.displayHandle,
            textAlign: TextAlign.center,
            style: theme.textTheme.headlineSmall
                ?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Text(
            "You're friends now 🦎",
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyLarge
                ?.copyWith(color: theme.textTheme.bodySmall?.color),
          ),
        ],
      ),
      actions: [
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: () => Navigator.of(context).pop(),
            style: ElevatedButton.styleFrom(
              backgroundColor: theme.primaryColor,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
            child: const Text('Done'),
          ),
        ),
      ],
    );
  }
}
