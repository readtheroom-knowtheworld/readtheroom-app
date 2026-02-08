// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import '../services/notification_service.dart';

class QuestionActivityPermissionDialog extends StatelessWidget {
  final Future<void> Function()? onPermissionGranted;
  final Future<void> Function()? onPermissionDenied;

  const QuestionActivityPermissionDialog({
    Key? key,
    this.onPermissionGranted,
    this.onPermissionDenied,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(
        children: [
          Icon(
            Icons.notifications_active,
            color: Theme.of(context).primaryColor,
            size: 28,
          ),
          SizedBox(width: 12),
          Text('Ping...? 👀'),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          RichText(
            text: TextSpan(
              style: Theme.of(context).textTheme.bodyMedium,
              children: [
                TextSpan(text: 'Stay in the loop with questions you care about.\n\nGet notified when questions you\'re subscribed to receive '),
                TextSpan(
                  text: 'comments and significant activity',
                  style: TextStyle(
                    decoration: TextDecoration.underline,
                    color: Theme.of(context).textTheme.bodyMedium?.color,
                  ),
                ),
                TextSpan(text: '.'),
              ],
            ),
          ),
          SizedBox(height: 16),
          Container(
            padding: EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Theme.of(context).primaryColor.withOpacity(0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.notifications,
                      size: 16,
                      color: Theme.of(context).primaryColor,
                    ),
                    SizedBox(width: 8),
                    Text(
                      'Subscribe to Questions',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: Theme.of(context).primaryColor,
                      ),
                    ),
                  ],
                ),
                SizedBox(height: 4),
                Text(
                  'Tap the bell icon on any question page to subscribe to the question. \n\nYou\'re automatically subscribed to questions you post. All other questions are opt-in.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                SizedBox(height: 12),
                Row(
                  children: [
                    Icon(
                      Icons.volume_off,
                      size: 16,
                      color: Theme.of(context).primaryColor,
                    ),
                    SizedBox(width: 8),
                    Text(
                      'Smart & Silent',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: Theme.of(context).primaryColor,
                      ),
                    ),
                  ],
                ),
                SizedBox(height: 4),
                Text(
                  'Only get notified when there are comments or significant activity on your subscribed questions. \n\nNo sounds. No vibrations.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                SizedBox(height: 12),
              ],
            ),
          ),
        ],
      ),
      actions: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            TextButton(
              onPressed: () async {
                Navigator.of(context).pop();
                await onPermissionDenied?.call();
              },
              child: Text('Not Now'),
            ),
            ElevatedButton(
              onPressed: () async {
                Navigator.of(context).pop();
                
                // Check if permissions are already granted
                final notificationService = NotificationService();
                final alreadyGranted = await notificationService.arePermissionsGranted();
                
                if (alreadyGranted) {
                  // Permissions already granted - just enable the feature
                  await onPermissionGranted?.call();
                } else {
                  // Request permissions
                  final granted = await notificationService.requestPermissions();
                  
                  // Let the parent handle state management and UI feedback
                  if (granted) {
                    await onPermissionGranted?.call();
                  } else {
                    await onPermissionDenied?.call();
                  }
                }
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: Theme.of(context).primaryColor,
                foregroundColor: Colors.white,
              ),
              child: Text('Count me in!'),
            ),
          ],
        ),
      ],
    );
  }

  // Static method to show the dialog
  static Future<void> show(BuildContext context, {
    Future<void> Function()? onPermissionGranted,
    Future<void> Function()? onPermissionDenied,
  }) {
    return showDialog<void>(
      context: context,
      barrierDismissible: false, // User must make a choice
      builder: (context) => QuestionActivityPermissionDialog(
        onPermissionGranted: onPermissionGranted,
        onPermissionDenied: onPermissionDenied,
      ),
    );
  }
} 