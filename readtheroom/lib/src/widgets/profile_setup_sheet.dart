// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/analytics_service.dart';
import '../services/profile_service.dart';
import 'avatar_picker_sheet.dart';
import 'username_edit_sheet.dart';

/// One-time, skippable "Pick your chameleon" sheet for users who installed
/// before the identity update (WP-C3 step 3, decision D5).
///
/// New users meet this content as an onboarding slide
/// (`onboarding/profile_setup_slide.dart`); this sheet reuses the very same
/// widgets — [AvatarGrid] and [UsernameField] — so the two surfaces cannot
/// drift apart.
///
/// Shown at most once, tracked with a SharedPreferences flag.
class ProfileSetupSheet extends StatelessWidget {
  const ProfileSetupSheet({Key? key}) : super(key: key);

  /// SharedPreferences flag: the sheet has been shown (whether or not the user
  /// filled anything in).
  static const String prefsKey = 'profile_setup_sheet_shown';

  /// Whether the existing-user sheet should be shown right now.
  ///
  /// Pure decision, split out for testing: show it only to an authenticated
  /// user with no handle yet who has not already been asked.
  static bool shouldShow({
    required bool isAuthenticated,
    required bool hasUsername,
    required bool alreadyShown,
  }) =>
      isAuthenticated && !hasUsername && !alreadyShown;

  /// Evaluates [shouldShow] against live state and, if due, presents the sheet
  /// and records the flag. Safe to call unconditionally on app start.
  static Future<void> maybeShow(BuildContext context) async {
    final profile = Provider.of<ProfileService>(context, listen: false);
    if (!profile.isLoaded) await profile.load();

    final prefs = await SharedPreferences.getInstance();
    final due = shouldShow(
      isAuthenticated: profile.isAuthenticated,
      hasUsername: profile.hasUsername,
      alreadyShown: prefs.getBool(prefsKey) ?? false,
    );
    if (!due || !context.mounted) return;

    // Recorded before showing: a crash or a force-quit must not turn a
    // one-time prompt into a recurring one.
    await prefs.setBool(prefsKey, true);
    AnalyticsService().trackEvent('profile_setup_sheet_shown', const {});

    if (!context.mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const ProfileSetupSheet(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.9,
        ),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
        child: SafeArea(
          top: false,
          child: SingleChildScrollView(
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
                const SizedBox(height: 6),
                Text(
                  'New: give yourself a look and a name. Only friends ever see '
                  'them — your questions, answers and comments stay anonymous.',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: Colors.grey[600]),
                ),
                const SizedBox(height: 18),
                const AvatarGrid(popOnSelect: false, tileSize: 52),
                const SizedBox(height: 22),
                UsernameField(
                  saveLabel: 'Save name',
                  onSaved: () => Navigator.of(context).maybePop(),
                ),
                Center(
                  child: TextButton(
                    onPressed: () => Navigator.of(context).maybePop(),
                    child: Text(
                      'Maybe later',
                      style: TextStyle(
                        color: Colors.grey[600],
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
