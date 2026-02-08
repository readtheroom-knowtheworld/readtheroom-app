// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import '../services/notification_service.dart';
import '../services/user_service.dart';
import 'package:provider/provider.dart';

class FirstQuestionNotificationDialog extends StatelessWidget {
  final VoidCallback? onPermissionGranted;
  final VoidCallback? onPermissionDenied;
  final VoidCallback? onCompleted;

  const FirstQuestionNotificationDialog({
    Key? key,
    this.onPermissionGranted,
    this.onPermissionDenied,
    this.onCompleted,
  }) : super(key: key);

  static Future<void> show(
    BuildContext context, {
    VoidCallback? onPermissionGranted,
    VoidCallback? onPermissionDenied,
    VoidCallback? onCompleted,
  }) async {
    return showDialog<void>(
      context: context,
      barrierDismissible: false, // User must make a choice
      builder: (BuildContext context) {
        return FirstQuestionNotificationDialog(
          onPermissionGranted: onPermissionGranted,
          onPermissionDenied: onPermissionDenied,
          onCompleted: onCompleted,
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(
        children: [
          Icon(
            Icons.celebration,
            color: Theme.of(context).primaryColor,
            size: 28,
          ),
          SizedBox(width: 12),
          Expanded(child: Text('Great Question!')),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Here\'s what happens next:',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            SizedBox(height: 16),
            
            // Auto-subscription explanation
            Container(
              padding: EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context).primaryColor.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: Theme.of(context).primaryColor.withOpacity(0.3),
                  width: 1,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.notifications_active,
                        size: 16,
                        color: Theme.of(context).primaryColor,
                      ),
                      SizedBox(width: 8),
                      Text(
                        'Personal Subscription',
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: Theme.of(context).primaryColor,
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: 4),
                  Text(
                    'You\'re automatically subscribed to questions you post.\n\nToggle notifications for individual questions at any time by clicking the bell icon at the top of any results page.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            
            SizedBox(height: 12),
            
            // Notification explanation
            Container(
              padding: EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.orange.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: Colors.orange.withOpacity(0.3),
                  width: 1,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.volume_off,
                        size: 16,
                        color: Colors.orange.shade700,
                      ),
                      SizedBox(width: 8),
                      Text(
                        'Smart Notifications',
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: Colors.orange.shade700,
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: 4),
                  Text(
                    'You\'ll only be notified when your question gets significant activity.\n\nWe never trigger a ping, sound, or vibration.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            
            SizedBox(height: 12),
            
            // Control explanation
            Container(
              padding: EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.grey.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: Colors.grey.withOpacity(0.3),
                  width: 1,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.settings,
                        size: 16,
                        color: Colors.grey.shade700,
                      ),
                      SizedBox(width: 8),
                      Text(
                        'Full Control',
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: Colors.grey.shade700,
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: 4),
                  Text(
                    'Customize rules in the Settings screen.\n\nYour app, your rules.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            
            SizedBox(height: 16),
          ],
        ),
      ),
      actionsAlignment: MainAxisAlignment.center,
      actions: [
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
          onPressed: () async {
            Navigator.of(context).pop();
            
            try {
              // Request notification permissions
              final notificationService = NotificationService();
              final permissionGranted = await notificationService.requestPermissions();
              
              if (permissionGranted) {
                // Enable notifications in user service
                final userService = Provider.of<UserService>(context, listen: false);
                await userService.onNotificationPermissionsGranted();
                
                // Show success message
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Row(
                        children: [
                          Icon(Icons.notifications_active, color: Colors.white, size: 20),
                          SizedBox(width: 8),
                          Expanded(child: Text('Notifications enabled! You\'ll be notified when your question gets activity.')),
                        ],
                      ),
                      backgroundColor: Theme.of(context).primaryColor,
                      duration: Duration(seconds: 4),
                    ),
                  );
                }
                
                if (onPermissionGranted != null) {
                  onPermissionGranted!();
                }
              } else {
                // Permissions denied
                final userService = Provider.of<UserService>(context, listen: false);
                await userService.onNotificationPermissionsDenied();
                
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Row(
                        children: [
                          Icon(Icons.notifications_off, color: Colors.white, size: 20),
                          SizedBox(width: 8),
                          Expanded(child: Text('Notifications disabled. You can enable them later in device Settings.')),
                        ],
                      ),
                      backgroundColor: Colors.orange,
                      duration: Duration(seconds: 4),
                    ),
                  );
                }
                
                if (onPermissionDenied != null) {
                  onPermissionDenied!();
                }
              }
            } catch (e) {
              print('Error requesting notifications: $e');
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Error setting up notifications. You can try again in Settings.'),
                    backgroundColor: Colors.red,
                  ),
                );
              }
              
              if (onPermissionDenied != null) {
                onPermissionDenied!();
              }
            }
            
            if (onCompleted != null) {
              onCompleted!();
            }
          },
          style: ElevatedButton.styleFrom(
            backgroundColor: Theme.of(context).primaryColor,
            foregroundColor: Colors.white,
          ),
          child: Text('Sounds good!'),
                ),
              ),
            SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: TextButton(
                onPressed: () async {
                  Navigator.of(context).pop();
                  
                  // Don't enable notifications
                  final userService = Provider.of<UserService>(context, listen: false);
                  userService.setNotifyResponses(false);
                  
                  if (onPermissionDenied != null) {
                    onPermissionDenied!();
                  }
                  
                  if (onCompleted != null) {
                    onCompleted!();
                  }
                },
                child: Text(
                  'I don\'t care about my question. \n(I am posting spam)',
                  style: TextStyle(color: Colors.grey[600]),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
} 