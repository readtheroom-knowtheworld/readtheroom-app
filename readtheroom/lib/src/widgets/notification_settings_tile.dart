// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// One row of the Settings → Notifications section.
//
// The section used to be a column of `SwitchListTile`s carrying two- and
// three-sentence subtitles, each followed by its own indented `ListTile` block
// for a time picker — six screens of scrolling to answer "what will this app
// send me?". This tile is the replacement unit: icon, title, **one** short
// line, an optional inline chip (the QOTD time, the quiet-hours window) and the
// switch, all on a single row.
//
// Extracted into its own widget rather than a private helper in
// `settings_screen.dart` because `SettingsScreen` cannot be pumped — it touches
// `Supabase.instance` in `initState` and `build` — so a private version would
// be untestable, exactly like the section it replaces.

import 'package:flutter/material.dart';

/// Key prefix for a tile's switch: `notification-toggle-<id>`.
String notificationToggleKey(String id) => 'notification-toggle-$id';

/// Key prefix for a tile's inline chip: `notification-chip-<id>`.
String notificationChipKey(String id) => 'notification-chip-$id';

/// A compact notification preference row.
class NotificationSettingsTile extends StatelessWidget {
  const NotificationSettingsTile({
    Key? key,
    required this.id,
    required this.icon,
    required this.title,
    this.subtitle,
    required this.value,
    required this.onChanged,
    this.chipLabel,
    this.onChipTap,
    this.emphasised = false,
  }) : super(key: key);

  /// Stable id used for the widget keys (`qotd`, `activity`, `friends`, …).
  final String id;

  final IconData icon;
  final String title;

  /// At most one short line. Anything longer belongs in the guide, not here.
  /// Optional: a row whose title says it all carries no second line.
  final String? subtitle;

  final bool value;
  final ValueChanged<bool> onChanged;

  /// Inline control shown between the text and the switch — the QOTD reminder
  /// time, or the quiet-hours window. Null hides it, which is how a row
  /// "expands" when its toggle is on without growing a second block.
  final String? chipLabel;
  final VoidCallback? onChipTap;

  /// The master row: heavier title, so the section reads as one switch plus its
  /// refinements rather than five equal peers.
  final bool emphasised;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final active = value ? theme.primaryColor : Colors.grey;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          Icon(icon, size: 20, color: active),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: emphasised
                      ? theme.textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w600)
                      : theme.textTheme.bodyLarge,
                ),
                if ((subtitle ?? '').isNotEmpty)
                  Text(
                    subtitle!,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: Colors.grey[600]),
                  ),
              ],
            ),
          ),
          if (chipLabel != null) ...[
            const SizedBox(width: 8),
            InkWell(
              key: Key(notificationChipKey(id)),
              onTap: onChipTap,
              borderRadius: BorderRadius.circular(12),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: theme.primaryColor.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: theme.primaryColor.withOpacity(0.3),
                  ),
                ),
                child: Text(
                  chipLabel!,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: theme.primaryColor,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ],
          Switch(
            key: Key(notificationToggleKey(id)),
            value: value,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}
