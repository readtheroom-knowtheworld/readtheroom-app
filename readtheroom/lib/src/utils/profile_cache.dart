// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Last known server profile (handle + avatar) for one signed-in user.
///
/// Written after every successful `get_my_profile` / `set_username` /
/// `set_avatar`, read before every profile fetch, so a failed or slow fetch
/// shows the last good values instead of an empty profile that looks like a
/// reset (2026-09-28 incident: a background-launch fetch failed and the app
/// showed no name or avatar for ~10 hours).
///
/// Keyed by auth uid: an entry for a different account is ignored, so a
/// device that switches accounts never shows the previous user's handle.
class ProfileCacheEntry {
  final String uid;
  final String? username;
  final String? avatarId;
  final DateTime? usernameUpdatedAt;

  const ProfileCacheEntry({
    required this.uid,
    this.username,
    this.avatarId,
    this.usernameUpdatedAt,
  });

  bool get isEmpty =>
      (username ?? '').isEmpty && (avatarId ?? '').isEmpty;

  String encode() => jsonEncode({
        'uid': uid,
        'username': username,
        'avatar_id': avatarId,
        'username_updated_at': usernameUpdatedAt?.toUtc().toIso8601String(),
      });

  /// Parses [raw]; `null` when it is missing, malformed, or belongs to
  /// another user than [forUid].
  static ProfileCacheEntry? decode(String? raw, {required String forUid}) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final map = jsonDecode(raw);
      if (map is! Map || map['uid'] != forUid) return null;
      final updatedAt = map['username_updated_at'];
      return ProfileCacheEntry(
        uid: forUid,
        username: map['username'] as String?,
        avatarId: map['avatar_id'] as String?,
        usernameUpdatedAt:
            updatedAt is String ? DateTime.tryParse(updatedAt) : null,
      );
    } catch (_) {
      return null;
    }
  }
}

/// SharedPreferences storage for [ProfileCacheEntry]. One entry per device:
/// only the current account's profile is ever worth keeping.
class ProfileCache {
  static const String key = 'profile_cache_v1';

  static Future<ProfileCacheEntry?> read(String uid) async {
    final prefs = await SharedPreferences.getInstance();
    return ProfileCacheEntry.decode(prefs.getString(key), forUid: uid);
  }

  /// Stores [entry], or removes the cache when it holds nothing worth showing.
  static Future<void> write(ProfileCacheEntry entry) async {
    final prefs = await SharedPreferences.getInstance();
    if (entry.isEmpty) {
      await prefs.remove(key);
    } else {
      await prefs.setString(key, entry.encode());
    }
  }

  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(key);
  }
}

/// Delay before retry number [attempt] (1-based) of a failed profile fetch:
/// 5s, 15s, 30s, 60s, 2m, then every 5m while the fetch keeps failing.
Duration profileRetryDelay(int attempt) {
  const schedule = [5, 15, 30, 60, 120];
  if (attempt < 1) return Duration(seconds: schedule.first);
  if (attempt > schedule.length) return const Duration(minutes: 5);
  return Duration(seconds: schedule[attempt - 1]);
}
