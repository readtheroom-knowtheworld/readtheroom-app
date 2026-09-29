// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:provider/provider.dart';
import '../models/notification_item.dart';
import '../widgets/notification_permission_card.dart';
import '../services/notification_log_service.dart';
import '../services/question_service.dart';
import '../services/user_service.dart';
import 'authentication_screen.dart';

class ActivityScreen extends StatefulWidget {
  const ActivityScreen({Key? key}) : super(key: key);

  @override
  _ActivityScreenState createState() => _ActivityScreenState();
}

class _ActivityScreenState extends State<ActivityScreen> {
  final NotificationLogService _notificationService = NotificationLogService();
  bool _hasUnviewedNotifications = false;
  bool _isAuthenticated = false;

  @override
  void initState() {
    super.initState();
    _checkAuthentication();
    _checkUnviewedNotifications();
    _markAllAsViewed();
  }

  void _checkAuthentication() {
    setState(() {
      _isAuthenticated = Supabase.instance.client.auth.currentUser != null;
    });
  }

  Future<void> _checkUnviewedNotifications() async {
    if (_isAuthenticated) {
      final hasUnviewed = await _notificationService.hasUnviewedTodaysNotifications();
      if (mounted) {
        setState(() {
          _hasUnviewedNotifications = hasUnviewed;
        });
      }
    }
  }

  Future<void> _markAllAsViewed() async {
    if (_isAuthenticated) {
      await _notificationService.markAllTodaysNotificationsAsViewed();
      if (mounted) {
        setState(() {
          _hasUnviewedNotifications = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Activity'),
        centerTitle: false,
      ),
      body: _isAuthenticated ? _buildNotificationsList() : _buildAuthenticationRequired(),
    );
  }

  Widget _buildAuthenticationRequired() {
    return Center(
      child: Padding(
        padding: EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.notifications_off_outlined,
              size: 64,
              color: Colors.grey[400],
            ),
            SizedBox(height: 16),
            Text(
              'Authentication Required',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            SizedBox(height: 8),
            Text(
              'Please authenticate to view your activity feed',
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                color: Colors.grey[600],
              ),
              textAlign: TextAlign.center,
            ),
            SizedBox(height: 24),
            ElevatedButton(
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => AuthenticationScreen(),
                  ),
                ).then((_) {
                  // Refresh authentication status when returning
                  _checkAuthentication();
                  _checkUnviewedNotifications();
                });
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: Theme.of(context).primaryColor,
                foregroundColor: Colors.white,
                padding: EdgeInsets.symmetric(horizontal: 32, vertical: 12),
              ),
              child: Text('Authenticate'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNotificationsList() {
    return RefreshIndicator(
      onRefresh: () async {
        await _checkUnviewedNotifications();
      },
      child: FutureBuilder<List<NotificationItem>>(
        future: _notificationService.getAllNotifications(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return Center(child: CircularProgressIndicator());
          }

          final allNotifications = snapshot.data ?? [];
          
          // Split notifications into today and earlier
          final todayNotifications = allNotifications.where((n) => n.isToday && !n.isDismissed).toList();
          final earlierNotifications = allNotifications.where((n) => !n.isToday && !n.isDismissed).toList();
          
          // Only show the full empty state if there are NO notifications at all
          if (allNotifications.isEmpty) {
            return _buildEmptyState();
          }

          return ListView(
            physics: AlwaysScrollableScrollPhysics(),
            padding: EdgeInsets.all(16),
            children: [
              // Notification permission widget (if applicable)
              _buildNotificationPermissionWidget(),
              
              // Today's Activity Section (always shown)
              _buildSectionHeader("Today's Activity"),
              SizedBox(height: 8),
              if (todayNotifications.isNotEmpty) ...[
                ...todayNotifications.map((notification) => Padding(
                  padding: EdgeInsets.only(bottom: 8),
                  child: _buildNotificationTile(notification),
                )),
              ] else ...[
                // Empty state for today
                Padding(
                  padding: EdgeInsets.symmetric(vertical: 16),
                  child: Center(
                    child: Text(
                      'Nothing new, for now...',
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        color: Colors.grey[500],
                      ),
                    ),
                  ),
                ),
              ],
              SizedBox(height: 16),
              
              // Earlier this week Section
              if (earlierNotifications.isNotEmpty) ...[
                _buildSectionHeader("Earlier this week"),
                SizedBox(height: 8),
                ...earlierNotifications.map((notification) => Padding(
                  padding: EdgeInsets.only(bottom: 8),
                  child: _buildNotificationTile(notification),
                )),
              ],
            ],
          );
        },
      ),
    );
  }

  /// The Activity tab's notification promo.
  ///
  /// Was a near-duplicate of `NotificationPermissionCard` with its own
  /// permission check, its own dismissal handling and its own enable button —
  /// which meant the two copies disagreed about OS-denied (this one ran a dead
  /// `requestPermissions()` and then claimed the user had refused). It now
  /// delegates, keeping its own copy text and its own dismissal key.
  Widget _buildNotificationPermissionWidget() {
    if (!_isAuthenticated) return const SizedBox.shrink();
    return const NotificationPermissionCard(
      dismissedPrefsKey: 'notification_widget_dismissed',
      title: 'Stay in the loop!',
      message:
          'Enabling notifications allows you to get updates here when people '
          'vote or comment on your subscribed questions.',
      enabledSnackBarMessage:
          "Notifications enabled! You'll now receive activity updates.",
      deniedSnackBarMessage:
          'Enable notifications in your device settings to receive activity '
          'updates.',
    );
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: EdgeInsets.only(left: 4, bottom: 4),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.w600,
          color: Colors.grey[600],
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return SingleChildScrollView(
      physics: AlwaysScrollableScrollPhysics(),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            // Notification permission widget (if applicable)
            _buildNotificationPermissionWidget(),
            
            // Empty state content
            Container(
              height: MediaQuery.of(context).size.height * 0.6,
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.inbox_outlined,
                      size: 64,
                      color: Colors.grey[400],
                    ),
                    SizedBox(height: 16),
                    Text(
                      'No notifications',
                      style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                        color: Colors.grey[600],
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    SizedBox(height: 8),
                    Text(
                      'Your recent notifications will appear here',
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        color: Colors.grey[500],
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
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
        decoration: BoxDecoration(
          color: Colors.grey.withOpacity(0.8),
          borderRadius: BorderRadius.circular(12),
        ),
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
        // Mark as dismissed
        await _notificationService.markAsDismissed(notification.id);
        
        // Show snackbar with undo option (same style as home_screen.dart)
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
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
          );
        }
        
        // Return false and trigger setState to rebuild the list
        // This way the item is removed from the filtered list, not just the widget tree
        setState(() {});
        return false;
      },
      child: Card(
        elevation: 0,
        color: Theme.of(context).colorScheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(
            color: notification.isViewed 
                ? Colors.grey.withOpacity(0.2)
                : Theme.of(context).primaryColor.withOpacity(0.3),
            width: 1,
          ),
        ),
        child: ListTile(
          contentPadding: EdgeInsets.all(16),
          title: Text(
            notification.title,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              fontWeight: notification.isViewed ? FontWeight.normal : FontWeight.w600,
              color: notification.isViewed ? Colors.grey[600] : null,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Padding(
            padding: EdgeInsets.only(top: 4),
            child: Text(
              notification.body,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: notification.isViewed ? Colors.grey[500] : Colors.grey[700],
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
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
            child: Text(
              notification.body,
              style: Theme.of(context).textTheme.bodyMedium,
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
