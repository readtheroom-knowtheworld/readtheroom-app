// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Widget tests for the Asker's Pick sheet (Phase 3b). The sheet is pure UI: it
// takes pre-fetched candidates + an onNominate callback, so it renders without
// any Supabase dependency.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:read_the_room/src/services/nomination_result.dart';
import 'package:read_the_room/src/widgets/qotd_nomination_sheet.dart';

List<Map<String, dynamic>> _candidates() => [
      {'id': 'q1', 'prompt': 'Is a hotdog a sandwich?', 'votes': 42},
      {'id': 'q2', 'prompt': 'Should pineapple go on pizza?', 'votes': 17},
      {'id': 'q3', 'prompt': 'Are cats better than dogs?', 'votes': 1},
    ];

void main() {
  testWidgets('renders title, subtitle, 3 candidate tiles and a Skip',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: QotdNominationSheet(
            candidates: _candidates(),
            onNominate: (_) async => const NominationResult.ok(),
          ),
        ),
      ),
    );

    expect(find.text("Help pick tomorrow's question!"), findsOneWidget);
    expect(find.text('Is a hotdog a sandwich?'), findsOneWidget);
    expect(find.text('Should pineapple go on pizza?'), findsOneWidget);
    expect(find.text('Are cats better than dogs?'), findsOneWidget);
    // Vote counts + singular/plural handling.
    expect(find.text('42 answers'), findsOneWidget);
    expect(find.text('1 answer'), findsOneWidget);
    expect(find.text('Skip'), findsOneWidget);
  });

  testWidgets('tapping a tile nominates that question and returns picked',
      (tester) async {
    String? nominatedId;
    QotdNominationOutcome? outcome;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () async {
                  outcome = await QotdNominationSheet.show(
                    context,
                    candidates: _candidates(),
                    onNominate: (id) async {
                      nominatedId = id;
                      return const NominationResult.ok();
                    },
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Should pineapple go on pizza?'));
    await tester.pumpAndSettle();

    expect(nominatedId, 'q2');
    expect(outcome, isNotNull);
    expect(outcome!.action, QotdNominationAction.picked);
    expect(outcome!.candidatesShown, 3);
    // Success feedback surfaces after the sheet closes.
    expect(find.byType(SnackBar), findsOneWidget);
  });

  testWidgets('Skip returns skipped without nominating', (tester) async {
    var nominateCalled = false;
    QotdNominationOutcome? outcome;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () async {
                  outcome = await QotdNominationSheet.show(
                    context,
                    candidates: _candidates(),
                    onNominate: (id) async {
                      nominateCalled = true;
                      return const NominationResult.ok();
                    },
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Skip'));
    await tester.pumpAndSettle();

    expect(nominateCalled, isFalse);
    expect(outcome, isNotNull);
    expect(outcome!.action, QotdNominationAction.skipped);
    expect(outcome!.candidatesShown, 3);
  });

  testWidgets('a rule rejection still closes the sheet and shows a message',
      (tester) async {
    QotdNominationOutcome? outcome;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () async {
                  outcome = await QotdNominationSheet.show(
                    context,
                    candidates: _candidates(),
                    onNominate: (_) async =>
                        NominationResult.fail(NominationError.dailyLimit),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Is a hotdog a sandwich?'));
    await tester.pumpAndSettle();

    // Still counts as "picked" (user made a choice) and the flow continues.
    expect(outcome!.action, QotdNominationAction.picked);
    expect(find.byType(SnackBar), findsOneWidget);
  });
}
