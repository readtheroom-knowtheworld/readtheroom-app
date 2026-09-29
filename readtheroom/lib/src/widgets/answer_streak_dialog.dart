// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The one Answer Streak dialog. Opened from the top bar's streak pill
// (StreakCard) and from the Me screen's streak card, so the two can never
// drift apart again. Callers pass the values they already compute for their
// own card (streak, rank, urgency colour); the longest-streak record lives
// here.

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/analytics_service.dart';

const String _longestAnswerStreakKey = 'longest_answer_streak';

/// Rainbow ring for a top-five or 100+ day streak; null otherwise.
BoxDecoration? answerStreakDialogBorder(int currentStreak,
    {required bool isTopFive}) {
  if (!(isTopFive || currentStreak > 100)) return null;
  return BoxDecoration(
    borderRadius: BorderRadius.circular(12),
    gradient: const LinearGradient(
      colors: [
        Colors.red,
        Colors.orange,
        Colors.yellow,
        Colors.green,
        Colors.blue,
        Colors.indigo,
        Colors.purple,
      ],
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
    ),
  );
}

/// Shows the Answer Streak dialog. [streakColor] is the caller's card colour
/// and [shouldShowUrgent] whether the "running out of time" line appears.
Future<void> showAnswerStreakDialog(
  BuildContext context, {
  required int currentStreak,
  required int streakRank,
  required Color streakColor,
  required bool shouldShowUrgent,
}) async {
  final prefs = await SharedPreferences.getInstance();
  final longestStreak = prefs.getInt(_longestAnswerStreakKey) ?? 0;
  if (currentStreak > longestStreak) {
    await prefs.setInt(_longestAnswerStreakKey, currentStreak);
  }

  final isTopFive = streakRank >= 1 && streakRank <= 5;
  final isRecord = currentStreak > 0 && currentStreak >= longestStreak;
  final showRainbow = isTopFive || currentStreak > 100;
  final dialogBorder =
      answerStreakDialogBorder(currentStreak, isTopFive: isTopFive);

  if (!context.mounted) return;

  await showDialog<void>(
    context: context,
    builder: (context) => Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Container(
        decoration: dialogBorder,
        padding: showRainbow ? const EdgeInsets.all(3) : EdgeInsets.zero,
        child: Container(
          decoration: BoxDecoration(
            color: Theme.of(context).dialogBackgroundColor,
            borderRadius: BorderRadius.circular(showRainbow ? 9 : 12),
          ),
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Answer Streak',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '$currentStreak',
                    style: Theme.of(context).textTheme.displayLarge?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: Theme.of(context).primaryColor,
                        ),
                  ),
                  if (streakRank >= 1 && streakRank <= 3) ...[
                    const SizedBox(width: 8),
                    Text(
                      streakRank == 1
                          ? '🥇'
                          : streakRank == 2
                              ? '🥈'
                              : '🥉',
                      style: const TextStyle(fontSize: 32),
                    ),
                  ],
                ],
              ),
              if (streakRank > 0 && currentStreak > 0) ...[
                const SizedBox(height: 16),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: isTopFive
                        ? Theme.of(context).primaryColor.withOpacity(0.1)
                        : Theme.of(context).cardColor,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: isTopFive
                          ? Theme.of(context).primaryColor.withOpacity(0.3)
                          : Theme.of(context).dividerColor,
                    ),
                  ),
                  child: Text(
                    isTopFive
                        ? 'You are #$streakRank among all active streaks!'
                        : 'Ranked #$streakRank among all active streaks',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: isTopFive
                              ? Theme.of(context).primaryColor
                              : null,
                        ),
                    textAlign: TextAlign.center,
                  ),
                ),
              ],
              const SizedBox(height: 20),
              Text(
                isRecord && currentStreak > 0
                    ? 'This is your longest streak ever!'
                    : 'Your longest streak was $longestStreak day${longestStreak == 1 ? '' : 's'}.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color:
                          isRecord ? Theme.of(context).primaryColor : null,
                      fontWeight: isRecord ? FontWeight.w600 : null,
                    ),
                textAlign: TextAlign.center,
              ),
              if (shouldShowUrgent) ...[
                const SizedBox(height: 16),
                Text(
                  'You\'re running out of time today! Ask or answer a question to keep your streak.',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: streakColor,
                        fontWeight: FontWeight.w600,
                      ),
                  textAlign: TextAlign.center,
                ),
              ],
              const SizedBox(height: 16),
              Text(
                'A streak is the number of consecutive days you ask or answer a question.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Colors.grey[600],
                    ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              GestureDetector(
                onTap: () async {
                  AnalyticsService()
                      .trackEvent('streak_dialog_widget_link_tapped');
                  final uri = Uri.parse('https://readtheroom.site/widgets/');
                  if (await canLaunchUrl(uri)) {
                    await launchUrl(uri,
                        mode: LaunchMode.externalApplication);
                  }
                },
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Theme.of(context).primaryColor.withOpacity(0.08),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: Theme.of(context).primaryColor.withOpacity(0.2),
                      width: 1,
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.widgets_outlined,
                        color: Theme.of(context).primaryColor,
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Do you like widgets?',
                          style:
                              Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: Theme.of(context).primaryColor,
                                  ),
                        ),
                      ),
                      Icon(
                        Icons.open_in_new,
                        color: Theme.of(context).primaryColor,
                        size: 14,
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Got it'),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
