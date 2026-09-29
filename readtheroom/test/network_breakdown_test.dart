// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The "My Network" adapter: the server's network envelope seen as a results
// slice, and the filter token that selects it.
//
// The gated and unavailable cases matter most. Both must produce NO slice at
// all rather than a zeroed one, because a zeroed slice would draw an empty
// chart labelled "My Network" — a statement about the viewer's friends that
// the gate exists to avoid making.

import 'package:flutter_test/flutter_test.dart';
import 'package:read_the_room/src/models/network_results.dart';
import 'package:read_the_room/src/models/question_results.dart';
import 'package:read_the_room/src/utils/network_breakdown.dart';

NetworkResults _mc({
  List<Map<String, dynamic>>? options,
  int respondents = 9,
  int hidden = 2,
}) =>
    NetworkResults.fromJson(<String, dynamic>{
      'success': true,
      'question_id': 'q1',
      'question_type': 'multiple_choice',
      'k': 3,
      'friend_count': 12,
      'gated': false,
      'respondents': respondents,
      'hidden': hidden,
      'options': options ??
          <Map<String, dynamic>>[
            {'option_id': 'o2', 'label': 'No', 'option_index': 1, 'votes': 6},
            {'option_id': 'o1', 'label': 'Yes', 'option_index': 0, 'votes': 3},
          ],
      'graph': {'nodes': <Map<String, dynamic>>[]},
    });

NetworkResults _approval({List<int>? buckets, double? average}) =>
    NetworkResults.fromJson(<String, dynamic>{
      'success': true,
      'question_id': 'q1',
      'question_type': 'approval_rating',
      'k': 3,
      'friend_count': 12,
      'gated': false,
      'respondents': 9,
      'hidden': 0,
      'buckets': buckets ?? <int>[0, 3, 3, 0, 3],
      'average': average ?? -0.18,
      'graph': {'nodes': <Map<String, dynamic>>[]},
    });

NetworkResults _gated(String reason) =>
    NetworkResults.fromJson(<String, dynamic>{
      'success': true,
      'question_id': 'q1',
      'question_type': 'multiple_choice',
      'k': 3,
      'friend_count': 2,
      'gated': true,
      'reason': reason,
      'respondents': 0,
      'hidden': 0,
      'graph': null,
    });

QuestionResults _question() => QuestionResults.fromJson(<String, dynamic>{
      'question_id': 'q1',
      'type': 'multiple_choice',
      'total': 40,
      'answered': 40,
      'options': <Map<String, dynamic>>[
        {'id': 'o1', 'text': 'Yes', 'sort_order': 0},
        {'id': 'o2', 'text': 'No', 'sort_order': 1},
        {'id': 'o3', 'text': 'Depends', 'sort_order': 2},
      ],
      'overall': {
        'count': 40,
        'average': null,
        'bins': <int>[0, 0, 0, 0, 0],
        'option_counts': <String, dynamic>{'Yes': 20, 'No': 15, 'Depends': 5},
      },
      'by_country': <Map<String, dynamic>>[
        {
          'country': 'Testlandia',
          'country_code': 'Z1',
          'count': 25,
          'option_counts': <String, dynamic>{'Yes': 20, 'No': 5},
        },
      ],
    });

void main() {
  group('networkBreakdownFrom — multiple choice', () {
    test('votes land on the question options, in the question order', () {
      final b = networkBreakdownFrom(_mc(),
          optionTexts: const ['Yes', 'No', 'Depends']);

      expect(b, isNotNull);
      expect(b!.count, 9, reason: 'the floored respondent count, verbatim');
      expect(b.optionCounts, <String, int>{'Yes': 3, 'No': 6, 'Depends': 0});
      expect(b.optionCountsFor(const ['Yes', 'No', 'Depends']).keys.toList(),
          <String>['Yes', 'No', 'Depends']);
      expect(b.topOption, 'No');
      expect(b.scores, isEmpty, reason: 'never per-person');
    });

    test('an option the server omitted is a zero, not a missing key', () {
      final b = networkBreakdownFrom(
        _mc(options: <Map<String, dynamic>>[
          {'option_id': 'o1', 'label': 'Yes', 'option_index': 0, 'votes': 9},
        ]),
        optionTexts: const ['Yes', 'No', 'Depends'],
      );

      expect(b!.optionCounts['No'], 0);
      expect(b.optionCounts['Depends'], 0);
    });

    test('a relabelled option is matched by its index', () {
      final b = networkBreakdownFrom(
        _mc(options: <Map<String, dynamic>>[
          {'option_id': 'o2', 'label': 'Nope', 'option_index': 1, 'votes': 6},
        ]),
        optionTexts: const ['Yes', 'No', 'Depends'],
      );

      expect(b!.optionCounts['No'], 6);
      expect(b.optionCounts.containsKey('Nope'), isFalse);
    });

    test('no option texts: the labels are the keys', () {
      final b = networkBreakdownFrom(_mc());
      expect(b!.optionCounts, <String, int>{'No': 6, 'Yes': 3});
    });
  });

  group('networkBreakdownFrom — approval', () {
    test('the five buckets and the SERVER average, untouched', () {
      final b = networkBreakdownFrom(_approval());

      expect(b!.count, 9);
      expect(b.bins, <int>[0, 3, 3, 0, 3]);
      expect(b.average, -0.18, reason: 'never re-derived from the buckets');
      expect(b.binsByLabel['Strongly Approve'], 3);
      expect(b.binsByLabel['Strongly Disapprove'], 0);
      expect(b.scores, isEmpty);
    });

    test('a short bucket list is padded, never overflowed', () {
      final b = networkBreakdownFrom(_approval(buckets: <int>[3, 3]));
      expect(b!.bins, <int>[3, 3, 0, 0, 0]);
    });
  });

  group('networkBreakdownFrom — nothing to show', () {
    test('gated on friends → null', () {
      expect(networkBreakdownFrom(_gated('not_enough_friends')), isNull);
    });

    test('gated on answers → null', () {
      expect(networkBreakdownFrom(_gated('not_enough_answers')), isNull);
    });

    test('unavailable → null', () {
      expect(networkBreakdownFrom(NetworkResults.unavailable('q1')), isNull);
    });

    test('not loaded yet → null', () {
      expect(networkBreakdownFrom(null), isNull);
    });
  });

  test('networkCountLabel adds the + only when a remainder is withheld', () {
    expect(networkCountLabel(9, 2), '9+');
    expect(networkCountLabel(9, 0), '9');
  });

  group('resolveResultsFilter', () {
    final results = _question();
    final network =
        networkBreakdownFrom(_mc(), optionTexts: const ['Yes', 'No', 'Depends']);

    test('the Network token resolves to the network slice', () {
      final b = resolveResultsFilter(
          results: results, filter: kNetworkFilter, network: network);
      expect(b.count, 9);
      expect(b.optionCounts['No'], 6);
    });

    test('no network → the Network token falls back to World', () {
      final b = resolveResultsFilter(
          results: results, filter: kNetworkFilter, network: null);
      expect(b.count, 40);
    });

    test('country, World and null tokens are unchanged', () {
      expect(
          resolveResultsFilter(
                  results: results, filter: 'Testlandia', network: network)
              .count,
          25);
      expect(
          resolveResultsFilter(
                  results: results, filter: 'World', network: network)
              .count,
          40);
      expect(
          resolveResultsFilter(results: results, filter: null, network: network)
              .count,
          40);
    });

    test('a private question is never filtered, network included', () {
      final b = resolveResultsFilter(
          results: results,
          filter: kNetworkFilter,
          network: network,
          isPrivate: true);
      expect(b.count, 40);
    });

    test('clearedNetworkFilter drops only an unbacked Network token', () {
      expect(clearedNetworkFilter(kNetworkFilter, null), isNull);
      expect(clearedNetworkFilter(kNetworkFilter, network), kNetworkFilter);
      expect(clearedNetworkFilter('Testlandia', null), 'Testlandia');
      expect(clearedNetworkFilter(null, network), isNull);
    });

    test('isNetworkFilter recognises the token and nothing else', () {
      expect(isNetworkFilter(kNetworkFilter), isTrue);
      expect(isNetworkFilter('My Network'), isFalse);
      expect(isNetworkFilter(null), isFalse);
    });
  });
}
