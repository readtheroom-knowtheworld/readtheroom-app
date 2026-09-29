// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The error → user-copy mapping for the set_username / set_avatar RPCs
// (WP-C1). ProfileResult is dependency-free on purpose so this needs no
// Supabase client, mirroring nomination_result_test.dart.

import 'package:flutter_test/flutter_test.dart';
import 'package:read_the_room/src/services/demo/demo_friend_service.dart';
import 'package:read_the_room/src/services/profile_service.dart';

void main() {
  group('ProfileResult.parseError', () {
    test('maps every server error code from user_profiles.sql', () {
      expect(ProfileResult.parseError('not_authenticated'),
          UsernameError.notAuthenticated);
      expect(
          ProfileResult.parseError('invalid_format'), UsernameError.invalidFormat);
      expect(
          ProfileResult.parseError('invalid_avatar'), UsernameError.invalidFormat);
      expect(ProfileResult.parseError('profanity'), UsernameError.profanity);
      expect(ProfileResult.parseError('cooldown'), UsernameError.cooldown);
      expect(ProfileResult.parseError('taken'), UsernameError.taken);
    });

    test('unknown and null codes fall back to unknown', () {
      expect(ProfileResult.parseError('something_new'), UsernameError.unknown);
      expect(ProfileResult.parseError(null), UsernameError.unknown);
    });
  });

  group('ProfileResult.message', () {
    test('success reports saved', () {
      expect(const ProfileResult.ok().message, 'Saved');
    });

    test('every error has non-empty copy', () {
      for (final error in UsernameError.values) {
        expect(ProfileResult.fail(error).message, isNotEmpty);
      }
    });

    test('cooldown copy carries the remaining days and pluralises', () {
      expect(
        const ProfileResult.fail(UsernameError.cooldown, daysRemaining: 1)
            .message,
        contains('1 day'),
      );
      expect(
        const ProfileResult.fail(UsernameError.cooldown, daysRemaining: 4)
            .message,
        contains('4 days'),
      );
    });

    test('taken copy points at the suggestions', () {
      expect(
        const ProfileResult.fail(UsernameError.taken).message,
        contains('suggestions'),
      );
    });
  });

  group('share my answers with close friends (legacy, read-only)', () {
    // Superseded 2026-09-17 by the per-answer flag on `responses`
    // (feature-documentation/per-answer-share-flag-2026-09-17.md): there is no
    // setter any more, and no UI reads this. What still matters is that parsing
    // `get_my_profile()` cannot leave the value looking like an opt-out.
    test('defaults to ON before anything is loaded', () {
      expect(
        ProfileService(listenToAuth: false).shareAnswersWithCloseFriends,
        isTrue,
      );
    });

    test('a demo profile inherits the same default', () {
      expect(DemoProfileService().shareAnswersWithCloseFriends, isTrue);
    });
  });
}
