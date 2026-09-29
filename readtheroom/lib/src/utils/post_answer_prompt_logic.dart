// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Pure decision logic for the post-answer notification prompt.
//
// Before this file the decision was spread across three places that disagreed:
//   * `UserService.shouldShowNotificationPermissionDialog()` — the one-time
//     first ask, a bare `!notification_permission_shown`,
//   * `notification_reask_logic.dart` — the weekly re-ask, and
//   * `qotd_hero_card._maybeAskForNotifications` — the only caller that combined
//     them, which meant the ask existed *only* on the home hero. Answering the
//     QOTD from the Archive, a deep link, a discussion comment or the onboarding
//     replay recorded the answer and asked nothing.
//
// The combined rule now lives here, free of Flutter / Supabase /
// SharedPreferences so it is directly unit testable with an injected clock and
// an injected permission state. `PostAnswerPrompts` (services/) is the thin
// shell that reads the real state, calls this, and drives the UI.

import 'notification_reask_logic.dart';

/// The OS-level notification permission, mirroring `firebase_messaging`'s
/// `AuthorizationStatus` without importing it (that would drag Firebase into a
/// pure unit test). Map at the call site.
enum OsNotificationPermission {
  /// The user allowed notifications.
  authorized,

  /// The user explicitly refused. iOS will never re-show the system sheet, so a
  /// re-request is a dead call — only the Settings app can undo this.
  denied,

  /// Never asked. The system sheet is still available.
  notDetermined,

  /// iOS "deliver quietly" — notifications *are* delivered (to Notification
  /// Centre), so this counts as having permission, not as needing an ask.
  provisional,

  /// The status could not be read (Firebase unavailable, a widget test, a very
  /// early frame). Treated as [notDetermined] for deciding *how* to ask, but a
  /// caller may prefer to stay silent.
  unknown,
}

/// What to do about notification permission immediately after an answer.
enum PostAnswerPromptDecision {
  /// Say nothing: not a QOTD answer, permission already held, already accepted,
  /// or the cooling-off week has not elapsed.
  none,

  /// Show the in-app pre-prompt (`NotificationPermissionDialog`), which may go
  /// on to request the OS permission.
  showInAppPrompt,

  /// The OS permission is denied, so requesting it is a no-op: point the user at
  /// the system Settings page instead.
  openAppSettings,
}

/// `true` when [status] means notifications can actually be delivered.
///
/// [OsNotificationPermission.provisional] counts: iOS delivers provisional
/// notifications quietly, so asking again would be nagging a user who is already
/// reachable.
bool osPermissionAllowsDelivery(OsNotificationPermission status) =>
    status == OsNotificationPermission.authorized ||
    status == OsNotificationPermission.provisional;

/// The full post-answer decision.
///
/// - [answeredQotd]: the answer that just landed was for the effective QOTD
///   (real QOTD or its NSFW fallback). Archive / feed / deep-link answers to
///   other questions never trigger the ask — the prompt is tied to the daily
///   ritual, which is where it earns its keep.
/// - [everAsked]: the persisted `notification_permission_shown` bool. `false`
///   means this user has never seen the pre-prompt, so the *first*-ask gate
///   applies and the weekly cooling-off is irrelevant.
/// - [lastAskedAt]: the persisted `notification_permission_last_asked_at` stamp.
/// - [grantedInApp]: the user already accepted the in-app pre-prompt.
/// - [osStatus]: the live OS permission.
///
/// Order matters: permission already held short-circuits everything, so a user
/// who enabled notifications from Settings (or during onboarding) is never asked
/// again even though the persisted "asked" bookkeeping may say otherwise.
PostAnswerPromptDecision postAnswerNotificationPromptDecision({
  required DateTime now,
  required bool answeredQotd,
  required bool everAsked,
  DateTime? lastAskedAt,
  required bool grantedInApp,
  required OsNotificationPermission osStatus,
}) {
  if (!answeredQotd) return PostAnswerPromptDecision.none;

  // Already reachable: nothing to ask for. This is also the guard that stops the
  // first-ask gate from firing at a user who granted permission some other way
  // (Settings screen, the Activity/Community promo card, onboarding).
  if (osPermissionAllowsDelivery(osStatus)) {
    return PostAnswerPromptDecision.none;
  }

  final osDenied = osStatus == OsNotificationPermission.denied;

  // First ask: one-time, owned by `notification_permission_shown`. The weekly
  // gate deliberately abstains here (it returns `none` for a null stamp).
  if (!everAsked) {
    return osDenied
        ? PostAnswerPromptDecision.openAppSettings
        : PostAnswerPromptDecision.showInAppPrompt;
  }

  // Asked before: the weekly re-ask gate decides.
  switch (notificationReAskAction(
    now: now,
    lastAskedAt: lastAskedAt,
    grantedInApp: grantedInApp,
    osDenied: osDenied,
  )) {
    case NotificationReAskAction.none:
      return PostAnswerPromptDecision.none;
    case NotificationReAskAction.showInAppPrompt:
      return PostAnswerPromptDecision.showInAppPrompt;
    case NotificationReAskAction.openAppSettings:
      return PostAnswerPromptDecision.openAppSettings;
  }
}

/// How long a recorded-but-not-yet-shown prompt stays owed.
///
/// The onboarding replay (`PendingAnswerService.submitIfReady`) records the
/// answer while `OnboardingScreen` is being torn down, so the prompt cannot be
/// shown there — it is marked owed and drained by `MainScreen`. If the app dies
/// in between, the debt should not follow the user around for a week.
const Duration kPostAnswerPromptOwedWindow = Duration(hours: 24);

/// Whether an owed prompt recorded at [owedAt] is still fresh at [now].
///
/// A stamp from the future (clock skew) is treated as fresh, matching
/// `notificationReAskAction`'s handling of the same situation.
bool isPostAnswerPromptOwed({required DateTime now, DateTime? owedAt}) {
  if (owedAt == null) return false;
  if (now.isBefore(owedAt)) return true;
  return now.difference(owedAt) <= kPostAnswerPromptOwedWindow;
}

/// The state the Settings screen's notification section should render.
///
/// Split out pure so the three interesting states can be widget-tested with a
/// fake permission source instead of a live Firebase.
enum NotificationSettingsUiState {
  /// Not signed in: the toggles are gated behind authentication anyway.
  unauthenticated,

  /// Notifications can be delivered — render the toggles normally.
  granted,

  /// Turned off in the OS Settings app. Toggles cannot fix this, so show an
  /// explanation with an "Open Settings" action and stop pretending.
  osDenied,

  /// Never asked. Toggles work; enabling one shows the system sheet.
  notDetermined,
}

/// Whether the Settings section's master switch reads as on.
///
/// There is no server-side master flag to read — `notifications_enabled` is
/// deliberately never written by the client (it defaults to `true`, and the
/// pre-prompt's "Maybe later" must not be allowed to kill friend events). The
/// master row is therefore derived: it is on while *anything* can still arrive,
/// so turning it off is an unambiguous "send me nothing" and turning it on
/// cannot silently leave a category off.
bool notificationsMasterEnabled({
  required bool qotd,
  required bool responses,
  required bool friendEvents,
}) =>
    qotd || responses || friendEvents;

NotificationSettingsUiState notificationSettingsUiState({
  required bool isAuthenticated,
  required OsNotificationPermission osStatus,
}) {
  if (!isAuthenticated) return NotificationSettingsUiState.unauthenticated;
  if (osPermissionAllowsDelivery(osStatus)) {
    return NotificationSettingsUiState.granted;
  }
  if (osStatus == OsNotificationPermission.denied) {
    return NotificationSettingsUiState.osDenied;
  }
  // `unknown` renders like `notDetermined`: the toggles stay usable rather than
  // being locked out by a failed status read.
  return NotificationSettingsUiState.notDetermined;
}
