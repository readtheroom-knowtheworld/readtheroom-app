// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The why / what / how of the passkey step.
//
// The old slide gave the mechanism ("we do this with Passkeys: by unlocking
// your device you are validating that you are the device's owner") without the
// reason, and said nothing about what a passkey costs the user. Being asked for
// biometrics by an app that has not yet explained itself is exactly where a
// new user backs out — so each line answers one question, in the order a
// sceptical person asks them.
//
// Split out of `authentication_slide.dart` so it is widget-testable: that slide
// reads `Supabase.instance.client` in `build` and therefore cannot be pumped
// (the same documented gap as `OnboardingScreen`).
//
// 2026-09-17 follow-up: HOW originally stopped at "one tap creates it... it is
// anonymous", which never told the user what tapping actually does (a system
// Face ID/Touch ID/PIN sheet, a few seconds) or what happens if they skip past
// this slide or the prompt fails. The anonymity promise moved up into WHAT
// (it's a property of the passkey, not of the tap), freeing HOW to cover the
// tap experience and the honest answer to "what do I lose if I don't do this
// now": nothing is lost, the staged QOTD answer and chameleon pick just wait
// for authentication (see `pending_answer_service.dart` and
// `onboarding_screen.dart`'s `_onPasskeyRegistered`/`_navigateAfterAuth`) —
// and `LocationSetupSlide` asks again before onboarding can finish, so a user
// who swipes past here is deferring, not skipping.

import 'package:flutter/material.dart';

/// One row of the explainer: an icon, a bold lead, and the rest of the line.
class PasskeyExplainerPoint {
  const PasskeyExplainerPoint(this.icon, this.lead, this.body);

  final IconData icon;

  /// The bold opener — the question this line answers.
  final String lead;

  /// The rest of the sentence.
  final String body;
}

/// WHY, WHAT, HOW — the three things a user needs before a biometric prompt.
const List<PasskeyExplainerPoint> kPasskeyExplainerPoints = [
  PasskeyExplainerPoint(
    Icons.groups_outlined,
    'Why',
    'every answer here comes from one real person. No bots, no duplicate '
        'accounts — so the results actually mean something.',
  ),
  PasskeyExplainerPoint(
    Icons.fingerprint,
    'What',
    "a passkey: your device's Face ID, fingerprint or PIN. No email, no "
        "password, nothing to remember — and it's anonymous, never tied to "
        'your name or email.',
  ),
  PasskeyExplainerPoint(
    Icons.lock_outline,
    'How',
    "tap below and your device's unlock prompt pops up — done in a few "
        "seconds. Not ready, or it fails? No problem: keep going, and we'll "
        'hold your answer until you come back to authenticate.',
  ),
];

/// The three-line explainer shown above the "Authenticate as Human" button.
class PasskeyExplainer extends StatelessWidget {
  const PasskeyExplainer({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final point in kPasskeyExplainerPoints)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(point.icon, size: 20, color: theme.primaryColor),
                const SizedBox(width: 10),
                Expanded(
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: '${point.lead}: ',
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        TextSpan(text: point.body),
                      ],
                    ),
                    style: theme.textTheme.bodyMedium?.copyWith(height: 1.35),
                  ),
                ),
              ],
            ),
          ),
        // The recovery promise: reinstalling does not cost the account
        // (`passkey-recovery-2025-01-14.md` — the device id plus a fresh
        // biometric re-binds the existing user rather than making a new one).
        Text(
          'Reinstalled the app? Authenticating again on the same device '
          'restores your account.',
          style: theme.textTheme.bodySmall?.copyWith(color: Colors.grey[600]),
        ),
      ],
    );
  }
}
