// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Native app-store review prompt (Apple SKStoreReviewController via
// `in_app_review`, Google Play In-App Review on Android).
//
// Owner's requirement: "show it after the second question the user answers, or
// again the following week." The *rules* live in `utils/app_review_logic.dart`
// (pure, unit-tested); this file is the thin I/O shell around them —
// SharedPreferences bookkeeping, the plugin call, analytics.
//
// Wiring: one hook in `UserService.addAnsweredQuestion`, the single choke point
// every answer surface (home hero, answer screens, archive, onboarding replay,
// pending-answer flush, discussion answers) already passes through.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:in_app_review/in_app_review.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../utils/app_navigator.dart';
import '../utils/app_review_logic.dart';
import 'analytics_service.dart';
import 'post_answer_prompts.dart';

class AppReviewService {
  static final AppReviewService _instance = AppReviewService._internal();
  factory AppReviewService() => _instance;
  AppReviewService._internal();

  /// ISO-8601 stamp of the most recent prompt we actually fired.
  static const String _lastRequestedAtKey = 'app_review_last_requested_at';

  /// Every prompt we fired, ISO-8601, pruned to [kAppReviewQuotaWindow].
  static const String _requestTimestampsKey = 'app_review_request_timestamps';

  /// How long to wait after the answer is recorded before asking, so the OS
  /// sheet cannot race the notification-permission dialog that the QOTD submit
  /// path may put up in the same moment.
  static const Duration kPostAnswerDelay = Duration(milliseconds: 1500);

  /// Guards against two answers in quick succession each scheduling a prompt.
  bool _requestInFlight = false;

  /// Post-answer entry point. Fire-and-forget: never awaited by the answer
  /// path, never throws, and never blocks the UI.
  ///
  /// Waits [kPostAnswerDelay] and then declines if a dialog or bottom sheet is
  /// on top — see `isPopupRouteOnTop()` for why a pushed *page* does not count.
  void scheduleMaybeRequestReview({required int answeredCount}) {
    // Unit/widget tests must not leave a pending timer or hit the plugin.
    if (Platform.environment.containsKey('FLUTTER_TEST')) return;
    if (_requestInFlight) return;
    _requestInFlight = true;
    Future.delayed(kPostAnswerDelay, () async {
      try {
        // The notification-permission prompt owns the post-answer moment: if
        // it is on screen, or still owed and about to be drained by a surface,
        // yield to it. Skipping costs nothing — the next answer re-evaluates.
        if (PostAnswerPrompts.isShowing || PostAnswerPrompts.isPending) {
          await _trackSkipped('notification_prompt_pending');
          return;
        }
        if (isPopupRouteOnTop()) {
          // Any other dialog or bottom sheet on top.
          await _trackSkipped('popup_on_top');
          return;
        }
        await maybeRequestReview(answeredCount: answeredCount);
      } finally {
        _requestInFlight = false;
      }
    });
  }

  /// Run the decision and, if it says so, fire the native prompt.
  ///
  /// The timestamp is recorded **only** when `requestReview()` was actually
  /// called, so a platform that declines to show anything does not cost the
  /// user a slot in our own quota.
  Future<void> maybeRequestReview({required int answeredCount}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final now = DateTime.now();
      final lastRequestedAt = _readLastRequestedAt(prefs);
      final stamps = pruneAppReviewTimestamps(_readTimestamps(prefs), now);

      final decision = shouldRequestAppReview(
        answeredCount: answeredCount,
        now: now,
        lastRequestedAt: lastRequestedAt,
        requestsInLastYear: stamps.length,
      );

      if (kDebugMode) {
        print('APP REVIEW: decision=${decision.name} answered=$answeredCount '
            'last=${lastRequestedAt?.toIso8601String()} '
            'inWindow=${stamps.length}/$kAppReviewMaxRequestsPerWindow');
      }

      if (decision != AppReviewDecision.request) {
        await _trackSkipped(decision.name);
        return;
      }

      final inAppReview = InAppReview.instance;
      if (!await inAppReview.isAvailable()) {
        // iOS simulator, a Play-Store-less Android device, sideloads, F-Droid.
        if (kDebugMode) print('APP REVIEW: unavailable on this device');
        await _trackSkipped('unavailable');
        return;
      }

      await inAppReview.requestReview();

      // The call went out — spend the slot.
      final updated = pruneAppReviewTimestamps([...stamps, now], now);
      await prefs.setString(_lastRequestedAtKey, now.toIso8601String());
      await prefs.setStringList(
        _requestTimestampsKey,
        updated.map((t) => t.toIso8601String()).toList(),
      );

      if (kDebugMode) {
        print('APP REVIEW: requested (#${updated.length} in the last '
            '${kAppReviewQuotaWindow.inDays} days)');
      }
      await AnalyticsService().trackEvent('app_review_requested', {
        'answered_count': answeredCount,
        'request_number': updated.length,
      });
    } catch (e) {
      // A review prompt is never worth an error in the user's face.
      if (kDebugMode) print('APP REVIEW ERROR: $e');
      await _trackSkipped('error');
    }
  }

  Future<void> _trackSkipped(String reason) async {
    try {
      await AnalyticsService()
          .trackEvent('app_review_skipped', {'reason': reason});
    } catch (e) {
      if (kDebugMode) print('APP REVIEW ERROR: analytics failed: $e');
    }
  }

  DateTime? _readLastRequestedAt(SharedPreferences prefs) {
    final raw = prefs.getString(_lastRequestedAtKey);
    if (raw == null) return null;
    return DateTime.tryParse(raw);
  }

  List<DateTime> _readTimestamps(SharedPreferences prefs) {
    final raw = prefs.getStringList(_requestTimestampsKey) ?? const <String>[];
    return raw
        .map(DateTime.tryParse)
        .whereType<DateTime>()
        .toList(growable: false);
  }

  /// Forget every prompt on record, so the gate behaves like a fresh install.
  /// Only the app's own bookkeeping — the OS-level 3/365 counter is untouchable.
  Future<void> resetPromptHistory() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_lastRequestedAtKey);
    await prefs.remove(_requestTimestampsKey);
    if (kDebugMode) print('APP REVIEW: prompt history reset');
  }
}
