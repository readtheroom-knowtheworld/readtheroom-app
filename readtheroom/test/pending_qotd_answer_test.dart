// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The guest QOTD answer held between the onboarding question slide and the end
// of onboarding (WP-C3, decision D5). Pure model + the SharedPreferences-backed
// store; the actual submit needs a live Supabase and is exercised only through
// its prerequisite guards.

import 'package:flutter_test/flutter_test.dart';
import 'package:read_the_room/src/services/pending_answer_service.dart';
import 'package:read_the_room/src/utils/pending_qotd_answer.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final captured = DateTime.utc(2026, 9, 11, 12);

  PendingQotdAnswer approval({double? score = 0.6}) => PendingQotdAnswer(
        questionId: 'q1',
        questionType: 'approval_rating',
        capturedAt: captured,
        sliderValue: score,
        displayAnswer: 'Approve',
      );

  PendingQotdAnswer mc({String? option = 'Yes'}) => PendingQotdAnswer(
        questionId: 'q2',
        questionType: 'multiple_choice',
        capturedAt: captured,
        selectedOption: option,
        displayAnswer: option,
      );

  PendingQotdAnswer text({String? body = 'Because.'}) => PendingQotdAnswer(
        questionId: 'q3',
        questionType: 'text',
        capturedAt: captured,
        text: body,
        displayAnswer: body,
      );

  group('submitValue', () {
    test('matches QotdAnswerValue.submitValue per type', () {
      expect(approval().submitValue, 0.6);
      expect(mc().submitValue, 'Yes');
      expect(text().submitValue, 'Because.');
    });

    test('approval defaults to a neutral score when unset', () {
      expect(approval(score: null).submitValue, 0.0);
    });

    test('an unknown type yields nothing to submit', () {
      final unknown = PendingQotdAnswer(
        questionId: 'q4',
        questionType: 'mystery',
        capturedAt: captured,
      );
      expect(unknown.submitValue, isNull);
      expect(unknown.isSubmittable, isFalse);
    });
  });

  group('isSubmittable', () {
    test('requires the value its type needs', () {
      expect(approval().isSubmittable, isTrue);
      expect(approval(score: null).isSubmittable, isFalse);
      expect(mc().isSubmittable, isTrue);
      expect(mc(option: null).isSubmittable, isFalse);
      expect(mc(option: '').isSubmittable, isFalse);
      expect(text().isSubmittable, isTrue);
      expect(text(body: '   ').isSubmittable, isFalse);
    });
  });

  group('isExpired', () {
    test('a fresh stash is live', () {
      expect(approval().isExpired(captured.add(const Duration(hours: 23))),
          isFalse);
    });

    test('past 24 hours it is no longer "today\'s" answer', () {
      expect(
        approval().isExpired(captured.add(const Duration(hours: 25))),
        isTrue,
      );
    });

    test('the boundary itself is not expired', () {
      expect(approval().isExpired(captured.add(kPendingAnswerMaxAge)), isFalse);
    });
  });

  group('encode / decode round trip', () {
    test('preserves every field for each type', () {
      for (final answer in [approval(), mc(), text()]) {
        final decoded = PendingQotdAnswer.decode(answer.encode())!;
        expect(decoded.questionId, answer.questionId);
        expect(decoded.questionType, answer.questionType);
        expect(decoded.capturedAt.toUtc(), answer.capturedAt.toUtc());
        expect(decoded.sliderValue, answer.sliderValue);
        expect(decoded.selectedOption, answer.selectedOption);
        expect(decoded.text, answer.text);
        expect(decoded.displayAnswer, answer.displayAnswer);
        expect(decoded.submitValue, answer.submitValue);
        expect(
          decoded.sharedWithCloseFriends,
          answer.sharedWithCloseFriends,
        );
      }
    });

    test('rejects junk instead of throwing', () {
      expect(PendingQotdAnswer.decode(null), isNull);
      expect(PendingQotdAnswer.decode(''), isNull);
      expect(PendingQotdAnswer.decode('not json'), isNull);
      expect(PendingQotdAnswer.decode('[1,2,3]'), isNull);
      expect(PendingQotdAnswer.decode('{"question_id":"q"}'), isNull);
      expect(
        PendingQotdAnswer.decode(
            '{"question_id":"q","question_type":"text","captured_at":"nope"}'),
        isNull,
      );
    });
  });

  group('shared_with_close_friends (per-answer flag, 2026-09-17)', () {
    test('defaults to ON when the caller says nothing', () {
      expect(approval().sharedWithCloseFriends, isTrue);
      expect(mc().sharedWithCloseFriends, isTrue);
      expect(text().sharedWithCloseFriends, isTrue);
    });

    test('an opt-out survives the round trip', () {
      final off = PendingQotdAnswer(
        questionId: 'q5',
        questionType: 'text',
        capturedAt: captured,
        text: 'Quietly.',
        sharedWithCloseFriends: false,
      );
      expect(PendingQotdAnswer.decode(off.encode())!.sharedWithCloseFriends,
          isFalse);
    });

    test('the flag is always written, even when it is the default', () {
      // Unlike the optional answer fields this is never omitted: a reader that
      // cannot tell "ON" from "absent" would have to guess.
      expect(approval().toJson()['shared_with_close_friends'], isTrue);
    });

    test('a stash from an older build (no key) reads as ON, not as opt-out', () {
      final decoded = PendingQotdAnswer.decode(
        '{"question_id":"q6","question_type":"text",'
        '"captured_at":"2026-09-11T12:00:00.000Z","text":"hi"}',
      )!;
      expect(decoded.sharedWithCloseFriends, isTrue);
    });

    test('only an explicit false opts out', () {
      PendingQotdAnswer withFlag(String raw) => PendingQotdAnswer.decode(
            '{"question_id":"q7","question_type":"text",'
            '"captured_at":"2026-09-11T12:00:00.000Z","text":"hi",'
            '"shared_with_close_friends":$raw}',
          )!;
      expect(withFlag('false').sharedWithCloseFriends, isFalse);
      expect(withFlag('true').sharedWithCloseFriends, isTrue);
      expect(withFlag('null').sharedWithCloseFriends, isTrue);
    });

    test('the store keeps the opt-out across a reload', () async {
      SharedPreferences.setMockInitialValues({});
      final service = PendingAnswerService();
      await service.stash(
        PendingQotdAnswer(
          questionId: 'q8',
          questionType: 'multiple_choice',
          capturedAt: captured,
          selectedOption: 'No',
          sharedWithCloseFriends: false,
        ),
      );

      final loaded = await PendingAnswerService().load(now: captured);
      expect(loaded?.sharedWithCloseFriends, isFalse);
    });
  });

  group('PendingAnswerService store', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('stash then load returns the same answer', () async {
      final service = PendingAnswerService();
      await service.stash(mc());
      expect(service.hasPending, isTrue);

      final reloaded = PendingAnswerService();
      final loaded = await reloaded.load(now: captured);
      expect(loaded?.questionId, 'q2');
      expect(loaded?.selectedOption, 'Yes');
    });

    test('load drops an expired stash', () async {
      final service = PendingAnswerService();
      await service.stash(approval());

      final reloaded = PendingAnswerService();
      final loaded =
          await reloaded.load(now: captured.add(const Duration(days: 2)));
      expect(loaded, isNull);
      expect(reloaded.hasPending, isFalse);
    });

    test('load drops a corrupt stash without throwing', () async {
      SharedPreferences.setMockInitialValues({
        'pending_qotd_answer': 'garbage',
      });
      final service = PendingAnswerService();
      expect(await service.load(now: captured), isNull);
    });

    test('clear removes it', () async {
      final service = PendingAnswerService();
      await service.stash(text());
      await service.clear();
      expect(service.hasPending, isFalse);
      expect(await PendingAnswerService().load(now: captured), isNull);
    });

    test('empty by default', () async {
      final service = PendingAnswerService();
      expect(await service.load(now: captured), isNull);
      expect(service.hasPending, isFalse);
    });
  });
}
