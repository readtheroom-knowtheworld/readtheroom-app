// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/profile_service.dart';
import 'avatar_picker_sheet.dart';
import 'chameleon_avatar.dart';
import 'username_edit_sheet.dart';

/// Me-tab profile header: chameleon avatar + handle + an edit affordance.
///
/// Tapping the avatar opens the avatar picker (C2); tapping the name or "Edit"
/// opens [UsernameEditSheet]. Before anything is set it reads as a single
/// call-to-action row.
class ProfileHeader extends StatelessWidget {
  const ProfileHeader({Key? key, this.onTapAvatar}) : super(key: key);

  /// Overrides the default avatar-picker tap handler.
  final VoidCallback? onTapAvatar;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final profile = context.watch<ProfileService>();
    final username = profile.username;
    final hasUsername = (username ?? '').isNotEmpty;

    return Container(
      margin: const EdgeInsets.only(bottom: 20),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.primaryColor.withOpacity(0.2)),
      ),
      child: Row(
        children: [
          GestureDetector(
            onTap: onTapAvatar ?? () => AvatarPickerSheet.show(context),
            child: ChameleonAvatar(avatarId: profile.avatarId, size: 48),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  hasUsername ? '@$username' : 'Name your chameleon',
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.bold),
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  hasUsername
                      ? 'Only friends see this name'
                      : 'Pick a name and a chameleon',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: Colors.grey[600]),
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: () => UsernameEditSheet.show(context),
            child: Text(hasUsername ? 'Edit' : 'Set up'),
          ),
        ],
      ),
    );
  }
}
