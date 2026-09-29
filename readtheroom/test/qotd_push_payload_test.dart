// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The QOTD push contract (`lib/src/utils/qotd_push_payload.dart`).
//
// Both shapes below are copied from `supabase/functions/send-qotd-push/
// index.ts` — `buildDropMessage` and `buildLegacyMessage` — because a client in
// the field can receive either: the mode is an env var (`QOTD_PUSH_MODE`) the
// owner flips without an app release. If the server's payload changes, these
// literals are the place the drift shows up.

import 'package:flutter_test/flutter_test.dart';
import 'package:read_the_room/src/utils/qotd_push_payload.dart';

/// `buildDropMessage`'s `data` block, verbatim (FCM sends every value as a
/// string, including the numbers).
Map<String, dynamic> dropData() => <String, dynamic>{
      'type': 'qotd_drop',
      'questionId': 'b5f2f4c0-0000-4000-8000-000000000001',
      'historyId': 'a1a1a1a1-0000-4000-8000-000000000002',
      'liveUntil': '2026-09-17T20:05:00.000Z',
      'publishedAt': '2026-09-17T20:00:00.000Z',
      'spotCap': '20',
      'spotsRemaining': '17',
      'liveWindowSeconds': '300',
      'title': '⚡ 17 spots left to pick tomorrow\'s question',
      'body': 'Should tipping be abolished?',
      'deepLink': 'readtheroom://qotd/b5f2f4c0-0000-4000-8000-000000000001',
      'click_action': 'FLUTTER_NOTIFICATION_CLICK',
    };

/// `buildLegacyMessage`'s `data` block, verbatim. No notification block at all.
Map<String, dynamic> legacyData() => <String, dynamic>{
      'type': 'qotd',
      'questionId': 'b5f2f4c0-0000-4000-8000-000000000001',
      'deepLink':
          'readtheroom://question/b5f2f4c0-0000-4000-8000-000000000001',
      'title': '📆 Question of the Day',
      'body': 'Should tipping be abolished?',
    };

void main() {
  group('drop-mode push', () {
    test('parses every field the server sends', () {
      final push = QotdPushPayload.parse(
        dropData(),
        notificationTitle: '⚡ 17 spots left to pick tomorrow\'s question',
        notificationBody: 'Should tipping be abolished?',
      )!;

      expect(push.kind, QotdPushKind.drop);
      expect(push.isDrop, isTrue);
      expect(push.questionId, 'b5f2f4c0-0000-4000-8000-000000000001');
      expect(push.historyId, 'a1a1a1a1-0000-4000-8000-000000000002');
      expect(push.title, '⚡ 17 spots left to pick tomorrow\'s question');
      expect(push.body, 'Should tipping be abolished?');
      expect(push.publishedAt, DateTime.utc(2026, 9, 17, 20, 0, 0));
      expect(push.liveUntil, DateTime.utc(2026, 9, 17, 20, 5, 0));
      expect(push.spotCap, 20);
      expect(push.spotsRemaining, 17);
      expect(push.liveWindowSeconds, 300);
    });

    test('goes on the qotd_drop channel and its tap lands on home', () {
      final push = QotdPushPayload.parse(dropData())!;
      expect(push.androidChannelId, 'qotd_drop');
      // Owner decision 2026-09-22: the tap opens home, not the question. The
      // payload is a `qotd` payload (routed to home), never a `question_` one.
      expect(push.navigationPayload,
          'qotd_b5f2f4c0-0000-4000-8000-000000000001');
      expect(push.navigationPayload.startsWith('question_'), isFalse);
      expect(QotdPushPayload.isQotdNavigationPayload(push.navigationPayload),
          isTrue);
      // The id still rides along for the activity log.
      expect(
          QotdPushPayload.questionIdFromNavigationPayload(
              push.navigationPayload),
          'b5f2f4c0-0000-4000-8000-000000000001');
      expect(QotdPushPayload.isQotdNavigationPayload('question_abc'), isFalse);
      expect(QotdPushPayload.questionIdFromNavigationPayload('qotd'), isNull);
    });

    test('a notification block means the OS already rendered it', () {
      final withBlock = QotdPushPayload.parse(
        dropData(),
        notificationTitle: '⚡ Today\'s question just dropped',
        notificationBody: 'Should tipping be abolished?',
      )!;
      expect(withBlock.hasOsNotificationBlock, isTrue);

      // A hand-made data-only test push of the same type: nothing on screen, so
      // the client must render it itself.
      final withoutBlock = QotdPushPayload.parse(dropData())!;
      expect(withoutBlock.hasOsNotificationBlock, isFalse);
    });
  });

  group('legacy-mode push', () {
    test('parses the pre-Drop data-only payload', () {
      final push = QotdPushPayload.parse(legacyData())!;

      expect(push.kind, QotdPushKind.legacy);
      expect(push.isDrop, isFalse);
      expect(push.questionId, 'b5f2f4c0-0000-4000-8000-000000000001');
      expect(push.title, '📆 Question of the Day');
      expect(push.body, 'Should tipping be abolished?');
      expect(push.androidChannelId, 'qotd_channel');
      // Never rendered by the OS — that is what "data-only" means, and it is
      // why the client has to show it on arrival.
      expect(push.hasOsNotificationBlock, isFalse);
      // The drop-only fields are simply absent.
      expect(push.historyId, isNull);
      expect(push.publishedAt, isNull);
      expect(push.spotCap, isNull);
    });
  });

  group('not a QOTD push', () {
    test('returns null for other types, so the type chain keeps working', () {
      expect(QotdPushPayload.parse(<String, dynamic>{'type': 'comment'}),
          isNull);
      expect(QotdPushPayload.parse(<String, dynamic>{'type': 'friend_event'}),
          isNull);
      expect(QotdPushPayload.parse(<String, dynamic>{}), isNull);
      expect(QotdPushPayload.isQotdPush(<String, dynamic>{'type': 'qotd'}),
          isTrue);
      expect(QotdPushPayload.isQotdPush(<String, dynamic>{'type': 'qotd_drop'}),
          isTrue);
      expect(QotdPushPayload.isQotdPush(<String, dynamic>{'type': 'system'}),
          isFalse);
    });
  });

  group('defensive parsing', () {
    test('a bare type still yields something showable', () {
      final drop = QotdPushPayload.parse(<String, dynamic>{'type': 'qotd_drop'})!;
      expect(drop.title, QotdPushPayload.dropFallbackTitle);
      expect(drop.body, QotdPushPayload.fallbackBody);
      expect(drop.questionId, isNull);
      // No question id: the tap still lands on home, and no crash either.
      expect(drop.navigationPayload, 'qotd');
      expect(QotdPushPayload.isQotdNavigationPayload(drop.navigationPayload),
          isTrue);

      final legacy = QotdPushPayload.parse(<String, dynamic>{'type': 'qotd'})!;
      expect(legacy.title, QotdPushPayload.legacyFallbackTitle);
    });

    test('falls back to the notification block when data carries no copy', () {
      final push = QotdPushPayload.parse(
        <String, dynamic>{'type': 'qotd_drop', 'questionId': 'q1'},
        notificationTitle: '⚡ Today\'s question just dropped',
        notificationBody: 'Is cereal a soup?',
      )!;
      expect(push.title, '⚡ Today\'s question just dropped');
      expect(push.body, 'Is cereal a soup?');
    });

    test('snake_case keys are accepted too', () {
      final push = QotdPushPayload.parse(<String, dynamic>{
        'type': 'qotd_drop',
        'question_id': 'q7',
        'history_id': 'h7',
        'published_at': '2026-09-17T18:30:00Z',
        'spot_cap': '20',
        'spots_remaining': '0',
        'live_window_seconds': '300',
      })!;
      expect(push.questionId, 'q7');
      expect(push.historyId, 'h7');
      expect(push.publishedAt, DateTime.utc(2026, 9, 17, 18, 30));
      expect(push.spotCap, 20);
      expect(push.spotsRemaining, 0);
      expect(push.liveWindowSeconds, 300);
    });

    test('unknown, empty and malformed fields are ignored, never fatal', () {
      final push = QotdPushPayload.parse(<String, dynamic>{
        'type': 'qotd_drop',
        'questionId': 'q9',
        // Fields a future server release might add.
        'ballotId': 'not-used-yet',
        'somethingNew': '{"nested":true}',
        // The server sends '' rather than null for an absent timestamp.
        'liveUntil': '',
        'publishedAt': 'not-a-date',
        'spotCap': 'twenty',
        'spotsRemaining': '  4  ',
        'title': '   ',
      })!;
      expect(push.questionId, 'q9');
      expect(push.liveUntil, isNull);
      expect(push.publishedAt, isNull);
      expect(push.spotCap, isNull);
      expect(push.spotsRemaining, 4);
      // Whitespace-only copy is treated as absent, not shown as blank.
      expect(push.title, QotdPushPayload.dropFallbackTitle);
    });

    test('numeric ladder values survive arriving as numbers', () {
      final push = QotdPushPayload.parse(<String, dynamic>{
        'type': 'qotd_drop',
        'spotCap': 20,
        'spotsRemaining': 3.0,
        'liveWindowSeconds': 300,
      })!;
      expect(push.spotCap, 20);
      expect(push.spotsRemaining, 3);
      expect(push.liveWindowSeconds, 300);
    });

    test('a non-UTC publishedAt is normalised to UTC', () {
      final push = QotdPushPayload.parse(<String, dynamic>{
        'type': 'qotd_drop',
        'publishedAt': '2026-09-17T20:00:00+02:00',
      })!;
      expect(push.publishedAt!.isUtc, isTrue);
      expect(push.publishedAt, DateTime.utc(2026, 9, 17, 18, 0));
    });
  });
}
