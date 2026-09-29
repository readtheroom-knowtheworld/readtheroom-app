// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/analytics_service.dart';
import '../services/deep_link_service.dart';
import '../services/friend_chat_service.dart';
import '../services/friend_service.dart';
import '../services/post_answer_prompts.dart';
import '../services/user_service.dart';
import '../utils/friend_chat_logic.dart';
import '../utils/friend_logic.dart';
import '../utils/haptic_utils.dart';
import 'chameleon_avatar.dart';
import 'chameleon_lick_icon.dart';
import 'emoji_picker_sheet.dart';
import 'forward_question_picker.dart';
import 'friend_name_label.dart';
import 'friend_nickname_dialog.dart';
import 'question_type_badge.dart';

/// The friend chat overlay: licks, forwards and any-emoji reactions
/// (networks-update-design-2026-07-17.md §5.4, WP-F).
///
/// A modal bottom sheet on the `comments_overlay` pattern — 90 % height,
/// transparent barrier with its own rounded container, drag handle, header,
/// scrolling body, pinned bottom bar — because it is the same *kind* of thing:
/// a focused conversation opened over whatever the user was doing.
///
/// **No free text, by design.** The bottom bar sends a lick or a question; there
/// is no keyboard, which is why the sheet needs none of the comments overlay's
/// input plumbing.
class FriendChatOverlay {
  const FriendChatOverlay._();

  static Future<void> show(BuildContext context, Friend friend) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      isDismissible: true,
      enableDrag: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      // The sheet carries its own ScaffoldMessenger + transparent Scaffold, so
      // the SnackBars it shows (close-friend on/off, lick sent, …) float over
      // the sheet instead of on the screen underneath it (owner, 2026-09-22).
      builder: (_) => ScaffoldMessenger(
        child: Scaffold(
          backgroundColor: Colors.transparent,
          body: _FriendChatSheet(friend: friend),
        ),
      ),
    );
  }
}

class _FriendChatSheet extends StatefulWidget {
  const _FriendChatSheet({required this.friend});

  final Friend friend;

  @override
  State<_FriendChatSheet> createState() => _FriendChatSheetState();
}

class _FriendChatSheetState extends State<_FriendChatSheet> {
  /// Ticks the lick countdown. Only alive while the button is cooling down —
  /// a chat sitting open must not hold a 1 Hz timer for nothing.
  Timer? _countdown;
  bool _sending = false;

  /// Lick-button squeeze (see [_pulseLickButton]). 1.0 at rest.
  double _lickScale = 1.0;

  String get _friendId => widget.friend.userId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _open());
  }

  @override
  void dispose() {
    _countdown?.cancel();
    // Guarded: the service outlives the sheet, and a second chat may already
    // have claimed the slot (a notification tap over an open sheet), so only
    // this friend's own claim is released.
    _chatOrNull?.clearActiveFriend(_friendId);
    super.dispose();
  }

  FriendChatService? get _chatOrNull {
    try {
      return Provider.of<FriendChatService>(context, listen: false);
    } catch (_) {
      return null;
    }
  }

  Future<void> _open() async {
    final chat = _chatOrNull;
    if (chat == null) return;

    final unread = chat.unreadFor(_friendId);
    unawaited(AnalyticsService()
        .trackEvent('friend_chat_opened', {'unread': unread}));

    chat.setActiveFriend(_friendId);
    // Read first: the badge must clear on open (§5.4), not once the page
    // arrives.
    unawaited(chat.markRead(_friendId));
    await chat.loadTimeline(_friendId);
    _syncCountdown();
  }

  /// Runs a 1 Hz timer only while the lick button is disabled.
  void _syncCountdown() {
    final chat = _chatOrNull;
    if (chat == null) return;
    final cooling = chat.lickCooldownFor(_friendId) > Duration.zero;
    if (cooling && _countdown == null) {
      _countdown = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        setState(() {});
        final still = _chatOrNull?.lickCooldownFor(_friendId) ?? Duration.zero;
        if (still <= Duration.zero) {
          _countdown?.cancel();
          _countdown = null;
        }
      });
    } else if (!cooling) {
      _countdown?.cancel();
      _countdown = null;
    }
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message, style: const TextStyle(color: Colors.white)),
        backgroundColor: Theme.of(context).primaryColor,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  // --- actions ---------------------------------------------------------------

  /// A 110 ms squeeze on the lick button, so a poke feels like one. Skipped
  /// entirely under reduced motion — the haptic and the state change carry the
  /// feedback instead.
  void _pulseLickButton() {
    if (MediaQuery.of(context).disableAnimations) return;
    setState(() => _lickScale = 0.94);
    Timer(const Duration(milliseconds: 110), () {
      if (!mounted) return;
      setState(() => _lickScale = 1.0);
    });
  }

  Future<void> _sendLick() async {
    final chat = _chatOrNull;
    if (chat == null || _sending) return;
    AppHaptics.lightImpact();
    _pulseLickButton();
    setState(() => _sending = true);
    final result = await chat.sendLick(_friendId, surface: 'chat_overlay');
    if (!mounted) return;
    setState(() => _sending = false);
    _syncCountdown();
    if (!result.success) {
      _snack(result.message);
      return;
    }
    _maybePromptForNotifications();
  }

  /// A lick is the first moment a friend can answer back, so it is the first
  /// moment notifications matter for chat. Runs the same decision as the
  /// post-QOTD prompt (never asked → ask; declined → 7-day re-ask; OS-denied →
  /// Settings nudge), so a user who already answered it isn't asked twice.
  void _maybePromptForNotifications() {
    UserService userService;
    try {
      userService = context.read<UserService>();
    } on ProviderNotFoundException {
      return; // widget tests without an app-level UserService
    }
    unawaited(PostAnswerPrompts.promptForTrigger(
      context,
      userService: userService,
      source: 'first_lick',
    ));
  }

  Future<void> _forwardQuestion() async {
    final chat = _chatOrNull;
    if (chat == null || _sending) return;
    final questionId = await ForwardQuestionPicker.show(context);
    if (questionId == null || questionId.isEmpty || !mounted) return;

    setState(() => _sending = true);
    final result = await chat.forwardQuestion(
      friendId: _friendId,
      questionId: questionId,
      source: 'overlay',
    );
    if (!mounted) return;
    setState(() => _sending = false);
    _snack(result.success ? 'Sent 🦎' : result.message);
  }

  Future<void> _react(FriendEvent forward) async {
    final chat = _chatOrNull;
    if (chat == null) return;
    final emoji = await EmojiPickerSheet.show(
      context: context,
      title: 'React to this question',
      onRejected: (_) => _snack("That one can't be used as a reaction."),
    );
    if (emoji == null || !mounted) return;

    final result = await chat.react(
      friendId: _friendId,
      targetEventId: forward.id,
      emoji: emoji,
    );
    if (!mounted || result.success) return;
    _snack(result.message);
  }

  /// A tapped forward goes through the same smart routing a deep link uses, so
  /// an answered question opens its results and an unanswered one opens the
  /// answer screen. That routing resets the navigation stack, so the sheet is
  /// dismissed first rather than being torn out from under itself.
  Future<void> _openForward(FriendEvent event) async {
    final questionId = event.questionId;
    if (!event.isOpenableForward || questionId == null) {
      _snack("That question isn't available any more.");
      return;
    }
    // Closes the viral loop: forward sent -> forward opened -> answered.
    unawaited(AnalyticsService().trackEvent('friend_forward_opened', const {}));
    final navigatorContext = Navigator.of(context).context;
    Navigator.of(context).pop();
    await DeepLinkService().openQuestion(navigatorContext, questionId);
  }

  Future<void> _toggleClose(Friend friend) async {
    final friends = context.read<FriendService>();
    AppHaptics.lightImpact();
    final result = await friends.setCloseFriend(
        friend.userId, !friend.isClose,
        surface: 'chat_overlay');
    if (!mounted) return;
    if (!result.success) {
      _snack(result.message);
      return;
    }
    _snack(friend.isClose
        ? 'No longer a close friend'
        : 'Close friend — sharing your answers with them');
  }

  Future<void> _editNickname(Friend friend) async {
    final message = await editFriendNickname(context, friend);
    if (message != null) _snack(message);
  }

  Future<void> _confirmBlock(Friend friend) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Block this chameleon?'),
        content: Text(
          'Block ${friend.displayHandle}? Your chat disappears for both of '
          "you, you stop being friends, and neither of you can add the other "
          'again. They are not told.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Block'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final friends = context.read<FriendService>();
    final chat = _chatOrNull;
    final result =
        await friends.blockUser(friend.userId, surface: 'chat_overlay');
    // Silence the feed on this device immediately, whatever the server said —
    // if the block failed the next refresh puts the friend back, but a block
    // that visibly leaves messages arriving is worse than a redundant clear.
    chat?.dropFriend(friend.userId);
    if (!mounted) return;
    Navigator.of(context).pop();
    if (!result.success) return;
  }

  // --- build -----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final chat = context.watch<FriendChatService>();
    final friends = context.watch<FriendService>();
    // The header must follow live changes to mute / close-friend, which the
    // Friend passed in cannot know about.
    final friend = friends.friendById(_friendId) ?? widget.friend;
    final entries = chat.entriesFor(_friendId);

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        height: MediaQuery.of(context).size.height * 0.9,
        decoration: BoxDecoration(
          color: theme.scaffoldBackgroundColor,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(
          children: [
            _buildDragHandle(),
            _buildHeader(theme, friend),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Divider(height: 1),
            ),
            Expanded(child: _buildTimeline(theme, chat, entries)),
            _buildBottomBar(theme, chat),
          ],
        ),
      ),
    );
  }

  Widget _buildDragHandle() => Center(
        child: Container(
          margin: const EdgeInsets.only(top: 12, bottom: 8),
          width: 40,
          height: 4,
          decoration: BoxDecoration(
            color: Colors.grey[400],
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      );

  Widget _buildHeader(ThemeData theme, Friend friend) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 4, 8),
      child: Row(
        children: [
          ChameleonAvatar(
              avatarId: friend.avatarId, size: 40, closeFriend: friend.isClose),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildHandle(theme, friend),
                if (friend.isClose)
                  Text(
                    friend.mutualClose
                        ? 'Sharing answers with each other'
                        : 'Sharing your answers with them',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: Colors.grey[600]),
                  ),
              ],
            ),
          ),
          // Quick toggles, per the WP-F brief: the two settings someone reaches
          // for mid-conversation live in the conversation. The header has no
          // close button (drag down or tap outside), so these stay compact and
          // the handle keeps its own room to ellipsise in.
          IconButton(
            tooltip: friend.isClose ? 'Remove close friend' : 'Close friend',
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.all(4),
            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
            icon: Icon(
              friend.isClose ? Icons.favorite_rounded : Icons.favorite_border_rounded,
              color: friend.isClose ? theme.primaryColor : Colors.grey[600],
            ),
            onPressed: friend.isAccepted ? () => _toggleClose(friend) : null,
          ),
          PopupMenuButton<String>(
            tooltip: 'More',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 180),
            icon: Icon(Icons.more_vert, color: Colors.grey[600]),
            onSelected: (value) {
              if (value == 'nickname') _editNickname(friend);
              if (value == 'block') _confirmBlock(friend);
            },
            itemBuilder: (_) => const [
              PopupMenuItem<String>(
                value: 'nickname',
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.edit_outlined),
                  title: Text('Set nickname'),
                ),
              ),
              PopupMenuItem<String>(
                value: 'block',
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.block, color: Colors.red),
                  title: Text('Block'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Handle plus the private nickname in light grey, as on the friend list.
  /// The sheet is dismissed by dragging or tapping outside it; there is no
  /// close button (owner request 2026-09-28).
  Widget _buildHandle(ThemeData theme, Friend friend) => FriendNameLabel(
        friend: friend,
        style:
            theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
      );

  Widget _buildTimeline(
    ThemeData theme,
    FriendChatService chat,
    List<FriendChatEntry> entries,
  ) {
    if (entries.isEmpty) {
      if (chat.isLoadingTimeline(_friendId)) {
        return const Center(child: CircularProgressIndicator());
      }
      return _buildEmptyState(theme);
    }

    final me = chat.viewerId;
    final showLoadOlder = chat.hasMore(_friendId);

    // `reverse: true` puts the newest message at the bottom and starts the
    // view there, which is what a chat has to do; the list is therefore fed
    // newest-first.
    final rows = entries.reversed.toList();

    return ListView.builder(
      reverse: true,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      itemCount: rows.length + (showLoadOlder ? 1 : 0),
      itemBuilder: (context, index) {
        if (index >= rows.length) {
          return Center(
            child: TextButton(
              onPressed: chat.isLoadingTimeline(_friendId)
                  ? null
                  : () => chat.loadTimeline(_friendId, loadMore: true),
              child: Text(chat.isLoadingTimeline(_friendId)
                  ? 'Loading…'
                  : 'Load older'),
            ),
          );
        }
        return _ChatEntryRow(
          entry: rows[index],
          mine: rows[index].event.isMine(me),
          viewerId: me,
          onOpenForward: _openForward,
          onReact: _react,
        );
      },
    );
  }

  Widget _buildEmptyState(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const ChameleonLickIcon(size: 56, semanticsLabel: null),
          const SizedBox(height: 12),
          Text(
            'No words here',
            style: theme.textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Text(
            'Send a lick, or pass on a question worth arguing about. '
            'That is the whole conversation.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(color: Colors.grey),
          ),
        ],
      ),
    );
  }

  Widget _buildBottomBar(ThemeData theme, FriendChatService chat) {
    final remaining = chat.lickCooldownFor(_friendId);
    final cooling = remaining > Duration.zero;
    final canLick = !cooling && !_sending;

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Row(
          children: [
            Expanded(
              flex: 3,
              child: AnimatedScale(
                scale: _lickScale,
                duration: const Duration(milliseconds: 110),
                child: ElevatedButton(
                  onPressed: canLick ? _sendLick : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: theme.primaryColor,
                    foregroundColor: Colors.white,
                    disabledBackgroundColor: Colors.grey.withOpacity(0.3),
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(28),
                    ),
                  ),
                  child: cooling
                      ? Text(
                          'Lick in ${lickCountdownLabel(remaining)}',
                          style: const TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w600),
                        )
                      : Row(
                          mainAxisSize: MainAxisSize.min,
                          children: const [
                            Text(
                              'Lick',
                              style: TextStyle(
                                  fontSize: 16, fontWeight: FontWeight.w600),
                            ),
                            SizedBox(width: 8),
                            // The button already says "Lick"; a second label
                            // here would make the screen reader say it twice.
                            ChameleonLickIcon(size: 22, semanticsLabel: null),
                          ],
                        ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 2,
              child: OutlinedButton.icon(
                onPressed: _sending ? null : _forwardQuestion,
                icon: const Icon(Icons.help_outline, size: 18),
                label: const Text('Question'),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(28),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One timeline row: the event, plus any reactions attached beneath it.
class _ChatEntryRow extends StatelessWidget {
  const _ChatEntryRow({
    required this.entry,
    required this.mine,
    required this.viewerId,
    required this.onOpenForward,
    required this.onReact,
  });

  final FriendChatEntry entry;
  final bool mine;
  final String? viewerId;
  final Future<void> Function(FriendEvent) onOpenForward;
  final Future<void> Function(FriendEvent) onReact;

  @override
  Widget build(BuildContext context) {
    final event = entry.event;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment:
            mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          Semantics(
            label: friendEventSummary(event, mine: mine),
            child: _buildBubble(context, event),
          ),
          if (entry.hasReactions)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: _ReactionStrip(
                reactions: entry.reactions,
                viewerId: viewerId,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildBubble(BuildContext context, FriendEvent event) {
    switch (event.kind) {
      case FriendEventKind.lick:
        return _LickBubble(mine: mine);
      case FriendEventKind.forward:
        return _ForwardBubble(
          event: event,
          mine: mine,
          onTap: () => onOpenForward(event),
          // "React" is offered on forwards the viewer *received* (§5.4). You
          // can still see reactions to your own; you just do not react to
          // yourself.
          onReact: mine ? null : () => onReact(event),
        );
      case FriendEventKind.reaction:
      case FriendEventKind.unknown:
        // An orphan: its forward is older than the loaded page. Rendered as a
        // plain bubble rather than dropped.
        return _LooseReactionBubble(event: event, mine: mine);
    }
  }
}

class _LickBubble extends StatelessWidget {
  const _LickBubble({required this.mine});

  final bool mine;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: mine
            ? theme.primaryColor.withOpacity(0.15)
            : Colors.grey.withOpacity(0.15),
        borderRadius: BorderRadius.circular(20),
      ),
      // The row above already carries `friendEventSummary` as its semantics
      // label, so the mark itself stays silent.
      child: const ChameleonLickIcon(size: 32, semanticsLabel: null),
    );
  }
}

class _ForwardBubble extends StatelessWidget {
  const _ForwardBubble({
    required this.event,
    required this.mine,
    required this.onTap,
    this.onReact,
  });

  final FriendEvent event;
  final bool mine;
  final VoidCallback onTap;
  final VoidCallback? onReact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hidden = event.questionHidden;
    final prompt = hidden
        ? 'This question is no longer available'
        : (event.questionPrompt ?? 'A question');

    return ConstrainedBox(
      // Bubbles stop well short of the edge at phone width so the two sides
      // stay visibly two sides.
      constraints: BoxConstraints(
        maxWidth: MediaQuery.of(context).size.width * 0.78,
      ),
      child: Material(
        color: mine
            ? theme.primaryColor.withOpacity(0.12)
            : theme.cardColor,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          onTap: hidden ? null : onTap,
          borderRadius: BorderRadius.circular(16),
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.grey.withOpacity(0.25)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    QuestionTypeBadge(
                      type: event.questionType ?? '',
                      size: 18,
                      color: hidden ? Colors.grey : theme.primaryColor,
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        prompt,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w500,
                          fontStyle:
                              hidden ? FontStyle.italic : FontStyle.normal,
                          color: hidden ? Colors.grey : null,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (!hidden)
                      Text(
                        'Tap to answer',
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: theme.primaryColor),
                      ),
                    if (onReact != null && !hidden) ...[
                      const SizedBox(width: 12),
                      InkWell(
                        onTap: onReact,
                        borderRadius: BorderRadius.circular(12),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.add_reaction_outlined,
                                  size: 16, color: Colors.grey[600]),
                              const SizedBox(width: 4),
                              Text(
                                'React',
                                style: theme.textTheme.bodySmall
                                    ?.copyWith(color: Colors.grey[600]),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Reactions attached under the forward they target.
class _ReactionStrip extends StatelessWidget {
  const _ReactionStrip({required this.reactions, required this.viewerId});

  final List<FriendEvent> reactions;
  final String? viewerId;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: reactions.map((reaction) {
        final mine = reaction.isMine(viewerId);
        return Semantics(
          label: friendEventSummary(reaction, mine: mine),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: theme.primaryColor.withOpacity(mine ? 0.18 : 0.08),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: theme.primaryColor.withOpacity(mine ? 0.6 : 0.2),
              ),
            ),
            child: Text(reaction.emoji ?? '',
                style: const TextStyle(fontSize: 16)),
          ),
        );
      }).toList(),
    );
  }
}

/// A reaction whose forward is not in the loaded page.
class _LooseReactionBubble extends StatelessWidget {
  const _LooseReactionBubble({required this.event, required this.mine});

  final FriendEvent event;
  final bool mine;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: mine
            ? theme.primaryColor.withOpacity(0.12)
            : Colors.grey.withOpacity(0.12),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(event.emoji ?? '', style: const TextStyle(fontSize: 18)),
          const SizedBox(width: 8),
          Text(
            'on an earlier question',
            style: theme.textTheme.bodySmall?.copyWith(color: Colors.grey[600]),
          ),
        ],
      ),
    );
  }
}
