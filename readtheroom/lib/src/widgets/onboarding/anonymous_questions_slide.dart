// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'onboarding_slide.dart';

class AnonymousQuestionsSlide extends StatelessWidget {
  final VoidCallback onNext;

  const AnonymousQuestionsSlide({Key? key, required this.onNext}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return OnboardingSlide(
      title: "Anonymous Questions",
      description: "Questions are posted anonymously and addressed to your city, country, or the world.",
      showCurio: true,
      onNext: onNext,
      customContent: Container(
        padding: EdgeInsets.all(20),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Mock new question interface
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
                  Row(
                    children: [
                      Icon(Icons.create, color: Theme.of(context).primaryColor),
                      SizedBox(width: 8),
                      Text(
                        "Do you think that...?",
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: 16),
                  // Question Types indicators
                  Text(
                    "Example Question Types",
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: _buildTypeChip(
                          context,
                          icon: Icons.check_box,
                          label: "Pick One",
                          isSelected: true,
                        ),
                      ),
                      SizedBox(width: 8),
                      Expanded(
                        child: _buildTypeChip(
                          context,
                          icon: Icons.thumbs_up_down,
                          label: "Thumbs?",
                          isSelected: false,
                        ),
                      ),
                      SizedBox(width: 8),
                      Expanded(
                        child: _buildTypeChip(
                          context,
                          icon: Icons.text_fields,
                          label: "Text response",
                          isSelected: false,
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: 16),
                  Text(
                    "Target Audiences",
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: _buildScopeChip(context, Icons.public, "The World", true),
                      ),
                      SizedBox(width: 8),
                      Expanded(
                        child: _buildScopeChip(context, Icons.flag, "My Country", false),
                      ),
                      SizedBox(width: 8),
                      Expanded(
                        child: _buildScopeChip(context, Icons.location_city, "My City", false),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            SizedBox(height: 20),
            Text(
              "🔒 Your identity stays private",
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w500,
                color: Theme.of(context).primaryColor,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTypeChip(BuildContext context, {required IconData icon, required String label, required bool isSelected}) {
    return Container(
      height: 60,
      padding: EdgeInsets.symmetric(vertical: 8, horizontal: 6),
      decoration: BoxDecoration(
        color: isSelected ? Theme.of(context).primaryColor : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isSelected ? Theme.of(context).primaryColor : Colors.grey[400]!,
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 20,
            color: isSelected ? Colors.white : Colors.grey[600],
          ),
          SizedBox(height: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 9,
              fontWeight: FontWeight.bold,
              color: isSelected ? Colors.white : Colors.grey[600],
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _buildScopeChip(BuildContext context, IconData icon, String label, bool isSelected) {
    return Container(
      height: 60,
      padding: EdgeInsets.symmetric(vertical: 8, horizontal: 6),
      decoration: BoxDecoration(
        color: isSelected ? Theme.of(context).primaryColor : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isSelected ? Theme.of(context).primaryColor : Colors.grey[400]!,
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 20,
            color: isSelected ? Colors.white : Colors.grey[600],
          ),
          SizedBox(height: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 9,
              fontWeight: FontWeight.bold,
              color: isSelected ? Colors.white : Colors.grey[600],
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}
