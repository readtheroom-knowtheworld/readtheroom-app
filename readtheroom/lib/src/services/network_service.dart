// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The only way this app reads the "Your network" surface.
//
// Four SECURITY DEFINER RPCs sit behind it. Between them they are the entire
// answer↔user surface the client is allowed to see; `response_owners` itself
// has RLS on with no policies and no grants, so there is no other path and
// there is not meant to be one.
//
//   get_network_results(question)           the ego graph + the quantised aggregate
//   get_network_answered_counts(question[]) the batch gate, for lists of cards
//   get_close_friend_answers(question)      the named close-friend row
//   set_answer_sharing(question, shared)    un-share (or re-share) a past answer
//
// POSTURE: degrade to nothing, never to an error. Every failure — an
// undeployed RPC, a rate limit, a guest session, a dropped connection —
// becomes an "unavailable" result, and the caller draws the same nudge card it
// draws for a viewer with no circle. The network surface is a bonus on top of
// a results screen; it must never be the reason one fails to render.
//
// ON A BACKEND WITHOUT THESE RPCs, PostgREST answers every call here with
// `PGRST202` (no such function), which [_isMissingFunction] catches;
// the first one flips [_rpcsMissing] and the rest stop going out at all until
// the app restarts.
//
// Server contract: scripts/response_linkage_04_read_rpcs.sql
// Docs:            feature-documentation/response-linkage-design-2026-09-22.md §2.3, §2.9
//                  feature-documentation/networks-client-2026-09-22.md

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/network_graph.dart';
import '../models/network_results.dart';
import '../utils/demo_friends_mode.dart';
import 'analytics_service.dart';
import 'demo/demo_network_results.dart';

/// True when PostgREST is telling us the function does not exist — the state
/// every build is in until the linkage SQL is applied.
///
/// `PGRST202` is the documented code; the message check is a belt-and-braces
/// for older PostgREST versions that only said it in words.
bool isMissingRpc(Object error) {
  if (error is PostgrestException) {
    if (error.code == 'PGRST202' || error.code == '42883') return true;
    final m = error.message.toLowerCase();
    // "does not exist" alone is too broad — a missing COLUMN says it too, and
    // that is a real error, not a reason to fall back.
    return m.contains('could not find the function') ||
        (m.contains('function') && m.contains('does not exist'));
  }
  return false;
}

class NetworkService {
  NetworkService({SupabaseClient? client}) : _client = client;

  static final NetworkService _instance = NetworkService();

  /// The app-wide instance. Injectable through the constructor for tests.
  factory NetworkService.shared() => _instance;

  final SupabaseClient? _client;

  SupabaseClient? get _supabase {
    try {
      return _client ?? Supabase.instance.client;
    } catch (_) {
      return null;
    }
  }

  bool get _isAuthenticated => _supabase?.auth.currentUser != null;

  /// Sticky once set: the linkage SQL is applied by hand, so it either exists
  /// for the whole session or it does not. Saves a round trip per card.
  bool _rpcsMissing = false;

  /// Test seam — lets a test start from a clean slate, and lets the app clear
  /// the flag after a sign-in on a project that was mid-deploy.
  void resetDeploymentState() => _rpcsMissing = false;

  @visibleForTesting
  bool get rpcsMissing => _rpcsMissing;

  /// A short cache, for the same reason `ResultsService` has one: the graph,
  /// the aggregate and the sharing toggle all sit on one screen and all want
  /// the same payload in the same frame.
  final Map<String, _Cached<NetworkResults>> _resultsCache = {};
  static const Duration _cacheDuration = Duration(seconds: 45);

  void clearCache([String? questionId]) {
    if (questionId == null) {
      _resultsCache.clear();
      return;
    }
    _resultsCache.remove(questionId);
  }

  // -------------------------------------------------------------------------
  // Reads
  // -------------------------------------------------------------------------

  /// The ego graph and the quantised aggregate for one question.
  ///
  /// Never throws and never returns null: a gate, a guest, a missing RPC and a
  /// network failure all arrive as a [NetworkResults] the caller can render.
  Future<NetworkResults> getNetworkResults(
    String questionId, {
    String questionType = '',
    bool forceRefresh = false,
  }) async {
    if (questionId.isEmpty) {
      return NetworkResults.unavailable(questionId, questionType);
    }
    if (!forceRefresh) {
      final cached = _resultsCache[questionId];
      if (cached != null && cached.isFresh(_cacheDuration)) return cached.value;
    }
    // Debug "Demo friends": a fabricated but contract-exact network, so the
    // real card can be seen with nothing deployed (demo_network_results.dart).
    if (DemoFriendsMode.instance.enabled) {
      return buildDemoNetworkResults(questionId, questionType);
    }
    final client = _supabase;
    if (client == null || !_isAuthenticated || _rpcsMissing) {
      return NetworkResults.unavailable(questionId, questionType);
    }
    try {
      final raw = await client
          .rpc('get_network_results', params: {'p_question_id': questionId});
      if (raw is! Map) {
        return NetworkResults.unavailable(questionId, questionType);
      }
      final parsed = NetworkResults.fromJson(
        Map<String, dynamic>.from(raw),
        fallbackQuestionId: questionId,
        fallbackQuestionType: questionType,
      );
      _resultsCache[questionId] = _Cached(parsed);
      return parsed;
    } catch (e) {
      if (isMissingRpc(e)) {
        _rpcsMissing = true;
        debugPrint(
            'NetworkService: get_network_results is not deployed — the network '
            'surface stays hidden until the RPC is deployed.');
        // Review 2026-09-22 B6: with the migration applied by hand, "are the
        // linkage RPCs actually deployed for real users?" is otherwise
        // unanswerable from outside. Once per session per action.
        AnalyticsService().trackRpcNotDeployedOnce('get_network_results');
      } else {
        debugPrint('NetworkService.getNetworkResults($questionId) failed: $e');
        AnalyticsService().trackRpcFailed('get_network_results',
            reason: analyticsRpcReason(e));
      }
      return NetworkResults.unavailable(questionId, questionType);
    }
  }

  /// The batch gate for a list of questions. Capped at 50 ids per call by the
  /// server; chunked here so callers can hand over a whole feed.
  Future<NetworkAnsweredCounts> getNetworkAnsweredCounts(
      List<String> questionIds) async {
    final ids = questionIds.where((id) => id.isNotEmpty).toSet().toList();
    if (ids.isEmpty) {
      return const NetworkAnsweredCounts(
        available: true,
        gatedAll: false,
        friendCount: 0,
        byQuestion: <String, NetworkAnsweredCount>{},
      );
    }
    if (DemoFriendsMode.instance.enabled) {
      return buildDemoNetworkAnsweredCounts(ids);
    }
    final client = _supabase;
    if (client == null || !_isAuthenticated || _rpcsMissing) {
      return NetworkAnsweredCounts.unavailable;
    }

    const chunkSize = 50;
    final merged = <String, NetworkAnsweredCount>{};
    var friendCount = 0;
    var sawAny = false;
    for (var start = 0; start < ids.length; start += chunkSize) {
      final end = start + chunkSize > ids.length ? ids.length : start + chunkSize;
      final chunk = ids.sublist(start, end);
      try {
        final raw = await client.rpc('get_network_answered_counts',
            params: {'p_question_ids': chunk});
        if (raw is! Map) continue;
        final parsed =
            NetworkAnsweredCounts.fromJson(Map<String, dynamic>.from(raw));
        if (!parsed.available) continue;
        // Under the friend gate nothing has a card — say so and stop asking.
        if (parsed.gatedAll) return parsed;
        sawAny = true;
        friendCount = parsed.friendCount;
        merged.addAll(parsed.byQuestion);
      } catch (e) {
        if (isMissingRpc(e)) {
          _rpcsMissing = true;
          AnalyticsService()
              .trackRpcNotDeployedOnce('get_network_answered_counts');
          return NetworkAnsweredCounts.unavailable;
        }
        debugPrint('NetworkService.getNetworkAnsweredCounts chunk failed: $e');
        AnalyticsService().trackRpcFailed('get_network_answered_counts',
            reason: analyticsRpcReason(e));
      }
    }
    if (!sawAny) return NetworkAnsweredCounts.unavailable;
    return NetworkAnsweredCounts(
      available: true,
      gatedAll: false,
      friendCount: friendCount,
      byQuestion: merged,
    );
  }

  /// How many of the viewer's network answered one question, or null when the
  /// server could not say. Null is what `networkCardState` treats as zero.
  Future<int?> getNetworkAnsweredCount(String questionId) async {
    final counts = await getNetworkAnsweredCounts(<String>[questionId]);
    return counts.respondentsFor(questionId);
  }

  /// How each reciprocal close friend answered, when their own share flag
  /// allows it. Never cached to disk (privacy rule P-2), and empty for a text
  /// question — close friends see picks and slider positions only.
  Future<List<CloseFriendAnswer>> getCloseFriendAnswers(
      String questionId) async {
    if (questionId.isEmpty) return const <CloseFriendAnswer>[];
    if (DemoFriendsMode.instance.enabled) {
      return buildDemoCloseFriendAnswers(questionId, '');
    }
    final client = _supabase;
    if (client == null || !_isAuthenticated || _rpcsMissing) {
      return const <CloseFriendAnswer>[];
    }
    try {
      final raw = await client.rpc('get_close_friend_answers',
          params: {'p_question_id': questionId});
      if (raw is! Map || raw['success'] != true) {
        return const <CloseFriendAnswer>[];
      }
      final answers = raw['answers'];
      if (answers is! List) return const <CloseFriendAnswer>[];
      final out = <CloseFriendAnswer>[];
      for (final a in answers) {
        if (a is! Map) continue;
        final parsed =
            CloseFriendAnswer.fromJson(Map<String, dynamic>.from(a));
        if (parsed != null) out.add(parsed);
      }
      return out;
    } catch (e) {
      if (isMissingRpc(e)) {
        _rpcsMissing = true;
        AnalyticsService().trackRpcNotDeployedOnce('get_close_friend_answers');
      } else {
        debugPrint(
            'NetworkService.getCloseFriendAnswers($questionId) failed: $e');
        AnalyticsService().trackRpcFailed('get_close_friend_answers',
            reason: analyticsRpcReason(e));
      }
      return const <CloseFriendAnswer>[];
    }
  }

  // -------------------------------------------------------------------------
  // Un-share (owner decision D-5)
  // -------------------------------------------------------------------------

  /// Flips the sharing flag on the caller's own answer to [questionId].
  ///
  /// Retroactive: every reader filters at read time, so turning it off removes
  /// the answer from the close-friend row and greys the graph node immediately.
  /// Returns false when nothing changed — no linked answer (an answer filed by
  /// a pre-RPC build), no session, or the RPC is not deployed.
  Future<bool> setAnswerSharing(String questionId, bool shared) async {
    if (questionId.isEmpty) return false;
    // Recorded locally either way: nothing the server returns tells a later
    // session what the flag currently is (see the note on [localSharing]).
    await _rememberSharing(questionId, shared);
    if (DemoFriendsMode.instance.enabled) return true; // local record only
    final client = _supabase;
    if (client == null || !_isAuthenticated || _rpcsMissing) return false;
    try {
      final raw = await client.rpc('set_answer_sharing', params: {
        'p_question_id': questionId,
        'p_shared': shared,
      });
      clearCache(questionId);
      if (raw is! Map || raw['success'] != true) return false;
      final updated = raw['updated'];
      return updated is num ? updated > 0 : false;
    } catch (e) {
      if (isMissingRpc(e)) {
        _rpcsMissing = true;
        debugPrint('NetworkService: set_answer_sharing is not deployed.');
        AnalyticsService().trackRpcNotDeployedOnce('set_answer_sharing');
      } else {
        debugPrint('NetworkService.setAnswerSharing($questionId) failed: $e');
        AnalyticsService().trackRpcFailed('set_answer_sharing',
            reason: analyticsRpcReason(e));
      }
      return false;
    }
  }

  /// The sharing flag for the viewer's answer to [questionId]: the server's
  /// `self_shared` when `get_network_results` is reachable (it is returned even
  /// on a gated result), else the record this device wrote at submit time or on
  /// its last flip, else the server default (`true`).
  Future<bool> currentSharing(String questionId) async {
    try {
      final r = await getNetworkResults(questionId);
      if (r.available && r.selfShared != null) {
        await _rememberSharing(questionId, r.selfShared!);
        return r.selfShared!;
      }
    } catch (_) {}
    return localSharing(questionId);
  }

  /// The sharing flag this device last saw for [questionId] (fallback for
  /// [currentSharing] when the backend is unreachable).
  Future<bool> localSharing(String questionId) async {
    if (questionId.isEmpty) return true;
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool('$_sharingKeyPrefix$questionId') ?? true;
    } catch (_) {
      return true;
    }
  }

  /// Records what the answer to [questionId] was filed with, so the results
  /// screen's toggle opens in the state the user chose. Called by the submit
  /// paths as well as by [setAnswerSharing].
  Future<void> rememberSubmittedSharing(String questionId, bool shared) =>
      _rememberSharing(questionId, shared);

  static const String _sharingKeyPrefix = 'answer_sharing_';

  Future<void> _rememberSharing(String questionId, bool shared) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('$_sharingKeyPrefix$questionId', shared);
    } catch (_) {
      // A missing preference just means the toggle opens on the default.
    }
  }
}

class _Cached<T> {
  final T value;
  final DateTime at;
  _Cached(this.value) : at = DateTime.now();
  bool isFresh(Duration d) => DateTime.now().difference(at) < d;
}
