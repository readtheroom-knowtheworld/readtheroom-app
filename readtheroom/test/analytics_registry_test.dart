// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The registry is the contract; this file enforces it.
//
// `analytics_events_test.dart` covers the onboarding funnel and the individual
// helper shapes. This file does the three things that only a whole-tree scan
// can do:
//
//   1. every event name emitted anywhere under `lib/` is declared in
//      `kAnalyticsEventRegistry`, and every declared name is actually emitted
//      (a catalogue with ghosts in it is worse than no catalogue);
//   2. every property key written at a call site is declared for that event,
//      and no event anywhere carries a key from `kForbiddenPropertyKeys`;
//   3. the privacy rule — no event in `kIdentifiedAnswerEvents` may declare or
//      emit `question_id`, on the helper or at any call site.
//
// Plus unit tests for the four pure cores added by the 2026-09-22 review: the
// identity chain, the error-type / RPC-reason extraction, the push-receipt
// stash and drain, and the demo-mode kill switch.
//
// Review: feature-documentation/posthog-events-review-2026-09-22.md

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:read_the_room/src/services/analytics_event_registry.dart';
import 'package:read_the_room/src/services/analytics_service.dart';

/// One `trackEvent` / `trackEventAnonymous` call site found in the source.
class _CallSite {
  _CallSite(this.event, this.keys, this.file);
  final String event;
  final Set<String> keys;
  final String file;
}

/// Scans `lib/` for literal `trackEvent('name', {...})` call sites and pulls
/// out the event name and the property keys written at that site.
///
/// Reading the tree rather than restating a list is the point: a property
/// slipped onto an event in a widget fails here, not in a PostHog breakdown
/// three weeks later.
List<_CallSite> _scanCallSites() {
  final call = RegExp(r"""trackEvent(?:Anonymous)?\(\s*'([a-z0-9_]+)'""");
  final key = RegExp(r"""'([a-z0-9_$]+)'\s*:""");
  final sites = <_CallSite>[];

  for (final entity in Directory('lib').listSync(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('.dart')) continue;
    final source = entity.readAsStringSync();
    for (final match in call.allMatches(source)) {
      final name = match.group(1)!;
      // Balance parentheses from the call's opening one so a nested map or a
      // conditional expression is included and the next call is not.
      final start = source.indexOf('(', match.start);
      var depth = 0;
      var i = start;
      while (i < source.length) {
        if (source[i] == '(') depth++;
        if (source[i] == ')') {
          depth--;
          if (depth == 0) break;
        }
        i++;
      }
      final body = source.substring(start, i);
      final keys = key.allMatches(body).map((m) => m.group(1)!).toSet()
        ..remove(name);
      sites.add(_CallSite(name, keys, entity.path));
    }
  }
  return sites;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final sites = _scanCallSites();

  // ------------------------------------------------------- name coverage
  group('Every event name is in the registry', () {
    test('the scan found call sites at all', () {
      expect(sites, isNotEmpty,
          reason: 'the scanner matched nothing — has trackEvent been renamed?');
    });

    test('no call site emits an undeclared event name', () {
      final undeclared = <String>{};
      for (final site in sites) {
        if (!kAnalyticsEventRegistry.containsKey(site.event)) {
          undeclared.add('${site.event} (${site.file})');
        }
      }
      expect(undeclared, isEmpty,
          reason: 'declare these in analytics_event_registry.dart');
    });

    test('service helpers emit only declared names', () {
      // The helper-built events never appear as a literal at a call site, so
      // they are listed here and must also be in the registry.
      const helperEvents = <String>[
        'question_viewed',
        'question_answer_started',
        'question_answered',
        'question_answer_abandoned',
        'question_rated',
        'answer_submit_failed',
        'review_tags_submitted',
        'review_tags_skipped',
        'deeplink_opened',
        'notification_received',
        'notification_opened',
        'notification_response_time',
        'onboarding_step',
        'rpc_failed',
        'app_error',
        'push_topic_subscription',
        'submit_response_fallback_used',
      ];
      for (final name in helperEvents) {
        expect(kAnalyticsEventRegistry.containsKey(name), isTrue,
            reason: '$name is emitted by a helper but not declared');
      }
    });

    test('the registry has no ghosts', () {
      // Every declared name must be reachable: either a literal call site or a
      // helper. A catalogue that lists events the app cannot emit sends the
      // owner looking for data that will never arrive.
      final emitted = sites.map((s) => s.event).toSet();
      const viaHelper = <String>{
        'question_viewed',
        'question_answer_started',
        'question_answered',
        'question_answer_abandoned',
        'question_rated',
        'answer_submit_failed',
        'review_tags_submitted',
        'review_tags_skipped',
        'deeplink_opened',
        'notification_received',
        'notification_opened',
        'notification_response_time',
        'onboarding_step',
        'rpc_failed',
        'app_error',
        'push_topic_subscription',
        'submit_response_fallback_used',
        'guide_opened',
        'guide_closed',
      };
      final ghosts = kAnalyticsEventRegistry.keys
          .where((name) => !emitted.contains(name) && !viaHelper.contains(name))
          .toList();
      expect(ghosts, isEmpty,
          reason: 'declared but never emitted — delete or wire up');
    });
  });

  // --------------------------------------------------- property coverage
  group('Every property key is declared', () {
    test('no call site writes an undeclared key', () {
      final problems = <String>[];
      for (final site in sites) {
        final schema = kAnalyticsEventRegistry[site.event];
        if (schema == null) continue; // covered by the name test
        for (final k in site.keys) {
          if (k.startsWith(r'$')) continue; // PostHog's own control keys
          // A ternary value such as `'ok' : 'failed'` looks like a key to a
          // regex; skip anything the schema does not know that is also not a
          // plausible snake_case property.
          if (!schema.properties.contains(k) &&
              !kForbiddenPropertyKeys.contains(k) &&
              k.contains('_')) {
            problems.add('${site.event}.$k (${site.file})');
          }
        }
      }
      expect(problems, isEmpty,
          reason: 'add to the schema in analytics_event_registry.dart, or '
              'stop sending it');
    });

    test('no event declares a forbidden property key', () {
      final leaks = <String>[];
      kAnalyticsEventRegistry.forEach((name, schema) {
        for (final k in schema.properties) {
          // `location_changed.location_value` is the one deliberate exception
          // and is documented as such; it is feature data on an aggregate
          // event and is no longer mirrored to a person.
          if (name == 'location_changed') continue;
          if (kForbiddenPropertyKeys.contains(k)) leaks.add('$name.$k');
        }
      });
      expect(leaks, isEmpty);
    });

    test('no call site writes a forbidden key', () {
      final leaks = <String>[];
      for (final site in sites) {
        if (site.event == 'location_changed') continue;
        for (final k in site.keys) {
          if (kForbiddenPropertyKeys.contains(k)) {
            leaks.add('${site.event}.$k (${site.file})');
          }
        }
      }
      expect(leaks, isEmpty,
          reason: 'user content or an identifier must never reach PostHog');
    });

    test('person properties never include an email or a device id', () {
      expect(kPersonProperties, isNot(contains('email')));
      expect(kPersonProperties, isNot(contains('device_id')));
    });
  });

  // ------------------------------------------------------- the P0-1 rule
  group('No question_id on an identified answer event', () {
    test('the registry declares none of them with a question_id', () {
      for (final name in kIdentifiedAnswerEvents) {
        final schema = kAnalyticsEventRegistry[name];
        expect(schema, isNotNull, reason: '$name is not declared');
        expect(schema!.properties, isNot(contains('question_id')),
            reason: '$name must not carry a question id (P0-1)');
      }
    });

    test('no call site passes one either', () {
      for (final site in sites) {
        if (!kIdentifiedAnswerEvents.contains(site.event)) continue;
        expect(site.keys, isNot(contains('question_id')),
            reason: '${site.event} in ${site.file}');
      }
    });

    test('the helpers emit none of them with a question_id', () async {
      SharedPreferences.setMockInitialValues({});
      final analytics = AnalyticsService();
      analytics.debugConfigure(optedOut: false, initialized: true);
      final sink = <AnalyticsEventSpec>[];
      analytics.debugEventSink = sink;
      analytics.demoModeGate = () => false;

      await analytics.trackQuestionAnswerStarted('text', source: 'feed');
      await analytics.trackQuestionAnswered('text', 'text', source: 'feed');
      await analytics.trackQuestionAnswerAbandoned('text', 3, source: 'feed');
      await analytics.trackQuestionRated('negative');
      await analytics.trackAnswerSubmitFailed('text', source: 'feed');

      expect(sink.map((e) => e.name).toSet(), kIdentifiedAnswerEvents);
      for (final event in sink) {
        expect(event.properties.containsKey('question_id'), isFalse,
            reason: event.name);
        // And the emitted keys are all declared.
        final schema = kAnalyticsEventRegistry[event.name]!;
        for (final k in event.properties.keys) {
          expect(schema.properties, contains(k), reason: '${event.name}.$k');
        }
      }
      analytics.debugReset();
    });
  });

  // ------------------------------------------------------ identity chain
  group('The identity chain (P0-5)', () {
    test('an empty user id does nothing at all', () {
      // The old code fell through to `identify('')`, minting a junk person
      // keyed on the empty string.
      expect(identifyUserSteps(currentUserId: null, userId: ''), isEmpty);
      expect(identifyUserSteps(currentUserId: 'u1', userId: ''), isEmpty);
    });

    test('a guest signing in aliases BEFORE identifying', () {
      final steps = identifyUserSteps(currentUserId: null, userId: 'u1');
      expect(steps, [
        IdentityStep.alias,
        IdentityStep.identify,
        IdentityStep.registerAuthenticated,
      ]);
      // The whole bug in one assertion: alias must precede identify, or the
      // distinct id is already the account id and the alias is a no-op.
      expect(steps.indexOf(IdentityStep.alias),
          lessThan(steps.indexOf(IdentityStep.identify)));
    });

    test('re-identifying the same user does not alias an id to itself', () {
      expect(identifyUserSteps(currentUserId: 'u1', userId: 'u1'),
          isNot(contains(IdentityStep.alias)));
    });

    test('switching accounts aliases again', () {
      expect(identifyUserSteps(currentUserId: 'u1', userId: 'u2').first,
          IdentityStep.alias);
    });

    test('is_authenticated is re-registered on every identify', () {
      for (final current in <String?>[null, 'u1', 'u2']) {
        expect(identifyUserSteps(currentUserId: current, userId: 'u1'),
            contains(IdentityStep.registerAuthenticated));
      }
    });
  });

  // ------------------------------------------------ error-code extraction
  group('Failure events carry codes, never messages', () {
    test('a PostgREST-shaped error yields its code', () {
      expect(analyticsRpcReason(_FakePostgrest('PGRST202')), 'PGRST202');
      expect(analyticsRpcReason(_FakePostgrest('42501')), '42501');
    });

    test('an untyped error is just `exception`', () {
      expect(analyticsRpcReason(Exception('boom')), 'exception');
      expect(analyticsRpcReason('a string'), 'exception');
      expect(analyticsRpcReason(null), 'exception');
    });

    test('a suspiciously long "code" is rejected, not forwarded', () {
      // A message masquerading as a code must not get through.
      expect(
        analyticsRpcReason(
            _FakePostgrest('duplicate key value violates unique constraint '
                'responses_pkey on question "what do you think of ..."')),
        'exception',
      );
    });

    test('an empty code falls back rather than sending an empty string', () {
      expect(analyticsRpcReason(_FakePostgrest('')), 'exception');
    });

    test('error_type is a type name and nothing else', () {
      expect(analyticsErrorType(StateError('a secret message')), 'StateError');
      expect(analyticsErrorType(ArgumentError('another')), 'ArgumentError');
      expect(analyticsErrorType(null), 'unknown');
      // The assertion that matters: the message must not survive.
      expect(analyticsErrorType(StateError('a secret message')),
          isNot(contains('secret')));
    });
  });

  // ------------------------------------------- the push-receipt stash/drain
  group('Background push receipts (A1)', () {
    final published = DateTime.utc(2026, 9, 22, 18, 30);
    final received = DateTime.utc(2026, 9, 22, 18, 30, 12);

    test('a receipt carries a drop date, never a question or history id', () {
      final entry = buildPushReceiptEntry(
        kind: 'drop',
        isDrop: true,
        receivedAt: received,
        publishedAt: published,
      );
      expect(entry['drop_date'], '2026-09-22');
      expect(entry.containsKey('questionId'), isFalse);
      expect(entry.containsKey('question_id'), isFalse);
      expect(entry.containsKey('historyId'), isFalse);
      expect(entry.containsKey('history_id'), isFalse);
    });

    test('a legacy push with no publish time still stashes', () {
      final entry = buildPushReceiptEntry(
        kind: 'legacy',
        isDrop: false,
        receivedAt: received,
      );
      expect(entry['drop_date'], isNull);
      expect(entry['kind'], 'legacy');
      expect(entry['is_drop'], isFalse);
    });

    test('the stash is capped, keeping the most recent', () {
      var stash = <dynamic>[];
      for (var i = 0; i < 25; i++) {
        stash = appendPushReceipt(
          stash,
          buildPushReceiptEntry(
            kind: 'drop',
            isDrop: true,
            receivedAt: received.add(Duration(days: i)),
            publishedAt: published.add(Duration(days: i)),
          ),
          cap: 20,
        );
      }
      expect(stash.length, 20);
      // The first five are the ones dropped.
      expect((stash.first as Map)['drop_date'], '2026-09-27');
      expect((stash.last as Map)['drop_date'], '2026-10-16');
    });

    test('draining turns each receipt into one anonymous event', () {
      final stash = <dynamic>[
        buildPushReceiptEntry(
          kind: 'drop',
          isDrop: true,
          receivedAt: received,
          publishedAt: published,
        ),
        buildPushReceiptEntry(
          kind: 'legacy',
          isDrop: false,
          receivedAt: received.add(const Duration(days: 1)),
        ),
      ];
      final events =
          buildPushReceiptEvents(stash, received.add(const Duration(minutes: 5)));

      expect(events.length, 2);
      expect(events.every((e) => e.name == 'notification_received'), isTrue);
      expect(events[0].properties['delivery_context'], 'background');
      expect(events[0].properties['push_kind'], 'drop');
      expect(events[0].properties['is_drop'], isTrue);
      expect(events[0].properties['drop_date'], '2026-09-22');
      expect(events[0].properties['seconds_to_report'], 300);
      expect(events[1].properties['is_drop'], isFalse);
      expect(events[1].properties.containsKey('drop_date'), isFalse);

      // The declared shape holds.
      final schema = kAnalyticsEventRegistry['notification_received']!;
      for (final event in events) {
        for (final k in event.properties.keys) {
          expect(schema.properties, contains(k));
        }
      }
    });

    test('a corrupt stash costs the launch nothing', () {
      final events = buildPushReceiptEvents(
        <dynamic>['not a map', 42, null, {'kind': 'drop'}],
        received,
      );
      // Only the one map survives, and it does not need a received_at.
      expect(events.length, 1);
      expect(events.single.properties.containsKey('seconds_to_report'), isFalse);
    });

    test('the newest receipt is the response-time stamp', () {
      final stash = <dynamic>[
        buildPushReceiptEntry(
            kind: 'drop', isDrop: true, receivedAt: received),
        buildPushReceiptEntry(
            kind: 'drop',
            isDrop: true,
            receivedAt: received.add(const Duration(hours: 3))),
        buildPushReceiptEntry(
            kind: 'drop',
            isDrop: true,
            receivedAt: received.subtract(const Duration(hours: 9))),
      ];
      expect(newestPushReceipt(stash),
          received.add(const Duration(hours: 3)));
      expect(newestPushReceipt(<dynamic>[]), isNull);
    });

    test('drain empties the stash and reports it', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final analytics = AnalyticsService();
      analytics.debugConfigure(optedOut: false, initialized: true);
      analytics.demoModeGate = () => false;
      final sink = <AnalyticsEventSpec>[];
      analytics.debugEventSink = sink;

      final prefs = await SharedPreferences.getInstance();
      final stash = appendPushReceipt(
        <dynamic>[],
        buildPushReceiptEntry(
          kind: 'drop',
          isDrop: true,
          receivedAt: DateTime.now().toUtc(),
          publishedAt: DateTime.now().toUtc(),
        ),
      );
      await prefs.setString(AnalyticsService.pendingPushReceiptsKey,
          _encode(stash));

      await analytics.drainPendingPushReceipts();

      expect(sink.map((e) => e.name), ['notification_received']);
      // Cleared, so a second launch does not replay it.
      expect(prefs.getString(AnalyticsService.pendingPushReceiptsKey), isNull);
      // And the response-time stamp is written for the tap that may follow.
      expect(prefs.getString('notification_received_qotd'), isNotNull);

      sink.clear();
      await analytics.drainPendingPushReceipts();
      expect(sink, isEmpty);
      analytics.debugReset();
    });
  });

  // ---------------------------------------------------- demo-mode killswitch
  group('Demo data never reaches PostHog', () {
    late AnalyticsService analytics;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      analytics = AnalyticsService();
      analytics.debugConfigure(optedOut: false, initialized: true);
    });
    tearDown(() => analytics.debugReset());

    test('with demo mode on, nothing is sent at all', () async {
      final sink = <AnalyticsEventSpec>[];
      analytics.debugEventSink = sink;
      analytics.demoModeGate = () => true;

      await analytics.trackEventAnonymous('network_card_shown', {
        'state': 'network',
        'respondents_bucket': '3-5',
        'surface': 'results',
      });
      await analytics.trackQuestionAnswered('text', 'text', source: 'feed');
      await analytics.trackRpcFailed('get_network_results');
      await analytics.trackAppError(errorType: 'StateError', fatal: false);

      expect(sink, isEmpty,
          reason: 'fabricated demo data must never mix into a real metric');
    });

    test('with demo mode off, the same calls go through', () async {
      final sink = <AnalyticsEventSpec>[];
      analytics.debugEventSink = sink;
      analytics.demoModeGate = () => false;

      await analytics.trackEventAnonymous('network_card_shown', {
        'state': 'network',
        'respondents_bucket': '3-5',
        'surface': 'results',
      });
      expect(sink.single.name, 'network_card_shown');
    });
  });

  // --------------------------------------------------- the new app-health
  group('App-health helpers emit their declared shape', () {
    late AnalyticsService analytics;
    late List<AnalyticsEventSpec> sink;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      analytics = AnalyticsService();
      analytics.debugConfigure(optedOut: false, initialized: true);
      analytics.demoModeGate = () => false;
      sink = <AnalyticsEventSpec>[];
      analytics.debugEventSink = sink;
    });
    tearDown(() => analytics.debugReset());

    test('app_error carries a type and a library, never a message', () async {
      await analytics.trackAppError(
          errorType: 'PostgrestException', library: 'widgets library',
          fatal: false);
      await analytics.trackAppError(errorType: 'StateError', fatal: true);

      expect(sink[0].properties, {
        'error_type': 'PostgrestException',
        'library': 'widgets library',
        'fatal': false,
      });
      expect(sink[1].properties, {'error_type': 'StateError', 'fatal': true});
    });

    test('push_topic_subscription reports both outcomes', () async {
      await analytics.trackPushTopicSubscription(
          topic: 'qotd', result: 'ok', trigger: 'launch');
      await analytics.trackPushTopicSubscription(
          topic: 'qotd', result: 'failed', trigger: 'settings');

      expect(sink.map((e) => e.name),
          ['push_topic_subscription', 'push_topic_subscription']);
      expect(sink[0].properties['result'], 'ok');
      expect(sink[1].properties['trigger'], 'settings');
      // Anonymous: it must not mint a person profile.
      expect(sink[0].properties[r'$process_person_profile'], isFalse);
    });

    test('submit_response_fallback_used fires once per session', () async {
      await analytics.trackSubmitResponseFallbackUsed('not_deployed');
      await analytics.trackSubmitResponseFallbackUsed('not_deployed');
      await analytics.trackSubmitResponseFallbackUsed('not_deployed');

      expect(sink.length, 1);
      expect(sink.single.properties, {'reason': 'not_deployed'});
    });

    test('a not-deployed RPC is reported once per action', () async {
      await analytics.trackRpcNotDeployedOnce('get_network_results');
      await analytics.trackRpcNotDeployedOnce('get_network_results');
      await analytics.trackRpcNotDeployedOnce('set_answer_sharing');

      expect(sink.length, 2);
      expect(sink.map((e) => e.properties['action']),
          ['get_network_results', 'set_answer_sharing']);
      expect(sink.every((e) => e.properties['reason'] == 'not_deployed'),
          isTrue);
    });

    test('answer_submit_failed carries no reason of its own', () async {
      // By design: the reason rides on the paired `rpc_failed`, so the error
      // vocabulary lives in exactly one place (review C2).
      await analytics.trackAnswerSubmitFailed('approval_rating', source: 'qotd');
      expect(sink.single.properties,
          {'question_type': 'approval_rating', 'source': 'qotd'});
    });

    test('opt-out suppresses every new event too', () async {
      analytics.debugConfigure(optedOut: true, initialized: true);

      await analytics.trackAppError(errorType: 'StateError', fatal: true);
      await analytics.trackPushTopicSubscription(
          topic: 'qotd', result: 'ok', trigger: 'launch');
      await analytics.trackSubmitResponseFallbackUsed('not_deployed');
      await analytics.trackRpcNotDeployedOnce('get_network_results');
      await analytics.trackAnswerSubmitFailed('text', source: 'feed');
      await analytics.drainPendingPushReceipts();

      expect(sink, isEmpty);
    });
  });

  // ---------------------------------------------------------- vocabularies
  group('Closed vocabularies', () {
    test('every kind the router emits is in kDeepLinkKinds', () {
      final source =
          File('lib/src/services/deep_link_service.dart').readAsStringSync();
      final emitted = RegExp(r"""trackDeepLinkOpened\(\s*'([a-z_]+)'""")
          .allMatches(source)
          .map((m) => m.group(1)!)
          .toSet();
      // The computed `kind` at the home/widget branch is a variable, so the
      // literals it can hold are read from the branch itself.
      final computed = RegExp(r"""src == '([a-z_]+)'""")
          .allMatches(source)
          .map((m) => m.group(1)!)
          .toSet();
      expect(emitted, isNotEmpty);
      expect(kDeepLinkKinds, containsAll(emitted));
      expect(kDeepLinkKinds, containsAll(computed),
          reason: 'a ?src= value the router accepts but nothing declares');
    });

    test('an off-vocabulary kind becomes unknown, not a new value', () async {
      SharedPreferences.setMockInitialValues({});
      final analytics = AnalyticsService();
      analytics.debugConfigure(optedOut: false, initialized: true);
      analytics.demoModeGate = () => false;
      final sink = <AnalyticsEventSpec>[];
      analytics.debugEventSink = sink;

      await analytics.trackDeepLinkOpened('qotd_push');
      await analytics.trackDeepLinkOpened('streak_widget');
      await analytics.trackDeepLinkOpened('something_new');

      expect(sink.map((e) => e.properties['kind']).toList(),
          ['qotd_push', 'streak_widget', 'unknown']);
      analytics.debugReset();
    });

    test('every qr_shown surface in lib/ is in kQrSurfaces', () {
      final emitted = <String>{};
      for (final entity in Directory('lib').listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        emitted.addAll(
          RegExp(r"""FriendQrDialog\.show\([^)]*surface:\s*'([a-z_]+)'""")
              .allMatches(entity.readAsStringSync())
              .map((m) => m.group(1)!),
        );
      }
      expect(emitted, isNotEmpty);
      expect(kQrSurfaces, containsAll(emitted));
    });

    test('no raw Posthog() call survives outside the service', () {
      // P0-3: a raw SDK call bypasses both the opt-out and the F-Droid consent
      // slide. This is the second time one has appeared, hence the test.
      final offenders = <String>[];
      for (final entity in Directory('lib').listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        if (entity.path.endsWith('analytics_service.dart')) continue;
        for (final line in entity.readAsLinesSync()) {
          final trimmed = line.trimLeft();
          if (trimmed.startsWith('//') || trimmed.startsWith('///')) continue;
          if (RegExp(r'\bPosthog\(\)').hasMatch(line)) {
            offenders.add('${entity.path}: ${line.trim()}');
          }
        }
      }
      expect(offenders, isEmpty,
          reason: 'route it through AnalyticsService so opt-out applies');
    });

    test('the PostHog key is never a committed Dart default', () {
      final source =
          File('lib/src/services/analytics_service.dart').readAsStringSync();
      expect(
        RegExp(r"""fromEnvironment\('POSTHOG_API_KEY'\s*,\s*defaultValue""")
            .hasMatch(source),
        isFalse,
        reason: 'a committed key is a key that cannot be rotated',
      );
      expect(source.contains('phc_'), isFalse,
          reason: 'a PostHog project key must never appear in source');
    });
  });
}

String _encode(List<dynamic> stash) =>
    '[${stash.map((e) => _encodeMap(e as Map)).join(',')}]';

String _encodeMap(Map<dynamic, dynamic> m) {
  final parts = <String>[];
  m.forEach((k, v) {
    final value = v == null
        ? 'null'
        : (v is bool || v is num ? '$v' : '"$v"');
    parts.add('"$k":$value');
  });
  return '{${parts.join(',')}}';
}

/// Stands in for a `PostgrestException` — `analyticsRpcReason` is duck-typed so
/// `analytics_service.dart` needs no Supabase import.
class _FakePostgrest {
  _FakePostgrest(this.code);
  final String code;
  // The message must never be read. If it ever is, this makes it obvious.
  String get message => 'user content: "what do you think of pineapple?"';
}
