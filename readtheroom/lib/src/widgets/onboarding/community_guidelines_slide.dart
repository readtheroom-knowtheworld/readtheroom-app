// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:url_launcher/url_launcher.dart';
import 'onboarding_slide.dart';

class CommunityGuidelinesSlide extends StatelessWidget {
  final VoidCallback onNext;

  const CommunityGuidelinesSlide({Key? key, required this.onNext}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return OnboardingSlide(
      title: "Community Guidelines",
      description: "We're trying to be nice and curious here. So please no doxxing, harassment, or abuse.\n\nLet's keep the community curious, colourful, and cool as a chameleon.",
      showCurio: true,
      onNext: onNext,
      buttonText: "I understand 🦎",
      customContent: Container(
        padding: EdgeInsets.all(20),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Guidelines list
            Container(
              width: double.infinity,
              padding: EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Theme.of(context).cardColor,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.grey[300]!),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.1),
                    blurRadius: 8,
                    offset: Offset(0, 2),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    "Community Values",
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  SizedBox(height: 16),
                  _buildGuideline(
                    context,
                    "🎯",
                    "Be Curious",
                    "Ask thoughtful questions",
                  ),
                  SizedBox(height: 12),
                  _buildGuideline(
                    context,
                    "🌈",
                    "Be Colorful",
                    "Embrace diverse perspectives",
                  ),
                  SizedBox(height: 12),
                  _buildGuideline(
                    context,
                    "😎",
                    "Be Cool",
                    "Stay respectful and kind",
                  ),
                  SizedBox(height: 12),
                  _buildGuideline(
                    context,
                    "🚫",
                    "Zero Tolerance",
                    "For harassment, abuse, or incitement of violence",
                  ),
                ],
              ),
            ),
            SizedBox(height: 20),
            
            // Terms of service link
            RichText(
              textAlign: TextAlign.center,
              text: TextSpan(
                style: Theme.of(context).textTheme.bodyMedium,
                children: [
                  TextSpan(text: "Here are our full "),
                  TextSpan(
                    text: "terms of service",
                    style: TextStyle(
                      color: Theme.of(context).primaryColor,
                      fontWeight: FontWeight.bold,
                    ),
                    recognizer: TapGestureRecognizer()
                      ..onTap = () => _launchTerms(),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGuideline(BuildContext context, String emoji, String title, String description) {
    return Row(
      children: [
        Text(
          emoji,
          style: TextStyle(fontSize: 24),
        ),
        SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                description,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Colors.grey[600],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  void _launchTerms() async {
    final url = Uri.parse('https://readtheroom.site/terms/');
    if (await canLaunchUrl(url)) {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    }
  }
}
