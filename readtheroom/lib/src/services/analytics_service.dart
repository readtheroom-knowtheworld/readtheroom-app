// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:posthog_flutter/posthog_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';

import '../utils/demo_friends_mode.dart';
import 'analytics_event_registry.dart';

// ---------------------------------------------------------------------------
// Answer-source attribution (design doc §4.2 / QOTD-first §12 crux).
//
// `question_answered` and `question_answer_started` must record WHERE the
// answer originated so the QOTD-first pivot decision can split answers by
// entry point. This vocabulary is the single source of truth; call sites pass
// a raw string and it is normalized through [answerSourceFromString] so an
// unknown/typo value can never leak an off-vocabulary source into PostHog.
// ---------------------------------------------------------------------------
enum AnswerSource {
  qotd, // QOTD overlay, QOTD card, QOTD widget, or QOTD notification entry
  feed, // home feed tap
  search, // search screen result
  deeplink, // shared link / deep link (non-QOTD)
  swipe, // feed-context swipe navigation
  archive, // archive (evolved Search) queue or "your answers" entry
  other, // profile, activity, comments, author preview, etc.
}

/// Normalize an arbitrary string into the controlled [AnswerSource] vocabulary.
/// Anything not in the vocabulary collapses to [AnswerSource.other].
AnswerSource answerSourceFromString(String? raw) {
  switch (raw) {
    case 'qotd':
      return AnswerSource.qotd;
    case 'feed':
      return AnswerSource.feed;
    case 'search':
      return AnswerSource.search;
    case 'deeplink':
      return AnswerSource.deeplink;
    case 'swipe':
      return AnswerSource.swipe;
    case 'archive':
      return AnswerSource.archive;
    default:
      return AnswerSource.other;
  }
}

/// The canonical PostHog property value for an [AnswerSource].
String answerSourceToEventValue(AnswerSource source) => source.name;

// ---------------------------------------------------------------------------
// Canonical onboarding funnel (design doc §4.2).
//
// One `onboarding_step` event with a string `step_id` + int `step_index`
// replaces the old mixed numbering. Legacy `step_name`/`step_number` are
// dual-written alongside (see [buildOnboardingStepEvents]) for one release so
// existing dashboards do not break.
// ---------------------------------------------------------------------------
/// Declared in flow order; [kOnboardingStepInfo] numbers them 0..n to match, so
/// a funnel ordered by `step_index` is the funnel the user actually walks.
///
/// WP-C3 (decision D5) inserted the guest-answer and profile steps between
/// welcome and passkey auth, which renumbered everything after them. The
/// onboarding notification ask (2026-09-17) then inserted three more beside the
/// QOTD outcomes. Later the same day the profile slide moved AHEAD of the QOTD
/// slide (welcome → chameleon + name → QOTD → passkey → location), so the
/// profile steps now sit at 2–4 and the QOTD/notification steps at 5–10.
/// `step_id` is the stable key — dashboards should group on it, not on
/// `step_index` — and the legacy `step_name`/`step_number` dual-write is
/// untouched.
enum OnboardingStep {
  onboardingStarted,
  welcomeViewed,
  // Pick a chameleon + name first (staged locally — no account yet), then
  // answer today's QOTD as a guest, then the passkey step.
  profilePrompted,
  profileCompleted,
  profileSkipped,
  qotdPrompted,
  qotdAnswered,
  qotdSkipped,
  // Right after the guest answers, on the same slide: the one-tap ask for
  // tomorrow's question. It sits here, beside the QOTD outcomes, because that
  // is where it fires — moving it later would make a step_index-ordered funnel
  // disagree with the walk.
  notificationsPrompted,
  notificationsEnabled,
  notificationsSkipped,
  authPrompted,
  authAttempted,
  authCompleted,
  analyticsConsentViewed, // F-Droid only
  locationPrompted,
  locationCompleted,
  generationCompleted,
  onboardingCompleted,
  // Terminal, and deliberately LAST: the "Skip" button on a re-run of
  // onboarding. It is not a stage of the walk, so it sits past
  // `onboardingCompleted` rather than renumbering anything before it.
  onboardingAbandoned,
}

class OnboardingStepInfo {
  final String stepId;
  final int stepIndex;
  const OnboardingStepInfo(this.stepId, this.stepIndex);
}

/// Canonical step_id / step_index for each onboarding step (§4.2 table).
const Map<OnboardingStep, OnboardingStepInfo> kOnboardingStepInfo = {
  OnboardingStep.onboardingStarted: OnboardingStepInfo('onboarding_started', 0),
  OnboardingStep.welcomeViewed: OnboardingStepInfo('welcome_viewed', 1),
  OnboardingStep.profilePrompted: OnboardingStepInfo('profile_prompted', 2),
  OnboardingStep.profileCompleted: OnboardingStepInfo('profile_completed', 3),
  OnboardingStep.profileSkipped: OnboardingStepInfo('profile_skipped', 4),
  OnboardingStep.qotdPrompted: OnboardingStepInfo('qotd_prompted', 5),
  OnboardingStep.qotdAnswered: OnboardingStepInfo('qotd_answered', 6),
  OnboardingStep.qotdSkipped: OnboardingStepInfo('qotd_skipped', 7),
  OnboardingStep.notificationsPrompted:
      OnboardingStepInfo('notifications_prompted', 8),
  OnboardingStep.notificationsEnabled:
      OnboardingStepInfo('notifications_enabled', 9),
  OnboardingStep.notificationsSkipped:
      OnboardingStepInfo('notifications_skipped', 10),
  OnboardingStep.authPrompted: OnboardingStepInfo('auth_prompted', 11),
  OnboardingStep.authAttempted: OnboardingStepInfo('auth_attempted', 12),
  OnboardingStep.authCompleted: OnboardingStepInfo('auth_completed', 13),
  OnboardingStep.analyticsConsentViewed:
      OnboardingStepInfo('analytics_consent_viewed', 14),
  OnboardingStep.locationPrompted: OnboardingStepInfo('location_prompted', 15),
  OnboardingStep.locationCompleted: OnboardingStepInfo('location_completed', 16),
  OnboardingStep.generationCompleted:
      OnboardingStepInfo('generation_completed', 17),
  OnboardingStep.onboardingCompleted:
      OnboardingStepInfo('onboarding_completed', 18),
  OnboardingStep.onboardingAbandoned:
      OnboardingStepInfo('onboarding_abandoned', 19),
};

/// Maps a PageView index to the canonical "slide viewed" step. Pure so it can
/// be unit-tested without the widget tree.
///
/// WP-C3 order (decision D5) — 5 slides, 6 on F-Droid:
///   Non-F-Droid: 0=welcome, 1=qotd, 2=profile, 3=auth, 4=location.
///   F-Droid:     0=welcome, 1=qotd, 2=profile, 3=auth,
///                4=analytics-consent, 5=location.
/// The F-Droid consent slide keeps its existing position (between auth and
/// location).
OnboardingStep? onboardingStepForPage(int page, {required bool isFDroid}) {
  switch (page) {
    case 0:
      return OnboardingStep.welcomeViewed;
    case 1:
      return OnboardingStep.profilePrompted;
    case 2:
      return OnboardingStep.qotdPrompted;
    case 3:
      return OnboardingStep.authPrompted;
  }
  if (isFDroid) {
    if (page == 4) return OnboardingStep.analyticsConsentViewed;
    if (page == 5) return OnboardingStep.locationPrompted;
  } else {
    if (page == 4) return OnboardingStep.locationPrompted;
  }
  return null;
}

/// Number of onboarding slides in the WP-C3 flow. Single source of truth for
/// `OnboardingScreen._totalPages` and the tests.
int onboardingTotalPages({required bool isFDroid}) => isFDroid ? 6 : 5;

// ---------------------------------------------------------------------------
// Error-code extraction (review 2026-09-22 C1 / F1).
//
// The one rule for every failure event: **codes and types only, never a
// message**. A PostgREST message can quote a question prompt; an HTTP body can
// quote a comment; `e.toString()` on almost anything can quote a handle. So a
// failure is reduced here, in one place, to a short stable token.
// ---------------------------------------------------------------------------

/// The `reason` for a caught exception: a PostgREST error code when the object
/// exposes one (`PGRST202` = the function is not deployed, `42501` = the SELECT
/// grant was revoked — exactly what the responses lockdown needs to watch),
/// otherwise the literal `exception`.
///
/// Duck-typed rather than typed against `PostgrestException` so this file stays
/// free of a Supabase import and the function stays unit-testable with a stub.
String analyticsRpcReason(Object? error) {
  if (error == null) return 'exception';
  try {
    final dynamic e = error;
    final code = e.code;
    if (code is String && code.isNotEmpty && code.length <= 32) {
      return code;
    }
  } catch (_) {
    // No `code` getter — fall through.
  }
  return 'exception';
}

/// The `error_type` for an `app_error`: the runtime type's name, and nothing
/// else. Never the message.
String analyticsErrorType(Object? error) =>
    error == null ? 'unknown' : error.runtimeType.toString();

// ---------------------------------------------------------------------------
// Closed vocabularies (review 2026-09-22 §4.2, P1-9).
//
// Both of these used to be documented in a doc comment and re-stated in a
// test, and both had drifted: `deeplink_opened` was emitting `streak_widget`
// and `qotd_push` without either being listed, and `qr_shown.surface` had
// grown to six undeclared values. The test's source-grepping regexes could not
// see the computed kinds at all, so it passed vacuously.
//
// They are `const Set`s now: the router, the dialog and the test all read the
// same object, so a new value is a deliberate edit here or it is a test
// failure.
// ---------------------------------------------------------------------------

/// Every routing category `deeplink_opened` may carry. Never a link, an id or
/// a token.
///
/// NOTE on double counting: a tapped Drop emits BOTH `notification_opened`
/// and `deeplink_opened {kind: qotd_push}` — they answer different questions
/// (delivery vs routing), so both are kept, but `qotd_push` must be excluded
/// from any "deep link opens" total or it double-counts against notifications.
const Set<String> kDeepLinkKinds = <String>{
  'question',
  'qotd',
  'qotd_widget',
  'streak_widget',
  'qotd_push',
  'home',
  'room',
  'friend_token',
  'friend_chat',
  'community',
  'unknown',
};

/// Every surface `qr_shown` may be tagged with.
const Set<String> kQrSurfaces = <String>{
  'header',
  'community',
  'community_nudge',
  'home_nudge',
  'home_identity',
  'network_results',
};

// ---------------------------------------------------------------------------
// The identity chain, as data (review 2026-09-19 P0-5).
//
// The order of these steps IS the fix, so it is expressed as a pure function
// and unit-tested rather than living only inside an async method nobody can
// run in a test.
// ---------------------------------------------------------------------------
enum IdentityStep {
  /// `Posthog().alias(alias: userId)` — binds the CURRENT (anonymous) distinct
  /// id to the account id. Must come first: after `identify` the distinct id
  /// already is the account id, and PostHog will not merge two ids that are
  /// both already identified.
  alias,

  /// `Posthog().identify(userId: userId, ...)`.
  identify,

  /// Re-register the `is_authenticated` super property as true.
  registerAuthenticated,
}

/// The steps `identifyUser` must take, in order.
///
/// * an empty id does nothing — the old code could `identify('')` and mint a
///   junk person keyed on the empty string (P0-5c);
/// * re-identifying the SAME user skips the alias — aliasing an id to itself
///   is meaningless and PostHog rejects it;
/// * otherwise: alias, then identify, then re-register the super property.
List<IdentityStep> identifyUserSteps({
  required String? currentUserId,
  required String userId,
}) {
  if (userId.isEmpty) return const <IdentityStep>[];
  if (currentUserId == userId) {
    return const <IdentityStep>[
      IdentityStep.identify,
      IdentityStep.registerAuthenticated,
    ];
  }
  return const <IdentityStep>[
    IdentityStep.alias,
    IdentityStep.identify,
    IdentityStep.registerAuthenticated,
  ];
}

// ---------------------------------------------------------------------------
// Background push receipts (review 2026-09-22 A1), as pure functions so the
// stash written by the FCM isolate and the drain that reports it can be
// asserted together in a unit test.
// ---------------------------------------------------------------------------

/// One stashed receipt. **No question id and no history id** — a per-day
/// `drop_date` joins the receipt to the day's Drop and carries no per-person
/// link.
Map<String, dynamic> buildPushReceiptEntry({
  required String kind,
  required bool isDrop,
  required DateTime receivedAt,
  DateTime? publishedAt,
}) {
  final published = publishedAt?.toUtc();
  return <String, dynamic>{
    'kind': kind,
    'is_drop': isDrop,
    'received_at': receivedAt.toUtc().toIso8601String(),
    'published_at': published?.toIso8601String(),
    'drop_date': published?.toIso8601String().substring(0, 10),
  };
}

/// Appends [entry] to [existing] and caps the list at [cap], keeping the most
/// recent. A device offline for a week should report the last few Drops, not
/// replay a month of them.
List<dynamic> appendPushReceipt(
  List<dynamic> existing,
  Map<String, dynamic> entry, {
  int cap = AnalyticsService.maxPendingPushReceipts,
}) {
  final out = <dynamic>[...existing, entry];
  if (out.length <= cap) return out;
  return out.sublist(out.length - cap);
}

/// The events one drained stash produces. Malformed entries are skipped rather
/// than throwing: a corrupt receipt must never cost the launch.
List<AnalyticsEventSpec> buildPushReceiptEvents(
    List<dynamic> stash, DateTime now) {
  final utcNow = now.toUtc();
  final events = <AnalyticsEventSpec>[];
  for (final entry in stash) {
    if (entry is! Map) continue;
    final receivedAtRaw = entry['received_at'];
    final receivedAt =
        receivedAtRaw is String ? DateTime.tryParse(receivedAtRaw)?.toUtc() : null;
    events.add(AnalyticsEventSpec('notification_received', {
      'notification_type': 'qotd',
      'delivery_context': 'background',
      'push_kind': entry['kind'] is String ? entry['kind'] : 'unknown',
      'is_drop': entry['is_drop'] == true,
      if (entry['drop_date'] is String) 'drop_date': entry['drop_date'],
      if (receivedAt != null)
        'seconds_to_report': utcNow.difference(receivedAt).inSeconds,
    }));
  }
  return events;
}

/// The newest `received_at` in a stash, for the `notification_response_time`
/// stamp — a tap in this session belongs to the most recent receipt.
DateTime? newestPushReceipt(List<dynamic> stash) {
  DateTime? newest;
  for (final entry in stash) {
    if (entry is! Map) continue;
    final raw = entry['received_at'];
    if (raw is! String) continue;
    final parsed = DateTime.tryParse(raw)?.toUtc();
    if (parsed == null) continue;
    if (newest == null || parsed.isAfter(newest)) newest = parsed;
  }
  return newest;
}

/// How the app was most recently entered, for the one surface that is never
/// told: home (review 2026-09-22 A4).
///
/// The Drop now opens the HOME tab rather than the question
/// (`deep_link_service` just calls `MainTabRequests.goTo(MainTab.home)`), so
/// "did the push land on a user who then answered?" had no way to be read.
/// The router stamps the entry here; `home_screen` consumes it exactly once
/// and it falls back to `direct`.
///
/// A routing category, never a link, an id or a token — the same rule
/// `deeplink_opened.kind` follows.
class AppEntry {
  AppEntry._();

  static String? _lastSource;

  static void record(String source) => _lastSource = source;

  /// Reads and clears, so a later home view is not attributed to an old push.
  static String? consumeLastSource() {
    final value = _lastSource;
    _lastSource = null;
    return value;
  }

  @visibleForTesting
  static void debugReset() => _lastSource = null;
}

/// A single analytics event to emit — used by pure builders so the emitted
/// shape can be asserted in unit tests without a live PostHog client.
class AnalyticsEventSpec {
  final String name;
  final Map<String, dynamic> properties;
  const AnalyticsEventSpec(this.name, this.properties);
}

/// Builds the events for one canonical onboarding step. Emits the canonical
/// `onboarding_step` (step_id + step_index) and, when [legacyStepName] is
/// provided, a dual-write legacy `onboarding_step` (step_name + step_number)
/// so pre-existing dashboards keep receiving their events for one release.
List<AnalyticsEventSpec> buildOnboardingStepEvents(
  OnboardingStep step, {
  String? legacyStepName,
  int? legacyStepNumber,
  Map<String, dynamic>? properties,
}) {
  final info = kOnboardingStepInfo[step]!;
  final events = <AnalyticsEventSpec>[
    AnalyticsEventSpec('onboarding_step', {
      'step_id': info.stepId,
      'step_index': info.stepIndex,
      ...?properties,
    }),
  ];
  if (legacyStepName != null) {
    events.add(AnalyticsEventSpec('onboarding_step', {
      'step_name': legacyStepName,
      'step_number': legacyStepNumber ?? info.stepIndex,
      ...?properties,
    }));
  }
  return events;
}

class AnalyticsService {
  static final AnalyticsService _instance = AnalyticsService._internal();
  factory AnalyticsService() => _instance;
  AnalyticsService._internal();

  static const String _analyticsOptOutKey = 'analytics_opt_out';
  // The project key is supplied at build time from `.env` (POSTHOG_API_KEY)
  // via --dart-define / --dart-define-from-file. It is deliberately NOT given
  // a default: a committed key is a key that cannot be rotated (review
  // 2026-09-19 P1-13). An empty key means `initialize()` does nothing, which
  // is the correct failure mode for a build that forgot the define.
  static const String _posthogApiKey =
      String.fromEnvironment('POSTHOG_API_KEY');
  static const String _posthogHost = String.fromEnvironment('POSTHOG_HOST', defaultValue: 'https://us.i.posthog.com');

  bool _isInitialized = false;
  bool _isOptedOut = false;
  String? _currentUserId;
  String? _deviceId;

  // ---- Test seam --------------------------------------------------------
  // When [debugEventSink] is non-null, [trackEvent] records the (name, props)
  // it would send instead of calling PostHog, so the opt-out gate, canonical
  // onboarding funnel, and source attribution can be asserted in unit tests
  // without a live PostHog client. Suppression (opt-out / not-initialized)
  // still short-circuits BEFORE recording, so an opted-out service records
  // nothing — exactly what production does.
  @visibleForTesting
  List<AnalyticsEventSpec>? debugEventSink;

  @visibleForTesting
  void debugConfigure({required bool optedOut, required bool initialized}) {
    _isOptedOut = optedOut;
    _isInitialized = initialized;
  }

  @visibleForTesting
  void debugReset() {
    _isOptedOut = false;
    _isInitialized = false;
    debugEventSink = null;
    demoModeGate = () => DemoFriendsMode.instance.enabled;
    _fallbackReported = false;
    _networkRpcReported.clear();
  }

  Future<void> initialize() async {
    if (_isInitialized) return;

    try {
      final prefs = await SharedPreferences.getInstance();
      _isOptedOut = prefs.getBool(_analyticsOptOutKey) ?? false;

      if (_posthogApiKey.isEmpty) {
        debugPrint(
            'Analytics disabled: POSTHOG_API_KEY was not supplied at build '
            'time (--dart-define-from-file=.env).');
        return;
      }

      if (!_isOptedOut && !kDebugMode) {
        final config = PostHogConfig(_posthogApiKey);
        config.host = _posthogHost;
        config.captureApplicationLifecycleEvents = true;
        config.debug = kDebugMode;
        
        // Configure person profiles for cost optimization
        // Using identifiedOnly to capture anonymous events by default
        // and only create person profiles after identify/alias/group
        config.personProfiles = PostHogPersonProfiles.identifiedOnly;
        
        // Configure offline queue
        config.maxQueueSize = 1000; // Max events to store offline
        config.flushAt = 20; // Batch size for sending events
        config.flushInterval = Duration(seconds: 30); // How often to flush
        
        await Posthog().setup(config);
        _isInitialized = true;
        
        await _setDefaultSuperProperties();
      }
    } catch (e) {
      debugPrint('Failed to initialize analytics: $e');
    }
  }

  Future<void> _setDefaultSuperProperties() async {
    if (_isOptedOut || !_isInitialized) return;
    
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      await Posthog().register(
        'app_version', '${packageInfo.version}+${packageInfo.buildNumber}',
      );
      // The build on its own, because `app_version` is a compound string and
      // "which build regressed" is a per-build question.
      await Posthog().register('build', packageInfo.buildNumber);
      await Posthog().register(
        'platform', defaultTargetPlatform.toString().split('.').last,
      );
      // F5 (P1-11): guest vs signed-in on EVERY event, not just on every
      // person. With `personProfiles: identifiedOnly` a guest has no person
      // profile at all, so a person-property split cannot see them; a super
      // property can. Re-registered by `identifyUser` and `reset()`.
      await _registerIsAuthenticated(_currentUserId != null);
    } catch (e) {
      debugPrint('Failed to set super properties: $e');
    }
  }

  Future<void> _registerIsAuthenticated(bool value) async {
    try {
      await Posthog().register('is_authenticated', value);
    } catch (e) {
      debugPrint('Failed to register is_authenticated: $e');
    }
  }

  // ---------------------------------------------------------------------
  // THE IDENTITY MODEL (review 2026-09-19 P0-5, fixed here)
  //
  // 1. A guest is the SDK's own anonymous distinct id. Nothing identifies an
  //    install any more. Guest facts ride as super properties and as the
  //    `is_authenticated: false` split, so a guest is fully analysable
  //    without a person profile (`personProfiles: identifiedOnly` would not
  //    create one anyway).
  // 2. Signing in calls `alias(userId)` FIRST, while the distinct id is still
  //    the anonymous one, and only then `identify(userId)`. That is the order
  //    that merges: the alias binds the anon id to the account id before the
  //    switch. The old code identified first and aliased second, by which
  //    point the distinct id already WAS `userId`, making the alias a no-op —
  //    and PostHog will not merge two ids that are both already identified.
  // 3. Signing out calls `reset()`, which mints a fresh anonymous id. A second
  //    account on the same device is a second person, deliberately.
  //
  // The bug this fixes: `identifyAnonymousUser` hard-identified every install
  // with the device id from a LAZY provider, so which identify won was
  // order-dependent, and `onboarding_started` / `qotd_answered` could land on
  // a different person from `auth_completed` / `question_answered`. D2 could
  // not be built and per-person retention was unreliable.
  // ---------------------------------------------------------------------
  Future<void> identifyUser(String userId, Map<String, dynamic>? properties, [Map<String, dynamic>? propertiesSetOnce]) async {
    if (_isOptedOut || !_isInitialized) return;
    if (userId.isEmpty) return;

    try {
      // The order is the fix — see [identifyUserSteps], which is where it is
      // specified and tested.
      final steps =
          identifyUserSteps(currentUserId: _currentUserId, userId: userId);
      final userProps = properties?.cast<String, Object>() ?? <String, Object>{};
      final userPropsOnce = propertiesSetOnce?.cast<String, Object>();
      for (final step in steps) {
        switch (step) {
          case IdentityStep.alias:
            await Posthog().alias(alias: userId);
            break;
          case IdentityStep.identify:
            _currentUserId = userId;
            await Posthog().identify(
              userId: userId,
              userProperties: userProps,
              userPropertiesSetOnce: userPropsOnce,
            );
            break;
          case IdentityStep.registerAuthenticated:
            await _registerIsAuthenticated(true);
            break;
        }
      }
    } catch (e) {
      debugPrint('Failed to identify user: $e');
    }
  }

  /// Remembers the device id and records the guest facts WITHOUT identifying.
  ///
  /// Step 1 of the identity model above. This used to call
  /// `Posthog().identify(userId: deviceId)`, which minted a person per install
  /// and made the later `identify(userId)` a merge PostHog refuses to perform.
  Future<void> identifyAnonymousUser(String deviceId) async {
    if (_isOptedOut || !_isInitialized) return;

    try {
      _deviceId = deviceId;
      // PRIVACY (review 2026-09-19 P0-2): `device_id` is not a person property
      // either. The consent slide promises "no device fingerprints".
      await _registerIsAuthenticated(false);
    } catch (e) {
      debugPrint('Failed to record anonymous user: $e');
    }
  }

  /// Sets person properties — only for a person who actually exists.
  ///
  /// Guarded (review 2026-09-19 P0-5c): the old code fell back to
  /// `identify(userId: '')`, which either errored or created a junk person
  /// keyed on the empty string. A guest has no person profile by design, so
  /// guest properties are simply dropped here; the `is_authenticated` super
  /// property is what splits guests from members.
  Future<void> setUserProperties(Map<String, dynamic> properties) async {
    if (_isOptedOut || !_isInitialized) return;
    final userId = _currentUserId;
    if (userId == null || userId.isEmpty) return;

    try {
      final userProps = properties.cast<String, Object>();
      await Posthog().identify(userId: userId, userProperties: userProps);
    } catch (e) {
      debugPrint('Failed to set user properties: $e');
    }
  }

  /// DEMO-DATA KILL SWITCH (review 2026-09-22 B2, task item 3).
  ///
  /// `DemoFriendsMode` swaps in fabricated friends, a fabricated ego graph and
  /// fabricated answer counts. `buildDemoNetworkResults` round-trips that
  /// fiction through the real parser, so by the time it reaches an event it is
  /// indistinguishable from a server payload.
  ///
  /// Today a double lock keeps it out of PostHog — demo mode needs
  /// `kDebugMode` and `initialize()` needs `!kDebugMode` — but P1-15 proposes
  /// removing the second lock precisely so instrumentation can be verified
  /// locally, and at that moment fabricated data would start flowing as
  /// `state: 'network'`.
  ///
  /// DECISION: **drop**, not tag. A `demo: true` property only helps if every
  /// insight, funnel and cohort remembers to filter on it; one that forgets
  /// silently mixes fiction into a real metric. Dropping cannot be got wrong.
  /// The switch is here rather than at the call sites so it covers events that
  /// have not been written yet.
  @visibleForTesting
  bool Function() demoModeGate = () => DemoFriendsMode.instance.enabled;

  Future<void> trackEvent(String eventName, [Map<String, dynamic>? properties, bool? processPersonProfile]) async {
    if (_isOptedOut || !_isInitialized) return;
    if (demoModeGate()) return;

    // Debug-only: the catalogue in `analytics_event_registry.dart` is the
    // contract, and `test/analytics_registry_test.dart` enforces it against
    // the whole tree. This is the same check at the moment of emission, so a
    // dynamically-named event (one the source scan cannot see) still says so
    // out loud during development. Compiled out of release entirely.
    assert(() {
      final schema = kAnalyticsEventRegistry[eventName];
      if (schema == null) {
        debugPrint('ANALYTICS: "$eventName" is not declared in '
            'kAnalyticsEventRegistry — add it, or the catalogue is a lie.');
        return true;
      }
      for (final key in (properties ?? const <String, dynamic>{}).keys) {
        if (key.startsWith(r'$')) continue;
        if (!schema.properties.contains(key)) {
          debugPrint('ANALYTICS: "$eventName" sent an undeclared property '
              '"$key".');
        }
      }
      return true;
    }());
    
    try {
      final eventProps = properties?.cast<String, Object>() ?? <String, Object>{};
      
      // Add person profile processing flag if specified
      if (processPersonProfile != null) {
        eventProps['\$process_person_profile'] = processPersonProfile;
      }

      // Test seam: record instead of hitting PostHog (opt-out already applied).
      if (debugEventSink != null) {
        debugEventSink!.add(AnalyticsEventSpec(eventName, Map<String, dynamic>.from(eventProps)));
        return;
      }

      await Posthog().capture(eventName: eventName, properties: eventProps);
    } catch (e) {
      debugPrint('Failed to track event $eventName: $e');
    }
  }
  
  // Convenience method for tracking events without person profile processing
  Future<void> trackEventAnonymous(String eventName, [Map<String, dynamic>? properties]) async {
    await trackEvent(eventName, properties, false);
  }

  Future<void> trackScreenView(String screenName, [Map<String, dynamic>? properties]) async {
    if (_isOptedOut || !_isInitialized) return;
    
    try {
      final screenProperties = properties?.cast<String, Object>() ?? <String, Object>{};
      await Posthog().screen(screenName: screenName, properties: screenProperties);
    } catch (e) {
      debugPrint('Failed to track screen view $screenName: $e');
    }
  }

  // Onboarding funnel tracking
  Future<void> trackOnboardingStep(String stepName, int stepNumber, [Map<String, dynamic>? additionalProperties, bool? processPersonProfile]) async {
    if (_isOptedOut || !_isInitialized) return;
    
    final properties = {
      'step_name': stepName,
      'step_number': stepNumber,
      ...?additionalProperties,
    };
    
    await trackEvent('onboarding_step', properties, processPersonProfile);
  }

  // Question interaction tracking
  Future<void> trackQuestionViewed(String questionId, String questionType, String category, String viewSource, [Map<String, dynamic>? additionalProperties]) async {
    if (_isOptedOut || !_isInitialized) return;

    // Track question revisit behavior
    final revisitData = await _trackQuestionRevisitBehavior(questionId);

    final properties = {
      'question_type': questionType,
      'category': category,
      'view_source': viewSource,
      'view_count': revisitData['viewCount'],
      'is_revisit': revisitData['isRevisit'],
      'days_since_first_view': revisitData['daysSinceFirstView'],
      'time_since_last_view_minutes': revisitData['timeSinceLastViewMinutes'],
      ...?additionalProperties,
    };

    // Review 2026-09-22 §4.1: `question_revisited` duplicated every property
    // of this event and fired alongside it. `is_revisit` and `view_count` here
    // carry the same information with one name.
    await trackEvent('question_viewed', properties);
  }
  
  // Phase 5: Question revisit behavior tracking
  Future<Map<String, dynamic>> _trackQuestionRevisitBehavior(String questionId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final now = DateTime.now();
      
      // Track view history for this question
      final viewHistoryKey = 'question_views_$questionId';
      final viewHistoryString = prefs.getString(viewHistoryKey);
      
      List<String> viewHistory = [];
      if (viewHistoryString != null) {
        viewHistory = List<String>.from(json.decode(viewHistoryString));
      }
      
      // Add current view
      viewHistory.add(now.toIso8601String());
      
      // Keep only last 10 views to prevent storage bloat
      if (viewHistory.length > 10) {
        viewHistory = viewHistory.sublist(viewHistory.length - 10);
      }
      
      // Save updated history
      await prefs.setString(viewHistoryKey, json.encode(viewHistory));
      
      // Calculate revisit metrics
      final viewCount = viewHistory.length;
      final isRevisit = viewCount > 1;
      
      int? daysSinceFirstView;
      int? timeSinceLastViewMinutes;
      
      if (viewHistory.isNotEmpty) {
        final firstView = DateTime.parse(viewHistory.first);
        daysSinceFirstView = now.difference(firstView).inDays;
        
        if (viewHistory.length > 1) {
          final lastView = DateTime.parse(viewHistory[viewHistory.length - 2]);
          timeSinceLastViewMinutes = now.difference(lastView).inMinutes;
        }
      }
      
      return {
        'viewCount': viewCount,
        'isRevisit': isRevisit,
        'daysSinceFirstView': daysSinceFirstView,
        'timeSinceLastViewMinutes': timeSinceLastViewMinutes,
      };
      
    } catch (e) {
      debugPrint('Failed to track question revisit behavior: $e');
      return {
        'viewCount': 1,
        'isRevisit': false,
        'daysSinceFirstView': 0,
        'timeSinceLastViewMinutes': null,
      };
    }
  }

  /// §4.2: the answer flow was entered.
  ///
  /// PRIVACY (review 2026-09-19 P0-1, 2026-09-22 §4.4): this event fires
  /// against an IDENTIFIED person, so it must never carry a question id.
  /// `responses` deliberately has no `user_id` (DBarchitecture.md:167) and
  /// `networks-client-2026-09-22.md` §5 rule 5 makes "no analytics event
  /// carries a question id" a written project rule — a `question_id` here
  /// would re-create in PostHog the exact person<->answer join the schema
  /// refuses to store. The funnels split on `question_type` and `source`.
  /// Enforced by [kIdentifiedAnswerEvents] and its test.
  Future<void> trackQuestionAnswerStarted(
    String questionType, {
    String? source,
  }) async {
    if (_isOptedOut || !_isInitialized) return;

    await trackEvent('question_answer_started', {
      'question_type': questionType,
      // Source attribution (§4.2 crux): where the answer flow was entered.
      'source': answerSourceToEventValue(answerSourceFromString(source)),
    });
  }

  /// Review 2026-09-22 C2: a submit the server refused, or that threw.
  ///
  /// Without it a failed answer is indistinguishable from a user who chose not
  /// to answer, and `question_answer_started -> question_answered` silently
  /// loses them. The *reason* rides on the paired `rpc_failed` (B7 / C1),
  /// joined by timestamp, so the reason vocabulary lives in exactly one place.
  /// No `question_id` — same rule as [trackQuestionAnswered].
  Future<void> trackAnswerSubmitFailed(
    String questionType, {
    String? source,
  }) async {
    await trackEvent('answer_submit_failed', {
      'question_type': questionType,
      'source': answerSourceToEventValue(answerSourceFromString(source)),
    });
  }

  /// §4.2: a successful answer. Never carries a `question_id` — see
  /// [trackQuestionAnswerStarted] for why, and [kIdentifiedAnswerEvents] for
  /// the rule the test enforces.
  Future<void> trackQuestionAnswered(
    String questionType,
    String answerType, {
    String? source,
    bool? sharedWithCloseFriends,
  }) async {
    if (_isOptedOut || !_isInitialized) return;

    // Activation: flag the very first answer on the event that already exists
    // rather than minting a separate `first_answer` name — one funnel, one
    // event, split on the property.
    final isFirst = await markFirstTime('answer');

    await trackEvent('question_answered', {
      'question_type': questionType,
      'answer_type': answerType,
      // Source attribution (§4.2 crux): the pivot decision hinges on this split.
      'source': answerSourceToEventValue(answerSourceFromString(source)),
      if (isFirst) 'is_first': true,
      // The per-answer close-friend flag as submitted (owner decision
      // 2026-09-17). Omitted rather than defaulted where a call site has no
      // toggle to report, so "unset" can never be read as an opt-out.
      if (sharedWithCloseFriends != null)
        'shared_with_close_friends': sharedWithCloseFriends,
    });
  }

  /// §4.2: answer screen dismissed (dispose/back) without a successful submit.
  /// Call sites must guard against firing after a successful submission.
  Future<void> trackQuestionAnswerAbandoned(
    String questionType,
    int timeOnScreenSeconds, {
    String? source,
  }) async {
    if (_isOptedOut || !_isInitialized) return;

    await trackEvent('question_answer_abandoned', {
      'question_type': questionType,
      'time_on_screen_seconds': timeOnScreenSeconds,
      'source': answerSourceToEventValue(answerSourceFromString(source)),
    });
  }

  /// §4.2: question creation flow entered (new_question_screen initState).
  Future<void> trackQuestionCreateStarted(String entryPoint) async {
    if (_isOptedOut || !_isInitialized) return;

    await trackEvent('question_create_started', {
      'entry_point': entryPoint,
    });
  }

  /// §4.2: creation flow left (dispose) without posting. `furthestField` is the
  /// deepest field the user reached — never the field's text (privacy rule).
  Future<void> trackQuestionCreateAbandoned(String furthestField) async {
    if (_isOptedOut || !_isInitialized) return;

    await trackEvent('question_create_abandoned', {
      'furthest_field': furthestField,
    });
  }

  /// QOTD-first §12 growth-loop proxy: a share action was initiated.
  /// [surface] is one of `question` | `results` | `qotd`.
  Future<void> trackShareInitiated(String surface, {String? method, String? questionId}) async {
    if (_isOptedOut || !_isInitialized) return;

    await trackEvent('share_initiated', {
      'surface': surface,
      if (method != null) 'method': method,
      if (questionId != null) 'question_id': questionId,
    });
  }

  // -------------------------------------------------------------------------
  // Analytics review 2026-09-16: activation flags, and the funnel events the
  // social / prompt / deep-link surfaces were missing.
  //
  // Activation is measured as `is_first: true` on the event that already
  // exists, never as a parallel `first_*` event name, so one insight answers
  // both "how many" and "how many for the first time". The flag lives in
  // SharedPreferences under one namespace; a reinstall re-activates, which is
  // the honest reading (a new install is a new activation).
  // -------------------------------------------------------------------------
  static const String _firstTimePrefix = 'analytics_first_';

  /// Returns true exactly once per [key] per install, and remembers it.
  /// Any prefs failure returns false: a missed `is_first` is a much smaller
  /// problem than a duplicated one.
  @visibleForTesting
  Future<bool> markFirstTime(String key) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final prefsKey = '$_firstTimePrefix$key';
      if (prefs.getBool(prefsKey) ?? false) return false;
      await prefs.setBool(prefsKey, true);
      return true;
    } catch (e) {
      debugPrint('Failed to read first-time flag $key: $e');
      return false;
    }
  }

  /// A deep link or widget tap that opened the app. [kind] is a routing
  /// category, never the link itself — no ids, no tokens. The vocabulary is
  /// [kDeepLinkKinds]; anything outside it collapses to `unknown` rather than
  /// minting a value no dashboard knows about.
  Future<void> trackDeepLinkOpened(String kind) async {
    final safe = kDeepLinkKinds.contains(kind) ? kind : 'unknown';
    await trackEvent('deeplink_opened', {'kind': safe});
  }

  /// A question reaction was added or removed. [emojiSource] says which control
  /// produced it: `chip` (an existing reaction chip), `quick` (a quick pick in
  /// the sheet) or `picker` (the full keyboard, including its name search).
  /// The emoji itself is never sent — it is user-authored content, the same
  /// rule `friend_reaction_sent` follows.
  Future<void> trackReaction({
    required bool added,
    required String emojiSource,
    String? questionId,
  }) async {
    if (!added) {
      await trackEvent('reaction_removed', {
        'emoji_source': emojiSource,
        if (questionId != null) 'question_id': questionId,
      });
      return;
    }
    final isFirst = await markFirstTime('reaction');
    await trackEvent('reaction_added', {
      'emoji_source': emojiSource,
      if (questionId != null) 'question_id': questionId,
      if (isFirst) 'is_first': true,
    });
  }

  /// A comment was posted. Never carries the comment body.
  Future<void> trackCommentPosted({
    String? questionId,
    bool hasLinkedQuestions = false,
  }) async {
    final isFirst = await markFirstTime('comment');
    await trackEvent('comment_posted', {
      if (questionId != null) 'question_id': questionId,
      'has_linked_questions': hasLinkedQuestions,
      if (isFirst) 'is_first': true,
    });
  }

  /// Rating stage 1 (the optional slider). [ratingBucket] is
  /// `positive` | `neutral` | `negative` — the bucket, not the raw value, so a
  /// deliberately anonymous rating cannot be joined back to a person.
  /// No `question_id`, for the same reason as [trackQuestionAnswered]:
  /// "person X rated question Y negatively" is exactly the join the schema
  /// refuses to store, and `rating_bucket` alone does not save it once the id
  /// is present.
  Future<void> trackQuestionRated(String ratingBucket) async {
    await trackEvent('question_rated', {
      'rating_bucket': ratingBucket,
    });
  }

  /// Rating stage 2 (the review-tag chips): submitted with [tagCount] tags, or
  /// skipped. Only the count travels — the tag breakdown is already queryable
  /// server-side, and the count is what the drop-off question needs.
  Future<void> trackReviewTags({required bool skipped, int tagCount = 0}) async {
    await trackEvent(
      skipped ? 'review_tags_skipped' : 'review_tags_submitted',
      skipped ? const {} : {'tag_count': tagCount},
    );
  }

  /// The outcome of a notification permission prompt, tagged with the prompt's
  /// [source] (`main_screen` | `first_lick` | `settings` | ...) so effectiveness
  /// is measurable per surface. `notification_prompt_shown` carries the same
  /// `source`, which makes the pair a funnel.
  Future<void> trackNotificationPromptResult({
    required String source,
    required bool granted,
  }) async {
    await trackEvent('notification_prompt_result', {
      'source': source,
      'granted': granted,
    });
  }

  /// A backend call that failed in a way the user saw. [action] is a short
  /// stable verb (`send_friend_request`, `nominate_qotd`, `submit_rating`, ...)
  /// and [reason] a code from our own error vocabulary — never a raw server
  /// message, which can quote user content.
  Future<void> trackRpcFailed(String action, {String? reason}) async {
    await trackEvent('rpc_failed', {
      'action': action,
      if (reason != null) 'reason': reason,
    });
  }

  /// An unhandled Flutter / platform error (review 2026-09-22 F1).
  ///
  /// [errorType] and [library] only. **Never** `error.toString()`: a
  /// `PostgrestException`, an HTTP body or an assertion message can quote a
  /// question prompt, a comment or a handle, and an error event is not a place
  /// to leak user content. Use [analyticsErrorType] to derive [errorType].
  Future<void> trackAppError({
    required String errorType,
    String? library,
    required bool fatal,
  }) async {
    await trackEvent('app_error', {
      'error_type': errorType,
      if (library != null) 'library': library,
      'fatal': fatal,
    });
  }

  /// A topic subscribe / unsubscribe attempt (review 2026-09-22 A3).
  ///
  /// [result] is `ok` or `failed`; [trigger] is `launch` | `settings` |
  /// `unsubscribe`. This is the denominator under the Drop's delivery
  /// denominator: a device that is not on the `qotd` topic can never receive
  /// a Drop at all, and until now nothing said how many of those there are.
  Future<void> trackPushTopicSubscription({
    required String topic,
    required String result,
    required String trigger,
  }) async {
    await trackEventAnonymous('push_topic_subscription', {
      'topic': topic,
      'result': result,
      'trigger': trigger,
    });
  }

  /// The RPC fell back to the legacy unlinked insert (review 2026-09-22 B7).
  /// Fired at most once per session — the interesting number is "does this
  /// build's server have the function", not how many answers were filed.
  bool _fallbackReported = false;
  Future<void> trackSubmitResponseFallbackUsed(String reason) async {
    if (_fallbackReported) return;
    _fallbackReported = true;
    await trackEvent('submit_response_fallback_used', {'reason': reason});
  }

  /// `rpc_failed` for an RPC that is simply not deployed (review 2026-09-22
  /// B6). Reported once per `action` per session: the fact is about the
  /// project's schema, not about how many times a screen asked, and a
  /// sticky-flag service would otherwise emit one per card per scroll.
  final Set<String> _networkRpcReported = <String>{};
  Future<void> trackRpcNotDeployedOnce(String action) async {
    if (!_networkRpcReported.add(action)) return;
    await trackRpcFailed(action, reason: 'not_deployed');
  }

  @visibleForTesting
  void debugResetOnceFlags() {
    _fallbackReported = false;
  }

  /// The guest QOTD answer stashed during onboarding, replayed once the account
  /// exists. The failure case is the one worth counting: a silently lost first
  /// answer is an activation hole no other event reveals.
  Future<void> trackPendingAnswerReplayed({required bool success}) async {
    await trackEvent('pending_answer_replayed', {'success': success});
  }

  /// §4.2: canonical onboarding funnel step. Emits `onboarding_step` with
  /// step_id + step_index, plus a dual-write legacy `onboarding_step`
  /// (step_name + step_number) when [legacyStepName] is supplied.
  Future<void> trackOnboardingStepCanonical(
    OnboardingStep step, {
    String? legacyStepName,
    int? legacyStepNumber,
    Map<String, dynamic>? properties,
  }) async {
    if (_isOptedOut || !_isInitialized) return;

    final events = buildOnboardingStepEvents(
      step,
      legacyStepName: legacyStepName,
      legacyStepNumber: legacyStepNumber,
      properties: properties,
    );
    for (final event in events) {
      await trackEvent(event.name, event.properties);
    }
  }

  /// §4.2 fix: route the main-screen-loaded event through the service so it
  /// honours opt-out (was a raw `Posthog().capture()` privacy bug).
  Future<void> trackAppMainScreenLoaded([Map<String, dynamic>? additionalProperties]) async {
    await trackEvent('app_main_screen_loaded', additionalProperties);
  }

  Future<void> trackQuestionResultsViewed(String questionType) async {
    if (_isOptedOut || !_isInitialized) return;

    await trackEvent('question_results_viewed', {
      'question_type': questionType,
    });
  }

  // Guide tracking
  Future<void> trackGuideOpened(String source, [Map<String, dynamic>? additionalProperties]) async {
    if (_isOptedOut || !_isInitialized) return;
    
    final properties = {
      'source': source,
      ...?additionalProperties,
    };
    
    await trackEvent('guide_opened', properties);
  }

  Future<void> trackGuideClosed(Duration timeSpent, [Map<String, dynamic>? additionalProperties]) async {
    if (_isOptedOut || !_isInitialized) return;
    
    final properties = {
      'time_spent_seconds': timeSpent.inSeconds,
      ...?additionalProperties,
    };
    
    await trackEvent('guide_closed', properties);
  }

  // Notification tracking
  //
  // `trackNotificationPermissionRequested` / `...Granted` were deleted (review
  // 2026-09-22 §4.3): no call site has ever existed, at any version. The live
  // pair is `notification_prompt_shown` / `notification_prompt_result`, which
  // carry a `source`.
  Future<void> trackQotdNotificationPermissionRequested() async {
    await trackEvent('qotd_notification_permission_requested');
  }

  Future<void> trackQotdNotificationPermissionResult(bool granted) async {
    await trackEvent('qotd_notification_permission_result', {'granted': granted});
  }

  Future<void> trackQuestionSubscriptionNotificationEnabled(bool enabled) async {
    await trackEvent('question_subscription_notification_enabled', {'enabled': enabled});
  }

  /// The SharedPreferences key the FCM background isolate writes push
  /// receipts to. Public so `main.dart`'s top-level stash helper and this
  /// drain agree on one name.
  static const String pendingPushReceiptsKey = 'pending_push_receipts';

  /// At most this many receipts are kept. A device that was offline for a week
  /// should report the last few Drops, not replay a month of them.
  static const int maxPendingPushReceipts = 20;

  /// Turns the stashed background receipts into `notification_received`
  /// events (review 2026-09-22 A1).
  ///
  /// WHY A STASH. `notification_opened` has no denominator: today a Drop that
  /// was delivered and ignored is indistinguishable from a Drop that never
  /// arrived, which is exactly the live production question
  /// (drop-push-review-2026-09-22 §3, causes C1/C2/C3). But the FCM background
  /// isolate has its own memory and never runs `initialize()`, so it cannot
  /// call PostHog. It writes a small JSON list instead, and this drains it on
  /// the next foreground launch.
  ///
  /// WHAT IS STASHED. Never a `questionId` and never a `historyId`: a per-day
  /// `drop_date` is enough to join a receipt to the day's Drop and carries no
  /// per-person link. Emitted with [trackEventAnonymous] — a push receipt is
  /// not something the user chose to do, so it must not mint a person profile.
  ///
  /// It also writes the same `notification_received_qotd` prefs stamp the
  /// foreground path writes, so `notification_response_time` finally works for
  /// background receipts — which is how every real Drop arrives.
  Future<void> drainPendingPushReceipts() async {
    if (_isOptedOut || !_isInitialized) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getString(pendingPushReceiptsKey);
      if (stored == null || stored.isEmpty) return;
      // Cleared first: a crash mid-drain must not replay the same receipts on
      // every launch forever.
      await prefs.remove(pendingPushReceiptsKey);

      final decoded = json.decode(stored);
      if (decoded is! List) return;

      for (final event in buildPushReceiptEvents(decoded, DateTime.now())) {
        await trackEventAnonymous(event.name, event.properties);
      }
      final newest = newestPushReceipt(decoded);

      // The response-time stamp the foreground path keeps. The newest receipt
      // is the one a tap in this session would belong to.
      if (newest != null) {
        await prefs.setString(
            'notification_received_qotd', newest.toIso8601String());
      }
    } catch (e) {
      debugPrint('Failed to drain pending push receipts: $e');
    }
  }

  Future<void> trackNotificationReceived(String notificationType, [Map<String, dynamic>? additionalProperties]) async {
    final properties = {
      'notification_type': notificationType,
      ...?additionalProperties,
    };
    
    await trackEvent('notification_received', properties);
    
    // Store notification received timestamp for effectiveness tracking
    try {
      final prefs = await SharedPreferences.getInstance();
      final receivedKey = 'notification_received_$notificationType';
      await prefs.setString(receivedKey, DateTime.now().toIso8601String());
    } catch (e) {
      debugPrint('Failed to store notification received timestamp: $e');
    }
  }

  Future<void> trackNotificationOpened(String notificationType, [Map<String, dynamic>? additionalProperties]) async {
    final properties = {
      'notification_type': notificationType,
      ...?additionalProperties,
    };
    
    await trackEvent('notification_opened', properties);
    
    // Track notification effectiveness
    await _trackNotificationEffectiveness(notificationType, additionalProperties);
  }
  
  // Phase 5: Notification effectiveness tracking
  Future<void> _trackNotificationEffectiveness(String notificationType, Map<String, dynamic>? additionalProperties) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final now = DateTime.now();
      
      // Track time between notification received and opened
      final receivedKey = 'notification_received_$notificationType';
      final receivedTimeString = prefs.getString(receivedKey);
      
      if (receivedTimeString != null) {
        final receivedTime = DateTime.parse(receivedTimeString);
        final timeDifference = now.difference(receivedTime);
        
        await trackEvent('notification_response_time', {
          'notification_type': notificationType,
          'response_time_seconds': timeDifference.inSeconds,
          'response_time_minutes': timeDifference.inMinutes,
          'response_time_hours': timeDifference.inHours,
          'received_at': receivedTimeString,
          'opened_at': now.toIso8601String(),
          ...?additionalProperties,
        });
        
        // Clear the received timestamp
        await prefs.remove(receivedKey);
      }
      
      // PostHog automatically tracks daily patterns, so we just track the effectiveness
      
    } catch (e) {
      debugPrint('Failed to track notification effectiveness: $e');
    }
  }

  Future<void> trackQotdSubscribed(bool subscribed) async {
    await trackEvent('qotd_subscription_changed', {'subscribed': subscribed});
    await setUserProperties({'qotd_subscribed': subscribed});
  }

  Future<void> trackQotdClicked(String questionId, [Map<String, dynamic>? additionalProperties]) async {
    if (_isOptedOut || !_isInitialized) return;
    
    final properties = {
      'question_id': questionId,
      'source': 'homepage',
      ...?additionalProperties,
    };
    
    await trackEvent('qotd_clicked', properties);
  }

  // Location tracking
  Future<void> trackLocationChanged(String locationType, String locationValue, [Map<String, dynamic>? additionalProperties]) async {
    final properties = {
      'location_type': locationType,
      'location_value': locationValue,
      ...?additionalProperties,
    };
    
    await trackEvent('location_changed', properties);
    // The person-property mirror is gone (review 2026-09-19 P0-2 / 09-22
    // §4.4): a stored "this person currently lives in <place>" is personal in
    // a way the aggregate event is not, and the consent slide promises no
    // names. The event property stays — it is feature data, and the location
    // breakdown is a per-event question, not a per-person one.
  }

  // App lifecycle - typically tracked anonymously for cost optimization
  Future<void> trackAppOpened([Map<String, dynamic>? additionalProperties, bool processPersonProfile = false]) async {
    await trackEvent('app_opened', additionalProperties, processPersonProfile);
    
    // Track session metrics for retention analysis
    await _trackSessionMetrics();
  }
  
  // Phase 5: Session and retention tracking
  Future<void> _trackSessionMetrics() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final now = DateTime.now();
      
      // Track returning user patterns
      final firstOpenDate = prefs.getString('first_app_open');
      if (firstOpenDate == null) {
        // First time user
        await prefs.setString('first_app_open', now.toIso8601String());
        await trackEvent('user_first_open', {
          'first_open_date': now.toIso8601String(),
        });
      } else {
        // Returning user - calculate retention metrics
        final firstOpen = DateTime.parse(firstOpenDate);
        final daysSinceFirst = now.difference(firstOpen).inDays;
        
        await trackEvent('user_return', {
          'days_since_first_open': daysSinceFirst,
          'first_open_date': firstOpenDate,
          'return_date': now.toIso8601String(),
        });
        
        // `retention_day_1` / `_7` / `_28` were deleted (review 2026-09-22
        // §4.3). They fired only when `daysSinceFirst` was EXACTLY 1, 7 or 28,
        // so a user who opened the app on day 2 and day 9 counted as retained
        // on neither — they undercounted by construction. PostHog's native
        // retention insight over `app_opened` is correct and needs no code.
      }
      
      // Update user properties with session info
      await setUserProperties({
        'last_session_start': now.toIso8601String(),
        'total_days_since_first_open': firstOpenDate != null ? now.difference(DateTime.parse(firstOpenDate)).inDays : 0,
      });
      
    } catch (e) {
      debugPrint('Failed to track session metrics: $e');
    }
  }

  Future<void> trackAppBackgrounded([bool processPersonProfile = false]) async {
    await trackEvent('app_backgrounded', null, processPersonProfile);
  }

  Future<void> trackAppResumed([bool processPersonProfile = false]) async {
    await trackEvent('app_resumed', null, processPersonProfile);
  }

  // Session management
  /// Step 3 of the identity model: sign-out mints a fresh anonymous id, so a
  /// second account on the same device is a second person — deliberately, so
  /// one person's answers are never attributed to another's.
  Future<void> reset() async {
    if (!_isInitialized) return;

    try {
      await Posthog().reset();
      _currentUserId = null;
      _deviceId = null;
      // `reset()` clears registered super properties too, so the whole default
      // set has to be re-registered or every post-sign-out event loses its
      // app_version / platform / guest split.
      await _setDefaultSuperProperties();
    } catch (e) {
      debugPrint('Failed to reset analytics: $e');
    }
  }

  // Opt-out management
  Future<void> setOptOut(bool optOut) async {
    _isOptedOut = optOut;
    
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_analyticsOptOutKey, optOut);
    
    if (optOut && _isInitialized) {
      await Posthog().disable();
    } else if (!optOut && _isInitialized) {
      await Posthog().enable();
    }
  }

  Future<bool> isOptedOut() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_analyticsOptOutKey) ?? false;
  }

  // Feature flags (if using PostHog feature flags)
  Future<bool> isFeatureEnabled(String featureKey) async {
    if (_isOptedOut || !_isInitialized) return false;
    
    try {
      return await Posthog().isFeatureEnabled(featureKey) ?? false;
    } catch (e) {
      debugPrint('Failed to check feature flag $featureKey: $e');
      return false;
    }
  }

  Future<dynamic> getFeatureFlagPayload(String featureKey) async {
    if (_isOptedOut || !_isInitialized) return null;
    
    try {
      return await Posthog().getFeatureFlagPayload(featureKey);
    } catch (e) {
      debugPrint('Failed to get feature flag payload $featureKey: $e');
      return null;
    }
  }

  // Flush events immediately (useful for critical events)
  Future<void> flush() async {
    if (_isOptedOut || !_isInitialized) return;
    
    try {
      await Posthog().flush();
    } catch (e) {
      debugPrint('Failed to flush analytics: $e');
    }
  }
  
  // Get the current user's distinct ID
  Future<String?> getDistinctId() async {
    if (_isOptedOut || !_isInitialized) return null;
    
    try {
      return await Posthog().getDistinctId();
    } catch (e) {
      debugPrint('Failed to get distinct ID: $e');
      return null;
    }
  }
  
  // Phase 5: Feature adoption tracking
  Future<void> trackFeatureAdoption(String featureName, [Map<String, dynamic>? additionalProperties]) async {
    if (_isOptedOut || !_isInitialized) return;
    
    try {
      final prefs = await SharedPreferences.getInstance();
      final featureKey = 'feature_first_use_$featureName';
      final hasUsedBefore = prefs.getBool(featureKey) ?? false;
      
      if (!hasUsedBefore) {
        // This is the first time using this feature
        await prefs.setBool(featureKey, true);
        
        // Track first use event
        await trackEvent('feature_first_use', {
          'feature_name': featureName,
          'first_use_date': DateTime.now().toIso8601String(),
          ...?additionalProperties,
        });
        
        // Track feature adoption milestone
        await _trackFeatureAdoptionMilestone(featureName);
      }
      
      // Always track feature usage
      await trackEvent('feature_used', {
        'feature_name': featureName,
        'is_first_use': !hasUsedBefore,
        ...?additionalProperties,
      });
      
    } catch (e) {
      debugPrint('Failed to track feature adoption: $e');
    }
  }
  
  Future<void> _trackFeatureAdoptionMilestone(String featureName) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      
      // Get list of features user has adopted
      final adoptedFeaturesString = prefs.getString('adopted_features');
      List<String> adoptedFeatures = [];
      if (adoptedFeaturesString != null) {
        adoptedFeatures = List<String>.from(json.decode(adoptedFeaturesString));
      }
      
      if (!adoptedFeatures.contains(featureName)) {
        adoptedFeatures.add(featureName);
        await prefs.setString('adopted_features', json.encode(adoptedFeatures));
        
        // Track adoption milestone
        await trackEvent('feature_adoption_milestone', {
          'feature_name': featureName,
          'total_features_adopted': adoptedFeatures.length,
          'adopted_features': adoptedFeatures,
        });
        
        // Update user properties
        await setUserProperties({
          'total_features_adopted': adoptedFeatures.length,
          'adopted_features': adoptedFeatures,
        });
      }
      
    } catch (e) {
      debugPrint('Failed to track feature adoption milestone: $e');
    }
  }
  
  // Convenience methods for specific features
  Future<void> trackLocationChangeAdoption([Map<String, dynamic>? properties]) async {
    await trackFeatureAdoption('location_change', properties);
  }
  
  Future<void> trackPrivateQuestionAdoption([Map<String, dynamic>? properties]) async {
    await trackFeatureAdoption('private_question', properties);
  }
  
  Future<void> trackCategoryFilterAdoption([Map<String, dynamic>? properties]) async {
    await trackFeatureAdoption('category_filter', properties);
  }
  
  Future<void> trackFeedSwitchAdoption([Map<String, dynamic>? properties]) async {
    await trackFeatureAdoption('feed_switch', properties);
  }
  
  Future<void> trackQuestionTypeAdoption(String questionType, [Map<String, dynamic>? properties]) async {
    await trackFeatureAdoption('question_type_$questionType', {
      'question_type': questionType,
      ...?properties,
    });
  }

  // Widget uptake tracking
  Future<void> trackWidgetUpdated(String widgetType, [Map<String, dynamic>? additionalProperties]) async {
    if (_isOptedOut || !_isInitialized) return;

    await trackEvent('widget_updated', {
      'widget_type': widgetType,
      ...?additionalProperties,
    });

    // Track as feature adoption (first use tracking)
    await trackFeatureAdoption('widget_$widgetType');

    // Set user property so we can filter/breakdown by active widgets
    await _updateActiveWidgets(widgetType);
  }

  Future<void> _updateActiveWidgets(String widgetType) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final activeWidgetsString = prefs.getString('active_widgets');
      List<String> activeWidgets = [];
      if (activeWidgetsString != null) {
        activeWidgets = List<String>.from(json.decode(activeWidgetsString));
      }

      if (!activeWidgets.contains(widgetType)) {
        activeWidgets.add(widgetType);
        await prefs.setString('active_widgets', json.encode(activeWidgets));
      }

      await setUserProperties({
        'active_widgets': activeWidgets,
        'has_streak_widget': activeWidgets.contains('streak'),
        'has_qotd_widget': activeWidgets.contains('qotd'),
      });
    } catch (e) {
      debugPrint('Failed to update active widgets: $e');
    }
  }

  // Theme mode tracking
  Future<void> trackThemeModeChanged(String themeMode) async {
    if (_isOptedOut || !_isInitialized) return;

    await trackEvent('theme_mode_changed', {
      'theme_mode': themeMode,
    });

    await setUserProperties({
      'theme_mode': themeMode,
    });
  }
  
  // Enable analytics after opt-in
  Future<void> enable() async {
    try {
      await Posthog().enable();
      _isOptedOut = false;
    } catch (e) {
      debugPrint('Failed to enable analytics: $e');
    }
  }
  
  // Disable analytics for privacy
  Future<void> disable() async {
    try {
      await Posthog().disable();
      _isOptedOut = true;
    } catch (e) {
      debugPrint('Failed to disable analytics: $e');
    }
  }
}