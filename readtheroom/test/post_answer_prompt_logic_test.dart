// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The post-answer notification prompt decision: first ask vs weekly re-ask vs
// nothing, given the persisted state and the live OS permission.
//
// The bug this guards against is the one the owner hit: the decision used to be
// spread across `UserService.shouldShowNotificationPermissionDialog()`, the
// re-ask gate and one widget, so only the home hero ever asked. These tests pin
// the combined rule so any surface calling it behaves identically.

import 'package:flutter_test/flutter_test.dart';
import 'package:read_the_room/src/utils/notification_reask_logic.dart';
import 'package:read_the_room/src/utils/post_answer_prompt_logic.dart';

void main() {
  final now = DateTime(2026, 9, 11, 12, 0);

  PostAnswerPromptDecision decide({
    bool answeredQotd = true,
    bool everAsked = false,
    DateTime? lastAskedAt,
    bool grantedInApp = false,
    OsNotificationPermission osStatus = OsNotificationPermission.notDetermined,
  }) {
    return postAnswerNotificationPromptDecision(
      now: now,
      answeredQotd: answeredQotd,
      everAsked: everAsked,
      lastAskedAt: lastAskedAt,
      grantedInApp: grantedInApp,
      osStatus: osStatus,
    );
  }

  group('first ask (never asked before)', () {
    test('a QOTD answer with permission undetermined shows the pre-prompt', () {
      expect(decide(), PostAnswerPromptDecision.showInAppPrompt);
    });

    test('fires regardless of a null timestamp — the re-ask gate abstains', () {
      // The weekly gate returns `none` for a null stamp on purpose; if the first
      // ask deferred to it, a brand-new user would never be asked at all.
      expect(
        notificationReAskAction(
          now: now,
          lastAskedAt: null,
          grantedInApp: false,
          osDenied: false,
        ),
        NotificationReAskAction.none,
      );
      expect(decide(lastAskedAt: null),
          PostAnswerPromptDecision.showInAppPrompt);
    });

    test('OS already denied → Settings, not a dead system request', () {
      expect(
        decide(osStatus: OsNotificationPermission.denied),
        PostAnswerPromptDecision.openAppSettings,
      );
    });

    test('an unreadable status still asks rather than silently skipping', () {
      expect(
        decide(osStatus: OsNotificationPermission.unknown),
        PostAnswerPromptDecision.showInAppPrompt,
      );
    });
  });

  group('permission already held short-circuits everything', () {
    test('authorized → nothing, even on a first answer', () {
      expect(
        decide(osStatus: OsNotificationPermission.authorized),
        PostAnswerPromptDecision.none,
      );
    });

    test('provisional counts as held — iOS delivers quietly', () {
      expect(
        decide(osStatus: OsNotificationPermission.provisional),
        PostAnswerPromptDecision.none,
      );
      expect(
          osPermissionAllowsDelivery(OsNotificationPermission.provisional),
          isTrue);
    });

    test('a user who granted via Settings is not re-asked on the old stamp', () {
      // Persisted bookkeeping says "asked a month ago, declined", but the OS says
      // authorized — the OS wins.
      expect(
        decide(
          everAsked: true,
          lastAskedAt: now.subtract(const Duration(days: 30)),
          osStatus: OsNotificationPermission.authorized,
        ),
        PostAnswerPromptDecision.none,
      );
    });
  });

  group('re-ask (asked before)', () {
    test('inside the cooling-off week → nothing', () {
      expect(
        decide(
          everAsked: true,
          lastAskedAt: now.subtract(const Duration(days: 6, hours: 23)),
        ),
        PostAnswerPromptDecision.none,
      );
    });

    test('at the 7-day boundary → the pre-prompt again', () {
      expect(
        decide(
          everAsked: true,
          lastAskedAt: now.subtract(kNotificationReAskInterval),
        ),
        PostAnswerPromptDecision.showInAppPrompt,
      );
    });

    test('after the week with the OS denied → Settings deep link', () {
      expect(
        decide(
          everAsked: true,
          lastAskedAt: now.subtract(const Duration(days: 8)),
          osStatus: OsNotificationPermission.denied,
        ),
        PostAnswerPromptDecision.openAppSettings,
      );
    });

    test('accepted in app → never again', () {
      expect(
        decide(
          everAsked: true,
          lastAskedAt: now.subtract(const Duration(days: 400)),
          grantedInApp: true,
          osStatus: OsNotificationPermission.denied,
        ),
        PostAnswerPromptDecision.none,
      );
    });

    test('asked before but the stamp is missing → quiet, not a second first ask',
        () {
      // The migration in `UserService._load` backfills this, but an install that
      // somehow lacks the stamp must not be treated as never-asked.
      expect(
        decide(everAsked: true, lastAskedAt: null),
        PostAnswerPromptDecision.none,
      );
    });

    test('a future stamp (clock skew) is treated as just-asked', () {
      expect(
        decide(everAsked: true, lastAskedAt: now.add(const Duration(days: 3))),
        PostAnswerPromptDecision.none,
      );
    });
  });

  group('non-QOTD answers', () {
    test('never prompt — the ask is tied to the daily ritual', () {
      for (final status in OsNotificationPermission.values) {
        expect(
          decide(answeredQotd: false, osStatus: status),
          PostAnswerPromptDecision.none,
          reason: 'osStatus=$status',
        );
      }
    });
  });

  group('owed-prompt window', () {
    test('no stamp is no debt', () {
      expect(isPostAnswerPromptOwed(now: now, owedAt: null), isFalse);
    });

    test('a fresh stamp is owed', () {
      expect(
        isPostAnswerPromptOwed(
            now: now, owedAt: now.subtract(const Duration(minutes: 5))),
        isTrue,
      );
    });

    test('the window boundary is inclusive', () {
      expect(
        isPostAnswerPromptOwed(
            now: now, owedAt: now.subtract(kPostAnswerPromptOwedWindow)),
        isTrue,
      );
    });

    test('a stamp older than the window is forgotten', () {
      expect(
        isPostAnswerPromptOwed(
          now: now,
          owedAt: now
              .subtract(kPostAnswerPromptOwedWindow)
              .subtract(const Duration(minutes: 1)),
        ),
        isFalse,
      );
    });

    test('a future stamp (clock skew) still counts as owed', () {
      expect(
        isPostAnswerPromptOwed(
            now: now, owedAt: now.add(const Duration(hours: 2))),
        isTrue,
      );
    });

    test('the window is 24 hours', () {
      expect(kPostAnswerPromptOwedWindow, const Duration(hours: 24));
    });
  });

  group('notificationSettingsUiState', () {
    test('a guest gets the unauthenticated state whatever the OS says', () {
      for (final status in OsNotificationPermission.values) {
        expect(
          notificationSettingsUiState(
              isAuthenticated: false, osStatus: status),
          NotificationSettingsUiState.unauthenticated,
          reason: 'osStatus=$status',
        );
      }
    });

    test('authorized and provisional both render as granted', () {
      for (final status in [
        OsNotificationPermission.authorized,
        OsNotificationPermission.provisional,
      ]) {
        expect(
          notificationSettingsUiState(isAuthenticated: true, osStatus: status),
          NotificationSettingsUiState.granted,
          reason: 'osStatus=$status',
        );
      }
    });

    test('denied gets its own state so the UI can stop offering toggles', () {
      expect(
        notificationSettingsUiState(
            isAuthenticated: true,
            osStatus: OsNotificationPermission.denied),
        NotificationSettingsUiState.osDenied,
      );
    });

    test('notDetermined and unknown both keep the toggles usable', () {
      for (final status in [
        OsNotificationPermission.notDetermined,
        OsNotificationPermission.unknown,
      ]) {
        expect(
          notificationSettingsUiState(isAuthenticated: true, osStatus: status),
          NotificationSettingsUiState.notDetermined,
          reason: 'osStatus=$status',
        );
      }
    });
  });
}
