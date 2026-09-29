// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Debug-only "Demo friends" gate (see
/// `feature-documentation/demo-friends-mode-2026-09-11.md`).
///
/// When enabled, `main.dart` registers [DemoFriendService] /
/// [DemoFriendChatService] / [DemoProfileService] instead of the real ones, so
/// the Community tab and the friend chat overlay can be exercised on a
/// simulator with **no backend deployed at all**.
///
/// ## Release safety
///
/// The flag is clamped by [kDebugMode] in *two* independent places:
///
///   * [enabled] ANDs the stored value with [_debugMode], so even a
///     SharedPreferences entry written by a debug build (or hand-edited on a
///     jailbroken device) reads back as `false` in a release build;
///   * [setEnabled] refuses to write at all outside debug, so a release build
///     cannot even persist the intent.
///
/// [_debugMode] is injectable purely so the release behaviour is unit-testable;
/// production code always uses the real [kDebugMode] constant. Because
/// [kDebugMode] is a compile-time constant, the demo services are also
/// tree-shaken out of a release binary — nothing reachable constructs them.
///
/// The toggle itself is only *built* when [kDebugMode] (settings_screen.dart's
/// "Developer" section), so there is no release-mode UI for it either.
class DemoFriendsMode extends ChangeNotifier {
  DemoFriendsMode({bool debugMode = kDebugMode}) : _debugMode = debugMode;

  /// The app-wide instance. A plain singleton rather than a provider because
  /// `main.dart` has to read it *before* `runApp` in order to decide which
  /// services to register, and the settings toggle has to reach the same
  /// object afterwards.
  static final DemoFriendsMode instance = DemoFriendsMode();

  static const String prefsKey = 'demo_friends_mode';

  final bool _debugMode;

  bool _stored = false;
  bool _loaded = false;

  /// Whether the demo graph is in force. Always false outside debug builds.
  bool get enabled => _debugMode && _stored;

  /// Whether the toggle may be shown/used at all.
  bool get isAvailable => _debugMode;

  /// True once [load] has completed (success or not).
  bool get isLoaded => _loaded;

  /// Reads the persisted flag. Safe to call repeatedly and before `runApp`.
  Future<void> load() async {
    if (!_debugMode) {
      // Nothing to read: the value can never be true here, and touching
      // SharedPreferences for it would only risk an exception in release.
      _loaded = true;
      return;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      _stored = prefs.getBool(prefsKey) ?? false;
    } catch (e) {
      debugPrint('DemoFriendsMode.load failed: $e');
    } finally {
      _loaded = true;
      notifyListeners();
    }
  }

  /// Persists [value]. Returns the *effective* value afterwards, which is
  /// always false outside debug builds — callers should trust the return value
  /// rather than the argument they passed.
  Future<bool> setEnabled(bool value) async {
    if (!_debugMode) return false;
    if (_stored == value) return _stored;
    _stored = value;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(prefsKey, value);
    } catch (e) {
      debugPrint('DemoFriendsMode.setEnabled failed: $e');
    }
    return enabled;
  }
}
