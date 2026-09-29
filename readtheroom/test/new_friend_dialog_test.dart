// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:read_the_room/src/utils/friend_logic.dart';
import 'package:read_the_room/src/widgets/new_friend_dialog.dart';

void main() {
  testWidgets('NewFriendDialog names the friend and dismisses on Done',
      (tester) async {
    final friend = Friend(
      userId: 'pal',
      username: 'pal',
      status: FriendStatus.accepted,
    );
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => NewFriendDialog.show(context, friend),
            child: const Text('open'),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('@pal'), findsOneWidget);
    expect(find.textContaining("You're friends now"), findsOneWidget);

    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(find.byType(NewFriendDialog), findsNothing);
  });
}
