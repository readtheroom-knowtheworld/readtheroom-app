// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The Join-the-beta platform links (2026-09-17). Both constants ship empty —
// no enrolment URL exists anywhere in the repo — so what matters is that an
// unfilled link produces *no button* rather than a dead one. `hasBetaLink` is
// the whole gate, kept pure so the rule is testable without pumping the screen
// (JoinBetaScreen hard-instantiates Supabase in its state, like the feedback
// screen it grew out of).

import 'package:flutter_test/flutter_test.dart';
import 'package:read_the_room/src/utils/beta_links.dart';

void main() {
  group('hasBetaLink', () {
    test('an empty or blank URL hides its button', () {
      expect(hasBetaLink(''), isFalse);
      expect(hasBetaLink('   '), isFalse);
      expect(hasBetaLink('\n'), isFalse);
    });

    test('a real URL shows its button', () {
      expect(hasBetaLink('https://testflight.apple.com/join/ABCD1234'), isTrue);
      expect(
        hasBetaLink('https://play.google.com/apps/testing/com.readtheroom.app'),
        isTrue,
      );
    });
  });

  group('the shipped constants', () {
    test('are gated by hasBetaLink either way', () {
      // Deliberately not asserting they are empty: the owner filling them in
      // must not break the suite. What is asserted is that whatever they hold,
      // the gate agrees with it.
      expect(hasBetaLink(kTestFlightUrl), kTestFlightUrl.trim().isNotEmpty);
      expect(hasBetaLink(kPlayBetaUrl), kPlayBetaUrl.trim().isNotEmpty);
    });
  });
}
