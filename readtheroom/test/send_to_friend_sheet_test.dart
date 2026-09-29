// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Send-to-a-friend sheet: private nicknames show beside the handles, as on the
// friend list (owner request 2026-09-28).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:read_the_room/src/services/friend_chat_service.dart';
import 'package:read_the_room/src/services/friend_nickname_service.dart';
import 'package:read_the_room/src/services/friend_service.dart';
import 'package:read_the_room/src/utils/friend_logic.dart';
import 'package:read_the_room/src/widgets/send_to_friend_sheet.dart';

class _Friends extends FriendService {
  _Friends(this._friends) : super(listenToAuth: false);
  final List<Friend> _friends;

  @override
  bool get isAuthenticated => true;

  @override
  List<Friend> get friends => _friends;

  @override
  Future<void> load() async {}
}

Future<void> _openSheet(WidgetTester tester, FriendNicknameService store) async {
  await tester.pumpWidget(MultiProvider(
    providers: [
      ChangeNotifierProvider<FriendService>.value(
        value: _Friends(const [
          Friend(userId: 'id-sam', username: 'sam', status: FriendStatus.accepted),
          Friend(userId: 'id-kit', username: 'kit', status: FriendStatus.accepted),
        ]),
      ),
      ChangeNotifierProvider<FriendChatService>.value(
          value: FriendChatService(listenToAuth: false, enableRealtime: false)),
      ChangeNotifierProvider<FriendNicknameService>.value(value: store),
    ],
    child: MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: ElevatedButton(
            onPressed: () =>
                SendToFriendSheet.show(context: context, questionId: 'q1'),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('shows nicknames after the handle, only where one is set',
      (tester) async {
    final store =
        FriendNicknameService(viewerId: () => 'me', listenToAuth: false);
    await store.setNickname('id-sam', 'Big Sis');
    await _openSheet(tester, store);

    expect(find.text('@sam'), findsOneWidget);
    expect(find.text('(Big Sis)'), findsOneWidget);
    expect(find.text('@kit'), findsOneWidget);
    expect(find.textContaining('('), findsOneWidget);
  });
}
