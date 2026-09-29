// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// WP-D: compact-mode top-N reaction selection and the single-emoji guard that
// replaced the fixed 5-emoji allow-list.

import 'package:flutter_test/flutter_test.dart';
import 'package:read_the_room/src/utils/reaction_logic.dart';

List<String> _emojis(List<ReactionTally> tallies) =>
    tallies.map((t) => t.emoji).toList();

void main() {
  group('topReactions — compact mode selection', () {
    test('orders by count, highest first', () {
      final top = topReactions({'❤️': 2, '😂': 9, '🤔': 5});
      expect(_emojis(top), ['😂', '🤔', '❤️']);
      expect(top.first.count, 9);
    });

    test('caps at the limit', () {
      final top = topReactions(
        {'❤️': 5, '😂': 4, '🤔': 3, '😡': 2, '🤯': 1},
        limit: 3,
      );
      expect(_emojis(top), ['❤️', '😂', '🤔']);
    });

    test('drops zero and negative counts', () {
      final top = topReactions({'❤️': 0, '😂': 3, '🤔': -1});
      expect(_emojis(top), ['😂']);
    });

    test('empty map → empty list', () {
      expect(topReactions(const {}), isEmpty);
    });

    test('limit of zero or less → empty list', () {
      expect(topReactions({'❤️': 4}, limit: 0), isEmpty);
      expect(topReactions({'❤️': 4}, limit: -2), isEmpty);
    });

    test('ties break deterministically on the emoji', () {
      final a = topReactions({'😂': 2, '❤️': 2, '🤔': 2}, limit: 2);
      final b = topReactions({'🤔': 2, '😂': 2, '❤️': 2}, limit: 2);
      expect(_emojis(a), _emojis(b),
          reason: 'insertion order must not change the row');
    });

    test('fewer reactions than the limit returns them all', () {
      final top = topReactions({'❤️': 1}, limit: 3);
      expect(_emojis(top), ['❤️']);
    });
  });

  group('topReactions — the user\'s own reaction stays visible', () {
    test('a low-count own reaction is pinned into the row', () {
      final top = topReactions(
        {'❤️': 9, '😂': 8, '🤔': 7, '🤯': 1},
        limit: 3,
        alwaysInclude: {'🤯'},
      );
      expect(top.length, 3);
      expect(_emojis(top), contains('🤯'));
      // It displaces the weakest of the top three, not the strongest.
      expect(_emojis(top), contains('❤️'));
      expect(_emojis(top), isNot(contains('🤔')));
    });

    test('pinning keeps rank order (counts still descend)', () {
      final top = topReactions(
        {'❤️': 9, '😂': 8, '🤔': 7, '🤯': 1},
        limit: 3,
        alwaysInclude: {'🤯'},
      );
      final counts = top.map((t) => t.count).toList();
      final sorted = [...counts]..sort((a, b) => b.compareTo(a));
      expect(counts, sorted);
    });

    test('an own reaction already in the top N changes nothing', () {
      final top = topReactions(
        {'❤️': 9, '😂': 8, '🤔': 7, '🤯': 1},
        limit: 3,
        alwaysInclude: {'❤️'},
      );
      expect(_emojis(top), ['❤️', '😂', '🤔']);
    });

    test('an own reaction with no rows is not invented', () {
      final top = topReactions(
        {'❤️': 3},
        limit: 3,
        alwaysInclude: {'🦎'},
      );
      expect(_emojis(top), ['❤️']);
    });
  });

  group('totalReactionCount', () {
    test('sums the positive counts', () {
      expect(totalReactionCount({'❤️': 3, '😂': 4, '🤔': 0}), 7);
      expect(totalReactionCount(const {}), 0);
    });
  });

  group('isSingleEmoji', () {
    test('accepts the five original reactions', () {
      for (final e in ['❤️', '🤔', '😡', '😂', '🤯']) {
        expect(isSingleEmoji(e), isTrue, reason: e);
      }
    });

    test('accepts multi-code-point emoji as one grapheme', () {
      expect(isSingleEmoji('👍🏽'), isTrue); // skin tone modifier
      expect(isSingleEmoji('👩‍👩‍👧'), isTrue); // ZWJ family
      expect(isSingleEmoji('🇴🇲'), isTrue); // regional-indicator flag
      expect(isSingleEmoji('🦎'), isTrue);
    });

    test('rejects empty, whitespace, letters and digits', () {
      expect(isSingleEmoji(null), isFalse);
      expect(isSingleEmoji(''), isFalse);
      expect(isSingleEmoji(' '), isFalse);
      expect(isSingleEmoji('a'), isFalse);
      expect(isSingleEmoji('7'), isFalse);
      expect(isSingleEmoji('!'), isFalse);
    });

    test('rejects words and several emoji at once', () {
      expect(isSingleEmoji('lizard'), isFalse);
      expect(isSingleEmoji('😂😂'), isFalse);
      expect(isSingleEmoji('😂 '), isFalse);
      expect(isSingleEmoji('a😂'), isFalse);
    });
  });
}
