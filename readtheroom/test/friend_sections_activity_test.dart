import 'package:flutter_test/flutter_test.dart';
import 'package:read_the_room/src/utils/friend_logic.dart';

Friend _f(String id, {bool close = false, bool mutual = false, DateTime? at}) =>
    Friend(
        userId: id,
        username: id,
        status: FriendStatus.accepted,
        isClose: close,
        mutualClose: mutual,
        lastEventAt: at);

void main() {
  test('friends order: close first, latest chat first, no-chat last', () {
    final t = DateTime(2026, 9, 22, 12);
    final s = partitionFriends([
      _f('quiet_close', close: true),
      _f('old_close', close: true, at: t.subtract(const Duration(days: 3))),
      _f('fresh_close', close: true, at: t),
      _f('zed'),
      _f('amy', at: t.subtract(const Duration(hours: 1))),
      _f('bob', at: t.subtract(const Duration(minutes: 5))),
    ], viewerId: 'me');
    expect(s.allAccepted.map((f) => f.userId).toList(), [
      'fresh_close',
      'old_close',
      'quiet_close',
      'bob',
      'amy',
      'zed',
    ]);
  });

  test('close friends: mutual first, then one-sided, each by activity', () {
    final t = DateTime(2026, 9, 23, 12);
    final s = partitionFriends([
      _f('one_sided_fresh', close: true, at: t),
      _f('mutual_quiet', close: true, mutual: true),
      _f('one_sided_quiet', close: true),
      _f('mutual_old', close: true, mutual: true,
          at: t.subtract(const Duration(days: 2))),
      _f('regular_fresh', at: t),
    ], viewerId: 'me');
    expect(s.allAccepted.map((f) => f.userId).toList(), [
      'mutual_old',
      'mutual_quiet',
      'one_sided_fresh',
      'one_sided_quiet',
      'regular_fresh',
    ]);
  });

  test('last_event_at parses and survives copyWith', () {
    final f = Friend.fromMap({
      'user_id': 'u1',
      'username': 'u1',
      'status': 'accepted',
      'last_event_at': '2026-09-22T10:00:00Z',
    })!;
    expect(f.lastEventAt, DateTime.utc(2026, 9, 22, 10));
    expect(f.copyWith(muted: true).lastEventAt, f.lastEventAt);
    expect(Friend.fromMap({'user_id': 'u2', 'status': 'accepted'})!.lastEventAt,
        isNull);
  });
}
