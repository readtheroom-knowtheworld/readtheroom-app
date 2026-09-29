// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The chat overlay and the Community tab's unread badge (WP-F,
// networks-update-design §5.4). Pumped against a fake FriendChatService — no
// Supabase, no Realtime — so the three event shapes, the lick cooldown and the
// badge are covered without a backend.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:read_the_room/src/screens/main_screen.dart';
import 'package:read_the_room/src/widgets/chameleon_lick_icon.dart';
import 'package:read_the_room/src/services/friend_chat_service.dart';
import 'package:read_the_room/src/services/friend_nickname_service.dart';
import 'package:read_the_room/src/services/friend_service.dart';
import 'package:read_the_room/src/utils/friend_chat_logic.dart';
import 'package:read_the_room/src/utils/friend_logic.dart';
import 'package:read_the_room/src/widgets/friend_chat_overlay.dart';

const String kMe = 'me-uuid';
const String kPal = 'pal-uuid';

/// A FriendChatService with a fixed timeline and recorded no-op RPCs.
class FakeChatService extends FriendChatService {
  FakeChatService({
    List<FriendEvent> events = const [],
    this.unread = 0,
    this.cooldown = Duration.zero,
  })  : _events = events,
        super(listenToAuth: false, enableRealtime: false);

  final List<FriendEvent> _events;
  final int unread;
  final Duration cooldown;

  final List<String> calls = [];

  @override
  String? get viewerId => kMe;

  @override
  bool get isAuthenticated => true;

  @override
  List<FriendEvent> timelineFor(String friendId) => _events;

  @override
  List<FriendChatEntry> entriesFor(String friendId) =>
      buildChatEntries(_events);

  @override
  int unreadFor(String friendId) => unread;

  @override
  int get totalUnreadCount => unread;

  @override
  bool get hasUnread => unread > 0;

  @override
  Duration lickCooldownFor(String friendId, {DateTime? now}) => cooldown;

  @override
  bool canLick(String friendId, {DateTime? now}) => cooldown == Duration.zero;

  @override
  bool isLoadingTimeline(String friendId) => false;

  @override
  bool hasMore(String friendId) => false;

  @override
  Future<void> loadTimeline(String friendId, {bool loadMore = false}) async {
    calls.add('timeline:$friendId');
  }

  @override
  Future<void> markRead(String friendId) async => calls.add('read:$friendId');

  @override
  Future<void> loadUnreadCounts() async {}

  @override
  Future<FriendChatResult> sendLick(String friendId, {String surface = 'chat_overlay'}) async {
    calls.add('lick:$friendId');
    return const FriendChatResult.ok();
  }
}

/// A FriendService holding one accepted friend.
class FakeFriends extends FriendService {
  FakeFriends({Friend? friend})
      : _friend = friend ??
            const Friend(
              userId: kPal,
              username: 'pal',
              status: FriendStatus.accepted,
            ),
        super(listenToAuth: false);

  final Friend _friend;
  final List<String> calls = [];

  @override
  bool get isAuthenticated => true;

  @override
  List<Friend> get friends => [_friend];

  @override
  Friend? friendById(String userId) =>
      userId == _friend.userId ? _friend : null;

  @override
  Future<void> load() async {}

  @override
  Future<void> refresh() async {}

  @override
  Future<FriendResult> setFriendMuted(String userId, bool muted) async {
    calls.add('mute:$userId:$muted');
    return const FriendResult.ok();
  }

  @override
  Future<FriendResult> setCloseFriend(String userId, bool close, {String surface = 'community_menu'}) async {
    calls.add('close:$userId:$close');
    return const FriendResult.ok();
  }
}

final DateTime t0 = DateTime.utc(2026, 9, 11, 12, 0, 0);

FriendEvent _lick({String from = kPal, int minute = 0}) => FriendEvent(
      id: 'lick-$minute',
      senderId: from,
      recipientId: from == kMe ? kPal : kMe,
      kind: FriendEventKind.lick,
      createdAt: t0.add(Duration(minutes: minute)),
    );

FriendEvent _forward({
  String id = 'fwd-1',
  String from = kPal,
  int minute = 1,
  String prompt = 'Is cereal a soup?',
  bool hidden = false,
}) =>
    FriendEvent(
      id: id,
      senderId: from,
      recipientId: from == kMe ? kPal : kMe,
      kind: FriendEventKind.forward,
      createdAt: t0.add(Duration(minutes: minute)),
      questionId: 'q1',
      questionPrompt: prompt,
      questionType: 'approval_rating',
      questionHidden: hidden,
    );

FriendEvent _reaction({
  String id = 'rx-1',
  String from = kMe,
  int minute = 2,
  String target = 'fwd-1',
  String emoji = '😂',
}) =>
    FriendEvent(
      id: id,
      senderId: from,
      recipientId: from == kMe ? kPal : kMe,
      kind: FriendEventKind.reaction,
      createdAt: t0.add(Duration(minutes: minute)),
      targetEventId: target,
      emoji: emoji,
    );

/// Pumps a screen whose only job is to open the overlay.
Future<FakeChatService> _openOverlay(
  WidgetTester tester, {
  FakeChatService? chat,
  FakeFriends? friends,
  FriendNicknameService? nicknames,
}) async {
  final chatService = chat ?? FakeChatService();
  final friendService = friends ?? FakeFriends();

  await tester.pumpWidget(MultiProvider(
    providers: [
      ChangeNotifierProvider<FriendChatService>.value(value: chatService),
      ChangeNotifierProvider<FriendService>.value(value: friendService),
      ChangeNotifierProvider<FriendNicknameService>.value(
          value: nicknames ??
              FriendNicknameService(
                  viewerId: () => 'me', listenToAuth: false)),
    ],
    child: MaterialApp(
      theme: ThemeData(primaryColor: const Color(0xFF00897B)),
      home: MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => FriendChatOverlay.show(
                  context,
                  friendService.friends.first,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ),
  ));

  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return chatService;
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('chat overlay — the three event shapes (§5.4)', () {
    testWidgets('a lick renders as a chameleon-lick bubble', (tester) async {
      await _openOverlay(tester, chat: FakeChatService(events: [_lick()]));

      // One in the timeline, one on the bottom bar's button.
      expect(find.byType(ChameleonLickIcon), findsNWidgets(2));
      expect(find.text('Lick'), findsOneWidget);
    });

    testWidgets('a forward renders its prompt and a react affordance',
        (tester) async {
      await _openOverlay(tester, chat: FakeChatService(events: [_forward()]));

      expect(find.text('Is cereal a soup?'), findsOneWidget);
      expect(find.text('Tap to answer'), findsOneWidget);
      // Received forwards can be reacted to.
      expect(find.text('React'), findsOneWidget);
    });

    testWidgets('your own forward has no react affordance', (tester) async {
      await _openOverlay(tester,
          chat: FakeChatService(events: [_forward(from: kMe)]));

      expect(find.text('Is cereal a soup?'), findsOneWidget);
      expect(find.text('React'), findsNothing);
    });

    testWidgets('a reaction renders attached beneath its forward',
        (tester) async {
      await _openOverlay(tester, chat: FakeChatService(events: [
        _forward(),
        _reaction(emoji: '😂'),
        _reaction(id: 'rx-2', from: kPal, emoji: '❤️', minute: 3),
      ]));

      expect(find.text('Is cereal a soup?'), findsOneWidget);
      expect(find.text('😂'), findsOneWidget);
      expect(find.text('❤️'), findsOneWidget);
      // Attached, not a row of its own: no orphan caption.
      expect(find.text('on an earlier question'), findsNothing);
    });

    testWidgets('an orphaned reaction still renders, labelled', (tester) async {
      await _openOverlay(tester,
          chat: FakeChatService(events: [_reaction(target: 'gone')]));

      expect(find.text('😂'), findsOneWidget);
      expect(find.text('on an earlier question'), findsOneWidget);
    });

    testWidgets('a moderated forward shows a tombstone and cannot be opened',
        (tester) async {
      await _openOverlay(tester,
          chat: FakeChatService(events: [_forward(hidden: true)]));

      expect(find.text('This question is no longer available'), findsOneWidget);
      expect(find.text('Is cereal a soup?'), findsNothing);
      expect(find.text('Tap to answer'), findsNothing);
      expect(find.text('React'), findsNothing);
    });

    testWidgets('all three shapes coexist in one timeline', (tester) async {
      await _openOverlay(tester, chat: FakeChatService(events: [
        _lick(),
        _forward(),
        _reaction(),
      ]));

      // The lick bubble plus the bottom bar's button.
      expect(find.byType(ChameleonLickIcon), findsNWidgets(2));
      expect(find.text('Is cereal a soup?'), findsOneWidget);
      expect(find.text('😂'), findsOneWidget);
    });

    testWidgets('an empty chat explains what it is for', (tester) async {
      await _openOverlay(tester);
      expect(find.text('No words here'), findsOneWidget);
    });
  });

  group('chat overlay — opening and the lick button', () {
    testWidgets('opening reads the chat and loads the first page',
        (tester) async {
      final chat = await _openOverlay(
          tester, chat: FakeChatService(events: [_lick()], unread: 2));

      expect(chat.calls, contains('read:$kPal'));
      expect(chat.calls, contains('timeline:$kPal'));
    });

    testWidgets('the lick button sends when allowed', (tester) async {
      final chat = await _openOverlay(tester);

      await tester.tap(find.text('Lick'));
      await tester.pumpAndSettle();

      expect(chat.calls, contains('lick:$kPal'));
    });

    testWidgets('cooling down disables the button and shows a countdown',
        (tester) async {
      final chat = await _openOverlay(
        tester,
        chat: FakeChatService(cooldown: const Duration(minutes: 4, seconds: 5)),
      );

      expect(find.text('Lick in 4:05'), findsOneWidget);
      expect(find.text('Lick'), findsNothing);

      final button = tester.widget<ElevatedButton>(
        find.ancestor(
          of: find.text('Lick in 4:05'),
          matching: find.byType(ElevatedButton),
        ),
      );
      expect(button.onPressed, isNull);

      await tester.tap(find.text('Lick in 4:05'), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(chat.calls, isNot(contains('lick:$kPal')));
    });
  });

  group('chat overlay — header', () {
    testWidgets('shows the handle and the close-friend toggle only',
        (tester) async {
      final friends = FakeFriends();
      await _openOverlay(tester, friends: friends);

      expect(find.text('@pal'), findsOneWidget);
      expect(find.byIcon(Icons.favorite_border_rounded), findsOneWidget);
      // No per-friend mute: notifications are all-or-nothing.
      expect(find.byIcon(Icons.notifications_none), findsNothing);
    });

    testWidgets('the close-friend toggle calls the friend service',
        (tester) async {
      final friends = FakeFriends();
      await _openOverlay(tester, friends: friends);

      await tester.tap(find.byIcon(Icons.favorite_border_rounded));
      await tester.pumpAndSettle();

      expect(friends.calls, ['close:$kPal:true']);
    });

    testWidgets('a one-sided close friend shows the sharing line and the '
        'toggled star', (tester) async {
      final friends = FakeFriends(
        friend: const Friend(
          userId: kPal,
          username: 'pal',
          status: FriendStatus.accepted,
          isClose: true,
          muted: true,
        ),
      );
      await _openOverlay(tester, friends: friends);

      expect(find.text('Sharing your answers with them'), findsOneWidget);
      expect(find.byIcon(Icons.favorite_rounded), findsOneWidget);
      // Per-friend mute has no UI (notifications are all-or-nothing).
      expect(find.byIcon(Icons.notifications_off), findsNothing);
      expect(find.byIcon(Icons.notifications_none), findsNothing);
    });

    testWidgets('has no close button; drag or tap outside dismisses it',
        (tester) async {
      await _openOverlay(tester);
      expect(find.byIcon(Icons.close), findsNothing);
      expect(find.byTooltip('Close'), findsNothing);
    });

    testWidgets('set nickname from the overflow menu shows in the header',
        (tester) async {
      final store =
          FriendNicknameService(viewerId: () => 'me', listenToAuth: false);
      await _openOverlay(tester, nicknames: store);

      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Set nickname'));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const ValueKey('friend-nickname-field')), 'Bestie');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(find.text('@pal'), findsOneWidget);
      expect(find.text('(Bestie)'), findsOneWidget);
      expect(store.nicknameFor(kPal), 'Bestie');
    });

    testWidgets('block is in the overflow menu and confirms first',
        (tester) async {
      final friends = FakeFriends();
      await _openOverlay(tester, friends: friends);

      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Block'));
      await tester.pumpAndSettle();

      expect(find.text('Block this chameleon?'), findsOneWidget);

      // Cancelling blocks nobody.
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(friends.calls, isEmpty);
    });
  });

  group('chat overlay — phone width', () {
    testWidgets('lays out at 400 px with a long handle and no overflow',
        (tester) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      // A maximum-length handle (20 chars, §5.1) next to three header controls
      // is the worst case for the header row.
      final friends = FakeFriends(
        friend: const Friend(
          userId: kPal,
          username: 'chameleon_maximilian',
          status: FriendStatus.accepted,
          isClose: true,
          muted: true,
        ),
      );
      await _openOverlay(
        tester,
        friends: friends,
        chat: FakeChatService(
          events: [_lick(), _forward(prompt: 'Is cereal a soup? ' * 6)],
          cooldown: const Duration(minutes: 9, seconds: 59),
        ),
      );

      // A RenderFlex overflow throws in tests, so reaching here is the
      // assertion; these confirm it actually rendered.
      expect(tester.takeException(), isNull);
      expect(find.text('@chameleon_maximilian'), findsOneWidget);
      expect(find.text('Lick in 9:59'), findsOneWidget);
    });
  });

  group('Community tab unread badge', () {
    Widget badge(FakeChatService chat) => MultiProvider(
          providers: [
            ChangeNotifierProvider<FriendChatService>.value(value: chat),
          ],
          child: MaterialApp(
            theme: ThemeData(primaryColor: const Color(0xFF00897B)),
            home: const Scaffold(body: Center(child: CommunityTabIcon())),
          ),
        );

    testWidgets('hidden with nothing unread', (tester) async {
      await tester.pumpWidget(badge(FakeChatService()));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.groups_outlined), findsOneWidget);
      expect(find.byKey(const ValueKey(kCommunityUnreadDotKey)), findsNothing);
    });

    testWidgets('shown once something is unread', (tester) async {
      await tester.pumpWidget(badge(FakeChatService(unread: 3)));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey(kCommunityUnreadDotKey)), findsOneWidget);
    });

    testWidgets('renders the plain icon when the service is not in the tree',
        (tester) async {
      // A frame before the provider tree exists must not throw.
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: Center(child: CommunityTabIcon())),
      ));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.groups_outlined), findsOneWidget);
      expect(find.byKey(const ValueKey(kCommunityUnreadDotKey)), findsNothing);
    });
  });
}
