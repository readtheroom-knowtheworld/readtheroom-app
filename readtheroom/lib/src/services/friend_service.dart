// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../utils/friend_logic.dart';
import 'analytics_service.dart';

/// Server error vocabulary of the friend-graph RPCs
/// (`supabase/migrations/friendships.sql`).
enum FriendError {
  notAuthenticated,
  self,
  rateLimited,
  blocked,
  notFound,
  alreadyFriends,
  alreadyPending,
  noPendingRequest,
  notIncoming,
  notFriends,
  invalidToken,
  expiredToken,
  unknown,
}

/// Outcome of any friend RPC. Mirrors `ProfileResult` (WP-C) so the error →
/// copy mapping is unit-testable without a live backend.
class FriendResult {
  const FriendResult({
    required this.success,
    this.error,
    this.friend,
    this.alreadyFriends = false,
  });

  const FriendResult.ok({Friend? friend, bool alreadyFriends = false})
      : this(success: true, friend: friend, alreadyFriends: alreadyFriends);

  const FriendResult.fail(FriendError error) : this(success: false, error: error);

  final bool success;
  final FriendError? error;

  /// The other party, when the RPC returned enough to build one (QR add).
  final Friend? friend;

  /// QR add against someone who was already a friend — worth saying out loud
  /// rather than pretending a new connection was made.
  final bool alreadyFriends;

  /// User-facing copy. Deliberately vague about blocks (§5.2 / P-5: a blocked
  /// user must not be able to detect the block).
  String get message {
    if (success) return 'Done';
    switch (error) {
      case FriendError.notAuthenticated:
        return 'Verify that you are a human first.';
      case FriendError.self:
        return "That's you!";
      case FriendError.rateLimited:
        return "You've hit today's limit — try again tomorrow.";
      case FriendError.blocked:
      case FriendError.notFound:
        return "Couldn't send that request.";
      case FriendError.alreadyFriends:
        return "You're already friends.";
      case FriendError.alreadyPending:
        return 'Request already sent.';
      case FriendError.noPendingRequest:
      case FriendError.notIncoming:
        return 'That request is no longer waiting.';
      case FriendError.notFriends:
        return "You're not friends with them.";
      case FriendError.invalidToken:
        return "That QR code isn't a Read the Room friend code.";
      case FriendError.expiredToken:
        return 'That QR code has expired — ask for a fresh one.';
      case FriendError.unknown:
      default:
        return 'Something went wrong. Please try again.';
    }
  }

  static FriendError parseError(String? code) {
    switch (code) {
      case 'not_authenticated':
        return FriendError.notAuthenticated;
      case 'self':
        return FriendError.self;
      case 'rate_limited':
        return FriendError.rateLimited;
      case 'blocked':
        return FriendError.blocked;
      case 'not_found':
        return FriendError.notFound;
      case 'already_friends':
        return FriendError.alreadyFriends;
      case 'already_pending':
        return FriendError.alreadyPending;
      case 'no_pending_request':
        return FriendError.noPendingRequest;
      case 'not_incoming':
        return FriendError.notIncoming;
      case 'not_friends':
        return FriendError.notFriends;
      case 'invalid_token':
        return FriendError.invalidToken;
      case 'expired_token':
        return FriendError.expiredToken;
      default:
        return FriendError.unknown;
    }
  }
}

/// Result of an exact-handle lookup. Distinguishes "no such handle" from "the
/// lookup itself failed", which the UI copy must not conflate.
class FriendLookupResult {
  const FriendLookupResult({
    required this.success,
    this.found = false,
    this.userId,
    this.username,
    this.avatarId,
    this.error,
  });

  final bool success;
  final bool found;
  final String? userId;
  final String? username;
  final String? avatarId;
  final FriendError? error;
}

/// Owns the caller's friend graph: `get_friends()` plus a method per RPC.
///
/// Registered in `main.dart`'s provider tree. Every backend failure is
/// swallowed into an empty graph, so the client is safe to ship before the
/// migration lands (it simply cannot do anything).
///
/// Writes are **optimistic with rollback**: the local list is mutated
/// immediately, the RPC runs, and a failure restores the exact previous list.
/// A success then refreshes in the background, so the server stays the source
/// of truth for anything the optimistic guess could not know (mutual_close,
/// the other party's handle, a crossing request that auto-accepted).
class FriendService extends ChangeNotifier {
  FriendService({
    SupabaseClient? client,
    bool listenToAuth = true,
  }) : _client = client {
    if (listenToAuth) _subscribeToAuth();
  }

  final SupabaseClient? _client;

  SupabaseClient get _supabase => _client ?? Supabase.instance.client;

  /// Supabase throws when it has not been initialised (unit tests, very early
  /// startup). Treat that as "no client" rather than letting it escape.
  SupabaseClient? get _supabaseOrNull {
    try {
      return _supabase;
    } catch (_) {
      return null;
    }
  }

  List<Friend> _all = const [];
  FriendSections _sections = FriendSections.empty;
  bool _loaded = false;
  bool _loading = false;
  StreamSubscription<AuthState>? _authSubscription;

  /// Every accepted friend, close first then the rest (both alphabetical).
  List<Friend> get friends => _sections.allAccepted;

  /// Accepted friends the viewer marked close.
  List<Friend> get closeFriends => _sections.closeFriends;

  /// Accepted friends the viewer has *not* marked close.
  List<Friend> get regularFriends => _sections.friends;

  /// Requests waiting on the viewer.
  List<Friend> get pendingIncoming => _sections.incoming;

  /// Requests the viewer sent.
  List<Friend> get pendingOutgoing => _sections.outgoing;

  /// The partitioned view the Community tab renders directly.
  FriendSections get sections => _sections;

  /// `true` once a load attempt has finished (success or not).
  bool get isLoaded => _loaded;
  bool get isLoading => _loading;

  bool get isAuthenticated => _supabaseOrNull?.auth.currentUser != null;
  String? get _viewerId => _supabaseOrNull?.auth.currentUser?.id;

  // Derived from the public `sections` getter (not the private field) so a
  // subclass that overrides `sections` — the demo service, test fakes — gets
  // consistent counts.
  int get friendCount => sections.acceptedCount;
  bool get hasAnyFriends => friendCount > 0;
  bool get hasPending => sections.pendingCount > 0;

  Friend? friendById(String userId) {
    for (final f in _all) {
      if (f.userId == userId) return f;
    }
    return null;
  }

  // --- loading ---------------------------------------------------------------

  /// Loads `get_friends()`. Safe to call repeatedly and on every auth change.
  Future<void> load() async {
    if (_loading) return;
    _loading = true;
    notifyListeners();
    try {
      if (!isAuthenticated) {
        _setAll(const []);
        return;
      }
      final result = await _supabase.rpc('get_friends');
      _setAll(_parseFriends(result));
    } catch (e) {
      // Migration not deployed, offline, or an RLS change — stay friend-less
      // rather than breaking the Community tab.
      debugPrint('FriendService.load failed: $e');
    } finally {
      _loaded = true;
      _loading = false;
      notifyListeners();
    }
  }

  /// Refreshes without the `_loading` guard's early return, for pull-to-refresh
  /// and post-write reconciliation.
  Future<void> refresh() async {
    _loading = false;
    await load();
  }

  static List<Friend> _parseFriends(dynamic raw) {
    if (raw is! List) return const [];
    final out = <Friend>[];
    for (final row in raw) {
      if (row is Map) {
        final friend = Friend.fromMap(Map<String, dynamic>.from(row));
        if (friend != null) out.add(friend);
      }
    }
    return out;
  }

  void _setAll(List<Friend> all) {
    final previous = _all;
    _all = List.unmodifiable(all);
    _sections = partitionFriends(_all, viewerId: _viewerId);
    _announceQrFriends(previous, _all);
  }

  // --- "you're friends now" on the scanned phone ------------------------------

  /// New QR-made friendships, as they show up in a reload. The phone that
  /// showed the QR never ran `add_friend_via_qr`, so this is how it learns
  /// the scan worked: `FriendQrDialog` polls while it is open and a
  /// foreground `friend_accepted` push triggers a refresh, and both end up
  /// here. `MainScreen` listens and shows [NewFriendDialog].
  Stream<Friend> get qrFriendAdded => _qrFriendAdded.stream;
  final StreamController<Friend> _qrFriendAdded =
      StreamController<Friend>.broadcast();

  /// Friends this device added itself by scanning: the scanner screen already
  /// shows the success state, so the reload it triggers must not announce
  /// them a second time.
  final Set<String> _selfAddedQr = {};

  void _announceQrFriends(List<Friend> previous, List<Friend> current) {
    // The first load after sign-in is a snapshot, not a change.
    if (!_loaded) return;
    for (final friend in newlyAcceptedQrFriends(previous, current)) {
      if (_selfAddedQr.remove(friend.userId)) continue;
      _qrFriendAdded.add(friend);
    }
  }

  void _subscribeToAuth() {
    try {
      _authSubscription =
          _supabase.auth.onAuthStateChange.listen((state) async {
        switch (state.event) {
          case AuthChangeEvent.signedIn:
          case AuthChangeEvent.initialSession:
            // A friend link opened as a guest is redeemed here, once the
            // account it needed finally exists.
            await redeemStashedQrToken();
            await load();
            break;
          case AuthChangeEvent.signedOut:
            clear();
            break;
          default:
            break;
        }
      });
    } catch (e) {
      debugPrint('FriendService auth subscription unavailable: $e');
    }
  }

  @override
  void dispose() {
    _authSubscription?.cancel();
    _qrFriendAdded.close();
    super.dispose();
  }

  void clear() {
    _setAll(const []);
    _loaded = false;
    notifyListeners();
  }

  // --- optimistic update plumbing -------------------------------------------

  /// Applies [mutate] to the local list immediately and returns a rollback
  /// closure that restores the exact previous state.
  VoidCallback _optimistically(List<Friend> Function(List<Friend>) mutate) {
    final previous = _all;
    _setAll(mutate(List<Friend>.from(_all)));
    notifyListeners();
    return () {
      _setAll(previous);
      notifyListeners();
    };
  }

  List<Friend> _withoutFriend(List<Friend> list, String userId) =>
      list.where((f) => f.userId != userId).toList();

  List<Friend> _replacingFriend(List<Friend> list, Friend updated) {
    final out = List<Friend>.from(list);
    final i = out.indexWhere((f) => f.userId == updated.userId);
    if (i >= 0) {
      out[i] = updated;
    } else {
      out.add(updated);
    }
    return out;
  }

  /// Unwraps the jsonb `{success, error}` envelope every RPC returns.
  FriendResult _envelope(dynamic result) {
    if (result is Map && result['success'] == true) {
      return const FriendResult.ok();
    }
    final code = result is Map ? result['error']?.toString() : null;
    return FriendResult.fail(FriendResult.parseError(code));
  }

  // --- reads -----------------------------------------------------------------

  /// Exact-handle lookup (§5.1: exact match only, no enumeration).
  Future<FriendLookupResult> lookupByUsername(String rawHandle) async {
    final handle = rawHandle.trim().toLowerCase().replaceFirst('@', '');
    if (handle.isEmpty) {
      return const FriendLookupResult(success: true, found: false);
    }
    if (!isAuthenticated) {
      return const FriendLookupResult(
        success: false,
        error: FriendError.notAuthenticated,
      );
    }
    try {
      final result = await _supabase.rpc(
        'lookup_user_by_username',
        params: {'p_username': handle},
      );
      if (result is Map && result['success'] == true) {
        if (result['found'] != true) {
          unawaited(AnalyticsService()
              .trackEvent('friend_lookup', const {'result': 'not_found'}));
          return const FriendLookupResult(success: true, found: false);
        }
        // Never the handle that was searched for — that is another user's
        // identifier (§8 privacy rule).
        unawaited(AnalyticsService()
            .trackEvent('friend_lookup', const {'result': 'found'}));
        return FriendLookupResult(
          success: true,
          found: true,
          userId: result['user_id']?.toString(),
          username: result['username']?.toString(),
          avatarId: result['avatar_id']?.toString(),
        );
      }
      final code = result is Map ? result['error']?.toString() : null;
      final parsed = FriendResult.parseError(code);
      unawaited(AnalyticsService()
          .trackEvent('friend_lookup', {'result': parsed.name}));
      return FriendLookupResult(
        success: false,
        error: parsed,
      );
    } catch (e) {
      debugPrint('FriendService.lookupByUsername failed: $e');
      unawaited(AnalyticsService()
          .trackEvent('friend_lookup', const {'result': 'error'}));
      return const FriendLookupResult(
        success: false,
        error: FriendError.unknown,
      );
    }
  }

  // --- writes ----------------------------------------------------------------

  /// Sends a friend request. [method] is analytics-only (§8).
  Future<FriendResult> sendFriendRequest(
    String userId, {
    String method = 'username',
    String? username,
    String? avatarId,
  }) async {
    if (!isAuthenticated) {
      return const FriendResult.fail(FriendError.notAuthenticated);
    }

    // Optimistic: an outgoing pending row appears at once. requested_by is the
    // viewer, which is exactly what makes partitionFriends file it as outgoing.
    final rollback = _optimistically((list) => _replacingFriend(
          list,
          Friend(
            userId: userId,
            username: username,
            avatarId: avatarId,
            status: FriendStatus.pending,
            requestedBy: _viewerId,
            createdAt: DateTime.now(),
          ),
        ));

    try {
      final result = await _supabase
          .rpc('send_friend_request', params: {'p_user_id': userId});
      final envelope = _envelope(result);
      if (!envelope.success) {
        rollback();
        unawaited(AnalyticsService().trackRpcFailed('send_friend_request',
            reason: envelope.error?.name));
        return envelope;
      }
      unawaited(AnalyticsService()
          .trackEvent('friend_request_sent', {'method': method}));
      _nudgeNotificationFunction();
      unawaited(refresh());
      return const FriendResult.ok();
    } catch (e) {
      debugPrint('FriendService.sendFriendRequest failed: $e');
      rollback();
      unawaited(AnalyticsService()
          .trackRpcFailed('send_friend_request', reason: 'exception'));
      return const FriendResult.fail(FriendError.unknown);
    }
  }

  /// Accepts or declines an incoming request.
  ///
  /// [direction] is `incoming` (someone asked you) or `outgoing` (you are
  /// cancelling your own request). Review 2026-09-22 D1: `cancelRequest`
  /// delegates here, so without it half the social funnel's rejection leg —
  /// cancels — was counted as declines.
  Future<FriendResult> respondToRequest(String userId, bool accept,
      {String direction = 'incoming'}) async {
    if (!isAuthenticated) {
      return const FriendResult.fail(FriendError.notAuthenticated);
    }

    final existing = friendById(userId);
    final rollback = _optimistically((list) => accept && existing != null
        ? _replacingFriend(
            list, existing.copyWith(status: FriendStatus.accepted))
        : _withoutFriend(list, userId));

    try {
      final result = await _supabase.rpc(
        'respond_friend_request',
        params: {'p_user_id': userId, 'p_accept': accept},
      );
      final envelope = _envelope(result);
      if (!envelope.success) {
        rollback();
        unawaited(AnalyticsService().trackRpcFailed('respond_friend_request',
            reason: envelope.error?.name));
        return envelope;
      }
      // friend_count is post-optimistic-update, so an accept already counts
      // the new friendship — that is what makes "first friend" readable.
      unawaited(AnalyticsService().trackEvent('friend_request_responded', {
        'accepted': accept,
        'direction': direction,
        'friend_count': friendCount,
      }));
      if (accept) _nudgeNotificationFunction();
      unawaited(refresh());
      return const FriendResult.ok();
    } catch (e) {
      debugPrint('FriendService.respondToRequest failed: $e');
      rollback();
      unawaited(AnalyticsService()
          .trackRpcFailed('respond_friend_request', reason: 'exception'));
      return const FriendResult.fail(FriendError.unknown);
    }
  }

  /// Cancels an outgoing request. The server treats this as a decline by the
  /// requester, so it is the same RPC.
  Future<FriendResult> cancelRequest(String userId) =>
      respondToRequest(userId, false, direction: 'outgoing');

  /// Rotates the caller's QR token and returns `(token, expiresAt)`.
  Future<({String token, DateTime? expiresAt})?> createQrToken() async {
    if (!isAuthenticated) return null;
    try {
      final result = await _supabase.rpc('create_friend_qr_token');
      if (result is Map && result['success'] == true) {
        final token = result['token']?.toString();
        if (!isValidFriendToken(token)) return null;
        final expiresRaw = result['expires_at']?.toString();
        return (
          token: token!,
          expiresAt: expiresRaw == null ? null : DateTime.tryParse(expiresRaw),
        );
      }
      unawaited(AnalyticsService()
          .trackRpcFailed('create_qr_token', reason: 'refused'));
      return null;
    } catch (e) {
      debugPrint('FriendService.createQrToken failed: $e');
      unawaited(AnalyticsService()
          .trackRpcFailed('create_qr_token', reason: 'exception'));
      return null;
    }
  }

  /// Redeems a scanned / deep-linked friend token into an accepted pair.
  Future<FriendResult> addFriendViaQr(String token) async {
    if (!isAuthenticated) {
      return const FriendResult.fail(FriendError.notAuthenticated);
    }
    if (!isValidFriendToken(token)) {
      return const FriendResult.fail(FriendError.invalidToken);
    }
    try {
      final result =
          await _supabase.rpc('add_friend_via_qr', params: {'p_token': token});
      if (result is! Map || result['success'] != true) {
        final code = result is Map ? result['error']?.toString() : null;
        unawaited(AnalyticsService()
            .trackRpcFailed('add_friend_via_qr', reason: code ?? 'refused'));
        return FriendResult.fail(FriendResult.parseError(code));
      }

      final friend = Friend(
        userId: result['user_id']?.toString() ?? '',
        username: result['username']?.toString(),
        avatarId: result['avatar_id']?.toString(),
        status: FriendStatus.accepted,
        createdAt: DateTime.now(),
      );
      final alreadyFriends = result['already_friends'] == true;

      if (friend.userId.isNotEmpty) {
        // This phone did the scanning; the scanner screen shows the result.
        _selfAddedQr.add(friend.userId);
        _setAll(_replacingFriend(List<Friend>.from(_all), friend));
        notifyListeners();
      }

      if (!alreadyFriends) {
        unawaited(AnalyticsService()
            .trackEvent('friend_request_sent', {'method': 'qr'}));
        _nudgeNotificationFunction();
      }
      unawaited(refresh());
      return FriendResult.ok(friend: friend, alreadyFriends: alreadyFriends);
    } catch (e) {
      debugPrint('FriendService.addFriendViaQr failed: $e');
      return const FriendResult.fail(FriendError.unknown);
    }
  }

  /// Marks / unmarks a friend as close. Only reciprocity actually unlocks
  /// answer visibility, so the refresh afterwards matters: the server is the
  /// only place that can tell us whether it is now mutual.
  /// [surface] is `community_menu` or `chat_overlay` — the heart moved into
  /// the chat overlay, and without it there is no way to tell which control
  /// produced a close-friend flip (review 2026-09-22 D2).
  Future<FriendResult> setCloseFriend(String userId, bool close,
      {String surface = 'community_menu'}) async {
    if (!isAuthenticated) {
      return const FriendResult.fail(FriendError.notAuthenticated);
    }
    final existing = friendById(userId);
    if (existing == null) {
      return const FriendResult.fail(FriendError.notFriends);
    }

    final rollback = _optimistically((list) => _replacingFriend(
          list,
          applyAction(existing,
                  close ? FriendAction.setClose : FriendAction.unsetClose) ??
              existing,
        ));

    try {
      final result = await _supabase.rpc(
        'set_close_friend',
        params: {'p_user_id': userId, 'p_close': close},
      );
      if (result is! Map || result['success'] != true) {
        rollback();
        final code = result is Map ? result['error']?.toString() : null;
        unawaited(AnalyticsService()
            .trackRpcFailed('set_close_friend', reason: code ?? 'refused'));
        return FriendResult.fail(FriendResult.parseError(code));
      }

      // The RPC reports reciprocity; adopt it without waiting for the refresh
      // so the "you both added each other" hint is correct immediately.
      final mutual = result['mutual_close'] == true;
      _setAll(_replacingFriend(
        List<Friend>.from(_all),
        (friendById(userId) ?? existing)
            .copyWith(isClose: close, mutualClose: mutual),
      ));
      notifyListeners();

      unawaited(AnalyticsService().trackEvent('close_friend_set', {
        'value': close,
        'mutual': mutual,
        'surface': surface,
      }));
      unawaited(refresh());
      return const FriendResult.ok();
    } catch (e) {
      debugPrint('FriendService.setCloseFriend failed: $e');
      rollback();
      unawaited(AnalyticsService()
          .trackRpcFailed('set_close_friend', reason: 'exception'));
      return const FriendResult.fail(FriendError.unknown);
    }
  }

  /// Mutes / unmutes push from one friend.
  Future<FriendResult> setFriendMuted(String userId, bool muted) async {
    if (!isAuthenticated) {
      return const FriendResult.fail(FriendError.notAuthenticated);
    }
    final existing = friendById(userId);
    if (existing == null) {
      return const FriendResult.fail(FriendError.notFriends);
    }

    // Kept for the backend flag (`friendships.muted`); no UI drives it since
    // per-friend muting was dropped — notifications are all-or-nothing.
    final rollback = _optimistically((list) =>
        _replacingFriend(list, existing.copyWith(muted: muted)));

    try {
      final result = await _supabase.rpc(
        'set_friend_muted',
        params: {'p_user_id': userId, 'p_muted': muted},
      );
      final envelope = _envelope(result);
      if (!envelope.success) {
        rollback();
        unawaited(AnalyticsService().trackRpcFailed('set_friend_muted',
            reason: envelope.error?.name));
        return envelope;
      }
      return const FriendResult.ok();
    } catch (e) {
      debugPrint('FriendService.setFriendMuted failed: $e');
      rollback();
      unawaited(AnalyticsService()
          .trackRpcFailed('set_friend_muted', reason: 'exception'));
      return const FriendResult.fail(FriendError.unknown);
    }
  }

  /// Removes a friend in both directions. Silent — they are not notified.
  Future<FriendResult> unfriend(String userId) async {
    if (!isAuthenticated) {
      return const FriendResult.fail(FriendError.notAuthenticated);
    }
    final rollback = _optimistically((list) => _withoutFriend(list, userId));
    try {
      final result =
          await _supabase.rpc('unfriend', params: {'p_user_id': userId});
      final envelope = _envelope(result);
      if (!envelope.success) {
        rollback();
        unawaited(AnalyticsService()
            .trackRpcFailed('unfriend', reason: envelope.error?.name));
        return envelope;
      }
      // Churn against the 5-friend gate is the metric the whole network
      // feature depends on (review 2026-09-22 D4). Post-optimistic, so the
      // count is the one the user is left with.
      unawaited(AnalyticsService()
          .trackEvent('friend_removed', {'friend_count': friendCount}));
      unawaited(refresh());
      return const FriendResult.ok();
    } catch (e) {
      debugPrint('FriendService.unfriend failed: $e');
      rollback();
      unawaited(
          AnalyticsService().trackRpcFailed('unfriend', reason: 'exception'));
      return const FriendResult.fail(FriendError.unknown);
    }
  }

  /// Unfriend + suppress future requests in both directions.
  /// [surface] is `community` or `chat_overlay`, the two paths that reach it.
  Future<FriendResult> blockUser(String userId,
      {String surface = 'community'}) async {
    if (!isAuthenticated) {
      return const FriendResult.fail(FriendError.notAuthenticated);
    }
    final rollback = _optimistically((list) => _withoutFriend(list, userId));
    try {
      final result =
          await _supabase.rpc('block_user', params: {'p_user_id': userId});
      final envelope = _envelope(result);
      if (!envelope.success) {
        rollback();
        unawaited(AnalyticsService()
            .trackRpcFailed('block_user', reason: envelope.error?.name));
        return envelope;
      }
      unawaited(AnalyticsService().trackEvent('user_blocked', {
        'friend_count': friendCount,
        'surface': surface,
      }));
      unawaited(refresh());
      return const FriendResult.ok();
    } catch (e) {
      debugPrint('FriendService.blockUser failed: $e');
      rollback();
      unawaited(
          AnalyticsService().trackRpcFailed('block_user', reason: 'exception'));
      return const FriendResult.fail(FriendError.unknown);
    }
  }

  // --- guest-held friend link ------------------------------------------------
  //
  // A `/friend/{token}` link opened by a guest cannot be redeemed: every
  // friend RPC is granted to `authenticated` only (§5.2). DeepLinkService
  // stashes the token here and shows the sign-in prompt; it retries directly
  // when that prompt completes, and this stash is the backstop for the other
  // route — a guest who dismisses the prompt and signs in later through
  // onboarding still gets the friend, silently, on the next auth event.
  //
  // Bounded by the same 24 h as the token itself, so a stale stash cannot
  // surprise someone with a friend request a week later.

  static const String _pendingQrTokenKey = 'pending_friend_qr_token';
  static const String _pendingQrTokenAtKey = 'pending_friend_qr_token_at';
  static const Duration _pendingQrTokenTtl = Duration(hours: 24);

  /// Holds a friend token until an account exists.
  Future<void> stashQrToken(String token) async {
    if (!isValidFriendToken(token)) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_pendingQrTokenKey, token);
      await prefs.setString(
          _pendingQrTokenAtKey, DateTime.now().toIso8601String());
    } catch (e) {
      debugPrint('FriendService.stashQrToken failed: $e');
    }
  }

  Future<void> clearStashedQrToken() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_pendingQrTokenKey);
      await prefs.remove(_pendingQrTokenAtKey);
    } catch (_) {
      // Non-fatal: worst case the (idempotent) redeem runs once more.
    }
  }

  /// Redeems a stashed token, if there is a live one and the user is now
  /// authenticated. Returns null when there was nothing to do.
  Future<FriendResult?> redeemStashedQrToken() async {
    if (!isAuthenticated) return null;

    String? token;
    try {
      final prefs = await SharedPreferences.getInstance();
      token = prefs.getString(_pendingQrTokenKey);
      final stashedAtRaw = prefs.getString(_pendingQrTokenAtKey);
      final stashedAt =
          stashedAtRaw == null ? null : DateTime.tryParse(stashedAtRaw);
      if (stashedAt != null &&
          DateTime.now().difference(stashedAt) > _pendingQrTokenTtl) {
        await clearStashedQrToken();
        return null;
      }
    } catch (e) {
      debugPrint('FriendService.redeemStashedQrToken read failed: $e');
      return null;
    }

    if (!isValidFriendToken(token)) return null;

    final result = await addFriendViaQr(token!);
    // Clear on success, and on any *permanent* failure — retrying an expired
    // or invalid token on every launch achieves nothing.
    if (result.success || result.error != FriendError.unknown) {
      await clearStashedQrToken();
    }
    return result;
  }

  // --- push --------------------------------------------------------------

  /// Fire-and-forget nudge so the recipient's push goes out now rather than on
  /// the next scheduled drain.
  ///
  /// The RPC has *already* written the outbox row, so this is purely a latency
  /// optimisation: the DB webhook / cron path in
  /// `supabase/migrations/friendships.sql` delivers the same row regardless,
  /// and the function claims each row exactly once. Failure is ignored on
  /// purpose — a friend request must not appear to have failed because a push
  /// could not be hurried along.
  void _nudgeNotificationFunction() {
    final client = _supabaseOrNull;
    if (client == null) return;
    unawaited(
      client.functions
          .invoke('send-friend-event-notifications', body: const {})
          .catchError((Object e) {
        debugPrint('FriendService: notification nudge failed (ignored): $e');
        // The return value is discarded; the drain path still delivers.
        return FunctionResponse(status: 0);
      }),
    );
  }
}
