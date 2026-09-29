// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// AvatarGrid selection behaviour (WP-C2). ProfileService is constructed with
// `listenToAuth: false` and a null Supabase client: guest mode, so setAvatar
// stages the choice in SharedPreferences instead of hitting the backend — which
// is exactly the onboarding path WP-C3 relies on.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:read_the_room/src/services/profile_service.dart';
import 'package:read_the_room/src/utils/avatar_catalog.dart';
import 'package:read_the_room/src/widgets/avatar_picker_sheet.dart';
import 'package:read_the_room/src/widgets/chameleon_avatar.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Widget host(ProfileService profile, Widget child) => MaterialApp(
        theme: ThemeData(primaryColor: const Color(0xFF00897B)),
        home: ChangeNotifierProvider<ProfileService>.value(
          value: profile,
          child: Scaffold(body: Center(child: child)),
        ),
      );

  testWidgets('renders one tile per catalogued avatar', (tester) async {
    final profile = ProfileService(listenToAuth: false);
    await tester.pumpWidget(host(profile, const AvatarGrid()));
    await tester.pump();

    expect(
      find.byType(ChameleonAvatar),
      findsNWidgets(kChameleonAvatarIds.length),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('one tap selects and reports the id', (tester) async {
    final profile = ProfileService(listenToAuth: false);
    String? picked;
    await tester.pumpWidget(host(
      profile,
      AvatarGrid(popOnSelect: false, onSelected: (id) => picked = id),
    ));
    await tester.pump();

    await tester.tap(find.byType(ChameleonAvatar).first);
    await tester.pumpAndSettle();

    expect(picked, kChameleonAvatarIds.first);
    // Guest: staged locally rather than written to user_profiles.
    expect(profile.avatarId, kChameleonAvatarIds.first);
    expect(profile.hasPendingSelection, isTrue);
  });

  testWidgets('the selected tile is marked selected for a11y', (tester) async {
    final profile = ProfileService(listenToAuth: false);
    await profile.stageAvatar(kChameleonAvatarIds[2]);

    await tester.pumpWidget(host(profile, const AvatarGrid(popOnSelect: false)));
    await tester.pump();

    final selected = tester
        .widgetList<Semantics>(find.byType(Semantics))
        .where((s) => s.properties.selected == true)
        .toList();
    expect(selected, hasLength(1));
  });

  testWidgets('an unknown avatar id falls back to the placeholder',
      (tester) async {
    final profile = ProfileService(listenToAuth: false);
    await tester.pumpWidget(host(
      profile,
      const ChameleonAvatar(avatarId: 'chameleon_99', size: 40),
    ));
    await tester.pump();

    // The placeholder is the lizard glyph; no exception from a missing asset.
    expect(find.text('🦎'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
