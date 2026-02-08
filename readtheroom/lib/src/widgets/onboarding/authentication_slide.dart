// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../screens/authentication_screen.dart';
import 'onboarding_slide.dart';

class AuthenticationSlide extends StatefulWidget {
  final VoidCallback onNext;

  const AuthenticationSlide({Key? key, required this.onNext}) : super(key: key);

  @override
  _AuthenticationSlideState createState() => _AuthenticationSlideState();
}

class _AuthenticationSlideState extends State<AuthenticationSlide> {
  void _navigateToAuthentication() async {
    // Navigate to authentication screen
    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => AuthenticationScreen(
          onAuthComplete: () {
            // Pop back to onboarding
            Navigator.pop(context, true);
          },
        ),
      ),
    );
    
    // If authentication was successful, proceed to next slide
    if (result == true && mounted) {
      widget.onNext();
    }
  }

  @override
  Widget build(BuildContext context) {
    // If user is already authenticated, just show next button
    if (Supabase.instance.client.auth.currentUser != null) {
      return OnboardingSlide(
        title: "Already Authenticated! ✅",
        description: "Great! You're already authenticated and ready to go.",
        showCurio: true,
        onNext: widget.onNext,
        buttonText: "Continue 🚀",
        customContent: Container(
          padding: EdgeInsets.all(20),
          child: Container(
            padding: EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Theme.of(context).primaryColor.withOpacity(0.1),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Theme.of(context).primaryColor.withOpacity(0.3)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.verified_user, color: Theme.of(context).primaryColor, size: 24),
                SizedBox(width: 12),
                Text(
                  "Authentication Complete",
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: Theme.of(context).primaryColor,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    // Show authentication slide with direct button
    return OnboardingSlide(
      title: "Authenticate as Human",
      description: "Everyone needs to prove to us that they are a human to prevent bots voting on the platform!\n\nWe do this with Passkeys: by unlocking your device you are validating that you are the device's owner.",
      showCurio: true,
      onNext: null, // No default next button
      customContent: Container(
        padding: EdgeInsets.all(20),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Authentication button
            SizedBox(
              width: 280,
              child: ElevatedButton.icon(
                onPressed: _navigateToAuthentication,
                icon: Icon(Icons.fingerprint),
                label: Text('Authenticate as Human'),
                style: ElevatedButton.styleFrom(
                  padding: EdgeInsets.symmetric(vertical: 16),
                  backgroundColor: Colors.white,
                  foregroundColor: Colors.black87,
                  elevation: 2,
                  side: BorderSide(color: Colors.grey.shade300),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
