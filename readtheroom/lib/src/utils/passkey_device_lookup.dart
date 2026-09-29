// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The pure half of the passkey device lookup.
//
// Before this, the sign-in path asked the `users` table directly, PRE-AUTH,
// with a filter the caller supplied:
//
//   from('users').select('*').eq('android_id', deviceId)…
//
// which only worked because a blanket SELECT policy was open to anon — and a
// filter the caller supplies is a filter the caller can drop, so the same
// public key listed every passkey user's `uuid`, `credential_id` and
// `public_key` in one request. The Supabase password is derived from `uuid`,
// so that list was a list of passwords.
//
// The server now answers ONE device id at a time:
//   find_passkey_user_for_device(p_device_id text, p_platform text)
//     -> 0 or 1 rows (uuid, credential_id, public_key, is_fully_registered,
//        auth_method, created_at, last_passkey_use)
//
// Contract:  scripts/passkey_lookup_01_rpc.sql
// Docs:      feature-documentation/passkey-lookup-2026-09-23.md
//
// Everything here is pure so the shaping — which the whole sign-in path hangs
// on — is unit-testable without a device, a network or a Supabase stub.

/// The `p_platform` value `find_passkey_user_for_device` expects.
///
/// Only two are valid server-side; anything else makes the function's CASE
/// fall through to `false` and return no rows.
String passkeyLookupPlatform({required bool isAndroid}) =>
    isAndroid ? 'android' : 'ios';

/// Reduces what PostgREST handed back for `find_passkey_user_for_device` to
/// the single row the sign-in path reads, or null.
///
/// [raw] is whatever `rpc()` returned: a list of rows (the normal shape for a
/// `RETURNS TABLE` function), a bare map (defensive — a single row can arrive
/// unwrapped), or null.
///
/// [fullyRegistered] is applied HERE rather than server-side because the RPC
/// deliberately returns the best row for the device — fully registered first —
/// so one round trip answers both "is there an account" and "is there a broken
/// half-registration". Pass null to accept either.
///
/// A row whose `is_fully_registered` is null or not a bool never matches, which
/// is what the old `.eq('is_fully_registered', …)` did too: SQL equality does
/// not match NULL.
Map<String, dynamic>? passkeyRowFromRpc(
  Object? raw, {
  required bool? fullyRegistered,
}) {
  final row = _firstRow(raw);
  if (row == null) return null;

  if (fullyRegistered != null) {
    final flag = row['is_fully_registered'];
    if (flag is! bool || flag != fullyRegistered) return null;
  }

  return row;
}

Map<String, dynamic>? _firstRow(Object? raw) {
  if (raw == null) return null;
  if (raw is Map) return raw.isEmpty ? null : Map<String, dynamic>.from(raw);
  if (raw is List) {
    for (final entry in raw) {
      if (entry is Map && entry.isNotEmpty) return Map<String, dynamic>.from(entry);
    }
  }
  return null;
}
