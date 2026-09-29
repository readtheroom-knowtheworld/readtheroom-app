// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';

class LoadingMessageCycler extends StatefulWidget {
  const LoadingMessageCycler({Key? key}) : super(key: key);

  @override
  State<LoadingMessageCycler> createState() => _LoadingMessageCyclerState();
}

class _LoadingMessageCyclerState extends State<LoadingMessageCycler>
    with SingleTickerProviderStateMixin {
  static const _messages = [
    'Loading more questions...',
    'Digging through the archives...',
    'Dusting off some good ones...',
    'Asking the chameleons for more...',
    'Rummaging through the vault...',
    'Fetching hidden gems...',
    'Almost there...',
    'Unearthing forgotten classics...',
    'The chameleons are on it...',
    'Scouring the depths...',
    'Chasing my own tail...',
  ];

  static final _random = Random();
  late int _currentIndex;
  Timer? _timer;
  late AnimationController _fadeController;
  late Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
    _currentIndex = _random.nextInt(_messages.length);
    _fadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _fadeAnimation = CurvedAnimation(
      parent: _fadeController,
      curve: Curves.easeInOut,
    );
    _fadeController.value = 1.0;

    _timer = Timer.periodic(const Duration(milliseconds: 2500), (_) {
      _cycleMessage();
    });
  }

  void _cycleMessage() async {
    // Fade out
    await _fadeController.reverse();
    if (!mounted) return;
    setState(() {
      int next;
      do {
        next = _random.nextInt(_messages.length);
      } while (next == _currentIndex && _messages.length > 1);
      _currentIndex = next;
    });
    // Fade in
    _fadeController.forward();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _fadeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _fadeAnimation,
      child: Text(
        _messages[_currentIndex],
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: Colors.grey,
        ),
      ),
    );
  }
}
