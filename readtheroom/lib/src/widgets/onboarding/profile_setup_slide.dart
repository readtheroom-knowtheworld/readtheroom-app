// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/analytics_service.dart';
import '../../services/profile_service.dart';
import '../avatar_picker_sheet.dart';
import '../username_edit_sheet.dart';
import 'onboarding_slide.dart';

/// Onboarding slide 3 (WP-C3): "Pick your chameleon" — the avatar grid plus the
/// handle field with generated suggestions.
///
/// The user has no account at this point, so [ProfileService] stages both
/// choices in SharedPreferences; they are written to `user_profiles` right
/// after passkey registration succeeds
/// ([ProfileService.flushPendingSelection]).
///
/// Skippable: identity is optional, and the rest of onboarding must not depend
/// on it.
class ProfileSetupSlide extends StatelessWidget {
  const ProfileSetupSlide({Key? key, required this.onNext}) : super(key: key);

  final VoidCallback onNext;

  void _complete(BuildContext context, {required bool skipped}) {
    final profile = Provider.of<ProfileService>(context, listen: false);
    AnalyticsService().trackOnboardingStepCanonical(
      skipped
          ? OnboardingStep.profileSkipped
          : OnboardingStep.profileCompleted,
      properties: {
        'has_avatar': (profile.avatarId ?? '').isNotEmpty,
        'has_username': profile.hasUsername,
      },
    );
    onNext();
  }

  @override
  Widget build(BuildContext context) {
    final profile = context.watch<ProfileService>();
    final ready = profile.hasUsername;

    return OnboardingSlide(
      title: 'Pick your chameleon',
      description:
          'Pick an avatar and a usernname. Only your friends ever see them',
      showCurio: false,
      onNext: ready ? () => _complete(context, skipped: false) : null,
      buttonText: 'Continue',
      customContent: _ProfileSetupContent(
        onSkip: () => _complete(context, skipped: true),
      ),
    );
  }
}

class _ProfileSetupContent extends StatelessWidget {
  const _ProfileSetupContent({required this.onSkip});

  final VoidCallback onSkip;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final profile = context.watch<ProfileService>();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Same grid the picker sheet uses, without the sheet chrome.
        const AvatarGrid(popOnSelect: false, tileSize: 52),
        const SizedBox(height: 24),
        Align(
          alignment: Alignment.centerLeft,
          child: Text(
            'Your name',
            style: theme.textTheme.labelLarge
                ?.copyWith(fontWeight: FontWeight.w600),
          ),
        ),
        const SizedBox(height: 8),
        // Same field (and therefore the same validation copy and the same
        // profanity-checked suggestions) as the Me-tab edit sheet.
        UsernameField(
          initialValue: profile.username,
          saveLabel: profile.hasUsername ? 'Update name' : 'Use this name',
        ),
        const SizedBox(height: 4),
        Center(
          child: TextButton(
            onPressed: onSkip,
            child: Text(
              'Skip for now',
              style:
                  TextStyle(color: Colors.grey[600], fontWeight: FontWeight.w500),
            ),
          ),
        ),
      ],
    );
  }
}
