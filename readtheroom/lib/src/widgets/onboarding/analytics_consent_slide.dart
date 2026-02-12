// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import '../../services/analytics_service.dart';
import 'onboarding_slide.dart';

class AnalyticsConsentSlide extends StatefulWidget {
  final VoidCallback onNext;

  const AnalyticsConsentSlide({Key? key, required this.onNext}) : super(key: key);

  @override
  State<AnalyticsConsentSlide> createState() => _AnalyticsConsentSlideState();
}

class _AnalyticsConsentSlideState extends State<AnalyticsConsentSlide> {
  bool _analyticsEnabled = true;

  @override
  Widget build(BuildContext context) {
    return OnboardingSlide(
      title: "Your Privacy, Your Choice",
      description: "Read the Room uses PostHog, an open-source analytics platform, to understand how people use the app. We only collect anonymous feature usage metrics — no personal data, no tracking across apps.",
      showCurio: true,
      onNext: widget.onNext,
      customContent: Container(
        padding: EdgeInsets.all(20),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _buildFeature(
              context,
              Icons.analytics_outlined,
              "Anonymous Metrics",
              "Which features are used and how often",
              Theme.of(context).primaryColor,
            ),
            SizedBox(height: 16),
            _buildFeature(
              context,
              Icons.code,
              "Open Source",
              "PostHog is fully open-source, just like us.",
              Theme.of(context).primaryColor,
            ),
            SizedBox(height: 16),
            _buildFeature(
              context,
              Icons.block,
              "No Personal Data",
              "No names, emails, or device fingerprints",
              Theme.of(context).primaryColor,
            ),
            SizedBox(height: 24),
            SwitchListTile(
              title: Text(
                'Share anonymous analytics',
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              subtitle: Text(
                _analyticsEnabled
                    ? 'Help improve Read the Room'
                    : 'Analytics are disabled',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Colors.grey[600],
                ),
              ),
              value: _analyticsEnabled,
              onChanged: (bool value) {
                setState(() {
                  _analyticsEnabled = value;
                });
                AnalyticsService().setOptOut(!value);
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFeature(BuildContext context, IconData icon, String title, String description, Color color) {
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
}
