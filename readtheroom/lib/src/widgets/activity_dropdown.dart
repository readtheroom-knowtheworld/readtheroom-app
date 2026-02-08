// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/notification_item.dart';
import '../services/notification_log_service.dart';
import '../services/question_service.dart';
import '../services/user_service.dart';
import '../utils/theme_utils.dart';
import '../utils/time_utils.dart';

class ActivityDropdown extends StatefulWidget {
  final bool isAuthenticated;

  const ActivityDropdown({
    Key? key,
    required this.isAuthenticated,
  }) : super(key: key);

  @override
  _ActivityDropdownState createState() => _ActivityDropdownState();
}

class _ActivityDropdownState extends State<ActivityDropdown> {
  final NotificationLogService _notificationService = NotificationLogService();
  bool _hasUnviewedNotifications = false;

  @override
  void initState() {
    super.initState();
    _checkUnviewedNotifications();
  }

  Future<void> _checkUnviewedNotifications() async {
    if (widget.isAuthenticated) {
      final hasUnviewed = await _notificationService.hasUnviewedTodaysNotifications();
      if (mounted) {
        setState(() {
          _hasUnviewedNotifications = hasUnviewed;
        });
      }
    }
  }

  Future<void> _markAllAsViewed() async {
    await _notificationService.markAllTodaysNotificationsAsViewed();
    if (mounted) {
      setState(() {
        _hasUnviewedNotifications = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.only(bottom: 16),
      color: ThemeUtils.getDropdownBackgroundColor(context),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12.0),
      ),
      child: ExpansionTile(
        leading: Stack(
          children: [
            Icon(Icons.notifications_outlined),
            if (_hasUnviewedNotifications)
              Positioned(
                right: 0,
                top: 0,
                child: Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: Theme.of(context).primaryColor,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
          ],
        ),
        title: Row(
          children: [
            Text(
              'Activity',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            if (_hasUnviewedNotifications) ...[
              SizedBox(width: 8),
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: Theme.of(context).primaryColor,
                  shape: BoxShape.circle,
                ),
              ),
            ],
          ],
        ),
        onExpansionChanged: (expanded) {
          if (expanded && widget.isAuthenticated && _hasUnviewedNotifications) {
            // Mark all as viewed when user expands the dropdown
            _markAllAsViewed();
          } else if (expanded && !widget.isAuthenticated) {
            // Navigate to authentication if not authenticated
            Navigator.pushNamed(context, '/authentication');
          }
        },
        children: [
          if (!widget.isAuthenticated)
            ListTile(
              title: Text(
                'Authentication required',
                style: TextStyle(
                  color: Colors.grey[600],
                  fontStyle: FontStyle.italic,
                ),
              ),
              subtitle: Text(
                'Please authenticate to view notifications',
                style: TextStyle(
                  color: Colors.grey[500],
                  fontSize: 12,
                ),
              ),
            )
          else
            FutureBuilder<List<NotificationItem>>(
              future: _notificationService.getRecentTodaysNotifications(),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return Padding(
                    padding: EdgeInsets.all(16),
                    child: Center(child: CircularProgressIndicator()),
                  );
                }

                final notifications = snapshot.data ?? [];
                
                if (notifications.isEmpty) {
                  return ListTile(
                    leading: Icon(Icons.inbox_outlined, color: Colors.grey),
                    title: Text(
                      'No notifications today',
                      style: TextStyle(color: Colors.grey[600]),
                    ),
                    subtitle: Text(
                      'Your recent notifications live here',
                      style: TextStyle(color: Colors.grey[500], fontSize: 12),
                    ),
                  );
                }

                return Column(
                  children: notifications.map((notification) => 
                    _buildNotificationTile(notification)
                  ).toList(),
                );
              },
            ),
        ],
      ),
    );
  }

  Widget _buildNotificationTile(NotificationItem notification) {
    return Dismissible(
      key: ValueKey('notification_${notification.id}'),
      direction: DismissDirection.endToStart,
      background: Container(),
      secondaryBackground: Container(
        alignment: Alignment.centerRight,
        padding: EdgeInsets.symmetric(horizontal: 20),
        color: Colors.grey.withOpacity(0.8),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            Text(
              'Dismiss',
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
            ),
            SizedBox(width: 8),
            Icon(Icons.clear, color: Colors.white),
          ],
        ),
      ),
      confirmDismiss: (direction) async {
        await _notificationService.markAsDismissed(notification.id);
        
        // Show snackbar with undo option (same style as home_screen.dart)
        if (mounted) {
          await ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              backgroundColor: Theme.of(context).primaryColor,
              duration: Duration(seconds: 4),
              content: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('💨 Notification dismissed!'),
                  GestureDetector(
                    onTap: () {
                      ScaffoldMessenger.of(context).hideCurrentSnackBar();
                      _notificationService.undismissNotification(notification.id);
                      setState(() {}); // Refresh the UI to show the notification again
                    },
                    child: Text(
                      'UNDO',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ).closed;
        }
        
        return true;
      },
      child: ListTile(
        dense: true,
        leading: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: notification.isViewed 
                ? Colors.grey.withOpacity(0.1)
                : Theme.of(context).primaryColor.withOpacity(0.1),
            shape: BoxShape.circle,
          ),
          child: Center(
            child: Text(
              notification.displayType,
              style: TextStyle(fontSize: 18),
            ),
          ),
        ),
        title: Text(
          notification.title,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            fontWeight: notification.isViewed ? FontWeight.normal : FontWeight.w600,
            color: notification.isViewed ? Colors.grey[600] : null,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              notification.body,
              style: TextStyle(
                fontSize: 12,
                color: notification.isViewed ? Colors.grey[500] : Colors.grey[700],
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            SizedBox(height: 2),
            Text(
              getTimeAgo(notification.timestamp.toIso8601String()),
              style: TextStyle(
                fontSize: 10,
                color: Colors.grey[400],
              ),
            ),
          ],
        ),
        trailing: notification.isViewed 
            ? null 
            : Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: Theme.of(context).primaryColor,
                  shape: BoxShape.circle,
                ),
              ),
        onTap: () => _handleNotificationTap(notification),
      ),
    );
  }

  void _handleNotificationTap(NotificationItem notification) async {
    // Mark as viewed when tapped
    if (!notification.isViewed) {
      await _notificationService.markAsViewed(notification.id);
      setState(() {}); // Refresh the UI
    }

    // Navigate based on notification type
    if (notification.questionId != null) {
      await _navigateToQuestion(notification.questionId!);
    } else if (notification.suggestionId != null) {
      // Navigate to suggestion - keeping the original route navigation for now
      // TODO: Update this to use proper suggestion navigation if available
      Navigator.pushNamed(
        context, 
        '/suggestion/${notification.suggestionId}',
      );
    } else if (notification.type == 'system') {
      // For system notifications, show a dialogue with the full message
      _showSystemNotificationDialog(notification);
    }
    // For other notifications without specific targets, just mark as viewed
  }

  Future<void> _navigateToQuestion(String questionId) async {
    final questionService = Provider.of<QuestionService>(context, listen: false);
    final userService = Provider.of<UserService>(context, listen: false);
    
    try {
      // Show loading indicator
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => Center(
          child: CircularProgressIndicator(),
        ),
      );
      
      // Fetch complete question data
      final completeQuestion = await questionService.getQuestionById(questionId);
      
      // Hide loading indicator
      if (mounted) {
        Navigator.of(context).pop();
      }
      
      if (completeQuestion != null) {
        // Check if user has answered this question
        final hasAnswered = userService.hasAnsweredQuestion(completeQuestion['id']);
        
        // Navigate to appropriate screen
        if (hasAnswered) {
          await questionService.navigateToResultsScreen(
            context, 
            completeQuestion,
            fromUserScreen: true,
          );
        } else {
          await questionService.navigateToAnswerScreen(
            context, 
            completeQuestion,
            fromUserScreen: true,
          );
        }
      } else {
        // Question not found in database (might be deleted)
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Question not found. It may have been deleted.'),
              backgroundColor: Colors.orange,
            ),
          );
        }
      }
    } catch (e) {
      // Hide loading indicator if still showing
      if (mounted && Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
      
      print('Error fetching question: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error loading question. Please try again.'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  void _showSystemNotificationDialog(NotificationItem notification) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Row(
            children: [
              Text(
                notification.displayType,
                style: TextStyle(fontSize: 24),
              ),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  notification.title,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  notification.body,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                SizedBox(height: 16),
                Text(
                  getTimeAgo(notification.timestamp.toIso8601String()),
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.grey[500],
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text('Close'),
            ),
          ],
        );
      },
    );
  }
}
