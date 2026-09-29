// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Fabricated, deterministic demo data for the Phase-2 "Networks" preview shown
// on the Community tab (design doc §5.5). NONE of this is real: there is no
// backend, no `response_owners` linkage, no friend graph — it exists purely to
// let users (and us) see how the ego-network results views will look before the
// real RPCs land in v1.3.0.
//
// The domain types the widgets consume (`NetworkGraphNode`, `NetworkGraphData`,
// `CloseFriendAnswer`, the answer kinds) MOVED to `models/network_graph.dart`
// when the real RPCs landed (2026-09-22) — they are no longer demo types, they
// are the server's shapes. They are re-exported here, and `DemoAnswerKind`
// stays as an alias, so the fabricated dataset below and its tests read as they
// always did.

import '../models/network_graph.dart';

export '../models/network_graph.dart';

/// Old name for [NetworkAnswerKind], kept so the demo dataset and its tests did
/// not have to be rewritten when the type stopped being a demo type.
typedef DemoAnswerKind = NetworkAnswerKind;

/// A complete fabricated demo question: the card content, the aggregated
/// network distribution (§5.5A) and the reciprocal close-friend answers
/// (§5.5B). Deterministic — no `Random()`.
class DemoNetworkQuestion {
  final String id;
  final String emoji;
  final String prompt;
  final String category;
  final DemoAnswerKind kind;

  /// Number of network members (friends + friends-of-friends) who answered.
  /// Drives the k = 3 gate in [NetworkAggregateCard].
  final int respondentCount;

  // --- Approval aggregate (one value per respondent, in [-1, 1]) ---
  final List<double> approvalValues;

  // --- Multiple-choice aggregate ---
  final List<String> mcOptionLabels;
  final List<int> mcOptionVotes;

  // --- Reciprocal close-friend individual answers ---
  final List<CloseFriendAnswer> closeFriends;

  // --- YOUR own answer (drives the "You" node colour in the ego graph) ---
  /// Your approval score in [-1, 1] — set only when [kind] is approval.
  final double? selfApprovalValue;

  /// Your multiple-choice option index — set only when [kind] is
  /// multipleChoice.
  final int? selfOptionIndex;

  /// Human label for your own answer (shown in the graph tooltip).
  final String selfAnswerLabel;

  const DemoNetworkQuestion({
    required this.id,
    required this.emoji,
    required this.prompt,
    required this.category,
    required this.kind,
    required this.respondentCount,
    this.approvalValues = const [],
    this.mcOptionLabels = const [],
    this.mcOptionVotes = const [],
    this.closeFriends = const [],
    this.selfApprovalValue,
    this.selfOptionIndex,
    this.selfAnswerLabel = 'You',
  });

  double get approvalAverage {
    if (approvalValues.isEmpty) return 0;
    final sum = approvalValues.fold<double>(0, (a, b) => a + b);
    return sum / approvalValues.length;
  }
}

/// The two headline demo questions the preview toggles between: one approval,
/// one multiple-choice, both above the k = 3 gate so the aggregate renders.
const List<DemoNetworkQuestion> kDemoNetworkQuestions = [
  DemoNetworkQuestion(
    id: 'demo-pizza',
    emoji: '🍍',
    prompt: 'Does pineapple belong on pizza?',
    category: 'Food fights',
    kind: DemoAnswerKind.approval,
    respondentCount: 12,
    // You land firmly in the "approve" camp on this one.
    selfApprovalValue: 0.6,
    selfAnswerLabel: 'You approve',
    // 12 network answers, leaning gently approve — a believable spread across
    // all five buckets so the beeswarm looks alive.
    approvalValues: [
      -0.95, -0.6, -0.4, -0.1, 0.05, 0.2, 0.45, 0.6, 0.7, 0.85, 0.9, 0.97,
    ],
    closeFriends: [
      CloseFriendAnswer.approval(
        handle: '@curio_thechameleon',
        answerLabel: 'Strongly approve',
        value: 0.95,
      ),
      CloseFriendAnswer.approval(
        handle: '@basil_basks',
        answerLabel: 'Approve',
        value: 0.5,
      ),
      CloseFriendAnswer.approval(
        handle: '@mango_morphs',
        answerLabel: 'Strongly disapprove',
        value: -0.9,
      ),
      CloseFriendAnswer.approval(
        handle: '@sunny_scales',
        answerLabel: 'Neutral',
        value: 0.05,
      ),
    ],
  ),
  DemoNetworkQuestion(
    id: 'demo-texting',
    emoji: '📱',
    prompt: 'Best time to send a risky text?',
    category: 'Modern dilemmas',
    kind: DemoAnswerKind.multipleChoice,
    respondentCount: 11,
    // You side with the golden-hour crowd.
    selfOptionIndex: 1,
    selfAnswerLabel: 'You: Golden hour (3pm)',
    mcOptionLabels: ['Never', 'Golden hour (3pm)', 'Midnight', 'Whenever, honestly'],
    mcOptionVotes: [2, 5, 3, 1],
    closeFriends: [
      CloseFriendAnswer.mc(
        handle: '@curio_thechameleon',
        answerLabel: 'Golden hour (3pm)',
        optionIndex: 1,
      ),
      CloseFriendAnswer.mc(
        handle: '@basil_basks',
        answerLabel: 'Midnight',
        optionIndex: 2,
      ),
      CloseFriendAnswer.mc(
        handle: '@pip_prism',
        answerLabel: 'Never',
        optionIndex: 0,
      ),
    ],
  ),
];

/// A third demo question used to show the k = 3 gated state (§5.5A): fewer than
/// three network members have answered, so the aggregate is withheld and the
/// "invite friends" copy shows instead.
const DemoNetworkQuestion kDemoGatedQuestion = DemoNetworkQuestion(
  id: 'demo-gated',
  emoji: '🦎',
  prompt: 'A chameleon\'s true colour is the one it is right now.',
  category: 'Deep thoughts',
  kind: DemoAnswerKind.approval,
  respondentCount: 2, // below k = 3 → gated
  approvalValues: [0.4, 0.8],
);

// ---------------------------------------------------------------------------
// Ego-network graph model (design doc §5.2 friend graph, §5.5 results, §9
// privacy). This is the data the `NetworkGraphPreview` widget visualizes. It
// is deliberately shaped for Phase-2 reuse: a flat node list keyed by degree
// ([NetworkNodeKind]), each node optionally carrying the handle + answer it is
// allowed to expose. The privacy semantics live in the *data*, not the widget:
//
//   • self / closeFriend nodes carry an answer (colourable).
//   • friend (regular) nodes carry a handle but NEVER an answer — their answers
//     are private (§5.5, only reciprocal close friends share individual
//     answers).
//   • friendOfFriend nodes carry an answer (colourable, revealed like close
//     friends) but NO handle — their identity stays anonymous — and connect only
//     to their bridging friend, never to each other (their FoF↔FoF topology is
//     never exposed, §9).
// ---------------------------------------------------------------------------

/// Regular (non-close) direct friends — fixed across both demo questions. They
/// render GREY in the graph: you know who they are, but their answers stay
/// private (only reciprocal close friends share individual answers, §5.5).
const List<String> _kDemoRegularFriendHandles = [
  '@flick_thegecko',
  '@nova_newt',
  '@cliff_theanole',
];

/// One fabricated friend-of-friend: a bridging friend plus a plausible,
/// deterministic answer for BOTH demo questions. FoF reveal their answer (like
/// close friends) but stay anonymous — no handle. The approval/MC fields let the
/// same node recolour when the Approval/Choice toggle flips, exactly as close
/// friends do.
class _DemoFof {
  final String id;

  /// Handle of the always-present bridging friend this FoF connects to.
  final String bridgeHandle;

  /// Approval answer (used when the selected question is approval).
  final double approvalValue;
  final String approvalLabel;

  /// Multiple-choice answer (used when the selected question is MC).
  final int optionIndex;
  final String mcLabel;

  const _DemoFof({
    required this.id,
    required this.bridgeHandle,
    required this.approvalValue,
    required this.approvalLabel,
    required this.optionIndex,
    required this.mcLabel,
  });
}

/// A modest, deterministic 2nd-degree spread. Bridges are always-present friends
/// (the three regulars plus the two close friends who answered both demo
/// questions), so all 9 FoF always render. Each FoF carries a fixed answer for
/// both questions — anonymous but coloured, spread across every bucket/option so
/// the outer ring looks alive.
const List<_DemoFof> _kDemoFofSpec = [
  _DemoFof(
    id: 'fof_1',
    bridgeHandle: '@flick_thegecko',
    approvalValue: 0.9,
    approvalLabel: 'Strongly approve',
    optionIndex: 1,
    mcLabel: 'Golden hour (3pm)',
  ),
  _DemoFof(
    id: 'fof_2',
    bridgeHandle: '@flick_thegecko',
    approvalValue: 0.5,
    approvalLabel: 'Approve',
    optionIndex: 2,
    mcLabel: 'Midnight',
  ),
  _DemoFof(
    id: 'fof_3',
    bridgeHandle: '@nova_newt',
    approvalValue: 0.1,
    approvalLabel: 'Neutral',
    optionIndex: 0,
    mcLabel: 'Never',
  ),
  _DemoFof(
    id: 'fof_4',
    bridgeHandle: '@nova_newt',
    approvalValue: -0.5,
    approvalLabel: 'Disapprove',
    optionIndex: 3,
    mcLabel: 'Whenever, honestly',
  ),
  _DemoFof(
    id: 'fof_5',
    bridgeHandle: '@cliff_theanole',
    approvalValue: -0.9,
    approvalLabel: 'Strongly disapprove',
    optionIndex: 1,
    mcLabel: 'Golden hour (3pm)',
  ),
  _DemoFof(
    id: 'fof_6',
    bridgeHandle: '@curio_thechameleon',
    approvalValue: 0.7,
    approvalLabel: 'Approve',
    optionIndex: 2,
    mcLabel: 'Midnight',
  ),
  _DemoFof(
    id: 'fof_7',
    bridgeHandle: '@curio_thechameleon',
    approvalValue: -0.2,
    approvalLabel: 'Neutral',
    optionIndex: 1,
    mcLabel: 'Golden hour (3pm)',
  ),
  _DemoFof(
    id: 'fof_8',
    bridgeHandle: '@basil_basks',
    approvalValue: 0.4,
    approvalLabel: 'Approve',
    optionIndex: 0,
    mcLabel: 'Never',
  ),
  _DemoFof(
    id: 'fof_9',
    bridgeHandle: '@basil_basks',
    approvalValue: -0.6,
    approvalLabel: 'Disapprove',
    optionIndex: 3,
    mcLabel: 'Whenever, honestly',
  ),
];

/// Builds the deterministic ego-network graph for a demo [question].
///
/// The topology (you → friends → friends-of-friends) is stable; only the
/// *colours* of the "You" node and the close-friend nodes change with the
/// selected question, mirroring how the real graph would recolour per question.
/// Close-friend nodes are derived from [DemoNetworkQuestion.closeFriends] so
/// they always match the `CloseFriendsAnswersRow` for the same question.
NetworkGraphData buildDemoNetworkGraph(DemoNetworkQuestion question) {
  final nodes = <NetworkGraphNode>[
    // Centre: you, coloured by your own answer.
    NetworkGraphNode(
      id: 'self',
      kind: NetworkNodeKind.self,
      handle: 'You',
      answerKind: question.kind,
      approvalValue: question.selfApprovalValue,
      optionIndex: question.selfOptionIndex,
      answerLabel: question.selfAnswerLabel,
    ),
    // Regular friends — grey, answers private.
    for (final h in _kDemoRegularFriendHandles)
      NetworkGraphNode(
        id: h,
        kind: NetworkNodeKind.friend,
        parentId: 'self',
        handle: h,
      ),
    // Reciprocal close friends who answered this question — coloured.
    for (final cf in question.closeFriends)
      NetworkGraphNode(
        id: cf.handle,
        kind: NetworkNodeKind.closeFriend,
        parentId: 'self',
        handle: cf.handle,
        answerKind: cf.kind,
        approvalValue: cf.approvalValue,
        optionIndex: cf.optionIndex,
        answerLabel: cf.answerLabel,
      ),
  ];

  // Friends-of-friends: anonymous (no handle), each bridged by exactly one
  // friend that exists in this graph, with no FoF↔FoF edges — but their answer
  // IS revealed, coloured like a close friend's, per the selected question.
  final isApproval = question.kind == DemoAnswerKind.approval;
  final existingIds = nodes.map((n) => n.id).toSet();
  for (final spec in _kDemoFofSpec) {
    if (existingIds.contains(spec.bridgeHandle)) {
      nodes.add(NetworkGraphNode(
        id: spec.id,
        kind: NetworkNodeKind.friendOfFriend,
        parentId: spec.bridgeHandle,
        // No handle — identity stays anonymous even though the answer shows.
        answerKind: question.kind,
        approvalValue: isApproval ? spec.approvalValue : null,
        optionIndex: isApproval ? null : spec.optionIndex,
        answerLabel: isApproval ? spec.approvalLabel : spec.mcLabel,
      ));
    }
  }

  return NetworkGraphData(nodes);
}
