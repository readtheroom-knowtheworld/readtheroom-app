// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Pure friend-graph logic (WP-E): the status machine, Community-tab
// partitioning, mutual-close derivation, friend-link parsing and QR token
// expiry. No Flutter, no Supabase — these are the rules the Community tab and
// FriendService depend on, tested without either.

import 'package:flutter_test/flutter_test.dart';
import 'package:read_the_room/src/utils/friend_logic.dart';

const String kMe = 'me-uuid';
const String kThem = 'them-uuid';

Friend _accepted(
  String id, {
  String? handle,
  bool isClose = false,
  bool mutualClose = false,
  bool muted = false,
  int? streak,
  DateTime? createdAt,
}) =>
    Friend(
      userId: id,
      username: handle ?? id,
      status: FriendStatus.accepted,
      isClose: isClose,
      mutualClose: mutualClose,
      muted: muted,
      streak: streak,
      createdAt: createdAt,
    );

/// A pending row as the *recipient* sees it: the sender is the other party, so
/// `requested_by` is their id.
Friend _incoming(String id, {DateTime? createdAt}) => Friend(
      userId: id,
      username: id,
      status: FriendStatus.pending,
      requestedBy: id,
      createdAt: createdAt,
    );

/// A pending row as the *sender* sees it: `requested_by` is the viewer.
Friend _outgoing(String id, {DateTime? createdAt}) => Friend(
      userId: id,
      username: id,
      status: FriendStatus.pending,
      requestedBy: kMe,
      createdAt: createdAt,
    );

void main() {
  group('Friend.fromMap — the get_friends() contract', () {
    test('parses a full accepted row', () {
      final friend = Friend.fromMap({
        'user_id': kThem,
        'username': 'basil_basks',
        'avatar_id': 'chameleon_03',
        'status': 'accepted',
        'is_close': true,
        'mutual_close': true,
        'muted': false,
        'requested_by': kMe,
        'streak': 12,
        'created_at': '2026-09-01T10:00:00Z',
      });

      expect(friend, isNotNull);
      expect(friend!.userId, kThem);
      expect(friend.username, 'basil_basks');
      expect(friend.avatarId, 'chameleon_03');
      expect(friend.status, FriendStatus.accepted);
      expect(friend.isClose, isTrue);
      expect(friend.mutualClose, isTrue);
      expect(friend.streak, 12);
      expect(friend.displayHandle, '@basil_basks');
      expect(friend.createdAt, isNotNull);
    });

    test('a row without a user_id is dropped, not thrown on', () {
      expect(Friend.fromMap(const {'username': 'nobody'}), isNull);
      expect(Friend.fromMap(const {'user_id': ''}), isNull);
    });

    test('a handle-less friend degrades to a neutral label', () {
      final friend = Friend.fromMap({'user_id': kThem, 'status': 'accepted'});
      expect(friend!.username, isNull);
      expect(friend.displayHandle, 'A chameleon');
    });

    test('an unknown status round-trips instead of throwing', () {
      final friend =
          Friend.fromMap({'user_id': kThem, 'status': 'something_new'});
      expect(friend!.status, FriendStatus.unknown);
    });

    test('the string "null" is treated as absent', () {
      final friend = Friend.fromMap({
        'user_id': kThem,
        'username': 'null',
        'requested_by': 'null',
      });
      expect(friend!.username, isNull);
      expect(friend.requestedBy, isNull);
    });
  });

  group('request direction', () {
    test('requested_by == the other party => incoming', () {
      final f = _incoming(kThem);
      expect(f.isIncomingRequest, isTrue);
      expect(f.isOutgoingRequest, isFalse);
    });

    test('requested_by == the viewer => outgoing', () {
      final f = _outgoing(kThem);
      expect(f.isOutgoingRequest, isTrue);
      expect(f.isIncomingRequest, isFalse);
    });

    test('an accepted row is neither', () {
      final f = _accepted(kThem);
      expect(f.isIncomingRequest, isFalse);
      expect(f.isOutgoingRequest, isFalse);
    });

    test('a pending row with no requested_by falls back to outgoing', () {
      // Should be impossible (send_friend_request always stamps it), but
      // offering "cancel" is safer than offering "accept" on a request the
      // viewer may have sent.
      const f = Friend(userId: kThem, status: FriendStatus.pending);
      expect(f.isOutgoingRequest, isTrue);
      expect(f.isIncomingRequest, isFalse);
    });
  });

  group('partitionFriends — the §5.3 sections', () {
    test('splits pending in/out, close and regular friends', () {
      final sections = partitionFriends([
        _incoming('a'),
        _outgoing('b'),
        _accepted('c', isClose: true),
        _accepted('d'),
      ], viewerId: kMe);

      expect(sections.incoming.map((f) => f.userId), ['a']);
      expect(sections.outgoing.map((f) => f.userId), ['b']);
      expect(sections.closeFriends.map((f) => f.userId), ['c']);
      expect(sections.friends.map((f) => f.userId), ['d']);
      expect(sections.acceptedCount, 2);
      expect(sections.pendingCount, 2);
      expect(sections.isEmpty, isFalse);
    });

    test('an empty graph is the empty state', () {
      final sections = partitionFriends(const [], viewerId: kMe);
      expect(sections.isEmpty, isTrue);
      expect(sections.allAccepted, isEmpty);
    });

    test('blocked and unknown rows never reach the UI', () {
      final sections = partitionFriends([
        const Friend(userId: 'blocked', status: FriendStatus.blocked),
        const Friend(userId: 'weird', status: FriendStatus.unknown),
        _accepted('ok'),
      ], viewerId: kMe);

      expect(sections.acceptedCount, 1);
      expect(sections.pendingCount, 0);
      expect(sections.friends.single.userId, 'ok');
    });

    test('a self-row is dropped', () {
      final sections =
          partitionFriends([_accepted(kMe), _accepted(kThem)], viewerId: kMe);
      expect(sections.friends.map((f) => f.userId), [kThem]);
    });

    test('duplicate user_ids collapse to one row', () {
      final sections = partitionFriends([
        _accepted(kThem, handle: 'old'),
        _accepted(kThem, handle: 'new'),
      ], viewerId: kMe);
      expect(sections.acceptedCount, 1);
      expect(sections.friends.single.username, 'new');
    });

    test('friends sort by handle, case-insensitively, handle-less last', () {
      final sections = partitionFriends([
        _accepted('3', handle: 'zoe'),
        _accepted('1', handle: 'Alice'),
        const Friend(userId: '4', status: FriendStatus.accepted),
        _accepted('2', handle: 'bob'),
      ], viewerId: kMe);

      expect(
        sections.friends.map((f) => f.username).toList(),
        ['Alice', 'bob', 'zoe', null],
      );
    });

    test('pending rows sort newest first', () {
      final sections = partitionFriends([
        _incoming('older', createdAt: DateTime.utc(2026, 1, 1)),
        _incoming('newer', createdAt: DateTime.utc(2026, 9, 1)),
      ], viewerId: kMe);

      expect(sections.incoming.map((f) => f.userId), ['newer', 'older']);
    });

    test('allAccepted puts close friends first', () {
      final sections = partitionFriends([
        _accepted('zzz_regular', handle: 'zzz_regular'),
        _accepted('aaa_close', handle: 'aaa_close', isClose: true),
      ], viewerId: kMe);

      expect(
        sections.allAccepted.map((f) => f.userId),
        ['aaa_close', 'zzz_regular'],
      );
    });

    test('a null viewerId still partitions (pre-auth render)', () {
      final sections = partitionFriends([_accepted(kThem)], viewerId: null);
      expect(sections.acceptedCount, 1);
    });
  });

  group('newlyAcceptedQrFriends — the scanned phone finds out', () {
    test('a QR pair that appears between two loads is announced', () {
      final before = [_accepted('old')];
      final after = [_accepted('old'), _accepted('new')];
      expect(
        newlyAcceptedQrFriends(before, after).map((f) => f.userId),
        ['new'],
      );
    });

    test('an accepted request is not a QR add (requested_by is set)', () {
      final before = [_incoming('asker')];
      final after = [
        Friend(
          userId: 'asker',
          username: 'asker',
          status: FriendStatus.accepted,
          requestedBy: 'asker',
        ),
      ];
      expect(newlyAcceptedQrFriends(before, after), isEmpty);
    });

    test('friends already accepted last time are not announced again', () {
      final graph = [_accepted('a'), _accepted('b')];
      expect(newlyAcceptedQrFriends(graph, graph), isEmpty);
    });

    test('a pending row that was there before still counts once accepted', () {
      // A pending pair with no requester (a race with the QR RPC) becoming
      // accepted is the transition that matters, not the row's existence.
      final before = [
        Friend(userId: 'p', username: 'p', status: FriendStatus.pending),
      ];
      final after = [_accepted('p')];
      expect(newlyAcceptedQrFriends(before, after).length, 1);
    });
  });

  group('mutual close', () {
    test('one-sided close is close for the viewer but not mutual', () {
      final f = _accepted(kThem, isClose: true);
      expect(f.isClose, isTrue);
      expect(f.mutualClose, isFalse);
    });

    test('unsetting close also drops the mutual flag', () {
      final f = _accepted(kThem, isClose: true, mutualClose: true);
      final after = applyAction(f, FriendAction.unsetClose)!;
      expect(after.isClose, isFalse);
      // Reciprocity cannot survive one side dropping out.
      expect(after.mutualClose, isFalse);
    });

    test('setting close does not presume reciprocity', () {
      final after = applyAction(_accepted(kThem), FriendAction.setClose)!;
      expect(after.isClose, isTrue);
      expect(after.mutualClose, isFalse);
    });
  });

  group('availableActions — the status machine', () {
    test('an incoming request offers accept / decline / block only', () {
      expect(
        availableActions(_incoming(kThem)),
        {FriendAction.accept, FriendAction.decline, FriendAction.block},
      );
    });

    test('an outgoing request offers cancel / block only', () {
      expect(
        availableActions(_outgoing(kThem)),
        {FriendAction.cancelRequest, FriendAction.block},
      );
    });

    test('a pending row never offers close', () {
      for (final f in [_incoming(kThem), _outgoing(kThem)]) {
        final actions = availableActions(f);
        expect(actions.contains(FriendAction.setClose), isFalse);
        expect(actions.contains(FriendAction.setNickname), isFalse);
        expect(actions.contains(FriendAction.unfriend), isFalse);
      }
    });

    test(
        'an accepted friend offers nickname/close/unfriend/block '
        '(no per-friend mute)', () {
      expect(
        availableActions(_accepted(kThem)),
        {
          FriendAction.setNickname,
          FriendAction.setClose,
          FriendAction.unfriend,
          FriendAction.block,
        },
      );
    });

    test('the close entry is the toggle-off when already set', () {
      final actions =
          availableActions(_accepted(kThem, isClose: true, muted: true));
      expect(actions.contains(FriendAction.unsetClose), isTrue);
      expect(actions.contains(FriendAction.setClose), isFalse);
    });

    test('a blocked row offers nothing', () {
      expect(
        availableActions(
            const Friend(userId: kThem, status: FriendStatus.blocked)),
        isEmpty,
      );
    });
  });

  group('applyAction — optimistic transitions', () {
    test('accept flips the row to accepted', () {
      final after = applyAction(_incoming(kThem), FriendAction.accept)!;
      expect(after.status, FriendStatus.accepted);
      expect(after.isAccepted, isTrue);
    });

    test('every removing action drops the row', () {
      for (final action in [
        FriendAction.decline,
        FriendAction.cancelRequest,
        FriendAction.unfriend,
        FriendAction.block,
      ]) {
        expect(applyAction(_accepted(kThem), action), isNull,
            reason: '$action should remove the row');
      }
    });

    test('an accepted row survives a full accept -> close -> unfriend walk',
        () {
      var f = _incoming(kThem);
      f = applyAction(f, FriendAction.accept)!;
      f = applyAction(f, FriendAction.setClose)!;
      expect(f.isClose, isTrue);
      expect(applyAction(f, FriendAction.unfriend), isNull);
    });
  });

  group('friend link / QR token', () {
    const token = '0123456789abcdef0123456789abcdef';

    test('validates the exact 32-hex shape the RPC mints', () {
      expect(isValidFriendToken(token), isTrue);
      expect(isValidFriendToken(null), isFalse);
      expect(isValidFriendToken(''), isFalse);
      expect(isValidFriendToken('short'), isFalse);
      // 31 and 33 chars.
      expect(isValidFriendToken(token.substring(1)), isFalse);
      expect(isValidFriendToken('${token}a'), isFalse);
      // Uppercase hex and non-hex characters.
      expect(isValidFriendToken(token.toUpperCase()), isFalse);
      expect(isValidFriendToken('g' * 32), isFalse);
    });

    test('builds the app link and the custom-scheme fallback', () {
      expect(friendLinkForToken(token),
          'https://readtheroom.site/friend/$token');
      expect(friendFallbackLinkForToken(token), 'readtheroom://friend/$token');
    });

    test('parses every accepted form', () {
      expect(parseFriendToken('https://readtheroom.site/friend/$token'), token);
      expect(parseFriendToken('http://readtheroom.site/friend/$token'), token);
      expect(parseFriendToken('readtheroom://friend/$token'), token);
      // A bare payload, for scanners that hand back raw text.
      expect(parseFriendToken(token), token);
      // Whitespace and case are normalised.
      expect(parseFriendToken('  ${token.toUpperCase()}  '), token);
      expect(
        parseFriendToken('https://readtheroom.site/friend/${token.toUpperCase()}'),
        token,
      );
    });

    test('round-trips its own generated links', () {
      expect(parseFriendToken(friendLinkForToken(token)), token);
      expect(parseFriendToken(friendFallbackLinkForToken(token)), token);
    });

    test('rejects anything that is not a friend link', () {
      expect(parseFriendToken(null), isNull);
      expect(parseFriendToken(''), isNull);
      expect(parseFriendToken('   '), isNull);
      // Another app's QR.
      expect(parseFriendToken('https://example.com/hello'), isNull);
      // A well-formed friend path on any other host is not ours.
      expect(parseFriendToken('https://example.com/friend/$token'), isNull);
      expect(
        parseFriendToken('https://readtheroom.site.evil.test/friend/$token'),
        isNull,
      );
      expect(parseFriendToken('ftp://readtheroom.site/friend/$token'), isNull);
      expect(parseFriendToken('https://www.readtheroom.site/friend/$token'),
          token);
      // Our own question link must NOT be claimed as a friend link.
      expect(
        parseFriendToken('https://readtheroom.site/question/$token'),
        isNull,
      );
      expect(parseFriendToken('readtheroom://question/$token'), isNull);
      // Right path, malformed token — never reaches the RPC.
      expect(parseFriendToken('https://readtheroom.site/friend/nope'), isNull);
      expect(parseFriendToken('readtheroom://friend/nope'), isNull);
      // Path with no token at all.
      expect(parseFriendToken('https://readtheroom.site/friend'), isNull);
      expect(parseFriendToken('readtheroom://friend'), isNull);
    });

    test('isFriendLink agrees with parseFriendToken', () {
      expect(isFriendLink(Uri.parse(friendLinkForToken(token))), isTrue);
      expect(
        isFriendLink(Uri.parse('https://readtheroom.site/question/$token')),
        isFalse,
      );
    });
  });

  group('QR token expiry', () {
    const token = '0123456789abcdef0123456789abcdef';
    final now = DateTime.utc(2026, 9, 11, 12, 0);

    test('a fresh token is not rotated', () {
      expect(
        shouldRotateQrToken(
          token: token,
          expiresAt: now.add(const Duration(hours: 23)),
          now: now,
        ),
        isFalse,
      );
    });

    test('an expired token is rotated', () {
      expect(
        shouldRotateQrToken(
          token: token,
          expiresAt: now.subtract(const Duration(minutes: 1)),
          now: now,
        ),
        isTrue,
      );
    });

    test('a token inside the refresh margin is rotated before display', () {
      // Never put a code on screen that dies while someone is scanning it.
      expect(
        shouldRotateQrToken(
          token: token,
          expiresAt: now.add(const Duration(minutes: 4)),
          now: now,
        ),
        isTrue,
      );
      expect(
        shouldRotateQrToken(
          token: token,
          expiresAt: now.add(const Duration(minutes: 6)),
          now: now,
        ),
        isFalse,
      );
    });

    test('a missing or malformed token is always rotated', () {
      expect(
        shouldRotateQrToken(token: null, expiresAt: null, now: now),
        isTrue,
      );
      expect(
        shouldRotateQrToken(
          token: 'not-a-token',
          expiresAt: now.add(const Duration(hours: 5)),
          now: now,
        ),
        isTrue,
      );
      // A valid token with no known expiry cannot be trusted either.
      expect(
        shouldRotateQrToken(token: token, expiresAt: null, now: now),
        isTrue,
      );
    });
  });

  group('streak flair (OQ-3)', () {
    test('shows only for a positive streak', () {
      expect(_accepted(kThem, streak: 5).hasStreakFlair, isTrue);
      expect(_accepted(kThem, streak: 0).hasStreakFlair, isFalse);
      expect(_accepted(kThem).hasStreakFlair, isFalse);
    });
  });
}
