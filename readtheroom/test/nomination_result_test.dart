// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Pure unit tests for the Asker's Pick error → user-message mapping. Mirrors
// the BoostResult pattern; no Supabase needed. The error codes here must stay
// in lockstep with the `nominate_qotd` SQL RPC's json 'error' vocabulary.

import 'package:flutter_test/flutter_test.dart';
import 'package:read_the_room/src/services/nomination_result.dart';

void main() {
  group('NominationResult.parseError — RPC vocabulary', () {
    const cases = {
      'not_authenticated': NominationError.notAuthenticated,
      'question_not_found': NominationError.questionNotFound,
      'own_question': NominationError.ownQuestion,
      'not_eligible': NominationError.notEligible,
      'already_nominated': NominationError.alreadyNominated,
      'daily_limit': NominationError.dailyLimit,
    };

    cases.forEach((code, expected) {
      test('maps "$code" -> $expected', () {
        expect(NominationResult.parseError(code), expected);
      });
    });

    test('unknown / null codes fall back to unknown', () {
      expect(NominationResult.parseError('something_else'),
          NominationError.unknown);
      expect(NominationResult.parseError(null), NominationError.unknown);
    });
  });

  group('NominationResult.message', () {
    test('success has a positive, non-empty message', () {
      const result = NominationResult.ok();
      expect(result.success, isTrue);
      expect(result.message, isNotEmpty);
    });

    test('every error produces a distinct, non-empty, user-friendly message', () {
      final messages = <String>{};
      for (final error in NominationError.values) {
        final result = NominationResult.fail(error);
        expect(result.success, isFalse);
        expect(result.message, isNotEmpty, reason: '$error message empty');
        messages.add(result.message);
      }
      // Each distinct error surfaces its own message (unknown is the fallback).
      expect(messages.length, NominationError.values.length);
    });

    test('own_question and daily_limit map to their specific copy', () {
      expect(NominationResult.fail(NominationError.ownQuestion).message,
          contains("your own"));
      expect(NominationResult.fail(NominationError.dailyLimit).message,
          contains('today'));
    });
  });
}
