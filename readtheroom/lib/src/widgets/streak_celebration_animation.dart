// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

// lib/src/widgets/streak_celebration_animation.dart
//
// The post-answer celebration: one continuous pop-in → beat → fade-out, two
// variants sharing the frame (🎉, badge card, Curio card):
//  * streak — flame with the old count, "+1" pops, the count rolls to the new
//    one (~2.7 s);
//  * first answerer — a ballot badge with the user's answer rank and Curio's
//    "you get to pick tomorrow's Question of the Day" line (~3.5 s, longer
//    copy needs the read time). Replaces the streak variant for the first
//    kQotdPickSpots answerers; see PostAnswerPrompts.maybeShow.
import 'dart:async';

import 'package:flutter/material.dart';
import '../utils/haptic_utils.dart';
import '../utils/qotd_pick_logic.dart';
import '../utils/username_logic.dart';

class StreakCelebrationAnimation extends StatefulWidget {
  final VoidCallback? onComplete;
  final int oldStreak;
  final int newStreak;

  /// Chameleon handle, when the user has one — personalises the thanks copy
  /// (backlog item 7). Null keeps the original wording.
  final String? username;

  /// Set for the first-answerer variant: "you were answerer #N". Null plays
  /// the streak variant.
  final int? firstAnswererRank;

  const StreakCelebrationAnimation({
    Key? key,
    this.onComplete,
    required this.oldStreak,
    required this.newStreak,
    this.username,
    this.firstAnswererRank,
  }) : super(key: key);

  @override
  StreakCelebrationAnimationState createState() => StreakCelebrationAnimationState();
}

class StreakCelebrationAnimationState extends State<StreakCelebrationAnimation>
    with SingleTickerProviderStateMixin {
  static const _enter = Duration(milliseconds: 380);
  static const _exit = Duration(milliseconds: 320);

  // Streak beats, measured from the start.
  static const _incrementAt = Duration(milliseconds: 500);
  static const _rollAt = Duration(milliseconds: 850);
  static const _streakExitAt = Duration(milliseconds: 2300);

  // First-answerer beat: the Curio line is a sentence, give it time to read.
  static const _firstAnswererExitAt = Duration(milliseconds: 3200);

  late final AnimationController _controller;
  late final Animation<double> _scale;
  late final Animation<double> _opacity;
  final List<Timer> _timers = [];
  late int _displayStreak;
  bool _showIncrement = false;
  bool _finished = false;

  bool get _isFirstAnswerer => widget.firstAnswererRank != null;

  @override
  void initState() {
    super.initState();
    _displayStreak = widget.oldStreak;
    _controller = AnimationController(
      vsync: this,
      duration: _enter,
      reverseDuration: _exit,
    );
    _scale = Tween<double>(begin: 0.88, end: 1.0).animate(CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutBack,
      reverseCurve: Curves.easeIn,
    ));
    _opacity = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOut,
      reverseCurve: Curves.easeIn,
    );

    AppHaptics.mediumImpact();
    _controller.forward();

    if (_isFirstAnswerer) {
      _at(_firstAnswererExitAt, _dismiss);
    } else {
      _at(_incrementAt, () => setState(() => _showIncrement = true));
      _at(_rollAt, () {
        AppHaptics.lightImpact();
        setState(() {
          _displayStreak = widget.newStreak;
          _showIncrement = false;
        });
      });
      _at(_streakExitAt, _dismiss);
    }
  }

  void _at(Duration delay, VoidCallback action) {
    _timers.add(Timer(delay, () {
      if (mounted) action();
    }));
  }

  Future<void> _dismiss() async {
    try {
      await _controller.reverse().orCancel;
    } on TickerCanceled {
      // Disposed mid-fade; still report completion below.
    }
    _complete();
  }

  void _complete() {
    if (_finished) return;
    _finished = true;
    widget.onComplete?.call();
  }

  @override
  void dispose() {
    for (final t in _timers) {
      t.cancel();
    }
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).primaryColor;
    return Positioned.fill(
      child: IgnorePointer(
        child: FadeTransition(
          opacity: _opacity,
          child: Container(
            color: Colors.black.withOpacity(0.1),
            child: Center(
              child: ScaleTransition(
                scale: _scale,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text(
                        '🎉',
                        style: TextStyle(
                          fontSize: 56,
                          decoration: TextDecoration.none,
                        ),
                      ),
                      const SizedBox(height: 12),
                      _card(
                        primary,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 24, vertical: 16),
                        child: _isFirstAnswerer
                            ? _rankBadge()
                            : _streakCounter(),
                      ),
                      const SizedBox(height: 16),
                      _card(
                        primary,
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Image.asset(
                              'assets/images/Curio_smiling_trans.png',
                              height: 130,
                              width: 130,
                            ),
                            const SizedBox(height: 12),
                            Text(
                              _isFirstAnswerer
                                  ? firstAnswererCelebrationText(
                                      widget.firstAnswererRank!,
                                      widget.username,
                                    )
                                  : thanksForContributingText(
                                      widget.username,
                                      exclaim: true,
                                    ),
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w600,
                                color: Colors.white,
                                decoration: TextDecoration.none,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _card(Color color,
      {required EdgeInsets padding, required Widget child}) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.2),
            blurRadius: 10,
          ),
        ],
      ),
      child: child,
    );
  }

  static const _bigNumber = TextStyle(
    fontSize: 36,
    fontWeight: FontWeight.bold,
    color: Colors.white,
    decoration: TextDecoration.none,
  );

  Widget _rankBadge() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.how_to_vote, color: Colors.white, size: 44),
        const SizedBox(width: 12),
        Text('#${widget.firstAnswererRank}', style: _bigNumber),
      ],
    );
  }

  Widget _streakCounter() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.local_fire_department, color: Colors.white, size: 44),
        const SizedBox(width: 12),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 280),
          transitionBuilder: (child, animation) {
            // New count rolls up from below; the old one leaves upward.
            final incoming = child.key == ValueKey(_displayStreak);
            final offset = Tween<Offset>(
              begin: Offset(0, incoming ? 0.6 : -0.6),
              end: Offset.zero,
            ).animate(animation);
            return ClipRect(
              child: SlideTransition(
                position: offset,
                child: FadeTransition(opacity: animation, child: child),
              ),
            );
          },
          child: Text(
            '$_displayStreak',
            key: ValueKey(_displayStreak),
            style: _bigNumber,
          ),
        ),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          transitionBuilder: (child, animation) =>
              ScaleTransition(scale: animation, child: child),
          child: _showIncrement
              ? const Text(
                  ' +1',
                  key: ValueKey('inc'),
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    color: Colors.greenAccent,
                    decoration: TextDecoration.none,
                  ),
                )
              : const SizedBox.shrink(key: ValueKey('none')),
        ),
      ],
    );
  }
}

// Overlay controller for managing the celebration animation
class StreakCelebrationOverlay {
  static OverlayEntry? _overlayEntry;
  static bool _isShowing = false;

  static void show(BuildContext context, {required int oldStreak, required int newStreak, VoidCallback? onComplete, String? username}) {
    _insert(
      context,
      StreakCelebrationAnimation(
        oldStreak: oldStreak,
        newStreak: newStreak,
        username: username,
        onComplete: () {
          hide();
          onComplete?.call();
        },
      ),
    );
  }

  /// The first-answerer variant. Completes when the overlay has faded out
  /// (immediately if another celebration is already on screen), so the caller
  /// can open the pick sheet right after.
  static Future<void> showFirstAnswerer(
    BuildContext context, {
    required int rank,
    String? username,
  }) {
    final done = Completer<void>();
    final inserted = _insert(
      context,
      StreakCelebrationAnimation(
        oldStreak: 0,
        newStreak: 0,
        firstAnswererRank: rank,
        username: username,
        onComplete: () {
          hide();
          if (!done.isCompleted) done.complete();
        },
      ),
    );
    if (!inserted) done.complete();
    return done.future;
  }

  static bool _insert(BuildContext context, Widget celebration) {
    if (_isShowing) return false; // Prevent multiple overlays
    _isShowing = true;
    _overlayEntry = OverlayEntry(builder: (context) => celebration);
    Overlay.of(context).insert(_overlayEntry!);
    return true;
  }

  static void hide() {
    if (_overlayEntry != null) {
      _overlayEntry!.remove();
      _overlayEntry = null;
    }
    _isShowing = false;
  }
}
