// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The one decision that decides whether an answer is linked or filed the old
// way: is this error PostgREST telling us the function is not there?
//
// It matters in both directions, and both are easy to get wrong:
//
//   * Too eager, and a rate-limited or refused answer falls through to the
//     direct insert — routing straight around the server's own no, which is
//     exactly the hole `submit_response` was written to close.
//   * Too shy, and every answer fails on a project where the SQL has not been
//     pasted yet, which is every project the day before the deploy.
//
// The same predicate gates the read path: the first PGRST202 stops the network
// RPCs going out at all for the session.

import 'package:flutter_test/flutter_test.dart';
import 'package:read_the_room/src/services/network_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  group('the RPC is not deployed — fall back', () {
    test('PGRST202, the documented code', () {
      expect(
        isMissingRpc(PostgrestException(
          message:
              'Could not find the function public.submit_response(...) in the schema cache',
          code: 'PGRST202',
        )),
        isTrue,
      );
    });

    test('42883, what Postgres itself calls it', () {
      expect(
        isMissingRpc(PostgrestException(
          message: 'function public.get_network_results(uuid) does not exist',
          code: '42883',
        )),
        isTrue,
      );
    });

    test('the wording alone, for a PostgREST that sent no code', () {
      expect(
        isMissingRpc(const PostgrestException(
            message: 'Could not find the function public.set_answer_sharing')),
        isTrue,
      );
    });
  });

  group('the RPC answered — do NOT fall back', () {
    test('a rate limit is a real refusal', () {
      expect(
        isMissingRpc(const PostgrestException(
            message: 'rate limited', code: 'PGRST301')),
        isFalse,
      );
    });

    test('a permission error is a real refusal', () {
      expect(
        isMissingRpc(const PostgrestException(
            message: 'permission denied for function submit_response',
            code: '42501')),
        isFalse,
      );
    });

    test('a schema-cache reload is not a missing function', () {
      expect(
        isMissingRpc(const PostgrestException(
            message: 'JWT expired', code: 'PGRST303')),
        isFalse,
      );
    });

    test('a missing COLUMN says "does not exist" too, and is a real error', () {
      expect(
        isMissingRpc(const PostgrestException(
            message: 'column responses.shared_with_close_friends does not exist',
            code: '42703')),
        isFalse,
      );
    });

    test('anything that is not a Postgrest error is not a missing function', () {
      expect(isMissingRpc(Exception('SocketException: connection refused')),
          isFalse);
      expect(isMissingRpc(StateError('no client')), isFalse);
    });
  });

  group('the service degrades rather than throwing', () {
    // No Supabase is initialised in a unit test, so every call here takes the
    // "no client" path — which is the same path a guest and a dropped
    // connection take, and it must produce a renderable result, not an
    // exception.
    final service = NetworkService();

    test('results come back unavailable, never null', () async {
      final r = await service.getNetworkResults('q1', questionType: 'text');
      expect(r.available, isFalse);
      expect(r.gated, isTrue);
      expect(r.hasGraph, isFalse);
      expect(r.networkAnswered, isNull);
    });

    test('an empty question id short-circuits', () async {
      final r = await service.getNetworkResults('');
      expect(r.available, isFalse);
      expect(await service.getCloseFriendAnswers(''), isEmpty);
      expect(await service.setAnswerSharing('', true), isFalse);
    });

    test('close friend answers come back empty', () async {
      expect(await service.getCloseFriendAnswers('q1'), isEmpty);
    });

    test('an empty batch is a success with nothing in it', () async {
      final counts = await service.getNetworkAnsweredCounts(<String>[]);
      expect(counts.available, isTrue);
      expect(counts.respondentsFor('q1'), 0);
    });

    test('a batch with no client is unknown, not zero', () async {
      final counts = await service.getNetworkAnsweredCounts(<String>['q1']);
      expect(counts.available, isFalse);
      expect(counts.respondentsFor('q1'), isNull);
    });
  });
}
