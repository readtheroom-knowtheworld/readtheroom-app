// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Unit tests for the answers-read-lockdown result models: the JSON contract of
// get_question_results / get_question_map_cells / get_question_text_answers /
// get_question_counts (scripts/responses_lockdown_01_results_rpcs.sql), and the
// pure maths the results screens now read instead of counting rows.
//
// The fixtures here are the shapes the RPCs actually emit — the same population
// as scripts/responses_lockdown_test.sql, so the two sides stay in step.

import 'package:flutter_test/flutter_test.dart';
import 'package:read_the_room/src/models/question_results.dart';

/// The approval fixture from responses_lockdown_test.sql: ten answers, six
/// gen_z at 100 in Testville, two boomers at -100 (suppressed, k = 5), one at 0
/// and one at 40.
Map<String, dynamic> _approvalJson() => <String, dynamic>{
      'question_id': 'q-approval',
      'type': 'approval_rating',
      'total': 10,
      'answered': 10,
      'text_count': 0,
      'comment_count': 3,
      'options': <dynamic>[],
      'overall': {
        'count': 10,
        'average': 0.44,
        'bins': [2, 0, 1, 1, 6],
        'scores': [-100, -100, 0, 40, 100, 100, 100, 100, 100, 100],
        'option_counts': <String, dynamic>{},
      },
      'by_country': <Map<String, dynamic>>[
        {
          'country': 'Testlandia',
          'country_code': 'Z1',
          'count': 9,
          'average': 0.4888,
          'bins': [2, 0, 0, 1, 6],
          'option_counts': <String, dynamic>{},
        },
        {
          'country': 'Fixtureland',
          'country_code': 'Z2',
          'count': 1,
          'average': 0.0,
          'bins': [0, 0, 1, 0, 0],
          'option_counts': <String, dynamic>{},
        },
      ],
      'by_city': [
        {
          'city': 'Testville',
          'country': 'Testlandia',
          'country_code': 'Z1',
          'count': 6,
          'average': 1.0,
          'bins': [0, 0, 0, 0, 6],
          'option_counts': <String, dynamic>{},
        },
      ],
      'by_generation': [
        {
          'generation': 'gen_z',
          'count': 6,
          'average': 1.0,
          'bins': [0, 0, 0, 0, 6],
          'option_counts': <String, dynamic>{},
        },
      ],
      'generation_suppressed_groups': 1,
      'generation_suppressed_count': 2,
    };

/// The multiple-choice fixture: Yes 5, No 4, Maybe 0.
Map<String, dynamic> _mcJson() => <String, dynamic>{
      'question_id': 'q-mc',
      'type': 'multiple_choice',
      'total': 9,
      'answered': 9,
      'text_count': 0,
      'comment_count': 0,
      'options': [
        {'id': 'o3', 'text': 'Maybe', 'sort_order': 2},
        {'id': 'o1', 'text': 'Yes', 'sort_order': 0},
        {'id': 'o2', 'text': 'No', 'sort_order': 1},
      ],
      'overall': {
        'count': 9,
        'average': null,
        'bins': [0, 0, 0, 0, 0],
        'scores': null,
        'option_counts': {'Yes': 5, 'No': 4, 'Maybe': 0},
      },
      'by_country': <Map<String, dynamic>>[
        {
          'country': 'Testlandia',
          'country_code': 'Z1',
          'count': 8,
          'average': null,
          'bins': [0, 0, 0, 0, 0],
          'option_counts': {'Yes': 5, 'No': 3, 'Maybe': 0},
        },
      ],
      'by_city': <dynamic>[],
      'by_generation': [
        {
          'generation': 'gen_z',
          'count': 5,
          'average': null,
          'bins': [0, 0, 0, 0, 0],
          'option_counts': {'Yes': 5, 'No': 0, 'Maybe': 0},
        },
      ],
      'generation_suppressed_groups': 1,
      'generation_suppressed_count': 3,
    };

void main() {
  group('QuestionResults.fromJson — approval', () {
    test('parses the whole-question facet', () {
      final r = QuestionResults.fromJson(_approvalJson());
      expect(r.questionId, 'q-approval');
      expect(r.type, 'approval_rating');
      expect(r.total, 10);
      expect(r.answered, 10);
      expect(r.commentCount, 3);
      expect(r.overall.count, 10);
      expect(r.overall.average, closeTo(0.44, 1e-9));
      expect(r.overall.bins, [2, 0, 1, 1, 6]);
    });

    test('binsByLabel flips the histogram into display order, approve first',
        () {
      final r = QuestionResults.fromJson(_approvalJson());
      expect(r.overall.binsByLabel, {
        'Strongly Approve': 6,
        'Approve': 1,
        'Neutral': 1,
        'Disapprove': 0,
        'Strongly Disapprove': 2,
      });
    });

    test('scoreValues normalise the sorted multiset to -1..1', () {
      final r = QuestionResults.fromJson(_approvalJson());
      expect(r.overall.scoreValues,
          [-1.0, -1.0, 0.0, 0.4, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0]);
      // Sorted, so it carries no ordering the viewer could time anything by.
      final sorted = [...r.overall.scoreValues]..sort();
      expect(r.overall.scoreValues, sorted);
    });

    test('country totals add up to the question total', () {
      final r = QuestionResults.fromJson(_approvalJson());
      final sum =
          r.byCountry.fold<int>(0, (a, c) => a + c.breakdown.count);
      expect(sum, r.total);
    });

    test('a suppressed generation group is absent, and counted', () {
      final r = QuestionResults.fromJson(_approvalJson());
      expect(r.byGeneration.map((g) => g.generation), ['gen_z']);
      expect(r.forGeneration('boomer'), isNull);
      expect(r.generationSuppressedGroups, 1);
      expect(r.generationSuppressedCount, 2);
    });

    test('the Unknown country bucket is kept in the totals but not offered '
        'as a filter', () {
      final json = _approvalJson();
      (json['by_country'] as List<Map<String, dynamic>>).add(<String, dynamic>{
        'country': 'Unknown',
        'country_code': null,
        'count': 4,
        'average': 0.1,
        'bins': [0, 0, 4, 0, 0],
        'option_counts': <String, dynamic>{},
      });
      final r = QuestionResults.fromJson(json);
      expect(r.forCountry('Unknown')!.count, 4);
      expect(r.countriesWithResponses, isNot(contains('Unknown')));
      expect(r.countryResponseData.keys, isNot(contains('Unknown')));
    });
  });

  group('QuestionResults.fromJson — multiple choice', () {
    test('options come back in sort order, not JSON order', () {
      final r = QuestionResults.fromJson(_mcJson());
      expect(r.optionTexts, ['Yes', 'No', 'Maybe']);
    });

    test('an unvoted option keeps its zero row', () {
      final r = QuestionResults.fromJson(_mcJson());
      expect(r.overall.optionCounts['Maybe'], 0);
      expect(r.overall.optionCountsFor(['Yes', 'No', 'Maybe']),
          {'Yes': 5, 'No': 4, 'Maybe': 0});
    });

    test('optionCountsFor keeps the caller order and fills gaps', () {
      final r = QuestionResults.fromJson(_mcJson());
      expect(r.overall.optionCountsFor(['No', 'Yes', 'Nonexistent']).keys,
          ['No', 'Yes', 'Nonexistent']);
      expect(r.overall.optionCountsFor(['Nonexistent'])['Nonexistent'], 0);
    });

    test('topOption picks the leader and reports a genuine tie', () {
      final r = QuestionResults.fromJson(_mcJson());
      expect(r.overall.topOption, 'Yes');
      expect(r.forCountry('Testlandia')!.topOption, 'Yes');

      const tied = ResultsBreakdown(
        count: 4,
        average: null,
        bins: [0, 0, 0, 0, 0],
        optionCounts: {'Yes': 2, 'No': 2},
      );
      expect(tied.topOption, 'TIE');
    });

    test('an all-zero option map is a TIE, not a crash', () {
      const none = ResultsBreakdown(
        count: 0,
        average: null,
        bins: [0, 0, 0, 0, 0],
        optionCounts: {'Yes': 0, 'No': 0},
      );
      expect(none.topOption, 'TIE');
    });

    test('a scoreless question has a null average and an empty beeswarm', () {
      final r = QuestionResults.fromJson(_mcJson());
      expect(r.overall.average, isNull);
      expect(r.overall.averageOrZero, 0.0);
      expect(r.overall.scores, isEmpty);
      expect(r.overall.scoreValues, isEmpty);
    });

    test('generationMostPopular reports the leader per surviving group', () {
      final r = QuestionResults.fromJson(_mcJson());
      expect(r.generationMostPopular, {'gen_z': 'Yes'});
    });
  });

  group('breakdownForFilter — the screens\' one filter token', () {
    test('null is everybody', () {
      final r = QuestionResults.fromJson(_approvalJson());
      expect(r.breakdownForFilter(null).count, 10);
      expect(r.breakdownForFilter('').count, 10);
    });

    test('a country, a city and a generation each resolve to their slice', () {
      final r = QuestionResults.fromJson(_approvalJson());
      expect(r.breakdownForFilter('Testlandia').count, 9);
      expect(r.breakdownForFilter('City:Testville').count, 6);
      expect(r.breakdownForFilter('Gen:gen_z').count, 6);
    });

    test('a filter for a suppressed or unknown group shows NOTHING, never '
        'everybody', () {
      final r = QuestionResults.fromJson(_approvalJson());
      expect(r.breakdownForFilter('Gen:boomer').count, 0);
      expect(r.breakdownForFilter('City:Atlantis').count, 0);
      expect(r.breakdownForFilter('Nowhereland').count, 0);
    });
  });

  group('QuestionResults — degenerate input', () {
    test('an empty object parses to an empty result rather than throwing', () {
      final r = QuestionResults.fromJson(const <String, dynamic>{});
      expect(r.total, 0);
      expect(r.isEmpty, isTrue);
      expect(r.overall.count, 0);
      expect(r.overall.bins, [0, 0, 0, 0, 0]);
      expect(r.byCountry, isEmpty);
      expect(r.optionTexts, isEmpty);
    });

    test('a short or long bins array is padded and clipped to five', () {
      final b = ResultsBreakdown.fromJson(const {
        'count': 3,
        'bins': [1, 2],
      });
      expect(b.bins, [1, 2, 0, 0, 0]);

      final c = ResultsBreakdown.fromJson(const {
        'count': 3,
        'bins': [1, 2, 3, 4, 5, 6, 7],
      });
      expect(c.bins, [1, 2, 3, 4, 5]);
    });

    test('numbers arriving as strings are still read', () {
      final b = ResultsBreakdown.fromJson(const {
        'count': '7',
        'average': '-0.25',
        'bins': ['1', 2, '3', 0, 1],
      });
      expect(b.count, 7);
      expect(b.average, -0.25);
      expect(b.bins, [1, 2, 3, 0, 1]);
    });

    test('emptyFor keeps the identity so a screen can render its empty state',
        () {
      final r = QuestionResults.emptyFor('q1', 'approval_rating');
      expect(r.questionId, 'q1');
      expect(r.type, 'approval_rating');
      expect(r.breakdownForFilter('Anything').count, 0);
    });
  });

  group('QuestionMapCells.fromJson', () {
    Map<String, dynamic> cellsJson() => <String, dynamic>{
          'question_id': 'q-approval',
          'type': 'approval_rating',
          'options': <dynamic>[],
          'total': 10,
          'cells': <Map<String, dynamic>>[
            {
              'kind': 'city',
              'city_id': 'c1',
              'city': 'Testville',
              'admin1': 'T1',
              'lat': 10.0,
              'lng': 20.0,
              'country_code': 'Z1',
              'country_iso3': 'TST',
              'country': 'Testlandia',
              'count': 6,
              'average': 1.0,
              'bins': [0, 0, 0, 0, 6],
              'option_counts': <String, dynamic>{},
            },
            {
              'kind': 'city',
              'city_id': 'c3',
              'city': 'Solotown',
              'admin1': 'F1',
              'lat': -5.0,
              'lng': 30.0,
              'country_code': 'Z2',
              'country_iso3': 'FIX',
              'country': 'Fixtureland',
              'count': 1,
              'average': 0.0,
              'bins': [0, 0, 1, 0, 0],
              'option_counts': <String, dynamic>{},
            },
            {
              'kind': 'country',
              'city_id': null,
              'city': null,
              'admin1': null,
              'lat': null,
              'lng': null,
              'country_code': 'Z1',
              'country_iso3': 'TST',
              'country': 'Testlandia',
              'count': 3,
              'average': 0.4,
              'bins': [0, 0, 0, 3, 0],
              'option_counts': <String, dynamic>{},
            },
          ],
        };

    test('parses city and country cells and tells them apart', () {
      final m = QuestionMapCells.fromJson(cellsJson());
      expect(m.cells.length, 3);
      expect(m.total, 10);
      expect(m.cells[0].isCity, isTrue);
      expect(m.cells[0].city, 'Testville');
      expect(m.cells[0].count, 6);
      expect(m.cells[2].isCity, isFalse);
      expect(m.cells[2].lat, isNull);
      expect(m.cells[2].city, isNull);
    });

    test('a one-answer city still gets its cell — no k on the map', () {
      final m = QuestionMapCells.fromJson(cellsJson());
      final solo = m.cells.firstWhere((c) => c.city == 'Solotown');
      expect(solo.count, 1);
      expect(solo.lat, -5.0);
    });

    test('a cell with coordinates missing is not treated as a city', () {
      final json = cellsJson();
      (json['cells'] as List<Map<String, dynamic>>)[0]['lat'] = null;
      final m = QuestionMapCells.fromJson(json);
      expect(m.cells[0].isCity, isFalse);
    });

    test('an MC cell reports the option it is coloured by', () {
      final cell = MapCell.fromJson(const {
        'kind': 'city',
        'city': 'Testville',
        'lat': 1.0,
        'lng': 2.0,
        'country': 'Testlandia',
        'count': 8,
        'bins': [0, 0, 0, 0, 0],
        'option_counts': {'Yes': 5, 'No': 3},
      });
      expect(cell.topOption, 'Yes');
      expect(cell.count, 8);
    });

    test('an empty payload yields no cells', () {
      final m = QuestionMapCells.fromJson(const <String, dynamic>{});
      expect(m.cells, isEmpty);
      expect(m.total, 0);
    });
  });

  group('TextAnswerPage.fromJson', () {
    test('parses answers and keeps the hour, never a finer time', () {
      final page = TextAnswerPage.fromJson(const {
        'question_id': 'q-text',
        'total': 3,
        'answers': [
          {
            'id': 'r1',
            'text': 'newest answer',
            'country': 'Testlandia',
            'country_code': 'Z1',
            'answered_hour': '2026-09-22T14:00:00+00:00',
          },
        ],
        'next_before': '2026-09-22T14:00:00+00:00',
        'has_more': true,
      });

      expect(page.total, 3);
      expect(page.answers.single.text, 'newest answer');
      expect(page.answers.single.country, 'Testlandia');
      expect(page.hasMore, isTrue);
      expect(page.nextBefore, isNotNull);

      final hour = page.answers.single.answeredHour!;
      expect(hour.minute, 0);
      expect(hour.second, 0);
    });

    test('toRows gives the legacy shape, with the hour under created_at', () {
      final page = TextAnswerPage.fromJson(const {
        'total': 1,
        'answers': [
          {
            'id': 'r1',
            'text': 'hello',
            'country': 'Testlandia',
            'answered_hour': '2026-09-22T14:00:00Z',
          },
        ],
      });
      final row = page.toRows().single;
      expect(row['text_response'], 'hello');
      expect(row['country'], 'Testlandia');
      expect(row['id'], 'r1');
      expect(row.containsKey('generation'), isFalse);
      expect(DateTime.parse(row['created_at'] as String).minute, 0);
    });

    test('a missing country reads as Unknown, and no answers is not an error',
        () {
      final page = TextAnswerPage.fromJson(const {
        'answers': [
          {'id': 'r1', 'text': 'x'},
        ],
      });
      expect(page.answers.single.country, 'Unknown');
      expect(page.answers.single.answeredHour, isNull);

      final empty = TextAnswerPage.fromJson(const <String, dynamic>{});
      expect(empty.answers, isEmpty);
      expect(empty.hasMore, isFalse);
      expect(empty.nextBefore, isNull);
    });
  });

  group('QuestionCounts.fromJson', () {
    test('reads the four counts', () {
      final c = QuestionCounts.fromJson(const {
        'total': 10,
        'answered': 9,
        'text': 3,
        'last_24h': 2,
      });
      expect(c.total, 10);
      expect(c.answered, 9);
      expect(c.text, 3);
      expect(c.last24h, 2);
    });

    test('an absent field is zero, not null', () {
      final c = QuestionCounts.fromJson(const <String, dynamic>{});
      expect(c.total, 0);
      expect(c.answered, 0);
      expect(QuestionCounts.zero.total, 0);
    });
  });
}
