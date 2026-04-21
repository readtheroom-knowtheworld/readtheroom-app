// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:url_launcher/url_launcher.dart';
import 'onboarding_slide.dart';

class PrivacySlide extends StatelessWidget {
  final VoidCallback onNext;

  const PrivacySlide({Key? key, required this.onNext}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return OnboardingSlide(
      title: "Privacy First",
      description: "We're all anonymous here.",
      showCurio: true,
      onNext: onNext,
      customContent: Container(
        padding: EdgeInsets.all(20),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Privacy features
            _buildPrivacyFeature(
              context,
              Icons.security,
              "Anonymous Responses",
              "Your votes are never linked to an identity",
              Theme.of(context).primaryColor,
            ),
            SizedBox(height: 16),
            _buildPrivacyFeature(
              context,
              Icons.phone_android,
              "Local Processing",
              "Most data stays on your device",
              Theme.of(context).primaryColor,
            ),
            SizedBox(height: 16),
            _buildPrivacyFeature(
              context,
              Icons.no_accounts,
              "No Personal Data",
              "We don't collect personal information",
              Theme.of(context).primaryColor,
            ),
            SizedBox(height: 16),
            _buildPrivacyFeature(
              context,
              Icons.code,
              "Open Source",
              "Our code is publicly available on GitHub",
              Theme.of(context).primaryColor,
            ),
            SizedBox(height: 24),
            
            // Privacy policy link
            RichText(
              textAlign: TextAlign.center,
              text: TextSpan(
                style: Theme.of(context).textTheme.bodyMedium,
                children: [
                  TextSpan(text: "🦎 Here is our full "),
                  TextSpan(
                    text: "privacy policy",
                    style: TextStyle(
                      color: Theme.of(context).primaryColor,
                      fontWeight: FontWeight.bold,
                    ),
                    recognizer: TapGestureRecognizer()
                      ..onTap = () => _launchPrivacyPolicy(),
                  ),
                ],
              ),
            ),
            SizedBox(height: 16),
            Text(
              "Just like a chameleon, you'll be hiding in plain sight!",
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

  Widget _buildPrivacyFeature(BuildContext context, IconData icon, String title, String description, Color color) {
    return Row(
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: color.withOpacity(0.1),
            shape: BoxShape.circle,
          ),
          child: Icon(
            icon,
            color: color,
            size: 20,
          ),
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
                  color: Theme.of(context).brightness == Brightness.dark 
                      ? Colors.white70 
                      : Colors.black87,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  void _launchPrivacyPolicy() async {
    final url = Uri.parse('https://readtheroom.site/privacy/');
    if (await canLaunchUrl(url)) {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    }
  }
}
