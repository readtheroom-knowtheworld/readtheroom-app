// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:read_the_room/src/widgets/streak_celebration_animation.dart';

Widget _host(Widget celebration) => MaterialApp(
      home: Scaffold(body: Stack(children: [celebration])),
    );

void main() {
  testWidgets('streak variant rolls the count and finishes in under 3 s',
      (tester) async {
    var completed = false;
    await tester.pumpWidget(_host(StreakCelebrationAnimation(
      oldStreak: 4,
      newStreak: 5,
      onComplete: () => completed = true,
    )));

    expect(find.text('4'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text(' +1'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('5'), findsOneWidget);
    expect(find.text('Thanks for contributing today!'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 1400));
    await tester.pumpAndSettle();
    expect(completed, isTrue);
  });

  testWidgets('first-answerer variant shows the rank and Curio line',
      (tester) async {
    var completed = false;
    await tester.pumpWidget(_host(StreakCelebrationAnimation(
      oldStreak: 0,
      newStreak: 0,
      firstAnswererRank: 3,
      username: 'curious_cham7',
      onComplete: () => completed = true,
    )));
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('#3'), findsOneWidget);
    expect(find.byIcon(Icons.local_fire_department), findsNothing);
    expect(
      find.text("You're the 3rd to answer today, curious_cham7 — "
          "you get to pick tomorrow's Question of the Day!"),
      findsOneWidget,
    );

    await tester.pump(const Duration(milliseconds: 2900));
    expect(completed, isFalse);
    await tester.pumpAndSettle();
    expect(completed, isTrue);
  });
}
