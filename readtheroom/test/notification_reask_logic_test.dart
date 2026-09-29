// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// WP-A item 4: the weekly notification re-ask gate.

import 'package:flutter_test/flutter_test.dart';
import 'package:read_the_room/src/utils/notification_reask_logic.dart';

void main() {
  final now = DateTime(2026, 9, 11, 12, 0);

  group('shouldReAskNotificationPermission', () {
    test('never re-asks a user who accepted the in-app pre-prompt', () {
      expect(
        shouldReAskNotificationPermission(
          now: now,
          lastAskedAt: now.subtract(const Duration(days: 400)),
          grantedInApp: true,
          osDenied: false,
        ),
        isFalse,
      );
    });

    test('no ask on record leaves the first-ask gate in charge', () {
      expect(
        shouldReAskNotificationPermission(
          now: now,
          lastAskedAt: null,
          grantedInApp: false,
          osDenied: false,
        ),
        isFalse,
      );
    });

    test('stays quiet inside the cooling-off week', () {
      expect(
        shouldReAskNotificationPermission(
          now: now,
          lastAskedAt: now.subtract(const Duration(days: 6, hours: 23)),
          grantedInApp: false,
          osDenied: false,
        ),
        isFalse,
      );
    });

    test('re-asks exactly at the 7-day boundary', () {
      expect(
        shouldReAskNotificationPermission(
          now: now,
          lastAskedAt: now.subtract(kNotificationReAskInterval),
          grantedInApp: false,
          osDenied: false,
        ),
        isTrue,
      );
    });

    test('re-asks after the week, OS denied or not', () {
      for (final osDenied in [true, false]) {
        expect(
          shouldReAskNotificationPermission(
            now: now,
            lastAskedAt: now.subtract(const Duration(days: 30)),
            grantedInApp: false,
            osDenied: osDenied,
          ),
          isTrue,
          reason: 'osDenied=$osDenied changes how we ask, not whether',
        );
      }
    });

    test('a future stamp (clock skew) is treated as just-asked', () {
      expect(
        shouldReAskNotificationPermission(
          now: now,
          lastAskedAt: now.add(const Duration(days: 2)),
          grantedInApp: false,
          osDenied: false,
        ),
        isFalse,
      );
    });
  });

  group('notificationReAskAction', () {
    test('OS denied → Settings deep link instead of a dead system request', () {
      expect(
        notificationReAskAction(
          now: now,
          lastAskedAt: now.subtract(const Duration(days: 8)),
          grantedInApp: false,
          osDenied: true,
        ),
        NotificationReAskAction.openAppSettings,
      );
    });

    test('OS not denied → the in-app pre-prompt', () {
      expect(
        notificationReAskAction(
          now: now,
          lastAskedAt: now.subtract(const Duration(days: 8)),
          grantedInApp: false,
          osDenied: false,
        ),
        NotificationReAskAction.showInAppPrompt,
      );
    });

    test('granted in app → nothing, even when the OS says denied', () {
      expect(
        notificationReAskAction(
          now: now,
          lastAskedAt: now.subtract(const Duration(days: 99)),
          grantedInApp: true,
          osDenied: true,
        ),
        NotificationReAskAction.none,
      );
    });

    test('the interval is one week', () {
      expect(kNotificationReAskInterval, const Duration(days: 7));
    });

    test('one second short of the boundary is still quiet', () {
      expect(
        notificationReAskAction(
          now: now,
          lastAskedAt: now
              .subtract(kNotificationReAskInterval)
              .add(const Duration(seconds: 1)),
          grantedInApp: false,
          osDenied: false,
        ),
        NotificationReAskAction.none,
      );
    });

    test('a stamp equal to now is "just asked"', () {
      expect(
        notificationReAskAction(
          now: now,
          lastAskedAt: now,
          grantedInApp: false,
          osDenied: false,
        ),
        NotificationReAskAction.none,
      );
    });

    test('a very old stamp still only asks once per evaluation, via the same '
        'action', () {
      // Regression guard: the gate is stateless, so repeated evaluation with the
      // same inputs must keep returning the same action. Advancing the stamp is
      // the caller's job (`recordNotificationPermissionAsked`).
      final action = notificationReAskAction(
        now: now,
        lastAskedAt: now.subtract(const Duration(days: 365)),
        grantedInApp: false,
        osDenied: false,
      );
      expect(action, NotificationReAskAction.showInAppPrompt);
      expect(
        notificationReAskAction(
          now: now,
          lastAskedAt: now.subtract(const Duration(days: 365)),
          grantedInApp: false,
          osDenied: false,
        ),
        action,
      );
    });

    test('shouldReAsk agrees with notificationReAskAction for every input',
        () {
      final stamps = <DateTime?>[
        null,
        now,
        now.subtract(const Duration(days: 1)),
        now.subtract(kNotificationReAskInterval),
        now.subtract(const Duration(days: 100)),
        now.add(const Duration(days: 1)),
      ];
      for (final stamp in stamps) {
        for (final granted in [true, false]) {
          for (final denied in [true, false]) {
            final action = notificationReAskAction(
              now: now,
              lastAskedAt: stamp,
              grantedInApp: granted,
              osDenied: denied,
            );
            expect(
              shouldReAskNotificationPermission(
                now: now,
                lastAskedAt: stamp,
                grantedInApp: granted,
                osDenied: denied,
              ),
              action != NotificationReAskAction.none,
              reason: 'stamp=$stamp granted=$granted denied=$denied',
            );
          }
        }
      }
    });
  });
}
