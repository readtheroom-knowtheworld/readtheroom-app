// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Pure friend-graph logic: the [Friend] value object, the status machine, the
/// Community-tab partitioning/sorting, and friend-QR URL parsing.
///
/// Everything here is dependency-free (no Flutter, no Supabase) so the rules
/// that the Community tab and [FriendService] depend on are unit-testable
/// without a backend. Implements networks-update-design-2026-07-17.md §5.2 /
/// §5.3 and the `get_friends()` contract in
/// `supabase/migrations/friendships.sql`.
library;

/// Server-side `friendships.status` vocabulary.
///
/// `blocked` never reaches the client — `get_friends()` omits those rows — but
/// it is in the enum so an unexpected value round-trips instead of throwing.
enum FriendStatus { pending, accepted, blocked, unknown }

FriendStatus friendStatusFromString(String? raw) {
  switch (raw) {
    case 'pending':
      return FriendStatus.pending;
    case 'accepted':
      return FriendStatus.accepted;
    case 'blocked':
      return FriendStatus.blocked;
    default:
      return FriendStatus.unknown;
  }
}

/// One row of `get_friends()`, from the caller's perspective.
class Friend {
  const Friend({
    required this.userId,
    this.username,
    this.avatarId,
    this.status = FriendStatus.accepted,
    this.isClose = false,
    this.mutualClose = false,
    this.muted = false,
    this.requestedBy,
    this.streak,
    this.createdAt,
    this.lastEventAt,
  });

  /// The *other* party's id (`friendships.friend_id`).
  final String userId;

  /// Their handle, or null when they have not picked one yet.
  final String? username;

  /// Their `chameleon_NN` avatar id, or null for the placeholder.
  final String? avatarId;

  final FriendStatus status;

  /// The viewer marked them as close.
  final bool isClose;

  /// Both sides marked each other close — the only state that actually
  /// unlocks individual answer visibility (§5.2 / §5.5B).
  final bool mutualClose;

  final bool muted;

  /// Who initiated. While [status] is pending this yields the direction; see
  /// [isIncomingRequest] / [isOutgoingRequest].
  final String? requestedBy;

  /// Current answer streak (OQ-3 flair). Null when unknown or zero-less.
  final int? streak;

  final DateTime? createdAt;

  /// Newest chat event (lick / forward / reaction, either direction) with this
  /// friend, from `get_friends().last_event_at`; null when there is none or
  /// the server predates the field. Orders the Friends section.
  final DateTime? lastEventAt;

  /// Display handle with the leading `@`. Falls back to a neutral label rather
  /// than an empty row when a friend has not picked a handle.
  String get displayHandle =>
      (username ?? '').isEmpty ? 'A chameleon' : '@$username';

  /// Sort key: the handle, or a value that sorts last for handle-less rows.
  String get _sortKey => (username ?? '').isEmpty ? '￿' : username!;

  bool get isAccepted => status == FriendStatus.accepted;
  bool get isPending => status == FriendStatus.pending;

  /// A request *they* sent *you* — render accept / decline.
  ///
  /// Direction comes from [requestedBy]: the server stamps it with the
  /// *sender's* id on both rows, and this row's [userId] is the other party.
  /// So `requestedBy == userId` means they sent it.
  bool get isIncomingRequest =>
      isPending && requestedBy != null && requestedBy == userId;

  /// A request *you* sent *them* — render "Sent" + cancel. Anything pending
  /// that is not incoming is outgoing, including the (impossible) row with a
  /// null `requested_by`, which is safer to offer "cancel" for than "accept".
  bool get isOutgoingRequest => isPending && !isIncomingRequest;

  /// Shows streak flair only when there is a streak worth showing.
  bool get hasStreakFlair => (streak ?? 0) > 0;

  Friend copyWith({
    String? username,
    String? avatarId,
    FriendStatus? status,
    bool? isClose,
    bool? mutualClose,
    bool? muted,
    String? requestedBy,
    int? streak,
    DateTime? createdAt,
    DateTime? lastEventAt,
  }) {
    return Friend(
      userId: userId,
      username: username ?? this.username,
      avatarId: avatarId ?? this.avatarId,
      status: status ?? this.status,
      isClose: isClose ?? this.isClose,
      mutualClose: mutualClose ?? this.mutualClose,
      muted: muted ?? this.muted,
      requestedBy: requestedBy ?? this.requestedBy,
      streak: streak ?? this.streak,
      createdAt: createdAt ?? this.createdAt,
      lastEventAt: lastEventAt ?? this.lastEventAt,
    );
  }

  /// Parses one element of the `get_friends()` jsonb array. Tolerant by
  /// design: a row with an unreadable field degrades rather than blowing up
  /// the whole list.
  static Friend? fromMap(Map<String, dynamic> map) {
    final userId = map['user_id']?.toString();
    if (userId == null || userId.isEmpty) return null;

    final createdAtRaw = map['created_at']?.toString();
    final lastEventRaw = map['last_event_at']?.toString();
    final streakRaw = map['streak'];

    return Friend(
      userId: userId,
      username: _nullIfEmpty(map['username']?.toString()),
      avatarId: _nullIfEmpty(map['avatar_id']?.toString()),
      status: friendStatusFromString(map['status']?.toString()),
      isClose: map['is_close'] == true,
      mutualClose: map['mutual_close'] == true,
      muted: map['muted'] == true,
      requestedBy: _nullIfEmpty(map['requested_by']?.toString()),
      streak: streakRaw is num
          ? streakRaw.toInt()
          : int.tryParse(streakRaw?.toString() ?? ''),
      createdAt: createdAtRaw == null ? null : DateTime.tryParse(createdAtRaw),
      lastEventAt:
          lastEventRaw == null ? null : DateTime.tryParse(lastEventRaw),
    );
  }

  static String? _nullIfEmpty(String? v) =>
      (v == null || v.isEmpty || v == 'null') ? null : v;

  @override
  bool operator ==(Object other) =>
      other is Friend &&
      other.userId == userId &&
      other.username == username &&
      other.avatarId == avatarId &&
      other.status == status &&
      other.isClose == isClose &&
      other.mutualClose == mutualClose &&
      other.muted == muted &&
      other.requestedBy == requestedBy &&
      other.streak == streak;

  @override
  int get hashCode => Object.hash(userId, username, avatarId, status, isClose,
      mutualClose, muted, requestedBy, streak);

  @override
  String toString() => 'Friend($displayHandle, ${status.name}'
      '${isClose ? ', close' : ''}${mutualClose ? '+mutual' : ''})';
}

/// The Community tab's sections (§5.3, top → bottom after the identity card).
class FriendSections {
  const FriendSections({
    required this.incoming,
    required this.outgoing,
    required this.closeFriends,
    required this.friends,
  });

  /// Requests waiting on the viewer — accept / decline.
  final List<Friend> incoming;

  /// Requests the viewer sent — "Sent", cancellable.
  final List<Friend> outgoing;

  /// Accepted friends the viewer marked close.
  final List<Friend> closeFriends;

  /// Accepted friends the viewer has not marked close.
  final List<Friend> friends;

  /// Every accepted friend, close or not.
  List<Friend> get allAccepted => [...closeFriends, ...friends];

  int get acceptedCount => closeFriends.length + friends.length;
  int get pendingCount => incoming.length + outgoing.length;

  /// True when there is nothing at all to show — the §5.3(4) empty state.
  bool get isEmpty => acceptedCount == 0 && pendingCount == 0;

  static const FriendSections empty = FriendSections(
    incoming: [],
    outgoing: [],
    closeFriends: [],
    friends: [],
  );
}

/// Splits `get_friends()` output into the Community tab's sections.
///
/// [viewerId] is the signed-in user's id, used only to drop a self-row should
/// one ever appear (the `friendships_no_self` CHECK should make that
/// impossible). Request *direction* needs no viewer id: it falls out of
/// `requested_by` vs the row's `user_id` — see [Friend.isIncomingRequest].
///
/// Ordering within each section:
///   * pending — newest first, so a fresh request is at the top;
///   * close friends — mutual close ("Sharing answers")
///     first, then one-sided ("Sharing your answers"), each tier by
///     latest chat activity, no-chat rows last, ties by handle;
///   * friends — by latest chat activity, no-chat rows last, ties by handle.
///
/// Blocked rows and rows for the viewer themselves are dropped, as are exact
/// duplicate `user_id`s (last one wins — a defensive guard, the unique
/// constraint should make it impossible).
FriendSections partitionFriends(
  List<Friend> all, {
  required String? viewerId,
}) {
  final deduped = <String, Friend>{};
  for (final f in all) {
    if (f.userId.isEmpty) continue;
    if (viewerId != null && f.userId == viewerId) continue;
    if (f.status == FriendStatus.blocked || f.status == FriendStatus.unknown) {
      continue;
    }
    deduped[f.userId] = f;
  }

  final incoming = <Friend>[];
  final outgoing = <Friend>[];
  final close = <Friend>[];
  final regular = <Friend>[];

  for (final f in deduped.values) {
    if (f.isPending) {
      (f.isIncomingRequest ? incoming : outgoing).add(f);
    } else if (f.isAccepted) {
      (f.isClose ? close : regular).add(f);
    }
  }

  int byNewest(Friend a, Friend b) {
    final at = a.createdAt;
    final bt = b.createdAt;
    if (at == null && bt == null) return byHandle(a, b);
    if (at == null) return 1;
    if (bt == null) return -1;
    final c = bt.compareTo(at);
    return c != 0 ? c : byHandle(a, b);
  }

  // Friends: most recent chat activity first, then by handle; friends with no
  // chat yet come after everyone who has one (owner decision 2026-09-22). The
  // Community tab lists close friends above regular ones in a single section.
  int byActivity(Friend a, Friend b) {
    final at = a.lastEventAt;
    final bt = b.lastEventAt;
    if (at == null && bt == null) return byHandle(a, b);
    if (at == null) return 1;
    if (bt == null) return -1;
    final c = bt.compareTo(at);
    return c != 0 ? c : byHandle(a, b);
  }

  // Close friends: the ones sharing answers with each other first (mutual
  // close), then the ones the viewer shares with one-sidedly, each tier by
  // activity (owner decision 2026-09-23). Regular friends follow both.
  int byMutualThenActivity(Friend a, Friend b) {
    if (a.mutualClose != b.mutualClose) return a.mutualClose ? -1 : 1;
    return byActivity(a, b);
  }

  incoming.sort(byNewest);
  outgoing.sort(byNewest);
  close.sort(byMutualThenActivity);
  regular.sort(byActivity);

  return FriendSections(
    incoming: incoming,
    outgoing: outgoing,
    closeFriends: close,
    friends: regular,
  );
}

/// Case-insensitive handle order, handle-less rows last, ties broken by id so
/// the sort is total (and therefore stable across reloads).
int byHandle(Friend a, Friend b) {
  final c = a._sortKey.toLowerCase().compareTo(b._sortKey.toLowerCase());
  return c != 0 ? c : a.userId.compareTo(b.userId);
}

// ---------------------------------------------------------------------------
// Status machine
// ---------------------------------------------------------------------------

/// What the viewer can do with a given row. Drives the per-row overflow menu
/// and keeps the "is this action legal right now" rule in one testable place
/// instead of scattered across the widget tree.
enum FriendAction {
  accept,
  decline,
  cancelRequest,

  /// Opens the on-device nickname dialog. Local only: no RPC, no row change.
  setNickname,
  setClose,
  unsetClose,
  unfriend,
  block,
}

/// The actions legal for [friend] right now.
Set<FriendAction> availableActions(Friend friend) {
  if (friend.isPending) {
    // A pending row is either theirs to answer or ours to withdraw — never
    // both, and never close (there is no friendship to flag yet).
    if (friend.isIncomingRequest) {
      return {FriendAction.accept, FriendAction.decline, FriendAction.block};
    }
    return {FriendAction.cancelRequest, FriendAction.block};
  }
  if (friend.isAccepted) {
    return {
      FriendAction.setNickname,
      friend.isClose ? FriendAction.unsetClose : FriendAction.setClose,
      FriendAction.unfriend,
      FriendAction.block,
    };
  }
  return const {};
}

/// The row's state after [action] succeeds, or null when the row should be
/// removed from the list entirely. Used for optimistic updates; a failure
/// rolls back to the previous value.
Friend? applyAction(Friend friend, FriendAction action) {
  switch (action) {
    case FriendAction.accept:
      return friend.copyWith(status: FriendStatus.accepted);
    case FriendAction.decline:
    case FriendAction.cancelRequest:
    case FriendAction.unfriend:
    case FriendAction.block:
      return null;
    case FriendAction.setNickname:
      return friend;
    case FriendAction.setClose:
      return friend.copyWith(isClose: true);
    case FriendAction.unsetClose:
      // Reciprocity cannot survive one side dropping out.
      return friend.copyWith(isClose: false, mutualClose: false);
  }
}

// ---------------------------------------------------------------------------
// Friend QR / link
// ---------------------------------------------------------------------------

/// Host the friend app-link lives on (matches the Android intent-filter and
/// the iOS associated domain).
const String kFriendLinkHost = 'readtheroom.site';

/// Path segment for friend links: `/friend/{token}`.
const String kFriendLinkPath = 'friend';

/// Custom-scheme equivalent, used as the share fallback: `readtheroom://friend/{token}`.
const String kAppScheme = 'readtheroom';

/// 32 lowercase hex chars — the exact shape `create_friend_qr_token()` mints
/// and `add_friend_via_qr()` validates. Keeping the two in step means a
/// malformed scan is rejected on-device without a round trip.
final RegExp kFriendTokenPattern = RegExp(r'^[0-9a-f]{32}$');

bool isValidFriendToken(String? token) =>
    token != null && kFriendTokenPattern.hasMatch(token);

/// The URL encoded into the QR and shared by the "share link" button.
String friendLinkForToken(String token) =>
    'https://$kFriendLinkHost/$kFriendLinkPath/$token';

/// Custom-scheme fallback, mirroring
/// `DeepLinkService.generateFallbackLink`'s idiom.
String friendFallbackLinkForToken(String token) =>
    '$kAppScheme://$kFriendLinkPath/$token';

/// Extracts the token from any friend link the app accepts, or null when the
/// input is not one.
///
/// Accepts:
///   * `https://readtheroom.site/friend/{token}` (app link / shared link)
///   * `http://…` and any host (a QR from a staging build still resolves)
///   * `readtheroom://friend/{token}` (custom scheme — `friend` is the *host*)
///   * a bare token, so a scanner that hands back raw text still works
///
/// Rejects anything whose token is not [kFriendTokenPattern]-shaped, so a
/// question link, a random QR on a poster, or a truncated scan never reaches
/// the RPC.
String? parseFriendToken(String? raw) {
  if (raw == null) return null;
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return null;

  // A bare token (some scanners hand back just the payload).
  final lowered = trimmed.toLowerCase();
  if (kFriendTokenPattern.hasMatch(lowered)) return lowered;

  final uri = Uri.tryParse(trimmed);
  if (uri == null) return null;

  String? candidate;
  if (uri.scheme == kAppScheme) {
    // readtheroom://friend/{token} — `friend` parses as the host.
    if (uri.host == kFriendLinkPath && uri.pathSegments.isNotEmpty) {
      candidate = uri.pathSegments.first;
    }
  } else if ((uri.scheme == 'https' || uri.scheme == 'http') &&
      (uri.host == kFriendLinkHost || uri.host == 'www.$kFriendLinkHost') &&
      uri.pathSegments.length >= 2 &&
      uri.pathSegments[0] == kFriendLinkPath) {
    // Web links only from our own domain: a look-alike host must not be able
    // to hand the app a friend token.
    candidate = uri.pathSegments[1];
  }

  if (candidate == null) return null;
  final normalized = candidate.trim().toLowerCase();
  return kFriendTokenPattern.hasMatch(normalized) ? normalized : null;
}

/// True when [uri] is a friend link this app should handle — used by
/// `DeepLinkService` to claim the link before its question routing.
bool isFriendLink(Uri uri) => parseFriendToken(uri.toString()) != null;

// ---------------------------------------------------------------------------
// QR token expiry
// ---------------------------------------------------------------------------

/// Refresh the QR this long before it actually expires, so a code that is
/// about to die is not put on screen for someone to scan.
const Duration kQrRefreshMargin = Duration(minutes: 5);

/// Whether a held token still needs replacing before being displayed.
///
/// Returns true when there is no token, no expiry, the expiry has passed, or
/// it is within [kQrRefreshMargin] of passing.
bool shouldRotateQrToken({
  required String? token,
  required DateTime? expiresAt,
  required DateTime now,
}) {
  if (!isValidFriendToken(token)) return true;
  if (expiresAt == null) return true;
  return !expiresAt.isAfter(now.add(kQrRefreshMargin));
}

/// Friends who are accepted in [after] but were not accepted in [before], and
/// whose pair has no `requested_by` — the shape `add_friend_via_qr` creates.
/// A request-based acceptance always records who asked, so this deliberately
/// ignores it: that flow has its own SnackBar and push copy.
///
/// Pure so the "you're friends now" moment on the scanned phone can be tested
/// without a Supabase client. [FriendService] calls it on every reload and
/// surfaces the result on [FriendService.qrFriendAdded].
List<Friend> newlyAcceptedQrFriends(List<Friend> before, List<Friend> after) {
  final wasAccepted = <String>{
    for (final f in before)
      if (f.status == FriendStatus.accepted) f.userId,
  };
  return [
    for (final f in after)
      if (f.status == FriendStatus.accepted &&
          f.requestedBy == null &&
          !wasAccepted.contains(f.userId))
        f,
  ];
}
