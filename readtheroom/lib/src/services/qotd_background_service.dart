// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

// lib/src/services/qotd_background_service.dart
import 'dart:io' show Platform;
import 'package:workmanager/workmanager.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'home_widget_service.dart';

/// Background service for refreshing QOTD widget data.
///
/// Uses WorkManager on Android to periodically fetch QOTD from the server
/// and update the home screen widget, even when the app is closed.
/// iOS uses native BGTaskScheduler instead (configured in AppDelegate.swift).
class QOTDBackgroundService {
  static const String taskName = 'qotdRefreshTask';
  static const String taskTag = 'qotd_refresh';

  /// Initialize the background service and schedule periodic updates.
  /// Call this once during app startup.
  /// Only runs on Android - iOS uses native BGTaskScheduler.
  static Future<void> initialize() async {
    // Only initialize WorkManager on Android
    // iOS uses native BGTaskScheduler configured in AppDelegate.swift
    if (!Platform.isAndroid) {
      print('QOTD background service: Skipping WorkManager on iOS (uses native BGTaskScheduler)');
      return;
    }

    await Workmanager().initialize(
      callbackDispatcher,
      isInDebugMode: false,
    );

    // Schedule periodic task - runs approximately every 1 hour
    // (minimum interval on Android is 15 minutes)
    await Workmanager().registerPeriodicTask(
      taskName,
      taskName,
      tag: taskTag,
      frequency: const Duration(hours: 1),
      constraints: Constraints(
        networkType: NetworkType.connected,
      ),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.replace,
    );

    print('QOTD background refresh scheduled (Android, 1-hour interval)');
  }

  /// Cancel all scheduled background tasks.
  static Future<void> cancel() async {
    await Workmanager().cancelByTag(taskTag);
  }
}

/// Top-level callback for WorkManager.
/// This runs in a separate isolate, so we need to initialize Supabase here.
@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    try {
      print('QOTD background task started: $task');

      // Initialize Supabase in background isolate
      await Supabase.initialize(
        url: const String.fromEnvironment('SUPABASE_URL'),
        anonKey: const String.fromEnvironment('SUPABASE_ANON_KEY'),
      );

      final supabase = Supabase.instance.client;
      final now = DateTime.now();
      final dateKey = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';

      // Fetch QOTD from server
      final result = await supabase
          .from('question_of_the_day_history')
          .select('''
            question_id,
            questions!inner(
              id,
              prompt,
              votes,
              comment_count,
              is_hidden
            )
          ''')
          .eq('date', dateKey)
          .maybeSingle();

      if (result != null && result['questions'] != null) {
        final question = result['questions'];

        if (question['is_hidden'] != true) {
          // Initialize HomeWidgetService and update widget (Android only)
          await HomeWidgetService().initialize();
          await HomeWidgetService().updateQOTDWidget(
            questionText: question['prompt']?.toString() ?? '',
            voteCount: question['votes'] as int? ?? 0,
            commentCount: question['comment_count'] as int? ?? 0,
            hasAnswered: false, // Can't check this in background without user context
            questionId: question['id']?.toString() ?? '',
          );

          print('QOTD widget updated in background: ${question['prompt']}');
        }
      }

      return true;
    } catch (e) {
      print('QOTD background task error: $e');
      return false;
    }
  });
}
