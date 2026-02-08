// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'onboarding_slide.dart';

class WelcomeSlide extends StatelessWidget {
  final VoidCallback onNext;

  const WelcomeSlide({Key? key, required this.onNext}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return OnboardingSlide(
      title: "Welcome to Read the Room!",
      description: "My name is Curio, the Chameleon.\n\nTogether, we are going to map the mood of our planet.",
      showCurio: true,
      onNext: onNext,
      buttonText: "Let's go! 🦎",
      illustration: Container(
        padding: EdgeInsets.all(20),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.public,
              size: 80,
              color: Theme.of(context).primaryColor,
            ),
            SizedBox(height: 16),
            Text(
              "",
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.bold,
                color: Theme.of(context).primaryColor,
              ),
              textAlign: TextAlign.center,
            ),
            SizedBox(height: 8),
            Text(
              "We'll produce real-time insights into how the world feels",
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).brightness == Brightness.dark 
                    ? Colors.white70 
                    : Colors.black87,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
