// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Onboarding tests. The order changed in WP-C3 (backlog triage 2026-09-11,
// decision D5): Welcome → answer today's QOTD as a guest → pick a chameleon →
// passkey → location, with the F-Droid consent slide keeping its existing
// position between auth and location.
//
// The full OnboardingScreen hard-instantiates Supabase in its slides'
// initState/build (AuthenticationSlide and LocationSetupSlide read
// `Supabase.instance.client`), so it cannot be pumped without a live backend
// and the provider tree. We therefore:
//   - widget-test the pumpable slides (WelcomeSlide, ProfileSetupSlide)
//     directly, and
//   - assert the page-count and page→step mapping that drives the flow.
// The auth-gate and completion-flag writes need live Supabase and are left as a
// documented gap (see spec §10 item 5).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:read_the_room/src/config/build_config.dart';
import 'package:read_the_room/src/services/analytics_service.dart';
import 'package:read_the_room/src/services/profile_service.dart';
import 'package:read_the_room/src/utils/avatar_catalog.dart';
import 'package:read_the_room/src/widgets/avatar_picker_sheet.dart';
import 'package:read_the_room/src/widgets/chameleon_avatar.dart';
import 'package:read_the_room/src/widgets/onboarding/profile_setup_slide.dart';
import 'package:read_the_room/src/widgets/onboarding/welcome_slide.dart';
import 'package:read_the_room/src/widgets/username_edit_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Widget host(Widget child) => MaterialApp(
        theme: ThemeData(primaryColor: const Color(0xFF00897B)),
        home: Scaffold(body: child),
      );

  Widget hostWithProfile(ProfileService profile, Widget child) => MaterialApp(
        theme: ThemeData(primaryColor: const Color(0xFF00897B)),
        home: ChangeNotifierProvider<ProfileService>.value(
          value: profile,
          child: Scaffold(body: child),
        ),
      );

  group('Onboarding page count (WP-C3: 5 slides, 6 on F-Droid)', () {
    test('total pages comes from the shared helper', () {
      // Mirrors OnboardingScreen._totalPages exactly.
      final totalPages =
          onboardingTotalPages(isFDroid: BuildConfig.isFDroidBuild);

      // `flutter test` runs the standard (non-F-Droid) build.
      expect(BuildConfig.isFDroidBuild, isFalse);
      expect(totalPages, 5);
      expect(onboardingTotalPages(isFDroid: true), 6);
    });
  });

  group('Onboarding slide order (decision D5)', () {
    test('standard build: welcome → profile → qotd → auth → location', () {
      expect(
        [for (var p = 0; p < 5; p++) onboardingStepForPage(p, isFDroid: false)],
        [
          OnboardingStep.welcomeViewed,
          OnboardingStep.profilePrompted,
          OnboardingStep.qotdPrompted,
          OnboardingStep.authPrompted,
          OnboardingStep.locationPrompted,
        ],
      );
    });

    test('the question comes before auth (the whole point of D5)', () {
      final qotdIndex = kOnboardingStepInfo[OnboardingStep.qotdPrompted]!.stepIndex;
      final authIndex = kOnboardingStepInfo[OnboardingStep.authPrompted]!.stepIndex;
      expect(qotdIndex, lessThan(authIndex));
    });

    test('the profile step comes before auth, so the choice can be staged', () {
      final profileIndex =
          kOnboardingStepInfo[OnboardingStep.profilePrompted]!.stepIndex;
      final authIndex = kOnboardingStepInfo[OnboardingStep.authPrompted]!.stepIndex;
      expect(profileIndex, lessThan(authIndex));
    });

    test('F-Droid consent stays between auth and location', () {
      expect(
        onboardingStepForPage(4, isFDroid: true),
        OnboardingStep.analyticsConsentViewed,
      );
      expect(
        onboardingStepForPage(5, isFDroid: true),
        OnboardingStep.locationPrompted,
      );
    });

    test('skip steps exist for both optional slides', () {
      expect(kOnboardingStepInfo[OnboardingStep.qotdSkipped]!.stepId,
          'qotd_skipped');
      expect(kOnboardingStepInfo[OnboardingStep.profileSkipped]!.stepId,
          'profile_skipped');
    });
  });

  group('WelcomeSlide (page 1)', () {
    testWidgets('renders the Curio welcome and intro copy', (tester) async {
      await tester.pumpWidget(host(WelcomeSlide(onNext: () {})));
      await tester.pump();

      expect(find.text('Welcome to Read the Room!'), findsOneWidget);
      expect(find.textContaining('Curio'), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('no "Read the full guide" link on the first slide',
        (tester) async {
      await tester.pumpWidget(host(WelcomeSlide(onNext: () {})));
      await tester.pump();

      // The guide stays reachable from the drawer; the first slide is kept
      // short (2026-09-16).
      expect(find.text('Read the full guide'), findsNothing);
    });

    testWidgets('surfaces the QOTD-first highlights', (tester) async {
      await tester.pumpWidget(host(WelcomeSlide(onNext: () {})));
      await tester.pump();

      // QOTD-first reframing (2026-08-31): the daily ritual leads, privacy
      // stays.
      expect(find.text('One question a day'), findsOneWidget);
      expect(find.text('Privacy first'), findsOneWidget);
      expect(find.textContaining(RegExp('open source', caseSensitive: false)), findsWidgets);
    });

    testWidgets('renders the primary advance button', (tester) async {
      // The button's enablement is gated by OnboardingSlide's scroll state, so
      // we assert its presence rather than driving the (scroll-dependent) tap.
      await tester.pumpWidget(host(WelcomeSlide(onNext: () {})));
      await tester.pump();
      expect(find.text("Let's go! 🦎"), findsOneWidget);
    });
  });

  group('ProfileSetupSlide (page 3)', () {
    testWidgets('offers the ten chameleons and the handle field',
        (tester) async {
      final profile = ProfileService(listenToAuth: false);
      await tester.pumpWidget(
        hostWithProfile(profile, ProfileSetupSlide(onNext: () {})),
      );
      await tester.pump();

      expect(find.text('Pick your chameleon'), findsOneWidget);
      expect(find.byType(AvatarGrid), findsOneWidget);
      expect(
        find.byType(ChameleonAvatar),
        findsNWidgets(kChameleonAvatarIds.length),
      );
      expect(find.byType(UsernameField), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('is skippable — it must never block onboarding',
        (tester) async {
      final profile = ProfileService(listenToAuth: false);
      var advanced = false;
      await tester.pumpWidget(
        hostWithProfile(
          profile,
          ProfileSetupSlide(onNext: () => advanced = true),
        ),
      );
      await tester.pump();

      await tester.tap(find.text('Skip for now'));
      await tester.pump();
      expect(advanced, isTrue);
    });

    testWidgets('offers three generated suggestions', (tester) async {
      final profile = ProfileService(listenToAuth: false);
      await tester.pumpWidget(
        hostWithProfile(profile, ProfileSetupSlide(onNext: () {})),
      );
      await tester.pump();

      expect(find.byType(ActionChip), findsNWidgets(3));
    });

    testWidgets('picking an avatar stages it for the guest', (tester) async {
      final profile = ProfileService(listenToAuth: false);
      await tester.pumpWidget(
        hostWithProfile(profile, ProfileSetupSlide(onNext: () {})),
      );
      await tester.pump();

      await tester.tap(find.byType(ChameleonAvatar).first);
      await tester.pumpAndSettle();

      expect(profile.avatarId, kChameleonAvatarIds.first);
      expect(profile.hasPendingSelection, isTrue);
    });
  });
}
