// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The one-time existing-user profile prompt (WP-C3 step 3, decision D5).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:read_the_room/src/services/profile_service.dart';
import 'package:read_the_room/src/utils/avatar_catalog.dart';
import 'package:read_the_room/src/widgets/avatar_picker_sheet.dart';
import 'package:read_the_room/src/widgets/chameleon_avatar.dart';
import 'package:read_the_room/src/widgets/profile_setup_sheet.dart';
import 'package:read_the_room/src/widgets/username_edit_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('ProfileSetupSheet.shouldShow', () {
    test('shows for an authenticated user with no handle, once', () {
      expect(
        ProfileSetupSheet.shouldShow(
          isAuthenticated: true,
          hasUsername: false,
          alreadyShown: false,
        ),
        isTrue,
      );
    });

    test('never shows twice', () {
      expect(
        ProfileSetupSheet.shouldShow(
          isAuthenticated: true,
          hasUsername: false,
          alreadyShown: true,
        ),
        isFalse,
      );
    });

    test('never shows to someone who already has a handle', () {
      expect(
        ProfileSetupSheet.shouldShow(
          isAuthenticated: true,
          hasUsername: true,
          alreadyShown: false,
        ),
        isFalse,
      );
    });

    test('never shows to a guest — they get the onboarding slide instead', () {
      expect(
        ProfileSetupSheet.shouldShow(
          isAuthenticated: false,
          hasUsername: false,
          alreadyShown: false,
        ),
        isFalse,
      );
    });
  });

  group('ProfileSetupSheet content', () {
    testWidgets('reuses the same avatar grid and handle field as onboarding',
        (tester) async {
      final profile = ProfileService(listenToAuth: false);
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(primaryColor: const Color(0xFF00897B)),
        home: ChangeNotifierProvider<ProfileService>.value(
          value: profile,
          child: const Scaffold(body: ProfileSetupSheet()),
        ),
      ));
      await tester.pump();

      expect(find.byType(AvatarGrid), findsOneWidget);
      expect(
        find.byType(ChameleonAvatar),
        findsNWidgets(kChameleonAvatarIds.length),
      );
      expect(find.byType(UsernameField), findsOneWidget);
      // Skippable.
      expect(find.text('Maybe later'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
