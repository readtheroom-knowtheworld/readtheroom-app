// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Pure logic for question reactions (WP-D, list item 8 / decision D8).
//
// Reactions are now free-form: the picker offers the whole emoji keyboard and
// `question_reactions.reaction_type` simply stores the chosen grapheme. Two
// jobs live here, both free of Flutter/Supabase so they can be unit tested:
//
//   * [topReactions] — which reactions the compact control (the home hero's
//     answered card) shows, and in which order.
//   * [isSingleEmoji] — the client-side guard that keeps junk out of the
//     column now that the fixed 5-emoji allow-list is gone.

import 'package:characters/characters.dart';

/// One reaction and its count, as rendered by the reactions controls.
class ReactionTally {
  final String emoji;
  final int count;

  const ReactionTally(this.emoji, this.count);

  @override
  bool operator ==(Object other) =>
      other is ReactionTally && other.emoji == emoji && other.count == count;

  @override
  int get hashCode => Object.hash(emoji, count);

  @override
  String toString() => 'ReactionTally($emoji × $count)';
}

/// The reactions the compact control should show, highest count first.
///
/// - Zero/negative counts are dropped (they are an artefact of the optimistic
///   update in [QuestionReactionsWidget], not real rows).
/// - Ties break on the emoji itself, so the row never reshuffles between
///   rebuilds of the same data.
/// - [alwaysInclude] (the current user's own reaction) is kept even when it
///   falls outside the top [limit], because a control that hides your own
///   reaction reads as if the tap didn't register. It keeps its rank position
///   among the shown entries; the lowest-ranked other entry makes room.
List<ReactionTally> topReactions(
  Map<String, int> counts, {
  int limit = 3,
  Set<String> alwaysInclude = const {},
}) {
  if (limit <= 0) return const [];

  final ranked = counts.entries
      .where((e) => e.value > 0)
      .map((e) => ReactionTally(e.key, e.value))
      .toList()
    ..sort((a, b) {
      final byCount = b.count.compareTo(a.count);
      return byCount != 0 ? byCount : a.emoji.compareTo(b.emoji);
    });

  if (ranked.length <= limit) return ranked;

  final top = ranked.take(limit).toList();
  final pinned = ranked
      .skip(limit)
      .where((t) => alwaysInclude.contains(t.emoji))
      .toList();
  if (pinned.isEmpty) return top;

  // Make room for the pinned entries by dropping the weakest unpinned ones,
  // then restore rank order.
  final kept = <ReactionTally>[
    ...top.where((t) => alwaysInclude.contains(t.emoji)),
    ...pinned,
  ];
  // Strongest first, so the entries that make room are the weakest ones.
  for (final t in top) {
    if (kept.length >= limit) break;
    if (!kept.contains(t)) kept.add(t);
  }
  final result = kept.take(limit).toList()
    ..sort((a, b) {
      final byCount = b.count.compareTo(a.count);
      return byCount != 0 ? byCount : a.emoji.compareTo(b.emoji);
    });
  return result;
}

/// Total across every reaction on a question (ignoring the optimistic zeros).
int totalReactionCount(Map<String, int> counts) =>
    counts.values.where((c) => c > 0).fold<int>(0, (sum, c) => sum + c);

/// Whether [value] is exactly one emoji grapheme cluster — the client-side
/// guard that replaced the fixed 5-emoji allow-list.
///
/// Uses the `characters` package (bundled with Flutter) so a multi-code-point
/// emoji — a skin-tone modifier, a ZWJ family, a flag, a keycap — counts as the
/// single character a user sees, while a letter, a digit, whitespace, an empty
/// string or two emoji in a row are rejected.
bool isSingleEmoji(String? value) {
  if (value == null) return false;
  final chars = value.characters;
  if (chars.length != 1) return false;

  final grapheme = chars.first;
  // A single-code-unit grapheme is only an emoji in a few ranges; anything in
  // the ASCII/Latin-1 block (letters, digits, punctuation, whitespace) is not.
  final runes = grapheme.runes.toList();
  if (runes.length == 1) {
    final cp = runes.first;
    if (cp <= 0xFF) return false;
    // Symbol/pictograph/dingbat/misc ranges that are emoji on their own.
    const pictographRanges = <List<int>>[
      [0x203C, 0x3299], // misc symbols, dingbats, enclosed characters
      [0x1F000, 0x1FAFF], // emoji blocks
      [0x1FC00, 0x1FFFD], // future emoji blocks
    ];
    return pictographRanges.any((r) => cp >= r[0] && cp <= r[1]);
  }

  // Multi-code-point grapheme: accept when any code point is an emoji base,
  // variation selector, ZWJ, keycap, regional indicator or skin-tone modifier.
  return runes.any((cp) =>
      (cp >= 0x1F000 && cp <= 0x1FAFF) || // emoji blocks
      (cp >= 0x1F1E6 && cp <= 0x1F1FF) || // regional indicators (flags)
      (cp >= 0x1F3FB && cp <= 0x1F3FF) || // skin-tone modifiers
      (cp >= 0x2600 && cp <= 0x27BF) || // misc symbols + dingbats
      cp == 0xFE0F || // variation selector-16 (emoji presentation)
      cp == 0x200D || // zero-width joiner
      cp == 0x20E3); // combining enclosing keycap
}
