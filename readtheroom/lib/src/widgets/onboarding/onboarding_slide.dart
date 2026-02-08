// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';

class OnboardingSlide extends StatelessWidget {
  final String title;
  final String description;
  final Widget? illustration;
  final VoidCallback? onNext;
  final String? buttonText;
  final bool showCurio;
  final Widget? customContent;

  const OnboardingSlide({
    Key? key,
    required this.title,
    required this.description,
    this.illustration,
    this.onNext,
    this.buttonText,
    this.showCurio = true,
    this.customContent,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: EdgeInsets.all(24.0),
      child: Column(
        children: [
          // Curio character
          if (showCurio) ...[
            SizedBox(height: 20),
            Container(
              width: 120,
              height: 120,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.teal[50],
              ),
              child: ClipOval(
                child: Image.asset(
                  'assets/images/Curio_smiling_trans.png',
                  width: 100,
                  height: 100,
                  fit: BoxFit.cover,
                  errorBuilder: (context, error, stackTrace) {
                    return Container(
                      width: 100,
                      height: 100,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.teal[100],
                      ),
                      child: Icon(
                        Icons.pets,
                        size: 50,
                        color: Colors.teal[600],
                      ),
                    );
                  },
                ),
              ),
            ),
            SizedBox(height: 24),
          ],

          // Title
          Text(
            title,
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.bold,
              color: Theme.of(context).primaryColor,
            ),
            textAlign: TextAlign.center,
          ),
          
          SizedBox(height: 16),
          
          // Description
          Text(
            description,
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
              height: 1.5,
              color: Theme.of(context).brightness == Brightness.dark 
                  ? Colors.white 
                  : Colors.black,
            ),
            textAlign: TextAlign.center,
          ),
          
          SizedBox(height: 32),
          
          // Illustration or custom content
          customContent ?? illustration ?? Container(),
          
          SizedBox(height: 32),
          
          // Swipe hint for slides with "Next" button
          if (onNext != null && (buttonText == null || buttonText == 'Next')) ...[
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.swipe_left,
                  color: Colors.grey[600],
                  size: 16,
                ),
                SizedBox(width: 4),
                Text(
                  'Swipe to continue',
                  style: TextStyle(
                    color: Colors.grey[600],
                    fontSize: 12,
                  ),
                ),
              ],
            ),
            SizedBox(height: 16),
          ],
          
          // Next button
          if (onNext != null)
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: onNext,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Theme.of(context).primaryColor,
                  foregroundColor: Colors.white,
                  padding: EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: Text(
                  buttonText ?? 'Next',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
            
          // Extra bottom padding to ensure button is always accessible
          SizedBox(height: 40),
        ],
      ),
    );
  }
}