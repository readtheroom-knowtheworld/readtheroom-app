// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Unit tests for the device-local search-history helper and the "Posted by me"
// result partitioning (design doc §4.5). This logic was extracted from
// SearchScreen into lib/src/utils/search_history.dart so it can be tested
// without pumping the screen (which needs Supabase + the provider tree).

import 'package:flutter_test/flutter_test.dart';
import 'package:read_the_room/src/utils/search_history.dart';

void main() {
  group('SearchHistory.add — LRU, dedup, ordering', () {
    test('newest query is inserted at the front', () {
      var history = <String>[];
      history = SearchHistory.add(history, 'apple');
      history = SearchHistory.add(history, 'banana');
      expect(history, ['banana', 'apple']);
    });

    test('caps at 10 entries, dropping the oldest', () {
      var history = <String>[];
      for (var i = 1; i <= 11; i++) {
        history = SearchHistory.add(history, 'query$i');
      }
      expect(history.length, 10);
      // Newest first; the very first query ("query1") was evicted.
      expect(history.first, 'query11');
      expect(history.last, 'query2');
      expect(history.contains('query1'), isFalse);
    });

    test('case-insensitive dedup moves the entry to the front', () {
      var history = ['apple', 'banana'];
      history = SearchHistory.add(history, 'BANANA');
      // Old-cased duplicate removed; new casing inserted at front.
      expect(history, ['BANANA', 'apple']);
      expect(history.length, 2);
    });

    test('re-adding the current front keeps a single entry', () {
      var history = SearchHistory.add(<String>[], 'chameleon');
      history = SearchHistory.add(history, 'chameleon');
      expect(history, ['chameleon']);
    });

    test('blank or too-short queries are ignored', () {
      var history = ['keep'];
      history = SearchHistory.add(history, '');
      history = SearchHistory.add(history, '   ');
      history = SearchHistory.add(history, 'ab'); // < 3 chars
      expect(history, ['keep']);
    });

    test('queries are trimmed before storing', () {
      final history = SearchHistory.add(<String>[], '  frogs  ');
      expect(history, ['frogs']);
    });
  });

  group('SearchHistory.remove — per-item delete', () {
    test('removes the exact query only', () {
      final history = SearchHistory.remove(['a', 'b', 'c'], 'b');
      expect(history, ['a', 'c']);
    });

    test('removing a missing query is a no-op', () {
      final history = SearchHistory.remove(['a', 'b'], 'z');
      expect(history, ['a', 'b']);
    });

    test('does not mutate the input list', () {
      final input = ['a', 'b'];
      SearchHistory.remove(input, 'a');
      expect(input, ['a', 'b']);
    });
  });

  group('SearchHistory.decode / encode — persistence and clear-all', () {
    test('null and empty payloads yield an empty history (archive-queue state)',
        () {
      expect(SearchHistory.decode(null), isEmpty);
      expect(SearchHistory.decode(''), isEmpty);
    });

    test('a cleared history round-trips as empty', () {
      final encoded = SearchHistory.encode(<String>[]);
      expect(SearchHistory.decode(encoded), isEmpty);
    });

    test('encode/decode round-trips a populated history newest-first', () {
      final history = ['banana', 'apple'];
      expect(SearchHistory.decode(SearchHistory.encode(history)), history);
    });

    test('malformed JSON decodes to an empty history', () {
      expect(SearchHistory.decode('{not json'), isEmpty);
      expect(SearchHistory.decode('"a string"'), isEmpty);
    });

    test('decode caps at the max and drops blank entries', () {
      final raw = SearchHistory.encode([
        for (var i = 0; i < 15; i++) 'q$i',
        '',
        '  ',
      ]);
      final decoded = SearchHistory.decode(raw);
      expect(decoded.length, 10);
      expect(decoded.every((e) => e.trim().isNotEmpty), isTrue);
    });
  });

  group('searchEmptyState — recent-searches slot decision (§4.5)', () {
    test('non-empty history shows the Recent searches block', () {
      // Tapping the search bar should reveal recent searches before typing.
      // With history loaded and present, we pick recentSearches — the archive
      // queue then renders below it in the default view.
      expect(
        searchEmptyState(historyLoaded: true, hasHistory: true),
        SearchEmptyState.recentSearches,
      );
    });

    test('empty history: no recent-searches block, archive queue is first', () {
      expect(
        searchEmptyState(historyLoaded: true, hasHistory: false),
        SearchEmptyState.archiveQueue,
      );
    });

    test('history not yet loaded waits — no recent-searches flash', () {
      // Before the async prefs read resolves we must not commit to the
      // recent-searches block, otherwise it flickers in/out even when history
      // exists.
      expect(
        searchEmptyState(historyLoaded: false, hasHistory: false),
        SearchEmptyState.loadingHistory,
      );
      expect(
        searchEmptyState(historyLoaded: false, hasHistory: true),
        SearchEmptyState.loadingHistory,
      );
    });
  });

  group('partitionByAuthor — "Posted by me" grouping', () {
    List<Map<String, dynamic>> results() => [
          {'id': '1', 'author_id': 'me'},
          {'id': '2', 'author_id': 'other'},
          {'id': '3', 'author_id': 'me'},
          {'id': '4', 'author_id': null},
        ];

    test('splits mine (first) from all others, preserving order', () {
      final groups = partitionByAuthor(results(), 'me');
      expect(groups.mine.map((q) => q['id']), ['1', '3']);
      expect(groups.others.map((q) => q['id']), ['2', '4']);
      expect(groups.hasMine, isTrue);
      // Ordered list = mine + others, backing swipe navigation.
      expect(groups.ordered.map((q) => q['id']), ['1', '3', '2', '4']);
    });

    test('null current user (guest) yields no "mine"', () {
      final groups = partitionByAuthor(results(), null);
      expect(groups.mine, isEmpty);
      expect(groups.hasMine, isFalse);
      expect(groups.others.length, 4);
    });

    test('no authored questions yields no "mine"', () {
      final groups = partitionByAuthor(results(), 'nobody');
      expect(groups.mine, isEmpty);
      expect(groups.others.length, 4);
    });
  });
}
