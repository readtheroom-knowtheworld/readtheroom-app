// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Analytics overhaul tests (design doc §4.2 + QOTD-first §12 crux).
//
// The full answer/onboarding widget trees hard-instantiate Supabase, so we test
// at the highest feasible pure level:
//   - the answer-source vocabulary helper (the pivot-decision crux),
//   - the canonical onboarding step table + page→step mapping,
//   - the dual-write event builder (canonical + legacy), and
//   - the AnalyticsService opt-out gate, via a test seam that records events
//     instead of hitting PostHog (so opt-out suppression, source attribution,
//     and app_main_screen_loaded routing are all observable).

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:read_the_room/src/services/analytics_service.dart';

void main() {
  // trackQuestionAnswered now reads a SharedPreferences first-time flag for its
  // `is_first` activation property, so the binding and a prefs mock have to
  // exist or every call logs a (harmless, caught) binding error.
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  // ------------------------------------------------------------------ crux
  group('Answer-source vocabulary (§4.2 crux)', () {
    test('every in-vocabulary value round-trips to itself', () {
      for (final value in ['qotd', 'feed', 'search', 'deeplink', 'swipe', 'archive', 'other']) {
        expect(answerSourceToEventValue(answerSourceFromString(value)), value);
      }
    });

    test('the vocabulary is exactly the seven documented sources', () {
      expect(
        AnswerSource.values.map(answerSourceToEventValue).toSet(),
        {'qotd', 'feed', 'search', 'deeplink', 'swipe', 'archive', 'other'},
      );
    });

    test('archive round-trips to itself (added in QOTD-first §Streak/Archive)', () {
      expect(answerSourceFromString('archive'), AnswerSource.archive);
      expect(answerSourceToEventValue(AnswerSource.archive), 'archive');
    });

    test('unknown, null, and mis-cased values collapse to other', () {
      expect(answerSourceFromString('nonsense'), AnswerSource.other);
      expect(answerSourceFromString(null), AnswerSource.other);
      expect(answerSourceFromString(''), AnswerSource.other);
      expect(answerSourceFromString('QOTD'), AnswerSource.other); // case-sensitive
    });
  });

  // ------------------------------------------------------- onboarding table
  group('Canonical onboarding step table (§4.2)', () {
    test('indices are 0..n in enum-declaration order', () {
      final indices =
          OnboardingStep.values.map((s) => kOnboardingStepInfo[s]!.stepIndex).toList();
      expect(
        indices,
        List<int>.generate(OnboardingStep.values.length, (i) => i),
      );
    });

    test('step_ids match the spec exactly', () {
      expect(kOnboardingStepInfo[OnboardingStep.onboardingStarted]!.stepId, 'onboarding_started');
      expect(kOnboardingStepInfo[OnboardingStep.welcomeViewed]!.stepId, 'welcome_viewed');
      // WP-C3 additions (decision D5), between welcome and passkey auth.
      expect(kOnboardingStepInfo[OnboardingStep.qotdPrompted]!.stepId, 'qotd_prompted');
      expect(kOnboardingStepInfo[OnboardingStep.qotdAnswered]!.stepId, 'qotd_answered');
      expect(kOnboardingStepInfo[OnboardingStep.qotdSkipped]!.stepId, 'qotd_skipped');
      // 2026-09-17: the onboarding notification ask, on the QOTD slide.
      expect(kOnboardingStepInfo[OnboardingStep.notificationsPrompted]!.stepId,
          'notifications_prompted');
      expect(kOnboardingStepInfo[OnboardingStep.notificationsEnabled]!.stepId,
          'notifications_enabled');
      expect(kOnboardingStepInfo[OnboardingStep.notificationsSkipped]!.stepId,
          'notifications_skipped');
      expect(kOnboardingStepInfo[OnboardingStep.profilePrompted]!.stepId, 'profile_prompted');
      expect(kOnboardingStepInfo[OnboardingStep.profileCompleted]!.stepId, 'profile_completed');
      expect(kOnboardingStepInfo[OnboardingStep.profileSkipped]!.stepId, 'profile_skipped');
      expect(kOnboardingStepInfo[OnboardingStep.authPrompted]!.stepId, 'auth_prompted');
      expect(kOnboardingStepInfo[OnboardingStep.authAttempted]!.stepId, 'auth_attempted');
      expect(kOnboardingStepInfo[OnboardingStep.authCompleted]!.stepId, 'auth_completed');
      expect(kOnboardingStepInfo[OnboardingStep.analyticsConsentViewed]!.stepId, 'analytics_consent_viewed');
      expect(kOnboardingStepInfo[OnboardingStep.analyticsConsentViewed]!.stepIndex, 14);
      expect(kOnboardingStepInfo[OnboardingStep.locationPrompted]!.stepId, 'location_prompted');
      expect(kOnboardingStepInfo[OnboardingStep.locationCompleted]!.stepId, 'location_completed');
      expect(kOnboardingStepInfo[OnboardingStep.generationCompleted]!.stepId, 'generation_completed');
      expect(kOnboardingStepInfo[OnboardingStep.onboardingCompleted]!.stepId, 'onboarding_completed');
    });
  });

  group('onboardingStepForPage (WP-C3 5-slide flow, F-Droid 6-slide)', () {
    test('standard build: welcome / profile / qotd / auth / location', () {
      expect(onboardingStepForPage(0, isFDroid: false), OnboardingStep.welcomeViewed);
      expect(onboardingStepForPage(1, isFDroid: false), OnboardingStep.profilePrompted);
      expect(onboardingStepForPage(2, isFDroid: false), OnboardingStep.qotdPrompted);
      expect(onboardingStepForPage(3, isFDroid: false), OnboardingStep.authPrompted);
      expect(onboardingStepForPage(4, isFDroid: false), OnboardingStep.locationPrompted);
      expect(onboardingStepForPage(5, isFDroid: false), isNull);
    });

    test('F-Droid keeps the consent slide between auth and location', () {
      expect(onboardingStepForPage(0, isFDroid: true), OnboardingStep.welcomeViewed);
      expect(onboardingStepForPage(1, isFDroid: true), OnboardingStep.profilePrompted);
      expect(onboardingStepForPage(2, isFDroid: true), OnboardingStep.qotdPrompted);
      expect(onboardingStepForPage(3, isFDroid: true), OnboardingStep.authPrompted);
      expect(onboardingStepForPage(4, isFDroid: true), OnboardingStep.analyticsConsentViewed);
      expect(onboardingStepForPage(5, isFDroid: true), OnboardingStep.locationPrompted);
    });

    test('page count matches the slide list', () {
      expect(onboardingTotalPages(isFDroid: false), 5);
      expect(onboardingTotalPages(isFDroid: true), 6);
      // Every page below the count maps to a step; the count itself does not.
      for (var page = 0; page < onboardingTotalPages(isFDroid: false); page++) {
        expect(onboardingStepForPage(page, isFDroid: false), isNotNull,
            reason: 'page \$page');
      }
      for (var page = 0; page < onboardingTotalPages(isFDroid: true); page++) {
        expect(onboardingStepForPage(page, isFDroid: true), isNotNull,
            reason: 'F-Droid page \$page');
      }
    });

    test('the events the flow fires have strictly ascending canonical indices', () {
      // The ordered sequence a standard-build user produces.
      final flow = <OnboardingStep>[
        OnboardingStep.onboardingStarted,
        OnboardingStep.welcomeViewed,
        OnboardingStep.profilePrompted,
        OnboardingStep.profileCompleted,
        OnboardingStep.qotdPrompted,
        OnboardingStep.qotdAnswered,
        OnboardingStep.notificationsPrompted,
        OnboardingStep.notificationsEnabled,
        OnboardingStep.authPrompted,
        OnboardingStep.authAttempted,
        OnboardingStep.authCompleted,
        OnboardingStep.locationPrompted,
        OnboardingStep.locationCompleted,
        OnboardingStep.generationCompleted,
        OnboardingStep.onboardingCompleted,
      ];
      final indices = flow.map((s) => kOnboardingStepInfo[s]!.stepIndex).toList();
      final sorted = [...indices]..sort();
      expect(indices, sorted);
      expect(indices.toSet().length, indices.length); // no duplicates
    });
  });

  // -------------------------------------------------------- dual-write pure
  group('Onboarding dual-write builder (§4.2)', () {
    test('canonical event only when no legacy name is supplied', () {
      final events = buildOnboardingStepEvents(OnboardingStep.authAttempted);
      expect(events.length, 1);
      expect(events.single.name, 'onboarding_step');
      expect(events.single.properties['step_id'], 'auth_attempted');
      expect(events.single.properties['step_index'], 12);
      expect(events.single.properties.containsKey('step_name'), isFalse);
    });

    test('legacy event is dual-written when a legacy name is supplied', () {
      final events = buildOnboardingStepEvents(
        OnboardingStep.onboardingStarted,
        legacyStepName: 'onboarding_started',
        legacyStepNumber: 0,
        properties: {'triggered_from': 'guide'},
      );
      expect(events.length, 2);

      final canonical = events[0];
      expect(canonical.name, 'onboarding_step');
      expect(canonical.properties['step_id'], 'onboarding_started');
      expect(canonical.properties['step_index'], 0);
      expect(canonical.properties['triggered_from'], 'guide');
      expect(canonical.properties.containsKey('step_name'), isFalse);

      final legacy = events[1];
      expect(legacy.name, 'onboarding_step');
      expect(legacy.properties['step_name'], 'onboarding_started');
      expect(legacy.properties['step_number'], 0);
      expect(legacy.properties['triggered_from'], 'guide');
      expect(legacy.properties.containsKey('step_id'), isFalse);
    });
  });

  // ---------------------------------------------------- service opt-out gate
  group('AnalyticsService opt-out gate (test seam)', () {
    final analytics = AnalyticsService();

    tearDown(() => analytics.debugReset());

    test('records events through the service when enabled', () async {
      final sink = <AnalyticsEventSpec>[];
      analytics.debugConfigure(optedOut: false, initialized: true);
      analytics.debugEventSink = sink;

      await analytics.trackAppMainScreenLoaded({'initial_tab_index': 0});

      expect(sink.map((e) => e.name), contains('app_main_screen_loaded'));
    });

    test('opt-out suppresses everything, including app_main_screen_loaded', () async {
      final sink = <AnalyticsEventSpec>[];
      analytics.debugConfigure(optedOut: true, initialized: true);
      analytics.debugEventSink = sink;

      await analytics.trackAppMainScreenLoaded({'initial_tab_index': 0});
      await analytics.trackQuestionAnswered(
        'approval_rating', 'approval_rating',
        source: 'qotd',
      );
      await analytics.trackQuestionAnswerStarted('text', source: 'feed');
      await analytics.trackQuestionAnswerAbandoned('text', 4, source: 'feed');
      await analytics.trackShareInitiated('results', method: 'system');
      await analytics.trackOnboardingStepCanonical(
        OnboardingStep.onboardingStarted,
        legacyStepName: 'onboarding_started',
        legacyStepNumber: 0,
      );

      expect(sink, isEmpty);
    });

    test('question_answered carries a normalized source and NO question_id',
        () async {
      // Review 2026-09-19 P0-1: the id was removed deliberately. This event
      // fires against an identified person, so a question id here is the
      // person<->answer join `responses` refuses to store.
      final sink = <AnalyticsEventSpec>[];
      analytics.debugConfigure(optedOut: false, initialized: true);
      analytics.debugEventSink = sink;

      await analytics.trackQuestionAnswered(
        'approval_rating', 'approval_rating',
        source: 'qotd',
      );
      await analytics.trackQuestionAnswered(
        'text', 'text',
        source: 'archive', // in-vocabulary → archive
      );
      await analytics.trackQuestionAnswered(
        'text', 'text',
        source: 'nonsense', // off-vocabulary → other
      );

      expect(sink.map((e) => e.name),
          everyElement('question_answered'));
      expect(sink.map((e) => e.properties['source']).toList(),
          ['qotd', 'archive', 'other']);
      for (final event in sink) {
        expect(event.properties.containsKey('question_id'), isFalse);
      }
    });

    test('trackOnboardingStepCanonical dual-writes canonical + legacy', () async {
      final sink = <AnalyticsEventSpec>[];
      analytics.debugConfigure(optedOut: false, initialized: true);
      analytics.debugEventSink = sink;

      await analytics.trackOnboardingStepCanonical(
        OnboardingStep.onboardingStarted,
        legacyStepName: 'onboarding_started',
        legacyStepNumber: 0,
      );

      expect(sink.length, 2);
      expect(sink[0].properties['step_id'], 'onboarding_started');
      expect(sink[0].properties['step_index'], 0);
      expect(sink[1].properties['step_name'], 'onboarding_started');
      expect(sink[1].properties['step_number'], 0);
    });
  });
}
