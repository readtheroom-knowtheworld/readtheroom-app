// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The shaping of `find_passkey_user_for_device`.
//
// Small surface, but the whole sign-in path hangs on it: get the shape wrong
// and a returning user is offered a brand-new account, or a half-finished
// registration is treated as a real one. The RPC returns the device's BEST row
// — fully registered first, LIMIT 1 — so the `is_fully_registered` split that
// used to be two separate queries is now a client-side filter on one row, and
// it has to keep answering exactly what the old `.eq(...)` did, NULL included.
//
// Contract: scripts/passkey_lookup_01_rpc.sql

import 'package:flutter_test/flutter_test.dart';
import 'package:read_the_room/src/utils/passkey_device_lookup.dart';

/// One row exactly as PostgREST hands the RETURNS TABLE back.
Map<String, dynamic> row({
  String uuid = '11111111-2222-3333-4444-555555555555',
  Object? fullyRegistered = true,
}) =>
    <String, dynamic>{
      'uuid': uuid,
      'credential_id': 'Y3JlZA',
      'public_key': 'cHVi',
      'is_fully_registered': fullyRegistered,
      'auth_method': 'passkey',
      'created_at': '2026-09-01T10:00:00+00:00',
      'last_passkey_use': '2026-09-20T08:30:00+00:00',
    };

void main() {
  group('the platform string the RPC takes', () {
    test('only the two the server understands', () {
      expect(passkeyLookupPlatform(isAndroid: true), 'android');
      expect(passkeyLookupPlatform(isAndroid: false), 'ios');
    });
  });

  group('no row for this device', () {
    test('the empty list — the normal "unknown device" answer', () {
      expect(passkeyRowFromRpc(<dynamic>[], fullyRegistered: true), isNull);
      expect(passkeyRowFromRpc(<dynamic>[], fullyRegistered: false), isNull);
      expect(passkeyRowFromRpc(<dynamic>[], fullyRegistered: null), isNull);
    });

    test('null, for a client that unwrapped nothing at all', () {
      expect(passkeyRowFromRpc(null, fullyRegistered: null), isNull);
    });

    test('a shape we do not recognise is not a row', () {
      expect(passkeyRowFromRpc('oops', fullyRegistered: null), isNull);
      expect(passkeyRowFromRpc(<dynamic>[<String, dynamic>{}],
          fullyRegistered: null),
          isNull);
    });
  });

  group('one row, the whole map survives', () {
    test('every key the callers read is passed through untouched', () {
      final found =
          passkeyRowFromRpc(<dynamic>[row()], fullyRegistered: true);

      expect(found, isNotNull);
      // _authenticateWithExistingPasskey reads exactly these three.
      expect(found!['uuid'], '11111111-2222-3333-4444-555555555555');
      expect(found['credential_id'], 'Y3JlZA');
      expect(found['public_key'], 'cHVi');
      // …and the debug/telemetry path reads these.
      expect(found['auth_method'], 'passkey');
      expect(found['is_fully_registered'], isTrue);
      expect(found['created_at'], '2026-09-01T10:00:00+00:00');
      expect(found['last_passkey_use'], '2026-09-20T08:30:00+00:00');
    });

    test('a bare map is accepted too', () {
      final found = passkeyRowFromRpc(row(), fullyRegistered: true);
      expect(found?['uuid'], '11111111-2222-3333-4444-555555555555');
    });

    test('the returned map is typed for the callers, not a raw dynamic map', () {
      final found = passkeyRowFromRpc(
          <dynamic>[<dynamic, dynamic>{'uuid': 'u1', 'is_fully_registered': true}],
          fullyRegistered: true);
      expect(found, isA<Map<String, dynamic>>());
      expect(found?['uuid'], 'u1');
    });
  });

  group('the is_fully_registered split', () {
    test('a real account answers the "is there an account" question', () {
      expect(passkeyRowFromRpc(<dynamic>[row()], fullyRegistered: true),
          isNotNull);
      expect(passkeyRowFromRpc(<dynamic>[row()], fullyRegistered: false),
          isNull,
          reason: 'a finished registration is not a broken one');
    });

    test('a broken half-registration answers the other one', () {
      final broken = <dynamic>[row(fullyRegistered: false)];
      expect(passkeyRowFromRpc(broken, fullyRegistered: false), isNotNull);
      expect(passkeyRowFromRpc(broken, fullyRegistered: true), isNull,
          reason: 'sign-in must never accept a half-registered row');
    });

    test('null takes whichever row the device has', () {
      expect(passkeyRowFromRpc(<dynamic>[row()], fullyRegistered: null),
          isNotNull);
      expect(
          passkeyRowFromRpc(<dynamic>[row(fullyRegistered: false)],
              fullyRegistered: null),
          isNotNull);
    });

    test('a NULL flag matches neither, exactly as SQL equality did', () {
      // The old queries were `.eq('is_fully_registered', true|false)`, and
      // `= NULL` is never true in Postgres. Reset and recover, which pass
      // null, still see the row.
      final unknown = <dynamic>[row(fullyRegistered: null)];
      expect(passkeyRowFromRpc(unknown, fullyRegistered: true), isNull);
      expect(passkeyRowFromRpc(unknown, fullyRegistered: false), isNull);
      expect(passkeyRowFromRpc(unknown, fullyRegistered: null), isNotNull);
    });

    test('a non-bool flag is not coerced into a yes', () {
      final odd = <dynamic>[row(fullyRegistered: 'true')];
      expect(passkeyRowFromRpc(odd, fullyRegistered: true), isNull);
    });
  });

  group('the server already ordered the rows', () {
    test('the first row wins — fully registered first, LIMIT 1', () {
      // Defensive: the function returns at most one row, but if a future
      // change ever relaxed the LIMIT the ORDER BY is the contract, so the
      // first row is the one to take rather than the last.
      final rows = <dynamic>[
        row(uuid: 'best', fullyRegistered: true),
        row(uuid: 'stale', fullyRegistered: false),
      ];
      expect(passkeyRowFromRpc(rows, fullyRegistered: null)?['uuid'], 'best');
    });
  });
}
