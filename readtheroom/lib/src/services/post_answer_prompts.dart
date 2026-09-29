// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../utils/post_answer_prompt_logic.dart';
import '../utils/qotd_pick_logic.dart';
import '../widgets/notification_permission_dialog.dart';
import '../widgets/streak_celebration_animation.dart';
import 'analytics_service.dart';
import 'notification_service.dart';
import 'profile_service.dart';
import 'qotd_pick_prompt.dart';
import 'question_service.dart' show StreakUpdateEvent;
import 'user_service.dart';

/// The single place that decides, and performs, the "enable notifications" ask
/// after a QOTD answer.
///
/// ## Why a coordinator
///
/// The owner's requirement — "the enable notifications prompt should happen
/// after the user answers their first QOTD" — was only met on the home hero
/// card. Every other way to answer today's question recorded the answer and
/// asked nothing:
///
/// | Path | Before |
/// |---|---|
/// | home hero `_submit` | asked (the only working path) |
/// | `answer_approval_screen` / `answer_multiple_choice_screen` (Archive, deep link, search) | no ask |
/// | discussion (`text`) answers via `comments_overlay` | no ask |
/// | onboarding replay (`PendingAnswerService.submitIfReady`) | no ask — **the brand-new user, the case that matters most** |
///
/// The decision now lives in [postAnswerNotificationPromptDecision] (pure) and
/// the performance lives here. Surfaces do one of two things:
///
///  * [markQotdAnswered] — called from `UserService.addAnsweredQuestion`, the
///    choke point every path reaches. It has no `BuildContext`, so it only
///    records that a prompt is *owed* (SharedPreferences, so it survives the
///    `OnboardingScreen` → `MainScreen` replacement and a cold start).
///  * [maybeShow] — called from a surface that has a context and a settled UI.
///    It drains the debt and shows the prompt.
///
/// ## Sequencing
///
/// [maybeShow] is a no-op while [isShowing] is true, so two surfaces racing
/// (e.g. a results screen and `MainScreen`) cannot stack two dialogs. It also
/// waits [_settleDelay] before showing anything, so the prompt lands after the
/// results/reveal animation rather than on top of it.
///
/// ## Interop with the app-store review request
///
/// Another agent is adding an app-review request that fires ~1.5 s after
/// `UserService.addAnsweredQuestion`. This prompt takes priority: check
/// [isShowing] (and, for a request that may be scheduled *before* this one
/// resolves, [isPending]) and skip or defer the review ask. Nothing in this file
/// touches app-review state.
class PostAnswerPrompts {
  PostAnswerPrompts._();

  /// SharedPreferences key holding the ISO-8601 time a prompt became owed.
  static const String owedAtPrefsKey =
      'post_answer_notification_prompt_owed_at';

  /// How long to let the results/reveal settle before interrupting with a
  /// dialog. Long enough that the answer visibly registered, short enough that
  /// the prompt still reads as a consequence of answering.
  static const Duration _settleDelay = Duration(milliseconds: 900);

  static bool _showing = false;
  static bool _pendingInMemory = false;

  /// `true` while the pre-prompt dialog (or its Settings nudge) is on screen.
  ///
  /// Named for the app-review agent: check this before showing any other
  /// post-answer interruption.
  static bool get isShowing => _showing;

  /// `true` when an answer has been recorded this session and the prompt has not
  /// yet been resolved. Also useful to the app-review agent: a review request
  /// scheduled on a timer should skip while this is set.
  static bool get isPending => _pendingInMemory;

  /// Test seam: overrides the OS permission read so widget/unit tests do not
  /// need a live Firebase. Null means "read the real status".
  @visibleForTesting
  static OsNotificationPermission? debugOsStatusOverride;

  /// Test seam: set by [maybeShow] to the decision it acted on.
  @visibleForTesting
  static PostAnswerPromptDecision? debugLastDecision;

  /// Reads the live OS permission, mapped onto the pure enum.
  ///
  /// Never throws: `NotificationService()`'s constructor touches
  /// `FirebaseMessaging.instance`, which throws when Firebase is not
  /// initialised, and an unreadable status must not break an answer submit.
  static Future<OsNotificationPermission> osPermission() async {
    final override = debugOsStatusOverride;
    if (override != null) return override;
    try {
      switch (await NotificationService().getPermissionStatus()) {
        case AuthorizationStatus.authorized:
          return OsNotificationPermission.authorized;
        case AuthorizationStatus.denied:
          return OsNotificationPermission.denied;
        case AuthorizationStatus.notDetermined:
          return OsNotificationPermission.notDetermined;
        case AuthorizationStatus.provisional:
          return OsNotificationPermission.provisional;
      }
    } catch (e) {
      debugPrint('PostAnswerPrompts: could not read permission status: $e');
      return OsNotificationPermission.unknown;
    }
  }

  /// Requests the OS permission, never throwing.
  ///
  /// Same defensive wrapper as [osPermission]: `NotificationService()` reaches
  /// for `FirebaseMessaging.instance`, which throws when Firebase is not
  /// initialised. Callers want a bool, not an exception.
  static Future<bool> requestPermissions() async {
    try {
      return await NotificationService().requestPermissions();
    } catch (e) {
      debugPrint('PostAnswerPrompts: permission request failed: $e');
      return false;
    }
  }

  /// Records that the effective QOTD was just answered, so the prompt is owed.
  ///
  /// Called from `UserService.addAnsweredQuestion` for QOTD answers only (the
  /// same `counts_for_streak` test). Contextless by design — the onboarding
  /// replay runs while its screen is being torn down.
  ///
  /// Deliberately records unconditionally rather than pre-computing the
  /// decision: evaluating it needs an async permission read, and the whole point
  /// of this hook is that it cannot block or fail a submit. [maybeShow] decides.
  static Future<void> markQotdAnswered({DateTime? at}) async {
    _pendingInMemory = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          owedAtPrefsKey, (at ?? DateTime.now()).toIso8601String());
    } catch (e) {
      // Non-fatal: the in-memory flag still covers the same-session surfaces.
      debugPrint('PostAnswerPrompts: could not persist owed flag: $e');
    }
  }

  /// Clears the owed debt without showing anything.
  static Future<void> clearOwed() async {
    _pendingInMemory = false;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(owedAtPrefsKey);
    } catch (e) {
      debugPrint('PostAnswerPrompts: could not clear owed flag: $e');
    }
  }

  static Future<DateTime?> _owedAt() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(owedAtPrefsKey);
      return raw == null ? null : DateTime.tryParse(raw);
    } catch (e) {
      debugPrint('PostAnswerPrompts: could not read owed flag: $e');
      return null;
    }
  }

  /// Shows the notification pre-prompt if one is owed and the state says to ask.
  ///
  /// Call from any surface that is visible after a QOTD answer: the home hero,
  /// the three results screens, the discussion overlay, and `MainScreen` (which
  /// catches the onboarding replay and anything left over from a killed app).
  ///
  /// [source] is for analytics only. Safe to call on every build-once hook —
  /// with no debt on record it does nothing and touches no UI.
  static Future<void> maybeShow(
    BuildContext context, {
    required UserService userService,
    required String source,
    DateTime? now,
  }) async {
    if (_showing) return;

    final at = now ?? DateTime.now();
    final owedAt = await _owedAt();
    if (!_pendingInMemory && !isPostAnswerPromptOwed(now: at, owedAt: owedAt)) {
      // Either no debt at all, or a stamp old enough to forget.
      if (owedAt != null) await clearOwed();
      return;
    }

    // A held streak celebration belongs to this drain whatever happens next.
    final heldStreak = _heldStreak;
    _heldStreak = null;

    final osStatus = await osPermission();
    final decision = postAnswerNotificationPromptDecision(
      now: at,
      answeredQotd: true, // the debt itself is the QOTD test
      everAsked: userService.notificationPermissionShown,
      lastAskedAt: userService.notificationPermissionLastAskedAt,
      grantedInApp: userService.notificationPermissionGrantedInApp,
      osStatus: osStatus,
    );
    debugLastDecision = decision;

    // Resolved either way: the debt is settled here, not re-evaluated forever.
    await clearOwed();
    if (!context.mounted) {
      // The surface left; the streak card listens app-wide, so the streak
      // celebration can still play without this context.
      _fireStreak(heldStreak);
      return;
    }

    _showing = true;
    try {
      // Let the results / reveal finish before interrupting. The first-answerer
      // check (one count RPC + the candidate fetch) runs inside the same wait.
      // The "asked" stamp is deliberately written *after* this: if the user
      // leaves during the delay nothing was shown, and burning the stamp would
      // buy seven days of silence for a prompt they never saw. The debt is
      // already cleared, so this cannot loop — the next QOTD answer records a
      // fresh one.
      final offerFuture = QotdPickPrompt.resolveOffer(context);
      await Future<void>.delayed(_settleDelay);
      final offer = await offerFuture;
      if (!context.mounted) {
        _fireStreak(heldStreak);
        return;
      }

      final dialogShown =
          decision == PostAnswerPromptDecision.showInAppPrompt;

      if (decision != PostAnswerPromptDecision.none) {
        await userService.recordNotificationPermissionAsked();
        AnalyticsService().trackQotdNotificationPermissionRequested();
        AnalyticsService().trackEvent('notification_prompt_shown', {
          'source': source,
          'decision': decision.name,
          'os_status': osStatus.name,
        });

        if (decision == PostAnswerPromptDecision.openAppSettings) {
          // A SnackBar, not a dialog: it sits under the celebration fine.
          _showSettingsNudge(context);
        } else {
          await NotificationPermissionDialog.show(
            context,
            onPermissionGranted: () async {
              AnalyticsService().trackQotdNotificationPermissionResult(true);
              AnalyticsService().trackNotificationPromptResult(
                  source: source, granted: true);
              await userService.onNotificationPermissionsGranted();
            },
            onPermissionDenied: () async {
              AnalyticsService().trackQotdNotificationPermissionResult(false);
              AnalyticsService().trackNotificationPromptResult(
                  source: source, granted: false);
              await userService.onNotificationPermissionsDenied();
            },
          );
        }
        if (!context.mounted) return;
      }

      // The dialog outranks every celebration; otherwise the first-answerer
      // celebration replaces the streak +1 (qotd_pick_logic.dart).
      final celebration = postAnswerCelebration(
        notificationDialogShown: dialogShown,
        pickOffered: offer != null,
        streakExtended: heldStreak != null,
      );
      String? username;
      try {
        username = context.read<ProfileService>().username;
      } catch (_) {}

      switch (celebration) {
        case PostAnswerCelebration.streak:
          _fireStreak(heldStreak);
        case PostAnswerCelebration.firstAnswerer:
          await StreakCelebrationOverlay.showFirstAnswerer(
            context,
            rank: offer!.rank,
            username: username,
          ).timeout(_celebrationTimeout, onTimeout: () {});
        case PostAnswerCelebration.none:
          break;
      }

      // The pick sheet always follows, and says why it appeared when the
      // dialog took the celebration's slot. Same `_showing` guard, so the
      // app-review request keeps yielding.
      if (offer != null && context.mounted) {
        await QotdPickPrompt.present(
          context,
          offer,
          source: source,
          title: celebration == PostAnswerCelebration.firstAnswerer
              ? null
              : firstAnswererSheetTitle(offer.rank),
        );
      }
    } finally {
      _showing = false;
    }
  }

  /// A streak extension from a QOTD answer, held until [maybeShow] knows
  /// whether the notification dialog or the first-answerer celebration takes
  /// its slot. In-memory: a killed app simply skips the celebration.
  static ({int previous, int next})? _heldStreak;

  /// Upper bound on awaiting the first-answerer overlay — if its Overlay is
  /// torn down mid-play, the completion never fires and `_showing` must not
  /// stick.
  static const Duration _celebrationTimeout = Duration(seconds: 6);

  /// Called from `UserService.addAnsweredQuestion` instead of firing the
  /// streak celebration directly, for QOTD answers (which always record the
  /// debt that makes [maybeShow] run).
  static void holdStreakCelebration(int previousStreak, int newStreak) {
    _heldStreak = (previous: previousStreak, next: newStreak);
  }

  static void _fireStreak(({int previous, int next})? streak) {
    if (streak == null) return;
    StreakUpdateEvent.notifyStreakExtended(streak.previous, streak.next);
  }

  /// Ask outside the QOTD flow — e.g. the first lick a user sends. No debt is
  /// involved: the standard decision runs directly (never asked → ask;
  /// declined → 7-day re-ask; OS-denied → Settings nudge; granted → nothing),
  /// so a user who already answered the post-answer prompt is never asked
  /// twice. Shares the settle delay and the "stamp only once shown" rule.
  static Future<void> promptForTrigger(
    BuildContext context, {
    required UserService userService,
    required String source,
    DateTime? now,
  }) async {
    if (_showing) return;
    final at = now ?? DateTime.now();
    final osStatus = await osPermission();
    final decision = postAnswerNotificationPromptDecision(
      now: at,
      answeredQotd: true, // the trigger itself is the reason to ask
      everAsked: userService.notificationPermissionShown,
      lastAskedAt: userService.notificationPermissionLastAskedAt,
      grantedInApp: userService.notificationPermissionGrantedInApp,
      osStatus: osStatus,
    );
    debugLastDecision = decision;
    if (decision == PostAnswerPromptDecision.none) return;
    if (!context.mounted) return;

    _showing = true;
    try {
      await Future<void>.delayed(_settleDelay);
      if (!context.mounted) return;

      await userService.recordNotificationPermissionAsked();
      AnalyticsService().trackEvent('notification_prompt_shown', {
        'source': source,
        'decision': decision.name,
        'os_status': osStatus.name,
      });

      if (decision == PostAnswerPromptDecision.openAppSettings) {
        _showSettingsNudge(context);
        return;
      }

      await NotificationPermissionDialog.show(
        context,
        onPermissionGranted: () async {
          AnalyticsService().trackQotdNotificationPermissionResult(true);
          AnalyticsService()
              .trackNotificationPromptResult(source: source, granted: true);
          await userService.onNotificationPermissionsGranted();
        },
        onPermissionDenied: () async {
          AnalyticsService().trackQotdNotificationPermissionResult(false);
          AnalyticsService()
              .trackNotificationPromptResult(source: source, granted: false);
          await userService.onNotificationPermissionsDenied();
        },
      );
    } finally {
      _showing = false;
    }
  }

  /// The OS-denied branch: a SnackBar that deep-links to the system Settings
  /// page. iOS never re-shows the system sheet once denied, so a re-request is a
  /// dead call and only Settings can turn notifications back on.
  ///
  /// White text on the primary colour, per the house rule.
  static void _showSettingsNudge(BuildContext context) {
    final theme = Theme.of(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text(
          'Want the daily question? Notifications are off — turn them on in Settings.',
          style: TextStyle(color: Colors.white),
        ),
        backgroundColor: theme.primaryColor,
        duration: const Duration(seconds: 6),
        action: SnackBarAction(
          label: 'Open Settings',
          textColor: Colors.white,
          onPressed: () async {
            final uri = Uri.parse('app-settings:');
            if (await canLaunchUrl(uri)) {
              await launchUrl(uri);
            }
          },
        ),
      ),
    );
  }

  /// Resets the in-memory state. Tests only.
  @visibleForTesting
  static void debugReset() {
    _showing = false;
    _pendingInMemory = false;
    _heldStreak = null;
    debugOsStatusOverride = null;
    debugLastDecision = null;
  }
}
