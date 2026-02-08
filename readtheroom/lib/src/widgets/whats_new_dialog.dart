// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io' show Platform;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

/// Bump this constant to trigger a new "What's New?" dialog for a release.
const String whatsNewVersion = '1.1.1-widgets';

class WhatsNewDialog extends StatelessWidget {
  const WhatsNewDialog({Key? key}) : super(key: key);

  /// Show the dialog unconditionally (e.g. from settings screen).
  static Future<void> show(BuildContext context) {
    return showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (context) => const WhatsNewDialog(),
    );
  }

  /// Check SharedPreferences and show the dialog if this version hasn't been seen.
  static Future<void> checkAndShow(BuildContext context) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final seenVersion = prefs.getString('whats_new_seen_version');

      if (seenVersion == whatsNewVersion) return;

      if (!context.mounted) return;

      showDialog<void>(
        context: context,
        barrierDismissible: true,
        builder: (context) => const WhatsNewDialog(),
      );
    } catch (e) {
      print('WhatsNewDialog: Error checking version: $e');
    }
  }

  Future<void> _dismiss(BuildContext context) async {
    Navigator.of(context).pop();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('whats_new_seen_version', whatsNewVersion);
    } catch (e) {
      print('WhatsNewDialog: Error saving seen version: $e');
    }
  }

  Future<void> _launchAppStore() async {
    final url = Platform.isIOS
        ? 'https://apps.apple.com/us/app/read-the-room-know-the-world/id6747105473'
        : 'https://play.google.com/store/apps/details?id=com.readtheroom.app';
    try {
      final uri = Uri.parse(url);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    } catch (e) {
      print('WhatsNewDialog: Error launching app store: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(
        children: [
          Icon(
            Icons.auto_awesome,
            color: Theme.of(context).primaryColor,
            size: 28,
          ),
          SizedBox(width: 12),
          Text("What's New?"),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'QOTD Widget',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: Theme.of(context).primaryColor,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.3,
            ),
          ),
          SizedBox(height: 6),
          Text(
            'See today\'s question on your home screen with Curio! Also — streak widgets for home and lock screen.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              height: 1.4,
            ),
          ),
          SizedBox(height: 16),
          Text(
            'Swipe Navigation',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: Theme.of(context).primaryColor,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.3,
            ),
          ),
          SizedBox(height: 6),
          Text(
            'Swipe from the left edge to go home from any question.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              height: 1.4,
            ),
          ),
          SizedBox(height: 16),
          RichText(
            textAlign: TextAlign.center,
            text: TextSpan(
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                height: 1.5,
                color: Colors.grey[600],
              ),
              children: [
                TextSpan(text: 'Enjoying RTR? Leave an '),
                TextSpan(
                  text: 'app store review',
                  style: TextStyle(
                    color: Theme.of(context).primaryColor,
                    fontWeight: FontWeight.w600,
                  ),
                  recognizer: TapGestureRecognizer()..onTap = _launchAppStore,
                ),
                TextSpan(text: ' <3'),
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
              onPressed: () => _dismiss(context),
              child: Text('Got it'),
            ),
            ElevatedButton.icon(
              onPressed: () async {
                final uri = Uri.parse('https://readtheroom.site/widgets/');
                try {
                  if (await canLaunchUrl(uri)) {
                    await launchUrl(uri, mode: LaunchMode.externalApplication);
                  }
                } catch (e) {
                  print('WhatsNewDialog: Error launching URL: $e');
                }
                if (context.mounted) {
                  _dismiss(context);
                }
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: Theme.of(context).primaryColor,
                foregroundColor: Colors.white,
              ),
              icon: Icon(Icons.open_in_new, size: 16),
              label: Text('Learn More'),
            ),
          ],
        ),
      ],
    );
  }
}
