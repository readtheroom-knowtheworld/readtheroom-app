// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io' show Platform;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

/// Bump this constant to trigger a new "What's New?" dialog for a release.
const String whatsNewVersion = '2.0.0';

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

  /// One concise What's New line: icon + bold title, one-sentence body.
  Widget _item(BuildContext context, IconData icon, String title, String body) {
    final primary = Theme.of(context).primaryColor;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: primary, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: RichText(
              text: TextSpan(
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(height: 1.35),
                children: [
                  TextSpan(
                    text: '$title — ',
                    style: TextStyle(fontWeight: FontWeight.w600, color: primary),
                  ),
                  TextSpan(text: body),
                ],
              ),
            ),
          ),
        ],
      ),
    );
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
            _item(context, Icons.today, 'One question a day',
                'It drops at a random moment, turn on notifications to be there when it happens and vote on the Question of Tomorrow!'),
            _item(context, Icons.group, 'Friends',
                'Add friends by QR or handle. Close friends can share answers with each other.'),
            _item(context, Icons.hub_rounded, 'Your network',
                'See how your friends-of-friends think, are you in an echo chamber?'),
            SizedBox(height: 4),
            RichText(
              text: TextSpan(
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Colors.grey[600],
                ),
                children: [
                  TextSpan(
                    text: 'App store reviews',
                    style: TextStyle(
                      color: Theme.of(context).primaryColor,
                      fontWeight: FontWeight.w600,
                    ),
                    recognizer: TapGestureRecognizer()..onTap = _launchAppStore,
                  ),
                  TextSpan(text: ' really help us out ;)'),
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
