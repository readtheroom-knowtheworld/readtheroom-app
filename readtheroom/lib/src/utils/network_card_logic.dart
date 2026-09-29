// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Which "Your network" card a question gets (owner rule, 2026-09-20):
//
//   fewer than 5 friends                       -> the sample (demo) network
//   5+ friends, fewer than 3 of them answered  -> "not enough friends answered
//                                                  this one — send a lick?"
//   5+ friends and 3+ of them answered         -> the real network map
//
// The count comes from the server: `get_network_results` (one question) or
// `get_network_answered_counts` (a feed of them), both of which return a
// respondent total already floored to a multiple of k. The rule below is the
// CLIENT MIRROR of the server's, used to decide which card to draw before the
// payload arrives and when it cannot — it never overrides the server, which
// answers with `gated` and a `reason` of its own and is always right about
// what a card may show.
//
// A null count means the server could not say (no session, the RPCs are not
// deployed on this project yet, a failed call). Null counts as zero, so a
// viewer with 5+ friends gets the "not enough" card rather than the card
// silently disappearing.
//
// One number, two definitions, historically (design finding R11): this counts
// the NETWORK — friends AND friends-of-friends — exactly as the server does.

import '../models/network_results.dart';

/// Friends needed before the real network replaces the sample one. Mirrors
/// `kCircleFriendGoal` (network_demo_card.dart); kept here so the rule is
/// testable without pulling in widgets.
const int kNetworkMinFriends = 5;

/// Network members who must have answered THIS question before its map is
/// shown. The agreed k = 3 (networks-update-design §5.5 / §9 P-1): below it a
/// unanimous result would reveal how each of them answered. Mirrors the
/// server's `c_k` in get_network_results().
const int kNetworkMinFriendAnswers = 3;

enum NetworkCardState { demo, notEnoughAnswers, realMap }

/// [networkAnswered] is how many of the viewer's network — friends and
/// friends-of-friends — answered this question, as the server counted them;
/// null when it could not say.
NetworkCardState networkCardState({
  required int friendCount,
  required int? networkAnswered,
}) {
  if (friendCount < kNetworkMinFriends) return NetworkCardState.demo;
  if ((networkAnswered ?? 0) < kNetworkMinFriendAnswers) {
    return NetworkCardState.notEnoughAnswers;
  }
  return NetworkCardState.realMap;
}

/// Which card a [NetworkResults] earns.
///
/// The server decides, and it is allowed to disagree with the client mirror
/// above: an ungated payload is the real card whatever the local friend count
/// says, and `not_enough_answers` is the lick nudge even for someone whose
/// local FriendService has not loaded yet. [localFriendCount] is consulted only
/// where the server declined to answer at all — an undeployed RPC, a failed
/// call — because then the client mirror is all there is.
NetworkCardState networkCardStateFor(
  NetworkResults results, {
  int localFriendCount = 0,
}) {
  if (results.hasGraph) return NetworkCardState.realMap;
  if (results.reason == NetworkGateReason.notEnoughAnswers) {
    return NetworkCardState.notEnoughAnswers;
  }
  if (results.reason == NetworkGateReason.notEnoughFriends) {
    return NetworkCardState.demo;
  }
  return networkCardState(
    friendCount: results.friendCount > 0 ? results.friendCount : localFriendCount,
    networkAnswered: results.networkAnswered,
  );
}
