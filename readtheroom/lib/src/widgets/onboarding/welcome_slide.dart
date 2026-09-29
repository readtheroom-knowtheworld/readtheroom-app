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
      description:
          "My name is Curio, the Chameleon.\n\nTogether, we're going to map the mood of our planet, one question at a time.",
      showCurio: true,
      onNext: onNext,
      buttonText: "Let's go! 🦎",
      customContent: _WelcomeContent(),
    );
  }
}

class _WelcomeContent extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).primaryColor;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Column(
      children: [
        SizedBox(height: 20),

        // Quick highlights of what the full guide covers.
        _buildHighlight(
          context,
          Icons.today,
          "One question a day",
          "Everyone, everywhere, answers the same question",
        ),
        SizedBox(height: 14),
        _buildHighlight(
          context,
          Icons.public,
          "Map the world",
          "Explore the world's opinions",
        ),
        SizedBox(height: 14),
        _buildHighlight(
          context,
          Icons.shield_outlined,
          "Privacy first",
          "Open source, no collection of personal data",
        ),
        SizedBox(height: 14),
        _buildHighlight(
          context,
          Icons.favorite_outline,
          "Be curious & kind",
          "No harassment, doxxing, or abuse",
        ),

        SizedBox(height: 8),
      ],
    );
  }

  Widget _buildHighlight(
    BuildContext context,
    IconData icon,
    String title,
    String description,
  ) {
    final primary = Theme.of(context).primaryColor;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Row(
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: primary.withOpacity(0.10),
            shape: BoxShape.circle,
          ),
          child: Icon(icon, color: primary, size: 20),
        ),
        SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: isDark ? Colors.white : Colors.black87,
                    ),
              ),
              SizedBox(height: 2),
              Text(
                description,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: isDark ? Colors.white70 : Colors.black54,
                      height: 1.3,
                    ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
