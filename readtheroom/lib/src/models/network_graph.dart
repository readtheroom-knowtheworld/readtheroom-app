// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The shared shapes of the "Your network" surface — the ego graph and the
// close-friend row.
//
// These types used to live in `utils/demo_network_data.dart`, next to the
// fabricated preview data, because nothing real produced them yet. Since the
// response linkage (2026-09-22) the server does: `get_network_results` returns
// exactly this node shape and `get_close_friend_answers` returns exactly this
// answer shape, so the types moved here and the demo builders now import them
// like anyone else. `demo_network_data.dart` re-exports them, and keeps
// `DemoAnswerKind` as an alias, so existing call sites did not have to move.
//
// The privacy model lives in the DATA, not in the widgets that draw it. The
// server decides what each node is allowed to say; the client's only job is to
// render null as grey and never invent an answer:
//
//   • `answerKind == null` means GREY, whatever `kind` says. A close friend who
//     turned this answer's share flag off arrives as a close-friend node with a
//     null answer, and must look identical to a regular friend's node — if the
//     opt-out were visible, it would not be an opt-out.
//   • `answered == true` with a null `answerKind` is not a bug and never gets a
//     "hidden answer" badge.
//   • A friend-of-friend carries no handle and no user id. Never make one
//     tappable through to a profile.
//
// Server contract: scripts/response_linkage_04_read_rpcs.sql
// Docs:            feature-documentation/response-linkage-design-2026-09-22.md §2.3

/// Whether an answer is an approval-slider value or a multiple-choice option.
///
/// Text answers have no kind at all: close friends see picks and slider
/// positions only, never a text body (owner decision D-1), so every node on a
/// text question arrives with a null kind.
enum NetworkAnswerKind {
  approval,
  multipleChoice;

  /// `"approval"` / `"multiple_choice"` from the RPC; null for anything else,
  /// including the deliberate null the server sends for a withheld answer.
  static NetworkAnswerKind? fromJson(dynamic value) {
    switch (value?.toString()) {
      case 'approval':
        return NetworkAnswerKind.approval;
      case 'multiple_choice':
        return NetworkAnswerKind.multipleChoice;
      default:
        return null;
    }
  }
}

/// A node's position in your ego network, by friendship degree.
enum NetworkNodeKind {
  /// You — the centre of the ego graph.
  self,

  /// A regular (non-close) direct friend. Their individual answer is private.
  friend,

  /// A reciprocal close friend. Shares their individual answer with you, when
  /// that answer's own share flag allows it.
  closeFriend,

  /// A friend-of-friend (2nd degree): an answer with no identity attached.
  friendOfFriend;

  static NetworkNodeKind fromJson(dynamic value) {
    switch (value?.toString()) {
      case 'self':
        return NetworkNodeKind.self;
      case 'close_friend':
        return NetworkNodeKind.closeFriend;
      case 'friend_of_friend':
        return NetworkNodeKind.friendOfFriend;
      default:
        return NetworkNodeKind.friend;
    }
  }
}

/// One node in the ego-network graph.
///
/// [parentId] defines the single edge each node exposes (to its bridging
/// friend, or to you), and the answer fields are populated only for nodes the
/// server decided are allowed to reveal one.
class NetworkGraphNode {
  /// `"self"`, `"f_<user uuid>"` for a direct friend, or `"x_<16 hex>"` for a
  /// friend-of-friend. The FoF form is salted per viewer and per question, so
  /// it is stable within one render and meaningless outside it.
  final String id;
  final NetworkNodeKind kind;

  /// The node this one draws its (only) edge to. `null` for [NetworkNodeKind.self].
  /// Friends connect to `self`; friends-of-friends connect to their bridging
  /// friend. Friends-of-friends never connect to each other.
  final String? parentId;

  /// The account behind a direct friend — the viewer already knows them. Always
  /// null on self and on every friend-of-friend.
  final String? userId;

  /// Handle to surface on tap. Present for you, friends and close friends;
  /// `null` for friends-of-friends (their identity is never exposed).
  final String? handle;

  /// Avatar key from `user_profiles.avatar_id`, on direct friends only.
  final String? avatarId;

  /// The answer, if this node is allowed to reveal one. Null means grey.
  final NetworkAnswerKind? answerKind;
  final double? approvalValue;
  final int? optionIndex;
  final String? answerLabel;

  /// Whether this person answered this question at all. True with a null
  /// [answerKind] means "answered, but you may not see it" — rendered exactly
  /// like any other grey node.
  final bool answered;

  /// On a friend node: how many of that friend's answering friends were NOT
  /// drawn because of the 3-per-friend cap. 0 everywhere else.
  final int fofOverflow;

  const NetworkGraphNode({
    required this.id,
    required this.kind,
    this.parentId,
    this.userId,
    this.handle,
    this.avatarId,
    this.answerKind,
    this.approvalValue,
    this.optionIndex,
    this.answerLabel,
    this.answered = false,
    this.fofOverflow = 0,
  });

  /// True when this node exposes a colourable answer.
  bool get hasAnswer => answerKind != null;

  /// Every node carries every field, nulled where it does not apply, so there
  /// is one shape to parse. Unknown keys are ignored and missing ones tolerated.
  factory NetworkGraphNode.fromJson(Map<String, dynamic> json) {
    final handle = _nonEmpty(json['handle']);
    return NetworkGraphNode(
      id: json['id']?.toString() ?? '',
      kind: NetworkNodeKind.fromJson(json['kind']),
      parentId: _nonEmpty(json['parent_id']),
      userId: _nonEmpty(json['user_id']),
      // The app writes handles with a leading @ everywhere; the server stores
      // the bare username.
      handle: handle == null
          ? null
          : (handle.startsWith('@') ? handle : '@$handle'),
      avatarId: _nonEmpty(json['avatar_id']),
      answerKind: NetworkAnswerKind.fromJson(json['answer_kind']),
      approvalValue: _asDouble(json['approval_value']),
      optionIndex: _asIntOrNull(json['option_index']),
      answerLabel: _nonEmpty(json['answer_label']),
      answered: json['answered'] == true,
      fofOverflow: _asIntOrNull(json['fof_overflow']) ?? 0,
    );
  }
}

/// A complete ego-network graph: a flat node list, self first.
class NetworkGraphData {
  final List<NetworkGraphNode> nodes;
  const NetworkGraphData(this.nodes);

  /// The centre node. Synthesises an empty self rather than throwing when a
  /// payload somehow arrives without one — an ego graph with no ego is a
  /// server bug, not a reason to crash a results screen.
  NetworkGraphNode get self => nodes.firstWhere(
        (n) => n.kind == NetworkNodeKind.self,
        orElse: () =>
            const NetworkGraphNode(id: 'self', kind: NetworkNodeKind.self),
      );

  /// Inner-ring nodes: direct friends (regular + close), in list order.
  List<NetworkGraphNode> get directFriends => nodes
      .where((n) =>
          n.kind == NetworkNodeKind.friend ||
          n.kind == NetworkNodeKind.closeFriend)
      .toList(growable: false);

  List<NetworkGraphNode> get closeFriends => nodes
      .where((n) => n.kind == NetworkNodeKind.closeFriend)
      .toList(growable: false);

  List<NetworkGraphNode> get regularFriends => nodes
      .where((n) => n.kind == NetworkNodeKind.friend)
      .toList(growable: false);

  List<NetworkGraphNode> get friendsOfFriends => nodes
      .where((n) => n.kind == NetworkNodeKind.friendOfFriend)
      .toList(growable: false);

  /// Friends-of-friends grouped by the friend that bridges to them.
  Map<String, List<NetworkGraphNode>> get fofByParent {
    final byParent = <String, List<NetworkGraphNode>>{};
    for (final n in friendsOfFriends) {
      (byParent[n.parentId ?? 'self'] ??= <NetworkGraphNode>[]).add(n);
    }
    return byParent;
  }

  /// `graph: {"nodes": [...]}` as `get_network_results` sends it.
  factory NetworkGraphData.fromJson(Map<String, dynamic> json) {
    final raw = json['nodes'];
    if (raw is! List) return const NetworkGraphData(<NetworkGraphNode>[]);
    return NetworkGraphData(<NetworkGraphNode>[
      for (final n in raw)
        if (n is Map) NetworkGraphNode.fromJson(Map<String, dynamic>.from(n)),
    ]);
  }
}

/// How a single reciprocal close friend answered one question (design §5.5B).
///
/// One row of `get_close_friend_answers`. Picks and slider positions only —
/// there is no text variant, because text bodies are never shared (D-1).
class CloseFriendAnswer {
  final String handle;
  final String answerLabel;
  final NetworkAnswerKind kind;

  /// Approval score in [-1, 1] — set only when [kind] is approval.
  final double? approvalValue;

  /// Multiple-choice option index — set only when [kind] is multipleChoice.
  final int? optionIndex;

  /// The account behind the handle, when the row came from the server.
  final String? userId;
  final String? avatarId;

  const CloseFriendAnswer.approval({
    required this.handle,
    required this.answerLabel,
    required double value,
    this.userId,
    this.avatarId,
  })  : approvalValue = value,
        optionIndex = null,
        kind = NetworkAnswerKind.approval;

  const CloseFriendAnswer.mc({
    required this.handle,
    required this.answerLabel,
    required this.optionIndex,
    this.userId,
    this.avatarId,
  })  : approvalValue = null,
        kind = NetworkAnswerKind.multipleChoice;

  /// Null when the row carries no colourable answer — a text question, or an
  /// answer the server withheld. There is nothing to draw in either case.
  static CloseFriendAnswer? fromJson(Map<String, dynamic> json) {
    final kind = NetworkAnswerKind.fromJson(json['answer_kind']);
    if (kind == null) return null;
    final username = _nonEmpty(json['username']) ?? 'friend';
    final handle = username.startsWith('@') ? username : '@$username';
    final label = _nonEmpty(json['answer_label']);
    switch (kind) {
      case NetworkAnswerKind.approval:
        final value = _asDouble(json['approval_value']);
        if (value == null) return null;
        return CloseFriendAnswer.approval(
          handle: handle,
          answerLabel: label ?? approvalAnswerLabel(value),
          value: value,
          userId: _nonEmpty(json['user_id']),
          avatarId: _nonEmpty(json['avatar_id']),
        );
      case NetworkAnswerKind.multipleChoice:
        final index = _asIntOrNull(json['option_index']);
        if (index == null) return null;
        return CloseFriendAnswer.mc(
          handle: handle,
          answerLabel: label ?? 'Their pick',
          optionIndex: index,
          userId: _nonEmpty(json['user_id']),
          avatarId: _nonEmpty(json['avatar_id']),
        );
    }
  }
}

/// The five approval bands the results palette colours by, in the order the
/// server's `buckets` array uses (strongly disapprove first).
const List<String> kNetworkApprovalBandLabels = <String>[
  'Strongly disapprove',
  'Disapprove',
  'Neutral',
  'Approve',
  'Strongly approve',
];

/// Midpoints of those five bands. The server derives its published `average`
/// from these exact numbers, so the client uses them too rather than inventing
/// a different reading of the same buckets.
const List<double> kNetworkApprovalBandMidpoints = <double>[
  -0.90,
  -0.55,
  0.0,
  0.55,
  0.90,
];

/// Which of the five bands a value in [-1, 1] falls in, using the server's own
/// thresholds (score <= -80, -80..-30, -30..30, 30..80, >= 80).
int networkApprovalBand(double value) {
  if (value <= -0.80) return 0;
  if (value <= -0.30) return 1;
  if (value < 0.30) return 2;
  if (value < 0.80) return 3;
  return 4;
}

/// A words label for an approval value, for the rare row the server sends
/// without one.
String approvalAnswerLabel(double value) =>
    kNetworkApprovalBandLabels[networkApprovalBand(value)];

// --- parsing helpers -------------------------------------------------------

String? _nonEmpty(dynamic v) {
  if (v == null) return null;
  final s = v.toString();
  return s.isEmpty ? null : s;
}

double? _asDouble(dynamic v) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v);
  return null;
}

int? _asIntOrNull(dynamic v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v);
  return null;
}
