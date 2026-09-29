// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The 2026-09-17 onboarding changes:
//   1. the QOTD slide's answered state shows the results (the shared
//      `QotdResultsPreview`, whose pure aggregation is covered by
//      `qotd_results_preview_logic_test.dart`),
//   2. the notification ask that sits under them, and
//   3. the why/what/how passkey explainer.
//
// What is pumpable here, and what is not: `QotdQuestionSlide` reads
// `QuestionService` from the provider tree in `initState` and fetches, and
// `AuthenticationSlide` reads `Supabase.instance.client` in `build` — the same
// documented gap as `OnboardingScreen` itself. So the two pieces that carry the
// new copy and the new interaction were split into standalone widgets
// (`OnboardingNotificationAsk`, `PasskeyExplainer`) and are tested directly.
//
// `OnboardingNotificationAsk.build` deliberately touches no provider — the
// `UserService` read happens inside the enable handler — so its rendering and
// its "off is not this card's job" rule are testable without a live backend.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:read_the_room/src/services/analytics_service.dart';
import 'package:read_the_room/src/utils/qotd_results_preview_logic.dart';
import 'package:read_the_room/src/widgets/onboarding/onboarding_notification_ask.dart';
import 'package:read_the_room/src/widgets/onboarding/passkey_explainer.dart';

void main() {
  Widget host(Widget child) => MaterialApp(
        theme: ThemeData(primaryColor: const Color(0xFF00897B)),
        home: Scaffold(body: child),
      );

  final askSwitch = find.byKey(const Key(kOnboardingNotificationSwitchKey));

  group('OnboardingNotificationAsk', () {
    testWidgets('is a single-purpose card with an explicit switch',
        (tester) async {
      await tester.pumpWidget(host(const OnboardingNotificationAsk()));
      await tester.pump();

      expect(find.text('Be there when it drops'), findsOneWidget);
      expect(find.textContaining('Turn on notifications'), findsOneWidget);
      expect(askSwitch, findsOneWidget);
      expect(tester.widget<Switch>(askSwitch).value, isFalse);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'says the question drops at a random moment and the whole world '
        'answers at the same time', (tester) async {
      // The drop is a server-chosen random instant, the same for everyone
      // (qotd-drop-voting-2026-08-31.md §2.2). That pair of facts is the reason
      // the notification matters, and the reason there is no time to pick — so
      // the card has to say both, and must never imply a chosen time.
      await tester.pumpWidget(host(const OnboardingNotificationAsk()));
      await tester.pump();
      expect(find.textContaining('one drop a day'), findsOneWidget);
      expect(find.textContaining('random moment'), findsOneWidget);
      expect(find.textContaining('whole world'), findsOneWidget);
      expect(find.textContaining('same time'), findsOneWidget);
    });

    testWidgets('offers a one-tap "Not now" that resolves as declined',
        (tester) async {
      // Walking past the ask has to be a choice. The slide's Continue button is
      // not the only exit, and a decline reports itself like any other outcome.
      final outcomes = <bool>[];
      await tester.pumpWidget(host(
        OnboardingNotificationAsk(onResolved: outcomes.add),
      ));
      await tester.pump();

      final notNow = find.byKey(const Key(kOnboardingNotificationNotNowKey));
      expect(notNow, findsOneWidget);
      await tester.tap(notNow);
      await tester.pump();

      expect(outcomes, <bool>[false]);
      // The choice is visible afterwards, and cannot be tapped twice.
      expect(find.textContaining('No drop alerts'), findsOneWidget);
      expect(notNow, findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('switching an already-off card off does nothing at all',
        (tester) async {
      // Guards the handler's early return: an off→off tap must not reach
      // UserService (there is no provider here, so it would throw).
      final outcomes = <bool>[];
      await tester.pumpWidget(host(
        OnboardingNotificationAsk(onResolved: outcomes.add),
      ));
      await tester.pump();

      tester.widget<Switch>(askSwitch).onChanged!(false);
      await tester.pump();

      expect(outcomes, isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('reports its analytics source, so the ask is comparable',
        (tester) async {
      // The coordinator tags every other prompt with a `source`; this one has
      // to be in the same vocabulary or the effectiveness view loses a surface.
      expect(kOnboardingNotificationPromptSource, 'onboarding_qotd');
    });
  });

  group('PasskeyExplainer (why / what / how)', () {
    testWidgets('answers all three questions, in that order', (tester) async {
      await tester.pumpWidget(host(const PasskeyExplainer()));
      await tester.pump();

      expect(kPasskeyExplainerPoints.map((p) => p.lead).toList(),
          ['Why', 'What', 'How']);
      expect(tester.takeException(), isNull);
    });

    testWidgets('WHY is about one real person per answer, not about bots alone',
        (tester) async {
      final why = kPasskeyExplainerPoints.first;
      expect(why.lead, 'Why');
      expect(why.body, contains('one real person'));
      expect(why.body, contains('No bots'));
      expect(why.body, contains('duplicate accounts'));
    });

    testWidgets(
        'WHAT names the device unlock, rules out email/passwords, and promises anonymity',
        (tester) async {
      final what = kPasskeyExplainerPoints[1];
      expect(what.body, contains('Face ID'));
      expect(what.body, contains('fingerprint'));
      expect(what.body, contains('PIN'));
      expect(what.body, contains('No email'));
      expect(what.body, contains('no password'));
      expect(what.body, contains('anonymous'));
    });

    testWidgets(
        'HOW describes the tap and is honest that skipping or failing loses nothing',
        (tester) async {
      final how = kPasskeyExplainerPoints[2];
      expect(how.body, contains('unlock prompt'));
      expect(how.body, contains('a few seconds'));
      expect(how.body, contains('Not ready, or it fails'));
      expect(how.body, contains('keep going'));
    });

    testWidgets('keeps the recovery promise (passkey-recovery-2025-01-14)',
        (tester) async {
      await tester.pumpWidget(host(const PasskeyExplainer()));
      await tester.pump();
      // Reinstalling must not read as "you lose your account".
      expect(find.textContaining('restores your account'), findsOneWidget);
    });

    testWidgets('stays short — three points plus the recovery line',
        (tester) async {
      await tester.pumpWidget(host(const PasskeyExplainer()));
      await tester.pump();
      expect(kPasskeyExplainerPoints, hasLength(3));
      expect(find.byType(Icon), findsNWidgets(3));
    });
  });

  group('Results-so-far count label', () {
    test('singular at one, so the first answerer is not told "1 responses"',
        () {
      expect(qotdResponseCountLabel(1), '1 response');
    });

    test('plural everywhere else, including zero', () {
      expect(qotdResponseCountLabel(0), '0 responses');
      expect(qotdResponseCountLabel(2), '2 responses');
      expect(qotdResponseCountLabel(1284), '1284 responses');
    });
  });

  group('Onboarding notification steps are wired to the QOTD slide', () {
    test('the three step ids exist with the documented names', () {
      expect(kOnboardingStepInfo[OnboardingStep.notificationsPrompted]!.stepId,
          'notifications_prompted');
      expect(kOnboardingStepInfo[OnboardingStep.notificationsEnabled]!.stepId,
          'notifications_enabled');
      expect(kOnboardingStepInfo[OnboardingStep.notificationsSkipped]!.stepId,
          'notifications_skipped');
    });

    test('prompted sorts before both of its outcomes', () {
      int idx(OnboardingStep s) => kOnboardingStepInfo[s]!.stepIndex;
      expect(idx(OnboardingStep.notificationsPrompted),
          lessThan(idx(OnboardingStep.notificationsEnabled)));
      expect(idx(OnboardingStep.notificationsPrompted),
          lessThan(idx(OnboardingStep.notificationsSkipped)));
    });
  });
}
