// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../utils/friend_chat_logic.dart';
import 'analytics_service.dart';

/// Server error vocabulary of `send_friend_event()`
/// (`supabase/migrations/friend_events.sql`).
enum FriendChatError {
  notAuthenticated,
  self,
  invalidType,
  notFriends,
  blocked,
  lickCooldown,
  questionRequired,
  questionNotFound,
  targetRequired,
  targetNotFound,
  emojiRequired,
  emojiTooLong,
  rateLimited,
  unknown,
}

/// Outcome of a chat RPC. Mirrors `FriendResult` (WP-E) so the error → copy
/// mapping is unit-testable without a live backend.
class FriendChatResult {
  const FriendChatResult({
    required this.success,
    this.error,
    this.event,
    this.retryAfter,
  });

  const FriendChatResult.ok({FriendEvent? event})
      : this(success: true, event: event);

  const FriendChatResult.fail(FriendChatError error, {Duration? retryAfter})
      : this(success: false, error: error, retryAfter: retryAfter);

  final bool success;
  final FriendChatError? error;

  /// The row the server actually wrote, when it returned one.
  final FriendEvent? event;

  /// How long until a lick is allowed again (`lick_cooldown` only).
  final Duration? retryAfter;

  /// User-facing copy. Deliberately vague about blocks, matching WP-E: a
  /// blocked user must not be able to detect the block (§5.2 / P-5).
  String get message {
    if (success) return 'Sent';
    switch (error) {
      case FriendChatError.notAuthenticated:
        return 'Sign in to send this.';
      case FriendChatError.lickCooldown:
        final left = retryAfter;
        if (left == null || left <= Duration.zero) {
          return 'One lick at a time — try again shortly.';
        }
        return 'One lick every 10 minutes — ${lickCountdownLabel(left)} to go.';
      case FriendChatError.questionNotFound:
        return "That question isn't available any more.";
      case FriendChatError.targetNotFound:
        return "That message isn't there any more.";
      case FriendChatError.emojiTooLong:
      case FriendChatError.emojiRequired:
        return 'Pick a single emoji.';
      case FriendChatError.rateLimited:
        return "You've sent a lot today — try again tomorrow.";
      case FriendChatError.notFriends:
      case FriendChatError.blocked:
      case FriendChatError.self:
        return "Couldn't send that.";
      default:
        return 'Something went wrong. Try again.';
    }
  }

  static FriendChatError parseError(String? code) {
    switch (code) {
      case 'not_authenticated':
        return FriendChatError.notAuthenticated;
      case 'self':
        return FriendChatError.self;
      case 'invalid_type':
        return FriendChatError.invalidType;
      case 'not_friends':
        return FriendChatError.notFriends;
      case 'blocked':
        return FriendChatError.blocked;
      case 'lick_cooldown':
        return FriendChatError.lickCooldown;
      case 'question_required':
        return FriendChatError.questionRequired;
      case 'question_not_found':
        return FriendChatError.questionNotFound;
      case 'target_required':
        return FriendChatError.targetRequired;
      case 'target_not_found':
        return FriendChatError.targetNotFound;
      case 'emoji_required':
        return FriendChatError.emojiRequired;
      case 'emoji_too_long':
        return FriendChatError.emojiTooLong;
      case 'rate_limited':
        return FriendChatError.rateLimited;
      default:
        return FriendChatError.unknown;
    }
  }
}

/// Friend chat: licks, question forwards and emoji reactions
/// (networks-update-design-2026-07-17.md §5.4, WP-F).
///
/// Registered in `main.dart`'s provider tree. Holds a per-friend timeline cache
/// and the unread counts that badge the Community tab, and is **the app's first
/// Supabase Realtime consumer**: one channel on `friend_events` filtered to
/// `recipient_id = <me>`, with a 500 ms debounced flush so a burst of licks is
/// one rebuild rather than ten.
///
/// Degradation is deliberate at every level. No Realtime (publication not
/// enabled, websocket blocked, channel error) → a 15 s poll of
/// `get_friend_event_unread_counts()`. No migration at all → every RPC failure
/// is swallowed, the overlay shows an empty timeline, and the Community tab is
/// unaffected.
class FriendChatService extends ChangeNotifier {
  FriendChatService({
    SupabaseClient? client,
    bool listenToAuth = true,
    bool enableRealtime = true,
  })  : _client = client,
        _enableRealtime = enableRealtime {
    if (listenToAuth) _subscribeToAuth();
  }

  final SupabaseClient? _client;
  final bool _enableRealtime;

  /// How long incoming Realtime inserts are buffered before one flush.
  static const Duration kRealtimeDebounce = Duration(milliseconds: 500);

  /// Fallback poll interval when Realtime is unavailable.
  static const Duration kFallbackPollInterval = Duration(seconds: 15);

  /// Timeline page size. Matches `get_friend_timeline`'s default.
  static const int kPageSize = 50;

  /// friendId → events, newest first.
  final Map<String, List<FriendEvent>> _timelines = {};

  /// friendId → unread count. The single source for every badge: the server
  /// seeds it, Realtime bumps it, [markRead] clears it. Deriving it from
  /// [_timelines] instead would under-count every friend whose chat has never
  /// been opened on this device.
  Map<String, int> _unread = const {};

  final Set<String> _loadingTimelines = {};
  final Map<String, bool> _hasMore = {};

  /// Friends whose chat is gone for good on this device (blocked, unfriended).
  /// Realtime inserts from them are dropped on arrival — item 7 of the WP-F
  /// brief: a block must silence the feed immediately, without waiting for the
  /// server's own teardown to propagate.
  final Set<String> _suppressed = {};

  /// Licks sent but not yet echoed back by the server, so the button's
  /// countdown starts on the tap rather than on the round trip.
  final Map<String, DateTime> _pendingLicks = {};

  /// The chat currently on screen. Events from this friend do not bump the
  /// badge — they are about to be marked read.
  String? _activeFriendId;

  RealtimeChannel? _channel;
  Timer? _debounce;
  Timer? _poll;
  StreamSubscription<AuthState>? _authSubscription;
  final List<FriendEvent> _pendingIncoming = [];
  bool _realtimeConnected = false;
  bool _unreadLoaded = false;

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

  String? get viewerId => _supabaseOrNull?.auth.currentUser?.id;
  bool get isAuthenticated => viewerId != null;

  // --- reads -----------------------------------------------------------------

  /// Events for one friend, newest first. Never null — an un-fetched chat is
  /// simply empty.
  List<FriendEvent> timelineFor(String friendId) =>
      _timelines[friendId] ?? const [];

  /// Render-ready rows, oldest first, with reactions attached to their forwards.
  List<FriendChatEntry> entriesFor(String friendId) =>
      buildChatEntries(timelineFor(friendId));

  bool isLoadingTimeline(String friendId) =>
      _loadingTimelines.contains(friendId);

  bool hasMore(String friendId) => _hasMore[friendId] ?? false;

  Map<String, int> get unreadCounts => Map.unmodifiable(_unread);

  int unreadFor(String friendId) => _unread[friendId] ?? 0;

  int get totalUnreadCount => totalUnread(_unread);

  bool get hasUnread => totalUnreadCount > 0;

  bool get isUnreadLoaded => _unreadLoaded;

  /// True while Realtime is connected. False means the fallback poll is (or
  /// should be) carrying the unread counts.
  bool get isLive => _realtimeConnected;

  /// When the viewer last licked [friendId], including a lick still in flight.
  DateTime? lastLickAt(String friendId) {
    final me = viewerId;
    if (me == null) return null;
    final fromTimeline = lastOutgoingLickAt(
      timelineFor(friendId),
      viewerId: me,
      friendId: friendId,
    );
    final pending = _pendingLicks[friendId];
    if (fromTimeline == null) return pending;
    if (pending == null) return fromTimeline;
    return pending.isAfter(fromTimeline) ? pending : fromTimeline;
  }

  /// Mirrors the server's OQ-2 window so the button can disable itself with a
  /// countdown instead of letting the user discover the limit by failing.
  Duration lickCooldownFor(String friendId, {DateTime? now}) =>
      lickCooldownRemaining(
        lastLickAt: lastLickAt(friendId),
        now: now ?? DateTime.now().toUtc(),
      );

  bool canLick(String friendId, {DateTime? now}) =>
      lickCooldownFor(friendId, now: now) == Duration.zero;

  // --- lifecycle -------------------------------------------------------------

  /// Loads unread counts and opens the Realtime channel. Safe to call
  /// repeatedly; idempotent per auth session.
  Future<void> start() async {
    if (!isAuthenticated) return;
    await loadUnreadCounts();
    _openRealtime();
  }

  void _subscribeToAuth() {
    try {
      _authSubscription =
          _supabase.auth.onAuthStateChange.listen((state) async {
        switch (state.event) {
          case AuthChangeEvent.signedIn:
          case AuthChangeEvent.initialSession:
            await start();
            break;
          case AuthChangeEvent.signedOut:
            clear();
            break;
          default:
            break;
        }
      });
    } catch (e) {
      debugPrint('FriendChatService auth subscription unavailable: $e');
    }
  }

  /// Drops every cached chat and closes the feed. Called on sign-out.
  void clear() {
    _closeRealtime();
    _poll?.cancel();
    _poll = null;
    _debounce?.cancel();
    _debounce = null;
    _pendingIncoming.clear();
    _timelines.clear();
    _loadingTimelines.clear();
    _hasMore.clear();
    _pendingLicks.clear();
    _suppressed.clear();
    _unread = const {};
    _unreadLoaded = false;
    _activeFriendId = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _authSubscription?.cancel();
    _debounce?.cancel();
    _poll?.cancel();
    _closeRealtime();
    super.dispose();
  }

  // --- Realtime --------------------------------------------------------------

  /// Opens the single `friend_events` channel.
  ///
  /// The `recipient_id = me` filter is a bandwidth optimisation, not the
  /// security boundary — the table's RLS policy is (`friend_events.sql`). Only
  /// INSERT is subscribed to: `read_at` updates are stamped locally, and
  /// deletes arrive only as a primary key under the default replica identity,
  /// which the overlay does not need.
  void _openRealtime() {
    if (!_enableRealtime || _channel != null) return;
    final client = _supabaseOrNull;
    final me = viewerId;
    if (client == null || me == null) return;

    try {
      final channel = client.channel('friend_events:$me');
      channel
          .onPostgresChanges(
            event: PostgresChangeEvent.insert,
            schema: 'public',
            table: 'friend_events',
            filter: PostgresChangeFilter(
              type: PostgresChangeFilterType.eq,
              column: 'recipient_id',
              value: me,
            ),
            callback: _onRealtimeInsert,
          )
          .subscribe((status, error) {
        switch (status) {
          case RealtimeSubscribeStatus.subscribed:
            _realtimeConnected = true;
            _stopFallbackPoll();
            notifyListeners();
            break;
          case RealtimeSubscribeStatus.channelError:
          case RealtimeSubscribeStatus.timedOut:
          case RealtimeSubscribeStatus.closed:
            // Publication not enabled, websocket blocked, token expired — all
            // look the same from here, and all mean the same thing: poll.
            debugPrint('FriendChatService: realtime $status ($error)');
            _realtimeConnected = false;
            _startFallbackPoll();
            notifyListeners();
            break;
        }
      });
      _channel = channel;
    } catch (e) {
      debugPrint('FriendChatService: realtime unavailable: $e');
      _realtimeConnected = false;
      _startFallbackPoll();
    }
  }

  void _closeRealtime() {
    final channel = _channel;
    _channel = null;
    _realtimeConnected = false;
    if (channel == null) return;
    try {
      _supabaseOrNull?.removeChannel(channel);
    } catch (e) {
      debugPrint('FriendChatService: removeChannel failed (ignored): $e');
    }
  }

  void _onRealtimeInsert(PostgresChangePayload payload) {
    final event = FriendEvent.fromMap(Map<String, dynamic>.from(payload.newRecord));
    if (event == null) return;
    // A blocked friend's events stop existing for this client at once, without
    // waiting for the server's teardown to propagate.
    if (_suppressed.contains(event.senderId)) return;
    _pendingIncoming.add(event);
    _debounce?.cancel();
    _debounce = Timer(kRealtimeDebounce, _flushIncoming);
  }

  /// Applies the buffered inserts in one pass — one rebuild for a burst.
  void _flushIncoming() {
    _debounce = null;
    if (_pendingIncoming.isEmpty) return;
    final batch = List<FriendEvent>.from(_pendingIncoming);
    _pendingIncoming.clear();

    final me = viewerId;
    if (me == null) return;

    final unread = Map<String, int>.from(_unread);
    var changed = false;

    for (final event in batch) {
      final friendId = event.friendId(me);
      if (friendId == null || _suppressed.contains(friendId)) continue;

      // Only cache into a chat that is already loaded: seeding a half-timeline
      // for a chat the user has never opened would render as a conversation
      // with the middle missing.
      final existing = _timelines[friendId];
      if (existing != null) {
        _timelines[friendId] = mergeEvents(existing, [event]);
        changed = true;
      }

      if (event.recipientId == me && event.isUnread && friendId != _activeFriendId) {
        unread[friendId] = (unread[friendId] ?? 0) + 1;
        changed = true;
      }
    }

    if (changed) {
      _unread = Map.unmodifiable(unread);
      notifyListeners();
    }
  }

  void _startFallbackPoll() {
    if (_poll != null || !_enableRealtime) return;
    _poll = Timer.periodic(kFallbackPollInterval, (_) {
      if (!isAuthenticated) return;
      loadUnreadCounts();
    });
  }

  void _stopFallbackPoll() {
    _poll?.cancel();
    _poll = null;
  }

  // --- unread ----------------------------------------------------------------

  /// Replaces the unread map from `get_friend_event_unread_counts()`.
  Future<void> loadUnreadCounts() async {
    if (!isAuthenticated) return;
    try {
      final result = await _supabase.rpc('get_friend_event_unread_counts');
      if (result is Map && result['success'] == true) {
        _unread = Map.unmodifiable(parseUnreadCounts(result['counts']));
        _unreadLoaded = true;
        notifyListeners();
      }
    } catch (e) {
      // Migration not deployed, offline, signed out mid-flight — keep whatever
      // the badge already showed rather than flashing it away.
      debugPrint('FriendChatService.loadUnreadCounts failed: $e');
    }
  }

  /// Marks everything from [friendId] read: locally first (the badge must clear
  /// on the frame the overlay opens), then on the server.
  Future<void> markRead(String friendId) async {
    final me = viewerId;
    if (me == null) return;

    final existing = _timelines[friendId];
    if (existing != null) {
      _timelines[friendId] = markReadLocally(
        existing,
        viewerId: me,
        senderId: friendId,
        at: DateTime.now().toUtc(),
      );
    }
    if (_unread.containsKey(friendId)) {
      final next = Map<String, int>.from(_unread)..remove(friendId);
      _unread = Map.unmodifiable(next);
    }
    notifyListeners();

    try {
      await _supabase.rpc('mark_friend_events_read',
          params: {'p_friend': friendId});
    } catch (e) {
      debugPrint('FriendChatService.markRead failed: $e');
    }
  }

  /// The chat currently on screen, if any.
  String? get activeFriendId => _activeFriendId;

  /// Tells the service which chat is on screen, so its incoming events skip the
  /// badge. Pass null on close.
  void setActiveFriend(String? friendId) {
    if (_activeFriendId == friendId) return;
    _activeFriendId = friendId;
  }

  /// Clears the active chat **only if it is still [friendId]**.
  ///
  /// An overlay's `dispose` runs after the next one's `initState` when the user
  /// taps straight from one chat into another (a notification tap over an open
  /// sheet), so an unconditional clear would blank the chat that just opened
  /// and let its own events badge the tab.
  void clearActiveFriend(String friendId) {
    if (_activeFriendId == friendId) _activeFriendId = null;
  }

  // --- timeline --------------------------------------------------------------

  /// Loads one page of the pair timeline.
  ///
  /// [loadMore] pages backwards from the oldest cached event; without it the
  /// newest page is fetched and merged (never replacing the cache, so an event
  /// that arrived over Realtime mid-fetch is not lost).
  Future<void> loadTimeline(String friendId, {bool loadMore = false}) async {
    if (!isAuthenticated || _loadingTimelines.contains(friendId)) return;
    if (loadMore && !(hasMore(friendId))) return;

    _loadingTimelines.add(friendId);
    notifyListeners();
    try {
      final cached = timelineFor(friendId);
      final before = loadMore && cached.isNotEmpty
          ? cached.last.createdAt.toUtc().toIso8601String()
          : null;

      final result = await _supabase.rpc('get_friend_timeline', params: {
        'p_friend': friendId,
        'p_before': before,
        'p_limit': kPageSize,
      });

      final page = _parseEvents(result);
      _timelines[friendId] = mergeEvents(cached, page);
      // A short page means the end; a full one might not be, so keep the
      // affordance until a page proves otherwise.
      _hasMore[friendId] = page.length >= kPageSize;
    } catch (e) {
      debugPrint('FriendChatService.loadTimeline failed: $e');
      _hasMore[friendId] ??= false;
    } finally {
      _loadingTimelines.remove(friendId);
      notifyListeners();
    }
  }

  static List<FriendEvent> _parseEvents(dynamic raw) {
    if (raw is! List) return const [];
    final out = <FriendEvent>[];
    for (final row in raw) {
      if (row is Map) {
        final event = FriendEvent.fromMap(Map<String, dynamic>.from(row));
        if (event != null) out.add(event);
      }
    }
    return out;
  }

  // --- writes ----------------------------------------------------------------

  /// Sends a lick. Client-side cooldown first (the button should already be
  /// disabled, but a race between the timer and the tap is cheap to lose here),
  /// then the RPC, whose own window is the authority.
  Future<FriendChatResult> sendLick(String friendId,
      {String surface = 'chat_overlay'}) async {
    if (!isAuthenticated) {
      return const FriendChatResult.fail(FriendChatError.notAuthenticated);
    }
    final remaining = lickCooldownFor(friendId);
    if (remaining > Duration.zero) {
      // Review 2026-09-22 D3: a lick the cooldown ate is not a lick the user
      // declined to send, and until now the two were the same silence.
      unawaited(AnalyticsService().trackEvent('friend_lick_blocked', {
        'reason': 'cooldown',
        'surface': surface,
      }));
      return FriendChatResult.fail(FriendChatError.lickCooldown,
          retryAfter: remaining);
    }

    // Start the countdown on the tap, not on the response.
    _pendingLicks[friendId] = DateTime.now().toUtc();
    notifyListeners();

    final result = await _send(
      friendId: friendId,
      type: 'lick',
    );

    if (!result.success) {
      // Keep the cooldown if the server says we are inside its window — it
      // knows about licks this device never saw.
      if (result.error != FriendChatError.lickCooldown) {
        _pendingLicks.remove(friendId);
      }
      notifyListeners();
      unawaited(AnalyticsService()
          .trackRpcFailed('send_lick', reason: result.error?.name));
      return result;
    }

    // `surface` makes the nudge funnel joinable:
    // `network_not_enough_cta_tapped` -> `friend_lick_sent` (review D3). The
    // map used to be empty, so it could not be joined to anything.
    unawaited(AnalyticsService()
        .trackEvent('friend_lick_sent', {'surface': surface}));
    return result;
  }

  /// Forwards a question. [source] is `overlay` or `share_menu` (§8).
  Future<FriendChatResult> forwardQuestion({
    required String friendId,
    required String questionId,
    String source = 'overlay',
  }) async {
    if (!isAuthenticated) {
      return const FriendChatResult.fail(FriendChatError.notAuthenticated);
    }
    final result = await _send(
      friendId: friendId,
      type: 'forward',
      questionId: questionId,
    );
    if (result.success) {
      unawaited(AnalyticsService()
          .trackEvent('friend_forward_sent', {'source': source}));
    }
    return result;
  }

  /// Reacts to a forward with any emoji (decision D8).
  Future<FriendChatResult> react({
    required String friendId,
    required String targetEventId,
    required String emoji,
  }) async {
    if (!isAuthenticated) {
      return const FriendChatResult.fail(FriendChatError.notAuthenticated);
    }
    final result = await _send(
      friendId: friendId,
      type: 'reaction',
      targetEventId: targetEventId,
      emoji: emoji,
    );
    if (result.success) {
      // No emoji in the payload: §8's events carry no user content.
      unawaited(AnalyticsService().trackEvent('friend_reaction_sent', const {}));
    }
    return result;
  }

  /// One `send_friend_event` call. On success the row the server wrote is
  /// merged into the cache, so the timeline shows the real id, the real
  /// timestamp, and (for reactions) the inherited question id — nothing is
  /// guessed client-side.
  Future<FriendChatResult> _send({
    required String friendId,
    required String type,
    String? questionId,
    String? targetEventId,
    String? emoji,
  }) async {
    try {
      final result = await _supabase.rpc('send_friend_event', params: {
        'p_recipient': friendId,
        'p_type': type,
        'p_question_id': questionId,
        'p_target_event_id': targetEventId,
        'p_emoji': emoji,
      });

      if (result is Map && result['success'] == true) {
        final raw = result['event'];
        FriendEvent? event;
        if (raw is Map) {
          event = FriendEvent.fromMap(Map<String, dynamic>.from(raw));
        }
        if (event != null) {
          _timelines[friendId] = mergeEvents(timelineFor(friendId), [event]);
          notifyListeners();
        }
        return FriendChatResult.ok(event: event);
      }

      final code = result is Map ? result['error']?.toString() : null;
      Duration? retryAfter;
      if (result is Map && result['retry_after_seconds'] != null) {
        final seconds = result['retry_after_seconds'];
        final value =
            seconds is num ? seconds.toInt() : int.tryParse('$seconds') ?? 0;
        if (value > 0) retryAfter = Duration(seconds: value);
      }
      return FriendChatResult.fail(FriendChatResult.parseError(code),
          retryAfter: retryAfter);
    } catch (e) {
      debugPrint('FriendChatService._send($type) failed: $e');
      // This one catch swallows EVERY failed send — lick, forward and
      // reaction alike (review 2026-09-22 D3).
      unawaited(AnalyticsService()
          .trackRpcFailed('friend_chat_send', reason: 'exception'));
      return const FriendChatResult.fail(FriendChatError.unknown);
    }
  }

  // --- teardown --------------------------------------------------------------

  /// Forgets a friend's chat and silences their feed immediately.
  ///
  /// Called after `block_user` / `unfriend` (both of which delete the rows
  /// server-side). Suppression is kept for the session so an insert already in
  /// flight — or replicated a beat late — cannot repopulate the chat the user
  /// just ended.
  void dropFriend(String friendId, {bool suppress = true}) {
    if (suppress) _suppressed.add(friendId);
    _timelines.remove(friendId);
    _loadingTimelines.remove(friendId);
    _hasMore.remove(friendId);
    _pendingLicks.remove(friendId);
    _pendingIncoming.removeWhere(
        (e) => e.senderId == friendId || e.recipientId == friendId);
    if (_unread.containsKey(friendId)) {
      final next = Map<String, int>.from(_unread)..remove(friendId);
      _unread = Map.unmodifiable(next);
    }
    if (_activeFriendId == friendId) _activeFriendId = null;
    notifyListeners();
  }

  /// Lets a previously blocked friend's events through again (after
  /// `unblock_user`). No WP-F UI calls this yet; it exists so suppression is
  /// not a one-way door.
  void unsuppressFriend(String friendId) {
    if (_suppressed.remove(friendId)) notifyListeners();
  }

  @visibleForTesting
  void debugHandleEvent(FriendEvent event) {
    if (_suppressed.contains(event.senderId)) return;
    _pendingIncoming.add(event);
    _flushIncoming();
  }

  @visibleForTesting
  bool get debugIsPolling => _poll != null;
}
