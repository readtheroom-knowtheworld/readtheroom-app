// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// `get_close_friend_answers` rows, and the one rule that surface exists to
// keep: picks and slider positions, never a text body (owner decision D-1).
//
// The answer half of a row is produced by the same server helper as a graph
// node's, so a row with `answer_kind: null` is not an error — it is the server
// declining to colour something. There is nothing to draw, so it parses to
// null and the row never reaches the widget.
//
// Fixtures from design §2.3 and scripts/response_linkage_04_read_rpcs.sql.

import 'package:flutter_test/flutter_test.dart';
import 'package:read_the_room/src/models/network_graph.dart';

void main() {
  group('multiple choice', () {
    test('the design doc row, verbatim', () {
      final a = CloseFriendAnswer.fromJson(<String, dynamic>{
        'user_id': '3b9e',
        'username': 'nova_newt',
        'avatar_id': 'chameleon_03',
        'answered': true,
        'answer_kind': 'multiple_choice',
        'approval_value': null,
        'option_id': 'c4a1',
        'option_index': 2,
        'answer_label': 'Pizza',
      });

      expect(a, isNotNull);
      expect(a!.kind, NetworkAnswerKind.multipleChoice);
      expect(a.handle, '@nova_newt', reason: 'the app writes handles with an @');
      expect(a.userId, '3b9e');
      expect(a.avatarId, 'chameleon_03');
      // option_index is the colour key, and it is the question's own order.
      expect(a.optionIndex, 2);
      expect(a.answerLabel, 'Pizza');
      expect(a.approvalValue, isNull);
    });

    test('option_index 0 is a real index, not a missing one', () {
      final a = CloseFriendAnswer.fromJson(<String, dynamic>{
        'username': 'basil_basks',
        'answer_kind': 'multiple_choice',
        'option_index': 0,
        'answer_label': 'Never',
      });
      expect(a, isNotNull);
      expect(a!.optionIndex, 0);
    });

    test('no option index means nothing to colour', () {
      final a = CloseFriendAnswer.fromJson(<String, dynamic>{
        'username': 'basil_basks',
        'answer_kind': 'multiple_choice',
        'option_index': null,
        'answer_label': 'Never',
      });
      expect(a, isNull);
    });
  });

  group('approval', () {
    test('carries the normalised slider position', () {
      final a = CloseFriendAnswer.fromJson(<String, dynamic>{
        'user_id': 'c001',
        'username': 'curio_thechameleon',
        'answered': true,
        'answer_kind': 'approval',
        'approval_value': -0.55,
        'option_id': null,
        'option_index': null,
        'answer_label': null,
      });

      expect(a, isNotNull);
      expect(a!.kind, NetworkAnswerKind.approval);
      expect(a.approvalValue, closeTo(-0.55, 1e-9));
      expect(a.optionIndex, isNull);
      // The server sends no label for approval; one is derived from the value
      // so the chip is never blank.
      expect(a.answerLabel, 'Disapprove');
    });

    test('the derived label follows the server thresholds', () {
      String labelFor(double v) => CloseFriendAnswer.fromJson(<String, dynamic>{
            'username': 'x',
            'answer_kind': 'approval',
            'approval_value': v,
          })!.answerLabel;

      expect(labelFor(-0.95), 'Strongly disapprove');
      expect(labelFor(-0.80), 'Strongly disapprove');
      expect(labelFor(-0.55), 'Disapprove');
      expect(labelFor(0.0), 'Neutral');
      expect(labelFor(0.29), 'Neutral');
      expect(labelFor(0.55), 'Approve');
      expect(labelFor(0.90), 'Strongly approve');
    });

    test('an already-@ handle is not double-prefixed', () {
      final a = CloseFriendAnswer.fromJson(<String, dynamic>{
        'username': '@mango_morphs',
        'answer_kind': 'approval',
        'approval_value': 0.1,
      });
      expect(a!.handle, '@mango_morphs');
    });

    test('a missing username still renders a row', () {
      final a = CloseFriendAnswer.fromJson(<String, dynamic>{
        'user_id': 'x',
        'answer_kind': 'approval',
        'approval_value': 0.1,
      });
      expect(a!.handle, '@friend');
    });
  });

  group('text', () {
    test('a text question produces no close-friend row at all (D-1)', () {
      // What the server sends for a text question: the identity half filled in,
      // the answer half entirely null.
      final a = CloseFriendAnswer.fromJson(<String, dynamic>{
        'user_id': '3b9e',
        'username': 'nova_newt',
        'avatar_id': 'chameleon_03',
        'answered': true,
        'answer_kind': null,
        'approval_value': null,
        'option_id': null,
        'option_index': null,
        'answer_label': null,
      });
      expect(a, isNull, reason: 'there is no body to show, and never will be');
    });
  });

  test('an unknown answer kind is treated as nothing to show', () {
    final a = CloseFriendAnswer.fromJson(<String, dynamic>{
      'username': 'nova_newt',
      'answer_kind': 'ranked_choice',
    });
    expect(a, isNull);
  });
}
