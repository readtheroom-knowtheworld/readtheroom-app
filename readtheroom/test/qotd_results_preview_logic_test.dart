// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Unit tests for the pure QOTD answered-state results-preview helpers
// (own-answer matching + the card's copy). No Supabase, no widgets.
//
// The bucket/option distribution tests moved to question_results_test.dart with
// the maths itself: since the answers read lockdown (2026-09-22) the preview
// counts nothing, it renders the server's ResultsBreakdown.

import 'package:flutter_test/flutter_test.dart';
import 'package:read_the_room/src/utils/qotd_results_preview_logic.dart';

List<Map<String, dynamic>> _approval(List<double> values) =>
    [for (final v in values) {'answer': v}];

List<Map<String, dynamic>> _mc(List<String> answers) =>
    [for (final a in answers) {'answer': a}];

void main() {
  group('commentCountOf — tolerant read, absent → 0', () {
    test('reads an int comment_count', () {
      expect(commentCountOf({'comment_count': 5}), 5);
    });

    test('absent, null, or missing map → 0', () {
      expect(commentCountOf(null), 0);
      expect(commentCountOf(const {}), 0);
      expect(commentCountOf({'comment_count': null}), 0);
    });

    test('num and String shapes coerce', () {
      expect(commentCountOf({'comment_count': 3.0}), 3);
      expect(commentCountOf({'comment_count': '7'}), 7);
      expect(commentCountOf({'comment_count': '  4 '}), 4);
      expect(commentCountOf({'comment_count': 'oops'}), 0);
    });
  });

  group('qotdCommentButtonSpec — label/icon-mode decision', () {
    test('zero comments → "Start the conversation", no-comments mode', () {
      final spec = qotdCommentButtonSpec(0);
      expect(spec.label, 'Start the conversation');
      expect(spec.hasComments, isFalse);
    });

    test('negative count collapses to the "Start the conversation" variant', () {
      expect(qotdCommentButtonSpec(-1), qotdCommentButtonSpec(0));
    });

    test('one comment → singular-count label, has-comments mode', () {
      final spec = qotdCommentButtonSpec(1);
      expect(spec.label, 'Join the conversation (1)');
      expect(spec.hasComments, isTrue);
    });

    test('many comments → count embedded in label', () {
      expect(qotdCommentButtonSpec(42).label, 'Join the conversation (42)');
    });

    test('equality reflects label + mode', () {
      expect(qotdCommentButtonSpec(2), qotdCommentButtonSpec(2));
      expect(qotdCommentButtonSpec(2) == qotdCommentButtonSpec(3), isFalse);
    });
  });

  group('own-answer matching', () {
    test('ownApprovalBucket matches only the coarse labels', () {
      expect(ownApprovalBucket('Approve'), 'Approve');
      expect(ownApprovalBucket('Neutral'), 'Neutral');
      expect(ownApprovalBucket('Disapprove'), 'Disapprove');
      expect(ownApprovalBucket('  Approve  '), 'Approve');
      expect(ownApprovalBucket('Strongly Approve'), isNull);
      expect(ownApprovalBucket(null), isNull);
      expect(ownApprovalBucket(''), isNull);
    });

    test('ownOption matches an option that exists', () {
      const options = ['Cats', 'Dogs'];
      expect(ownOption('Dogs', options), 'Dogs');
      expect(ownOption('  Cats  ', options), 'Cats');
      expect(ownOption('Birds', options), isNull);
      expect(ownOption(null, options), isNull);
    });
  });
}
