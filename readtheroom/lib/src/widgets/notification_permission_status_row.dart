// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';

import '../utils/post_answer_prompt_logic.dart';

/// Key of the OS-denied explanation, so a widget test can assert the state
/// without matching copy.
const String kNotificationStatusDeniedKey = 'notification-status-denied';

/// Key of the never-asked hint.
const String kNotificationStatusNotDeterminedKey =
    'notification-status-not-determined';

/// Key of the "Open Settings" button inside the denied row.
const String kNotificationOpenSettingsKey = 'notification-open-settings';

/// The header of the Settings screen's notification section: what the OS
/// actually thinks, rather than what the app's local prefs wish were true.
///
/// Before this row the section showed toggles alone. A user who had refused
/// notifications at the OS level saw switches they could flip — and flipping one
/// wrote a local bool, subscribed an FCM topic, and delivered nothing, with no
/// hint as to why. Worse, on iOS the in-app pre-prompt's "Count me in!" button
/// led to a `requestPermission` call the system silently ignores, so the flow
/// dead-ended in a success message.
///
/// Stateless and driven entirely by [state] (computed by
/// [notificationSettingsUiState]) so the three interesting cases are
/// widget-testable without Firebase.
class NotificationPermissionStatusRow extends StatelessWidget {
  const NotificationPermissionStatusRow({
    Key? key,
    required this.state,
    this.onOpenSettings,
  }) : super(key: key);

  final NotificationSettingsUiState state;

  /// Invoked by the denied row's action. Null hides the button (tests).
  final VoidCallback? onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    switch (state) {
      // Nothing to say: permission is held, or the toggles are already gated
      // behind the authentication prompt.
      case NotificationSettingsUiState.granted:
      case NotificationSettingsUiState.unauthenticated:
        return const SizedBox.shrink();

      case NotificationSettingsUiState.osDenied:
        return Container(
          key: const Key(kNotificationStatusDeniedKey),
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Colors.orange.withOpacity(0.1),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.orange.withOpacity(0.3)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.notifications_off,
                      size: 20, color: Colors.orange[700]),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Notifications are off in your device Settings',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: Colors.orange[700],
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                'The switches below remember what you want, but nothing can be '
                'delivered until notifications are allowed for Read the Room.',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: Colors.orange[800]),
              ),
              if (onOpenSettings != null) ...[
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    key: const Key(kNotificationOpenSettingsKey),
                    onPressed: onOpenSettings,
                    icon: const Icon(Icons.open_in_new, size: 18),
                    label: const Text('Open Settings'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.orange[700],
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        );

      case NotificationSettingsUiState.notDetermined:
        return Padding(
          key: const Key(kNotificationStatusNotDeterminedKey),
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Row(
            children: [
              Icon(Icons.info_outline, size: 18, color: theme.primaryColor),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Turning any of these on will ask for permission to send '
                  'notifications.',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: Colors.grey[600]),
                ),
              ),
            ],
          ),
        );
    }
  }
}
