// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:math';

class CurioLoading extends StatefulWidget {
  const CurioLoading({Key? key}) : super(key: key);

  @override
  State<CurioLoading> createState() => _CurioLoadingState();
}

class _CurioLoadingState extends State<CurioLoading> with SingleTickerProviderStateMixin {
  int _currentPhraseIndex = 0;
  Timer? _timer;
  late AnimationController _animationController;
  late Animation<double> _fadeAnimation;
  final Random _random = Random();

  final List<String> _loadingPhrases = [
    'Thanks for being a part of this <3',
    'Chameleons now represent 50 countries! \n🇴🇲🇨🇦🇺🇸🇹🇼🇭🇰🇸🇬🇬🇧🇳🇴🇵🇸🇨🇳🇵🇰🇮🇳',
    'Reading the room... 👓',
    'Gathering global insights... 🗺️',
    'Connecting chameleons... 🦎',
    'Analyzing the zeitgeist... 🔍',
    'Mapping the moment... 🕒',
    'Tuning into the world... 🌍',
    'Perplexing perspectives... 🤔',
    'Entering the hivemind... 🐝',
    'Tapping into the network... 🌐',
    'Remember, someone, somewhere, is waiting too... ⏳',
    'Measuring the mood... 📐',
    'The lizard is listening... 🦎',
    'Just checking the vibes...🌴',
    'Calibrating the conversation... 🛠️',
    'Crowdsourcing clarity... 💡',
    'Waiting on wisdom... 🧠',
    'Running a vibe check... ✅',
    'The world\'s first human bioindicator 🧪',
    'Consensus under construction... 🚧',
    'Testing the waters... 🌡️',
    'Open source, always 🛠️',
    'Big questions take a moment.\nWe\'re only human after all...',
    'You can swipe between questions 👉👈️',
    'Dismiss uninteresting questions by swiping left 👈️💨',
    'Invite your friends and family to a room from the Me page!\n\nSee how your network compares to the world\'s 🌐',
    'Invite friends to join in!\nUse the QR in the sidebar! 📷+📱',
    'Did you know we have home screen widgets?',
    'Did you know you can switch between light/dark mode in Settings?',
  ];

  @override
  void initState() {
    super.initState();
    
    // Start with a random phrase instead of always starting with index 0
    _currentPhraseIndex = _random.nextInt(_loadingPhrases.length);
    
    _animationController = AnimationController(
      duration: Duration(milliseconds: 785),
      vsync: this,
    );
    
    _fadeAnimation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeInOut,
    ));

    _animationController.forward();
    
    // Only start cycling messages after normal loading time (2.8s) has passed
    // This keeps the initial random message static for normal loading duration
    _timer = Timer(Duration(milliseconds: 2800), () {
      if (mounted) {
        // If we're still loading after 2.8s, start cycling messages
        _startMessageCycling();
      }
    });
  }

  void _startMessageCycling() {
    // Start cycling through messages every ~2 seconds for slow loading
    _timer?.cancel(); // Cancel the initial timer
    _timer = Timer.periodic(Duration(milliseconds: 2094), (timer) {
      if (mounted) {
        setState(() {
          // Pick a random index that's different from the current one
          int newIndex;
          do {
            newIndex = _random.nextInt(_loadingPhrases.length);
          } while (newIndex == _currentPhraseIndex && _loadingPhrases.length > 1);
          _currentPhraseIndex = newIndex;
        });
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _animationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: FadeTransition(
        opacity: _fadeAnimation,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Curio image with subtle pulse animation that reaches max size at end of loading
            TweenAnimationBuilder<double>(
              tween: Tween(begin: 0.9, end: 1.1),
              duration: Duration(milliseconds: 2800), // Match loading duration
              builder: (context, scale, child) {
                return Transform.scale(
                  scale: scale,
                  child: Image.asset(
                    'assets/images/Curio_smiling_trans.png',
                    height: 180,
                    width: 180,
                  ),
                );
              },
              onEnd: () {
                // Restart the animation for continuous pulsing
                if (mounted) {
                  setState(() {});
                }
              },
            ),
            
            SizedBox(height: 64),
            
            // Rotating text phrases with smooth transition
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32.0),
              child: AnimatedSwitcher(
                duration: Duration(milliseconds: 600),
                transitionBuilder: (Widget child, Animation<double> animation) {
                  return FadeTransition(
                    opacity: animation,
                    child: SlideTransition(
                      position: Tween<Offset>(
                        begin: Offset(0.0, 0.3),
                        end: Offset.zero,
                      ).animate(animation),
                      child: child,
                    ),
                  );
                },
                child: Text(
                  _loadingPhrases[_currentPhraseIndex],
                  key: ValueKey<int>(_currentPhraseIndex),
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: Theme.of(context).textTheme.bodyMedium?.color?.withOpacity(0.7),
                    fontWeight: FontWeight.w500,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
            
            SizedBox(height: 24),
            
            // Subtle loading indicator
            SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation<Color>(
                  Theme.of(context).primaryColor.withOpacity(0.6),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
} 
