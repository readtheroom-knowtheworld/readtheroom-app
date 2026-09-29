// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Debug-only "Demo friends" mode (feature-documentation/
// demo-friends-mode-2026-09-11.md): the release-safety gate, the seeded graph
// and chat, the simulated two-way replies and their push copy, and the
// Community tab's amber marker.
//
// Everything here runs with no Supabase and no Realtime: the demo services make
// no backend calls at all, and the notification sink is injected so a simulated
// push is recorded rather than drawn.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:read_the_room/src/screens/community_screen.dart';
import 'package:read_the_room/src/widgets/chameleon_lick_icon.dart';
import 'package:read_the_room/src/services/demo/demo_friend_chat_service.dart';
import 'package:read_the_room/src/services/demo/demo_friend_service.dart';
import 'package:read_the_room/src/services/demo/demo_friends_data.dart';
import 'package:read_the_room/src/services/friend_chat_service.dart';
import 'package:read_the_room/src/services/friend_service.dart';
import 'package:read_the_room/src/services/profile_service.dart';
import 'package:read_the_room/src/utils/demo_friends_mode.dart';
import 'package:read_the_room/src/utils/friend_chat_logic.dart';
import 'package:read_the_room/src/utils/friend_logic.dart';
import 'package:read_the_room/src/widgets/demo_friends_banner.dart';
import 'package:read_the_room/src/widgets/network_demo_card.dart';

/// Records simulated pushes instead of asking the OS to draw them.
class _PushRecorder {
  final List<DemoFriendNotification> pushes = [];

  Future<void> call(DemoFriendNotification notification) async {
    pushes.add(notification);
  }

  DemoFriendNotification get last => pushes.last;
}

/// Captures the scheduled reply so a test can fire it on demand instead of
/// waiting 1.5–3 s of wall clock.
class _ManualScheduler {
  final List<void Function()> pending = [];
  final List<Duration> delays = [];

  void call(Duration delay, void Function() run) {
    delays.add(delay);
    pending.add(run);
  }

  void runAll() {
    final queued = List<void Function()>.from(pending);
    pending.clear();
    for (final run in queued) {
      run();
    }
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  // ---------------------------------------------------------------------------
  // The gate
  // ---------------------------------------------------------------------------

  group('DemoFriendsMode release safety', () {
    test('a release build cannot turn it on', () async {
      final mode = DemoFriendsMode(debugMode: false);

      expect(mode.isAvailable, isFalse);
      expect(mode.enabled, isFalse);

      final effective = await mode.setEnabled(true);
      expect(effective, isFalse, reason: 'setEnabled must refuse in release');
      expect(mode.enabled, isFalse);

      // It did not even persist the intent.
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(DemoFriendsMode.prefsKey), isNull);
    });

    test('a stored true from a debug build still reads false in release',
        () async {
      SharedPreferences.setMockInitialValues({
        DemoFriendsMode.prefsKey: true,
      });

      final release = DemoFriendsMode(debugMode: false);
      await release.load();
      expect(release.enabled, isFalse);

      // The same stored value is honoured in debug, so the test above is about
      // the clamp and not about a failed read.
      final debug = DemoFriendsMode(debugMode: true);
      await debug.load();
      expect(debug.enabled, isTrue);
    });

    test('a debug build persists the flag and notifies', () async {
      final mode = DemoFriendsMode(debugMode: true);
      var notifications = 0;
      mode.addListener(() => notifications++);

      expect(await mode.setEnabled(true), isTrue);
      expect(mode.enabled, isTrue);
      expect(notifications, 1);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(DemoFriendsMode.prefsKey), isTrue);

      // Idempotent: setting the same value again is not a change.
      expect(await mode.setEnabled(true), isTrue);
      expect(notifications, 1);

      expect(await mode.setEnabled(false), isFalse);
      expect(mode.enabled, isFalse);
      expect(notifications, 2);
    });
  });

  // ---------------------------------------------------------------------------
  // Push copy — ported verbatim from the edge function's copy.ts
  // ---------------------------------------------------------------------------

  group('simulated push copy matches the edge function', () {
    test('every type renders the documented body', () {
      expect(
        demoNotificationCopy(DemoFriendPushType.friendRequest,
                actorId: 'a', handle: 'pip_prism')
            .body,
        '@pip_prism wants to be friends',
      );
      expect(
        demoNotificationCopy(DemoFriendPushType.friendAccepted,
                actorId: 'a', handle: 'pip_prism')
            .body,
        '@pip_prism accepted your request',
      );

      final lick = demoNotificationCopy(DemoFriendPushType.lick,
          actorId: 'a', handle: 'basil_basks');
      expect(lick.title, '🦎 Lick');
      expect(lick.body, '@basil_basks licked you 🦎');

      expect(
        demoNotificationCopy(DemoFriendPushType.lick,
                actorId: 'a', handle: 'basil_basks', lickCount: 3)
            .body,
        '3 licks from @basil_basks',
      );

      final forward = demoNotificationCopy(DemoFriendPushType.forward,
          actorId: 'a', handle: 'mango_morphs', prompt: 'Is a hotdog a sandwich?');
      expect(forward.title, '🦎 A question for you');
      expect(forward.body,
          '@mango_morphs sent you a question: Is a hotdog a sandwich?');

      final reaction = demoNotificationCopy(DemoFriendPushType.reaction,
          actorId: 'a', handle: 'sunny_scales', emoji: '😂');
      expect(reaction.title, '🦎 New reaction');
      expect(reaction.body, '@sunny_scales reacted 😂 to your question');
    });

    test('missing facts degrade rather than break', () {
      expect(
        demoNotificationCopy(DemoFriendPushType.lick, actorId: 'a', handle: null)
            .body,
        'Someone licked you 🦎',
      );
      expect(
        demoNotificationCopy(DemoFriendPushType.forward,
                actorId: 'a', handle: 'pip', prompt: '   ')
            .body,
        '@pip sent you a question',
      );
      expect(
        demoNotificationCopy(DemoFriendPushType.reaction,
                actorId: 'a', handle: 'pip', emoji: null)
            .body,
        '@pip reacted to your question',
      );
    });

    test('truncatePrompt collapses whitespace and ellipsises at 120', () {
      expect(demoTruncatePrompt('  a   b \n c '), 'a b c');
      expect(demoTruncatePrompt(null), '');
      expect(demoTruncatePrompt('y' * 120).length, 120);
      expect(demoTruncatePrompt('y' * 120).endsWith('…'), isFalse);

      final long = demoTruncatePrompt('y' * 200);
      expect(long.length, 120);
      expect(long.endsWith('…'), isTrue);
    });
  });

  // ---------------------------------------------------------------------------
  // Seeded graph
  // ---------------------------------------------------------------------------

  group('DemoFriendService seeded graph', () {
    late _PushRecorder pushes;
    late DemoFriendService service;

    setUp(() {
      pushes = _PushRecorder();
      service = DemoFriendService(notificationSink: pushes.call);
    });

    tearDown(() => service.dispose());

    test('is authenticated and loaded without a backend', () {
      expect(service.isAuthenticated, isTrue);
      expect(service.isLoaded, isTrue);
      expect(service.isLoading, isFalse);
    });

    test('partitions into two regular, two close, one in, one out', () {
      final sections = service.sections;

      expect(sections.friends.map((f) => f.userId),
          containsAll(<String>[kDemoRegularAId, kDemoRegularBId]));
      expect(sections.friends, hasLength(2));

      expect(sections.closeFriends.map((f) => f.userId),
          containsAll(<String>[kDemoCloseMutualId, kDemoCloseOneSidedId]));
      expect(sections.closeFriends, hasLength(2));

      expect(sections.incoming.map((f) => f.userId), [kDemoIncomingId]);
      expect(sections.outgoing.map((f) => f.userId), [kDemoOutgoingId]);

      expect(service.friendCount, 4);
      expect(service.hasAnyFriends, isTrue);
      expect(service.hasPending, isTrue);
    });

    test('one close friend is mutual and one is close-for-you-only', () {
      expect(service.friendById(kDemoCloseMutualId)!.mutualClose, isTrue);
      expect(service.friendById(kDemoCloseOneSidedId)!.isClose, isTrue);
      expect(service.friendById(kDemoCloseOneSidedId)!.mutualClose, isFalse,
          reason: 'the one-sided "sharing your answers with them" copy needs this row');
    });

    test('the incoming row really is incoming and the outgoing one outgoing',
        () {
      expect(service.friendById(kDemoIncomingId)!.isIncomingRequest, isTrue);
      expect(service.friendById(kDemoOutgoingId)!.isOutgoingRequest, isTrue);
    });

    test('demo ids can never be read as a friend QR token', () {
      for (final id in kDemoFriendHandles.keys.followedBy([kDemoViewerId])) {
        expect(isValidFriendToken(id), isFalse);
        expect(parseFriendToken('readtheroom://friend/$id'), isNull,
            reason: 'a demo chat deep link must not parse as a QR token');
      }
    });

    test('the first load announces the pending incoming request, once',
        () async {
      await service.load();
      expect(pushes.pushes, hasLength(1));
      expect(pushes.last.title, '🦎 New friend request');
      expect(pushes.last.body, '@pip_prism wants to be friends');
      expect(pushes.last.actorId, kDemoIncomingId);

      await service.load();
      await service.refresh();
      expect(pushes.pushes, hasLength(1));
    });
  });

  group('DemoFriendService mutations', () {
    late _PushRecorder pushes;
    late DemoFriendService service;
    late int notifications;

    setUp(() {
      pushes = _PushRecorder();
      service = DemoFriendService(notificationSink: pushes.call);
      notifications = 0;
      service.addListener(() => notifications++);
    });

    tearDown(() => service.dispose());

    test('accepting an incoming request promotes it and pushes the accept copy',
        () async {
      final result = await service.respondToRequest(kDemoIncomingId, true);

      expect(result.success, isTrue);
      expect(service.friendById(kDemoIncomingId)!.isAccepted, isTrue);
      expect(service.sections.incoming, isEmpty);
      expect(notifications, 1);

      expect(pushes.last.title, '🦎 You have a new friend');
      expect(pushes.last.body, '@pip_prism accepted your request');
      expect(pushes.last.actorId, kDemoIncomingId);
    });

    test('declining and cancelling drop the row silently', () async {
      expect((await service.respondToRequest(kDemoIncomingId, false)).success,
          isTrue);
      expect(service.friendById(kDemoIncomingId), isNull);

      expect((await service.cancelRequest(kDemoOutgoingId)).success, isTrue);
      expect(service.friendById(kDemoOutgoingId), isNull);

      expect(pushes.pushes, isEmpty, reason: 'nobody is told (§5.2)');
      expect(notifications, 2);
    });

    test('close friend is mutual only for a friend who added you back',
        () async {
      // The one-sided row stays one-sided however often it is toggled.
      expect((await service.setCloseFriend(kDemoRegularAId, true)).success,
          isTrue);
      expect(service.friendById(kDemoRegularAId)!.isClose, isTrue);
      expect(service.friendById(kDemoRegularAId)!.mutualClose, isFalse);

      // The reciprocating row goes back to mutual when re-added.
      expect((await service.setCloseFriend(kDemoCloseMutualId, false)).success,
          isTrue);
      expect(service.friendById(kDemoCloseMutualId)!.isClose, isFalse);
      expect(service.friendById(kDemoCloseMutualId)!.mutualClose, isFalse);

      expect((await service.setCloseFriend(kDemoCloseMutualId, true)).success,
          isTrue);
      expect(service.friendById(kDemoCloseMutualId)!.mutualClose, isTrue);

      expect(notifications, 3);
    });

    test('mute, unfriend and block all mutate and notify', () async {
      expect((await service.setFriendMuted(kDemoRegularAId, true)).success,
          isTrue);
      expect(service.friendById(kDemoRegularAId)!.muted, isTrue);

      expect((await service.unfriend(kDemoRegularBId)).success, isTrue);
      expect(service.friendById(kDemoRegularBId), isNull);

      expect((await service.blockUser(kDemoCloseOneSidedId)).success, isTrue);
      expect(service.friendById(kDemoCloseOneSidedId), isNull);

      expect(notifications, 3);
      expect(service.friendCount, 2);
    });

    test('a close-friend or mute call on a non-friend fails the same way the '
        'server would', () async {
      final close = await service.setCloseFriend('nobody', true);
      expect(close.success, isFalse);
      expect(close.error, FriendError.notFriends);

      final mute = await service.setFriendMuted(kDemoIncomingId, true);
      expect(mute.success, isFalse, reason: 'a pending row is not a friendship');
      expect(mute.error, FriendError.notFriends);
    });

    test('handle lookup always resolves, and a request becomes outgoing',
        () async {
      final lookup = await service.lookupByUsername('@WhoEver');
      expect(lookup.success, isTrue);
      expect(lookup.found, isTrue);
      expect(lookup.userId, kDemoLookupId);
      expect(lookup.username, kDemoLookupHandle);

      expect((await service.sendFriendRequest(kDemoLookupId)).success, isTrue);
      expect(service.sections.outgoing.map((f) => f.userId),
          contains(kDemoLookupId));

      // A second request to the same person is refused, as the RPC would.
      final again = await service.sendFriendRequest(kDemoLookupId);
      expect(again.error, FriendError.alreadyPending);
    });

    test('an empty handle finds nobody', () async {
      final lookup = await service.lookupByUsername('   ');
      expect(lookup.success, isTrue);
      expect(lookup.found, isFalse);
    });

    test('the QR token is token-shaped so the dialog can render it', () async {
      final token = await service.createQrToken();
      expect(token, isNotNull);
      expect(isValidFriendToken(token!.token), isTrue);
      expect(token.expiresAt, isNotNull);

      final added = await service.addFriendViaQr(token.token);
      expect(added.success, isTrue);
      expect(service.friendById(kDemoLookupId)!.isAccepted, isTrue);
    });

    test('DemoProfileService gives the viewer a handle and an avatar', () {
      final profile = DemoProfileService();
      addTearDown(profile.dispose);
      expect(profile.isAuthenticated, isTrue);
      expect(profile.username, kDemoViewerHandle);
      expect(profile.avatarId, kDemoViewerAvatarId);
    });
  });

  // ---------------------------------------------------------------------------
  // Seeded chat + simulated replies
  // ---------------------------------------------------------------------------

  group('DemoFriendChatService seeded chat', () {
    late DemoFriendChatService chat;

    setUp(() {
      chat = DemoFriendChatService(
        notificationSink: _PushRecorder().call,
        scheduler: _ManualScheduler().call,
      );
    });

    tearDown(() => chat.dispose());

    test('every accepted friend starts with a lick, a forward and a reaction',
        () {
      for (final friendId in kDemoAcceptedFriendIds) {
        final events = chat.timelineFor(friendId);
        expect(events, hasLength(3), reason: friendId);
        expect(events.where((e) => e.isLick), hasLength(1));
        expect(events.where((e) => e.isForward), hasLength(1));
        expect(events.where((e) => e.isReaction), hasLength(1));
      }
    });

    test('the seeded reaction hangs off the seeded forward', () {
      final entries = chat.entriesFor(kDemoCloseMutualId);
      final forward = entries.firstWhere((e) => e.event.isForward);
      expect(forward.reactions, hasLength(1));
      expect(forward.reactions.single.emoji, kDemoSeedReactionEmoji);
      // Reactions are folded into their forward, so the timeline is two rows.
      expect(entries, hasLength(2));
    });

    test('it opens with no phantom unread badges and a lickable button', () {
      expect(chat.totalUnreadCount, 0);
      expect(chat.hasUnread, isFalse);
      expect(chat.isUnreadLoaded, isTrue);
      expect(chat.canLick(kDemoCloseMutualId), isTrue);
      expect(chat.hasMore(kDemoCloseMutualId), isFalse);
      expect(chat.isLive, isFalse, reason: 'replies are local timers, not Realtime');
    });

    test('a pending friend has no seeded chat', () {
      expect(chat.timelineFor(kDemoIncomingId), isEmpty);
    });
  });

  group('DemoFriendChatService two-way simulation', () {
    late _PushRecorder pushes;
    late _ManualScheduler scheduler;
    late DemoFriendChatService chat;
    const friendId = kDemoRegularAId;

    setUp(() {
      pushes = _PushRecorder();
      scheduler = _ManualScheduler();
      chat = DemoFriendChatService(
        notificationSink: pushes.call,
        scheduler: scheduler.call,
      );
    });

    tearDown(() => chat.dispose());

    test('a lick is sent, schedules a reply, and the reply licks back',
        () async {
      var notifications = 0;
      chat.addListener(() => notifications++);

      final result = await chat.sendLick(friendId);
      expect(result.success, isTrue);
      expect(notifications, greaterThanOrEqualTo(1));

      // The outgoing lick is in the timeline immediately.
      final mine = chat
          .timelineFor(friendId)
          .where((e) => e.isLick && e.isMine(kDemoViewerId));
      expect(mine, hasLength(1));

      // A reply is queued inside the documented window, and nothing has
      // arrived or been pushed until it fires.
      expect(scheduler.pending, hasLength(1));
      expect(scheduler.delays.single,
          greaterThanOrEqualTo(kDemoReplyMinDelay));
      expect(scheduler.delays.single, lessThanOrEqualTo(kDemoReplyMaxDelay));
      expect(pushes.pushes, isEmpty);

      scheduler.runAll();
      await Future<void>.delayed(Duration.zero);

      // Their lick arrived through the same path Realtime would use: merged
      // into the timeline and counted against the tab's badge.
      final theirs = chat
          .timelineFor(friendId)
          .where((e) => e.isLick && !e.isMine(kDemoViewerId));
      expect(theirs, hasLength(2), reason: 'the seeded lick plus the reply');
      expect(chat.unreadFor(friendId), 1);
      expect(chat.hasUnread, isTrue);

      expect(pushes.last.title, '🦎 Lick');
      expect(pushes.last.body, '@basil_basks licked you 🦎');
      expect(pushes.last.actorId, friendId,
          reason: 'the payload must route to this friend\'s chat');
    });

    test('the lick cooldown still applies, shortened to the demo window',
        () async {
      expect(await chat.sendLick(friendId), isA<FriendChatResult>());

      final remaining = chat.lickCooldownFor(friendId);
      expect(remaining, greaterThan(Duration.zero));
      expect(remaining, lessThanOrEqualTo(kDemoLickCooldown));
      expect(chat.canLick(friendId), isFalse);

      // The countdown label the button shows is the production one.
      expect(lickCountdownLabel(remaining), isNotEmpty);

      final blocked = await chat.sendLick(friendId);
      expect(blocked.success, isFalse);
      expect(blocked.error, FriendChatError.lickCooldown);
      expect(blocked.retryAfter, isNotNull);
      expect(blocked.message, contains('to go'));

      // A blocked lick neither lands nor schedules a second reply.
      expect(scheduler.pending, hasLength(1));
    });

    test('the demo cooldown is much shorter than the real one', () {
      expect(kDemoLickCooldown, lessThan(kLickCooldown));
      expect(kDemoLickCooldown, const Duration(seconds: 20));
    });

    test('a forward is answered with a reaction attached to it', () async {
      final sent = await chat.forwardQuestion(
        friendId: friendId,
        questionId: kDemoForwardQuestionId,
      );
      expect(sent.success, isTrue);
      final forwardId = sent.event!.id;

      scheduler.runAll();
      await Future<void>.delayed(Duration.zero);

      final reaction = chat.timelineFor(friendId).firstWhere(
          (e) => e.isReaction && e.targetEventId == forwardId);
      expect(reaction.emoji, kDemoReplyReactionEmoji);
      expect(reaction.senderId, friendId);
      // The RPC copies the forward's question id onto its reactions.
      expect(reaction.questionId, kDemoForwardQuestionId);

      // It renders attached, not as a loose bubble.
      final entry = chat
          .entriesFor(friendId)
          .firstWhere((e) => e.event.id == forwardId);
      expect(entry.reactions.map((r) => r.emoji), contains(kDemoReplyReactionEmoji));

      expect(pushes.last.title, '🦎 New reaction');
      expect(pushes.last.body,
          '@basil_basks reacted $kDemoReplyReactionEmoji to your question');
    });

    test('a reaction is answered with a forward of their own', () async {
      final forward = chat
          .timelineFor(friendId)
          .firstWhere((e) => e.isForward);

      final reacted = await chat.react(
        friendId: friendId,
        targetEventId: forward.id,
        emoji: '🦎',
      );
      expect(reacted.success, isTrue);
      expect(reacted.event!.questionId, forward.questionId,
          reason: 'a reaction inherits its target forward\'s question');

      scheduler.runAll();
      await Future<void>.delayed(Duration.zero);

      final theirForward = chat.timelineFor(friendId).firstWhere(
          (e) => e.isForward && e.senderId == friendId);
      expect(theirForward.questionPrompt, kDemoForwardQuestionPrompt);
      expect(theirForward.isOpenableForward, isTrue);

      expect(pushes.last.title, '🦎 A question for you');
      expect(
        pushes.last.body,
        '@basil_basks sent you a question: $kDemoForwardQuestionPrompt',
      );
    });

    test('an empty emoji is refused without scheduling a reply', () async {
      final result =
          await chat.react(friendId: friendId, targetEventId: 'x', emoji: '  ');
      expect(result.success, isFalse);
      expect(result.error, FriendChatError.emojiRequired);
      expect(scheduler.pending, isEmpty);
    });

    test('an incoming event does not badge the chat that is on screen',
        () async {
      chat.setActiveFriend(friendId);
      expect(chat.activeFriendId, friendId);

      await chat.sendLick(friendId);
      scheduler.runAll();
      await Future<void>.delayed(Duration.zero);

      expect(chat.unreadFor(friendId), 0);
      expect(pushes.pushes, hasLength(1),
          reason: 'the push still fires — only the badge is skipped');

      chat.clearActiveFriend(friendId);
      expect(chat.activeFriendId, isNull);
    });

    test('markRead clears the badge and stamps the timeline', () async {
      await chat.sendLick(friendId);
      scheduler.runAll();
      await Future<void>.delayed(Duration.zero);
      expect(chat.unreadFor(friendId), 1);

      await chat.markRead(friendId);
      expect(chat.unreadFor(friendId), 0);
      expect(
        chat.timelineFor(friendId).where(
            (e) => e.recipientId == kDemoViewerId && e.isUnread),
        isEmpty,
      );
      expect(chat.calls, contains('read:$friendId'));
    });

    test('a blocked friend stops arriving, even mid-flight', () async {
      await chat.sendLick(friendId);
      expect(scheduler.pending, hasLength(1));

      chat.dropFriend(friendId);
      scheduler.runAll();
      await Future<void>.delayed(Duration.zero);

      expect(chat.timelineFor(friendId), isEmpty);
      expect(chat.unreadFor(friendId), 0);
      expect(pushes.pushes, isEmpty);
    });
  });

  // ---------------------------------------------------------------------------
  // The Community tab under the demo providers
  // ---------------------------------------------------------------------------

  group('Community tab in demo mode', () {
    late DemoFriendService friends;
    late DemoFriendChatService chat;

    setUp(() async {
      friends = DemoFriendService(notificationSink: _PushRecorder().call);
      chat = DemoFriendChatService(
        notificationSink: _PushRecorder().call,
        scheduler: _ManualScheduler().call,
      );
      await DemoFriendsMode.instance.setEnabled(true);
    });

    tearDown(() async {
      await DemoFriendsMode.instance.setEnabled(false);
      friends.dispose();
      chat.dispose();
    });

    Widget app() => MultiProvider(
          providers: [
            ChangeNotifierProvider<FriendService>.value(value: friends),
            ChangeNotifierProvider<ProfileService>.value(
                value: DemoProfileService()),
            ChangeNotifierProvider<FriendChatService>.value(value: chat),
          ],
          child: MaterialApp(
            theme: ThemeData(primaryColor: const Color(0xFF00897B)),
            home: const MediaQuery(
              data: MediaQueryData(disableAnimations: true),
              child: CommunityScreen(),
            ),
          ),
        );

    testWidgets('renders the amber marker above every section', (tester) async {
      tester.view.physicalSize = const Size(1000, 3000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      // The marker, with the shared DEMO badge.
      expect(find.byType(DemoFriendsBanner), findsOneWidget);
      expect(find.text(DemoFriendsBanner.label), findsOneWidget);
      expect(find.text('DEMO'), findsOneWidget);

      // Every section of the seeded graph.
      expect(find.text('Friend requests'), findsOneWidget);
      expect(find.text('Close friends'), findsNothing);
      expect(find.text('Friends'), findsOneWidget);

      expect(find.text('@pip_prism'), findsOneWidget);
      expect(find.text('@juno_jade'), findsOneWidget);
      expect(find.text('@curio_thechameleon'), findsOneWidget);
      expect(find.text('@basil_basks'), findsOneWidget);

      // The viewer's own identity, not "Pick a name".
      expect(find.text('@$kDemoViewerHandle'), findsOneWidget);

      // Both halves of the reciprocity copy are on screen at once.
      expect(find.text('Sharing answers'),
          findsOneWidget);
      expect(find.text('Sharing your answers'),
          findsOneWidget);

      // The marker sits above the identity card.
      expect(
        tester.getTopLeft(find.text(DemoFriendsBanner.label)).dy,
        lessThan(tester.getTopLeft(find.text('@$kDemoViewerHandle')).dy),
      );

      // The sample-network card would be a second, competing demo surface.
      expect(find.byType(NetworkDemoCard), findsNothing);
      expect(find.text('No friends yet'), findsNothing);
    });

    testWidgets('tapping a friend row opens the demo chat overlay',
        (tester) async {
      // The tab is a lazy ListView, so a short window never builds down as far
      // as the regular-friends section.
      tester.view.physicalSize = const Size(1000, 3000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      await tester.tap(find.text('@basil_basks'));
      await tester.pumpAndSettle();

      expect(find.text('Lick'), findsOneWidget);
      expect(find.byType(ChameleonLickIcon), findsWidgets);
      expect(find.text('Question'), findsOneWidget);
      // The seeded history is there to lick/react against.
      expect(find.text(kDemoForwardQuestionPrompt), findsOneWidget);
      expect(chat.calls, contains('read:$kDemoRegularAId'));
    });

    testWidgets('the marker is absent when the mode is off', (tester) async {
      await DemoFriendsMode.instance.setEnabled(false);

      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      expect(find.text(DemoFriendsBanner.label), findsNothing);
      expect(find.byType(DemoFriendsBanner), findsNothing);
      // (The grow-your-circle NetworkDemoCard may still show its own DEMO
      // badge here — that card is sample data by design, not the mode marker.)
    });
  });
}
