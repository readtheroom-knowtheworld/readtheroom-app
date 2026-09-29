// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The toggle sits beside AnimatedSubmitButton on the answer screens
// (Row([Expanded(AnimatedSubmitButton), ShareWithCloseFriendsToggle])) and
// is meant to be exactly as tall as the button, and square. It reads
// AnimatedSubmitButton.height as its single source of truth rather than a
// second hardcoded number, so this pins that contract down.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:read_the_room/src/services/friend_service.dart';
import 'package:read_the_room/src/utils/friend_logic.dart';
import 'package:read_the_room/src/widgets/animated_submit_button.dart';
import 'package:read_the_room/src/widgets/share_with_close_friends_toggle.dart';

/// A viewer with one close friend, so the toggle actually renders (it draws
/// nothing when `closeFriends` is empty).
class _FakeFriendService extends FriendService {
  _FakeFriendService() : super(listenToAuth: false);

  @override
  List<Friend> get closeFriends =>
      const [Friend(userId: 'friend-1', isClose: true, mutualClose: true)];
}

void main() {
  Widget wrap(Widget child) {
    return ChangeNotifierProvider<FriendService>.value(
      value: _FakeFriendService(),
      child: MaterialApp(home: Scaffold(body: child)),
    );
  }

  testWidgets(
      'toggle is exactly AnimatedSubmitButton.height tall, and square',
      (tester) async {
    await tester.pumpWidget(wrap(
      ShareWithCloseFriendsToggle(value: true, onChanged: (_) {}),
    ));
    await tester.pump();

    final size = tester.getSize(find.byType(ShareWithCloseFriendsToggle));
    expect(size.height, AnimatedSubmitButton.height);
    // Square: the icon frame itself (not the outer left-padding wrapper)
    // has equal width and height.
    final frameSize = tester.getSize(find.byType(AnimatedContainer));
    expect(frameSize.width, frameSize.height);
    expect(frameSize.height, AnimatedSubmitButton.height);
  });

  testWidgets(
      'submit button + toggle render at the same height on one row',
      (tester) async {
    await tester.pumpWidget(wrap(
      Row(
        children: [
          Expanded(
            child: AnimatedSubmitButton(
              onPressed: () {},
              isLoading: false,
              buttonText: 'Submit Answer',
              padding: const EdgeInsets.symmetric(vertical: 16),
            ),
          ),
          ShareWithCloseFriendsToggle(value: true, onChanged: (_) {}),
        ],
      ),
    ));
    await tester.pump();

    final buttonHeight =
        tester.getSize(find.byType(AnimatedSubmitButton)).height;
    final toggleHeight =
        tester.getSize(find.byType(ShareWithCloseFriendsToggle)).height;
    expect(toggleHeight, buttonHeight);
  });
}
