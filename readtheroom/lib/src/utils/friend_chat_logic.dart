// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Pure friend-chat logic: the [FriendEvent] value object, the timeline
/// merge/dedupe reducer, reaction attachment, unread derivation, the lick
/// cooldown, and forward-picker filtering.
///
/// Everything here is dependency-free (no Flutter, no Supabase) so the rules
/// `FriendChatService` and the chat overlay depend on are unit-testable without
/// a backend or a Realtime connection. Implements
/// networks-update-design-2026-07-17.md §5.4 / §6.4 and the RPC contracts in
/// `supabase/migrations/friend_events.sql`; OQ-2's 10-minute lick window lives
/// here as [kLickCooldown], mirroring the server's own check.
library;

/// Server-side `friend_events.type` vocabulary.
///
/// `unknown` exists so a future event type round-trips as an inert row instead
/// of throwing inside a timeline the user is already looking at.
enum FriendEventKind { lick, forward, reaction, unknown }

FriendEventKind friendEventKindFromString(String? raw) {
  switch ((raw ?? '').trim().toLowerCase()) {
    case 'lick':
      return FriendEventKind.lick;
    case 'forward':
      return FriendEventKind.forward;
    case 'reaction':
      return FriendEventKind.reaction;
    default:
      return FriendEventKind.unknown;
  }
}

/// One row of `friend_events`, as returned by `get_friend_timeline()`,
/// `send_friend_event()`'s `event` envelope, or a Realtime INSERT payload.
///
/// The three sources agree on the table's own columns and differ only in the
/// joined question fields, which `get_friend_timeline` adds and the other two
/// do not — hence [questionPrompt] / [questionType] are nullable and
/// [questionHidden] defaults to false. A forward that arrives over Realtime
/// therefore renders with its prompt missing until the next timeline fetch
/// fills it in, which is why [mergeEvents] prefers a row that *has* a prompt
/// over one that does not.
class FriendEvent {
  const FriendEvent({
    required this.id,
    required this.senderId,
    required this.recipientId,
    required this.kind,
    required this.createdAt,
    this.questionId,
    this.targetEventId,
    this.emoji,
    this.readAt,
    this.questionPrompt,
    this.questionType,
    this.questionHidden = false,
  });

  final String id;
  final String senderId;
  final String recipientId;
  final FriendEventKind kind;
  final DateTime createdAt;

  /// The forwarded question. Set on forwards, and inherited by the reactions
  /// attached to them (the RPC copies it across).
  final String? questionId;

  /// The forward a reaction hangs off. Reactions only.
  final String? targetEventId;

  /// Any single emoji (decision D8). Reactions only.
  final String? emoji;

  /// Null while unread. Only ever meaningful for the viewer as recipient.
  final DateTime? readAt;

  /// Joined by `get_friend_timeline()`; null over Realtime.
  final String? questionPrompt;
  final String? questionType;

  /// True when the question was moderated away after it was forwarded, so the
  /// card renders a tombstone instead of hidden content.
  final bool questionHidden;

  bool get isLick => kind == FriendEventKind.lick;
  bool get isForward => kind == FriendEventKind.forward;
  bool get isReaction => kind == FriendEventKind.reaction;

  bool get isUnread => readAt == null;

  /// True when [viewerId] sent this event (right-hand side of the timeline).
  bool isMine(String? viewerId) => viewerId != null && senderId == viewerId;

  /// The other party in the pair, from [viewerId]'s point of view.
  String? friendId(String? viewerId) {
    if (viewerId == null) return null;
    if (senderId == viewerId) return recipientId;
    if (recipientId == viewerId) return senderId;
    return null;
  }

  /// A forward the viewer can still open. A hidden question is kept in the
  /// timeline (the send happened) but must not be navigable.
  bool get isOpenableForward =>
      isForward && !questionHidden && (questionId ?? '').isNotEmpty;

  FriendEvent copyWith({
    FriendEventKind? kind,
    DateTime? createdAt,
    String? questionId,
    String? targetEventId,
    String? emoji,
    DateTime? readAt,
    String? questionPrompt,
    String? questionType,
    bool? questionHidden,
  }) {
    return FriendEvent(
      id: id,
      senderId: senderId,
      recipientId: recipientId,
      kind: kind ?? this.kind,
      createdAt: createdAt ?? this.createdAt,
      questionId: questionId ?? this.questionId,
      targetEventId: targetEventId ?? this.targetEventId,
      emoji: emoji ?? this.emoji,
      readAt: readAt ?? this.readAt,
      questionPrompt: questionPrompt ?? this.questionPrompt,
      questionType: questionType ?? this.questionType,
      questionHidden: questionHidden ?? this.questionHidden,
    );
  }

  /// Parses one row. Returns null when the row cannot identify itself — a row
  /// with no id could never be deduped or reacted to, so it is dropped rather
  /// than rendered as a ghost.
  static FriendEvent? fromMap(Map<String, dynamic> map) {
    final id = _str(map['id']);
    final sender = _str(map['sender_id']);
    final recipient = _str(map['recipient_id']);
    if (id == null || sender == null || recipient == null) return null;

    final created = _date(map['created_at']);
    return FriendEvent(
      id: id,
      senderId: sender,
      recipientId: recipient,
      kind: friendEventKindFromString(_str(map['type'])),
      // An unparseable timestamp would otherwise sort randomly; epoch keeps it
      // pinned to the bottom of the timeline instead.
      createdAt: created ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      questionId: _str(map['question_id']),
      targetEventId: _str(map['target_event_id']),
      emoji: _str(map['emoji']),
      readAt: _date(map['read_at']),
      questionPrompt: _str(map['question_prompt']),
      questionType: _str(map['question_type']),
      questionHidden: map['question_hidden'] == true,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is FriendEvent &&
      other.id == id &&
      other.senderId == senderId &&
      other.recipientId == recipientId &&
      other.kind == kind &&
      other.questionId == questionId &&
      other.targetEventId == targetEventId &&
      other.emoji == emoji &&
      other.readAt == readAt &&
      other.questionPrompt == questionPrompt &&
      other.questionType == questionType &&
      other.questionHidden == questionHidden;

  @override
  int get hashCode => Object.hash(id, senderId, recipientId, kind, questionId,
      targetEventId, emoji, readAt, questionPrompt, questionType,
      questionHidden);

  @override
  String toString() => 'FriendEvent($id, ${kind.name}, from $senderId)';
}

String? _str(dynamic value) {
  if (value == null) return null;
  final s = value.toString().trim();
  // PostgREST and jsonb both hand back the literal string "null" in places.
  if (s.isEmpty || s == 'null') return null;
  return s;
}

DateTime? _date(dynamic value) {
  if (value == null) return null;
  if (value is DateTime) return value;
  return DateTime.tryParse(value.toString());
}

// ---------------------------------------------------------------------------
// Timeline merge / dedupe
// ---------------------------------------------------------------------------

/// Newest first, ties broken by id — the same total order
/// `get_friend_timeline()` pages by, so a merged cache and a fresh page agree.
int byNewestEvent(FriendEvent a, FriendEvent b) {
  final byTime = b.createdAt.compareTo(a.createdAt);
  if (byTime != 0) return byTime;
  return b.id.compareTo(a.id);
}

/// Merges [incoming] into [existing], deduping by id, newest first.
///
/// Three sources write into one cache — a paged fetch, a Realtime INSERT, and
/// the optimistic echo of the user's own send — so the same event routinely
/// arrives twice. Rules:
///
/// * dedupe by `id`; the incoming copy wins, **except** that a field the
///   incoming copy does not know is not allowed to erase one the cache does.
///   Realtime payloads carry no joined question prompt, so a live forward that
///   later re-arrives from a fetch keeps its prompt, and vice versa;
/// * `read_at` is sticky once set: the client stamps it locally the moment the
///   overlay opens, and a row re-fetched from a page that predates the stamp
///   must not make the unread badge reappear.
List<FriendEvent> mergeEvents(
  List<FriendEvent> existing,
  List<FriendEvent> incoming,
) {
  final byId = <String, FriendEvent>{};
  for (final e in existing) {
    byId[e.id] = e;
  }
  for (final e in incoming) {
    final old = byId[e.id];
    byId[e.id] = old == null ? e : _reconcile(old, e);
  }
  final out = byId.values.toList()..sort(byNewestEvent);
  return List.unmodifiable(out);
}

FriendEvent _reconcile(FriendEvent old, FriendEvent fresh) {
  return fresh.copyWith(
    questionPrompt: fresh.questionPrompt ?? old.questionPrompt,
    questionType: fresh.questionType ?? old.questionType,
    questionId: fresh.questionId ?? old.questionId,
    emoji: fresh.emoji ?? old.emoji,
    targetEventId: fresh.targetEventId ?? old.targetEventId,
    readAt: fresh.readAt ?? old.readAt,
    // `false` is the default rather than a statement, so a row that knows the
    // question is hidden keeps saying so.
    questionHidden: fresh.questionHidden || old.questionHidden,
  );
}

/// Stamps [readAt] on unread events the viewer received from [senderId].
///
/// The local half of `mark_friend_events_read()`: the badge must clear on the
/// frame the overlay opens, not on the RPC's round trip.
List<FriendEvent> markReadLocally(
  List<FriendEvent> events, {
  required String viewerId,
  required String senderId,
  required DateTime at,
}) {
  var changed = false;
  final out = <FriendEvent>[];
  for (final e in events) {
    if (e.recipientId == viewerId && e.senderId == senderId && e.isUnread) {
      out.add(e.copyWith(readAt: at));
      changed = true;
    } else {
      out.add(e);
    }
  }
  return changed ? List.unmodifiable(out) : events;
}

// ---------------------------------------------------------------------------
// Display grouping
// ---------------------------------------------------------------------------

/// A timeline row: one event, plus the reactions attached to it.
class FriendChatEntry {
  const FriendChatEntry({required this.event, this.reactions = const []});

  final FriendEvent event;

  /// Reactions targeting [event], oldest first. Only ever non-empty for
  /// forwards.
  final List<FriendEvent> reactions;

  bool get hasReactions => reactions.isNotEmpty;
}

/// Builds the renderable timeline, **oldest first** (chat reading order).
///
/// Reactions are attached beneath the forward they target (§5.4) rather than
/// occupying their own row. A reaction whose target is not in the loaded page
/// is kept as its own entry instead of vanishing — losing a message because
/// its anchor fell off the end of pagination would read as data loss.
/// Unknown-kind rows are dropped: there is nothing to draw for them.
List<FriendChatEntry> buildChatEntries(List<FriendEvent> events) {
  final chronological = events.toList()
    ..sort((a, b) => byNewestEvent(b, a)); // oldest first

  final forwardIds = <String>{
    for (final e in chronological)
      if (e.isForward) e.id,
  };

  final reactionsByTarget = <String, List<FriendEvent>>{};
  for (final e in chronological) {
    if (!e.isReaction) continue;
    final target = e.targetEventId;
    if (target == null || !forwardIds.contains(target)) continue;
    (reactionsByTarget[target] ??= <FriendEvent>[]).add(e);
  }

  final out = <FriendChatEntry>[];
  for (final e in chronological) {
    if (e.kind == FriendEventKind.unknown) continue;
    if (e.isReaction) {
      final target = e.targetEventId;
      // Attached reactions are rendered by their target's entry.
      if (target != null && forwardIds.contains(target)) continue;
      out.add(FriendChatEntry(event: e));
      continue;
    }
    out.add(FriendChatEntry(
      event: e,
      reactions: reactionsByTarget[e.id] ?? const [],
    ));
  }
  return List.unmodifiable(out);
}

// ---------------------------------------------------------------------------
// Unread
// ---------------------------------------------------------------------------

/// Unread events the viewer received from [senderId].
int unreadFrom(
  List<FriendEvent> events, {
  required String viewerId,
  required String senderId,
}) {
  var n = 0;
  for (final e in events) {
    if (e.recipientId == viewerId && e.senderId == senderId && e.isUnread) n++;
  }
  return n;
}

/// Per-sender unread counts, senders with none omitted — the same shape
/// `get_friend_event_unread_counts()` returns, so a locally derived map and a
/// server one are interchangeable.
Map<String, int> unreadCountsBySender(
  List<FriendEvent> events, {
  required String viewerId,
}) {
  final out = <String, int>{};
  for (final e in events) {
    if (e.recipientId != viewerId || !e.isUnread) continue;
    out[e.senderId] = (out[e.senderId] ?? 0) + 1;
  }
  return out;
}

/// Total across a per-friend map. Negative values (never expected, but the map
/// can come from the server) are ignored rather than subtracted.
int totalUnread(Map<String, int> counts) {
  var n = 0;
  for (final v in counts.values) {
    if (v > 0) n += v;
  }
  return n;
}

/// Parses `get_friend_event_unread_counts()`'s `counts` array.
Map<String, int> parseUnreadCounts(dynamic raw) {
  if (raw is! List) return const {};
  final out = <String, int>{};
  for (final row in raw) {
    if (row is! Map) continue;
    final id = _str(row['user_id']);
    if (id == null) continue;
    final value = row['unread'];
    final n = value is num ? value.toInt() : int.tryParse('$value') ?? 0;
    if (n > 0) out[id] = n;
  }
  return out;
}

// ---------------------------------------------------------------------------
// Lick cooldown (OQ-2)
// ---------------------------------------------------------------------------

/// 1 lick per friend per 10 minutes. The server enforces the same window in
/// `send_friend_event()`; this copy exists so the button can disable itself and
/// show a countdown instead of letting the user discover the limit by failing.
const Duration kLickCooldown = Duration(minutes: 10);

/// The viewer's most recent lick *to* [friendId], or null if there is none in
/// the loaded timeline.
///
/// Derived from the cache rather than tracked separately, so it survives a
/// restart the moment the timeline loads, and cannot drift from what the server
/// will see.
DateTime? lastOutgoingLickAt(
  List<FriendEvent> events, {
  required String viewerId,
  required String friendId,
}) {
  DateTime? latest;
  for (final e in events) {
    if (!e.isLick) continue;
    if (e.senderId != viewerId || e.recipientId != friendId) continue;
    if (latest == null || e.createdAt.isAfter(latest)) latest = e.createdAt;
  }
  return latest;
}

/// How long until a lick is allowed again. [Duration.zero] when it is allowed
/// now.
///
/// A timestamp in the future (clock skew between device and server — the rows
/// are stamped by Postgres) is treated as "just licked", which errs towards the
/// button being disabled rather than towards a request the server will reject.
Duration lickCooldownRemaining({
  required DateTime? lastLickAt,
  required DateTime now,
  Duration cooldown = kLickCooldown,
}) {
  if (lastLickAt == null) return Duration.zero;
  final elapsed = now.difference(lastLickAt);
  if (elapsed.isNegative) return cooldown;
  final left = cooldown - elapsed;
  return left.isNegative ? Duration.zero : left;
}

bool canSendLick({
  required DateTime? lastLickAt,
  required DateTime now,
  Duration cooldown = kLickCooldown,
}) =>
    lickCooldownRemaining(
          lastLickAt: lastLickAt,
          now: now,
          cooldown: cooldown,
        ) ==
        Duration.zero;

/// `m:ss` countdown for the lick button. Rounds *up*, so the label never shows
/// 0:00 on a button that is still disabled.
String lickCountdownLabel(Duration remaining) {
  if (remaining <= Duration.zero) return '';
  final seconds = (remaining.inMilliseconds / 1000).ceil();
  final m = seconds ~/ 60;
  final s = seconds % 60;
  return '$m:${s.toString().padLeft(2, '0')}';
}

// ---------------------------------------------------------------------------
// Forward picker
// ---------------------------------------------------------------------------

/// Max rows the forward picker shows at once. Enough to scroll, few enough to
/// build eagerly.
const int kForwardPickerLimit = 30;

/// Filters and de-duplicates candidate questions for the forward picker.
///
/// Candidates arrive from three sources with different shapes (the current
/// QOTD, `UserService.answeredQuestions` from SharedPreferences, and search
/// results), so this is deliberately tolerant: anything without an `id` or a
/// non-blank `prompt` is dropped, which also removes the guest-migration stubs
/// that `archive_logic.dart` has to guard against. Hidden questions are
/// dropped because `send_friend_event` would refuse them anyway.
///
/// Order is the input order — callers put their most relevant source first —
/// and the first copy of an id wins, so a question that is both the QOTD and
/// already answered keeps its QOTD position.
List<Map<String, dynamic>> filterForwardCandidates(
  List<Map<String, dynamic>> candidates, {
  String query = '',
  Set<String> excludeIds = const {},
  int limit = kForwardPickerLimit,
}) {
  final needle = query.trim().toLowerCase();
  final seen = <String>{};
  final out = <Map<String, dynamic>>[];

  for (final q in candidates) {
    if (out.length >= limit) break;
    final id = _str(q['id']);
    if (id == null || excludeIds.contains(id) || !seen.add(id)) continue;
    if (q['is_hidden'] == true) continue;

    final prompt = _str(q['prompt']);
    if (prompt == null) continue;

    if (needle.isNotEmpty) {
      final haystack =
          '$prompt ${_str(q['description']) ?? ''}'.toLowerCase();
      if (!haystack.contains(needle)) continue;
    }
    out.add(q);
  }
  return out;
}

/// One-line description of an event, for the Community row subtitle and as the
/// semantics label of a chat bubble (a bare lick mark is meaningless to a
/// screen reader otherwise).
String friendEventSummary(FriendEvent event, {required bool mine}) {
  switch (event.kind) {
    case FriendEventKind.lick:
      return mine ? 'You sent a lick 🦎' : 'Sent you a lick 🦎';
    case FriendEventKind.forward:
      final prompt = event.questionHidden
          ? 'a question that is no longer available'
          : (event.questionPrompt ?? 'a question');
      return mine ? 'You sent $prompt' : 'Sent you $prompt';
    case FriendEventKind.reaction:
      final emoji = event.emoji ?? '';
      return mine
          ? 'You reacted $emoji'.trimRight()
          : 'Reacted $emoji'.trimRight();
    case FriendEventKind.unknown:
      return '';
  }
}
