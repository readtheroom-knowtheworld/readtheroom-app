// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/profile_service.dart';
import 'avatar_picker_sheet.dart';
import 'chameleon_avatar.dart';

/// App-bar identity chip: the user's chameleon avatar, tappable to open the Me
/// tab (backlog item 3, "profile on header").
///
/// Deliberately avatar-only — the handle is private to friends (§5.1), so it is
/// never rendered in the app bar where a screenshot would expose it.
class ProfileAvatarChip extends StatelessWidget {
  const ProfileAvatarChip({
    Key? key,
    required this.onTap,
    this.size = 30,
  }) : super(key: key);

  /// Navigates to the Me tab.
  final VoidCallback onTap;

  final double size;

  @override
  Widget build(BuildContext context) {
    final avatarId = context.watch<ProfileService>().avatarId;
    return Semantics(
      button: true,
      label: 'Your profile',
      child: InkWell(
        onTap: onTap,
        // Shortcut straight to the picker; the tap target stays the Me tab so
        // the chip's primary action is unambiguous.
        onLongPress: () => AvatarPickerSheet.show(context),
        customBorder: const CircleBorder(),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: ChameleonAvatar(avatarId: avatarId, size: size),
        ),
      ),
    );
  }
}
