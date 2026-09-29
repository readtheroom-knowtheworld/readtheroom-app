// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// What the results screens do with the `Network` token, at the level the
// screens themselves work: load a NetworkResults, turn it into a slice, resolve
// the current filter against it, and drop the selection when the slice goes.
//
// The screens delegate all four steps to `network_breakdown.dart`, so this
// exercises the same calls in the same order — including the Demo-friends path,
// which is how the feature is seen on a simulator with nothing deployed.

import 'package:flutter_test/flutter_test.dart';
import 'package:read_the_room/src/models/network_results.dart';
import 'package:read_the_room/src/models/question_results.dart';
import 'package:read_the_room/src/services/network_service.dart';
import 'package:read_the_room/src/utils/demo_friends_mode.dart';
import 'package:read_the_room/src/utils/network_breakdown.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A multiple-choice question with 40 answers worldwide.
QuestionResults _mcQuestion() => QuestionResults.fromJson(<String, dynamic>{
      'question_id': 'q-mc',
      'type': 'multiple_choice',
      'total': 40,
      'answered': 40,
      'options': <Map<String, dynamic>>[
        {'id': 'o1', 'text': 'Yes', 'sort_order': 0},
        {'id': 'o2', 'text': 'No', 'sort_order': 1},
      ],
      'overall': {
        'count': 40,
        'bins': <int>[0, 0, 0, 0, 0],
        'option_counts': <String, dynamic>{'Yes': 30, 'No': 10},
      },
      'by_country': <Map<String, dynamic>>[
        {
          'country': 'Testlandia',
          'country_code': 'Z1',
          'count': 40,
          'option_counts': <String, dynamic>{'Yes': 30, 'No': 10},
        },
      ],
    });

NetworkResults _ungatedMc() => NetworkResults.fromJson(<String, dynamic>{
      'success': true,
      'question_id': 'q-mc',
      'question_type': 'multiple_choice',
      'k': 3,
      'friend_count': 9,
      'gated': false,
      'respondents': 6,
      'hidden': 1,
      'options': <Map<String, dynamic>>[
        {'option_id': 'o2', 'label': 'No', 'option_index': 1, 'votes': 6},
      ],
      'graph': {'nodes': <Map<String, dynamic>>[]},
    });

/// The screens' own chain, in one place.
ResultsBreakdown _filteredBreakdown({
  required QuestionResults results,
  required String? filter,
  required NetworkResults? network,
  List<String> optionTexts = const <String>[],
  bool isPrivate = false,
}) =>
    resolveResultsFilter(
      results: results,
      filter: filter,
      network: networkBreakdownFrom(network, optionTexts: optionTexts),
      isPrivate: isPrivate,
    );

void main() {
  group('the screens\' filter chain', () {
    final results = _mcQuestion();
    const options = <String>['Yes', 'No'];

    test('Network selected: the slice is the network, floored count and all',
        () {
      final b = _filteredBreakdown(
        results: results,
        filter: kNetworkFilter,
        network: _ungatedMc(),
        optionTexts: options,
      );

      expect(b.count, 6);
      expect(b.optionCountsFor(options), <String, int>{'Yes': 0, 'No': 6});
      expect(b.topOption, 'No',
          reason: 'the network disagrees with the world, which is the point');
    });

    test('World is still the world while the network filter exists', () {
      final b = _filteredBreakdown(
        results: results,
        filter: null,
        network: _ungatedMc(),
        optionTexts: options,
      );
      expect(b.count, 40);
      expect(b.topOption, 'Yes');
    });

    test('the gate closes: the token falls back to World and is cleared', () {
      final gated = NetworkResults.fromJson(<String, dynamic>{
        'success': true,
        'question_id': 'q-mc',
        'question_type': 'multiple_choice',
        'k': 3,
        'friend_count': 9,
        'gated': true,
        'reason': 'not_enough_answers',
        'respondents': 0,
        'hidden': 0,
        'graph': null,
      });

      final slice = networkBreakdownFrom(gated, optionTexts: options);
      expect(slice, isNull);
      expect(clearedNetworkFilter(kNetworkFilter, slice), isNull);
      expect(
        _filteredBreakdown(
            results: results,
            filter: kNetworkFilter,
            network: gated,
            optionTexts: options).count,
        40,
        reason: 'never an empty chart labelled My Network',
      );
    });

    test('the RPC is not deployed: same silent fallback', () {
      final slice = networkBreakdownFrom(NetworkResults.unavailable('q-mc'),
          optionTexts: options);
      expect(slice, isNull);
      expect(clearedNetworkFilter(kNetworkFilter, slice), isNull);
    });

    test('a country selection is untouched by any of this', () {
      expect(
        _filteredBreakdown(
            results: results,
            filter: 'Testlandia',
            network: _ungatedMc(),
            optionTexts: options).count,
        40,
      );
      expect(clearedNetworkFilter('Testlandia', null), 'Testlandia');
    });
  });

  group('Demo friends mode', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues(
          <String, Object>{DemoFriendsMode.prefsKey: true});
      await DemoFriendsMode.instance.load();
    });

    tearDown(() async {
      await DemoFriendsMode.instance.setEnabled(false);
    });

    test('a multiple-choice question gets a real, ungated slice', () async {
      expect(DemoFriendsMode.instance.enabled, isTrue,
          reason: 'tests run in debug mode, where the flag is allowed');

      final results = await NetworkService()
          .getNetworkResults('q-demo-mc', questionType: 'multiple_choice');
      final slice = networkBreakdownFrom(results,
          optionTexts: const <String>['Yes', 'No', 'Depends']);

      expect(slice, isNotNull, reason: 'the owner must see this on a simulator');
      expect(slice!.count, results.respondents);
      expect(slice.count % results.k, 0);
      expect(slice.optionCounts.keys, containsAll(<String>['Yes', 'No', 'Depends']));
    });

    test('an approval question gets the buckets and the demo average',
        () async {
      final results = await NetworkService()
          .getNetworkResults('q-demo-approval', questionType: 'approval_rating');
      final slice = networkBreakdownFrom(results);

      expect(slice, isNotNull);
      expect(slice!.bins, hasLength(5));
      expect(slice.bins.reduce((a, b) => a + b), lessThanOrEqualTo(slice.count));
      expect(slice.average, results.average);
      expect(slice.scores, isEmpty);
    });
  });
}
