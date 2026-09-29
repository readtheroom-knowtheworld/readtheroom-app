// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// "My Network" as a slice of a results page.
//
// The results screens already speak one language for a filter: a token that is
// null for everyone, `Gen:<id>` for a generation, `City:<name>` for a city and
// a bare country name otherwise. This file adds one more token —
// [kNetworkFilter] — and the adapter that turns the server's network envelope
// into the same [ResultsBreakdown] every chart on those screens already reads.
//
// Three rules the adapter exists to keep (networks design §5.5A, response
// linkage design §2.9):
//
//   1. The server's numbers are the server's. [NetworkResults.respondents] and
//      [NetworkResults.average] are quantised on purpose; nothing here
//      re-tallies a count from the graph or re-derives an average from buckets.
//   2. A gate is not an error and not an empty slice. A gated or unavailable
//      network has NO breakdown at all (null), so the caller can leave the row
//      out of the dialog and fall back to World rather than draw a zeroed
//      chart.
//   3. Never per-person. A network slice carries counts only — there is no
//      `scores` list, because a beeswarm of a handful of friends is a picture
//      of individual answers.
//
// Docs: feature-documentation/my-network-filter-2026-09-22.md
//       feature-documentation/networks-update-design-2026-07-17.md §5.5A

import 'dart:math' as math;

import '../models/network_results.dart';
import '../models/question_results.dart';

/// The filter token for the viewer's own network, alongside `Gen:` and `City:`.
const String kNetworkFilter = 'Network';

/// What the token is called in front of a reader. Never "friends-of-friends"
/// in a heading — that is the subtitle's job.
const String kNetworkFilterLabel = 'My Network';

/// The one line under the row, word for word the aggregate card's line.
const String kNetworkFilterSubtitle =
    'Friends and friends-of-friends, mixed together.';

/// True when [filter] names the network slice.
bool isNetworkFilter(String? filter) => filter == kNetworkFilter;

/// `9+` when the server withheld a remainder, `9` when it did not — the same
/// rendering as `NetworkAggregateCard`.
String networkCountLabel(int count, int hidden) =>
    hidden > 0 ? '$count+' : '$count';

/// The network envelope as a results slice, or null when there is nothing to
/// show: no result yet, the RPC is unavailable, or the viewer is under the gate.
///
/// [optionTexts] are the question's own options, in the question's order; the
/// returned [ResultsBreakdown.optionCounts] carries all of them, zeros included,
/// so a chart keeps its ordering and still draws options the network skipped.
ResultsBreakdown? networkBreakdownFrom(
  NetworkResults? results, {
  List<String> optionTexts = const <String>[],
}) {
  if (results == null || !results.available || results.gated) return null;

  final counts = <String, int>{for (final o in optionTexts) o: 0};
  final tallies = results.options;
  if (tallies != null) {
    for (final tally in tallies) {
      final key = _optionKey(tally, optionTexts);
      counts[key] = (counts[key] ?? 0) + tally.votes;
    }
  }

  final bins = List<int>.filled(5, 0);
  final buckets = results.buckets;
  if (buckets != null) {
    for (var i = 0; i < math.min(5, buckets.length); i++) {
      bins[i] = buckets[i];
    }
  }

  return ResultsBreakdown(
    count: results.respondents,
    average: results.average,
    bins: bins,
    optionCounts: counts,
    // Deliberately empty: the server sends no per-answer scores for a network,
    // and a beeswarm of three friends would be a list of people.
    scores: const <int>[],
  );
}

/// Match a server tally to one of the question's option texts.
///
/// The label is the server's own copy of the option text, so it usually matches
/// outright; `option_index` (0-based by `sort_order`) is the fallback for a
/// question whose text was edited after the answers came in.
String _optionKey(NetworkOptionTally tally, List<String> optionTexts) {
  if (optionTexts.contains(tally.label)) return tally.label;
  if (tally.optionIndex >= 0 && tally.optionIndex < optionTexts.length) {
    return optionTexts[tally.optionIndex];
  }
  return tally.label;
}

/// Resolve one filter token against the question results and the network slice.
///
/// [network] is null whenever the network has nothing to say, and a `Network`
/// token then falls back to World silently — the caller clears its selection
/// with [clearedNetworkFilter] so the button does not keep claiming a filter
/// that is not being applied.
ResultsBreakdown resolveResultsFilter({
  required QuestionResults results,
  required String? filter,
  ResultsBreakdown? network,
  bool isPrivate = false,
}) {
  if (isPrivate || filter == null || filter.isEmpty || filter == 'World') {
    return results.overall;
  }
  if (isNetworkFilter(filter)) return network ?? results.overall;
  return results.breakdownForFilter(filter);
}

/// [filter] with a `Network` token dropped when the network cannot be shown.
String? clearedNetworkFilter(String? filter, ResultsBreakdown? network) =>
    isNetworkFilter(filter) && network == null ? null : filter;
