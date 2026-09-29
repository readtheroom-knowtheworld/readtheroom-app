// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The "be there when it drops" ask, shown on the onboarding QOTD slide
// immediately after the guest answers — the moment the daily ritual has just
// been demonstrated rather than merely described.
//
// ## What the copy has to say, and why
//
// The drop is a server-chosen random minute, the same instant for everyone
// (`qotd-drop-voting-2026-08-31.md` §2.2). That is exactly why the notification
// matters and why there is no time to pick: without it you hear about the
// question late, and the moment the whole world answered it together has
// already passed. Two short lines carry that — the volume ("one drop a day"),
// the unpredictability ("at a random moment") and the shared instant ("the
// whole world answers it at the same time"). There is no time picker anywhere
// in the app any more.
//
// ## Why it is here and not only in PostAnswerPrompts
//
// The post-answer coordinator asks after a QOTD answer *lands*. A guest's
// onboarding answer is stashed, not submitted (`PendingAnswerService`), so the
// coordinator's debt is only recorded at the end of onboarding and drained on
// the first MainScreen frame — a screen or two after the moment that earns the
// permission. This widget runs the same flow at the better moment.
//
// ## It must not cause a second ask
//
// It drives the *same* state the coordinator reads, so the coordinator's own
// decision (`postAnswerNotificationPromptDecision`) turns into `none`:
//
//   * accepted  → `onNotificationPermissionsGranted()` sets
//     `notification_permission_granted_in_app`, and the OS status is now
//     `authorized`/`provisional`, which short-circuits the decision outright;
//   * skipped / declined → `recordNotificationPermissionAsked()` stamps
//     `notification_permission_last_asked_at = now`, so the weekly re-ask gate
//     stays shut for 7 days and then may legitimately ask again.
//
// Either way MainScreen's drain finds nothing to show. That is the whole point:
// one ask, at the best moment, not two.
//
// ## Guests
//
// There is no account yet at this point in onboarding, and that is fine:
// `NotificationService.requestPermissions()` and the `qotd` FCM topic are not
// user-scoped, so a guest can genuinely grant and be subscribed. The two
// user-scoped writes (`notification_settings.qotd_enabled` and the personal
// `user_{id}` topic) return early with a log line instead of throwing, and are
// picked up at the end of onboarding by `UserService.resyncNotificationState()`
// once the passkey has created the account — see `OnboardingScreen`.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../services/analytics_service.dart';
import '../../services/post_answer_prompts.dart';
import '../../services/user_service.dart';
import '../../utils/post_answer_prompt_logic.dart';
import '../notification_permission_dialog.dart';

/// Analytics `source` for this surface, so the prompt's effectiveness is
/// comparable with the other places that ask.
const String kOnboardingNotificationPromptSource = 'onboarding_qotd';

/// Key of the enable switch, so a widget test can drive it without copy.
const String kOnboardingNotificationSwitchKey = 'onboarding-notification-switch';

/// Key of the explicit decline. The ask is one tap to say yes **and** one tap to
/// say no — the slide's Continue button is not the only way past it.
const String kOnboardingNotificationNotNowKey =
    'onboarding-notification-not-now';

/// Single-purpose "Be there when it drops" card with an explicit switch.
///
/// Reports the outcome through [onResolved] — `true` once notifications are
/// actually enabled, `false` for a decline or an OS-denied dead end. Never
/// blocks the flow: the surrounding slide's advance button stays live whatever
/// happens here.
class OnboardingNotificationAsk extends StatefulWidget {
  const OnboardingNotificationAsk({Key? key, this.onResolved})
      : super(key: key);

  /// Called with the outcome each time the ask resolves.
  final void Function(bool enabled)? onResolved;

  @override
  State<OnboardingNotificationAsk> createState() =>
      _OnboardingNotificationAskState();
}

class _OnboardingNotificationAskState extends State<OnboardingNotificationAsk> {
  bool _busy = false;
  bool _enabled = false;
  bool _declined = false;
  bool _shownReported = false;

  @override
  void initState() {
    super.initState();
    // Review 2026-09-22 P1-3: `notification_prompt_shown` used to fire inside
    // `_enable()`, i.e. on the TAP — so it counted grants, not impressions,
    // and the shown -> result pair was not a funnel at all (its conversion
    // read as ~100%). It now fires once when the card is actually on screen.
    WidgetsBinding.instance.addPostFrameCallback((_) => _reportShown());
  }

  Future<void> _reportShown() async {
    if (_shownReported || !mounted) return;
    _shownReported = true;
    String osStatus = 'unknown';
    try {
      osStatus = (await PostAnswerPrompts.osPermission()).name;
    } catch (e) {
      debugPrint('OnboardingNotificationAsk: could not read the OS status: $e');
    }
    // `decision` matches `post_answer_prompts.dart`'s property set: this
    // surface always asks outright, so the decision is `askInApp`.
    await AnalyticsService().trackEvent('notification_prompt_shown', {
      'source': kOnboardingNotificationPromptSource,
      'decision': 'askInApp',
      'os_status': osStatus,
    });
  }

  Future<void> _onChanged(bool value) async {
    // Switching back off is not this card's job — Settings owns turning
    // notifications off, and an accidental double tap should not unsubscribe.
    if (!value || _busy || _enabled) return;
    // A declined card can still be switched on: changing your mind must work.
    if (_declined) setState(() => _declined = false);
    await _enable();
  }

  /// "Not now" — an explicit decline rather than a dodge. It reports the
  /// outcome, collapses the card so the choice is visible on screen, and stamps
  /// the ask (the same 7-day re-ask gate [_enable] writes) so the post-answer
  /// coordinator does not ask again on the very next screen.
  Future<void> _notNow() async {
    if (_busy || _enabled || _declined) return;
    setState(() => _declined = true);

    try {
      await context.read<UserService>().recordNotificationPermissionAsked();
    } catch (e) {
      // No provider (a widget test) or prefs unavailable: the decline still
      // stands, it just is not remembered for the weekly gate.
      debugPrint('OnboardingNotificationAsk: could not record the ask: $e');
    }

    AnalyticsService().trackNotificationPromptResult(
      source: kOnboardingNotificationPromptSource,
      granted: false,
    );
    widget.onResolved?.call(false);
  }

  Future<void> _enable() async {
    setState(() => _busy = true);
    final userService = context.read<UserService>();
    var granted = false;
    try {
      final osStatus = await PostAnswerPrompts.osPermission();

      // Stamp the ask before showing anything that can be dismissed: this is
      // the record the post-answer coordinator reads, and an ask the user saw
      // must never be repeated on the next screen.
      await userService.recordNotificationPermissionAsked();
      AnalyticsService().trackQotdNotificationPermissionRequested();
      // `notification_prompt_shown` is NOT fired here any more — see
      // `_reportShown`. This is the tap, not the impression.

      if (osPermissionAllowsDelivery(osStatus)) {
        // Already reachable (a reinstall, or provisional delivery): no sheet to
        // show, just turn the preferences on.
        await userService.onNotificationPermissionsGranted();
        granted = true;
      } else if (osStatus == OsNotificationPermission.denied) {
        // iOS never re-shows the system sheet once refused, so a request here
        // is a dead call — point at the place that can actually fix it.
        if (mounted) _showSettingsNudge();
      } else {
        if (!mounted) return;
        await NotificationPermissionDialog.show(
          context,
          onPermissionGranted: () async {
            granted = true;
            await userService.onNotificationPermissionsGranted();
          },
          onPermissionDenied: () async {
            await userService.onNotificationPermissionsDenied();
          },
        );
      }
    } catch (e) {
      // An ask that throws must not strand the user mid-onboarding.
      debugPrint('OnboardingNotificationAsk: enable failed: $e');
    }

    AnalyticsService().trackQotdNotificationPermissionResult(granted);
    AnalyticsService().trackNotificationPromptResult(
      source: kOnboardingNotificationPromptSource,
      granted: granted,
    );
    widget.onResolved?.call(granted);

    if (!mounted) return;
    setState(() {
      _busy = false;
      _enabled = granted;
    });
  }

  /// White text on the primary colour, per the house rule.
  void _showSettingsNudge() {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text(
          'Notifications are off in your device Settings — turn them on there '
          'to get tomorrow\'s question.',
          style: TextStyle(color: Colors.white),
        ),
        backgroundColor: Theme.of(context).primaryColor,
        duration: const Duration(seconds: 6),
        action: SnackBarAction(
          label: 'Open Settings',
          textColor: Colors.white,
          onPressed: () async {
            final uri = Uri.parse('app-settings:');
            if (await canLaunchUrl(uri)) await launchUrl(uri);
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: theme.primaryColor.withOpacity(_enabled ? 0.12 : 0.06),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: theme.primaryColor.withOpacity(0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(
                _enabled ? Icons.notifications_active : Icons.bolt,
                color: theme.primaryColor,
                size: 22,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Be there when it drops',
                      style: theme.textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      // The drop is a server-chosen random minute, the same
                      // instant for everyone — there is no time to pick, and
                      // that is the pitch, not a caveat. Miss the push and you
                      // miss the moment the world answered together.
                      _enabled
                          ? "You're in — one drop a day, at a random moment, "
                              'answered by the whole world at the same time.'
                          : 'Turn on notifications — one drop a day, at a '
                              'random moment. The whole world answers it at '
                              'the same time.',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: Colors.grey[600]),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (_busy)
                const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                Switch(
                  key: const Key(kOnboardingNotificationSwitchKey),
                  value: _enabled,
                  onChanged: _onChanged,
                ),
            ],
          ),
          // One tap to say no, so walking past the ask is a choice rather than
          // an accident. Gone once the answer either way is in.
          if (!_enabled && !_declined && !_busy)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                key: const Key(kOnboardingNotificationNotNowKey),
                onPressed: _notNow,
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                child: Text(
                  'Not now',
                  style: TextStyle(
                    color: Colors.grey[600],
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ),
          if (_declined)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                'No drop alerts — you can turn them on any time in Settings.',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: Colors.grey[600]),
              ),
            ),
        ],
      ),
    );
  }
}
