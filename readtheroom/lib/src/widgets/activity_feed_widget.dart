// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import '../models/room.dart';
import '../services/activity_service.dart';
import '../services/room_sharing_service.dart';

class ActivityFeedWidget extends StatefulWidget {
  final bool showHeader;
  final int? maxItems;
  
  const ActivityFeedWidget({
    Key? key,
    this.showHeader = true,
    this.maxItems,
  }) : super(key: key);

  @override
  State<ActivityFeedWidget> createState() => _ActivityFeedWidgetState();
}

class _ActivityFeedWidgetState extends State<ActivityFeedWidget> {
  final ActivityService _activityService = ActivityService();
  final RoomSharingService _roomSharingService = RoomSharingService();
  List<UserActivityItem> _activities = [];
  bool _isLoading = false;
  int _unreadCount = 0;

  @override
  void initState() {
    super.initState();
    _loadActivities();
    _loadUnreadCount();
  }

  Future<void> _loadActivities() async {
    setState(() {
      _isLoading = true;
    });

    try {
      final activities = await _activityService.getUserActivity(
        limit: widget.maxItems ?? 20,
      );
      setState(() {
        _activities = activities;
      });
    } catch (e) {
      debugPrint('Error loading activities: $e');
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  Future<void> _loadUnreadCount() async {
    try {
      final count = await _activityService.getUnreadCount();
      setState(() {
        _unreadCount = count;
      });
    } catch (e) {
      debugPrint('Error loading unread count: $e');
    }
  }

  Future<void> _markAsRead(UserActivityItem activity) async {
    if (!activity.isRead) {
      try {
        await _activityService.markAsRead(activity.id);
        setState(() {
          final index = _activities.indexWhere((a) => a.id == activity.id);
          if (index != -1) {
            _activities[index] = UserActivityItem(
              id: activity.id,
              userId: activity.userId,
              activityType: activity.activityType,
              title: activity.title,
              subtitle: activity.subtitle,
              isActionable: activity.isActionable,
              roomId: activity.roomId,
              questionId: activity.questionId,
              metadata: activity.metadata,
              createdAt: activity.createdAt,
              expiresAt: activity.expiresAt,
              isRead: true,
              isDismissed: activity.isDismissed,
            );
          }
          if (_unreadCount > 0) _unreadCount--;
        });
      } catch (e) {
        debugPrint('Error marking activity as read: $e');
      }
    }
  }

  Future<void> _dismissActivity(UserActivityItem activity) async {
    try {
      await _activityService.dismissActivity(activity.id);
      setState(() {
        _activities.removeWhere((a) => a.id == activity.id);
        if (!activity.isRead && _unreadCount > 0) _unreadCount--;
      });
    } catch (e) {
      debugPrint('Error dismissing activity: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to dismiss activity: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _markAllAsRead() async {
    try {
      await _activityService.markAllAsRead();
      setState(() {
        _activities = _activities.map((activity) => UserActivityItem(
          id: activity.id,
          userId: activity.userId,
          activityType: activity.activityType,
          title: activity.title,
          subtitle: activity.subtitle,
          isActionable: activity.isActionable,
          roomId: activity.roomId,
          questionId: activity.questionId,
          metadata: activity.metadata,
          createdAt: activity.createdAt,
          expiresAt: activity.expiresAt,
          isRead: true,
          isDismissed: activity.isDismissed,
        )).toList();
        _unreadCount = 0;
      });
    } catch (e) {
      debugPrint('Error marking all as read: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.showHeader) _buildHeader(),
        if (_isLoading)
          const Padding(
            padding: EdgeInsets.all(16.0),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_activities.isEmpty)
          _buildEmptyState()
        else
          _buildActivityList(),
      ],
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              const Icon(Icons.notifications, size: 24),
              const SizedBox(width: 8),
              Text(
                'Activity',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              if (_unreadCount > 0) ...[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.red,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '$_unreadCount',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ],
          ),
          if (_unreadCount > 0)
            TextButton(
              onPressed: _markAllAsRead,
              child: const Text('Mark all read'),
            ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return Padding(
      padding: const EdgeInsets.all(32.0),
      child: Center(
        child: Column(
          children: [
            Icon(
              Icons.notifications_none,
              size: 64,
              color: Colors.grey[400],
            ),
            const SizedBox(height: 16),
            Text(
              'No activity yet',
              style: TextStyle(
                fontSize: 18,
                color: Colors.grey[600],
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Join rooms and share responses to see activity here',
              style: TextStyle(
                fontSize: 14,
                color: Colors.grey[500],
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildActivityList() {
    return ListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: _activities.length,
      itemBuilder: (context, index) {
        final activity = _activities[index];
        return _buildActivityTile(activity);
      },
    );
  }

  Widget _buildActivityTile(UserActivityItem activity) {
    return Dismissible(
      key: Key(activity.id),
      direction: DismissDirection.endToStart,
      background: Container(
        color: Colors.red,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        child: const Icon(
          Icons.delete,
          color: Colors.white,
        ),
      ),
      onDismissed: (direction) => _dismissActivity(activity),
      child: Container(
        decoration: BoxDecoration(
          color: activity.isRead ? null : Colors.blue[50],
          border: Border(
            bottom: BorderSide(
              color: Colors.grey[200]!,
              width: 0.5,
            ),
          ),
        ),
        child: ListTile(
          leading: _buildActivityIcon(activity),
          title: Text(
            activity.title,
            style: TextStyle(
              fontWeight: activity.isRead ? FontWeight.normal : FontWeight.bold,
            ),
          ),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (activity.subtitle != null)
                Text(activity.subtitle!),
              Text(
                _formatRelativeTime(activity.createdAt),
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.grey[600],
                ),
              ),
            ],
          ),
          trailing: activity.isActionable
              ? const Icon(Icons.arrow_forward_ios, size: 16)
              : null,
          onTap: () => _handleActivityTap(activity),
        ),
      ),
    );
  }

  Widget _buildActivityIcon(UserActivityItem activity) {
    IconData iconData;
    Color? iconColor;

    switch (activity.activityType) {
      case 'room_needs_input':
      case 'room_majority_answered':
      case 'manual_share_prompt':
        iconData = Icons.groups;
        iconColor = Colors.orange;
        break;
      case 'question_forwarded_to_room':
        iconData = Icons.forward;
        iconColor = Colors.green;
        break;
      case 'room_milestone':
      case 'room_unlocked':
        iconData = Icons.celebration;
        iconColor = Colors.purple;
        break;
      case 'room_joined':
        iconData = Icons.group_add;
        iconColor = Theme.of(context).primaryColor;
        break;
      case 'room_response_shared':
      case 'room_completed':
        iconData = Icons.check_circle;
        iconColor = Colors.green;
        break;
      case 'room_achievement':
        iconData = Icons.emoji_events;
        iconColor = Colors.amber;
        break;
      case 'room_ranking':
        iconData = Icons.leaderboard;
        iconColor = Colors.blue;
        break;
      case 'room_quality_leader':
        iconData = Icons.star;
        iconColor = Colors.amber[700];
        break;
      case 'room_quality_improvement':
        iconData = Icons.trending_up;
        iconColor = Colors.green[700];
        break;
      case 'room_rqi_milestone':
        iconData = Icons.emoji_events;
        iconColor = Colors.purple[600];
        break;
      case 'comment':
      case 'new_comment':
        iconData = Icons.comment;
        iconColor = Colors.blue[600];
        break;
      case 'vote_activity':
        iconData = Icons.trending_up;
        iconColor = Colors.green[600];
        break;
      case 'qotd':
      case 'question_of_the_day':
        iconData = Icons.calendar_today;
        iconColor = Colors.purple[600];
        break;
      case 'private_link_opened':
        iconData = Icons.link;
        iconColor = Colors.blue[600];
        break;
      default:
        iconData = Icons.notifications;
        iconColor = Colors.grey[600];
    }

    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: iconColor?.withOpacity(0.1),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Icon(
        iconData,
        color: iconColor,
        size: 20,
      ),
    );
  }

  void _handleActivityTap(UserActivityItem activity) {
    _markAsRead(activity);

    // Handle navigation for all activity types
    switch (activity.activityType) {
      case 'room_needs_input':
      case 'room_majority_answered':
      case 'manual_share_prompt':
        if (activity.isActionable) {
          _handleManualSharePrompt(activity);
        }
        break;
      case 'question_forwarded_to_room':
        if (activity.isActionable) {
          _handleQuestionForwarded(activity);
        }
        break;
      case 'comment':
      case 'new_comment':
      case 'vote_activity':
      case 'qotd':
      case 'question_of_the_day':
      case 'private_link_opened':
        // Navigate directly to question for comment/vote/qotd/private link activities
        if (activity.questionId != null) {
          _navigateToQuestion(activity.questionId!);
        }
        break;
      case 'room_quality_leader':
      case 'room_quality_improvement':
      case 'room_rqi_milestone':
        // Navigate to room for quality activities
        if (activity.roomId != null) {
          _navigateToRoom(activity.roomId!);
        }
        break;
      default:
        // Navigate to related content if available
        if (activity.questionId != null) {
          _navigateToQuestion(activity.questionId!);
        } else if (activity.roomId != null) {
          _navigateToRoom(activity.roomId!);
        }
    }
  }

  void _handleManualSharePrompt(UserActivityItem activity) {
    final questionText = activity.subtitle ?? 'Unknown question';
    
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            Text('🎪', style: TextStyle(fontSize: 20)),
            SizedBox(width: 8),
            Expanded(child: Text('Share Response')),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Question:',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            SizedBox(height: 4),
            Text(
              questionText,
              style: TextStyle(fontStyle: FontStyle.italic),
            ),
            SizedBox(height: 16),
            Text('Would you like to share your response to this room?'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _dismissActivity(activity);
            },
            child: const Text('Not now'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              _shareResponse(activity);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.orange,
              foregroundColor: Colors.white,
            ),
            child: const Text('Share to Room'),
          ),
        ],
      ),
    );
  }

  void _handleQuestionForwarded(UserActivityItem activity) {
    final questionText = activity.subtitle ?? 'Unknown question';
    
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            Text('🎪', style: TextStyle(fontSize: 20)),
            SizedBox(width: 8),
            Expanded(child: Text('New Question')),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(questionText),
            SizedBox(height: 16),
            Text('Someone shared this question to your room. Would you like to answer it?'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _dismissActivity(activity);
            },
            child: const Text('Maybe later'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              if (activity.questionId != null) {
                _navigateToQuestion(activity.questionId!);
              }
              _dismissActivity(activity);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.green,
              foregroundColor: Colors.white,
            ),
            child: const Text('Answer Question'),
          ),
        ],
      ),
    );
  }

  Future<void> _shareResponse(UserActivityItem activity) async {
    if (activity.roomId == null || activity.questionId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Missing room or question information'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    try {
      // Show loading indicator
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          content: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(),
              SizedBox(width: 16),
              Text('Sharing response...'),
            ],
          ),
        ),
      );

      // Share the locally stored response to the room
      await _roomSharingService.shareLocalResponseToRoom(
        roomId: activity.roomId!,
        questionId: activity.questionId!,
      );

      // Close loading dialog
      Navigator.pop(context);

      // Show success message
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              Icon(Icons.check_circle, color: Colors.white),
              SizedBox(width: 8),
              Text('Response shared successfully!'),
            ],
          ),
          backgroundColor: Colors.green,
          duration: Duration(seconds: 2),
        ),
      );

      // Remove the activity item since it's been completed
      _dismissActivity(activity);
    } catch (e) {
      // Close loading dialog
      Navigator.pop(context);

      // Show error message
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              Icon(Icons.error, color: Colors.white),
              SizedBox(width: 8),
              Expanded(child: Text('Failed to share: ${e.toString()}')),
            ],
          ),
          backgroundColor: Colors.red,
          duration: Duration(seconds: 4),
        ),
      );
    }
  }

  void _navigateToQuestion(String questionId) {
    // TODO: Navigate to question details
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Navigate to question $questionId - Coming soon!'),
      ),
    );
  }

  void _navigateToRoom(String roomId) {
    // TODO: Navigate to room details
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Navigate to room $roomId - Coming soon!'),
      ),
    );
  }

  String _formatRelativeTime(DateTime dateTime) {
    final now = DateTime.now();
    final difference = now.difference(dateTime);

    if (difference.inDays > 7) {
      return '${dateTime.day}/${dateTime.month}/${dateTime.year}';
    } else if (difference.inDays > 0) {
      return '${difference.inDays}d ago';
    } else if (difference.inHours > 0) {
      return '${difference.inHours}h ago';
    } else if (difference.inMinutes > 0) {
      return '${difference.inMinutes}m ago';
    } else {
      return 'Just now';
    }
  }
}