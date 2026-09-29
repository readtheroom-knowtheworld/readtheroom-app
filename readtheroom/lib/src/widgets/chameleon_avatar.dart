// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../utils/avatar_catalog.dart';

/// Renders a user's chosen chameleon avatar by `avatar_id`.
///
/// Falls back to a neutral silhouette when the id is null or unknown (an id
/// written by a newer client must never break an older one).
class ChameleonAvatar extends StatelessWidget {
  const ChameleonAvatar({
    Key? key,
    required this.avatarId,
    this.size = 32,
    this.closeFriend = false,
  }) : super(key: key);

  /// `chameleon_01` … `chameleon_10`, or `null` for the placeholder.
  final String? avatarId;

  /// Rendered width/height in logical pixels (ring included).
  final double size;

  /// Draws the close-friend ring — a thin border in the app's teal primary
  /// colour — around the avatar (owner, 2026-09-22). The ring is part of
  /// [size], so a ringed and an unringed avatar line up in a list.
  final bool closeFriend;

  @override
  Widget build(BuildContext context) {
    final assetPath = avatarAssetPath(avatarId);
    final ring = closeFriend ? (size >= 40 ? 2.5 : 2.0) : 0.0;
    final inner = size - ring * 2;
    final Widget avatar = assetPath == null
        ? _ChameleonPlaceholder(size: inner)
        : ClipOval(
            child: SvgPicture.asset(
              assetPath,
              width: inner,
              height: inner,
              // The disc is baked into the artwork, so nothing else is needed
              // while the asset loads or if it fails to parse.
              placeholderBuilder: (_) => _ChameleonPlaceholder(size: inner),
              semanticsLabel: 'Chameleon avatar',
            ),
          );
    if (!closeFriend) return avatar;
    return Semantics(
      label: 'Close friend',
      container: true,
      child: Container(
        key: const ValueKey('close-friend-ring'),
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: Theme.of(context).primaryColor,
            width: ring,
          ),
        ),
        child: avatar,
      ),
    );
  }
}

/// Neutral chameleon silhouette used before a user picks an avatar (and as the
/// graceful fallback for an unknown id).
class _ChameleonPlaceholder extends StatelessWidget {
  const _ChameleonPlaceholder({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: theme.primaryColor.withOpacity(0.15),
        border: Border.all(color: theme.primaryColor.withOpacity(0.45)),
      ),
      alignment: Alignment.center,
      child: Text(
        '🦎',
        style: TextStyle(fontSize: size * 0.55),
      ),
    );
  }
}
