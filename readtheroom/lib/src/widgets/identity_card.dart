// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The viewer's identity card: chameleon avatar + handle, and the three
// add-a-friend actions (My QR / Scan / Add by handle). One widget, two homes:
//
//   • Community tab — `editable: true`: tapping the handle opens the username
//     sheet, tapping the avatar opens the avatar picker (the WP-C sheets, so
//     validation/cooldown copy cannot drift).
//   • Home screen (above the QOTD, replacing the logo header) —
//     `editable: false`: same card, same three actions, but the avatar and
//     handle are display-only. Editing lives on Community / Me.
//
// Requires ProfileService + FriendService above it. Guests never see it (the
// callers gate on FriendService.isAuthenticated).

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../screens/friend_scanner_screen.dart';
import '../services/friend_service.dart';
import '../services/profile_service.dart';
import '../utils/haptic_utils.dart';
import 'add_friend_by_username_sheet.dart';
import 'avatar_picker_sheet.dart';
import 'chameleon_avatar.dart';
import 'friend_qr_dialog.dart';
import 'username_edit_sheet.dart';

class IdentityCard extends StatelessWidget {
  final bool editable;

  /// Analytics surface tag for the QR dialog (`community` / `home`).
  final String surface;

  const IdentityCard({
    Key? key,
    required this.editable,
    this.surface = 'community',
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.primaryColor;
    final profile = context.watch<ProfileService>();
    final handle = profile.username;
    final hasHandle = (handle ?? '').isNotEmpty;

    final identityRow = Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          if (editable)
            GestureDetector(
              onTap: () {
                AppHaptics.lightImpact();
                AvatarPickerSheet.show(context);
              },
              child: ChameleonAvatar(avatarId: profile.avatarId, size: 52),
            )
          else
            ChameleonAvatar(avatarId: profile.avatarId, size: 52),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  hasHandle ? '@$handle' : 'Pick a name',
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 2),
                Text(
                  !hasHandle
                      ? 'Friends find you by your handle'
                      : (editable
                          ? 'Tap to change · avatar to restyle'
                          : 'Share your code to add friends'),
                  style: theme.textTheme.bodySmall?.copyWith(color: Colors.grey),
                ),
              ],
            ),
          ),
          if (editable)
            Icon(Icons.edit_outlined, size: 18, color: Colors.grey[500]),
        ],
      ),
    );

    return Container(
      decoration: BoxDecoration(
        color: theme.brightness == Brightness.dark
            ? Colors.white.withOpacity(0.04)
            : primary.withOpacity(0.05),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: primary.withOpacity(0.2)),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          if (editable)
            InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () {
                AppHaptics.lightImpact();
                UsernameEditSheet.show(context);
              },
              child: identityRow,
            )
          else
            identityRow,
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: _IdentityAction(
                  icon: Icons.qr_code_2_rounded,
                  label: 'My QR',
                  onTap: () {
                    AppHaptics.lightImpact();
                    FriendQrDialog.show(context, surface: surface);
                  },
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _IdentityAction(
                  icon: Icons.qr_code_scanner_rounded,
                  label: 'Scan',
                  onTap: () async {
                    AppHaptics.lightImpact();
                    final added = await FriendScannerScreen.push(context);
                    if (!context.mounted) return;
                    if (added == true) context.read<FriendService>().refresh();
                  },
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _IdentityAction(
                  icon: Icons.alternate_email_rounded,
                  label: 'Add',
                  onTap: () async {
                    AppHaptics.lightImpact();
                    final sent = await AddFriendByUsernameSheet.show(context);
                    if (!context.mounted) return;
                    if (sent == true) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: const Text('Friend request sent 🦎',
                              style: TextStyle(color: Colors.white)),
                          backgroundColor: theme.primaryColor,
                        ),
                      );
                    }
                  },
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _IdentityAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _IdentityAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.primaryColor;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: primary.withOpacity(0.10),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          children: [
            Icon(icon, color: primary, size: 22),
            const SizedBox(height: 4),
            Text(
              label,
              style: theme.textTheme.labelMedium?.copyWith(
                color: primary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
