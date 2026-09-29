// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The §5.5 "network results" widgets, in isolation.
//
// HISTORY: this file was `community_demo_test.dart` and also asserted that the
// Community tab rendered a DEMO sneak peek of these widgets. WP-E replaced that
// tab with the real friend graph, so the tab-level assertions moved to
// `community_screen_test.dart` and the DEMO section is gone.
//
// The three widgets themselves are KEPT, and so is `demo_network_data.dart`:
//   * each is explicitly parameterised for the RPC shapes §5.5 will return
//     (`get_network_results`, `get_close_friend_answers`), not for the demo;
//   * `demo_network_data.dart` carries their model types (`NetworkGraphData`,
//     `CloseFriendAnswer`, `DemoAnswerKind`) as well as the fabricated dataset,
//     so `network_graph_preview.dart` and `close_friends_answers_row.dart`
//     still depend on it — it is not unused;
//   * the tests below cover them, which is the WP-E brief's own keep condition.
//
// Nothing in the shipping UI renders them at the moment. §5.5 (which needs
// `response_owners` and the two aggregate RPCs — out of WP-E's scope) is where
// they get wired to real data.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:read_the_room/src/utils/demo_network_data.dart';
import 'package:read_the_room/src/widgets/close_friends_answers_row.dart';
import 'package:read_the_room/src/widgets/network_aggregate_card.dart';
import 'package:read_the_room/src/widgets/network_graph_preview.dart';

/// Wraps [child] with animations disabled so entrance/dot animations settle on
/// the first frame.
Widget _app(Widget child) => MaterialApp(
      theme: ThemeData(primaryColor: const Color(0xFF00897B)),
      home: MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: child,
      ),
    );

void main() {
  group('demo dataset / graph builder', () {
    test('builder produces the deterministic demo topology', () {
      final pizza = buildDemoNetworkGraph(kDemoNetworkQuestions[0]);
      // 1 self + 3 regular + 4 close + 9 FoF.
      expect(pizza.self.kind, NetworkNodeKind.self);
      expect(pizza.regularFriends.length, 3);
      expect(pizza.closeFriends.length, 4);
      expect(pizza.friendsOfFriends.length, 9);
      expect(pizza.nodes.length, 17);

      // Regular friends never expose an answer (privacy is in the data).
      for (final f in pizza.regularFriends) {
        expect(f.hasAnswer, isFalse);
      }
      // Close friends do expose an answer.
      for (final f in pizza.closeFriends) {
        expect(f.hasAnswer, isTrue);
      }
      // Friends-of-friends stay anonymous (no handle) but DO reveal an answer,
      // and bridge to exactly one inner-ring friend — never to another FoF.
      final innerIds = {
        'self',
        ...pizza.regularFriends.map((n) => n.id),
        ...pizza.closeFriends.map((n) => n.id),
      };
      final fofIds = pizza.friendsOfFriends.map((n) => n.id).toSet();
      for (final fof in pizza.friendsOfFriends) {
        expect(fof.handle, isNull);
        expect(fof.hasAnswer, isTrue);
        expect(fof.answerKind, DemoAnswerKind.approval);
        expect(fof.answerLabel, isNotNull);
        expect(innerIds.contains(fof.parentId), isTrue);
        expect(fofIds.contains(fof.parentId), isFalse);
      }
    });

    test('switching question changes the close-friend node set + colours', () {
      final pizza = buildDemoNetworkGraph(kDemoNetworkQuestions[0]);
      final texting = buildDemoNetworkGraph(kDemoNetworkQuestions[1]);

      // Approval question → close friends carry approval answers.
      expect(
        pizza.closeFriends
            .every((n) => n.answerKind == DemoAnswerKind.approval),
        isTrue,
      );
      // MC question → close friends carry multiple-choice answers.
      expect(
        texting.closeFriends
            .every((n) => n.answerKind == DemoAnswerKind.multipleChoice),
        isTrue,
      );

      final pizzaHandles = pizza.closeFriends.map((n) => n.handle).toSet();
      final textingHandles = texting.closeFriends.map((n) => n.handle).toSet();
      expect(pizzaHandles.contains('@mango_morphs'), isTrue);
      expect(textingHandles.contains('@pip_prism'), isTrue);
      expect(pizzaHandles, isNot(equals(textingHandles)));

      // Your own answer differs too.
      expect(pizza.self.answerKind, DemoAnswerKind.approval);
      expect(texting.self.answerKind, DemoAnswerKind.multipleChoice);

      // Friends-of-friends recolour on the switch exactly like close friends,
      // while their identity stays anonymous.
      expect(
        pizza.friendsOfFriends
            .every((n) => n.answerKind == DemoAnswerKind.approval && n.hasAnswer),
        isTrue,
      );
      expect(
        texting.friendsOfFriends.every(
            (n) => n.answerKind == DemoAnswerKind.multipleChoice && n.hasAnswer),
        isTrue,
      );
      expect(pizza.friendsOfFriends.every((n) => n.handle == null), isTrue);

      // Regular friends still never expose an answer, on either question.
      expect(pizza.regularFriends.every((n) => !n.hasAnswer), isTrue);
      expect(texting.regularFriends.every((n) => !n.hasAnswer), isTrue);
    });
  });

  group('NetworkGraphPreview (§5.2 / §9)', () {
    testWidgets('reduced-motion path builds and settles on the first frame',
        (tester) async {
      await tester.pumpWidget(_app(
        Scaffold(
          body: Center(
            child: SizedBox(
              width: 320,
              child: NetworkGraphPreview(
                data: buildDemoNetworkGraph(kDemoNetworkQuestions[0]),
              ),
            ),
          ),
        ),
      ));
      // A single pump (no settle) — with disableAnimations the entrance jumps
      // straight to its settled state.
      await tester.pump();
      expect(find.byType(NetworkGraphPreview), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('tapping the centre reveals the "You" answer tooltip',
        (tester) async {
      await tester.pumpWidget(_app(
        Scaffold(
          body: Center(
            child: SizedBox(
              width: 320,
              child: NetworkGraphPreview(
                data: buildDemoNetworkGraph(kDemoNetworkQuestions[0]),
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      // The self node sits at the centre of the canvas (width 320 →
      // height (320 * 0.78).clamp = 249.6).
      final rect = tester.getRect(find.byType(NetworkGraphPreview));
      final canvasHeight = (320.0 * 0.78).clamp(220.0, 320.0);
      await tester.tapAt(Offset(rect.center.dx, rect.top + canvasHeight / 2));
      await tester.pumpAndSettle();

      // An approval answer is a colour on the legend's scale, not a word:
      // the tooltip chip is the dot alone (owner, 2026-09-25). The legend
      // under the graph is what spells the scale out.
      expect(find.text('You approve'), findsNothing);
      expect(find.text('Disapprove'), findsOneWidget);
      expect(find.text('Approve'), findsOneWidget);
    });

    testWidgets('no legend on a multiple-choice question', (tester) async {
      final mc = kDemoNetworkQuestions
          .firstWhere((q) => q.kind != kDemoNetworkQuestions[0].kind);
      await tester.pumpWidget(_app(
        Scaffold(
          body: Center(
            child: SizedBox(
              width: 320,
              child: NetworkGraphPreview(data: buildDemoNetworkGraph(mc)),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.text('Disapprove'), findsNothing);
      expect(find.text('Approve'), findsNothing);
    });
  });

  group('NetworkAggregateCard (§5.5A)', () {
    testWidgets('renders the aggregate above the k threshold', (tester) async {
      await tester.pumpWidget(_app(
        const Scaffold(
          body: SingleChildScrollView(
            child: NetworkAggregateCard.approval(
              respondentCount: 7,
              values: [-0.5, 0.1, 0.9],
              average: 0.17,
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.text('7 answers from your network'), findsOneWidget);
      expect(find.textContaining('Not enough of your network'), findsNothing);
    });

    testWidgets('gates below the k threshold', (tester) async {
      await tester.pumpWidget(_app(
        const Scaffold(
          body: SingleChildScrollView(
            child: NetworkAggregateCard.approval(
              respondentCount: 2,
              values: [0.1, 0.9],
              average: 0.5,
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      expect(
        find.text(
            'Not enough of your network has answered yet — invite friends'),
        findsOneWidget,
      );
    });

    testWidgets('renders the multiple-choice variant', (tester) async {
      await tester.pumpWidget(_app(
        Scaffold(
          body: SingleChildScrollView(
            child: NetworkAggregateCard.multipleChoice(
              respondentCount: kDemoNetworkQuestions[1].respondentCount,
              optionLabels: kDemoNetworkQuestions[1].mcOptionLabels,
              optionVotes: kDemoNetworkQuestions[1].mcOptionVotes,
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.text('11 answers from your network'), findsOneWidget);
      expect(find.text('Golden hour (3pm)'), findsWidgets);
    });

    test('k-anonymity threshold matches the spec (k = 3)', () {
      expect(kNetworkAnonymityThreshold, 3);
    });
  });

  group('CloseFriendsAnswersRow (§5.5B)', () {
    testWidgets('renders one row per close friend with an answer chip',
        (tester) async {
      const answers = [
        CloseFriendAnswer.approval(
          handle: '@sunny_scales',
          answerLabel: 'Approve',
          value: 0.5,
        ),
        CloseFriendAnswer.mc(
          handle: '@pip_prism',
          answerLabel: 'Never',
          optionIndex: 0,
        ),
      ];
      await tester.pumpWidget(_app(
        const Scaffold(
          body: SingleChildScrollView(
            child: CloseFriendsAnswersRow(answers: answers),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.text('@sunny_scales'), findsOneWidget);
      expect(find.text('@pip_prism'), findsOneWidget);
      expect(find.text('Approve'), findsOneWidget);
      expect(find.text('Never'), findsOneWidget);
    });

    testWidgets('states the reciprocity requirement honestly (§9 P-2)',
        (tester) async {
      await tester.pumpWidget(_app(
        const Scaffold(
          body: SingleChildScrollView(
            child: CloseFriendsAnswersRow(
              answers: [
                CloseFriendAnswer.approval(
                  handle: '@sunny_scales',
                  answerLabel: 'Approve',
                  value: 0.5,
                ),
              ],
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.text('Close friends'), findsOneWidget);
      expect(
        find.textContaining("Close friends can see each other's answers"),
        findsOneWidget,
      );
    });
  });
}
