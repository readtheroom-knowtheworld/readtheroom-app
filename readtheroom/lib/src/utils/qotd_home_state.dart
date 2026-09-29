// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Pure state machine for the QOTD-first "Today" home (Phase 2). The home
// screen resolves the Question of the Day asynchronously (with a bounded
// cold-start retry window) and then renders one of four states via
// [QotdHeroCard]. Keeping the mapping in a pure function makes the
// truth-table exhaustively testable without pumping any widgets.

/// The four mutually-exclusive states the QOTD hero can be in.
enum QotdHomeState {
  /// QOTD resolution is still in flight (initial load / cold-start window).
  loading,

  /// Resolution finished but no QOTD is available (retry window exhausted).
  unavailable,

  /// A QOTD exists and the user has not answered it yet.
  ask,

  /// The user has already answered today's QOTD.
  answered,
}

/// Pure mapping from resolution flags to the [QotdHomeState] to render.
///
///  - Until [qotdResolved] is true we are [QotdHomeState.loading], regardless
///    of the other flags.
///  - Once resolved, a missing QOTD ([qotdExists] false) is
///    [QotdHomeState.unavailable].
///  - A resolved, existing QOTD is [QotdHomeState.answered] when [hasAnswered],
///    otherwise [QotdHomeState.ask].
QotdHomeState qotdHomeState({
  required bool qotdResolved,
  required bool qotdExists,
  required bool hasAnswered,
}) {
  if (!qotdResolved) return QotdHomeState.loading;
  if (!qotdExists) return QotdHomeState.unavailable;
  if (hasAnswered) return QotdHomeState.answered;
  return QotdHomeState.ask;
}
