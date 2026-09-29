// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../utils/profile_cache.dart';
import '../utils/username_logic.dart';
import 'analytics_service.dart';
import 'profanity_filter_service.dart';

/// Server error vocabulary of `set_username()` / `set_avatar()`
/// (`supabase/migrations/user_profiles.sql`).
enum UsernameError {
  notAuthenticated,
  invalidFormat,
  profanity,
  cooldown,
  taken,
  unknown,
}

/// Outcome of a `setUsername` / `setAvatar` call. Mirrors the `BoostResult` /
/// `NominationResult` pattern so the error → copy mapping is unit-testable
/// without a live backend.
class ProfileResult {
  final bool success;
  final UsernameError? error;

  /// Days left on the 7-day cooldown, only set for [UsernameError.cooldown].
  final int? daysRemaining;

  const ProfileResult({required this.success, this.error, this.daysRemaining});

  const ProfileResult.ok() : this(success: true);

  const ProfileResult.fail(UsernameError error, {int? daysRemaining})
      : this(success: false, error: error, daysRemaining: daysRemaining);

  String get message {
    if (success) return 'Saved';
    switch (error) {
      case UsernameError.notAuthenticated:
        return 'Verify that you are a human first.';
      case UsernameError.invalidFormat:
        return 'Lowercase letters, numbers and underscores only '
            '($kUsernameMinLength–$kUsernameMaxLength characters).';
      case UsernameError.profanity:
        return "Let's keep it friendly — try another name.";
      case UsernameError.cooldown:
        final days = daysRemaining ?? 7;
        return 'You can change your name again in '
            '$days ${days == 1 ? 'day' : 'days'}.';
      case UsernameError.taken:
        return 'That name is taken. Try one of the suggestions!';
      case UsernameError.unknown:
      default:
        return 'Something went wrong. Please try again.';
    }
  }

  static UsernameError parseError(String? code) {
    switch (code) {
      case 'not_authenticated':
        return UsernameError.notAuthenticated;
      case 'invalid_format':
      case 'invalid_avatar':
        return UsernameError.invalidFormat;
      case 'profanity':
        return UsernameError.profanity;
      case 'cooldown':
        return UsernameError.cooldown;
      case 'taken':
        return UsernameError.taken;
      default:
        return UsernameError.unknown;
    }
  }
}

/// Owns the caller's `user_profiles` row: handle + chameleon avatar.
///
/// Registered in `main.dart`'s provider tree. Everything degrades to "no
/// profile" when the backend objects are missing or the user is a guest, so the
/// client is safe to ship before/without the migration (it just cannot save).
///
/// Guest support (WP-C3): [stageUsername] / [stageAvatar] hold a choice locally
/// in SharedPreferences while no user exists; [flushPendingSelection] persists
/// it to the server right after passkey registration.
///
/// Resilience (2026-09-28): the last good handle + avatar are cached per auth
/// uid ([ProfileCache]) and shown while a fetch is in flight or after it
/// fails, and a failed fetch is retried with backoff, on app resume and on
/// token refresh until it succeeds. A network blip must never look like the
/// profile was reset.
class ProfileService extends ChangeNotifier with WidgetsBindingObserver {
  ProfileService({
    SupabaseClient? client,
    ProfanityFilterService? profanityFilter,
    Random? random,
    bool listenToAuth = true,
  })  : _client = client,
        _profanity = profanityFilter ?? ProfanityFilterService(),
        _random = random ?? Random() {
    if (listenToAuth) {
      _subscribeToAuth();
      _observeLifecycle();
    }
  }

  /// A fetch that has not answered by then counts as failed (and is retried),
  /// so a hung request can never block every later load.
  static const Duration _fetchTimeout = Duration(seconds: 10);

  static const String _pendingUsernameKey = 'pending_profile_username';
  static const String _pendingAvatarKey = 'pending_profile_avatar_id';
  static const String _usernameSourceKey = 'pending_profile_username_source';

  final SupabaseClient? _client;
  final ProfanityFilterService _profanity;
  final Random _random;

  SupabaseClient get _supabase => _client ?? Supabase.instance.client;

  /// Supabase throws if it has not been initialised (unit tests, very early
  /// startup). Treat that as "no client" rather than letting it escape into UI
  /// callbacks.
  SupabaseClient? get _supabaseOrNull {
    try {
      return _supabase;
    } catch (_) {
      return null;
    }
  }

  String? _username;
  String? _avatarId;
  DateTime? _usernameUpdatedAt;
  bool _shareAnswersWithCloseFriends = true;
  bool _loaded = false;
  bool _loading = false;

  /// Auth uid the in-memory profile belongs to.
  String? _profileUid;

  /// The last server fetch failed; the values shown are cached ones.
  bool _loadFailed = false;

  /// [load] was called while one was in flight; run again when it finishes
  /// instead of dropping the call (e.g. `initialSession` arriving during the
  /// provider's own first load).
  bool _reloadQueued = false;

  int _retryAttempt = 0;
  Timer? _retryTimer;
  bool _observingLifecycle = false;

  StreamSubscription<AuthState>? _authSubscription;

  String? _pendingUsername;
  String? _pendingAvatarId;
  String? _pendingUsernameSource;

  /// The saved handle, or the locally-staged one while the user is still a
  /// guest — so the header chip and "Thanks, {name}" copy work during
  /// onboarding, before an account exists.
  String? get username => _username ?? _pendingUsername;

  /// The saved avatar id, or the locally-staged one (see [username]).
  String? get avatarId => _avatarId ?? _pendingAvatarId;

  DateTime? get usernameUpdatedAt => _usernameUpdatedAt;

  /// **Legacy, read-only.** The old profile-wide "share my answers with close
  /// friends" switch (§5.5B), superseded on 2026-09-17 by the per-answer flag
  /// (`responses.shared_with_close_friends`,
  /// feature-documentation/per-answer-share-flag-2026-09-17.md). Nothing in the
  /// app writes it any more and no UI reads it; it stays only because
  /// `get_my_profile()` still returns the column and parsing what the RPC sends
  /// is cheaper than keeping the contract in sync with a deletion.
  ///
  /// Default ON, which is also the fallback when there is no row yet or the
  /// profile could not be loaded.
  bool get shareAnswersWithCloseFriends => _shareAnswersWithCloseFriends;

  bool get hasUsername => (username ?? '').isNotEmpty;
  bool get hasProfile => hasUsername || (avatarId ?? '').isNotEmpty;

  /// `true` once a load attempt has finished (success or not).
  bool get isLoaded => _loaded;
  bool get isLoading => _loading;

  /// `true` when the last fetch failed and the profile shown is the cached
  /// one (a retry is scheduled).
  bool get lastLoadFailed => _loadFailed;

  bool get isAuthenticated => _supabaseOrNull?.auth.currentUser != null;

  /// Remaining days on the 7-day change cooldown, 0 when a change is allowed.
  int cooldownDaysRemaining({DateTime? now}) {
    final updatedAt = _usernameUpdatedAt;
    if (updatedAt == null || _username == null) return 0;
    final elapsed = (now ?? DateTime.now()).difference(updatedAt);
    final remaining = const Duration(days: 7) - elapsed;
    if (remaining.isNegative) return 0;
    return remaining.inHours ~/ 24 + (remaining.inHours % 24 == 0 ? 0 : 1);
  }

  bool canChangeUsername({DateTime? now}) =>
      cooldownDaysRemaining(now: now) == 0;

  // --- loading ---------------------------------------------------------------

  /// Loads the profile for the current user. Safe to call repeatedly and on
  /// every auth-state change; a guest call just restores the staged selection.
  Future<void> load() async {
    if (_loading) {
      _reloadQueued = true;
      return;
    }
    _loading = true;
    notifyListeners();
    try {
      await _restorePending();

      final uid = _supabaseOrNull?.auth.currentUser?.id;
      if (uid == null) {
        _setProfile(null, null, null);
        _profileUid = null;
        _loadFailed = false;
        _cancelRetry();
        return;
      }

      // Show the last known profile for this account straight away; the
      // fetch below replaces it, or it stays if the fetch fails.
      if (_profileUid != uid) {
        final cached = await ProfileCache.read(uid);
        _profileUid = uid;
        _setProfile(
            cached?.username, cached?.avatarId, cached?.usernameUpdatedAt);
        notifyListeners();
      }

      final result =
          await _supabase.rpc('get_my_profile').timeout(_fetchTimeout);
      if (_supabaseOrNull?.auth.currentUser?.id != uid) {
        // Account changed mid-fetch: this answer is for someone else.
        _reloadQueued = true;
        return;
      }
      if (result is! Map) {
        throw FormatException('get_my_profile returned $result');
      }
      if (result['exists'] == true) {
        final updatedAt = result['username_updated_at']?.toString();
        _setProfile(
          result['username']?.toString(),
          result['avatar_id']?.toString(),
          updatedAt == null ? null : DateTime.tryParse(updatedAt),
        );
        // Absent (an older `get_my_profile`) means "not told otherwise" — the
        // column's own default is true.
        _shareAnswersWithCloseFriends =
            result['share_answers_with_close_friends'] != false;
      } else {
        // The server answered and has no row: that is authoritative.
        _setProfile(null, null, null);
        _shareAnswersWithCloseFriends = true;
      }
      await _writeCache();
      _loadFailed = false;
      _retryAttempt = 0;
      _cancelRetry();
    } catch (e) {
      // Offline, token refresh failing, timeout, or the migration missing:
      // keep showing the cached profile and try again later.
      print('ProfileService.load failed: $e');
      _loadFailed = true;
      _scheduleRetry();
    } finally {
      _loaded = true;
      _loading = false;
      notifyListeners();
      if (_reloadQueued) {
        _reloadQueued = false;
        unawaited(load());
      }
    }
  }

  void _setProfile(String? username, String? avatarId, DateTime? updatedAt) {
    _username = username;
    _avatarId = avatarId;
    _usernameUpdatedAt = updatedAt;
  }

  /// Saves the current account's profile as the last known good one.
  Future<void> _writeCache() async {
    final uid = _profileUid;
    if (uid == null) return;
    try {
      await ProfileCache.write(ProfileCacheEntry(
        uid: uid,
        username: _username,
        avatarId: _avatarId,
        usernameUpdatedAt: _usernameUpdatedAt,
      ));
    } catch (e) {
      print('ProfileService cache write failed: $e');
    }
  }

  void _scheduleRetry() {
    if (!_observingLifecycle) return; // tests / demo: no background timers
    _retryTimer?.cancel();
    _retryAttempt++;
    _retryTimer = Timer(profileRetryDelay(_retryAttempt), () {
      _retryTimer = null;
      if (_loadFailed && isAuthenticated) load();
    });
  }

  void _cancelRetry() {
    _retryTimer?.cancel();
    _retryTimer = null;
  }

  void _observeLifecycle() {
    try {
      WidgetsBinding.instance.addObserver(this);
      _observingLifecycle = true;
    } catch (e) {
      print('ProfileService lifecycle observer unavailable: $e');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _loadFailed) load();
  }

  /// Keeps the profile in step with auth without every sign-in call site having
  /// to remember to refresh it.
  void _subscribeToAuth() {
    try {
      _authSubscription =
          _supabase.auth.onAuthStateChange.listen((state) async {
        switch (state.event) {
          case AuthChangeEvent.signedIn:
          case AuthChangeEvent.initialSession:
          case AuthChangeEvent.userUpdated:
            await load();
            break;
          case AuthChangeEvent.tokenRefreshed:
            // The network is back; recover a fetch that failed earlier.
            if (_loadFailed) await load();
            break;
          case AuthChangeEvent.signedOut:
            clear();
            break;
          default:
            break;
        }
      }, onError: (Object e) {
        // A failed token refresh surfaces here; the session is kept and the
        // retry above handles the profile, so it is not an app error.
        print('ProfileService auth stream error: $e');
      });
    } catch (e) {
      // Supabase not initialised (unit tests) — the service still works, it
      // just will not auto-refresh.
      print('ProfileService auth subscription unavailable: $e');
    }
  }

  @override
  void dispose() {
    _authSubscription?.cancel();
    _cancelRetry();
    if (_observingLifecycle) WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Clears in-memory state on sign-out. Staged guest choices are kept.
  void clear() {
    _setProfile(null, null, null);
    _shareAnswersWithCloseFriends = true;
    _loaded = false;
    _profileUid = null;
    _loadFailed = false;
    _cancelRetry();
    unawaited(ProfileCache.clear().catchError((Object e) {
      print('ProfileService cache clear failed: $e');
    }));
    notifyListeners();
  }

  // --- writes ----------------------------------------------------------------

  /// Calls `set_username`. When the user is not authenticated yet the handle is
  /// staged locally instead (guest onboarding) and reported as a success.
  Future<ProfileResult> setUsername(
    String raw, {
    bool wasSuggested = false,
  }) async {
    final value = normalizeUsername(raw);
    final formatError = usernameFormatError(value);
    if (formatError != null) {
      return const ProfileResult.fail(UsernameError.invalidFormat);
    }
    // Advisory client-side filter (§5.1); the RPC re-checks server-side.
    if (_profanity.containsProfanity(value.replaceAll('_', ' '))) {
      return const ProfileResult.fail(UsernameError.profanity);
    }

    if (!isAuthenticated) {
      await stageUsername(value, wasSuggested: wasSuggested);
      return const ProfileResult.ok();
    }

    try {
      final result =
          await _supabase.rpc('set_username', params: {'p_username': value});
      if (result is Map && result['success'] == true) {
        final isChange = result['is_change'] == true;
        _username = result['username']?.toString() ?? value;
        // Re-saving the same handle is a server no-op that does not restart
        // the 7-day cooldown, so the client must not restart it either.
        if (isChange || _usernameUpdatedAt == null) {
          _usernameUpdatedAt = DateTime.now();
        }
        _profileUid ??= _supabaseOrNull?.auth.currentUser?.id;
        await _writeCache();
        await _clearPendingUsername();
        notifyListeners();
        AnalyticsService().trackEvent('username_set', {'is_change': isChange});
        await _trackProfileSet(wasSuggested: wasSuggested);
        return const ProfileResult.ok();
      }
      final code = result is Map ? result['error']?.toString() : null;
      final daysRemaining =
          result is Map ? (result['days_remaining'] as num?)?.toInt() : null;
      return ProfileResult.fail(
        ProfileResult.parseError(code),
        daysRemaining: daysRemaining,
      );
    } catch (e) {
      print('ProfileService.setUsername failed: $e');
      return const ProfileResult.fail(UsernameError.unknown);
    }
  }

  /// Calls `set_avatar`. Stages locally for guests, like [setUsername].
  Future<ProfileResult> setAvatar(String? avatarId) async {
    if (!isAuthenticated) {
      await stageAvatar(avatarId);
      return const ProfileResult.ok();
    }
    try {
      final result =
          await _supabase.rpc('set_avatar', params: {'p_avatar_id': avatarId});
      if (result is Map && result['success'] == true) {
        _avatarId = result['avatar_id']?.toString();
        _profileUid ??= _supabaseOrNull?.auth.currentUser?.id;
        await _writeCache();
        await _clearPendingAvatar();
        notifyListeners();
        return const ProfileResult.ok();
      }
      final code = result is Map ? result['error']?.toString() : null;
      return ProfileResult.fail(ProfileResult.parseError(code));
    } catch (e) {
      print('ProfileService.setAvatar failed: $e');
      return const ProfileResult.fail(UsernameError.unknown);
    }
  }

  // --- suggestions -----------------------------------------------------------

  /// [n] generated, profanity-checked handle suggestions (decision D4: the
  /// suggestions are filtered too, not only typed input).
  List<String> suggestUsernames(int n) {
    return generateUsernameSuggestions(
      n,
      random: _random,
      isAllowed: (candidate) =>
          !_profanity.containsProfanity(candidate.replaceAll('_', ' ')),
    );
  }

  // --- guest staging (WP-C3) -------------------------------------------------

  /// Holds a handle locally until an account exists.
  Future<void> stageUsername(String raw, {bool wasSuggested = false}) async {
    _pendingUsername = normalizeUsername(raw);
    _pendingUsernameSource = wasSuggested ? 'suggested' : 'custom';
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_pendingUsernameKey, _pendingUsername!);
    await prefs.setString(_usernameSourceKey, _pendingUsernameSource!);
    notifyListeners();
  }

  /// Holds an avatar id locally until an account exists.
  Future<void> stageAvatar(String? avatarId) async {
    _pendingAvatarId = avatarId;
    final prefs = await SharedPreferences.getInstance();
    if (avatarId == null) {
      await prefs.remove(_pendingAvatarKey);
    } else {
      await prefs.setString(_pendingAvatarKey, avatarId);
    }
    notifyListeners();
  }

  bool get hasPendingSelection =>
      (_pendingUsername ?? '').isNotEmpty || (_pendingAvatarId ?? '').isNotEmpty;

  /// Persists any staged guest selection now that a user exists. Called right
  /// after passkey registration succeeds (WP-C3 step 2).
  Future<void> flushPendingSelection() async {
    if (!isAuthenticated) return;
    await _restorePending();

    final pendingAvatar = _pendingAvatarId;
    if (pendingAvatar != null && pendingAvatar.isNotEmpty) {
      await setAvatar(pendingAvatar);
    }
    final pendingUsername = _pendingUsername;
    if (pendingUsername != null && pendingUsername.isNotEmpty) {
      await setUsername(
        pendingUsername,
        wasSuggested: _pendingUsernameSource == 'suggested',
      );
    }
  }

  Future<void> _restorePending() async {
    final prefs = await SharedPreferences.getInstance();
    _pendingUsername ??= prefs.getString(_pendingUsernameKey);
    _pendingAvatarId ??= prefs.getString(_pendingAvatarKey);
    _pendingUsernameSource ??= prefs.getString(_usernameSourceKey);
  }

  Future<void> _clearPendingUsername() async {
    _pendingUsername = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_pendingUsernameKey);
    await prefs.remove(_usernameSourceKey);
  }

  Future<void> _clearPendingAvatar() async {
    _pendingAvatarId = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_pendingAvatarKey);
  }

  Future<void> _trackProfileSet({required bool wasSuggested}) async {
    await AnalyticsService().trackEvent('profile_set', {
      'has_avatar': (avatarId ?? '').isNotEmpty,
      'username_source': wasSuggested ? 'suggested' : 'custom',
    });
  }
}
