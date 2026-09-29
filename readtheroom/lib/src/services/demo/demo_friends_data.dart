// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Shared fixtures for debug-only "Demo friends" mode: the seeded graph, the
/// simulated-push copy, and the sink that shows it.
///
/// Dependency-free apart from the app's own pure logic libraries and
/// `NotificationService`, so the seed shape and the copy are unit-testable
/// without a backend. See
/// `feature-documentation/demo-friends-mode-2026-09-11.md`.
library;

import 'package:flutter/foundation.dart';

import '../../utils/friend_chat_logic.dart';
import '../../utils/friend_logic.dart';
import '../notification_service.dart';

// ---------------------------------------------------------------------------
// Ids and handles
// ---------------------------------------------------------------------------

/// The demo viewer's own id. Deliberately *not* 32 lowercase hex, so a
/// `readtheroom://friend/{id}` link built from a demo id can never be mistaken
/// for a friend **QR token** by `parseFriendToken` (which DeepLinkService
/// checks first).
const String kDemoViewerId = 'demo-you';

/// The demo viewer's handle and avatar, used by [DemoProfileService].
const String kDemoViewerHandle = 'you_demo';
const String kDemoViewerAvatarId = 'chameleon_03';

/// Ids of the seeded friends. Same no-hex-token rule as [kDemoViewerId].
const String kDemoCloseMutualId = 'demo-friend-curio';
const String kDemoCloseOneSidedId = 'demo-friend-sunny';
const String kDemoRegularAId = 'demo-friend-basil';
const String kDemoRegularBId = 'demo-friend-mango';
const String kDemoIncomingId = 'demo-friend-pip';
const String kDemoOutgoingId = 'demo-friend-juno';

/// The user [DemoFriendService.lookupByUsername] always resolves to, so the
/// "add by handle" sheet has something to find.
const String kDemoLookupId = 'demo-friend-lookup';
const String kDemoLookupHandle = 'nova_nictitates';
const String kDemoLookupAvatarId = 'chameleon_08';

/// 32 lowercase hex — the exact shape `create_friend_qr_token()` mints (and
/// `isValidFriendToken` demands), so the QR dialog renders a real-looking code.
const String kDemoQrToken = 'deadbeefcafef00d0123456789abcdef';

/// The friend the demo ids belong to, for log lines and the docs table.
const Map<String, String> kDemoFriendHandles = <String, String>{
  kDemoCloseMutualId: 'curio_thechameleon',
  kDemoCloseOneSidedId: 'sunny_scales',
  kDemoRegularAId: 'basil_basks',
  kDemoRegularBId: 'mango_morphs',
  kDemoIncomingId: 'pip_prism',
  kDemoOutgoingId: 'juno_jade',
  kDemoLookupId: kDemoLookupHandle,
};

/// Friends who have *already* marked the viewer as a close friend, so toggling
/// "close friend" on them becomes mutual and anyone else stays one-sided. This
/// is what makes both halves of the reciprocity copy reachable in demo.
const Set<String> kDemoReciprocatingCloseFriends = <String>{kDemoCloseMutualId};

/// The lick cooldown in demo mode. The real window is
/// [kLickCooldown] (10 minutes), which is far too long to watch; 20 s keeps the
/// countdown UI on the same code path while staying testable by hand. Stated in
/// the Community banner's tooltip so the shortened window is never mistaken for
/// the product rule.
const Duration kDemoLickCooldown = Duration(seconds: 20);

/// How long the dummy friend "thinks" before replying.
const Duration kDemoReplyMinDelay = Duration(milliseconds: 1500);
const Duration kDemoReplyMaxDelay = Duration(milliseconds: 3000);

/// The question the seeded forwards point at. There is no backend in demo mode,
/// so there is no real QOTD to forward: this is one of the existing sample
/// questions from `demo_network_data.dart`, carried in the event itself so the
/// forward card renders a real prompt and type badge.
const String kDemoForwardQuestionId = 'demo-approval';
const String kDemoForwardQuestionPrompt =
    'Should pineapple be allowed anywhere near a pizza?';
const String kDemoForwardQuestionType = 'approval';

/// The emoji the dummy friends react with, and the one they pick when replying
/// to a forward of yours.
const String kDemoSeedReactionEmoji = '🔥';
const String kDemoReplyReactionEmoji = '😂';

// ---------------------------------------------------------------------------
// Seeded graph
// ---------------------------------------------------------------------------

/// The graph the Community tab renders in demo mode: two regular friends, one
/// mutual close friend, one close-for-you-only friend (so the "not yet mutual"
/// copy shows), one incoming request and one outgoing request.
///
/// [now] anchors `created_at`, which only drives the pending sections' newest-
/// first ordering.
List<Friend> buildDemoFriendGraph({required DateTime now}) {
  return <Friend>[
    Friend(
      userId: kDemoCloseMutualId,
      username: kDemoFriendHandles[kDemoCloseMutualId],
      avatarId: 'chameleon_01',
      status: FriendStatus.accepted,
      isClose: true,
      mutualClose: true,
      streak: 12,
      createdAt: now.subtract(const Duration(days: 40)),
      lastEventAt: now.subtract(const Duration(days: 1)),
    ),
    Friend(
      userId: kDemoCloseOneSidedId,
      username: kDemoFriendHandles[kDemoCloseOneSidedId],
      avatarId: 'chameleon_05',
      status: FriendStatus.accepted,
      isClose: true,
      // Close for you only — they have not added you back.
      mutualClose: false,
      streak: 3,
      createdAt: now.subtract(const Duration(days: 21)),
      lastEventAt: now.subtract(const Duration(hours: 2)),
    ),
    Friend(
      userId: kDemoRegularAId,
      username: kDemoFriendHandles[kDemoRegularAId],
      avatarId: 'chameleon_02',
      status: FriendStatus.accepted,
      streak: 7,
      createdAt: now.subtract(const Duration(days: 30)),
    ),
    Friend(
      userId: kDemoRegularBId,
      username: kDemoFriendHandles[kDemoRegularBId],
      avatarId: 'chameleon_04',
      status: FriendStatus.accepted,
      createdAt: now.subtract(const Duration(days: 9)),
      lastEventAt: now.subtract(const Duration(days: 3)),
    ),
    Friend(
      userId: kDemoIncomingId,
      username: kDemoFriendHandles[kDemoIncomingId],
      avatarId: 'chameleon_06',
      status: FriendStatus.pending,
      // requested_by == the row's own user_id ⇒ incoming (friend_logic.dart).
      requestedBy: kDemoIncomingId,
      createdAt: now.subtract(const Duration(hours: 4)),
    ),
    Friend(
      userId: kDemoOutgoingId,
      username: kDemoFriendHandles[kDemoOutgoingId],
      avatarId: 'chameleon_07',
      status: FriendStatus.pending,
      requestedBy: kDemoViewerId,
      createdAt: now.subtract(const Duration(days: 2)),
    ),
  ];
}

/// Ids of the accepted friends in [buildDemoFriendGraph] — the ones that get a
/// seeded chat history.
const List<String> kDemoAcceptedFriendIds = <String>[
  kDemoCloseMutualId,
  kDemoCloseOneSidedId,
  kDemoRegularAId,
  kDemoRegularBId,
];

/// A small pre-existing chat with one friend: a lick from them, a forward of
/// the sample question from you, and their reaction to it.
///
/// All three are stamped read, so the demo does not open with phantom unread
/// badges on every row — the badge is exercised by the *simulated replies*
/// instead.
List<FriendEvent> buildDemoChatHistory({
  required String friendId,
  required DateTime now,
}) {
  final lickAt = now.subtract(const Duration(hours: 5));
  final forwardAt = now.subtract(const Duration(hours: 4));
  final reactionAt = now.subtract(const Duration(hours: 3, minutes: 50));
  final read = now.subtract(const Duration(hours: 3));

  return <FriendEvent>[
    FriendEvent(
      id: 'demo-$friendId-lick',
      senderId: friendId,
      recipientId: kDemoViewerId,
      kind: FriendEventKind.lick,
      createdAt: lickAt,
      readAt: read,
    ),
    FriendEvent(
      id: 'demo-$friendId-forward',
      senderId: kDemoViewerId,
      recipientId: friendId,
      kind: FriendEventKind.forward,
      createdAt: forwardAt,
      questionId: kDemoForwardQuestionId,
      questionPrompt: kDemoForwardQuestionPrompt,
      questionType: kDemoForwardQuestionType,
    ),
    FriendEvent(
      id: 'demo-$friendId-reaction',
      senderId: friendId,
      recipientId: kDemoViewerId,
      kind: FriendEventKind.reaction,
      createdAt: reactionAt,
      // The RPC copies the forward's question id onto its reactions.
      questionId: kDemoForwardQuestionId,
      targetEventId: 'demo-$friendId-forward',
      emoji: kDemoSeedReactionEmoji,
      readAt: read,
    ),
  ];
}

// ---------------------------------------------------------------------------
// Simulated push copy
// ---------------------------------------------------------------------------

/// The outbox `event_type` vocabulary the copy switch covers.
enum DemoFriendPushType { friendRequest, friendAccepted, lick, forward, reaction }

/// One simulated push: exactly what the edge function would have sent, plus the
/// actor whose chat a tap should open.
@immutable
class DemoFriendNotification {
  const DemoFriendNotification({
    required this.title,
    required this.body,
    required this.actorId,
  });

  final String title;
  final String body;

  /// Routed as `friend_{actorId}` → `readtheroom://friend/{actorId}` → the
  /// Community tab plus that friend's overlay, the same path a real push takes.
  final String actorId;

  @override
  String toString() => 'DemoFriendNotification($title / $body / $actorId)';
}

/// Where a simulated push goes. Injectable so unit tests can record pushes
/// instead of asking the OS to draw them.
typedef DemoNotificationSink = Future<void> Function(
    DemoFriendNotification notification);

/// Max prompt length in a forward push, ported verbatim from the edge
/// function's `copy.ts` (`MAX_PROMPT_CHARS`).
const int kDemoMaxPromptChars = 120;

/// Whitespace-collapses and ellipsises a prompt exactly as `copy.ts`'s
/// `truncatePrompt` does, so demo copy cannot drift from production copy.
String demoTruncatePrompt(String? prompt, {int max = kDemoMaxPromptChars}) {
  final text = (prompt ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();
  if (text.length <= max) return text;
  return '${text.substring(0, max - 1).replaceAll(RegExp(r'\s+$'), '')}…';
}

/// The push copy for one event, ported verbatim from `copy.ts`'s
/// `notificationCopy` — title and body, including every degradation (unknown
/// handle → "Someone", missing prompt or emoji simply dropped from the
/// sentence).
DemoFriendNotification demoNotificationCopy(
  DemoFriendPushType type, {
  required String actorId,
  required String? handle,
  String? prompt,
  String? emoji,
  int lickCount = 1,
}) {
  final at = (handle ?? '').isEmpty ? 'Someone' : '@$handle';

  String title;
  String body;
  switch (type) {
    case DemoFriendPushType.friendRequest:
      title = '🦎 New friend request';
      body = '$at wants to be friends';
      break;
    case DemoFriendPushType.friendAccepted:
      title = '🦎 You have a new friend';
      body = '$at accepted your request';
      break;
    case DemoFriendPushType.lick:
      if (lickCount > 1) {
        title = '🦎 Licks';
        body = '$lickCount licks from $at';
      } else {
        title = '🦎 Lick';
        body = '$at licked you 🦎';
      }
      break;
    case DemoFriendPushType.forward:
      final shown = demoTruncatePrompt(prompt);
      title = '🦎 A question for you';
      body = shown.isEmpty
          ? '$at sent you a question'
          : '$at sent you a question: $shown';
      break;
    case DemoFriendPushType.reaction:
      final trimmed = (emoji ?? '').trim();
      title = '🦎 New reaction';
      body = trimmed.isEmpty
          ? '$at reacted to your question'
          : '$at reacted $trimmed to your question';
      break;
  }

  return DemoFriendNotification(title: title, body: body, actorId: actorId);
}

/// The production sink: a real local notification, carrying the same
/// `friend_{id}` payload a real FCM friend push carries, so tapping it lands on
/// the Community tab with that friend's chat open.
///
/// Failures are swallowed: a demo push that cannot be drawn (notifications
/// denied, plugin not initialised) must not break the action that triggered it.
Future<void> showDemoFriendLocalNotification(
    DemoFriendNotification notification) async {
  try {
    await NotificationService().showDemoFriendNotification(
      title: notification.title,
      body: notification.body,
      actorId: notification.actorId,
    );
  } catch (e) {
    debugPrint('Demo friends: local notification failed (ignored): $e');
  }
}
