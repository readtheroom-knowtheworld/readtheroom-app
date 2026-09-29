// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../utils/friend_chat_logic.dart';
import '../friend_chat_service.dart';
import 'demo_friends_data.dart';

/// How a simulated reply is delivered. Injectable so unit tests can fire the
/// reply immediately and deterministically instead of waiting on a real timer.
typedef DemoReplyScheduler = void Function(Duration delay, void Function() run);

/// Debug-only [FriendChatService] with seeded timelines, **no Supabase and no
/// Realtime**, and a dummy friend who answers back.
///
/// Modelled on `test/friend_chat_overlay_test.dart`'s `FakeChatService` (hence
/// `listenToAuth: false, enableRealtime: false`). The base class keeps its
/// caches private, so every read and write is overridden onto local state here
/// rather than reusing the parent's — there is no code path left that could
/// reach a backend.
///
/// ## Two-way simulation
///
/// A lick, a forward or a reaction from you schedules an incoming event from
/// the friend 1.5–3 s later. It is applied through [_receive], which mirrors
/// `FriendChatService._flushIncoming` exactly (merge into the timeline, bump
/// the unread count unless that chat is on screen, notify once), so the UI
/// cannot tell a simulated event from a Realtime one. The matching local
/// notification carries the verbatim edge-function copy
/// ([demoNotificationCopy]) and a `friend_{id}` payload, so tapping it routes
/// exactly as a real push does.
///
/// ## Cooldown
///
/// The lick rate limit still applies — it is the same `lickCooldownRemaining`
/// code path — but shortened to [kDemoLickCooldown] (20 s) so the countdown can
/// actually be watched. The Community banner's tooltip says so.
class DemoFriendChatService extends FriendChatService {
  DemoFriendChatService({
    DemoNotificationSink? notificationSink,
    DemoReplyScheduler? scheduler,
    DateTime? now,
    Random? random,
  })  : _notify = notificationSink ?? showDemoFriendLocalNotification,
        _scheduler = scheduler,
        _random = random ?? Random(),
        super(listenToAuth: false, enableRealtime: false) {
    final anchor = (now ?? DateTime.now()).toUtc();
    for (final friendId in kDemoAcceptedFriendIds) {
      _timelines[friendId] =
          mergeEvents(const [], buildDemoChatHistory(friendId: friendId, now: anchor));
    }
  }

  final DemoNotificationSink _notify;
  final DemoReplyScheduler? _scheduler;
  final Random _random;

  final Map<String, List<FriendEvent>> _timelines = {};
  Map<String, int> _unread = const {};
  final Set<String> _suppressed = <String>{};
  final List<Timer> _timers = <Timer>[];

  String? _active;
  int _seq = 0;

  /// Every mutation and every scheduled reply, in order, for unit tests.
  @visibleForTesting
  final List<String> calls = <String>[];

  // --- identity --------------------------------------------------------------

  /// A fixed viewer id, so `FriendEvent.isMine` and the timeline's two sides
  /// work without an auth session.
  @override
  String? get viewerId => kDemoViewerId;

  @override
  bool get isAuthenticated => true;

  // --- reads -----------------------------------------------------------------

  @override
  List<FriendEvent> timelineFor(String friendId) =>
      _timelines[friendId] ?? const [];

  @override
  bool isLoadingTimeline(String friendId) => false;

  /// Everything is seeded up front, so there is never an older page.
  @override
  bool hasMore(String friendId) => false;

  @override
  Map<String, int> get unreadCounts => Map.unmodifiable(_unread);

  @override
  int unreadFor(String friendId) => _unread[friendId] ?? 0;

  @override
  int get totalUnreadCount => totalUnread(_unread);

  @override
  bool get hasUnread => totalUnreadCount > 0;

  @override
  bool get isUnreadLoaded => true;

  /// Honest: there is no Realtime connection in demo mode, the replies are
  /// local timers.
  @override
  bool get isLive => false;

  /// The shortened demo window. Everything else about the cooldown — where the
  /// last lick comes from, the countdown label, the button's disabled state —
  /// is the production code path.
  @override
  Duration lickCooldownFor(String friendId, {DateTime? now}) =>
      lickCooldownRemaining(
        lastLickAt: lastLickAt(friendId),
        now: now ?? DateTime.now().toUtc(),
        cooldown: kDemoLickCooldown,
      );

  @override
  String? get activeFriendId => _active;

  // --- lifecycle -------------------------------------------------------------

  @override
  Future<void> start() async {}

  @override
  Future<void> loadTimeline(String friendId, {bool loadMore = false}) async {
    calls.add('timeline:$friendId');
  }

  @override
  Future<void> loadUnreadCounts() async {}

  @override
  Future<void> markRead(String friendId) async {
    calls.add('read:$friendId');
    final existing = _timelines[friendId];
    if (existing != null) {
      _timelines[friendId] = markReadLocally(
        existing,
        viewerId: kDemoViewerId,
        senderId: friendId,
        at: DateTime.now().toUtc(),
      );
    }
    if (_unread.containsKey(friendId)) {
      _unread = Map.unmodifiable(Map<String, int>.from(_unread)..remove(friendId));
    }
    notifyListeners();
  }

  @override
  void setActiveFriend(String? friendId) {
    _active = friendId;
  }

  @override
  void clearActiveFriend(String friendId) {
    if (_active == friendId) _active = null;
  }

  @override
  void dropFriend(String friendId, {bool suppress = true}) {
    calls.add('drop:$friendId:$suppress');
    if (suppress) _suppressed.add(friendId);
    _timelines.remove(friendId);
    if (_unread.containsKey(friendId)) {
      _unread = Map.unmodifiable(Map<String, int>.from(_unread)..remove(friendId));
    }
    if (_active == friendId) _active = null;
    notifyListeners();
  }

  @override
  void unsuppressFriend(String friendId) {
    if (_suppressed.remove(friendId)) notifyListeners();
  }

  @override
  void clear() {
    _cancelTimers();
    _timelines.clear();
    _unread = const {};
    _suppressed.clear();
    _active = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _cancelTimers();
    super.dispose();
  }

  void _cancelTimers() {
    for (final timer in _timers) {
      timer.cancel();
    }
    _timers.clear();
  }

  // --- writes ----------------------------------------------------------------

  @override
  Future<FriendChatResult> sendLick(String friendId, {String surface = 'chat_overlay'}) async {
    final remaining = lickCooldownFor(friendId);
    if (remaining > Duration.zero) {
      calls.add('lick-blocked:$friendId');
      return FriendChatResult.fail(FriendChatError.lickCooldown,
          retryAfter: remaining);
    }
    calls.add('lick:$friendId');

    final event = _mine(friendId, FriendEventKind.lick);
    _append(event);
    // They lick back.
    _scheduleReply(friendId, _DemoReply.lick);
    return FriendChatResult.ok(event: event);
  }

  @override
  Future<FriendChatResult> forwardQuestion({
    required String friendId,
    required String questionId,
    String source = 'overlay',
  }) async {
    calls.add('forward:$friendId:$questionId');
    final event = _mine(
      friendId,
      FriendEventKind.forward,
      questionId: questionId,
      // No backend to join the prompt from, so a forward the *user* sends
      // renders as "A question" unless it happens to be the seeded one.
      questionPrompt:
          questionId == kDemoForwardQuestionId ? kDemoForwardQuestionPrompt : null,
      questionType:
          questionId == kDemoForwardQuestionId ? kDemoForwardQuestionType : null,
    );
    _append(event);
    // They react to what you just sent.
    _scheduleReply(friendId, _DemoReply.reaction, targetEventId: event.id);
    return FriendChatResult.ok(event: event);
  }

  @override
  Future<FriendChatResult> react({
    required String friendId,
    required String targetEventId,
    required String emoji,
  }) async {
    final trimmed = emoji.trim();
    if (trimmed.isEmpty) {
      return const FriendChatResult.fail(FriendChatError.emojiRequired);
    }
    calls.add('react:$friendId:$trimmed');

    final target = _eventById(friendId, targetEventId);
    final event = _mine(
      friendId,
      FriendEventKind.reaction,
      targetEventId: targetEventId,
      // The RPC copies the target forward's question id onto the reaction.
      questionId: target?.questionId,
      emoji: trimmed,
    );
    _append(event);
    // They pass a question of their own back.
    _scheduleReply(friendId, _DemoReply.forward);
    return FriendChatResult.ok(event: event);
  }

  // --- simulated incoming ----------------------------------------------------

  /// Applies an incoming event the way `_flushIncoming` would, then shows the
  /// push the edge function would have sent.
  Future<void> _receive(FriendEvent event, DemoFriendPushType type) async {
    final friendId = event.friendId(kDemoViewerId);
    if (friendId == null || _suppressed.contains(friendId)) return;

    _timelines[friendId] = mergeEvents(timelineFor(friendId), [event]);
    if (event.recipientId == kDemoViewerId &&
        event.isUnread &&
        friendId != _active) {
      _unread = Map.unmodifiable(
        Map<String, int>.from(_unread)
          ..[friendId] = (_unread[friendId] ?? 0) + 1,
      );
    }
    notifyListeners();

    await _notify(demoNotificationCopy(
      type,
      actorId: friendId,
      handle: kDemoFriendHandles[friendId],
      prompt: event.questionPrompt,
      emoji: event.emoji,
    ));
  }

  void _scheduleReply(String friendId, _DemoReply reply, {String? targetEventId}) {
    calls.add('reply-scheduled:$friendId:${reply.name}');
    _run(_replyDelay(), () {
      if (_suppressed.contains(friendId)) return;
      switch (reply) {
        case _DemoReply.lick:
          unawaited(_receive(
            _theirs(friendId, FriendEventKind.lick),
            DemoFriendPushType.lick,
          ));
          break;
        case _DemoReply.reaction:
          unawaited(_receive(
            _theirs(
              friendId,
              FriendEventKind.reaction,
              targetEventId: targetEventId,
              questionId: targetEventId == null
                  ? null
                  : _eventById(friendId, targetEventId)?.questionId,
              emoji: kDemoReplyReactionEmoji,
            ),
            DemoFriendPushType.reaction,
          ));
          break;
        case _DemoReply.forward:
          unawaited(_receive(
            _theirs(
              friendId,
              FriendEventKind.forward,
              questionId: kDemoForwardQuestionId,
              questionPrompt: kDemoForwardQuestionPrompt,
              questionType: kDemoForwardQuestionType,
            ),
            DemoFriendPushType.forward,
          ));
          break;
      }
    });
  }

  Duration _replyDelay() {
    final spread = kDemoReplyMaxDelay.inMilliseconds -
        kDemoReplyMinDelay.inMilliseconds;
    return Duration(
      milliseconds:
          kDemoReplyMinDelay.inMilliseconds + _random.nextInt(spread + 1),
    );
  }

  void _run(Duration delay, void Function() action) {
    final scheduler = _scheduler;
    if (scheduler != null) {
      scheduler(delay, action);
      return;
    }
    _timers.add(Timer(delay, action));
  }

  // --- plumbing --------------------------------------------------------------

  void _append(FriendEvent event) {
    final friendId = event.friendId(kDemoViewerId);
    if (friendId == null) return;
    _timelines[friendId] = mergeEvents(timelineFor(friendId), [event]);
    notifyListeners();
  }

  FriendEvent? _eventById(String friendId, String eventId) {
    for (final event in timelineFor(friendId)) {
      if (event.id == eventId) return event;
    }
    return null;
  }

  FriendEvent _mine(
    String friendId,
    FriendEventKind kind, {
    String? questionId,
    String? targetEventId,
    String? emoji,
    String? questionPrompt,
    String? questionType,
  }) =>
      FriendEvent(
        id: 'demo-out-${_seq++}',
        senderId: kDemoViewerId,
        recipientId: friendId,
        kind: kind,
        createdAt: DateTime.now().toUtc(),
        questionId: questionId,
        targetEventId: targetEventId,
        emoji: emoji,
        questionPrompt: questionPrompt,
        questionType: questionType,
        // Your own events are never unread to you.
        readAt: DateTime.now().toUtc(),
      );

  FriendEvent _theirs(
    String friendId,
    FriendEventKind kind, {
    String? questionId,
    String? targetEventId,
    String? emoji,
    String? questionPrompt,
    String? questionType,
  }) =>
      FriendEvent(
        id: 'demo-in-${_seq++}',
        senderId: friendId,
        recipientId: kDemoViewerId,
        kind: kind,
        createdAt: DateTime.now().toUtc(),
        questionId: questionId,
        targetEventId: targetEventId,
        emoji: emoji,
        questionPrompt: questionPrompt,
        questionType: questionType,
      );
}

/// What the dummy friend sends back.
enum _DemoReply { lick, reaction, forward }
