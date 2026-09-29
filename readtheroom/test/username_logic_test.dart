// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Pure handle validation + suggestion generation (WP-C1).
// The rules mirror networks-update-design §5.1 and the `set_username()` RPC in
// supabase/migrations/user_profiles.sql — if one changes, both these tests and
// the SQL CHECK must change together.

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:read_the_room/src/utils/username_logic.dart';

void main() {
  group('isValidUsername (§5.1 charset rule)', () {
    test('accepts the canonical shapes', () {
      expect(isValidUsername('abc'), isTrue); // minimum length
      expect(isValidUsername('curious_chameleon7'), isTrue);
      expect(isValidUsername('a1_b2_c3'), isTrue);
      expect(isValidUsername('0starter'), isTrue); // digit first is fine
      expect(isValidUsername('a' * 20), isTrue); // maximum length
    });

    test('rejects wrong length', () {
      expect(isValidUsername(''), isFalse);
      expect(isValidUsername('ab'), isFalse);
      expect(isValidUsername('a' * 21), isFalse);
    });

    test('rejects a leading underscore', () {
      expect(isValidUsername('_hidden'), isFalse);
    });

    test('rejects uppercase, spaces, punctuation and unicode', () {
      expect(isValidUsername('Chameleon'), isFalse);
      expect(isValidUsername('two words'), isFalse);
      expect(isValidUsername('hy-phen'), isFalse);
      expect(isValidUsername('dot.dot'), isFalse);
      expect(isValidUsername('emoji🦎'), isFalse);
    });

    test('rejects null', () {
      expect(isValidUsername(null), isFalse);
    });
  });

  group('normalizeUsername', () {
    test('trims and lowercases', () {
      expect(normalizeUsername('  Curious_Cham7 '), 'curious_cham7');
    });
  });

  group('usernameFormatError', () {
    test('returns null for a valid handle', () {
      expect(usernameFormatError('curious_cham7'), isNull);
      // Normalisation happens first, so typed uppercase is acceptable input.
      expect(usernameFormatError('Curious_Cham7'), isNull);
    });

    test('classifies each failure mode', () {
      expect(usernameFormatError('   '), UsernameFormatError.empty);
      expect(usernameFormatError('ab'), UsernameFormatError.tooShort);
      expect(usernameFormatError('a' * 21), UsernameFormatError.tooLong);
      expect(
        usernameFormatError('_lead'),
        UsernameFormatError.leadingUnderscore,
      );
      expect(
        usernameFormatError('bad chars!'),
        UsernameFormatError.invalidCharacters,
      );
    });

    test('leading underscore is reported ahead of length', () {
      // "_a" is both too short and underscore-led; the underscore hint is the
      // actionable one.
      expect(usernameFormatError('_a'), UsernameFormatError.leadingUnderscore);
    });

    test('every failure mode has non-empty copy', () {
      for (final error in UsernameFormatError.values) {
        expect(usernameFormatErrorMessage(error), isNotEmpty);
      }
    });
  });

  group('generateUsername', () {
    test('every generated handle is valid, over many seeds', () {
      for (var seed = 0; seed < 500; seed++) {
        final candidate = generateUsername(Random(seed));
        expect(
          isValidUsername(candidate),
          isTrue,
          reason: 'seed $seed produced invalid handle "$candidate"',
        );
      }
    });

    test('is deterministic for a given seed', () {
      expect(generateUsername(Random(42)), generateUsername(Random(42)));
    });

    test('uses the adjective_noun+number shape', () {
      final candidate = generateUsername(Random(7));
      expect(candidate, contains('_'));
      expect(RegExp(r'[0-9]+$').hasMatch(candidate), isTrue);
    });
  });

  group('generateUsernameSuggestions', () {
    test('returns the requested count, all distinct and valid', () {
      final suggestions = generateUsernameSuggestions(3, random: Random(1));
      expect(suggestions, hasLength(3));
      expect(suggestions.toSet(), hasLength(3));
      for (final s in suggestions) {
        expect(isValidUsername(s), isTrue);
      }
    });

    test('honours the isAllowed profanity gate (decision D4)', () {
      // Reject anything containing "cham" — the filter must be applied to the
      // generated candidates, not only to typed input.
      final suggestions = generateUsernameSuggestions(
        5,
        random: Random(3),
        isAllowed: (candidate) => !candidate.contains('cham'),
      );
      for (final s in suggestions) {
        expect(s, isNot(contains('cham')));
      }
    });

    test('terminates (empty) when nothing is allowed', () {
      final suggestions = generateUsernameSuggestions(
        3,
        random: Random(5),
        isAllowed: (_) => false,
      );
      expect(suggestions, isEmpty);
    });

    test('count of zero yields nothing', () {
      expect(generateUsernameSuggestions(0, random: Random(9)), isEmpty);
    });
  });

  group('thanksForContributingText (backlog item 7)', () {
    test('falls back to the original copy with no handle', () {
      expect(thanksForContributingText(null), 'Thanks for contributing today');
      expect(thanksForContributingText(''), 'Thanks for contributing today');
      expect(thanksForContributingText('   '), 'Thanks for contributing today');
    });

    test('personalises when a handle exists', () {
      expect(
        thanksForContributingText('curious_cham7'),
        'Thanks for contributing today, curious_cham7',
      );
    });

    test('breakAfterComma puts the handle on its own line (home card)', () {
      expect(
        thanksForContributingText('curious_cham7', breakAfterComma: true),
        'Thanks for contributing today,\ncurious_cham7',
      );
      // No handle, nothing to break before.
      expect(
        thanksForContributingText(null, breakAfterComma: true),
        'Thanks for contributing today',
      );
    });

    test('exclaim matches the streak-celebration punctuation', () {
      expect(
        thanksForContributingText(null, exclaim: true),
        'Thanks for contributing today!',
      );
      expect(
        thanksForContributingText('zany_cham1', exclaim: true),
        'Thanks for contributing today, zany_cham1!',
      );
    });
  });

  group('vocabulary hygiene', () {
    test('every adjective survives the handle charset', () {
      for (final adjective in kHandleAdjectives) {
        expect(
          RegExp(r'^[a-z0-9]+$').hasMatch(adjective),
          isTrue,
          reason: 'adjective "$adjective" is not handle-safe',
        );
      }
    });

    test('every noun survives the handle charset', () {
      for (final noun in kHandleNouns) {
        expect(RegExp(r'^[a-z0-9]+$').hasMatch(noun), isTrue,
            reason: 'noun "$noun" is not handle-safe');
      }
    });

    test('no duplicate vocabulary entries', () {
      expect(kHandleAdjectives.toSet(), hasLength(kHandleAdjectives.length));
      expect(kHandleNouns.toSet(), hasLength(kHandleNouns.length));
    });
  });
}
