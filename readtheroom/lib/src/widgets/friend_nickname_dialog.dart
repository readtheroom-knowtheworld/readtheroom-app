// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';

import '../services/friend_nickname_service.dart';
import '../utils/friend_logic.dart';
import '../utils/friend_nickname_logic.dart';
import '../utils/haptic_utils.dart';

/// "Set nickname", shared by the friend list's overflow menu and the chat
/// overlay's, so the two cannot drift.
///
/// Returns the confirmation to show in a SnackBar, or null when nothing
/// changed (cancelled, or saved the same value). Each surface shows the
/// SnackBar itself because the chat overlay has its own ScaffoldMessenger.
Future<String?> editFriendNickname(BuildContext context, Friend friend) async {
  final service = FriendNicknameService.maybeOf(context, listen: false);
  if (service == null) return null;
  await service.load();
  if (!context.mounted) return null;

  final current = service.nicknameFor(friend.userId);
  final choice = await showDialog<_NicknameChoice>(
    context: context,
    builder: (_) => _FriendNicknameDialog(friend: friend, current: current),
  );
  if (choice == null) return null;

  final next = normalizeFriendNickname(choice.value);
  if (next == current) return null;
  AppHaptics.lightImpact();
  final saved = await service.setNickname(friend.userId, next);
  return saved == null ? 'Nickname removed' : 'Nickname saved';
}

class _NicknameChoice {
  const _NicknameChoice(this.value);
  final String? value;
}

class _FriendNicknameDialog extends StatefulWidget {
  const _FriendNicknameDialog({required this.friend, required this.current});

  final Friend friend;
  final String? current;

  @override
  State<_FriendNicknameDialog> createState() => _FriendNicknameDialogState();
}

class _FriendNicknameDialogState extends State<_FriendNicknameDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.current ?? '');

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() => Navigator.of(context).pop(_NicknameChoice(_controller.text));

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('Set nickname'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Only you can see this. It stays on this device, even if '
            '${widget.friend.displayHandle} changes their username.',
            style: theme.textTheme.bodySmall?.copyWith(color: Colors.grey),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('friend-nickname-field'),
            controller: _controller,
            autofocus: true,
            maxLength: kFriendNicknameMaxLength,
            textCapitalization: TextCapitalization.words,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _save(),
            decoration: const InputDecoration(
              hintText: 'Nickname',
              isDense: true,
            ),
          ),
        ],
      ),
      actions: [
        if (widget.current != null)
          TextButton(
            onPressed: () =>
                Navigator.of(context).pop(const _NicknameChoice(null)),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Remove'),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: _save,
          child: const Text('Save'),
        ),
      ],
    );
  }
}
