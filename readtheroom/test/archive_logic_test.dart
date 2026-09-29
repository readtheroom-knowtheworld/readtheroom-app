// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Unit tests for the Archive default-view partition helpers (QOTD-first Phase 3
// "Archive"). Extracted into lib/src/utils/archive_logic.dart so the queue /
// your-answers rules can be tested without pumping SearchScreen (which needs
// Supabase + the full provider tree).

import 'package:flutter_test/flutter_test.dart';
import 'package:read_the_room/src/utils/archive_logic.dart';

void main() {
  group('archiveQueueExcludingAnswered — answered subtraction, order preserved', () {
    List<Map<String, dynamic>> candidates() => [
          {'id': '1', 'votes': 30},
          {'id': '2', 'votes': 20},
          {'id': '3', 'votes': 10},
          {'id': '4', 'votes': 5},
        ];

    test('excludes answered ids from the queue', () {
      final queue = archiveQueueExcludingAnswered(candidates(), {'2', '4'});
      expect(queue.map((q) => q['id']), ['1', '3']);
    });

    test('preserves input (most-answered-first) order', () {
      final queue = archiveQueueExcludingAnswered(candidates(), {});
      expect(queue.map((q) => q['id']), ['1', '2', '3', '4']);
    });

    test('drops candidates without an id', () {
      final queue = archiveQueueExcludingAnswered(
        [
          {'id': '1'},
          {'votes': 99}, // no id
          {'id': ''}, // blank id
          {'id': '2'},
        ],
        {},
      );
      expect(queue.map((q) => q['id']), ['1', '2']);
    });

    test('empty answered set keeps everything', () {
      final queue = archiveQueueExcludingAnswered(candidates(), {});
      expect(queue.length, 4);
    });
  });

  group('yourAnswersMostVotesFirst — votes desc, guest stubs excluded', () {
    test('sorts by vote count, most-answered first', () {
      final answered = [
        {'id': 'a', 'prompt': 'Fewest?', 'votes': 5},
        {'id': 'b', 'prompt': 'Most?', 'votes': 40},
        {'id': 'c', 'prompt': 'Middle?', 'votes': 20},
      ];
      final result = yourAnswersMostVotesFirst(answered);
      expect(result.map((q) => q['id']), ['b', 'c', 'a']);
    });

    test('breaks vote ties by newest-answered (timestamp desc)', () {
      final answered = [
        {'id': 'a', 'prompt': 'Older tie', 'votes': 10, 'timestamp': '2026-01-01T00:00:00Z'},
        {'id': 'b', 'prompt': 'Newer tie', 'votes': 10, 'timestamp': '2026-03-01T00:00:00Z'},
      ];
      final result = yourAnswersMostVotesFirst(answered);
      expect(result.map((q) => q['id']), ['b', 'a']);
    });

    test('treats missing/malformed votes as 0 (sorts last), not crashing', () {
      final answered = [
        {'id': 'a', 'prompt': 'No votes field'},
        {'id': 'b', 'prompt': 'Has votes', 'votes': 3},
        {'id': 'c', 'prompt': 'String votes', 'votes': '7'},
      ];
      final result = yourAnswersMostVotesFirst(answered);
      expect(result.map((q) => q['id']), ['c', 'b', 'a']);
    });

    test('excludes guest-migration stubs lacking a prompt', () {
      final answered = [
        {'id': 'a', 'prompt': 'Real question', 'votes': 1},
        {'id': 'b', 'votes': 99}, // no prompt → stub
        {'id': 'c', 'prompt': '', 'votes': 99}, // blank prompt → stub
        {'id': 'd', 'prompt': '   ', 'votes': 99}, // whitespace → stub
      ];
      final result = yourAnswersMostVotesFirst(answered);
      expect(result.map((q) => q['id']), ['a']);
    });

    test('empty input yields empty list', () {
      expect(yourAnswersMostVotesFirst([]), isEmpty);
    });
  });

  group('mergeAnsweredWithFreshCounts — fresh counts overlay stored votes', () {
    test('overrides votes with the fresh count when present', () {
      final answered = [
        {'id': 'a', 'prompt': 'A', 'votes': 5},
        {'id': 'b', 'prompt': 'B', 'votes': 10},
      ];
      final merged = mergeAnsweredWithFreshCounts(answered, {'a': 50, 'b': 2});
      expect(merged.map((q) => q['votes']), [50, 2]);
    });

    test('falls back to stored votes when the id has no fresh count', () {
      final answered = [
        {'id': 'a', 'prompt': 'A', 'votes': 5},
        {'id': 'b', 'prompt': 'B', 'votes': 10},
      ];
      final merged = mergeAnsweredWithFreshCounts(answered, {'a': 50});
      expect(merged.map((q) => q['votes']), [50, 10]);
    });

    test('empty fresh map leaves every stored value intact (fetch-fail path)', () {
      final answered = [
        {'id': 'a', 'prompt': 'A', 'votes': 5},
        {'id': 'b', 'prompt': 'B', 'votes': 10},
      ];
      final merged = mergeAnsweredWithFreshCounts(answered, {});
      expect(merged.map((q) => q['votes']), [5, 10]);
    });

    test('does not mutate the input records', () {
      final original = {'id': 'a', 'prompt': 'A', 'votes': 5};
      final merged = mergeAnsweredWithFreshCounts([original], {'a': 99});
      expect(original['votes'], 5); // untouched
      expect(merged.first['votes'], 99);
    });

    test('feeds votes-desc ordering — fresh counts re-rank answers', () {
      final answered = [
        {'id': 'a', 'prompt': 'Was low', 'votes': 1},
        {'id': 'b', 'prompt': 'Was high', 'votes': 100},
      ];
      // Fresh counts flip the ranking: a is now the most-answered.
      final merged = mergeAnsweredWithFreshCounts(answered, {'a': 200, 'b': 3});
      final ordered = yourAnswersMostVotesFirst(merged);
      expect(ordered.map((q) => q['id']), ['a', 'b']);
    });
  });

  group('yourAnswersNewestFirst — answered-at desc, guest stubs excluded', () {
    test('sorts by answer timestamp, newest first', () {
      final answered = [
        {'id': 'a', 'prompt': 'Middle', 'timestamp': '2026-02-01T00:00:00Z'},
        {'id': 'b', 'prompt': 'Oldest', 'timestamp': '2026-01-01T00:00:00Z'},
        {'id': 'c', 'prompt': 'Newest', 'timestamp': '2026-03-01T00:00:00Z'},
      ];
      expect(yourAnswersNewestFirst(answered).map((q) => q['id']), ['c', 'a', 'b']);
    });

    test('ignores vote count — a low-vote recent answer still leads', () {
      final answered = [
        {'id': 'a', 'prompt': 'Popular but old', 'votes': 900, 'timestamp': '2026-01-01T00:00:00Z'},
        {'id': 'b', 'prompt': 'Quiet but recent', 'votes': 1, 'timestamp': '2026-05-01T00:00:00Z'},
      ];
      expect(yourAnswersNewestFirst(answered).map((q) => q['id']), ['b', 'a']);
    });

    test('falls back to the question created_at when no answer timestamp', () {
      final answered = [
        {'id': 'a', 'prompt': 'Created later', 'created_at': '2026-04-01T00:00:00Z'},
        {'id': 'b', 'prompt': 'Answered later', 'timestamp': '2026-06-01T00:00:00Z'},
      ];
      expect(yourAnswersNewestFirst(answered).map((q) => q['id']), ['b', 'a']);
    });

    test('undated records sort last instead of crashing', () {
      final answered = [
        {'id': 'a', 'prompt': 'No dates at all'},
        {'id': 'b', 'prompt': 'Dated', 'timestamp': '2026-01-01T00:00:00Z'},
        {'id': 'c', 'prompt': 'Junk date', 'timestamp': 'not-a-date'},
      ];
      final result = yourAnswersNewestFirst(answered);
      expect(result.first['id'], 'b');
      expect(result.length, 3);
    });

    test('breaks timestamp ties by votes desc', () {
      final answered = [
        {'id': 'a', 'prompt': 'Tie, fewer', 'votes': 2, 'timestamp': '2026-01-01T00:00:00Z'},
        {'id': 'b', 'prompt': 'Tie, more', 'votes': 20, 'timestamp': '2026-01-01T00:00:00Z'},
      ];
      expect(yourAnswersNewestFirst(answered).map((q) => q['id']), ['b', 'a']);
    });

    test('excludes guest-migration stubs lacking a prompt', () {
      final answered = [
        {'id': 'a', 'prompt': 'Real', 'timestamp': '2026-01-01T00:00:00Z'},
        {'id': 'b', 'timestamp': '2026-09-01T00:00:00Z'}, // stub
        {'id': 'c', 'prompt': '  ', 'timestamp': '2026-09-02T00:00:00Z'}, // stub
      ];
      expect(yourAnswersNewestFirst(answered).map((q) => q['id']), ['a']);
    });

    test('empty input yields empty list', () {
      expect(yourAnswersNewestFirst([]), isEmpty);
    });
  });

  group('sortYourAnswers — dispatches on the section sort', () {
    final answered = [
      {'id': 'old_popular', 'prompt': 'A', 'votes': 99, 'timestamp': '2026-01-01T00:00:00Z'},
      {'id': 'new_quiet', 'prompt': 'B', 'votes': 1, 'timestamp': '2026-08-01T00:00:00Z'},
    ];

    test('popular → votes desc', () {
      expect(
        sortYourAnswers(answered, ArchiveSort.popular).map((q) => q['id']),
        ['old_popular', 'new_quiet'],
      );
    });

    test('newest → answered-at desc', () {
      expect(
        sortYourAnswers(answered, ArchiveSort.newest).map((q) => q['id']),
        ['new_quiet', 'old_popular'],
      );
    });
  });

  group('ArchiveSort — wire names, flip, parsing', () {
    test('wire names are the persisted / analytics strings', () {
      expect(ArchiveSort.popular.wireName, 'popular');
      expect(ArchiveSort.newest.wireName, 'new');
    });

    test('flipped swaps the two sorts', () {
      expect(ArchiveSort.popular.flipped, ArchiveSort.newest);
      expect(ArchiveSort.newest.flipped, ArchiveSort.popular);
      expect(ArchiveSort.popular.flipped.flipped, ArchiveSort.popular);
    });

    test('fromWireName round-trips both values', () {
      for (final sort in ArchiveSort.values) {
        expect(
          ArchiveSort.fromWireName(sort.wireName, fallback: sort.flipped),
          sort,
        );
      }
    });

    test('fromWireName falls back for null / unknown stored values', () {
      expect(
        ArchiveSort.fromWireName(null, fallback: ArchiveSort.popular),
        ArchiveSort.popular,
      );
      expect(
        ArchiveSort.fromWireName('trending', fallback: ArchiveSort.newest),
        ArchiveSort.newest,
      );
    });

    test('section defaults: Unanswered popular, Your answers new', () {
      expect(defaultArchiveSort(kArchiveUnansweredSection), ArchiveSort.popular);
      expect(defaultArchiveSort(kArchiveAnsweredSection), ArchiveSort.newest);
    });
  });

  group('archiveToggleTap — first tap selects, second tap flips the sort', () {
    test('tapping the other chip switches section and keeps its sort', () {
      final outcome = archiveToggleTap(
        currentView: kArchiveUnansweredSection,
        tappedView: kArchiveAnsweredSection,
        tappedSectionSort: ArchiveSort.newest,
      );
      expect(outcome.view, kArchiveAnsweredSection);
      expect(outcome.viewChanged, isTrue);
      expect(outcome.sortFlipped, isFalse);
      expect(outcome.sort, ArchiveSort.newest); // untouched
    });

    test('tapping the already-selected chip flips that section\'s sort', () {
      final outcome = archiveToggleTap(
        currentView: kArchiveUnansweredSection,
        tappedView: kArchiveUnansweredSection,
        tappedSectionSort: ArchiveSort.popular,
      );
      expect(outcome.view, kArchiveUnansweredSection);
      expect(outcome.viewChanged, isFalse);
      expect(outcome.sortFlipped, isTrue);
      expect(outcome.sort, ArchiveSort.newest);
    });

    test('a third tap flips back — the two taps are a round trip', () {
      final first = archiveToggleTap(
        currentView: kArchiveAnsweredSection,
        tappedView: kArchiveAnsweredSection,
        tappedSectionSort: ArchiveSort.newest,
      );
      final second = archiveToggleTap(
        currentView: kArchiveAnsweredSection,
        tappedView: kArchiveAnsweredSection,
        tappedSectionSort: first.sort,
      );
      expect(first.sort, ArchiveSort.popular);
      expect(second.sort, ArchiveSort.newest);
    });

    test('the two outcomes are mutually exclusive', () {
      for (final current in [kArchiveUnansweredSection, kArchiveAnsweredSection]) {
        for (final tapped in [kArchiveUnansweredSection, kArchiveAnsweredSection]) {
          final outcome = archiveToggleTap(
            currentView: current,
            tappedView: tapped,
            tappedSectionSort: ArchiveSort.popular,
          );
          expect(outcome.viewChanged && outcome.sortFlipped, isFalse);
          expect(outcome.viewChanged || outcome.sortFlipped, isTrue);
        }
      }
    });
  });

  group('section header / chip labels track the active sort', () {
    test('unanswered header spells out both orders', () {
      expect(
        archiveSectionHeader(kArchiveUnansweredSection, ArchiveSort.popular),
        'Unanswered — most answered first',
      );
      expect(
        archiveSectionHeader(kArchiveUnansweredSection, ArchiveSort.newest),
        'Unanswered — newest first',
      );
    });

    test('answered header reads "Your answers"', () {
      expect(
        archiveSectionHeader(kArchiveAnsweredSection, ArchiveSort.newest),
        'Your answers — newest first',
      );
      expect(
        archiveSectionHeader(kArchiveAnsweredSection, ArchiveSort.popular),
        'Your answers — most answered first',
      );
    });

    test('chip label is the short sort name', () {
      expect(archiveSortChipLabel(ArchiveSort.popular), 'Popular');
      expect(archiveSortChipLabel(ArchiveSort.newest), 'New');
    });
  });
}
