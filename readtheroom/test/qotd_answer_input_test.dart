// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// QotdAnswerInput — the hero card's inline per-type answer input. These tests
// pin the guarantee that every QOTD type is answerable from the home screen,
// including text/discussion questions (verified 2026-09-01).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:read_the_room/src/widgets/qotd_answer_input.dart';

Widget _host(
  Map<String, dynamic> question,
  ValueChanged<QotdAnswerValue> onChanged, {
  ValueChanged<QotdAnswerValue>? onCommit,
}) {
  return MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: QotdAnswerInput(
          question: question,
          onChanged: onChanged,
          onCommit: onCommit,
        ),
      ),
    ),
  );
}

void main() {
  group('QotdAnswerInput — text/discussion QOTD on the home hero', () {
    testWidgets('renders a text field and gates submit on non-empty text',
        (tester) async {
      QotdAnswerValue? value;
      await tester.pumpWidget(_host(
        {'id': 'q1', 'type': 'text', 'prompt': 'Tell us something'},
        (v) => value = v,
      ));
      await tester.pump(); // post-frame initial notify

      expect(find.byType(TextField), findsOneWidget);
      expect(value, isNotNull);
      expect(value!.canSubmit, isFalse); // empty text can't submit

      await tester.enterText(find.byType(TextField), '  My answer  ');
      await tester.pump();

      expect(value!.canSubmit, isTrue);
      expect(value!.submitValue, 'My answer'); // trimmed for the response API
    });

    testWidgets('whitespace-only text stays unsubmittable', (tester) async {
      QotdAnswerValue? value;
      await tester.pumpWidget(_host(
        {'id': 'q1', 'type': 'text', 'prompt': 'Tell us something'},
        (v) => value = v,
      ));
      await tester.pump();

      await tester.enterText(find.byType(TextField), '   ');
      await tester.pump();
      expect(value!.canSubmit, isFalse);
    });
  });

  group('QotdAnswerInput — other types', () {
    testWidgets('approval is submittable immediately with a slider value',
        (tester) async {
      QotdAnswerValue? value;
      await tester.pumpWidget(_host(
        {'id': 'q2', 'type': 'approval_rating', 'prompt': 'Agree?'},
        (v) => value = v,
      ));
      await tester.pump();

      expect(value!.canSubmit, isTrue);
      expect(value!.submitValue, isA<double>());
    });

    testWidgets('multiple choice requires a selection', (tester) async {
      QotdAnswerValue? value;
      await tester.pumpWidget(_host(
        {
          'id': 'q3',
          'type': 'multiple_choice',
          'prompt': 'Pick one',
          'question_options': [
            {'option_text': 'Alpha'},
            {'option_text': 'Beta'},
          ],
        },
        (v) => value = v,
      ));
      await tester.pump();

      expect(value!.canSubmit, isFalse);
      await tester.tap(find.text('Beta'));
      await tester.pump();
      expect(value!.canSubmit, isTrue);
      expect(value!.submitValue, 'Beta');
    });
  });

  // WP-A tap-to-submit: the input reports a "committed" one-gesture answer so
  // the hero can fire its AnimatedSubmitButton. Text questions must not.
  group('QotdAnswerInput — onCommit (tap-to-submit)', () {
    testWidgets('an MC option tap commits the selection', (tester) async {
      final commits = <QotdAnswerValue>[];
      await tester.pumpWidget(_host(
        {
          'id': 'q3',
          'type': 'multiple_choice',
          'prompt': 'Pick one',
          'question_options': [
            {'option_text': 'Alpha'},
            {'option_text': 'Beta'},
          ],
        },
        (_) {},
        onCommit: commits.add,
      ));
      await tester.pump();
      expect(commits, isEmpty);

      await tester.tap(find.text('Alpha'));
      await tester.pump();

      expect(commits.length, 1);
      expect(commits.single.submitValue, 'Alpha');
      expect(commits.single.canSubmit, isTrue);
    });

    testWidgets('releasing the approval slider commits (D7)', (tester) async {
      final commits = <QotdAnswerValue>[];
      await tester.pumpWidget(_host(
        {'id': 'q2', 'type': 'approval_rating', 'prompt': 'Agree?'},
        (_) {},
        onCommit: commits.add,
      ));
      await tester.pump();
      expect(commits, isEmpty, reason: 'no commit before the user touches it');

      // Drag the slider thumb and release.
      final slider = find.byType(Slider);
      await tester.drag(slider, const Offset(60, 0));
      await tester.pumpAndSettle();

      expect(commits.length, 1, reason: 'exactly one commit per release');
      expect(commits.single.submitValue, isA<double>());
    });

    testWidgets('text questions never commit (manual button only)',
        (tester) async {
      final commits = <QotdAnswerValue>[];
      await tester.pumpWidget(_host(
        {'id': 'q1', 'type': 'text', 'prompt': 'Tell us something'},
        (_) {},
        onCommit: commits.add,
      ));
      await tester.pump();

      await tester.enterText(find.byType(TextField), 'My answer');
      await tester.pump();

      expect(commits, isEmpty);
    });
  });
}
