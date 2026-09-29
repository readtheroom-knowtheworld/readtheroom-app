// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/profile_service.dart';
import '../utils/avatar_catalog.dart';
import 'chameleon_avatar.dart';

/// Bottom sheet: pick one of the ten chameleons. One tap selects and saves.
///
/// For a guest (no account yet) [ProfileService.setAvatar] stages the choice
/// locally; it is persisted right after passkey registration (WP-C3).
class AvatarPickerSheet extends StatelessWidget {
  const AvatarPickerSheet({Key? key}) : super(key: key);

  /// Returns the chosen avatar id, or null if dismissed.
  static Future<String?> show(BuildContext context) {
    return showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const AvatarPickerSheet(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey[400],
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Pick your chameleon',
              style: theme.textTheme.titleLarge
                  ?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            const AvatarGrid(),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

/// The 5×2 grid of selectable chameleons. Extracted so the onboarding
/// "Pick your chameleon" slide (WP-C3) can embed it without the sheet chrome.
class AvatarGrid extends StatelessWidget {
  const AvatarGrid({
    Key? key,
    this.onSelected,
    this.tileSize = 56,
    this.popOnSelect = true,
  }) : super(key: key);

  /// Extra callback after the selection is saved.
  final ValueChanged<String>? onSelected;

  final double tileSize;

  /// Whether picking should close an enclosing modal sheet.
  final bool popOnSelect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final profile = context.watch<ProfileService>();
    final selected = profile.avatarId;

    return Wrap(
      spacing: 12,
      runSpacing: 12,
      alignment: WrapAlignment.center,
      children: [
        for (final id in kChameleonAvatarIds)
          Semantics(
            selected: id == selected,
            button: true,
            label: 'Chameleon ${id.split('_').last}',
            child: InkWell(
              onTap: () async {
                await context.read<ProfileService>().setAvatar(id);
                onSelected?.call(id);
                if (popOnSelect && context.mounted) {
                  Navigator.of(context).maybePop(id);
                }
              },
              customBorder: const CircleBorder(),
              child: Container(
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: id == selected
                        ? theme.primaryColor
                        : Colors.transparent,
                    width: 3,
                  ),
                ),
                child: ChameleonAvatar(avatarId: id, size: tileSize),
              ),
            ),
          ),
      ],
    );
  }
}
