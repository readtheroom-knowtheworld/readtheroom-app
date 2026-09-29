// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Pure decision logic for re-asking notification permission (WP-A, item 4).
//
// The first ask happens right after the user's first successful QOTD answer
// (`UserService.shouldShowNotificationPermissionDialog`). This file owns the
// *second* ask: a user who declined the in-app pre-prompt is asked once more
// after a cooling-off week, and — because iOS will never re-show the system
// dialog once it has been denied — the re-ask deep-links to the app's Settings
// page instead of re-requesting when the OS permission is already denied.
//
// Kept free of Flutter/Supabase/SharedPreferences so it is directly unit
// testable with an injected clock.

/// How long to wait after a declined in-app pre-prompt before asking again.
const Duration kNotificationReAskInterval = Duration(days: 7);

/// What the app should do about notification permission right now.
enum NotificationReAskAction {
  /// Say nothing — already granted, too soon, or no ask on record.
  none,

  /// Show the in-app pre-prompt (`NotificationPermissionDialog`), which may go
  /// on to request the OS permission.
  showInAppPrompt,

  /// The OS permission is denied, so a request would be a no-op: point the user
  /// at the system Settings page instead.
  openAppSettings,
}

/// The full re-ask decision.
///
/// - [now] / [lastAskedAt]: the clock and the persisted
///   `notification_permission_last_asked_at` stamp (null = no ask on record,
///   which means the *first*-ask gate owns this user, not the re-ask gate).
/// - [grantedInApp]: the user already accepted the in-app pre-prompt — never
///   nag someone who said yes.
/// - [osDenied]: the OS-level permission is denied (`AuthorizationStatus.denied`).
NotificationReAskAction notificationReAskAction({
  required DateTime now,
  DateTime? lastAskedAt,
  required bool grantedInApp,
  required bool osDenied,
}) {
  if (grantedInApp) return NotificationReAskAction.none;
  if (lastAskedAt == null) return NotificationReAskAction.none;
  if (now.isBefore(lastAskedAt)) {
    // Clock skew / a stamp from the future: treat as "just asked".
    return NotificationReAskAction.none;
  }
  if (now.difference(lastAskedAt) < kNotificationReAskInterval) {
    return NotificationReAskAction.none;
  }
  return osDenied
      ? NotificationReAskAction.openAppSettings
      : NotificationReAskAction.showInAppPrompt;
}

/// Whether to re-ask at all. See [notificationReAskAction] for *how* to ask.
bool shouldReAskNotificationPermission({
  required DateTime now,
  DateTime? lastAskedAt,
  required bool grantedInApp,
  required bool osDenied,
}) {
  return notificationReAskAction(
        now: now,
        lastAskedAt: lastAskedAt,
        grantedInApp: grantedInApp,
        osDenied: osDenied,
      ) !=
      NotificationReAskAction.none;
}
