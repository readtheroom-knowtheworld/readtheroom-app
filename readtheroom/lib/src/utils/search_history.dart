// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';

/// Pure, device-local search-history logic, extracted from `SearchScreen` so it
/// can be unit-tested without pumping the screen (which requires Supabase and
/// the full provider tree).
///
/// The history is an LRU of the last [maxEntries] submitted-or-tapped queries,
/// newest first, de-duplicated case-insensitively. Persisted as a JSON string
/// list under the `search_history` SharedPreferences key and never included in
/// analytics payloads (privacy note P-6).
class SearchHistory {
  SearchHistory._();

  /// Maximum number of remembered queries.
  static const int maxEntries = 10;

  /// Queries shorter than this are never remembered (matches the search
  /// minimum query length).
  static const int minQueryLength = 3;

  /// Returns a new history list with [rawQuery] moved to the front.
  ///
  /// LRU semantics: any existing case-insensitive match is removed first, then
  /// the trimmed query is inserted at index 0 and the list capped at [max].
  /// Blank / too-short queries are ignored (the input list is returned as-is).
  static List<String> add(
    List<String> current,
    String rawQuery, {
    int max = maxEntries,
    int minLength = minQueryLength,
  }) {
    final query = rawQuery.trim();
    if (query.isEmpty || query.length < minLength) {
      return List<String>.from(current);
    }
    final updated = List<String>.from(current)
      ..removeWhere((q) => q.toLowerCase() == query.toLowerCase());
    updated.insert(0, query);
    return updated.take(max).toList();
  }

  /// Returns a new history list with every exact match of [query] removed.
  static List<String> remove(List<String> current, String query) =>
      List<String>.from(current)..removeWhere((q) => q == query);

  /// Parses the persisted JSON payload into a capped, non-blank list.
  /// Returns an empty list for null / empty / malformed input.
  static List<String> decode(String? raw, {int max = maxEntries}) {
    if (raw == null || raw.isEmpty) return <String>[];
    try {
      final decoded = json.decode(raw);
      if (decoded is List) {
        return decoded
            .map((e) => e.toString())
            .where((e) => e.trim().isNotEmpty)
            .take(max)
            .toList();
      }
    } catch (_) {
      // Malformed payload → treat as empty history.
    }
    return <String>[];
  }

  /// Encodes a history list for persistence.
  static String encode(List<String> current) => json.encode(current);
}

/// Which recent-searches surface the Archive's *empty-query* default view should
/// render at the top, above the always-present Unanswered queue / Your answers
/// sections.
enum SearchEmptyState {
  /// Device-local history hasn't been read yet — render nothing in the
  /// recent-searches slot so we don't flash a "Recent searches" header (or its
  /// absence) before the async read resolves.
  loadingHistory,

  /// History was read and is non-empty → show the compact "Recent searches"
  /// block above the archive queue.
  recentSearches,

  /// History was read and is empty → no recent-searches block; the Unanswered
  /// archive queue is the first section of the default view.
  archiveQueue,
}

/// Pure decision for the Archive default view's recent-searches slot, extracted
/// so the "history exists ⇒ Recent searches" rule can be unit-tested without
/// pumping `SearchScreen` (which needs Supabase + the provider tree).
///
/// Waiting on [historyLoaded] before choosing avoids a race where the async
/// SharedPreferences read finishes *after* the first frame and the recent
/// searches block flickers in/out even though history exists (design doc §4.5).
SearchEmptyState searchEmptyState({
  required bool historyLoaded,
  required bool hasHistory,
}) {
  if (!historyLoaded) return SearchEmptyState.loadingHistory;
  return hasHistory
      ? SearchEmptyState.recentSearches
      : SearchEmptyState.archiveQueue;
}

/// Result of splitting search results into the "Posted by me" and "All results"
/// sections rendered by `SearchScreen`.
class SearchResultGroups {
  final List<Map<String, dynamic>> mine;
  final List<Map<String, dynamic>> others;

  const SearchResultGroups(this.mine, this.others);

  /// Flat list backing swipe-navigation `FeedContext` — mine first, then all.
  List<Map<String, dynamic>> get ordered => [...mine, ...others];

  /// Whether the "Posted by me" section (and section headers) should show.
  bool get hasMine => mine.isNotEmpty;
}

/// Partitions [results] into questions authored by [currentUserId] ("Posted by
/// me", shown first) and everything else, preserving input order within each
/// section. A null [currentUserId] (guest / signed out) yields no "mine".
SearchResultGroups partitionByAuthor(
  List<Map<String, dynamic>> results,
  String? currentUserId,
) {
  final mine = <Map<String, dynamic>>[];
  final others = <Map<String, dynamic>>[];
  for (final question in results) {
    final authorId = question['author_id']?.toString();
    if (currentUserId != null && authorId == currentUserId) {
      mine.add(question);
    } else {
      others.add(question);
    }
  }
  return SearchResultGroups(mine, others);
}
