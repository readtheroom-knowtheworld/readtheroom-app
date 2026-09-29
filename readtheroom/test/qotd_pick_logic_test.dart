// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter_test/flutter_test.dart';
import 'package:read_the_room/src/utils/qotd_pick_logic.dart';

void main() {
  group('qotdPickDecision — first-N answerers get the pick sheet', () {
    test('answerer #1 through #10 are offered', () {
      for (var rank = 1; rank <= kQotdPickSpots; rank++) {
        expect(
          qotdPickDecision(
              answerRank: rank, alreadyOffered: false, authenticated: true),
          QotdPickDecision.offer,
          reason: 'rank $rank',
        );
      }
    });

    test('answerer #11 is not', () {
      expect(
        qotdPickDecision(
            answerRank: kQotdPickSpots + 1,
            alreadyOffered: false,
            authenticated: true),
        QotdPickDecision.notInFirstSpots,
      );
    });

    test('offered once per QOTD', () {
      expect(
        qotdPickDecision(answerRank: 2, alreadyOffered: true, authenticated: true),
        QotdPickDecision.alreadyOffered,
      );
    });

    test('guests and unknown ranks are never offered', () {
      expect(
        qotdPickDecision(answerRank: 1, alreadyOffered: false, authenticated: false),
        QotdPickDecision.notEligible,
      );
      expect(
        qotdPickDecision(answerRank: null, alreadyOffered: false, authenticated: true),
        QotdPickDecision.notEligible,
      );
      expect(
        qotdPickDecision(answerRank: 0, alreadyOffered: false, authenticated: true),
        QotdPickDecision.notEligible,
      );
    });

    test('the spot count is configurable (Drop ladder later)', () {
      expect(
        qotdPickDecision(
            answerRank: 15, alreadyOffered: false, authenticated: true, spots: 20),
        QotdPickDecision.offer,
      );
    });
  });

  group('ordinal', () {
    test('st / nd / rd / th, with the teens as th', () {
      final cases = {
        1: '1st', 2: '2nd', 3: '3rd', 4: '4th', 10: '10th',
        11: '11th', 12: '12th', 13: '13th', 21: '21st', 22: '22nd',
        23: '23rd', 101: '101st', 111: '111th', 112: '112th',
      };
      cases.forEach((n, expected) => expect(ordinal(n), expected));
    });
  });

  group('first-answerer copy', () {
    test('celebration line, with and without a handle', () {
      expect(
        firstAnswererCelebrationText(3, null),
        "You're the 3rd to answer today — "
        "you get to pick tomorrow's Question of the Day!",
      );
      expect(
        firstAnswererCelebrationText(1, '  '),
        "You're the 1st to answer today — "
        "you get to pick tomorrow's Question of the Day!",
      );
      expect(
        firstAnswererCelebrationText(2, 'curious_cham7'),
        "You're the 2nd to answer today, curious_cham7 — "
        "you get to pick tomorrow's Question of the Day!",
      );
    });

    test('sheet headline', () {
      expect(
        firstAnswererSheetTitle(11),
        "You're the 11th to answer today — pick tomorrow's Question of the Day!",
      );
    });
  });

  group('postAnswerCelebration', () {
    test('the notification dialog outranks every celebration', () {
      for (final pick in [true, false]) {
        for (final streak in [true, false]) {
          expect(
            postAnswerCelebration(
                notificationDialogShown: true,
                pickOffered: pick,
                streakExtended: streak),
            PostAnswerCelebration.none,
          );
        }
      }
    });

    test('first answerer replaces the streak +1', () {
      expect(
        postAnswerCelebration(
            notificationDialogShown: false,
            pickOffered: true,
            streakExtended: true),
        PostAnswerCelebration.firstAnswerer,
      );
    });

    test('first answerer plays even without a streak extension', () {
      expect(
        postAnswerCelebration(
            notificationDialogShown: false,
            pickOffered: true,
            streakExtended: false),
        PostAnswerCelebration.firstAnswerer,
      );
    });

    test('everyone else gets the streak celebration when it extended', () {
      expect(
        postAnswerCelebration(
            notificationDialogShown: false,
            pickOffered: false,
            streakExtended: true),
        PostAnswerCelebration.streak,
      );
      expect(
        postAnswerCelebration(
            notificationDialogShown: false,
            pickOffered: false,
            streakExtended: false),
        PostAnswerCelebration.none,
      );
    });
  });
}
