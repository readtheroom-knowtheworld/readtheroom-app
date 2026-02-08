// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/watchlist_service.dart';
import '../services/user_service.dart';
import '../services/notification_service.dart';
import 'question_activity_permission_dialog.dart';

class NotificationBell extends StatelessWidget {
  final Map<String, dynamic> question;
  final VoidCallback? onToggle;

  const NotificationBell({
    Key? key,
    required this.question,
    this.onToggle,
  }) : super(key: key);

  int _getCommentCount(Map<String, dynamic> question) {
    return question['comment_count'] as int? ?? 0;
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<WatchlistService>(
      builder: (context, watchlistService, child) {
        final questionId = question['id']?.toString();
        if (questionId == null) return SizedBox.shrink();

        final isWatching = watchlistService.isWatching(questionId);
        final voteCount = question['votes'] as int? ?? 0;
        final commentCount = _getCommentCount(question);

        return IconButton(
          icon: Icon(
            isWatching ? Icons.notifications_active : Icons.notifications_none,
            color: isWatching ? Theme.of(context).primaryColor : null,
          ),
          onPressed: () async {
            final wasWatching = isWatching;
            
            if (!wasWatching) {
              // User is trying to subscribe - check permissions first
              final userService = Provider.of<UserService>(context, listen: false);
              final notificationService = NotificationService();
              
              // Check if notification permissions are granted AND user has enabled notifications
              final permissionsGranted = await notificationService.arePermissionsGranted();
              final notificationsEnabled = userService.notifyResponses;
              
              if (!permissionsGranted || !notificationsEnabled) {
                // Show the q-activity permission dialog
                await QuestionActivityPermissionDialog.show(
                  context,
                  onPermissionGranted: () async {
                    // Permission granted - enable notifications and subscribe to the question
                    final userService = Provider.of<UserService>(context, listen: false);
                    userService.setNotifyResponses(true);
                    
                    final nowWatching = await watchlistService.toggleSubscription(
                      questionId, 
                      voteCount,
                      commentCount,
                    );
                    
                    if (nowWatching) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Row(
                            children: [
                              Icon(Icons.notifications_active, color: Colors.white, size: 20),
                              SizedBox(width: 8),
                              Expanded(child: Text('Subscribed! You\'ll be notified when there is new activity.')),
                            ],
                          ),
                          backgroundColor: Theme.of(context).primaryColor,
                          duration: Duration(seconds: 3),
                        ),
                      );
                    }
                    
                    // Call optional callback
                    onToggle?.call();
                  },
                  onPermissionDenied: () async {
                    // Permission denied - don't subscribe
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Row(
                          children: [
                            Icon(Icons.notifications_off, color: Colors.white, size: 20),
                            SizedBox(width: 8),
                            Expanded(child: Text('Notifications are disabled. You can enable them in Settings.')),
                          ],
                        ),
                        backgroundColor: Colors.orange,
                        duration: Duration(seconds: 4),
                      ),
                    );
                  },
                );
                return;
              }
            }
            
            // Toggle subscription (either unsubscribing or subscribing with permissions already granted)
            final nowWatching = await watchlistService.toggleSubscription(
              questionId, 
              voteCount,
              commentCount,
            );

            // Show appropriate snackbar
            if (nowWatching) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Row(
                    children: [
                      Icon(Icons.notifications_active, color: Colors.white, size: 20),
                      SizedBox(width: 8),
                      Expanded(child: Text('Subscribed! You\'ll be notified when there is new activity.')),
                    ],
                  ),
                  backgroundColor: Theme.of(context).primaryColor,
                  duration: Duration(seconds: 3),
                ),
              );
            } else {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Row(
                    children: [
                      Icon(Icons.notifications_off, color: Colors.white, size: 20),
                      SizedBox(width: 8),
                      Expanded(child: Text('Unsubscribed. You will not be notified about this question.')),
                    ],
                  ),
                  backgroundColor: Theme.of(context).primaryColor,
                  duration: Duration(seconds: 3),
                ),
              );
            }

            // Call optional callback
            onToggle?.call();
          },
          tooltip: isWatching ? 'Turn off notifications' : 'Get notified of new activity',
        );
      },
    );
  }
}

// Helper function to auto-subscribe users to questions they create or save
class AutoSubscriptionHelper {
  static Future<void> autoSubscribeToPostedQuestion(
    BuildContext context,
    Map<String, dynamic> question,
  ) async {
    final watchlistService = Provider.of<WatchlistService>(context, listen: false);
    final questionId = question['id']?.toString();
    final voteCount = question['votes'] as int? ?? 0;
    final commentCount = question['comment_count'] as int? ?? 0;

    if (questionId != null && !watchlistService.isWatching(questionId)) {
      await watchlistService.subscribeToQuestion(questionId, voteCount, commentCount);
      // Silently subscribe to own questions without showing a snackbar
    }
  }

  static Future<void> autoSubscribeToSavedQuestion(
    BuildContext context,
    Map<String, dynamic> question,
  ) async {
    final watchlistService = Provider.of<WatchlistService>(context, listen: false);
    final questionId = question['id']?.toString();
    final voteCount = question['votes'] as int? ?? 0;
    final commentCount = question['comment_count'] as int? ?? 0;

    if (questionId != null && !watchlistService.isWatching(questionId)) {
      await watchlistService.subscribeToQuestion(questionId, voteCount, commentCount);
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              Icon(Icons.notifications_active, color: Colors.white, size: 20),
              SizedBox(width: 8),
              Expanded(child: Text('You\'re now watching this saved question for new activity!')),
            ],
          ),
          backgroundColor: Theme.of(context).primaryColor,
          duration: Duration(seconds: 6), // Longer duration for user to see "Turn Off"
          action: SnackBarAction(
            label: 'Turn Off',
            textColor: Colors.white,
            onPressed: () {
              watchlistService.unsubscribeFromQuestion(questionId);
            },
          ),
        ),
      );
    }
  }
} 