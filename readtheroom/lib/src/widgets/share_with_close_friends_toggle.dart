// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';

import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'package:provider/provider.dart';

import '../services/friend_service.dart';
import '../utils/haptic_utils.dart';
import 'animated_submit_button.dart';

/// "Share this answer with close friends" — the per-answer close-friend flag,
/// shown **above** the answer controls on every path that submits an answer
/// (owner decision 2026-09-17).
///
/// It replaces the profile-wide switch that used to sit on the *answered* card.
/// That one was both too late (the choice arrived after the answer was already
/// filed) and too broad (off hid every answer, past and future). This one is a
/// property of the single answer being written: default ON, off means this one
/// answer is never shown to a close friend, and nothing else changes.
///
/// Shown ONLY once the user has at least one close friend (owner decision
/// 2026-09-19): before that there is nobody the choice could apply to, and a
/// control about "close friends" is noise. Without it the answer is filed with
/// the default (shared), which is what the switch would have said anyway.
///
/// SHAPE (2026-09-19, second pass): an ICON-ONLY square that sits on the same
/// row as the submit button, to its right — the submit button gives up 56pt of
/// width and nothing is added above the answer. People icon = shared (default),
/// ghost = this answer hidden. The words live in the SnackBar that follows a
/// tap, in the long-press tooltip and in the screen-reader label, so the glyph
/// never has to explain itself on screen. Square at [AnimatedSubmitButton.height]
/// (read from that widget rather than a second hardcoded number, so the two
/// stay the same height if the button's padding or text style ever changes)
/// with 8pt radius; state is carried by glyph AND fill, never colour alone.
/// Renders nothing (zero width) when it should not show, so call sites can
/// always place it in the row.
///
/// Stateless on purpose: each answer surface owns the value (it has to send it
/// with the answer), so there is exactly one source of truth per submit.
class ShareWithCloseFriendsToggle extends StatelessWidget {
  const ShareWithCloseFriendsToggle({
    Key? key,
    required this.value,
    required this.onChanged,
    this.enabled = true,
  }) : super(key: key);

  final bool value;
  final ValueChanged<bool> onChanged;

  /// False while a submit is in flight — the answer is already on its way with
  /// the value it had, so letting the toggle move would be a lie.
  final bool enabled;

  static const String onMessage =
      'Close friends can see this answer. Everyone else sees it anonymously.';
  static const String offMessage =
      'Ghost mode 👻 This one answer stays hidden from close friends too.';

  /// Whether the viewer has anyone this choice could apply to.
  static bool hasCloseFriends(BuildContext context) {
    try {
      return context.watch<FriendService>().closeFriends.isNotEmpty;
    } on ProviderNotFoundException {
      return false;
    }
  }

  void _toggle(BuildContext context) {
    if (!enabled) return;
    final next = !value;
    AppHaptics.lightImpact();
    onChanged(next);

    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          duration: const Duration(milliseconds: 2600),
          behavior: SnackBarBehavior.floating,
          backgroundColor: Theme.of(context).primaryColor,
          content: Text(
            next ? onMessage : offMessage,
            style: const TextStyle(color: Colors.white),
          ),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    if (!hasCloseFriends(context)) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final primary = theme.primaryColor;
    final muted = theme.brightness == Brightness.dark
        ? Colors.grey[400]!
        : Colors.grey[600]!;
    final fg = value ? primary : muted;
    const radius = BorderRadius.all(Radius.circular(8));

    return Padding(
      // The gap to the submit button lives here, so a hidden toggle leaves the
      // button at full width with no stray spacing.
      padding: const EdgeInsets.only(left: 8),
      child: Semantics(
        button: true,
        toggled: value,
        enabled: enabled,
        label: 'Share this answer with close friends',
        excludeSemantics: true,
        child: Tooltip(
          message: value
              ? 'Shared with close friends — tap to hide this answer'
              : 'Hidden from close friends — tap to share this answer',
          child: Opacity(
            opacity: enabled ? 1 : 0.5,
            child: InkWell(
              onTap: enabled ? () => _toggle(context) : null,
              borderRadius: radius,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOut,
                width: AnimatedSubmitButton.height,
                height: AnimatedSubmitButton.height,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  borderRadius: radius,
                  border: Border.all(color: fg.withOpacity(value ? 0.35 : 0.45)),
                  color: value ? primary.withOpacity(0.10) : Colors.transparent,
                ),
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 180),
                  transitionBuilder: (child, anim) =>
                      ScaleTransition(scale: anim, child: child),
                  child: value
                      ? Icon(Icons.group_rounded,
                          key: const ValueKey('share-on'), size: 22, color: fg)
                      : FaIcon(FontAwesomeIcons.ghost,
                          key: const ValueKey('share-off'), size: 19, color: fg),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
