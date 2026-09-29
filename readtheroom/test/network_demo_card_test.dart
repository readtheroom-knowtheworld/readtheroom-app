// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// NetworkDemoCard — the "see how your circle reads the room" sample graph
// shown to users with no friends (home + Community empty state).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:read_the_room/src/widgets/network_demo_card.dart';
import 'package:read_the_room/src/widgets/network_graph_preview.dart';

Widget _app(Widget child) => MaterialApp(
      theme: ThemeData(primaryColor: const Color(0xFF00897B)),
      home: MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: Scaffold(
          body: SingleChildScrollView(
            child: SizedBox(width: 360, child: child),
          ),
        ),
      ),
    );

void main() {
  testWidgets('is unmistakably sample data: DEMO badge + caption + graph',
      (tester) async {
    await tester.pumpWidget(_app(const NetworkDemoCard()));
    await tester.pump();

    expect(find.text('DEMO'), findsOneWidget);
    expect(find.byType(NetworkGraphPreview), findsOneWidget);
    // No chip legend (removed 2026-09-19): the one-line explainer carries the
    // privacy model on its own.
    expect(find.text('Friend (private)'), findsNothing);
    expect(find.textContaining('Friends keep their answers private'),
        findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the CTA fires the callback and can be turned off',
      (tester) async {
    var taps = 0;
    await tester.pumpWidget(_app(NetworkDemoCard(onAddFriends: () => taps++)));
    await tester.pump();
    await tester.tap(find.text('Add your first friend'));
    expect(taps, 1);

    await tester.pumpWidget(_app(const NetworkDemoCard(showCta: false)));
    await tester.pump();
    expect(find.text('Add your first friend'), findsNothing);
  });

  testWidgets('Hide is offered only when a dismiss handler exists',
      (tester) async {
    await tester.pumpWidget(_app(const NetworkDemoCard()));
    await tester.pump();
    expect(find.byTooltip('Hide'), findsNothing);

    var dismissed = 0;
    await tester
        .pumpWidget(_app(NetworkDemoCard(onDismiss: () => dismissed++)));
    await tester.pump();
    await tester.tap(find.byTooltip('Hide'));
    expect(dismissed, 1);
  });

  testWidgets('friendCount switches the header and shows progress',
      (tester) async {
    await tester.pumpWidget(_app(const NetworkDemoCard(friendCount: 3)));
    await tester.pump();

    expect(find.text('Your network'), findsOneWidget);
    expect(find.textContaining('2 more friends'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.text('Add a friend'), findsOneWidget);
    expect(find.text('DEMO'), findsOneWidget); // still sample data
  });
}
