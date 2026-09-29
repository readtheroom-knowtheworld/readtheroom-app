// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Full truth table for the pure QOTD-first home state machine (Phase 2).

import 'package:flutter_test/flutter_test.dart';
import 'package:read_the_room/src/utils/qotd_home_state.dart';

void main() {
  group('qotdHomeState — truth table', () {
    // While unresolved, the other flags are irrelevant → always loading.
    test('unresolved is loading regardless of exists/answered', () {
      for (final exists in [true, false]) {
        for (final answered in [true, false]) {
          expect(
            qotdHomeState(
              qotdResolved: false,
              qotdExists: exists,
              hasAnswered: answered,
            ),
            QotdHomeState.loading,
            reason: 'resolved=false, exists=$exists, answered=$answered',
          );
        }
      }
    });

    // Resolved but no QOTD → unavailable, regardless of answered.
    test('resolved + no QOTD is unavailable regardless of answered', () {
      for (final answered in [true, false]) {
        expect(
          qotdHomeState(
            qotdResolved: true,
            qotdExists: false,
            hasAnswered: answered,
          ),
          QotdHomeState.unavailable,
          reason: 'answered=$answered',
        );
      }
    });

    test('resolved + exists + not answered is ask', () {
      expect(
        qotdHomeState(
          qotdResolved: true,
          qotdExists: true,
          hasAnswered: false,
        ),
        QotdHomeState.ask,
      );
    });

    test('resolved + exists + answered is answered', () {
      expect(
        qotdHomeState(
          qotdResolved: true,
          qotdExists: true,
          hasAnswered: true,
        ),
        QotdHomeState.answered,
      );
    });
  });
}
