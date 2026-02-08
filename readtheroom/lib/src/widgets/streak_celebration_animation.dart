// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

// lib/src/widgets/streak_celebration_animation.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../utils/haptic_utils.dart';

class StreakCelebrationAnimation extends StatefulWidget {
  final VoidCallback? onComplete;
  final int oldStreak;
  final int newStreak;
  
  const StreakCelebrationAnimation({
    Key? key,
    this.onComplete,
    required this.oldStreak,
    required this.newStreak,
  }) : super(key: key);

  @override
  StreakCelebrationAnimationState createState() => StreakCelebrationAnimationState();
}

class StreakCelebrationAnimationState extends State<StreakCelebrationAnimation>
    with TickerProviderStateMixin {
  late AnimationController _controller;
  late AnimationController _confettiController;
  late Animation<double> _fadeAnimation;
  late Animation<double> _confettiAnimation;
  bool _showFireIcon = false;
  int _displayStreak = 0;
  bool _showIncrement = false;

  @override
  void initState() {
    super.initState();
    
    _controller = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    );
    
    _confettiController = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    );
    
    _fadeAnimation = Tween<double>(
      begin: 1.0,
      end: 0.0,
    ).animate(CurvedAnimation(
      parent: _controller,
      curve: Curves.easeInOut,
    ));
    
    _confettiAnimation = Tween<double>(
      begin: 0.3,
      end: 1.0,
    ).animate(CurvedAnimation(
      parent: _confettiController,
      curve: Curves.elasticOut,
    ));
    
    // Start confetti zoom animation immediately with haptic feedback
    _confettiController.forward();
    AppHaptics.mediumImpact();
    
    // Don't initialize _displayStreak here, let the animation control it
    _startAnimation();
  }

  void _startAnimation() async {
    try {
      // Show confetti for 1.5 seconds
      await Future.delayed(Duration(milliseconds: 1500));
      
      // Switch to fire icon with OLD streak first
      if (mounted) {
        setState(() {
          _showFireIcon = true;
          _displayStreak = widget.oldStreak; // Show old streak first
          _showIncrement = false;
        });
        print('Showing old streak: ${widget.oldStreak}');
      }
      
      // Show old streak for 1.2 seconds
      await Future.delayed(Duration(milliseconds: 1200));
      
      // Show +1 animation first
      if (mounted) {
        setState(() {
          _showIncrement = true; // Show +1 without changing number yet
        });
        print('Showing +1 animation');
      }
      
      // Wait for +1 to appear, then increment the number
      await Future.delayed(Duration(milliseconds: 600));
      
      if (mounted) {
        setState(() {
          _displayStreak = widget.newStreak; // Now increment to new streak
          _showIncrement = false; // Remove +1
        });
        print('Incrementing from ${widget.oldStreak} to ${widget.newStreak}');
      }
      
      // Show new streak for 1.5 seconds, then start smooth fade out
      await Future.delayed(Duration(milliseconds: 1500));
      _controller.forward();
      await Future.delayed(Duration(milliseconds: 1500));
      
      // Complete animation
      if (mounted && widget.onComplete != null) {
        widget.onComplete!();
      }
    } catch (e) {
      print('Animation error: $e');
      if (mounted && widget.onComplete != null) {
        widget.onComplete!();
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _confettiController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: IgnorePointer(
        child: Container(
          color: Colors.black.withOpacity(0.1),
          child: Center(
            child: _showFireIcon 
              ? FadeTransition(
                  opacity: _fadeAnimation,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        padding: EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          color: Theme.of(context).primaryColor,
                          borderRadius: BorderRadius.circular(20),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.2),
                              blurRadius: 10,
                            ),
                          ],
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.local_fire_department,
                              color: Colors.white,
                              size: 50,
                            ),
                            SizedBox(width: 12),
                            AnimatedSwitcher(
                              duration: Duration(milliseconds: 500),
                              child: Text(
                                '$_displayStreak',
                                key: ValueKey(_displayStreak),
                                style: TextStyle(
                                  fontSize: 36,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.white,
                                  decoration: TextDecoration.none,
                                ),
                              ),
                            ),
                            if (_showIncrement)
                              TweenAnimationBuilder(
                                duration: Duration(milliseconds: 300),
                                tween: Tween<double>(begin: 0, end: 1),
                                builder: (context, value, child) {
                                  return Transform.scale(
                                    scale: value,
                                    child: Text(
                                      ' +1',
                                      style: TextStyle(
                                        fontSize: 24,
                                        fontWeight: FontWeight.bold,
                                        color: Colors.greenAccent,
                                        decoration: TextDecoration.none,
                                      ),
                                    ),
                                  );
                                },
                              ),
                          ],
                        ),
                      ),
                      SizedBox(height: 20),
                      Container(
                        padding: EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: Theme.of(context).primaryColor,
                          borderRadius: BorderRadius.circular(16),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.2),
                              blurRadius: 8,
                            ),
                          ],
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Image.asset(
                              'assets/images/Curio_smiling_trans.png',
                              height: 150,
                              width: 150,
                            ),
                            SizedBox(height: 12),
                            Text(
                              'Thanks for contributing today!',
                              textAlign: TextAlign.center,
                              style: TextStyle(
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
                )
              : AnimatedBuilder(
                  animation: _confettiAnimation,
                  builder: (context, child) {
                    return Transform.scale(
                      scale: _confettiAnimation.value,
                      child: Text(
                        '🎉',
                        style: TextStyle(
                          fontSize: 100,
                          decoration: TextDecoration.none,
                        ),
                      ),
                    );
                  },
                ),
          ),
        ),
      ),
    );
  }
}

// Overlay controller for managing the celebration animation
class StreakCelebrationOverlay {
  static OverlayEntry? _overlayEntry;
  static bool _isShowing = false;

  static void show(BuildContext context, {required int oldStreak, required int newStreak, VoidCallback? onComplete}) {
    if (_isShowing) return; // Prevent multiple overlays
    
    _isShowing = true;
    _overlayEntry = OverlayEntry(
      builder: (context) => StreakCelebrationAnimation(
        oldStreak: oldStreak,
        newStreak: newStreak,
        onComplete: () {
          hide();
          onComplete?.call();
        },
      ),
    );
    
    Overlay.of(context).insert(_overlayEntry!);
  }

  static void hide() {
    if (_overlayEntry != null) {
      _overlayEntry!.remove();
      _overlayEntry = null;
    }
    _isShowing = false;
  }
}