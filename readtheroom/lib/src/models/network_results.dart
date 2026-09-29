// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The typed shape of `get_network_results` and `get_network_answered_counts`.
//
// Two rules from the server contract that this file exists to make hard to
// break (design §2.9, "Rendering rules the client must honour"):
//
//   1. The server's numbers are the server's. [respondents] and [average] are
//      quantised on purpose — a single new answer must never move a published
//      number — so nothing here re-tallies them from the node list and nothing
//      re-derives the average from the buckets.
//   2. A gate is not an error. `success: true, gated: true` with a `reason` is
//      the normal reply for a small network, and it comes back with no graph at
//      all; the client draws a nudge card, not an empty graph.
//
// Server contract: scripts/response_linkage_04_read_rpcs.sql
// Docs:            feature-documentation/response-linkage-design-2026-09-22.md §2.3, §2.9

import 'network_graph.dart';

/// Why there is no network result to draw.
enum NetworkGateReason {
  /// Fewer than 5 accepted friends — the viewer has no circle yet.
  notEnoughFriends,

  /// A circle, but fewer than k respondents who are not named in the
  /// close-friend row (the disjoint-k rule).
  notEnoughAnswers,

  /// The RPC is not deployed on this project yet, or the call failed. Treated
  /// as "no network surface", never as an error the user has to see.
  unavailable,
}

NetworkGateReason? _reasonFromJson(dynamic value) {
  switch (value?.toString()) {
    case 'not_enough_friends':
      return NetworkGateReason.notEnoughFriends;
    case 'not_enough_answers':
      return NetworkGateReason.notEnoughAnswers;
    default:
      return null;
  }
}

/// One option of a multiple-choice question, with the network's floored vote
/// count. Options whose floored count is 0 are absent from the server's list.
class NetworkOptionTally {
  final String optionId;
  final String label;

  /// 0-based by `question_options.sort_order` — the colour key, not the
  /// position in this list (the list is ordered by votes).
  final int optionIndex;
  final int votes;

  const NetworkOptionTally({
    required this.optionId,
    required this.label,
    required this.optionIndex,
    required this.votes,
  });

  factory NetworkOptionTally.fromJson(Map<String, dynamic> json) =>
      NetworkOptionTally(
        optionId: json['option_id']?.toString() ?? '',
        label: json['label']?.toString() ?? '',
        optionIndex: _asInt(json['option_index']),
        votes: _asInt(json['votes']),
      );
}

/// The whole "Your network" payload for one question.
class NetworkResults {
  /// False when the surface could not be reached at all — the RPC is not
  /// deployed, or the call threw. [gated] is true and [reason] is
  /// [NetworkGateReason.unavailable] in that case.
  final bool available;

  final String questionId;
  final String questionType;

  /// The server's k. Mirrored client-side as `kNetworkMinFriendAnswers`.
  final int k;

  /// Accepted friends the server counted. 0 when unavailable.
  final int friendCount;

  final bool gated;
  final NetworkGateReason? reason;

  /// Network respondents, floored to a multiple of [k]. 0 when gated.
  final int respondents;

  /// The remainder quantisation withheld from [respondents].
  final int hidden;

  /// Multiple-choice tallies, ordered by votes descending. Null otherwise.
  final List<NetworkOptionTally>? options;

  /// Five approval counts, strongly-disapprove first, each floored to a
  /// multiple of [k]. Null unless the question is an approval rating.
  final List<int>? buckets;

  /// -1..1, derived by the SERVER from the published buckets. Never recomputed
  /// here.
  final double? average;

  /// How many of the network answered a text question. No bodies, ever (D-1).
  final int? textCount;

  /// Friend nodes dropped because the viewer has more than the render cap.
  final int friendOverflow;

  /// Null whenever [gated] is true.
  final NetworkGraphData? graph;

  /// The viewer's own close-friends share flag on their latest answer to this
  /// question; null when they have not answered (or the server predates the
  /// field). Returned even when gated, so the results-screen toggle has a
  /// server source of truth across devices.
  final bool? selfShared;

  const NetworkResults({
    required this.available,
    required this.questionId,
    required this.questionType,
    required this.k,
    required this.friendCount,
    required this.gated,
    required this.reason,
    required this.respondents,
    required this.hidden,
    required this.options,
    required this.buckets,
    required this.average,
    required this.textCount,
    required this.friendOverflow,
    required this.graph,
    this.selfShared,
  });

  /// The "there is no network surface here" answer: what every failure, every
  /// guest and every undeployed backend degrades to.
  factory NetworkResults.unavailable(String questionId,
          [String questionType = '']) =>
      NetworkResults(
        available: false,
        questionId: questionId,
        questionType: questionType,
        k: 3,
        friendCount: 0,
        gated: true,
        reason: NetworkGateReason.unavailable,
        respondents: 0,
        hidden: 0,
        options: null,
        buckets: null,
        average: null,
        textCount: null,
        friendOverflow: 0,
        graph: null,
      );

  /// True when there is a real card to draw.
  bool get hasGraph => !gated && graph != null;

  /// The respondent count for the card pre-check, or null when the server could
  /// not say — which `networkCardState` treats as zero.
  int? get networkAnswered => available ? respondents : null;

  /// Parses the RPC envelope. `{success: false, error: ...}` — including
  /// `rate_limited` and `not_authenticated` — degrades to [unavailable]: none
  /// of them is something to put in front of a reader.
  factory NetworkResults.fromJson(Map<String, dynamic> json,
      {String fallbackQuestionId = '', String fallbackQuestionType = ''}) {
    final questionId =
        json['question_id']?.toString() ?? fallbackQuestionId;
    if (json['success'] != true) {
      return NetworkResults.unavailable(questionId, fallbackQuestionType);
    }

    final gated = json['gated'] == true;
    final rawGraph = json['graph'];
    return NetworkResults(
      available: true,
      questionId: questionId,
      questionType:
          json['question_type']?.toString() ?? fallbackQuestionType,
      k: _asIntOr(json['k'], 3),
      friendCount: _asInt(json['friend_count']),
      gated: gated,
      reason: _reasonFromJson(json['reason']),
      respondents: _asInt(json['respondents']),
      hidden: _asInt(json['hidden']),
      options: json['options'] is List
          ? <NetworkOptionTally>[
              for (final o in json['options'] as List)
                if (o is Map)
                  NetworkOptionTally.fromJson(Map<String, dynamic>.from(o)),
            ]
          : null,
      buckets: json['buckets'] is List
          ? <int>[for (final b in json['buckets'] as List) _asInt(b)]
          : null,
      average: _asDouble(json['average']),
      textCount: _asIntOrNull(json['text_count']),
      friendOverflow: _asInt(json['friend_overflow']),
      selfShared: json['self_shared'] is bool ? json['self_shared'] as bool : null,
      // Gate ⇒ no graph, whatever else the payload says.
      graph: (!gated && rawGraph is Map)
          ? NetworkGraphData.fromJson(Map<String, dynamic>.from(rawGraph))
          : null,
    );
  }
}

/// One row of `get_network_answered_counts`: how many of the viewer's network
/// answered that question, floored to a multiple of k, 0 below the gate.
class NetworkAnsweredCount {
  final String questionId;
  final int respondents;
  final bool gated;

  const NetworkAnsweredCount({
    required this.questionId,
    required this.respondents,
    required this.gated,
  });

  factory NetworkAnsweredCount.fromJson(Map<String, dynamic> json) =>
      NetworkAnsweredCount(
        questionId: json['question_id']?.toString() ?? '',
        respondents: _asInt(json['respondents']),
        gated: json['gated'] == true,
      );
}

/// The batch gate reply.
class NetworkAnsweredCounts {
  /// False when the RPC could not be reached — every count is then unknown,
  /// which is not the same as zero.
  final bool available;

  /// True when the viewer is under the friend gate, so no question has a card.
  final bool gatedAll;

  final int friendCount;
  final Map<String, NetworkAnsweredCount> byQuestion;

  const NetworkAnsweredCounts({
    required this.available,
    required this.gatedAll,
    required this.friendCount,
    required this.byQuestion,
  });

  static const NetworkAnsweredCounts unavailable = NetworkAnsweredCounts(
    available: false,
    gatedAll: true,
    friendCount: 0,
    byQuestion: <String, NetworkAnsweredCount>{},
  );

  /// The respondent count for one question, or null when the server could not
  /// say. Null is deliberately distinct from 0 — the card logic treats them the
  /// same today, but a caller that wants to show a spinner needs the difference.
  int? respondentsFor(String questionId) {
    if (!available) return null;
    if (gatedAll) return 0;
    return byQuestion[questionId]?.respondents ?? 0;
  }

  factory NetworkAnsweredCounts.fromJson(Map<String, dynamic> json) {
    if (json['success'] != true) return NetworkAnsweredCounts.unavailable;
    final raw = json['counts'];
    final byQuestion = <String, NetworkAnsweredCount>{};
    if (raw is List) {
      for (final c in raw) {
        if (c is! Map) continue;
        final parsed =
            NetworkAnsweredCount.fromJson(Map<String, dynamic>.from(c));
        if (parsed.questionId.isNotEmpty) byQuestion[parsed.questionId] = parsed;
      }
    }
    return NetworkAnsweredCounts(
      available: true,
      gatedAll: json['gated_all'] == true,
      friendCount: _asInt(json['friend_count']),
      byQuestion: byQuestion,
    );
  }
}

// --- parsing helpers -------------------------------------------------------

int _asInt(dynamic v) => _asIntOrNull(v) ?? 0;

int _asIntOr(dynamic v, int fallback) => _asIntOrNull(v) ?? fallback;

int? _asIntOrNull(dynamic v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v);
  return null;
}

double? _asDouble(dynamic v) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v);
  return null;
}
