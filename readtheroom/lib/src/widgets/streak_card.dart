// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Self-contained streak card, extracted from home_screen.dart (QOTD-first
// Phase 1). Renders the flame/medal + streak number chip in the home header,
// with all of its animations owned internally:
//   - a continuous pulse when the streak is at risk (urgent, <3h left),
//   - a one-shot celebration scale driven off [StreakUpdateEvent], and
//   - an attention glow that draws a tap when the streak is at risk.
// Tapping opens the answer-streak dialog (also extracted here).
//
// API contract (Phase 2 home rewrite uses this exactly):
//   StreakCard(userService: <UserService>)
// The card reads streak state from the injected UserService and rebuilds when
// it notifies. Home keeps its inline copy until the Phase 2 rewrite.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/profile_service.dart';
import '../services/user_service.dart';
import '../services/analytics_service.dart';
import '../services/question_service.dart' show StreakUpdateEvent;
import '../utils/streak_logic.dart' as streak_logic;
import 'answer_streak_dialog.dart';
import 'streak_celebration_animation.dart';

class StreakCard extends StatefulWidget {
  final UserService userService;

  /// Compact pill form for the AppBar (replaces the old Camo Counter badge):
  /// flame/medal + streak number on the streak color, same tap → dialog,
  /// same urgency colors / celebration / rainbow ring as the full card.
  final bool compact;

  const StreakCard({Key? key, required this.userService, this.compact = false})
      : super(key: key);

  @override
  State<StreakCard> createState() => _StreakCardState();
}

class _StreakCardState extends State<StreakCard> with TickerProviderStateMixin {
  // Continuous pulse for the at-risk (urgent) state.
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  // One-shot celebration scale, fired when the streak extends.
  late AnimationController _streakCardController;
  late Animation<double> _streakCardScaleAnimation;
  int? _animatingOldStreak;
  int? _animatingNewStreak;
  bool _isStreakAnimating = false;

  // Attention glow to draw a tap when the streak is at risk.
  late AnimationController _streakAttentionController;
  late Animation<double> _streakAttentionAnimation;
  bool _isStreakAttentionAnimating = false;

  @override
  void initState() {
    super.initState();

    _pulseController = AnimationController(
      duration: const Duration(milliseconds: 1000),
      vsync: this,
    );
    _pulseAnimation = Tween<double>(begin: 1.0, end: 1.105).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
    _pulseController.repeat(reverse: true);

    _streakCardController = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    );
    _streakCardScaleAnimation = TweenSequence<double>([
      TweenSequenceItem(tween: Tween<double>(begin: 1.0, end: 1.1), weight: 30),
      TweenSequenceItem(tween: Tween<double>(begin: 1.1, end: 1.0), weight: 70),
    ]).animate(_streakCardController);

    _streakAttentionController = AnimationController(
      duration: const Duration(milliseconds: 1200),
      vsync: this,
    );
    _streakAttentionAnimation = TweenSequence<double>([
      TweenSequenceItem(tween: Tween<double>(begin: 0.0, end: 1.0), weight: 20),
      TweenSequenceItem(tween: Tween<double>(begin: 1.0, end: 1.0), weight: 20),
      TweenSequenceItem(tween: Tween<double>(begin: 1.0, end: 0.0), weight: 20),
      TweenSequenceItem(tween: Tween<double>(begin: 0.0, end: 0.8), weight: 20),
      TweenSequenceItem(tween: Tween<double>(begin: 0.8, end: 0.0), weight: 20),
    ]).animate(_streakAttentionController);
    _streakAttentionController.addStatusListener((status) {
      if (status == AnimationStatus.completed && mounted) {
        setState(() => _isStreakAttentionAnimating = false);
      }
    });

    StreakUpdateEvent.addListener(_onStreakExtended);

    // Self-trigger the attention glow once after layout if the streak is at
    // risk (encourages a tap).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _maybeTriggerAttention();
    });
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _streakCardController.dispose();
    _streakAttentionController.dispose();
    StreakUpdateEvent.removeListener(_onStreakExtended);
    super.dispose();
  }

  // --- streak math (delegates to the pure util, both credit sources) --------

  int get _currentStreak => streak_logic.calculateAnswerStreak(
        widget.userService.answeredQuestions,
        askedCredits: widget.userService.askedStreakCredits,
      );

  bool get _hasExtendedStreakToday => streak_logic.hasExtendedStreakToday(
        widget.userService.answeredQuestions,
        askedCredits: widget.userService.askedStreakCredits,
      );

  // --- celebration ----------------------------------------------------------

  void _onStreakExtended(int previousStreak, int newStreak) {
    if (!mounted) return;
    setState(() {
      _animatingOldStreak = previousStreak;
      _animatingNewStreak = newStreak;
      _isStreakAnimating = true;
    });
    StreakCelebrationOverlay.show(
      context,
      oldStreak: previousStreak,
      newStreak: newStreak,
      // Personalised thanks when a chameleon name is set (backlog item 7).
      username: Provider.of<ProfileService>(context, listen: false).username,
      onComplete: () {
        if (mounted) {
          setState(() {
            _isStreakAnimating = false;
            _animatingOldStreak = null;
            _animatingNewStreak = null;
          });
        }
      },
    );
  }

  void _maybeTriggerAttention() {
    if (!mounted) return;
    if (_isStreakAttentionAnimating) return;
    if (_currentStreak == 0) return;
    if (_hasExtendedStreakToday) return;
    if (_getHoursRemainingToday() >= 6) return;

    setState(() => _isStreakAttentionAnimating = true);
    _streakAttentionController.reset();
    _streakAttentionController.forward();
  }

  // --- helpers (color / decoration / pulse) ---------------------------------

  double _getHoursRemainingToday() {
    final now = DateTime.now();
    final endOfDay = DateTime(now.year, now.month, now.day, 23, 59, 59);
    return endOfDay.difference(now).inMinutes / 60.0;
  }

  bool _shouldStreakCardPulse(bool hasExtendedStreakToday, int currentStreak) {
    if (currentStreak == 0) return false;
    if (!hasExtendedStreakToday) {
      return _getHoursRemainingToday() < 3;
    }
    return false;
  }

  Color _getStreakCardColor(BuildContext context, bool hasExtendedStreakToday) {
    if (!hasExtendedStreakToday) {
      final hoursRemaining = _getHoursRemainingToday();
      if (hoursRemaining < 3) {
        return const Color(0xff951414);
      } else if (hoursRemaining < 6) {
        return const Color(0xffea6d32);
      }
    }
    return Theme.of(context).primaryColor;
  }

  Color _getStreakCardColorForStreak(int streak, bool hasExtendedToday) {
    if (streak == 0) return Colors.grey;
    if (!hasExtendedToday) {
      final hoursRemaining = _getHoursRemainingToday();
      if (hoursRemaining < 3) {
        return const Color(0xff951414);
      } else if (hoursRemaining < 6) {
        return const Color(0xffea6d32);
      }
    }
    return Theme.of(context).primaryColor;
  }

  Decoration _getStreakCardDecoration(BuildContext context, int currentStreak,
      {bool isTopFive = false}) {
    if (isTopFive || currentStreak > 100) {
      return BoxDecoration(
        borderRadius: BorderRadius.circular(8.0),
        gradient: const LinearGradient(
          colors: [
            Colors.red,
            Colors.orange,
            Colors.yellow,
            Colors.green,
            Colors.blue,
            Colors.indigo,
            Colors.purple,
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      );
    }
    return BoxDecoration(
      border: Border.all(
        color: Theme.of(context).dividerColor.withOpacity(0.3),
        width: 0.5,
      ),
      borderRadius: BorderRadius.circular(8.0),
    );
  }

  // --- dialog ---------------------------------------------------------------

  Future<void> _showAnswerStreakDialog(
      BuildContext context, UserService userService) async {
    final currentStreak = _currentStreak;
    final hasExtendedStreakToday = _hasExtendedStreakToday;
    final streakColor = _getStreakCardColor(context, hasExtendedStreakToday);
    await showAnswerStreakDialog(
      context,
      currentStreak: currentStreak,
      streakRank: userService.streakRank,
      streakColor: streakColor,
      shouldShowUrgent:
          _shouldStreakCardPulse(hasExtendedStreakToday, currentStreak) ||
              streakColor == const Color(0xffea6d32),
    );
  }

  // --- compact (AppBar badge) form ------------------------------------------

  /// The AppBar pill: streak-colored background, flame (or top-3 medal) and
  /// the streak number. Shares the full card's urgency colors, pulse,
  /// celebration count-up and rainbow ring, and opens the same dialog.
  Widget _buildCompactBadge(
    BuildContext context, {
    required int currentStreak,
    required bool hasExtendedStreakToday,
    required int streakRank,
    required bool showRainbow,
  }) {
    return AnimatedBuilder(
      animation: Listenable.merge([_pulseAnimation, _streakCardController]),
      builder: (context, _) {
        final shouldPulse =
            _shouldStreakCardPulse(hasExtendedStreakToday, currentStreak);
        final pulseScale = shouldPulse ? _pulseAnimation.value : 1.0;
        final celebrationScale =
            _isStreakAnimating ? _streakCardScaleAnimation.value : 1.0;

        // Color + displayed number, mirroring the full card's celebration
        // lerp (old color → primary as the count-up passes the midpoint).
        Color pillColor;
        int displayStreak;
        if (_isStreakAnimating) {
          final progress = _streakCardController.value;
          if (progress < 0.5) {
            pillColor =
                _getStreakCardColorForStreak(_animatingOldStreak ?? 0, false);
            displayStreak = _animatingOldStreak ?? currentStreak;
          } else {
            final colorProgress = (progress - 0.5) * 2;
            final oldColor =
                _getStreakCardColorForStreak(_animatingOldStreak ?? 0, false);
            final newColor = Theme.of(context).primaryColor;
            pillColor =
                Color.lerp(oldColor, newColor, colorProgress) ?? newColor;
            displayStreak = _animatingNewStreak ?? currentStreak;
          }
        } else {
          pillColor = currentStreak > 0
              ? _getStreakCardColor(context, hasExtendedStreakToday)
              : Colors.grey;
          displayStreak = currentStreak;
        }

        final showMedal = streakRank >= 1 && streakRank <= 3;

        return Transform.scale(
          scale: pulseScale * celebrationScale,
          child: GestureDetector(
            onTap: () {
              AnalyticsService().trackEvent('streak_card_tapped', {
                'current_streak': currentStreak,
                'has_extended_today': hasExtendedStreakToday,
                'compact': true,
              });
              _showAnswerStreakDialog(context, widget.userService);
            },
            child: Container(
              decoration: showRainbow
                  ? const BoxDecoration(
                      borderRadius: BorderRadius.all(Radius.circular(14)),
                      gradient: LinearGradient(
                        colors: [
                          Colors.red,
                          Colors.orange,
                          Colors.yellow,
                          Colors.green,
                          Colors.blue,
                          Colors.indigo,
                          Colors.purple,
                        ],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                    )
                  : null,
              padding: showRainbow ? const EdgeInsets.all(2) : EdgeInsets.zero,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: pillColor,
                  borderRadius: BorderRadius.circular(showRainbow ? 12 : 14),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (showMedal)
                      Text(
                        streakRank == 1
                            ? '🥇'
                            : streakRank == 2
                                ? '🥈'
                                : '🥉',
                        style: const TextStyle(fontSize: 14),
                      )
                    else
                      const Icon(
                        Icons.local_fire_department,
                        size: 16,
                        color: Colors.white,
                      ),
                    const SizedBox(width: 4),
                    Text(
                      '$displayStreak',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  // --- build ----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.userService,
      builder: (context, _) {
        final currentStreak = _currentStreak;
        final hasExtendedStreakToday = _hasExtendedStreakToday;
        final streakRank = widget.userService.streakRank;
        final isTopFive = streakRank >= 1 && streakRank <= 5;
        final showRainbow = isTopFive || currentStreak > 100;

        if (widget.compact) {
          return _buildCompactBadge(
            context,
            currentStreak: currentStreak,
            hasExtendedStreakToday: hasExtendedStreakToday,
            streakRank: streakRank,
            showRainbow: showRainbow,
          );
        }

        return AnimatedBuilder(
          animation: _streakAttentionAnimation,
          builder: (context, child) {
            final glowOpacity = _isStreakAttentionAnimating
                ? _streakAttentionAnimation.value
                : 0.0;
            return Container(
              width: 120,
              height: 104,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8.0),
                boxShadow: glowOpacity > 0
                    ? [
                        BoxShadow(
                          color: Theme.of(context)
                              .primaryColor
                              .withOpacity(glowOpacity * 0.6),
                          blurRadius: 16 * glowOpacity,
                          spreadRadius: 3 * glowOpacity,
                        ),
                      ]
                    : null,
              ),
              child: Container(
                decoration: _getStreakCardDecoration(context, currentStreak,
                    isTopFive: isTopFive),
                padding: showRainbow
                    ? const EdgeInsets.all(2)
                    : EdgeInsets.zero,
                child: Container(
                  decoration: showRainbow
                      ? BoxDecoration(
                          color: Theme.of(context).scaffoldBackgroundColor,
                          borderRadius: BorderRadius.circular(6.0),
                        )
                      : null,
                  child: InkWell(
                    onTap: () {
                      AnalyticsService().trackEvent('streak_card_tapped', {
                        'current_streak': currentStreak,
                        'has_extended_today': hasExtendedStreakToday,
                      });
                      _showAnswerStreakDialog(context, widget.userService);
                    },
                    borderRadius: BorderRadius.circular(showRainbow ? 6 : 8),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: AnimatedBuilder(
                        animation: _pulseAnimation,
                        builder: (context, child) {
                          final shouldPulse = _shouldStreakCardPulse(
                              hasExtendedStreakToday, currentStreak);
                          final pulseScale =
                              shouldPulse ? _pulseAnimation.value : 1.0;

                          return AnimatedBuilder(
                            animation: _streakCardController,
                            builder: (context, child) {
                              final celebrationScale = _isStreakAnimating
                                  ? _streakCardScaleAnimation.value
                                  : 1.0;
                              final finalScale = pulseScale * celebrationScale;

                              Color iconColor;
                              Color textColor;
                              int displayStreak;

                              if (_isStreakAnimating) {
                                final animationProgress =
                                    _streakCardController.value;
                                if (animationProgress < 0.5) {
                                  iconColor = _getStreakCardColorForStreak(
                                      _animatingOldStreak ?? 0, false);
                                  textColor = iconColor;
                                  displayStreak =
                                      _animatingOldStreak ?? currentStreak;
                                } else {
                                  final colorProgress =
                                      (animationProgress - 0.5) * 2;
                                  final oldColor = _getStreakCardColorForStreak(
                                      _animatingOldStreak ?? 0, false);
                                  final newColor =
                                      Theme.of(context).primaryColor;
                                  iconColor = Color.lerp(
                                          oldColor, newColor, colorProgress) ??
                                      newColor;
                                  textColor = iconColor;
                                  displayStreak =
                                      _animatingNewStreak ?? currentStreak;
                                }
                              } else {
                                iconColor = currentStreak > 0
                                    ? _getStreakCardColor(
                                        context, hasExtendedStreakToday)
                                    : Colors.grey;
                                textColor = currentStreak > 0
                                    ? _getStreakCardColor(
                                        context, hasExtendedStreakToday)
                                    : Colors.grey[600] ?? Colors.grey;
                                displayStreak = currentStreak;
                              }

                              final showMedal =
                                  streakRank >= 1 && streakRank <= 3;

                              return Transform.scale(
                                scale: finalScale,
                                child: Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                  children: [
                                    if (showMedal)
                                      Text(
                                        streakRank == 1
                                            ? '🥇'
                                            : streakRank == 2
                                                ? '🥈'
                                                : '🥉',
                                        style: const TextStyle(fontSize: 36),
                                      )
                                    else
                                      Icon(
                                        Icons.local_fire_department,
                                        color: iconColor,
                                        size: 40,
                                      ),
                                    Text(
                                      '$displayStreak',
                                      style: Theme.of(context)
                                          .textTheme
                                          .displayMedium
                                          ?.copyWith(
                                            color: textColor,
                                            fontWeight: FontWeight.bold,
                                          ),
                                    ),
                                  ],
                                ),
                              );
                            },
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}
