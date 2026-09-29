// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The chameleon avatar catalogue (WP-C2). These tests hit the real files on
// disk: `flutter test` runs with the package root as the working directory, so
// a missing/renamed SVG, an id typo, or an asset dropped from pubspec.yaml
// fails here rather than as a blank avatar at runtime.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:read_the_room/src/utils/avatar_catalog.dart';

void main() {
  group('kChameleonAvatarIds', () {
    test('is exactly the ten ids 01–10, in order', () {
      expect(kChameleonAvatarIds, hasLength(10));
      for (var i = 0; i < 10; i++) {
        expect(
          kChameleonAvatarIds[i],
          'chameleon_${(i + 1).toString().padLeft(2, '0')}',
        );
      }
    });

    test('matches the avatar_id CHECK in user_profiles.sql', () {
      final pattern = RegExp(r'^chameleon_[0-9]{2}$');
      for (final id in kChameleonAvatarIds) {
        expect(pattern.hasMatch(id), isTrue, reason: '"$id" fails the SQL CHECK');
      }
    });
  });

  group('avatarAssetPath', () {
    test('every id maps to an asset that exists on disk', () {
      for (final id in kChameleonAvatarIds) {
        final path = avatarAssetPath(id);
        expect(path, isNotNull, reason: 'no path for $id');
        expect(
          File(path!).existsSync(),
          isTrue,
          reason: 'missing asset file for $id at $path',
        );
      }
    });

    test('every asset is a self-contained 128×128 SVG under 8 KB', () {
      for (final id in kChameleonAvatarIds) {
        final file = File(avatarAssetPath(id)!);
        final bytes = file.lengthSync();
        expect(bytes, lessThan(8 * 1024), reason: '$id is $bytes bytes');

        final svg = file.readAsStringSync();
        expect(svg, contains('viewBox="0 0 128 128"'), reason: id);
        // No external references — flutter_svg cannot resolve them and they
        // would silently render as nothing.
        expect(svg, isNot(contains('xlink:href')), reason: id);
        expect(svg, isNot(contains('<image')), reason: id);
        expect(svg, isNot(contains('url(http')), reason: id);
      }
    });

    test('the ten assets are visually distinct (no duplicate content)', () {
      final contents = <String>{};
      for (final id in kChameleonAvatarIds) {
        contents.add(File(avatarAssetPath(id)!).readAsStringSync());
      }
      expect(contents, hasLength(kChameleonAvatarIds.length));
    });

    test('unknown and null ids resolve to null, not a broken path', () {
      expect(avatarAssetPath(null), isNull);
      expect(avatarAssetPath(''), isNull);
      expect(avatarAssetPath('chameleon_99'), isNull);
      expect(avatarAssetPath('../../etc/passwd'), isNull);
    });
  });

  group('isKnownAvatarId', () {
    test('accepts catalogued ids only', () {
      expect(isKnownAvatarId('chameleon_01'), isTrue);
      expect(isKnownAvatarId('chameleon_10'), isTrue);
      expect(isKnownAvatarId('chameleon_11'), isFalse);
      expect(isKnownAvatarId(null), isFalse);
    });
  });

  group('pubspec registration', () {
    test('the avatars folder is declared as an asset', () {
      final pubspec = File('pubspec.yaml').readAsStringSync();
      expect(pubspec, contains('$kAvatarAssetDir/'));
    });

    test('flutter_svg is a pinned dependency', () {
      final pubspec = File('pubspec.yaml').readAsStringSync();
      expect(
        RegExp(r'^\s+flutter_svg:\s*\d+\.\d+\.\d+', multiLine: true)
            .hasMatch(pubspec),
        isTrue,
        reason: 'flutter_svg must be pinned to an exact version',
      );
    });
  });
}
