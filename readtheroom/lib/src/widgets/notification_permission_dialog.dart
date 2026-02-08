// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/notification_service.dart';

class NotificationPermissionDialog extends StatelessWidget {
  final Future<void> Function()? onPermissionGranted;
  final Future<void> Function()? onPermissionDenied;

  const NotificationPermissionDialog({
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
            Icons.today,
            color: Theme.of(context).primaryColor,
            size: 28,
          ),
          SizedBox(width: 12),
          Text('Earth\'s Vibe Check!'),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'We are mapping the mood of our planet. Help us?',
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
              fontSize: 16,
              height: 1.4,
            ),
            textAlign: TextAlign.center,
          ),
          SizedBox(height: 16),
          Container(
            padding: EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Theme.of(context).primaryColor.withOpacity(0.1),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Text(
                  '📅 Daily Question',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Theme.of(context).primaryColor,
                  ),
                ),
                SizedBox(height: 8),
                Text(
                  'Just the one question the world needs answered today.',
                  style: TextStyle(
                    fontSize: 14,
                    height: 1.3,
                  ),
                  textAlign: TextAlign.center,
                ),
                SizedBox(height: 16),
                Text(
                  '🚫 No Spam',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Theme.of(context).primaryColor,
                  ),
                ),
                SizedBox(height: 8),
                Text(
                  'Max 1 nudge per day.',
                  style: TextStyle(
                    fontSize: 14,
                  ),
                  textAlign: TextAlign.center,
                ),
                SizedBox(height: 16),
                Text(
                  '⚙️ Your Choice',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Theme.of(context).primaryColor,
                  ),
                ),
                SizedBox(height: 8),
                Text(
                  'Customize nudges in Settings.',
                  style: TextStyle(
                    fontSize: 14,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
          SizedBox(height: 16),
          // Widget suggestion link
          GestureDetector(
            onTap: () async {
              final uri = Uri.parse('https://readtheroom.site/widgets/');
              if (await canLaunchUrl(uri)) {
                await launchUrl(uri, mode: LaunchMode.externalApplication);
              }
            },
            child: Container(
              padding: EdgeInsets.all(12),
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
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Did you know we have widgets? It\'s a quiet way to support the platform.',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
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
              child: Text('Maybe later'),
            ),
            ElevatedButton(
              onPressed: () async {
                Navigator.of(context).pop();
                
                // Request permissions
                final notificationService = NotificationService();
                final granted = await notificationService.requestPermissions();
                
                // Let the parent handle state management and UI feedback
                if (granted) {
                  await onPermissionGranted?.call();
                } else {
                  await onPermissionDenied?.call();
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
      builder: (context) => NotificationPermissionDialog(
        onPermissionGranted: onPermissionGranted,
        onPermissionDenied: onPermissionDenied,
      ),
    );
  }
} 
