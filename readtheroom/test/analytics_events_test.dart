// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Analytics event-inventory tests (analytics review 2026-09-16).
//
// `analytics_funnel_test.dart` covers the §4.2 overhaul itself. This file
// guards the two vocabularies that silently rot the dashboards when code moves
// and nobody re-reads the doc:
//
//   1. the onboarding funnel — every canonical step exists, `step_index` is
//      monotonic in the NEW (WP-C3 / chameleon) slide order, and the slides,
//      skips, replay and terminal outcomes are all represented;
//   2. the answer-source vocabulary — every `entrySource:` literal in `lib/`
//      is in-vocabulary, so a new entry point cannot quietly land in `other`.
//
// (2) reads the source tree rather than restating a list, which is the point:
// a new entry point added in a screen fails this test instead of failing a
// PostHog breakdown three weeks later. Plus a pass over the new event helpers,
// asserting the emitted name/properties and that opt-out still suppresses them.
//
// The whole-catalogue contract — every event name, every property key, the
// no-question_id rule, the identity chain, the error-code extraction, the push
// receipt stash/drain and the demo kill switch — lives in
// `analytics_registry_test.dart` against `analytics_event_registry.dart`.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:read_the_room/src/services/analytics_service.dart';

/// Every `step_id` the onboarding funnel is documented to have, in flow order.
/// Kept as a literal list on purpose: it is the dashboard's funnel definition,
/// so a renamed or dropped step has to be an explicit edit here.
const List<String> kExpectedOnboardingStepIds = [
  'onboarding_started',
  'welcome_viewed',
  'profile_prompted',
  'profile_completed',
  'profile_skipped',
  'qotd_prompted',
  'qotd_answered',
  'qotd_skipped',
  'notifications_prompted',
  'notifications_enabled',
  'notifications_skipped',
  'auth_prompted',
  'auth_attempted',
  'auth_completed',
  'analytics_consent_viewed',
  'location_prompted',
  'location_completed',
  'generation_completed',
  'onboarding_completed',
  'onboarding_abandoned',
];

/// All `entrySource: '<value>'` literals under `lib/`.
Set<String> _entrySourceLiterals() {
  final pattern = RegExp(r"""entrySource:\s*'([a-z_]+)'""");
  final found = <String>{};
  for (final entity in Directory('lib').listSync(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('.dart')) continue;
    for (final match in pattern.allMatches(entity.readAsStringSync())) {
      found.add(match.group(1)!);
    }
  }
  return found;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // -------------------------------------------------- onboarding vocabulary
  group('Onboarding step vocabulary is complete', () {
    test('every documented step_id exists, exactly once, in flow order', () {
      final actual = OnboardingStep.values
          .map((s) => kOnboardingStepInfo[s]!.stepId)
          .toList();
      expect(actual, kExpectedOnboardingStepIds);
      expect(actual.toSet().length, actual.length, reason: 'duplicate step_id');
    });

    test('every enum value has a table entry (no null-bang landmine)', () {
      for (final step in OnboardingStep.values) {
        expect(kOnboardingStepInfo[step], isNotNull, reason: '$step');
      }
    });

    test('step_index is dense and monotonic across the whole table', () {
      final indices =
          OnboardingStep.values.map((s) => kOnboardingStepInfo[s]!.stepIndex);
      expect(indices, List<int>.generate(OnboardingStep.values.length, (i) => i));
    });
  });

  group('step_index is monotonic in the NEW slide order', () {
    // Welcome -> pick your chameleon -> today's QOTD -> passkey ->
    // [F-Droid consent] -> location. Each slide's "viewed" step must sort
    // before the next slide's, or a funnel ordered by step_index is a lie.
    int indexOf(OnboardingStep s) => kOnboardingStepInfo[s]!.stepIndex;

    test('standard build: the slide-viewed steps ascend with page order', () {
      final viewed = <int>[
        for (var page = 0; page < onboardingTotalPages(isFDroid: false); page++)
          indexOf(onboardingStepForPage(page, isFDroid: false)!)
      ];
      expect(viewed, [...viewed]..sort());
      expect(viewed.toSet().length, viewed.length);
    });

    test('F-Droid build: consent slots between passkey and location', () {
      final viewed = <int>[
        for (var page = 0; page < onboardingTotalPages(isFDroid: true); page++)
          indexOf(onboardingStepForPage(page, isFDroid: true)!)
      ];
      expect(viewed, [...viewed]..sort());
      expect(
        onboardingStepForPage(4, isFDroid: true),
        OnboardingStep.analyticsConsentViewed,
      );
    });

    test('the full walk, skips included, never goes backwards', () {
      // The worst case for monotonicity: a user who skips the QOTD ("I'll
      // answer later") and the avatar/name step still has to produce an
      // ascending sequence, because qotd_skipped/profile_skipped sit beside
      // their completed twins rather than after the steps that follow them.
      final skipper = <OnboardingStep>[
        OnboardingStep.onboardingStarted,
        OnboardingStep.welcomeViewed,
        OnboardingStep.profilePrompted,
        OnboardingStep.profileSkipped,
        OnboardingStep.qotdPrompted,
        OnboardingStep.qotdSkipped,
        OnboardingStep.authPrompted,
        OnboardingStep.authAttempted,
        OnboardingStep.authCompleted,
        OnboardingStep.locationPrompted,
        OnboardingStep.locationCompleted,
        OnboardingStep.generationCompleted,
        OnboardingStep.onboardingCompleted,
      ];
      final indices = skipper.map(indexOf).toList();
      expect(indices, [...indices]..sort());
    });

    test('onboarding_abandoned is terminal, past every walked step', () {
      final abandoned = indexOf(OnboardingStep.onboardingAbandoned);
      for (final step in OnboardingStep.values) {
        if (step == OnboardingStep.onboardingAbandoned) continue;
        expect(abandoned, greaterThan(indexOf(step)), reason: '$step');
      }
    });

    test('both QOTD outcomes and both profile outcomes are instrumented', () {
      final ids = OnboardingStep.values
          .map((s) => kOnboardingStepInfo[s]!.stepId)
          .toSet();
      expect(ids, containsAll(<String>['qotd_answered', 'qotd_skipped']));
      expect(ids, containsAll(<String>['profile_completed', 'profile_skipped']));
    });

    test('the notification ask has a prompt and both outcomes', () {
      // 2026-09-17: the ask moved onto the QOTD slide, right after the answer.
      final ids = OnboardingStep.values
          .map((s) => kOnboardingStepInfo[s]!.stepId)
          .toSet();
      expect(
        ids,
        containsAll(<String>[
          'notifications_prompted',
          'notifications_enabled',
          'notifications_skipped',
        ]),
      );
    });

    test('the notification steps sit between the QOTD and passkey slides', () {
      // They fire on the QOTD slide, so a step_index-ordered funnel must place
      // them after every QOTD outcome and before the passkey slide is viewed.
      int idx(OnboardingStep s) => kOnboardingStepInfo[s]!.stepIndex;
      expect(idx(OnboardingStep.qotdAnswered),
          lessThan(idx(OnboardingStep.notificationsPrompted)));
      expect(idx(OnboardingStep.qotdSkipped),
          lessThan(idx(OnboardingStep.notificationsPrompted)));
      for (final step in <OnboardingStep>[
        OnboardingStep.notificationsPrompted,
        OnboardingStep.notificationsEnabled,
        OnboardingStep.notificationsSkipped,
      ]) {
        expect(idx(step), lessThan(idx(OnboardingStep.authPrompted)),
            reason: '\$step');
      }
    });

    test('an answering user who enables notifications never goes backwards',
        () {
      int idx(OnboardingStep s) => kOnboardingStepInfo[s]!.stepIndex;
      final walk = <OnboardingStep>[
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
      ].map(idx).toList();
      expect(walk, [...walk]..sort());
      expect(walk.toSet().length, walk.length);
    });

    test('the same walk with the ask skipped also ascends', () {
      int idx(OnboardingStep s) => kOnboardingStepInfo[s]!.stepIndex;
      final walk = <OnboardingStep>[
        OnboardingStep.qotdAnswered,
        OnboardingStep.notificationsPrompted,
        OnboardingStep.notificationsSkipped,
        OnboardingStep.authPrompted,
      ].map(idx).toList();
      expect(walk, [...walk]..sort());
    });
  });

  // ------------------------------------------------- answer-source coverage
  group('Answer-source vocabulary covers every entry point', () {
    test('every entrySource literal under lib/ is in-vocabulary', () {
      final literals = _entrySourceLiterals();
      expect(literals, isNotEmpty,
          reason: 'scan found no entrySource literals — has the param moved?');
      for (final literal in literals) {
        expect(
          answerSourceToEventValue(answerSourceFromString(literal)),
          literal,
          reason: "entrySource '$literal' collapses to `other`: add it to "
              'AnswerSource or fix the call site',
        );
      }
    });

    test('the QOTD-first entry points are all present', () {
      // The kill/keep read is the qotd-vs-archive split, so these four in
      // particular must never degrade to `other`.
      for (final value in ['qotd', 'archive', 'search', 'swipe']) {
        expect(answerSourceFromString(value), isNot(AnswerSource.other));
      }
    });
  });

  // -------------------------------------------------------- deep-link kinds
  //
  // The old test here grepped `deep_link_service.dart` for
  // `trackDeepLinkOpened('literal')` and for a two-branch ternary. The home /
  // widget branch computes `kind` into a VARIABLE, so neither regex could see
  // `streak_widget` or `qotd_push` and the test passed vacuously while both
  // were shipping undocumented (review 2026-09-22 P1-9). It is replaced by
  // `analytics_registry_test.dart`, which checks the exported `kDeepLinkKinds`
  // against every literal AND every accepted `?src=` value, and asserts that
  // an off-vocabulary kind collapses to `unknown`.

  // ------------------------------------------------------ new event helpers
  group('New event helpers (review 2026-09-16)', () {
    final analytics = AnalyticsService();

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      analytics.debugConfigure(optedOut: false, initialized: true);
    });
    tearDown(() => analytics.debugReset());

    test('deeplink_opened carries only the routing kind', () async {
      final sink = <AnalyticsEventSpec>[];
      analytics.debugEventSink = sink;

      await analytics.trackDeepLinkOpened('friend_token');

      expect(sink.single.name, 'deeplink_opened');
      expect(sink.single.properties, {'kind': 'friend_token'});
    });

    test('reaction_added flags the first reaction and never the emoji',
        () async {
      final sink = <AnalyticsEventSpec>[];
      analytics.debugEventSink = sink;

      await analytics.trackReaction(
          added: true, emojiSource: 'quick', questionId: 'q1');
      await analytics.trackReaction(
          added: true, emojiSource: 'picker', questionId: 'q2');
      await analytics.trackReaction(
          added: false, emojiSource: 'chip', questionId: 'q2');

      expect(sink.map((e) => e.name),
          ['reaction_added', 'reaction_added', 'reaction_removed']);
      expect(sink[0].properties['is_first'], isTrue);
      expect(sink[0].properties['emoji_source'], 'quick');
      expect(sink[1].properties.containsKey('is_first'), isFalse);
      for (final event in sink) {
        expect(event.properties.keys, isNot(contains('emoji')));
        expect(event.properties.keys, isNot(contains('reaction')));
      }
    });

    test('comment_posted flags the first comment, never the body', () async {
      final sink = <AnalyticsEventSpec>[];
      analytics.debugEventSink = sink;

      await analytics.trackCommentPosted(questionId: 'q1');
      await analytics.trackCommentPosted(
          questionId: 'q2', hasLinkedQuestions: true);

      expect(sink[0].name, 'comment_posted');
      expect(sink[0].properties['is_first'], isTrue);
      expect(sink[0].properties['has_linked_questions'], isFalse);
      expect(sink[1].properties.containsKey('is_first'), isFalse);
      expect(sink[1].properties['has_linked_questions'], isTrue);
      for (final event in sink) {
        expect(event.properties.keys, isNot(contains('content')));
      }
    });

    test('rating stages emit buckets and counts, not raw values', () async {
      final sink = <AnalyticsEventSpec>[];
      analytics.debugEventSink = sink;

      await analytics.trackQuestionRated('positive');
      await analytics.trackReviewTags(skipped: false, tagCount: 2);
      await analytics.trackReviewTags(skipped: true);

      expect(sink.map((e) => e.name),
          ['question_rated', 'review_tags_submitted', 'review_tags_skipped']);
      expect(sink[0].properties['rating_bucket'], 'positive');
      expect(sink[0].properties.containsKey('rating'), isFalse);
      expect(sink[1].properties['tag_count'], 2);
      expect(sink[2].properties, isEmpty);
    });

    test('prompt result and rpc failure carry their source / action', () async {
      final sink = <AnalyticsEventSpec>[];
      analytics.debugEventSink = sink;

      await analytics.trackNotificationPromptResult(
          source: 'first_lick', granted: true);
      await analytics.trackRpcFailed('nominate_qotd', reason: 'daily_limit');
      await analytics.trackPendingAnswerReplayed(success: false);

      expect(sink[0].name, 'notification_prompt_result');
      expect(sink[0].properties, {'source': 'first_lick', 'granted': true});
      expect(sink[1].name, 'rpc_failed');
      expect(sink[1].properties,
          {'action': 'nominate_qotd', 'reason': 'daily_limit'});
      expect(sink[2].name, 'pending_answer_replayed');
      expect(sink[2].properties, {'success': false});
    });

    test('markFirstTime fires once per key, and keys do not collide', () async {
      expect(await analytics.markFirstTime('answer'), isTrue);
      expect(await analytics.markFirstTime('answer'), isFalse);
      expect(await analytics.markFirstTime('comment'), isTrue);
    });

    test('opt-out suppresses every new event', () async {
      final sink = <AnalyticsEventSpec>[];
      analytics.debugConfigure(optedOut: true, initialized: true);
      analytics.debugEventSink = sink;

      await analytics.trackDeepLinkOpened('question');
      await analytics.trackReaction(added: true, emojiSource: 'quick');
      await analytics.trackCommentPosted(questionId: 'q1');
      await analytics.trackQuestionRated('negative');
      await analytics.trackReviewTags(skipped: true);
      await analytics.trackNotificationPromptResult(
          source: 'main_screen', granted: false);
      await analytics.trackRpcFailed('submit_rating');
      await analytics.trackPendingAnswerReplayed(success: true);
      await analytics.trackOnboardingStepCanonical(
        OnboardingStep.onboardingAbandoned,
        legacyStepName: 'onboarding_skipped',
        legacyStepNumber: 2,
      );

      expect(sink, isEmpty);
    });

    test('onboarding_abandoned dual-writes the legacy skip name', () async {
      final sink = <AnalyticsEventSpec>[];
      analytics.debugEventSink = sink;

      await analytics.trackOnboardingStepCanonical(
        OnboardingStep.onboardingAbandoned,
        legacyStepName: 'onboarding_skipped',
        legacyStepNumber: 2,
        properties: {'abandoned_at_step_id': 'qotd_prompted'},
      );

      expect(sink.length, 2);
      expect(sink[0].properties['step_id'], 'onboarding_abandoned');
      expect(sink[0].properties['step_index'], 19);
      expect(sink[0].properties['abandoned_at_step_id'], 'qotd_prompted');
      expect(sink[1].properties['step_name'], 'onboarding_skipped');
      expect(sink[1].properties['step_number'], 2);
    });
  });
}
