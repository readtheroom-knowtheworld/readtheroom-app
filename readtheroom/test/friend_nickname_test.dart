// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Private friend nicknames (owner request 2026-09-28): on-device only, keyed
// by the friend's user id, per signed-in account.

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:read_the_room/src/services/friend_nickname_service.dart';
import 'package:read_the_room/src/utils/friend_nickname_logic.dart';

void main() {
  group('normalizeFriendNickname', () {
    test('trims and collapses whitespace', () {
      expect(normalizeFriendNickname('  Big \n  Sis  '), 'Big Sis');
    });

    test('blank means no nickname', () {
      expect(normalizeFriendNickname(null), isNull);
      expect(normalizeFriendNickname('   '), isNull);
    });

    test('caps the length without splitting an emoji', () {
      final long = '${'a' * (kFriendNicknameMaxLength - 1)}🦎🦎🦎';
      final out = normalizeFriendNickname(long)!;
      expect(out, '${'a' * (kFriendNicknameMaxLength - 1)}🦎');
    });
  });

  group('visibleFriendNickname', () {
    test('hidden when it just repeats the current username', () {
      expect(visibleFriendNickname('Sam', username: 'sam'), isNull);
      expect(visibleFriendNickname('@sam', username: 'sam'), isNull);
    });

    test('shown once the username differs', () {
      expect(visibleFriendNickname('Sam', username: 'sam_2026'), 'Sam');
      expect(visibleFriendNickname('Sam', username: null), 'Sam');
    });
  });

  group('storage', () {
    test('keys are per account', () {
      expect(friendNicknameStorageKey('abc'), 'friend_nicknames_v1_abc');
      expect(friendNicknameStorageKey(null), 'friend_nicknames_v1_guest');
    });

    test('decode tolerates junk', () {
      expect(decodeFriendNicknames('not json'), isEmpty);
      expect(decodeFriendNicknames('[1,2]'), isEmpty);
      expect(decodeFriendNicknames('{"a":"  Mo ","b":3,"c":"  "}'), {'a': 'Mo'});
    });
  });

  group('FriendNicknameService', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('persists and reloads for the same account', () async {
      final first = FriendNicknameService(
          viewerId: () => 'me', listenToAuth: false);
      await first.setNickname('friend-1', ' Roomie ');

      final second = FriendNicknameService(
          viewerId: () => 'me', listenToAuth: false);
      await second.load();
      expect(second.nicknameFor('friend-1'), 'Roomie');
    });

    test('another account on the same device sees none', () async {
      await FriendNicknameService(viewerId: () => 'me', listenToAuth: false)
          .setNickname('friend-1', 'Roomie');

      final other = FriendNicknameService(
          viewerId: () => 'someone-else', listenToAuth: false);
      await other.load();
      expect(other.nicknameFor('friend-1'), isNull);
    });

    test('an empty value removes it', () async {
      final store = FriendNicknameService(
          viewerId: () => 'me', listenToAuth: false);
      await store.setNickname('friend-1', 'Roomie');
      expect(await store.setNickname('friend-1', '  '), isNull);
      expect(store.nicknameFor('friend-1'), isNull);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(friendNicknameStorageKey('me')), isNull);
    });

    test('notifies listeners so both surfaces repaint', () async {
      final store = FriendNicknameService(
          viewerId: () => 'me', listenToAuth: false);
      await store.load();
      var ticks = 0;
      store.addListener(() => ticks++);
      await store.setNickname('friend-1', 'Roomie');
      expect(ticks, greaterThan(0));
    });
  });
}
