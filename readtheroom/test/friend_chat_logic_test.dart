// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Pure friend-chat logic (WP-F): the timeline merge/dedupe reducer, reaction
// attachment, unread derivation, the OQ-2 lick cooldown, forward-picker
// filtering and the event summary copy. No Flutter, no Supabase, no Realtime —
// these are the rules FriendChatService and the chat overlay depend on, tested
// without any of them.

import 'package:flutter_test/flutter_test.dart';
import 'package:read_the_room/src/utils/friend_chat_logic.dart';

const String kMe = 'me-uuid';
const String kThem = 'them-uuid';
const String kOther = 'other-uuid';

final DateTime t0 = DateTime.utc(2026, 9, 11, 12, 0, 0);
DateTime at(int minutes) => t0.add(Duration(minutes: minutes));

FriendEvent _lick(
  String id, {
  String from = kThem,
  String to = kMe,
  int minute = 0,
  DateTime? readAt,
}) =>
    FriendEvent(
      id: id,
      senderId: from,
      recipientId: to,
      kind: FriendEventKind.lick,
      createdAt: at(minute),
      readAt: readAt,
    );

FriendEvent _forward(
  String id, {
  String from = kThem,
  String to = kMe,
  int minute = 0,
  String questionId = 'q1',
  String? prompt = 'Is cereal a soup?',
  bool hidden = false,
  DateTime? readAt,
}) =>
    FriendEvent(
      id: id,
      senderId: from,
      recipientId: to,
      kind: FriendEventKind.forward,
      createdAt: at(minute),
      questionId: questionId,
      questionPrompt: prompt,
      questionType: 'approval_rating',
      questionHidden: hidden,
      readAt: readAt,
    );

FriendEvent _reaction(
  String id, {
  String from = kMe,
  String to = kThem,
  int minute = 0,
  required String target,
  String emoji = '😂',
  DateTime? readAt,
}) =>
    FriendEvent(
      id: id,
      senderId: from,
      recipientId: to,
      kind: FriendEventKind.reaction,
      createdAt: at(minute),
      targetEventId: target,
      emoji: emoji,
      readAt: readAt,
    );

void main() {
  group('FriendEvent.fromMap', () {
    test('parses a full get_friend_timeline row', () {
      final event = FriendEvent.fromMap({
        'id': 'e1',
        'sender_id': kThem,
        'recipient_id': kMe,
        'type': 'forward',
        'question_id': 'q1',
        'target_event_id': null,
        'emoji': null,
        'read_at': null,
        'created_at': '2026-09-11T12:00:00Z',
        'question_prompt': 'Is cereal a soup?',
        'question_type': 'approval_rating',
        'question_hidden': false,
      })!;

      expect(event.kind, FriendEventKind.forward);
      expect(event.questionId, 'q1');
      expect(event.questionPrompt, 'Is cereal a soup?');
      expect(event.isUnread, isTrue);
      expect(event.isMine(kMe), isFalse);
      expect(event.isMine(kThem), isTrue);
      expect(event.friendId(kMe), kThem);
      expect(event.isOpenableForward, isTrue);
    });

    test('drops rows that cannot identify themselves', () {
      expect(FriendEvent.fromMap({'sender_id': kMe, 'recipient_id': kThem}),
          isNull);
      expect(FriendEvent.fromMap({'id': 'e1', 'recipient_id': kThem}), isNull);
      expect(FriendEvent.fromMap({'id': '', 'sender_id': kMe, 'recipient_id': kThem}),
          isNull);
    });

    test('treats the literal string "null" as absent', () {
      final event = FriendEvent.fromMap({
        'id': 'e1',
        'sender_id': kMe,
        'recipient_id': kThem,
        'type': 'lick',
        'emoji': 'null',
        'question_id': 'null',
        'created_at': '2026-09-11T12:00:00Z',
      })!;
      expect(event.emoji, isNull);
      expect(event.questionId, isNull);
    });

    test('an unknown type round-trips instead of throwing', () {
      final event = FriendEvent.fromMap({
        'id': 'e1',
        'sender_id': kMe,
        'recipient_id': kThem,
        'type': 'telepathy',
        'created_at': '2026-09-11T12:00:00Z',
      })!;
      expect(event.kind, FriendEventKind.unknown);
    });

    test('an unparseable timestamp sinks to the epoch rather than sorting at random', () {
      final event = FriendEvent.fromMap({
        'id': 'e1',
        'sender_id': kMe,
        'recipient_id': kThem,
        'type': 'lick',
        'created_at': 'not a date',
      })!;
      expect(event.createdAt.millisecondsSinceEpoch, 0);
    });

    test('a hidden question is not openable, but is still an event', () {
      final event = _forward('e1', hidden: true);
      expect(event.isForward, isTrue);
      expect(event.isOpenableForward, isFalse);
    });
  });

  group('mergeEvents', () {
    test('dedupes by id and sorts newest first', () {
      final merged = mergeEvents(
        [_lick('a', minute: 0), _lick('b', minute: 5)],
        [_lick('b', minute: 5), _lick('c', minute: 10)],
      );
      expect(merged.map((e) => e.id), ['c', 'b', 'a']);
    });

    test('ties on created_at break by id, matching the RPC ordering', () {
      final merged = mergeEvents(
        [],
        [_lick('a', minute: 3), _lick('c', minute: 3), _lick('b', minute: 3)],
      );
      expect(merged.map((e) => e.id), ['c', 'b', 'a']);
    });

    test('a Realtime row without the joined prompt does not erase a cached one', () {
      final cached = [_forward('e1', prompt: 'Is cereal a soup?')];
      final live = FriendEvent(
        id: 'e1',
        senderId: kThem,
        recipientId: kMe,
        kind: FriendEventKind.forward,
        createdAt: at(0),
        questionId: 'q1',
      );
      final merged = mergeEvents(cached, [live]);
      expect(merged.single.questionPrompt, 'Is cereal a soup?');
      expect(merged.single.questionType, 'approval_rating');
    });

    test('a fetched row fills in a prompt the live row never had', () {
      final live = [
        FriendEvent(
          id: 'e1',
          senderId: kThem,
          recipientId: kMe,
          kind: FriendEventKind.forward,
          createdAt: at(0),
          questionId: 'q1',
        )
      ];
      final merged = mergeEvents(live, [_forward('e1')]);
      expect(merged.single.questionPrompt, 'Is cereal a soup?');
    });

    test('read_at is sticky — a stale page cannot un-read an event', () {
      final stamped = [_lick('e1', readAt: at(9))];
      final merged = mergeEvents(stamped, [_lick('e1')]);
      expect(merged.single.readAt, at(9));
      expect(merged.single.isUnread, isFalse);
    });

    test('question_hidden latches on', () {
      final merged = mergeEvents(
        [_forward('e1', hidden: true)],
        [_forward('e1', hidden: false)],
      );
      expect(merged.single.questionHidden, isTrue);
    });

    test('merging an empty page leaves the cache intact', () {
      final cache = mergeEvents([], [_lick('a'), _lick('b', minute: 1)]);
      expect(mergeEvents(cache, const []).map((e) => e.id), ['b', 'a']);
    });
  });

  group('markReadLocally', () {
    test('stamps only unread events received from that friend', () {
      final events = [
        _lick('in1', from: kThem, to: kMe),
        _lick('in2', from: kThem, to: kMe, readAt: at(1)),
        _lick('out', from: kMe, to: kThem),
        _lick('other', from: kOther, to: kMe),
      ];
      final out = markReadLocally(events,
          viewerId: kMe, senderId: kThem, at: at(30));

      expect(out.firstWhere((e) => e.id == 'in1').readAt, at(30));
      expect(out.firstWhere((e) => e.id == 'in2').readAt, at(1));
      expect(out.firstWhere((e) => e.id == 'out').readAt, isNull);
      expect(out.firstWhere((e) => e.id == 'other').readAt, isNull);
    });

    test('returns the same list when nothing changed', () {
      final events = [_lick('out', from: kMe, to: kThem)];
      expect(
        markReadLocally(events, viewerId: kMe, senderId: kThem, at: at(30)),
        same(events),
      );
    });
  });

  group('buildChatEntries', () {
    test('renders oldest first and attaches reactions to their forward', () {
      final entries = buildChatEntries([
        _lick('l1', minute: 0),
        _forward('f1', minute: 5),
        _reaction('r1', target: 'f1', minute: 6),
        _reaction('r2', target: 'f1', minute: 7, emoji: '❤️'),
      ]);

      expect(entries.map((e) => e.event.id), ['l1', 'f1']);
      expect(entries.last.reactions.map((e) => e.id), ['r1', 'r2']);
      expect(entries.first.hasReactions, isFalse);
    });

    test('an orphaned reaction survives as its own row', () {
      // Its forward fell off the end of pagination; dropping it would read as
      // data loss.
      final entries = buildChatEntries([
        _reaction('r1', target: 'f-not-loaded', minute: 6),
      ]);
      expect(entries.single.event.id, 'r1');
      expect(entries.single.reactions, isEmpty);
    });

    test('a reaction pointing at a lick is not attached to it', () {
      final entries = buildChatEntries([
        _lick('l1', minute: 0),
        _reaction('r1', target: 'l1', minute: 1),
      ]);
      expect(entries.map((e) => e.event.id), ['l1', 'r1']);
      expect(entries.first.reactions, isEmpty);
    });

    test('unknown-kind rows are not drawn', () {
      final entries = buildChatEntries([
        _lick('l1'),
        FriendEvent(
          id: 'x',
          senderId: kThem,
          recipientId: kMe,
          kind: FriendEventKind.unknown,
          createdAt: at(1),
        ),
      ]);
      expect(entries.map((e) => e.event.id), ['l1']);
    });

    test('empty in, empty out', () {
      expect(buildChatEntries(const []), isEmpty);
    });
  });

  group('unread derivation', () {
    final events = [
      _lick('a', from: kThem, to: kMe),
      _forward('b', from: kThem, to: kMe),
      _lick('c', from: kThem, to: kMe, readAt: at(1)),
      _lick('d', from: kOther, to: kMe),
      _lick('e', from: kMe, to: kThem),
    ];

    test('counts only unread events the viewer received', () {
      expect(unreadFrom(events, viewerId: kMe, senderId: kThem), 2);
      expect(unreadFrom(events, viewerId: kMe, senderId: kOther), 1);
      expect(unreadFrom(events, viewerId: kThem, senderId: kMe), 1);
    });

    test('per-sender map omits senders with nothing unread', () {
      final counts = unreadCountsBySender(events, viewerId: kMe);
      expect(counts, {kThem: 2, kOther: 1});
      expect(totalUnread(counts), 3);
    });

    test('totalUnread ignores nonsense values instead of subtracting them', () {
      expect(totalUnread({'a': 2, 'b': 0, 'c': -5}), 2);
      expect(totalUnread(const {}), 0);
    });

    test('parseUnreadCounts reads the RPC shape and tolerates junk', () {
      expect(
        parseUnreadCounts([
          {'user_id': kThem, 'unread': 3},
          {'user_id': kOther, 'unread': '2'},
          {'user_id': null, 'unread': 9},
          {'unread': 9},
          {'user_id': 'zero', 'unread': 0},
          'not a row',
        ]),
        {kThem: 3, kOther: 2},
      );
      expect(parseUnreadCounts(null), isEmpty);
      expect(parseUnreadCounts('nope'), isEmpty);
    });
  });

  group('lick cooldown (OQ-2)', () {
    test('never licked → allowed', () {
      expect(lickCooldownRemaining(lastLickAt: null, now: t0), Duration.zero);
      expect(canSendLick(lastLickAt: null, now: t0), isTrue);
    });

    test('inside the window → the exact remainder', () {
      expect(
        lickCooldownRemaining(lastLickAt: t0, now: at(4)),
        const Duration(minutes: 6),
      );
      expect(canSendLick(lastLickAt: t0, now: at(4)), isFalse);
    });

    test('the boundary is allowed, not refused', () {
      expect(lickCooldownRemaining(lastLickAt: t0, now: at(10)), Duration.zero);
      expect(canSendLick(lastLickAt: t0, now: at(10)), isTrue);
      expect(canSendLick(lastLickAt: t0, now: at(11)), isTrue);
    });

    test('a future timestamp (clock skew) errs towards disabled', () {
      // Rows are stamped by Postgres, so a device clock behind the server's can
      // legitimately see "the future". Refusing is safer than a request the
      // server will reject anyway.
      expect(lickCooldownRemaining(lastLickAt: at(5), now: t0), kLickCooldown);
      expect(canSendLick(lastLickAt: at(5), now: t0), isFalse);
    });

    test('lastOutgoingLickAt finds only the viewer\'s licks to that friend', () {
      final events = [
        _lick('theirs', from: kThem, to: kMe, minute: 9),
        _lick('mine-old', from: kMe, to: kThem, minute: 1),
        _lick('mine-new', from: kMe, to: kThem, minute: 4),
        _lick('mine-elsewhere', from: kMe, to: kOther, minute: 8),
        _forward('not-a-lick', from: kMe, to: kThem, minute: 7),
      ];
      expect(
        lastOutgoingLickAt(events, viewerId: kMe, friendId: kThem),
        at(4),
      );
      expect(
        lastOutgoingLickAt(const [], viewerId: kMe, friendId: kThem),
        isNull,
      );
    });

    test('the countdown label rounds up so a disabled button never reads 0:00', () {
      expect(lickCountdownLabel(const Duration(seconds: 0)), '');
      expect(lickCountdownLabel(const Duration(milliseconds: 1)), '0:01');
      expect(lickCountdownLabel(const Duration(seconds: 59)), '0:59');
      expect(lickCountdownLabel(const Duration(seconds: 60)), '1:00');
      expect(lickCountdownLabel(const Duration(minutes: 9, seconds: 5)), '9:05');
      expect(lickCountdownLabel(kLickCooldown), '10:00');
    });
  });

  group('filterForwardCandidates', () {
    List<Map<String, dynamic>> q(List<List<String>> rows) => [
          for (final r in rows) {'id': r[0], 'prompt': r[1]},
        ];

    test('keeps input order and the first copy of each id', () {
      final out = filterForwardCandidates(q([
        ['1', 'Cereal soup?'],
        ['2', 'Best biscuit?'],
        ['1', 'Cereal soup (duplicate)'],
      ]));
      expect(out.map((e) => e['id']), ['1', '2']);
      expect(out.first['prompt'], 'Cereal soup?');
    });

    test('drops rows with no id or no prompt — including guest stubs', () {
      final out = filterForwardCandidates([
        {'id': '1', 'prompt': 'Keep me'},
        {'id': '2'},
        {'id': '3', 'prompt': '   '},
        {'prompt': 'No id'},
        {'id': '4', 'prompt': null},
      ]);
      expect(out.map((e) => e['id']), ['1']);
    });

    test('drops hidden questions the RPC would refuse anyway', () {
      final out = filterForwardCandidates([
        {'id': '1', 'prompt': 'Fine'},
        {'id': '2', 'prompt': 'Moderated', 'is_hidden': true},
      ]);
      expect(out.map((e) => e['id']), ['1']);
    });

    test('matches the query against prompt and description, case-insensitively', () {
      final rows = [
        {'id': '1', 'prompt': 'Is CEREAL a soup?'},
        {'id': '2', 'prompt': 'Best biscuit?', 'description': 'cereal adjacent'},
        {'id': '3', 'prompt': 'Unrelated'},
      ];
      expect(
        filterForwardCandidates(rows, query: 'cereal').map((e) => e['id']),
        ['1', '2'],
      );
      expect(
        filterForwardCandidates(rows, query: '  ').map((e) => e['id']),
        ['1', '2', '3'],
      );
      expect(filterForwardCandidates(rows, query: 'zzz'), isEmpty);
    });

    test('honours excludeIds and the limit', () {
      final rows = q([
        ['1', 'a'],
        ['2', 'b'],
        ['3', 'c'],
      ]);
      expect(
        filterForwardCandidates(rows, excludeIds: {'2'}).map((e) => e['id']),
        ['1', '3'],
      );
      expect(filterForwardCandidates(rows, limit: 2).length, 2);
      expect(filterForwardCandidates(const []), isEmpty);
    });
  });

  group('friendEventSummary', () {
    test('says who did what, from both sides', () {
      expect(friendEventSummary(_lick('a'), mine: false), 'Sent you a lick 🦎');
      expect(friendEventSummary(_lick('a'), mine: true), 'You sent a lick 🦎');
      expect(
        friendEventSummary(_forward('f'), mine: false),
        'Sent you Is cereal a soup?',
      );
      expect(
        friendEventSummary(_reaction('r', target: 'f'), mine: true),
        'You reacted 😂',
      );
    });

    test('a hidden forward says so instead of quoting it', () {
      expect(
        friendEventSummary(_forward('f', hidden: true), mine: false),
        'Sent you a question that is no longer available',
      );
    });

    test('a forward with no prompt loaded still reads as a sentence', () {
      expect(
        friendEventSummary(_forward('f', prompt: null), mine: false),
        'Sent you a question',
      );
    });

    test('an unknown kind has nothing to say', () {
      final event = FriendEvent(
        id: 'x',
        senderId: kMe,
        recipientId: kThem,
        kind: FriendEventKind.unknown,
        createdAt: t0,
      );
      expect(friendEventSummary(event, mine: true), '');
    });
  });
}
