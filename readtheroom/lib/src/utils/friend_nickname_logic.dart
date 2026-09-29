// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Pure rules for friend nicknames (owner request 2026-09-28).
///
/// A nickname is a private label the viewer gives a friend. It lives only on
/// this device, keyed by the friend's user id rather than their username, so
/// it survives the friend changing their handle.
///
/// It appears in the Community tab's friend list and the chat overlay only.
/// It is deliberately never shown on the network graphs or anywhere an answer
/// is revealed: those surfaces render the friend's own handle, because a
/// private label there would read as the friend's identity.
library;

import 'dart:convert';

import 'package:characters/characters.dart';

/// Longest nickname kept, in user-perceived characters (an emoji counts once).
const int kFriendNicknameMaxLength = 24;

/// Trims, collapses inner whitespace and caps the length. Returns null when
/// nothing is left, which means "no nickname".
String? normalizeFriendNickname(String? raw) {
  if (raw == null) return null;
  final collapsed = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (collapsed.isEmpty) return null;
  final chars = collapsed.characters;
  if (chars.length <= kFriendNicknameMaxLength) return collapsed;
  return chars.take(kFriendNicknameMaxLength).toString().trimRight();
}

/// The nickname to draw beside the handle, or null when it would add nothing.
///
/// A nickname identical to the friend's current username is hidden rather than
/// deleted: "@sam (sam)" is noise today, but it becomes useful the moment Sam
/// renames themselves.
String? visibleFriendNickname(String? nickname, {String? username}) {
  final name = normalizeFriendNickname(nickname);
  if (name == null) return null;
  final handle = (username ?? '').trim().toLowerCase();
  if (handle.isNotEmpty &&
      name.toLowerCase().replaceFirst(RegExp('^@'), '') == handle) {
    return null;
  }
  return name;
}

/// SharedPreferences key. Per signed-in account, so two people sharing a
/// device never see each other's labels.
String friendNicknameStorageKey(String? viewerId) =>
    'friend_nicknames_v1_${(viewerId == null || viewerId.isEmpty) ? 'guest' : viewerId}';

/// Reads the stored map, dropping anything malformed instead of throwing.
Map<String, String> decodeFriendNicknames(String? raw) {
  if (raw == null || raw.isEmpty) return {};
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return {};
    final out = <String, String>{};
    decoded.forEach((key, value) {
      final name = value is String ? normalizeFriendNickname(value) : null;
      if (key is String && key.isNotEmpty && name != null) out[key] = name;
    });
    return out;
  } catch (_) {
    return {};
  }
}

String encodeFriendNicknames(Map<String, String> nicknames) =>
    jsonEncode(nicknames);
