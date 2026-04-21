// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'onboarding_slide.dart';

class DailyQuestionSlide extends StatelessWidget {
  final VoidCallback onNext;

  const DailyQuestionSlide({Key? key, required this.onNext}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return OnboardingSlide(
      title: "Question of the Day",
      description: "Every day, the world's most popular question is at the top of all our feeds.\n\nPlease contribute, help us measure the pulse of the planet!",
      showCurio: true,
      onNext: onNext,
      customContent: Container(
        padding: EdgeInsets.all(20),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Mock Question of the Day matching home screen styling
            Container(
              margin: EdgeInsets.fromLTRB(0, 4, 0, 12),
              padding: EdgeInsets.all(16),
              constraints: BoxConstraints(
                minHeight: 100,
              ),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    Theme.of(context).primaryColor.withOpacity(0.1),
                    Theme.of(context).primaryColor.withOpacity(0.05),
                  ],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: Theme.of(context).primaryColor.withOpacity(0.3),
                  width: 1,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.today,
                        color: Theme.of(context).primaryColor,
                        size: 16,
                      ),
                      SizedBox(width: 6),
                      Text(
                        'Question of the Day',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).primaryColor,
                          fontWeight: FontWeight.bold,
                          fontSize: 18,
                        ),
                      ),
                      SizedBox(width: 6),
                      Icon(
                        Icons.today,
                        color: Theme.of(context).primaryColor,
                        size: 16,
                      ),
                    ],
                  ),
                  SizedBox(height: 12),
                  Text(
                    "What's one small thing that made you smile today?",
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w500,
                      color: Theme.of(context).primaryColor,
                      fontSize: 16,
                    ),
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  SizedBox(height: 12),
                  Row(
                    children: [
                      Text(
                        '3,145 votes',
                        style: TextStyle(
                          color: Theme.of(context).primaryColor,
                          fontSize: 12,
                        ),
                      ),
                      Spacer(),
                      Text(
                        '7 comments',
                        style: TextStyle(
                          color: Theme.of(context).primaryColor,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            SizedBox(height: 20),
            Text(
              "🦎 Will your question make it up there?",
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
}
