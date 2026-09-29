// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter_test/flutter_test.dart';
import 'package:read_the_room/src/utils/profile_cache.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('ProfileCacheEntry', () {
    test('round-trips handle, avatar and cooldown timestamp', () {
      final entry = ProfileCacheEntry(
        uid: 'u1',
        username: 'veiled_tail7',
        avatarId: 'chameleon_04',
        usernameUpdatedAt: DateTime.utc(2026, 9, 17, 0, 44, 26),
      );
      final back = ProfileCacheEntry.decode(entry.encode(), forUid: 'u1')!;
      expect(back.username, 'veiled_tail7');
      expect(back.avatarId, 'chameleon_04');
      expect(back.usernameUpdatedAt, DateTime.utc(2026, 9, 17, 0, 44, 26));
    });

    test('ignores an entry that belongs to another account', () {
      const entry = ProfileCacheEntry(uid: 'u1', username: 'someone');
      expect(ProfileCacheEntry.decode(entry.encode(), forUid: 'u2'), isNull);
    });

    test('treats missing or malformed data as no cache', () {
      expect(ProfileCacheEntry.decode(null, forUid: 'u1'), isNull);
      expect(ProfileCacheEntry.decode('', forUid: 'u1'), isNull);
      expect(ProfileCacheEntry.decode('not json', forUid: 'u1'), isNull);
      expect(ProfileCacheEntry.decode('[1,2]', forUid: 'u1'), isNull);
    });

    test('isEmpty only when there is neither a handle nor an avatar', () {
      expect(const ProfileCacheEntry(uid: 'u1').isEmpty, isTrue);
      expect(const ProfileCacheEntry(uid: 'u1', avatarId: 'chameleon_01').isEmpty,
          isFalse);
      expect(const ProfileCacheEntry(uid: 'u1', username: 'abc').isEmpty,
          isFalse);
    });
  });

  group('ProfileCache storage', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('write then read for the same uid', () async {
      await ProfileCache.write(const ProfileCacheEntry(
          uid: 'u1', username: 'abc', avatarId: 'chameleon_02'));
      final read = await ProfileCache.read('u1');
      expect(read?.username, 'abc');
      expect(read?.avatarId, 'chameleon_02');
      expect(await ProfileCache.read('u2'), isNull);
    });

    test('writing an empty profile removes the cache', () async {
      await ProfileCache.write(
          const ProfileCacheEntry(uid: 'u1', username: 'abc'));
      await ProfileCache.write(const ProfileCacheEntry(uid: 'u1'));
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey(ProfileCache.key), isFalse);
    });

    test('clear removes the cache', () async {
      await ProfileCache.write(
          const ProfileCacheEntry(uid: 'u1', username: 'abc'));
      await ProfileCache.clear();
      expect(await ProfileCache.read('u1'), isNull);
    });
  });

  group('profileRetryDelay', () {
    test('backs off, then settles at five minutes', () {
      expect(profileRetryDelay(1), const Duration(seconds: 5));
      expect(profileRetryDelay(2), const Duration(seconds: 15));
      expect(profileRetryDelay(5), const Duration(minutes: 2));
      expect(profileRetryDelay(6), const Duration(minutes: 5));
      expect(profileRetryDelay(50), const Duration(minutes: 5));
      expect(profileRetryDelay(0), const Duration(seconds: 5));
    });
  });
}
