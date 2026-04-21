// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io' show Platform;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

/// Bump this constant to trigger a new "What's New?" dialog for a release.
const String whatsNewVersion = '1.1.5-boosts';

class WhatsNewDialog extends StatefulWidget {
  const WhatsNewDialog({Key? key}) : super(key: key);

  /// Show the dialog unconditionally (e.g. from settings screen).
  static Future<void> show(BuildContext context) {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => const WhatsNewDialog(),
    );
  }

  static bool _wasShownThisSession = false;

  static bool get wasShownThisSession => _wasShownThisSession;

  /// Check SharedPreferences and show the dialog if this version hasn't been seen.
  /// Returns true if the dialog was shown.
  static Future<bool> checkAndShow(BuildContext context) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final seenVersion = prefs.getString('whats_new_seen_version');

      if (seenVersion == whatsNewVersion) return false;

      // First time opening the app after onboarding — silently mark as seen
      if (seenVersion == null) {
        await prefs.setString('whats_new_seen_version', whatsNewVersion);
        return false;
      }

      if (!context.mounted) return false;

      _wasShownThisSession = true;
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (context) => const WhatsNewDialog(),
      );
      return true;
    } catch (e) {
      print('WhatsNewDialog: Error checking version: $e');
      return false;
    }
  }

  @override
  State<WhatsNewDialog> createState() => _WhatsNewDialogState();
}

class _WhatsNewDialogState extends State<WhatsNewDialog> {

  Future<void> _dismiss(BuildContext context) async {
    if (context.mounted) {
      Navigator.of(context).pop();
    }
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
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.rocket_launch, color: Theme.of(context).primaryColor, size: 20),
                SizedBox(width: 8),
                Text(
                  'Boost Questions',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: Theme.of(context).primaryColor,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.3,
                  ),
                ),
              ],
            ),
            SizedBox(height: 6),
            Text(
              'Found an old gem? Long-press questions in the search screen to nominate them as a future Question of the Day!',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                height: 1.4,
              ),
            ),
            SizedBox(height: 16),
            Row(
              children: [
                Icon(Icons.calendar_today, color: Theme.of(context).primaryColor, size: 20),
                SizedBox(width: 8),
                Text(
                  'QOTD Overlay',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: Theme.of(context).primaryColor,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.3,
                  ),
                ),
              ],
            ),
            SizedBox(height: 6),
            Text(
              'The Question of the Day now greets you when you open the app. Answer it right away or pull down to dismiss.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                height: 1.4,
              ),
            ),
            SizedBox(height: 16),
            Row(
              children: [
                Icon(Icons.comment, color: Theme.of(context).primaryColor, size: 20),
                SizedBox(width: 8),
                Text(
                  'Comments are back!',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: Theme.of(context).primaryColor,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.3,
                  ),
                ),
              ],
            ),
            SizedBox(height: 6),
            Text(
              'As per popular demand, comments are now visible by default again! Question ratings are only required to post a comment.',
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
                  TextSpan(text: 'Psst! Please leave an '),
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
      ),
      actions: [
        ElevatedButton(
          onPressed: () => _dismiss(context),
          style: ElevatedButton.styleFrom(
            backgroundColor: Theme.of(context).primaryColor,
            foregroundColor: Colors.white,
          ),
          child: Text('Got it'),
        ),
      ],
    );
  }
}
