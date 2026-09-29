// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// "My Network" in the two results dialogs.
//
// The row is conditional on one thing only — a non-null network slice — and
// that condition is the whole privacy story: a viewer under the gate must see
// the dialog exactly as it was before this feature existed, with no row, no
// greyed-out row and no explanation of why there is nothing.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:read_the_room/src/models/question_results.dart';
import 'package:read_the_room/src/utils/network_breakdown.dart';
import 'package:read_the_room/src/widgets/country_comparison_dialog.dart';
import 'package:read_the_room/src/widgets/country_filter_dialog.dart';

const ResultsBreakdown _network = ResultsBreakdown(
  count: 9,
  average: 0.3,
  bins: <int>[0, 0, 3, 3, 3],
  optionCounts: <String, int>{'Yes': 3, 'No': 6},
);

final Map<String, Map<String, dynamic>> _countries =
    <String, Map<String, dynamic>>{
  'Testlandia': <String, dynamic>{'total': 25},
  'Otherland': <String, dynamic>{'total': 15},
};

Widget _host(Widget Function(BuildContext) open) => MaterialApp(
      theme: ThemeData(primaryColor: const Color(0xFF00897B)),
      home: Scaffold(body: Builder(builder: (c) => open(c))),
    );

/// Pumps a button that opens [show] and records what the dialog returned.
Widget _opener(Future<Object?> Function(BuildContext) show, List<Object?> out) =>
    _host((context) => TextButton(
          onPressed: () async => out.add(await show(context)),
          child: const Text('open'),
        ));

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  group('CountryFilterDialog', () {
    testWidgets('no network slice: no row at all', (tester) async {
      await tester.pumpWidget(_opener(
        (context) => CountryFilterDialog.show(
          context: context,
          countryResponses: _countries,
          currentSelectedCountry: null,
          questionTitle: 'Do lizards dream?',
          questionId: 'q1',
          questionType: 'approval',
        ),
        <Object?>[],
      ));
      await _open(tester);

      expect(find.text(kNetworkFilterLabel), findsNothing);
      expect(find.text('World'), findsOneWidget);
    });

    testWidgets('a network slice: the row, its count and its one line',
        (tester) async {
      await tester.pumpWidget(_opener(
        (context) => CountryFilterDialog.show(
          context: context,
          countryResponses: _countries,
          currentSelectedCountry: null,
          questionTitle: 'Do lizards dream?',
          questionId: 'q1',
          questionType: 'approval',
          networkBreakdown: _network,
          networkHidden: 2,
        ),
        <Object?>[],
      ));
      await _open(tester);

      expect(find.text(kNetworkFilterLabel), findsOneWidget);
      expect(
        find.text('9+ answers · $kNetworkFilterSubtitle'),
        findsOneWidget,
        reason: 'the withheld remainder shows as "9+", as on the aggregate card',
      );
      expect(find.byIcon(Icons.hub_rounded), findsOneWidget);
    });

    testWidgets('no withheld remainder: a plain count', (tester) async {
      await tester.pumpWidget(_opener(
        (context) => CountryFilterDialog.show(
          context: context,
          countryResponses: _countries,
          currentSelectedCountry: null,
          questionTitle: 'Do lizards dream?',
          questionId: 'q1',
          questionType: 'approval',
          networkBreakdown: _network,
        ),
        <Object?>[],
      ));
      await _open(tester);

      expect(find.text('9 answers · $kNetworkFilterSubtitle'), findsOneWidget);
    });

    testWidgets('tapping the row returns the Network token', (tester) async {
      final returned = <Object?>[];
      await tester.pumpWidget(_opener(
        (context) => CountryFilterDialog.show(
          context: context,
          countryResponses: _countries,
          currentSelectedCountry: null,
          questionTitle: 'Do lizards dream?',
          questionId: 'q1',
          questionType: 'multiple_choice',
          questionOptions: const <String>['Yes', 'No'],
          networkBreakdown: _network,
          networkHidden: 2,
        ),
        returned,
      ));
      await _open(tester);
      await tester.tap(find.text(kNetworkFilterLabel));
      await tester.pumpAndSettle();

      expect(returned, <Object?>[kNetworkFilter]);
    });

    testWidgets('the selected row is ticked', (tester) async {
      await tester.pumpWidget(_opener(
        (context) => CountryFilterDialog.show(
          context: context,
          countryResponses: _countries,
          currentSelectedCountry: kNetworkFilter,
          questionTitle: 'Do lizards dream?',
          questionId: 'q1',
          questionType: 'approval',
          networkBreakdown: _network,
        ),
        <Object?>[],
      ));
      await _open(tester);

      expect(find.byIcon(Icons.check_circle), findsOneWidget);
    });
  });

  group('CountryComparisonDialog', () {
    testWidgets('no network slice: no row at all', (tester) async {
      await tester.pumpWidget(_opener(
        (context) => CountryComparisonDialog.show(
          context: context,
          countryResponses: _countries,
          questionTitle: 'Do lizards dream?',
          questionId: 'q1',
          questionType: 'approval',
        ),
        <Object?>[],
      ));
      await _open(tester);

      expect(find.text(kNetworkFilterLabel), findsNothing);
    });

    testWidgets('My Network can be a side, and comes back as the token',
        (tester) async {
      final returned = <Object?>[];
      await tester.pumpWidget(_opener(
        (context) => CountryComparisonDialog.show(
          context: context,
          countryResponses: _countries,
          questionTitle: 'Do lizards dream?',
          questionId: 'q1',
          questionType: 'approval',
          networkBreakdown: _network,
          networkHidden: 2,
        ),
        returned,
      ));
      await _open(tester);

      expect(find.text('9+ answers · $kNetworkFilterSubtitle'), findsOneWidget);

      // Side 1: My Network. Side 2: World.
      await tester.tap(find.text(kNetworkFilterLabel));
      await tester.pumpAndSettle();
      await tester.tap(find.text('World').first);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Compare'));
      await tester.pumpAndSettle();

      expect(returned, <Object?>[
        <String>[kNetworkFilter, 'World']
      ]);
    });
  });
}
