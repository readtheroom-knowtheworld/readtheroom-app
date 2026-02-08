// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/suggestion_watchlist_service.dart';
import '../services/user_service.dart';
import '../services/notification_service.dart';
import 'question_activity_permission_dialog.dart';

class SuggestionNotificationBell extends StatelessWidget {
  final Map<String, dynamic> suggestion;
  final VoidCallback? onToggle;

  const SuggestionNotificationBell({
    Key? key,
    required this.suggestion,
    this.onToggle,
  }) : super(key: key);

  int _getCommentCount(Map<String, dynamic> suggestion) {
    return suggestion['comment_count'] as int? ?? 0;
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<SuggestionWatchlistService>(
      builder: (context, watchlistService, child) {
        final suggestionId = suggestion['id']?.toString();
        if (suggestionId == null) return SizedBox.shrink();

        final isWatching = watchlistService.isWatching(suggestionId);
        final commentCount = _getCommentCount(suggestion);

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
                // Show the permission dialog
                await QuestionActivityPermissionDialog.show(
                  context,
                  onPermissionGranted: () async {
                    // Permission granted - enable notifications and subscribe to the suggestion
                    final userService = Provider.of<UserService>(context, listen: false);
                    userService.setNotifyResponses(true);
                    
                    final nowWatching = await watchlistService.toggleSubscription(
                      suggestionId, 
                      commentCount,
                    );
                    
                    if (nowWatching) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Row(
                            children: [
                              Icon(Icons.notifications_active, color: Colors.white, size: 20),
                              SizedBox(width: 8),
                              Expanded(child: Text('Subscribed! You\'ll be notified when there are new comments.')),
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
              suggestionId, 
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
                      Expanded(child: Text('Subscribed! You\'ll be notified when there are new comments.')),
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
                      Expanded(child: Text('Unsubscribed. You will not be notified about this suggestion.')),
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
          tooltip: isWatching ? 'Turn off notifications' : 'Get notified of new comments',
        );
      },
    );
  }
}

// Helper function to auto-subscribe users to suggestions they create
class SuggestionAutoSubscriptionHelper {
  static Future<void> autoSubscribeToPostedSuggestion(
    BuildContext context,
    Map<String, dynamic> suggestion,
  ) async {
    final watchlistService = Provider.of<SuggestionWatchlistService>(context, listen: false);
    final suggestionId = suggestion['id']?.toString();
    final commentCount = suggestion['comment_count'] as int? ?? 0;

    if (suggestionId != null && !watchlistService.isWatching(suggestionId)) {
      await watchlistService.subscribeToSuggestion(suggestionId, commentCount, source: 'author');
      // Silently subscribe to own suggestions without showing a snackbar
    }
  }
}