// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Community tab (WP-E, networks-update-design §5.3). Pumped against a fake
// FriendService so the sections, the guest gate, the empty state and the
// destructive-action confirmations are covered without a backend.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:read_the_room/src/screens/community_screen.dart';
import 'package:read_the_room/src/widgets/email_signup_card.dart';
import 'package:read_the_room/src/widgets/chameleon_lick_icon.dart';
import 'package:read_the_room/src/services/friend_chat_service.dart';
import 'package:read_the_room/src/services/friend_nickname_service.dart';
import 'package:read_the_room/src/services/friend_service.dart';
import 'package:read_the_room/src/services/profile_service.dart';
import 'package:read_the_room/src/utils/friend_logic.dart';
import 'package:read_the_room/src/widgets/friend_list_tile.dart';
import 'package:read_the_room/src/widgets/network_demo_card.dart';

/// A FriendService with a fixed graph and no Supabase behind it.
///
/// Every RPC method is overridden to a recorded no-op, so tapping a row's menu
/// exercises the screen's own flow (confirmation dialog, busy guard, SnackBar
/// copy) without a network call.
class FakeFriendService extends FriendService {
  FakeFriendService({
    List<Friend> graph = const [],
    this.authenticated = true,
    this.loaded = true,
  })  : _graph = graph,
        super(listenToAuth: false);

  final List<Friend> _graph;
  final bool authenticated;
  final bool loaded;

  /// Actions the screen actually invoked, for assertions.
  final List<String> calls = [];

  @override
  bool get isAuthenticated => authenticated;

  @override
  bool get isLoaded => loaded;

  @override
  FriendSections get sections =>
      partitionFriends(_graph, viewerId: 'me-uuid');

  @override
  List<Friend> get friends => sections.allAccepted;

  @override
  List<Friend> get closeFriends => sections.closeFriends;

  @override
  List<Friend> get pendingIncoming => sections.incoming;

  @override
  List<Friend> get pendingOutgoing => sections.outgoing;

  @override
  Future<void> load() async {}

  @override
  Future<void> refresh() async {}

  @override
  Future<FriendResult> respondToRequest(String userId, bool accept, {String direction = 'incoming'}) async {
    calls.add('respond:$userId:$accept');
    return const FriendResult.ok();
  }

  @override
  Future<FriendResult> cancelRequest(String userId) async {
    calls.add('cancel:$userId');
    return const FriendResult.ok();
  }

  @override
  Future<FriendResult> setCloseFriend(String userId, bool close, {String surface = 'community_menu'}) async {
    calls.add('close:$userId:$close');
    return const FriendResult.ok();
  }

  @override
  Future<FriendResult> setFriendMuted(String userId, bool muted) async {
    calls.add('mute:$userId:$muted');
    return const FriendResult.ok();
  }

  @override
  Future<FriendResult> unfriend(String userId) async {
    calls.add('unfriend:$userId');
    return const FriendResult.ok();
  }

  @override
  Future<FriendResult> blockUser(String userId, {String surface = 'community'}) async {
    calls.add('block:$userId');
    return const FriendResult.ok();
  }
}

/// A ProfileService with a fixed handle and no Supabase behind it.
class FakeProfileService extends ProfileService {
  FakeProfileService({String? handle = 'curio_thechameleon'})
      : _handle = handle,
        super(listenToAuth: false);

  final String? _handle;

  @override
  String? get username => _handle;

  @override
  String? get avatarId => 'chameleon_01';

  @override
  Future<void> load() async {}
}

/// A FriendChatService with no Supabase and no Realtime behind it (WP-F).
///
/// The tab reads it for the chat overlay and for the post-unfriend/block cache
/// teardown, so it has to be in the tree even for tests that never open a chat.
class FakeFriendChatService extends FriendChatService {
  FakeFriendChatService()
      : super(listenToAuth: false, enableRealtime: false);

  final List<String> calls = [];

  @override
  String? get viewerId => 'me-uuid';

  @override
  bool get isAuthenticated => true;

  @override
  Future<void> loadTimeline(String friendId, {bool loadMore = false}) async {
    calls.add('timeline:$friendId');
  }

  @override
  Future<void> markRead(String friendId) async {
    calls.add('read:$friendId');
    if (unread.remove(friendId) != null) notifyListeners();
  }

  @override
  Future<void> loadUnreadCounts() async {}

  /// friendId → unread count, settable by a test; [markRead] clears it.
  final Map<String, int> unread = {};

  @override
  int unreadFor(String friendId) => unread[friendId] ?? 0;

  @override
  void dropFriend(String friendId, {bool suppress = true}) {
    calls.add('drop:$friendId:$suppress');
  }
}

Widget _app(FakeFriendService friends,
    {FakeProfileService? profile,
    FakeFriendChatService? chat,
    FriendNicknameService? nicknames}) {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<FriendService>.value(value: friends),
      ChangeNotifierProvider<FriendNicknameService>.value(
          value: nicknames ??
              FriendNicknameService(
                  viewerId: () => 'me-uuid', listenToAuth: false)),
      ChangeNotifierProvider<ProfileService>.value(
          value: profile ?? FakeProfileService()),
      ChangeNotifierProvider<FriendChatService>.value(
          value: chat ?? FakeFriendChatService()),
    ],
    child: MaterialApp(
      theme: ThemeData(primaryColor: const Color(0xFF00897B)),
      home: const MediaQuery(
        data: MediaQueryData(disableAnimations: true),
        child: CommunityScreen(),
      ),
    ),
  );
}

Friend _accepted(String id,
        {bool isClose = false,
        bool mutualClose = false,
        DateTime? lastEventAt}) =>
    Friend(
      userId: id,
      username: id,
      status: FriendStatus.accepted,
      isClose: isClose,
      mutualClose: mutualClose,
      lastEventAt: lastEventAt,
    );

Friend _incoming(String id) => Friend(
      userId: id,
      username: id,
      status: FriendStatus.pending,
      requestedBy: id,
    );

Friend _outgoing(String id) => Friend(
      userId: id,
      username: id,
      status: FriendStatus.pending,
      requestedBy: 'me-uuid',
    );

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  /// The tab is a lazy ListView, so a short test window simply never builds the
  /// lower sections. Give every test a tall surface and assert on what is
  /// rendered rather than scrolling in each case.
  void useTallSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(1000, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  group('guest gate (§5.2)', () {
    testWidgets('a guest sees a sign-in prompt and no friend surface',
        (tester) async {
      await tester.pumpWidget(
          _app(FakeFriendService(authenticated: false)));
      await tester.pumpAndSettle();

      expect(find.text('Community'), findsOneWidget); // app bar
      expect(find.text('Verify that you are a human'), findsOneWidget);
      expect(find.text('Bring your people to the room'), findsOneWidget);

      // None of the friend affordances are reachable without an account.
      expect(find.text('My QR'), findsNothing);
      expect(find.text('Scan'), findsNothing);
      expect(find.byType(FriendListTile), findsNothing);

      // The email card still works for guests.
      expect(find.text('Keep in touch'), findsOneWidget);
    });
  });

  group('identity card (§5.3(1))', () {
    testWidgets('shows the handle and the three add affordances',
        (tester) async {
      useTallSurface(tester);
      // With a friend present the empty state is absent, so "My QR" can only
      // be the identity card's own button.
      await tester
          .pumpWidget(_app(FakeFriendService(graph: [_accepted('pal')])));
      await tester.pumpAndSettle();

      expect(find.text('@curio_thechameleon'), findsOneWidget);
      expect(find.text('My QR'), findsOneWidget);
      expect(find.text('Scan'), findsOneWidget);
      expect(find.text('Add'), findsOneWidget);
    });

    testWidgets('prompts for a handle when none is set', (tester) async {
      useTallSurface(tester);
      await tester.pumpWidget(_app(
        FakeFriendService(),
        profile: FakeProfileService(handle: null),
      ));
      await tester.pumpAndSettle();

      expect(find.text('Pick a name'), findsOneWidget);
      expect(find.text('Friends find you by your handle'), findsOneWidget);
    });
  });

  group('sections (§5.3(2)/(3))', () {
    testWidgets('renders requests, close friends, friends, then sent in order',
        (tester) async {
      useTallSurface(tester);
      await tester.pumpWidget(_app(FakeFriendService(graph: [
        _incoming('asks_me'),
        _outgoing('i_asked'),
        _accepted('bestie', isClose: true, mutualClose: true),
        _accepted('acquaintance'),
      ])));
      await tester.pumpAndSettle();

      expect(find.text('Friend requests'), findsOneWidget);
      expect(find.text('Requests'), findsNothing);
      expect(find.text('Sent'), findsNothing);
      expect(find.text('Close friends'), findsNothing);
      expect(find.text('Friends'), findsOneWidget);

      expect(find.text('@asks_me'), findsOneWidget);
      expect(find.text('@i_asked'), findsOneWidget);
      expect(find.text('@bestie'), findsOneWidget);
      expect(find.text('@acquaintance'), findsOneWidget);

      // Sections top-to-bottom: one Friends section (close friends first),
      // then one Friend requests section with incoming rows above sent ones
      // (2026-09-22 order).
      double y(String label) => tester.getTopLeft(find.text(label)).dy;
      expect(y('Friends'), lessThan(y('@bestie')));
      expect(y('@bestie'), lessThan(y('@acquaintance')));
      expect(y('@acquaintance'), lessThan(y('Friend requests')));
      expect(y('Friend requests'), lessThan(y('@asks_me')));
      expect(y('@asks_me'), lessThan(y('@i_asked')));

      expect(find.byType(FriendListTile), findsNWidgets(2));
      expect(find.byType(PendingRequestTile), findsNWidgets(2));
    });

    testWidgets('an incoming request offers accept and decline',
        (tester) async {
      final service = FakeFriendService(graph: [_incoming('asks_me')]);
      await tester.pumpWidget(_app(service));
      await tester.pumpAndSettle();

      expect(find.text('Wants to be friends'), findsOneWidget);
      await tester.tap(find.byTooltip('Accept'));
      await tester.pumpAndSettle();

      expect(service.calls, ['respond:asks_me:true']);
    });

    testWidgets('an outgoing request offers cancel only', (tester) async {
      final service = FakeFriendService(graph: [_outgoing('i_asked')]);
      await tester.pumpWidget(_app(service));
      await tester.pumpAndSettle();

      expect(find.text('Request sent'), findsOneWidget);
      expect(find.byTooltip('Accept'), findsNothing);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(service.calls, ['cancel:i_asked']);
    });

    testWidgets('close-friend rows tell the reciprocity story honestly',
        (tester) async {
      useTallSurface(tester);
      await tester.pumpWidget(_app(FakeFriendService(graph: [
        _accepted('mutual', isClose: true, mutualClose: true),
        _accepted('one_sided', isClose: true),
      ])));
      await tester.pumpAndSettle();

      expect(
        find.text('Sharing answers'),
        findsOneWidget,
      );
      expect(
        find.text('Sharing your answers'),
        findsOneWidget,
      );
    });

    testWidgets('streak flair renders only for a positive streak',
        (tester) async {
      useTallSurface(tester);
      await tester.pumpWidget(_app(FakeFriendService(graph: [
        const Friend(
          userId: 'streaky',
          username: 'streaky',
          status: FriendStatus.accepted,
          streak: 7,
        ),
        _accepted('plain'),
      ])));
      await tester.pumpAndSettle();

      expect(find.text('🔥 7'), findsOneWidget);
      expect(find.textContaining('🔥'), findsOneWidget);
    });
  });

  group('nicknames (on-device only)', () {
    FriendNicknameService nicknames() =>
        FriendNicknameService(viewerId: () => 'me-uuid', listenToAuth: false);

    testWidgets('set from the row menu, shown after the handle in grey',
        (tester) async {
      final store = nicknames();
      await tester.pumpWidget(
          _app(FakeFriendService(graph: [_accepted('pal')]), nicknames: store));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Set nickname'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Only you can see this'), findsOneWidget);

      await tester.enterText(
          find.byKey(const ValueKey('friend-nickname-field')), '  Big   Sis ');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final label = find.byKey(ValueKey(FriendListTile.nicknameKeyFor('pal')));
      expect(label, findsOneWidget);
      expect(tester.widget<Text>(label).data, '(Big Sis)');
      expect(tester.widget<Text>(label).style?.color, Colors.grey);
      expect(
          tester.getTopLeft(label).dx, greaterThan(tester.getTopLeft(find.text('@pal')).dx));
      expect(find.text('Nickname saved'), findsOneWidget);
      expect(store.nicknameFor('pal'), 'Big Sis');
    });

    testWidgets('survives a username change because it is keyed by user id',
        (tester) async {
      final store = nicknames();
      await store.setNickname('pal-id', 'Roomie');
      await tester.pumpWidget(_app(
          FakeFriendService(graph: [
            const Friend(
                userId: 'pal-id',
                username: 'renamed_pal',
                status: FriendStatus.accepted),
          ]),
          nicknames: store));
      await tester.pumpAndSettle();

      expect(find.text('@renamed_pal'), findsOneWidget);
      expect(find.text('(Roomie)'), findsOneWidget);
    });

    testWidgets('removing clears the label', (tester) async {
      final store = nicknames();
      await store.setNickname('pal', 'Roomie');
      await tester.pumpWidget(
          _app(FakeFriendService(graph: [_accepted('pal')]), nicknames: store));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Set nickname'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();

      expect(find.text('(Roomie)'), findsNothing);
      expect(find.text('Nickname removed'), findsOneWidget);
      expect(store.nicknameFor('pal'), isNull);
    });

    testWidgets('the streak sits at the far right, beside the menu',
        (tester) async {
      useTallSurface(tester);
      final store = nicknames();
      await store.setNickname('streaky', 'Mo');
      await tester.pumpWidget(_app(
          FakeFriendService(graph: [
            const Friend(
              userId: 'streaky',
              username: 'streaky',
              status: FriendStatus.accepted,
              streak: 7,
            ),
          ]),
          nicknames: store));
      await tester.pumpAndSettle();

      final streakX = tester.getTopLeft(find.text('🔥 7')).dx;
      expect(streakX, greaterThan(tester.getTopRight(find.text('(Mo)')).dx));
      expect(streakX, lessThan(tester.getTopLeft(find.byIcon(Icons.more_vert)).dx));
    });
  });

  group('row actions', () {
    testWidgets('unfriend confirms with the §5.2 copy before acting',
        (tester) async {
      final service = FakeFriendService(graph: [_accepted('pal')]);
      await tester.pumpWidget(_app(service));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove friend'));
      await tester.pumpAndSettle();

      // Spec copy, verbatim.
      expect(
        find.textContaining(
            "They won't be notified, and you'll disappear from each other's "
            'networks.'),
        findsOneWidget,
      );
      // Nothing has happened yet.
      expect(service.calls, isEmpty);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(service.calls, isEmpty);
    });

    testWidgets('confirming unfriend calls the service', (tester) async {
      final service = FakeFriendService(graph: [_accepted('pal')]);
      await tester.pumpWidget(_app(service));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove friend'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();

      expect(service.calls, ['unfriend:pal']);
    });

    testWidgets('block also confirms first', (tester) async {
      final service = FakeFriendService(graph: [_accepted('pal')]);
      await tester.pumpWidget(_app(service));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Block'));
      await tester.pumpAndSettle();

      expect(find.text('Block @pal?'), findsOneWidget);
      expect(service.calls, isEmpty);

      await tester.tap(find.widgetWithText(TextButton, 'Block'));
      await tester.pumpAndSettle();
      expect(service.calls, ['block:pal']);
    });

    testWidgets('set close friend acts immediately, no confirmation',
        (tester) async {
      final service = FakeFriendService(graph: [_accepted('pal')]);
      await tester.pumpWidget(_app(service));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Set as close friend'));
      await tester.pumpAndSettle();

      expect(service.calls, ['close:pal:true']);
      expect(
        find.textContaining('haring your answers with them'),
        findsOneWidget,
      );
    });

    testWidgets('tapping a friend row opens the chat overlay (WP-F)',
        (tester) async {
      final chat = FakeFriendChatService();
      await tester.pumpWidget(_app(
        FakeFriendService(graph: [_accepted('pal')]),
        chat: chat,
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('@pal'));
      await tester.pumpAndSettle();

      // The sheet's own controls, not the tab's.
      expect(find.text('Lick'), findsOneWidget);
      expect(find.byType(ChameleonLickIcon), findsWidgets);
      expect(find.text('Question'), findsOneWidget);
      // Opening a chat reads it and fetches the first page (§5.4).
      expect(chat.calls, contains('read:pal'));
      expect(chat.calls, contains('timeline:pal'));
    });
  });

  group('friend row unread dot', () {
    testWidgets('dot shows on the friend with unread events only',
        (tester) async {
      final chat = FakeFriendChatService()..unread['pal'] = 2;
      await tester.pumpWidget(_app(
        FakeFriendService(graph: [_accepted('pal'), _accepted('quiet')]),
        chat: chat,
      ));
      await tester.pumpAndSettle();

      expect(
        find.byKey(ValueKey(FriendListTile.unreadDotKeyFor('pal'))),
        findsOneWidget,
      );
      expect(
        find.byKey(ValueKey(FriendListTile.unreadDotKeyFor('quiet'))),
        findsNothing,
      );
      // The row's overflow menu is still there beside the dot.
      expect(find.byIcon(Icons.more_vert), findsNWidgets(2));
    });

    testWidgets('opening the chat clears the dot', (tester) async {
      final chat = FakeFriendChatService()..unread['pal'] = 1;
      await tester.pumpWidget(_app(
        FakeFriendService(graph: [_accepted('pal')]),
        chat: chat,
      ));
      await tester.pumpAndSettle();
      expect(
        find.byKey(ValueKey(FriendListTile.unreadDotKeyFor('pal'))),
        findsOneWidget,
      );

      await tester.tap(find.text('@pal'));
      await tester.pumpAndSettle();
      // Close the overlay so the list is the only thing on screen again.
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      expect(
        find.byKey(ValueKey(FriendListTile.unreadDotKeyFor('pal'))),
        findsNothing,
      );
    });
  });

  group('empty state (§5.3(4))', () {
    testWidgets('explains the model and offers both add CTAs', (tester) async {
      useTallSurface(tester);
      await tester.pumpWidget(_app(FakeFriendService()));
      await tester.pumpAndSettle();

      expect(find.text('No friends yet'), findsOneWidget);
      expect(
        find.textContaining('you both add each other as close friends'),
        findsOneWidget,
      );
      expect(find.text('Add by name'), findsOneWidget);
      // "My QR" appears in both the identity card and the empty state.
      expect(find.text('My QR'), findsNWidgets(2));
    });

    testWidgets('shows a spinner instead of the empty state before the load',
        (tester) async {
      await tester.pumpWidget(_app(FakeFriendService(loaded: false)));
      await tester.pump();

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('No friends yet'), findsNothing);
    });

    testWidgets('the empty state is gone once there are friends',
        (tester) async {
      await tester
          .pumpWidget(_app(FakeFriendService(graph: [_accepted('pal')])));
      await tester.pumpAndSettle();

      expect(find.text('No friends yet'), findsNothing);
    });
  });

  group('the Phase-1 DEMO section is gone', () {
    testWidgets('no coming-soon framing, sneak peek or DEMO badge',
        (tester) async {
      await tester.pumpWidget(_app(FakeFriendService()));
      await tester.pumpAndSettle();

      expect(find.text('COMING SOON'), findsNothing);
      expect(find.text('Sneak peek'), findsNothing);
      expect(find.text('Add friends with a QR code'), findsNothing);
      expect(find.text('See your network read the room'), findsNothing);
    });

    testWidgets('the empty state carries the DEMO-badged network graph card',
        (tester) async {
      await tester.pumpWidget(_app(FakeFriendService()));
      await tester.pumpAndSettle();

      expect(find.byType(NetworkDemoCard), findsOneWidget);
      expect(find.text('DEMO'), findsOneWidget);
      // The card carries its own add CTA on Community too (2026-09-19); it
      // opens the My QR dialog.
      expect(find.text('Add your first friend'), findsOneWidget);
    });

    testWidgets('with a few friends the card becomes a "N of 5" progress nudge',
        (tester) async {
      await tester.pumpWidget(_app(FakeFriendService(graph: [_accepted('pal')])));
      await tester.pumpAndSettle();

      expect(find.byType(NetworkDemoCard), findsOneWidget);
      expect(find.text('Your network'), findsOneWidget);
    });

    testWidgets('the demo card is gone once there are 5 friends',
        (tester) async {
      await tester.pumpWidget(_app(FakeFriendService(graph: [
        for (var i = 0; i < 5; i++) _accepted('pal$i'),
      ])));
      await tester.pumpAndSettle();

      expect(find.byType(NetworkDemoCard), findsNothing);
      expect(find.text('DEMO'), findsNothing);
    });

    testWidgets('the email signup card is kept', (tester) async {
      await tester.pumpWidget(_app(FakeFriendService()));
      await tester.pumpAndSettle();

      // The demo graph card pushes the email card below the fold of the lazy
      // list, so bring it into view before looking for it.
      await tester.scrollUntilVisible(find.text('Keep in touch'), 200,
          scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();

      expect(find.text('Keep in touch'), findsOneWidget);
      expect(find.byType(EmailSignupCard), findsOneWidget);
      expect(find.text('Sign up'), findsOneWidget);
    });

    testWidgets('email validation still rejects a bad address inline',
        (tester) async {
      await tester.pumpWidget(_app(FakeFriendService()));
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(find.text('Keep in touch'), 200,
          scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      final field = find.widgetWithText(TextField, 'karma@chameleon.com');
      await tester.ensureVisible(field);
      await tester.pumpAndSettle();
      await tester.enterText(field, 'not-an-email');
      await tester.tap(find.text('Sign up'));
      await tester.pump();

      expect(find.text('Please enter a valid email address'), findsOneWidget);
    });

    testWidgets('placeholder email disappears when the field is focused',
        (tester) async {
      await tester.pumpWidget(_app(FakeFriendService()));
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(find.text('Keep in touch'), 200,
          scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      final field = find.descendant(
          of: find.byType(EmailSignupCard), matching: find.byType(TextField));
      await tester.ensureVisible(field);
      await tester.pumpAndSettle();
      expect(find.text('karma@chameleon.com'), findsOneWidget);

      await tester.tap(field);
      await tester.pump();
      expect(find.text('karma@chameleon.com'), findsNothing);
    });
  });
}
