// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// `NetworkResultsSection` — which card the viewer actually sees, and what the
// real card is allowed to say.
//
// The interesting cases are the boring-looking ones: an undeployed backend must
// look exactly like the world before this feature existed, and a close friend
// who opted out must look exactly like a friend who never shared. Both are
// asserted here because both are invisible by design, and an invisible rule is
// the one a refactor breaks without anyone noticing.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:read_the_room/src/models/network_graph.dart';
import 'package:read_the_room/src/models/network_results.dart';
import 'package:read_the_room/src/services/friend_service.dart';
import 'package:read_the_room/src/services/network_service.dart';
import 'package:read_the_room/src/utils/friend_logic.dart';
import 'package:read_the_room/src/widgets/close_friends_answers_row.dart';
import 'package:read_the_room/src/widgets/network_aggregate_card.dart';
import 'package:read_the_room/src/widgets/network_demo_card.dart';
import 'package:read_the_room/src/widgets/network_graph_preview.dart';
import 'package:read_the_room/src/widgets/network_not_enough_card.dart';
import 'package:read_the_room/src/widgets/network_results_section.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A FriendService with a fixed accepted-friend count and no Supabase behind it.
class _FakeFriends extends FriendService {
  _FakeFriends({this.count = 0, this.authenticated = true, this.close = const []})
      : super(listenToAuth: false);

  final int count;
  final bool authenticated;
  final List<Friend> close;

  @override
  bool get isAuthenticated => authenticated;

  @override
  bool get isLoaded => true;

  @override
  int get friendCount => count;

  @override
  List<Friend> get closeFriends => close;

  @override
  Future<void> load() async {}
}

/// A NetworkService that answers from a fixture instead of the database.
class _FakeNetwork extends NetworkService {
  _FakeNetwork({required this.results, this.closeFriends = const []});

  final NetworkResults results;
  final List<CloseFriendAnswer> closeFriends;

  @override
  Future<NetworkResults> getNetworkResults(String questionId,
          {String questionType = '', bool forceRefresh = false}) async =>
      results;

  @override
  Future<List<CloseFriendAnswer>> getCloseFriendAnswers(
          String questionId) async =>
      closeFriends;

  @override
  Future<bool> localSharing(String questionId) async => true;
}

NetworkResults _results(Map<String, dynamic> json) =>
    NetworkResults.fromJson(json, fallbackQuestionId: 'q1');

Map<String, dynamic> _ungatedApproval({
  List<Map<String, dynamic>>? nodes,
  int friendOverflow = 0,
}) =>
    <String, dynamic>{
      'success': true,
      'question_id': 'q1',
      'question_type': 'approval_rating',
      'k': 3,
      'friend_count': 12,
      'gated': false,
      'reason': null,
      'respondents': 9,
      'hidden': 2,
      'buckets': [0, 3, 3, 0, 3],
      'average': -0.18,
      'friend_overflow': friendOverflow,
      'graph': {
        'nodes': nodes ??
            <Map<String, dynamic>>[
              {
                'id': 'self',
                'kind': 'self',
                'answered': true,
                'answer_kind': 'approval',
                'approval_value': 0.4,
              },
              {
                'id': 'f_1',
                'kind': 'close_friend',
                'parent_id': 'self',
                'user_id': '1',
                'handle': 'nova_newt',
                'answered': true,
                'fof_overflow': 2,
                'answer_kind': 'approval',
                'approval_value': -0.55,
              },
              {
                'id': 'f_2',
                'kind': 'friend',
                'parent_id': 'self',
                'user_id': '2',
                'handle': 'flick_thegecko',
                'answered': true,
                'answer_kind': null,
              },
              {
                'id': 'x_abc',
                'kind': 'friend_of_friend',
                'parent_id': 'f_1',
                'answered': true,
                'answer_kind': 'approval',
                'approval_value': 0.9,
              },
            ],
      },
    };

Map<String, dynamic> _gated(String reason, int friendCount) => <String, dynamic>{
      'success': true,
      'question_id': 'q1',
      'question_type': 'approval_rating',
      'k': 3,
      'friend_count': friendCount,
      'gated': true,
      'reason': reason,
      'respondents': 0,
      'hidden': 0,
      'graph': null,
    };

Widget _app(FriendService friends, Widget child) => MaterialApp(
      theme: ThemeData(primaryColor: const Color(0xFF00897B)),
      home: MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: ChangeNotifierProvider<FriendService>.value(
          value: friends,
          child: Scaffold(body: SingleChildScrollView(child: child)),
        ),
      ),
    );

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  group('which card', () {
    testWidgets('an ungated result draws the real network', (tester) async {
      await tester.pumpWidget(_app(
        _FakeFriends(count: 12),
        NetworkResultsSection(
          questionId: 'q1',
          questionType: 'approval_rating',
          service: _FakeNetwork(results: _results(_ungatedApproval())),
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.byType(NetworkGraphPreview), findsOneWidget);
      // Graph + toggle only: the aggregate card and the close-friends row are
      // hidden (owner, 2026-09-22), and the caption is the demo's explainer.
      expect(find.byType(NetworkAggregateCard), findsNothing);
      expect(find.byType(CloseFriendsAnswersRow), findsNothing);
      expect(find.textContaining('Friends keep their answers private'),
          findsOneWidget);
      expect(find.text('Your network'), findsOneWidget);
      // No demo, and no DEMO badge anywhere near a real graph.
      expect(find.byType(NetworkDemoCard), findsNothing);
      expect(find.text('DEMO'), findsNothing);
      expect(find.byType(NetworkNotEnoughCard), findsNothing);
    });

    testWidgets('not_enough_friends draws nothing: no demo on results screens',
        (tester) async {
      await tester.pumpWidget(_app(
        _FakeFriends(count: 2),
        NetworkResultsSection(
          questionId: 'q1',
          service: _FakeNetwork(results: _results(_gated('not_enough_friends', 2))),
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.byType(NetworkDemoCard), findsNothing);
      expect(find.byType(NetworkNotEnoughCard), findsNothing);
    });

    testWidgets('not_enough_answers draws the lick nudge', (tester) async {
      await tester.pumpWidget(_app(
        _FakeFriends(count: 8),
        NetworkResultsSection(
          questionId: 'q1',
          service: _FakeNetwork(results: _results(_gated('not_enough_answers', 8))),
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.byType(NetworkNotEnoughCard), findsOneWidget);
      expect(find.byType(NetworkDemoCard), findsNothing);
      // The owner's copy, unchanged.
      expect(
        find.textContaining('Not enough of your friends have answered'),
        findsOneWidget,
      );
    });

    testWidgets('an undeployed backend looks like it did before the feature',
        (tester) async {
      await tester.pumpWidget(_app(
        _FakeFriends(count: 8),
        NetworkResultsSection(
          questionId: 'q1',
          service: _FakeNetwork(results: NetworkResults.unavailable('q1')),
        ),
      ));
      await tester.pumpAndSettle();

      // A circle with an unknown count: the nudge, never an error and never a
      // blank slot.
      expect(find.byType(NetworkNotEnoughCard), findsOneWidget);
      expect(find.byType(NetworkGraphPreview), findsNothing);
    });

    testWidgets('a guest sees nothing at all', (tester) async {
      await tester.pumpWidget(_app(
        _FakeFriends(count: 12, authenticated: false),
        NetworkResultsSection(
          questionId: 'q1',
          service: _FakeNetwork(results: _results(_ungatedApproval())),
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.byType(NetworkGraphPreview), findsNothing);
      expect(find.byType(NetworkDemoCard), findsNothing);
      expect(find.byType(NetworkNotEnoughCard), findsNothing);
    });
  });

  group('what the real card says', () {
    testWidgets('the respondent count is the server\'s, not the node count',
        (tester) async {
      await tester.pumpWidget(_app(
        _FakeFriends(count: 12),
        NetworkResultsSection(
          questionId: 'q1',
          questionType: 'approval_rating',
          service: _FakeNetwork(results: _results(_ungatedApproval())),
        ),
      ));
      await tester.pumpAndSettle();

      // 9 respondents with 2 withheld, over a graph of 4 nodes — the count is
      // not rendered any more (aggregate card hidden), but it is what the
      // analytics bucket is computed from.
      expect(find.textContaining('people in your network'), findsNothing);
      expect(find.textContaining('answers from your network'), findsNothing);
    });

    testWidgets('a text question gets a count and no distribution',
        (tester) async {
      await tester.pumpWidget(_app(
        _FakeFriends(count: 12),
        NetworkResultsSection(
          questionId: 'q1',
          questionType: 'text',
          service: _FakeNetwork(
            results: _results(<String, dynamic>{
              'success': true,
              'question_id': 'q1',
              'question_type': 'text',
              'gated': false,
              'respondents': 6,
              'hidden': 0,
              'text_count': 6,
              'graph': {
                'nodes': [
                  {'id': 'self', 'kind': 'self', 'answered': true},
                ],
              },
            }),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.byType(NetworkGraphPreview), findsOneWidget);
      expect(find.textContaining('answers from your network'), findsNothing);
      expect(find.byType(NetworkAggregateCard), findsNothing);
    });

    testWidgets('close friends appear only when the server sent them',
        (tester) async {
      await tester.pumpWidget(_app(
        _FakeFriends(count: 12),
        NetworkResultsSection(
          questionId: 'q1',
          questionType: 'approval_rating',
          service: _FakeNetwork(
            results: _results(_ungatedApproval()),
            closeFriends: const [
              CloseFriendAnswer.approval(
                handle: '@nova_newt',
                answerLabel: 'Disapprove',
                value: -0.55,
              ),
            ],
          ),
        ),
      ));
      await tester.pumpAndSettle();

      // Hidden by owner decision (2026-09-22): the row is never drawn, even
      // when the server would have sent rows, and the RPC is not called.
      expect(find.byType(CloseFriendsAnswersRow), findsNothing);
      expect(find.text('@nova_newt'), findsNothing);
    });

    testWidgets('an empty close-friend list draws no row', (tester) async {
      await tester.pumpWidget(_app(
        _FakeFriends(count: 12),
        NetworkResultsSection(
          questionId: 'q1',
          questionType: 'approval_rating',
          service: _FakeNetwork(results: _results(_ungatedApproval())),
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.byType(CloseFriendsAnswersRow), findsNothing);
    });
  });

  group('the graph hydrates from real nodes', () {
    testWidgets('a close friend who opted out is grey like any friend',
        (tester) async {
      final json = _ungatedApproval();
      final nodes = (json['graph'] as Map)['nodes'] as List;
      (nodes[1] as Map)['answer_kind'] = null;
      (nodes[1] as Map)['approval_value'] = null;

      await tester.pumpWidget(_app(
        _FakeFriends(count: 12),
        NetworkResultsSection(
          questionId: 'q1',
          questionType: 'approval_rating',
          service: _FakeNetwork(results: _results(json)),
        ),
      ));
      await tester.pumpAndSettle();

      final preview =
          tester.widget<NetworkGraphPreview>(find.byType(NetworkGraphPreview));
      final close = preview.data.closeFriends.single;
      final regular = preview.data.regularFriends.single;
      expect(close.answered, isTrue);
      expect(close.hasAnswer, isFalse);
      expect(close.hasAnswer, regular.hasAnswer,
          reason: 'an opt-out must not be observable');
    });

    testWidgets('the friend-of-friend is anonymous and parented to its bridge',
        (tester) async {
      await tester.pumpWidget(_app(
        _FakeFriends(count: 12),
        NetworkResultsSection(
          questionId: 'q1',
          questionType: 'approval_rating',
          service: _FakeNetwork(results: _results(_ungatedApproval())),
        ),
      ));
      await tester.pumpAndSettle();

      final preview =
          tester.widget<NetworkGraphPreview>(find.byType(NetworkGraphPreview));
      final fof = preview.data.friendsOfFriends.single;
      expect(fof.handle, isNull);
      expect(fof.userId, isNull);
      expect(fof.parentId, 'f_1');
      expect(preview.data.closeFriends.single.fofOverflow, 2);
    });

    testWidgets('friend_overflow is reported in the caption', (tester) async {
      await tester.pumpWidget(_app(
        _FakeFriends(count: 40),
        NetworkResultsSection(
          questionId: 'q1',
          questionType: 'approval_rating',
          service:
              _FakeNetwork(results: _results(_ungatedApproval(friendOverflow: 7))),
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.textContaining('7 more friends not shown'), findsOneWidget);
    });
  });

  group('the analytics buckets', () {
    test('are coarse, because an exact count is itself a signal', () {
      expect(respondentsBucket(0), '0-2');
      expect(respondentsBucket(2), '0-2');
      expect(respondentsBucket(3), '3-5');
      expect(respondentsBucket(5), '3-5');
      expect(respondentsBucket(6), '6-10');
      expect(respondentsBucket(10), '6-10');
      expect(respondentsBucket(11), '11+');
      expect(respondentsBucket(9999), '11+');
    });
  });
}
