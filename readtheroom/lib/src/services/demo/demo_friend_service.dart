// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/foundation.dart';

import '../../utils/friend_logic.dart';
import '../friend_service.dart';
import '../profile_service.dart';
import 'demo_friends_data.dart';

/// Debug-only [FriendService] with a seeded graph and **no Supabase calls at
/// all** — every read is served from local state and every mutation rewrites
/// that state and notifies.
///
/// Modelled on `test/community_screen_test.dart`'s `FakeFriendService` (hence
/// `listenToAuth: false` and the overridden `isAuthenticated` / `isLoaded`), so
/// the production demo and the test fake behave the same way and neither can
/// reach a backend.
///
/// Only registered by `main.dart` when [DemoFriendsMode.enabled], which is
/// clamped to false outside debug builds. See
/// `feature-documentation/demo-friends-mode-2026-09-11.md`.
class DemoFriendService extends FriendService {
  DemoFriendService({
    DemoNotificationSink? notificationSink,
    DateTime? now,
  })  : _notify = notificationSink ?? showDemoFriendLocalNotification,
        super(listenToAuth: false) {
    final anchor = now ?? DateTime.now();
    for (final friend in buildDemoFriendGraph(now: anchor)) {
      _graph[friend.userId] = friend;
    }
  }

  final DemoNotificationSink _notify;

  /// userId → row. A map rather than a list so every mutation is a point write.
  final Map<String, Friend> _graph = <String, Friend>{};

  /// Every mutation the demo performed, in order, for unit tests and for
  /// eyeballing the debug console.
  @visibleForTesting
  final List<String> calls = <String>[];

  bool _announcedIncomingRequest = false;

  // --- reads -----------------------------------------------------------------

  /// Demo mode is always "signed in": the Community tab's guest gate would
  /// otherwise hide everything this mode exists to show.
  @override
  bool get isAuthenticated => true;

  @override
  bool get isLoaded => true;

  @override
  bool get isLoading => false;

  @override
  FriendSections get sections =>
      partitionFriends(_graph.values.toList(), viewerId: kDemoViewerId);

  @override
  List<Friend> get friends => sections.allAccepted;

  @override
  List<Friend> get closeFriends => sections.closeFriends;

  @override
  List<Friend> get regularFriends => sections.friends;

  @override
  List<Friend> get pendingIncoming => sections.incoming;

  @override
  List<Friend> get pendingOutgoing => sections.outgoing;

  @override
  int get friendCount => sections.acceptedCount;

  @override
  bool get hasAnyFriends => friendCount > 0;

  @override
  bool get hasPending => sections.pendingCount > 0;

  /// The base class looks this up in its own (private, always empty) list, so
  /// it has to be overridden or every chat overlay would open on a stale
  /// `Friend`.
  @override
  Friend? friendById(String userId) => _graph[userId];

  // --- lifecycle -------------------------------------------------------------

  /// No backend to load from. The first call doubles as "first enable", which
  /// is where the seeded incoming request announces itself — the same push the
  /// real outbox would have delivered while the app was closed.
  @override
  Future<void> load() async {
    if (_announcedIncomingRequest) return;
    _announcedIncomingRequest = true;
    final incoming = _graph[kDemoIncomingId];
    if (incoming == null || !incoming.isIncomingRequest) return;
    await _push(
      DemoFriendPushType.friendRequest,
      actorId: incoming.userId,
      handle: incoming.username,
    );
  }

  @override
  Future<void> refresh() async {}

  @override
  void clear() {}

  // --- writes ----------------------------------------------------------------

  /// Always finds [kDemoLookupHandle], whatever was typed, so the "add by
  /// handle" sheet has something to resolve without a backend.
  @override
  Future<FriendLookupResult> lookupByUsername(String rawHandle) async {
    final handle = rawHandle.trim().toLowerCase().replaceFirst('@', '');
    calls.add('lookup:$handle');
    if (handle.isEmpty) {
      return const FriendLookupResult(success: true, found: false);
    }
    return const FriendLookupResult(
      success: true,
      found: true,
      userId: kDemoLookupId,
      username: kDemoLookupHandle,
      avatarId: kDemoLookupAvatarId,
    );
  }

  @override
  Future<FriendResult> sendFriendRequest(
    String userId, {
    String method = 'username',
    String? username,
    String? avatarId,
  }) async {
    calls.add('request:$userId');
    final existing = _graph[userId];
    if (existing != null && existing.isAccepted) {
      return const FriendResult.fail(FriendError.alreadyFriends);
    }
    if (existing != null && existing.isPending) {
      return const FriendResult.fail(FriendError.alreadyPending);
    }
    _write(Friend(
      userId: userId,
      username: username ?? kDemoFriendHandles[userId],
      avatarId: avatarId ?? kDemoLookupAvatarId,
      status: FriendStatus.pending,
      requestedBy: kDemoViewerId,
      createdAt: DateTime.now(),
    ));
    return const FriendResult.ok();
  }

  @override
  Future<FriendResult> respondToRequest(String userId, bool accept, {String direction = 'incoming'}) async {
    calls.add('respond:$userId:$accept');
    final existing = _graph[userId];
    if (existing == null || !existing.isPending) {
      return const FriendResult.fail(FriendError.noPendingRequest);
    }

    if (!accept) {
      _remove(userId);
      return const FriendResult.ok();
    }

    _write(existing.copyWith(status: FriendStatus.accepted));
    // In production this push goes to the *other* side; demo mirrors it back so
    // the accept copy is visible on the one device there is.
    await _push(
      DemoFriendPushType.friendAccepted,
      actorId: userId,
      handle: existing.username,
    );
    return const FriendResult.ok();
  }

  @override
  Future<FriendResult> cancelRequest(String userId) async {
    calls.add('cancel:$userId');
    if (_graph[userId]?.isPending != true) {
      return const FriendResult.fail(FriendError.noPendingRequest);
    }
    _remove(userId);
    return const FriendResult.ok();
  }

  /// Reciprocity is only granted to [kDemoReciprocatingCloseFriends], so both
  /// halves of the §5.2 close-friend copy — "both ways" and "they have to add
  /// you back too" — are reachable in demo.
  @override
  Future<FriendResult> setCloseFriend(String userId, bool close, {String surface = 'community_menu'}) async {
    calls.add('close:$userId:$close');
    final existing = _graph[userId];
    if (existing == null || !existing.isAccepted) {
      return const FriendResult.fail(FriendError.notFriends);
    }
    _write(existing.copyWith(
      isClose: close,
      mutualClose: close && kDemoReciprocatingCloseFriends.contains(userId),
    ));
    return const FriendResult.ok();
  }

  @override
  Future<FriendResult> setFriendMuted(String userId, bool muted) async {
    calls.add('mute:$userId:$muted');
    final existing = _graph[userId];
    if (existing == null || !existing.isAccepted) {
      return const FriendResult.fail(FriendError.notFriends);
    }
    _write(existing.copyWith(muted: muted));
    return const FriendResult.ok();
  }

  @override
  Future<FriendResult> unfriend(String userId) async {
    calls.add('unfriend:$userId');
    if (_graph[userId] == null) {
      return const FriendResult.fail(FriendError.notFriends);
    }
    _remove(userId);
    return const FriendResult.ok();
  }

  @override
  Future<FriendResult> blockUser(String userId, {String surface = 'community'}) async {
    calls.add('block:$userId');
    _remove(userId);
    return const FriendResult.ok();
  }

  @override
  Future<({String token, DateTime? expiresAt})?> createQrToken() async {
    calls.add('qr');
    return (
      token: kDemoQrToken,
      expiresAt: DateTime.now().add(const Duration(hours: 24)),
    );
  }

  @override
  Future<FriendResult> addFriendViaQr(String token) async {
    calls.add('qrAdd:$token');
    final friend = Friend(
      userId: kDemoLookupId,
      username: kDemoLookupHandle,
      avatarId: kDemoLookupAvatarId,
      status: FriendStatus.accepted,
      createdAt: DateTime.now(),
    );
    final alreadyFriends = _graph[kDemoLookupId]?.isAccepted == true;
    _write(friend);
    return FriendResult.ok(friend: friend, alreadyFriends: alreadyFriends);
  }

  /// Nothing is stashed in demo mode: there is no token to redeem and no
  /// backend to redeem it against.
  @override
  Future<FriendResult?> redeemStashedQrToken() async => null;

  // --- plumbing --------------------------------------------------------------

  void _write(Friend friend) {
    _graph[friend.userId] = friend;
    notifyListeners();
  }

  void _remove(String userId) {
    _graph.remove(userId);
    notifyListeners();
  }

  Future<void> _push(
    DemoFriendPushType type, {
    required String actorId,
    required String? handle,
  }) =>
      _notify(demoNotificationCopy(type, actorId: actorId, handle: handle));
}

/// Debug-only [ProfileService] so the Community tab's identity card shows a
/// handle and an avatar instead of "Pick a name".
///
/// The real service degrades rather than throwing without a backend, so this
/// exists for the *screenshot*, not for safety.
class DemoProfileService extends ProfileService {
  DemoProfileService() : super(listenToAuth: false);

  @override
  bool get isAuthenticated => true;

  @override
  String? get username => kDemoViewerHandle;

  @override
  String? get avatarId => kDemoViewerAvatarId;

  @override
  Future<void> load() async {}
}
