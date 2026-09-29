// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The Dart side of the response-linkage read contract.
//
// The fixtures below are the envelopes from the design doc's §2.3 and from the
// `jsonb_build_object` calls in scripts/response_linkage_04_read_rpcs.sql —
// where the two disagreed, the SQL won, because the SQL is what answers.
//
// What these tests are really defending is the set of rules a careless
// refactor would quietly break: a gate is not an error, a gate carries no
// graph, a null `answer_kind` means grey whoever the node is, and the server's
// quantised numbers are never recomputed here.

import 'package:flutter_test/flutter_test.dart';
import 'package:read_the_room/src/models/network_graph.dart';
import 'package:read_the_room/src/models/network_results.dart';
import 'package:read_the_room/src/utils/network_card_logic.dart';

/// The approval example from design §2.3, verbatim.
Map<String, dynamic> approvalEnvelope() => <String, dynamic>{
      'success': true,
      'v': 1,
      'question_id': '8f1c0000-0000-0000-0000-000000000001',
      'question_type': 'approval_rating',
      'k': 3,
      'friend_count': 12,
      'gated': false,
      'reason': null,
      'respondents': 9,
      'hidden': 2,
      'options': null,
      'buckets': [0, 3, 3, 0, 3],
      'average': -0.18,
      'text_count': null,
      'friend_overflow': 0,
      'graph': {
        'nodes': [
          {
            'id': 'self',
            'kind': 'self',
            'parent_id': null,
            'user_id': null,
            'handle': null,
            'avatar_id': null,
            'answered': true,
            'fof_overflow': 0,
            'answer_kind': 'approval',
            'approval_value': 0.40,
            'option_id': null,
            'option_index': null,
            'answer_label': null,
          },
          {
            'id': 'f_3b9e',
            'kind': 'close_friend',
            'parent_id': 'self',
            'user_id': '3b9e',
            'handle': 'nova_newt',
            'avatar_id': 'chameleon_03',
            'answered': true,
            'fof_overflow': 2,
            'answer_kind': 'approval',
            'approval_value': -0.55,
            'option_id': null,
            'option_index': null,
            'answer_label': null,
          },
          {
            'id': 'f_a11d',
            'kind': 'friend',
            'parent_id': 'self',
            'user_id': 'a11d',
            'handle': 'flick_thegecko',
            'avatar_id': 'chameleon_07',
            'answered': true,
            'fof_overflow': 0,
            'answer_kind': null,
            'approval_value': null,
            'option_id': null,
            'option_index': null,
            'answer_label': null,
          },
          {
            'id': 'x_9c02f4ad71b6e358',
            'kind': 'friend_of_friend',
            'parent_id': 'f_3b9e',
            'user_id': null,
            'handle': null,
            'avatar_id': null,
            'answered': true,
            'fof_overflow': 0,
            'answer_kind': 'approval',
            'approval_value': 0.90,
            'option_id': null,
            'option_index': null,
            'answer_label': null,
          },
        ],
      },
    };

Map<String, dynamic> gatedEnvelope(String reason) => <String, dynamic>{
      'success': true,
      'v': 1,
      'question_id': 'q1',
      'question_type': 'approval_rating',
      'k': 3,
      'friend_count': reason == 'not_enough_friends' ? 1 : 8,
      'gated': true,
      'reason': reason,
      'respondents': 0,
      'hidden': 0,
      'options': null,
      'buckets': null,
      'average': null,
      'text_count': null,
      'friend_overflow': 0,
      'graph': null,
    };

void main() {
  group('get_network_results — ungated approval', () {
    test('parses the envelope without recomputing anything', () {
      final r = NetworkResults.fromJson(approvalEnvelope());

      expect(r.available, isTrue);
      expect(r.gated, isFalse);
      expect(r.reason, isNull);
      expect(r.questionType, 'approval_rating');
      expect(r.k, 3);
      expect(r.friendCount, 12);
      // The server said 9 with 2 withheld. The graph has 4 nodes. The count
      // must come from the server, never from counting dots.
      expect(r.respondents, 9);
      expect(r.hidden, 2);
      expect(r.buckets, <int>[0, 3, 3, 0, 3]);
      expect(r.average, closeTo(-0.18, 1e-9));
      expect(r.options, isNull);
      expect(r.textCount, isNull);
      expect(r.hasGraph, isTrue);
    });

    test('node kinds, parents and identity rules', () {
      final graph = NetworkResults.fromJson(approvalEnvelope()).graph!;

      expect(graph.nodes.length, 4);
      expect(graph.self.kind, NetworkNodeKind.self);
      expect(graph.directFriends.length, 2);
      expect(graph.closeFriends.length, 1);
      expect(graph.regularFriends.length, 1);
      expect(graph.friendsOfFriends.length, 1);

      // A friend-of-friend is anonymous and parented to its bridging friend.
      final fof = graph.friendsOfFriends.single;
      expect(fof.handle, isNull);
      expect(fof.userId, isNull);
      expect(fof.parentId, 'f_3b9e');
      expect(fof.approvalValue, closeTo(0.90, 1e-9));

      // A direct friend keeps their account id — the viewer already knows them.
      expect(graph.closeFriends.single.userId, '3b9e');
      expect(graph.closeFriends.single.handle, '@nova_newt');
      expect(graph.closeFriends.single.avatarId, 'chameleon_03');
    });

    test('a regular friend answered but shows no answer', () {
      final graph = NetworkResults.fromJson(approvalEnvelope()).graph!;
      final regular = graph.regularFriends.single;
      expect(regular.answered, isTrue, reason: 'they did answer');
      expect(regular.hasAnswer, isFalse, reason: 'you may not see it');
      expect(regular.answerKind, isNull);
    });

    test('fof_overflow rides on the bridging friend', () {
      final graph = NetworkResults.fromJson(approvalEnvelope()).graph!;
      expect(graph.closeFriends.single.fofOverflow, 2);
      expect(graph.regularFriends.single.fofOverflow, 0);
      expect(graph.friendsOfFriends.single.fofOverflow, 0);
    });

    test('friends-of-friends group under their bridge', () {
      final graph = NetworkResults.fromJson(approvalEnvelope()).graph!;
      expect(graph.fofByParent.keys, <String>['f_3b9e']);
      expect(graph.fofByParent['f_3b9e']!.length, 1);
    });
  });

  group('get_network_results — a close friend who opted out', () {
    test('is a close-friend node with no answer, indistinguishable from grey',
        () {
      final json = approvalEnvelope();
      final nodes = (json['graph'] as Map)['nodes'] as List;
      // The server nulls the whole answer half when the share flag is off, and
      // leaves `answered` truthful.
      (nodes[1] as Map)['answer_kind'] = null;
      (nodes[1] as Map)['approval_value'] = null;

      final graph = NetworkResults.fromJson(json).graph!;
      final close = graph.closeFriends.single;
      expect(close.kind, NetworkNodeKind.closeFriend);
      expect(close.answered, isTrue);
      expect(close.hasAnswer, isFalse);
      // Same observable answer state as the regular friend beside them.
      expect(close.hasAnswer, graph.regularFriends.single.hasAnswer);
    });
  });

  group('get_network_results — multiple choice', () {
    test('options carry their own colour index, not their list position', () {
      final r = NetworkResults.fromJson(<String, dynamic>{
        'success': true,
        'v': 1,
        'question_id': 'q2',
        'question_type': 'multiple_choice',
        'k': 3,
        'friend_count': 9,
        'gated': false,
        'reason': null,
        'respondents': 9,
        'hidden': 1,
        // Ordered by votes desc, as the server sends it.
        'options': [
          {'option_id': 'c4a1', 'label': 'Pizza', 'option_index': 2, 'votes': 6},
          {'option_id': 'b220', 'label': 'Pasta', 'option_index': 0, 'votes': 3},
        ],
        'buckets': null,
        'average': null,
        'text_count': null,
        'friend_overflow': 4,
        'graph': {'nodes': []},
      });

      expect(r.hasGraph, isTrue);
      expect(r.options!.length, 2);
      expect(r.options![0].label, 'Pizza');
      expect(r.options![0].optionIndex, 2);
      expect(r.options![0].votes, 6);
      expect(r.options![1].optionIndex, 0);
      expect(r.friendOverflow, 4);
      expect(r.buckets, isNull);
    });

    test('a multiple-choice node keeps its option index and label', () {
      final r = NetworkResults.fromJson(<String, dynamic>{
        'success': true,
        'question_id': 'q2',
        'question_type': 'multiple_choice',
        'gated': false,
        'respondents': 3,
        'graph': {
          'nodes': [
            {
              'id': 'self',
              'kind': 'self',
              'answered': true,
              'answer_kind': 'multiple_choice',
              'option_id': 'c4a1',
              'option_index': 2,
              'answer_label': 'Pizza',
            },
          ],
        },
      });
      final self = r.graph!.self;
      expect(self.answerKind, NetworkAnswerKind.multipleChoice);
      expect(self.optionIndex, 2);
      expect(self.answerLabel, 'Pizza');
      expect(self.approvalValue, isNull);
    });
  });

  group('get_network_results — text', () {
    test('a count and no colour anywhere (owner decision D-1)', () {
      final r = NetworkResults.fromJson(<String, dynamic>{
        'success': true,
        'v': 1,
        'question_id': 'q3',
        'question_type': 'text',
        'k': 3,
        'friend_count': 7,
        'gated': false,
        'reason': null,
        'respondents': 6,
        'hidden': 1,
        'options': null,
        'buckets': null,
        'average': null,
        'text_count': 6,
        'friend_overflow': 0,
        'graph': {
          'nodes': [
            {
              'id': 'self',
              'kind': 'self',
              'answered': true,
              'answer_kind': null,
              'approval_value': null,
            },
            {
              'id': 'f_1',
              'kind': 'close_friend',
              'parent_id': 'self',
              'user_id': '1',
              'handle': 'basil_basks',
              'answered': true,
              'answer_kind': null,
            },
          ],
        },
      });

      expect(r.textCount, 6);
      expect(r.respondents, 6);
      // Not one node on a text question carries a colourable answer — not even
      // the viewer's own, and not a close friend's.
      for (final n in r.graph!.nodes) {
        expect(n.hasAnswer, isFalse);
      }
      expect(r.graph!.closeFriends.single.answered, isTrue);
    });
  });

  group('gates', () {
    test('a gate is success, carries a reason and has no graph', () {
      for (final reason in <String>['not_enough_friends', 'not_enough_answers']) {
        final r = NetworkResults.fromJson(gatedEnvelope(reason));
        expect(r.available, isTrue, reason: '$reason reached the server');
        expect(r.gated, isTrue);
        expect(r.graph, isNull);
        expect(r.hasGraph, isFalse);
        expect(r.respondents, 0);
      }
      expect(NetworkResults.fromJson(gatedEnvelope('not_enough_friends')).reason,
          NetworkGateReason.notEnoughFriends);
      expect(NetworkResults.fromJson(gatedEnvelope('not_enough_answers')).reason,
          NetworkGateReason.notEnoughAnswers);
    });

    test('a graph is dropped if a gated payload ever carried one', () {
      final json = gatedEnvelope('not_enough_answers');
      json['graph'] = {
        'nodes': [
          {'id': 'self', 'kind': 'self'}
        ]
      };
      expect(NetworkResults.fromJson(json).graph, isNull);
    });

    test('an unknown reason string does not become a gate reason', () {
      final json = gatedEnvelope('not_enough_friends');
      json['reason'] = 'something_new';
      final r = NetworkResults.fromJson(json);
      expect(r.gated, isTrue);
      expect(r.reason, isNull);
    });
  });

  group('failures degrade to unavailable', () {
    test('every named error code', () {
      for (final code in <String>[
        'not_authenticated',
        'rate_limited',
        'question_not_found',
      ]) {
        final r = NetworkResults.fromJson(
            <String, dynamic>{'success': false, 'error': code},
            fallbackQuestionId: 'q9');
        expect(r.available, isFalse, reason: code);
        expect(r.gated, isTrue);
        expect(r.reason, NetworkGateReason.unavailable);
        expect(r.hasGraph, isFalse);
        expect(r.networkAnswered, isNull,
            reason: 'unknown is not the same as zero');
      }
    });

    test('unavailable() is the same shape', () {
      final r = NetworkResults.unavailable('q9', 'text');
      expect(r.available, isFalse);
      expect(r.reason, NetworkGateReason.unavailable);
      expect(r.respondents, 0);
      expect(r.k, 3);
    });
  });

  group('parser tolerance', () {
    test('unknown fields are ignored and missing ones tolerated', () {
      final json = approvalEnvelope();
      json['some_future_field'] = {'nested': true};
      (((json['graph'] as Map)['nodes'] as List)[0] as Map)['new_thing'] = 7;
      final r = NetworkResults.fromJson(json);
      expect(r.graph!.nodes.length, 4);
      expect(r.respondents, 9);
    });

    test('a nearly empty success envelope parses', () {
      final r = NetworkResults.fromJson(<String, dynamic>{'success': true},
          fallbackQuestionId: 'q0', fallbackQuestionType: 'text');
      expect(r.available, isTrue);
      expect(r.questionId, 'q0');
      expect(r.questionType, 'text');
      expect(r.k, 3, reason: 'k defaults to the server constant');
      expect(r.gated, isFalse);
      expect(r.graph, isNull);
    });

    test('numbers arriving as strings still parse', () {
      final json = approvalEnvelope();
      json['respondents'] = '9';
      json['average'] = '-0.18';
      json['buckets'] = ['0', 3, 3, 0, '3'];
      final r = NetworkResults.fromJson(json);
      expect(r.respondents, 9);
      expect(r.average, closeTo(-0.18, 1e-9));
      expect(r.buckets, <int>[0, 3, 3, 0, 3]);
    });

    test('an unknown node kind falls back to a plain friend', () {
      final json = approvalEnvelope();
      (((json['graph'] as Map)['nodes'] as List)[2] as Map)['kind'] = 'cousin';
      final graph = NetworkResults.fromJson(json).graph!;
      expect(graph.regularFriends.length, 1);
    });

    test('a graph with no self node still has one', () {
      final graph = NetworkGraphData.fromJson(<String, dynamic>{
        'nodes': [
          {'id': 'f_1', 'kind': 'friend', 'parent_id': 'self'}
        ]
      });
      expect(graph.self.id, 'self');
      expect(graph.self.answered, isFalse);
    });
  });

  group('get_network_answered_counts', () {
    test('parses the batch reply', () {
      final counts = NetworkAnsweredCounts.fromJson(<String, dynamic>{
        'success': true,
        'v': 1,
        'gated_all': false,
        'friend_count': 12,
        'counts': [
          {'question_id': 'a', 'respondents': 9, 'gated': false},
          {'question_id': 'b', 'respondents': 0, 'gated': true},
        ],
      });
      expect(counts.available, isTrue);
      expect(counts.friendCount, 12);
      expect(counts.respondentsFor('a'), 9);
      expect(counts.respondentsFor('b'), 0);
      // A question that was not asked about is zero, not null: the call
      // succeeded, and the server simply had nothing for it.
      expect(counts.respondentsFor('c'), 0);
    });

    test('gated_all means nobody has a card', () {
      final counts = NetworkAnsweredCounts.fromJson(<String, dynamic>{
        'success': true,
        'v': 1,
        'gated_all': true,
        'friend_count': 2,
        'counts': [],
      });
      expect(counts.gatedAll, isTrue);
      expect(counts.respondentsFor('a'), 0);
    });

    test('a failure is unknown, not zero', () {
      final counts = NetworkAnsweredCounts.fromJson(
          <String, dynamic>{'success': false, 'error': 'too_many'});
      expect(counts.available, isFalse);
      expect(counts.respondentsFor('a'), isNull);
    });
  });

  group('gate to card', () {
    test('an ungated payload is the real card, whatever the local count says',
        () {
      final r = NetworkResults.fromJson(approvalEnvelope());
      expect(networkCardStateFor(r, localFriendCount: 0),
          NetworkCardState.realMap);
    });

    test('not_enough_friends draws the sample circle', () {
      final r = NetworkResults.fromJson(gatedEnvelope('not_enough_friends'));
      expect(networkCardStateFor(r, localFriendCount: 99),
          NetworkCardState.demo);
    });

    test('not_enough_answers draws the lick nudge', () {
      final r = NetworkResults.fromJson(gatedEnvelope('not_enough_answers'));
      expect(networkCardStateFor(r, localFriendCount: 0),
          NetworkCardState.notEnoughAnswers);
    });

    test('unavailable falls back to the client mirror', () {
      final r = NetworkResults.unavailable('q9');
      // No circle locally: the sample card, exactly as before the RPCs existed.
      expect(networkCardStateFor(r, localFriendCount: 2), NetworkCardState.demo);
      // A circle locally: the nudge, so the slot never silently disappears.
      expect(networkCardStateFor(r, localFriendCount: 7),
          NetworkCardState.notEnoughAnswers);
    });
  });
}
