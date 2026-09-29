// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../utils/friend_nickname_logic.dart';

/// Private, on-device nicknames for friends (owner request 2026-09-28).
///
/// Nothing here touches the server. Nicknames are cached in memory and
/// persisted to SharedPreferences under a per-account key, keyed by the
/// friend's user id so a username change never loses one. Removing a friend
/// keeps the nickname, so re-adding them brings it back.
///
/// Read it only from the friend list and the chat overlay. See
/// `friend_nickname_logic.dart` for why the network graphs and answer reveals
/// must not use it.
class FriendNicknameService extends ChangeNotifier {
  FriendNicknameService({
    String? Function()? viewerId,
    bool listenToAuth = true,
  }) : _viewerIdOverride = viewerId {
    if (listenToAuth) _subscribeToAuth();
  }

  /// The provider when one is registered, else null. Widget tests and
  /// surfaces outside the app shell render without nicknames.
  static FriendNicknameService? maybeOf(BuildContext context,
      {bool listen = true}) {
    try {
      return Provider.of<FriendNicknameService>(context, listen: listen);
    } on ProviderNotFoundException {
      return null;
    }
  }

  final String? Function()? _viewerIdOverride;
  StreamSubscription<AuthState>? _authSubscription;

  Map<String, String> _nicknames = {};
  String? _storageKey;
  Future<void>? _loading;

  String? get _viewerId {
    if (_viewerIdOverride != null) return _viewerIdOverride();
    try {
      return Supabase.instance.client.auth.currentUser?.id;
    } catch (_) {
      return null;
    }
  }

  /// The stored nickname for [friendId], or null.
  String? nicknameFor(String friendId) => _nicknames[friendId];

  /// Loads the current account's nicknames. Safe to call repeatedly.
  Future<void> load() {
    final key = friendNicknameStorageKey(_viewerId);
    if (key == _storageKey && _loading != null) return _loading!;
    _storageKey = key;
    return _loading = _read(key);
  }

  Future<void> _read(String key) async {
    Map<String, String> loaded = {};
    try {
      final prefs = await SharedPreferences.getInstance();
      loaded = decodeFriendNicknames(prefs.getString(key));
    } catch (e) {
      debugPrint('FriendNicknameService.load failed: $e');
    }
    // A sign-out or account switch during the read wins.
    if (key != _storageKey) return;
    _nicknames = loaded;
    notifyListeners();
  }

  /// Saves [raw] as [friendId]'s nickname, or removes it when [raw] is empty.
  /// Returns the stored value (null when removed).
  Future<String?> setNickname(String friendId, String? raw) async {
    await load();
    final name = normalizeFriendNickname(raw);
    final next = Map<String, String>.from(_nicknames);
    if (name == null) {
      next.remove(friendId);
    } else {
      next[friendId] = name;
    }
    _nicknames = next;
    notifyListeners();

    final key = _storageKey!;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (next.isEmpty) {
        await prefs.remove(key);
      } else {
        await prefs.setString(key, encodeFriendNicknames(next));
      }
    } catch (e) {
      debugPrint('FriendNicknameService.setNickname failed: $e');
    }
    return name;
  }

  void _clear() {
    _storageKey = null;
    _loading = null;
    if (_nicknames.isEmpty) return;
    _nicknames = {};
    notifyListeners();
  }

  void _subscribeToAuth() {
    try {
      _authSubscription =
          Supabase.instance.client.auth.onAuthStateChange.listen((state) {
        switch (state.event) {
          case AuthChangeEvent.signedIn:
          case AuthChangeEvent.initialSession:
            unawaited(load());
            break;
          case AuthChangeEvent.signedOut:
            _clear();
            break;
          default:
            break;
        }
      });
    } catch (e) {
      debugPrint('FriendNicknameService auth subscription unavailable: $e');
    }
  }

  @override
  void dispose() {
    _authSubscription?.cancel();
    super.dispose();
  }
}
