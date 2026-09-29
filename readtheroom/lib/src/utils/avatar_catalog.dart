// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

/// The chameleon avatar catalogue (WP-C2, decision D3: an agent-generated set
/// of ten flat-vector chameleons).
///
/// Pure — no Flutter import — so the id ↔ asset-path mapping can be asserted in
/// a plain unit test against the real files on disk
/// (`test/avatar_catalog_test.dart`).
///
/// The ids here are exactly the `avatar_id` values stored in `user_profiles`.
/// The SVGs are Soud's hand-made set (2026-09-16), which replaced the
/// placeholder set from `scripts/gen_chameleon_avatars.py`. Same ids/paths.
library;

/// Folder holding the generated avatars, registered in `pubspec.yaml`.
const String kAvatarAssetDir = 'assets/avatars';

/// Every avatar id, in picker display order.
const List<String> kChameleonAvatarIds = <String>[
  'chameleon_01',
  'chameleon_02',
  'chameleon_03',
  'chameleon_04',
  'chameleon_05',
  'chameleon_06',
  'chameleon_07',
  'chameleon_08',
  'chameleon_09',
  'chameleon_10',
];

/// Asset path for [avatarId], or `null` when the id is unknown (or null) —
/// callers then fall back to the placeholder silhouette rather than throwing on
/// an id written by a newer client.
String? avatarAssetPath(String? avatarId) {
  if (avatarId == null) return null;
  if (!kChameleonAvatarIds.contains(avatarId)) return null;
  return '$kAvatarAssetDir/$avatarId.svg';
}

/// `true` when [avatarId] is one this build can render.
bool isKnownAvatarId(String? avatarId) =>
    avatarId != null && kChameleonAvatarIds.contains(avatarId);
