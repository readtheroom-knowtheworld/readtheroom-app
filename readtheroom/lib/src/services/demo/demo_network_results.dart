// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Demo-friends stand-in for the network RPCs (debug only).
//
// When `DemoFriendsMode` is on, `NetworkService` answers from here instead of
// calling `get_network_results` / `get_close_friend_answers` /
// `get_network_answered_counts`, so the real "Your network" card — the ego
// graph, the aggregate and the close-friends row — can be seen on any question
// on a simulator with nothing deployed. The payloads are built in the exact
// JSON shape the SQL returns (scripts/response_linkage_04_read_rpcs.sql) and
// fed through the real parsers, so the demo also exercises the contract.
//
// Deterministic per question id, so a question looks the same on every visit;
// different questions get different pictures. The cast is the demo friends
// from demo_friends_data.dart: Curio (mutual close, coloured), Sunny (close
// one-sided, grey), Basil and Mango (regular, grey), plus Pip and Juno as
// extra friends so the 5-friend gate passes.

import 'dart:convert';

import '../../models/network_graph.dart';
import '../../models/network_results.dart';
import 'demo_friends_data.dart';

const int _kDemoFriendCount = 6;

/// The question type each demo graph was built with, so the close-friends row
/// (whose RPC takes no type) colours the same way as the graph.
final Map<String, String> _demoTypes = <String, String>{};

/// A stable small integer from [seed] in [0, mod).
int _hash(String seed, int salt, int mod) {
  var h = 17 + salt * 31;
  for (final c in seed.codeUnits) {
    h = (h * 31 + c) & 0x7fffffff;
  }
  return h % mod;
}

Map<String, dynamic> _answerJson(String type, String seed, int salt) {
  if (type == 'approval_rating') {
    // Spread across the range, biased so a question reads as an opinion.
    final v = (_hash(seed, salt, 21) - 10) / 10.0; // -1.0 .. 1.0
    return {
      'answer_kind': 'approval',
      'approval_value': v,
      'option_id': null,
      'option_index': null,
      'answer_label': null,
    };
  }
  if (type == 'multiple_choice') {
    final idx = _hash(seed, salt, 3);
    return {
      'answer_kind': 'multiple_choice',
      'approval_value': null,
      'option_id': 'demo-option-$idx',
      'option_index': idx,
      'answer_label': kDemoOptionLabels[idx],
    };
  }
  return {
    'answer_kind': null,
    'approval_value': null,
    'option_id': null,
    'option_index': null,
    'answer_label': null,
  };
}

Map<String, dynamic> _noAnswerJson() => {
      'answer_kind': null,
      'approval_value': null,
      'option_id': null,
      'option_index': null,
      'answer_label': null,
    };

/// Labels for the three demo options of a multiple-choice question. The
/// section has no option texts of its own (the RPC carries them).
const List<String> kDemoOptionLabels = ['Yes', 'No', 'Depends'];

/// Which of the six demo friends answered [questionId]. Curio (the mutual
/// close friend) always does, so every demo graph has a coloured close friend.
List<String> demoFriendsWhoAnswered(String questionId) {
  const all = [
    kDemoCloseMutualId,
    kDemoCloseOneSidedId,
    kDemoRegularAId,
    kDemoRegularBId,
    kDemoIncomingId,
    kDemoOutgoingId,
  ];
  return [
    for (var i = 0; i < all.length; i++)
      if (i == 0 || _hash(questionId, i + 40, 4) != 0) all[i],
  ];
}

/// The `get_network_results` envelope for [questionId], ungated.
Map<String, dynamic> buildDemoNetworkResultsJson(
    String questionId, String questionType) {
  final type = questionType.isEmpty
      ? (_demoTypes[questionId] ?? 'multiple_choice')
      : questionType;
  _demoTypes[questionId] = type;
  final answered = demoFriendsWhoAnswered(questionId).toSet();
  final avatars = <String, String>{
    kDemoCloseMutualId: 'chameleon_01',
    kDemoCloseOneSidedId: 'chameleon_05',
    kDemoRegularAId: 'chameleon_02',
    kDemoRegularBId: 'chameleon_04',
    kDemoIncomingId: 'chameleon_06',
    kDemoOutgoingId: 'chameleon_07',
  };

  final nodes = <Map<String, dynamic>>[];
  final selfAnswered = _hash(questionId, 1, 3) != 0;
  nodes.add({
    'id': 'self',
    'kind': 'self',
    'parent_id': null,
    'user_id': null,
    'handle': null,
    'avatar_id': null,
    'answered': selfAnswered,
    'fof_overflow': 0,
    ...(selfAnswered ? _answerJson(type, questionId, 1) : _noAnswerJson()),
  });

  var totalRespondents = selfAnswered ? 1 : 0;
  final tallies = <int, int>{0: 0, 1: 0, 2: 0};
  final buckets = <int>[0, 0, 0, 0, 0];
  void count(Map<String, dynamic> a) {
    totalRespondents++;
    if (type == 'multiple_choice') {
      tallies[a['option_index'] as int] = tallies[a['option_index'] as int]! + 1;
    } else if (type == 'approval_rating') {
      final v = a['approval_value'] as double;
      final b = v < -0.6
          ? 0
          : v < -0.2
              ? 1
              : v <= 0.2
                  ? 2
                  : v <= 0.6
                      ? 3
                      : 4;
      buckets[b]++;
    }
  }

  if (selfAnswered) count(nodes.first);

  var friendIx = 0;
  for (final entry in avatars.entries) {
    final uid = entry.key;
    final isMutualClose = uid == kDemoCloseMutualId;
    final didAnswer = answered.contains(uid);
    // Every friend bridges to 0–3 friends-of-friends who answered; the real
    // cap is 3 per friend with the rest reported as overflow.
    final fofTotal = _hash(questionId, 100 + friendIx, 5); // 0..4
    final fofShown = fofTotal > 3 ? 3 : fofTotal;
    final answer = didAnswer ? _answerJson(type, '$questionId/$uid', 7) : null;
    if (didAnswer) count(answer!);
    nodes.add({
      'id': 'f_$uid',
      'kind': isMutualClose ? 'close_friend' : 'friend',
      'parent_id': 'self',
      'user_id': uid,
      'handle': kDemoFriendHandles[uid],
      'avatar_id': entry.value,
      'answered': didAnswer,
      'fof_overflow': fofTotal - fofShown,
      // Only a mutual close friend who shared shows an answer; everyone else
      // is grey, exactly as the RPC does it.
      ...(isMutualClose && didAnswer ? answer! : _noAnswerJson()),
    });
    for (var j = 0; j < fofShown; j++) {
      final seed = '$questionId/$uid/fof$j';
      final a = _answerJson(type, seed, 11);
      count(a);
      nodes.add({
        'id': 'fof_${_hash(seed, 3, 1 << 30).toRadixString(16)}',
        'kind': 'friend_of_friend',
        'parent_id': 'f_$uid',
        'user_id': null,
        'handle': null,
        'avatar_id': null,
        'answered': true,
        'fof_overflow': 0,
        ...a,
      });
    }
    friendIx++;
  }

  const k = 3;
  int floor(int n) => n - (n % k);
  final respondents = floor(totalRespondents);

  List<Map<String, dynamic>>? options;
  List<int>? flooredBuckets;
  double? average;
  int? textCount;
  var shownSum = 0;
  if (type == 'multiple_choice') {
    options = [
      for (var i = 0; i < 3; i++)
        {
          'option_id': 'demo-option-$i',
          'label': kDemoOptionLabels[i],
          'option_index': i,
          'votes': floor(tallies[i]!),
        }
    ]..sort((a, b) => (b['votes'] as int).compareTo(a['votes'] as int));
    shownSum = options.fold(0, (s, o) => s + (o['votes'] as int));
  } else if (type == 'approval_rating') {
    flooredBuckets = [for (final b in buckets) floor(b)];
    shownSum = flooredBuckets.fold(0, (s, b) => s + b);
    average = shownSum == 0
        ? 0
        : ((flooredBuckets[0] * -0.9 +
                    flooredBuckets[1] * -0.55 +
                    flooredBuckets[4] * 0.9 +
                    flooredBuckets[3] * 0.55) /
                shownSum * 100)
            .round() /
            100;
  } else {
    textCount = respondents;
    shownSum = respondents;
  }

  return {
    'success': true,
    'v': 1,
    'question_id': questionId,
    'question_type': type,
    'k': k,
    'friend_count': _kDemoFriendCount,
    'self_shared': selfAnswered ? true : null,
    'gated': false,
    'reason': null,
    'respondents': respondents,
    // Contract (N2): the floored count minus the floored buckets, never the
    // exact remainder; text questions report 0.
    'hidden': type == 'text' ? 0 : respondents - shownSum,
    'options': options,
    'buckets': flooredBuckets,
    'average': average,
    'text_count': textCount,
    'friend_overflow': 0,
    'graph': {'nodes': nodes},
  };
}

NetworkResults buildDemoNetworkResults(String questionId, String questionType) =>
    NetworkResults.fromJson(
      // Round-trip through JSON so the demo can only produce what the wire can.
      jsonDecode(jsonEncode(buildDemoNetworkResultsJson(questionId, questionType)))
          as Map<String, dynamic>,
      fallbackQuestionId: questionId,
      fallbackQuestionType: questionType,
    );

/// The `get_close_friend_answers` rows: the one mutual close friend, when
/// they answered (the one-sided close friend never appears — no reciprocity).
List<CloseFriendAnswer> buildDemoCloseFriendAnswers(
    String questionId, String questionType) {
  final type = questionType.isEmpty
      ? (_demoTypes[questionId] ?? 'multiple_choice')
      : questionType;
  if (!demoFriendsWhoAnswered(questionId).contains(kDemoCloseMutualId)) {
    return const <CloseFriendAnswer>[];
  }
  final json = <String, dynamic>{
    'user_id': kDemoCloseMutualId,
    'username': kDemoFriendHandles[kDemoCloseMutualId],
    'avatar_id': 'chameleon_01',
    'answered': true,
    ..._answerJson(type, '$questionId/$kDemoCloseMutualId', 7),
  };
  final parsed = CloseFriendAnswer.fromJson(
      jsonDecode(jsonEncode(json)) as Map<String, dynamic>);
  return parsed == null ? const <CloseFriendAnswer>[] : [parsed];
}

/// The `get_network_answered_counts` envelope for [questionIds].
NetworkAnsweredCounts buildDemoNetworkAnsweredCounts(List<String> questionIds) {
  return NetworkAnsweredCounts.fromJson({
    'success': true,
    'v': 1,
    'gated_all': false,
    'friend_count': _kDemoFriendCount,
    'counts': [
      for (final q in questionIds)
        {
          'question_id': q,
          'respondents': buildDemoNetworkResultsJson(q, '')['respondents'],
          'gated': false,
        }
    ],
  });
}
