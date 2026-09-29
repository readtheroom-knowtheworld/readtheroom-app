// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/post_answer_prompts.dart';
import '../utils/notification_reask_logic.dart';
import '../utils/post_answer_prompt_logic.dart';

/// Dismissible "turn on notifications" promo, shared by the Activity and
/// Community tabs.
///
/// Extracted from `activity_screen.dart` so the Community tab can carry its own
/// copy of the prompt when notifications are off (networks-update-design §5.3,
/// last paragraph — friend events want push). Each surface passes its own copy
/// and its own [dismissedPrefsKey], so dismissing it on one tab does not hide it
/// on the other.
///
/// ## State it respects
///
/// Renders nothing unless the user is authenticated and notifications cannot be
/// delivered. Beyond that it now agrees with the post-answer prompt instead of
/// contradicting it:
///
///  * **OS-denied** → the button opens the system Settings page rather than
///    calling `requestPermissions()`, which iOS ignores once denied. Previously
///    the button ran a request that could not succeed and then showed the
///    "denied" SnackBar, which read as the card being broken.
///  * **Dismissed** → the dismissal *sticks* for [kNotificationReAskInterval],
///    the same cooling-off week the post-answer re-ask uses. It used to be
///    cleared on every build while notifications were still off, which made the
///    close button do nothing beyond the current frame.
///  * **A post-answer prompt is pending or on screen** → the card stays hidden
///    for that frame, so the user is never asked the same thing twice at once.
class NotificationPermissionCard extends StatefulWidget {
  const NotificationPermissionCard({
    Key? key,
    required this.dismissedPrefsKey,
    required this.title,
    required this.message,
    required this.enabledSnackBarMessage,
    required this.deniedSnackBarMessage,
  }) : super(key: key);

  final String dismissedPrefsKey;
  final String title;
  final String message;
  final String enabledSnackBarMessage;
  final String deniedSnackBarMessage;

  @override
  State<NotificationPermissionCard> createState() =>
      _NotificationPermissionCardState();
}

class _NotificationPermissionCardState
    extends State<NotificationPermissionCard> {
  /// Suffix of the SharedPreferences key holding *when* the card was dismissed.
  /// Kept alongside the legacy bool so an existing dismissal is not lost.
  static const String _dismissedAtSuffix = '_at';

  bool _authenticated = false;
  // Assume deliverable until proven otherwise: never flash the card.
  OsNotificationPermission _osStatus = OsNotificationPermission.authorized;
  bool _dismissed = true;
  bool _checked = false;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    bool authenticated = false;
    try {
      authenticated = Supabase.instance.client.auth.currentUser != null;
    } catch (_) {
      authenticated = false;
    }

    // `unknown` means "cannot tell" (Firebase not initialised, a widget test) —
    // treated as deliverable so the card stays hidden rather than nagging.
    var status = OsNotificationPermission.authorized;
    if (authenticated) {
      final read = await PostAnswerPrompts.osPermission();
      status = read == OsNotificationPermission.unknown
          ? OsNotificationPermission.authorized
          : read;
    }

    var dismissed = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      dismissed = prefs.getBool(widget.dismissedPrefsKey) ?? false;
      if (dismissed) {
        // A dismissal older than the cooling-off week is spent: clear it so the
        // nudge can come back, on the same cadence as the post-answer re-ask.
        final raw =
            prefs.getString('${widget.dismissedPrefsKey}$_dismissedAtSuffix');
        final at = raw == null ? null : DateTime.tryParse(raw);
        final expired = at == null
            // A legacy dismissal has no stamp; stamp it now so its week starts
            // here rather than reviving instantly or lasting forever.
            ? false
            : DateTime.now().difference(at) >= kNotificationReAskInterval;
        if (at == null) {
          await prefs.setString(
              '${widget.dismissedPrefsKey}$_dismissedAtSuffix',
              DateTime.now().toIso8601String());
        }
        if (expired) {
          await prefs.setBool(widget.dismissedPrefsKey, false);
          dismissed = false;
        }
      }
    } catch (_) {
      dismissed = false;
    }

    if (!mounted) return;
    setState(() {
      _authenticated = authenticated;
      _osStatus = status;
      _dismissed = dismissed;
      _checked = true;
    });
  }

  Future<void> _dismiss() async {
    setState(() => _dismissed = true);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(widget.dismissedPrefsKey, true);
      await prefs.setString('${widget.dismissedPrefsKey}$_dismissedAtSuffix',
          DateTime.now().toIso8601String());
    } catch (_) {
      // Non-fatal; the card simply reappears next time.
    }
  }

  /// OS-denied: only the Settings app can undo this, so go there.
  Future<void> _openSystemSettings() async {
    final uri = Uri.parse('app-settings:');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    }
  }

  Future<void> _enable() async {
    if (_osStatus == OsNotificationPermission.denied) {
      await _openSystemSettings();
      return;
    }

    var success = false;
    try {
      success = await PostAnswerPrompts.requestPermissions();
    } catch (_) {
      success = false;
    }
    if (!mounted) return;

    if (success) {
      setState(() {
        _osStatus = OsNotificationPermission.authorized;
        _dismissed = true;
      });
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool(widget.dismissedPrefsKey, true);
      } catch (_) {
        // Non-fatal.
      }
    } else {
      // The request resolved to a refusal: remember it so the button becomes an
      // "Open Settings" pointer instead of offering a second dead request.
      setState(() => _osStatus = OsNotificationPermission.denied);
    }

    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          success
              ? widget.enabledSnackBarMessage
              : widget.deniedSnackBarMessage,
          style: const TextStyle(color: Colors.white),
        ),
        backgroundColor:
            success ? Theme.of(context).primaryColor : Colors.orange,
        duration: Duration(seconds: success ? 3 : 4),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final deliverable = osPermissionAllowsDelivery(_osStatus);
    // Yield to the post-answer prompt: two asks for the same permission on one
    // screen is worse than a delayed nudge.
    final yieldToPrompt =
        PostAnswerPrompts.isShowing || PostAnswerPrompts.isPending;

    if (!_checked || !_authenticated || deliverable || _dismissed ||
        yieldToPrompt) {
      return const SizedBox.shrink();
    }

    final osDenied = _osStatus == OsNotificationPermission.denied;
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.orange.withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.orange.withOpacity(0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.notifications_off, color: Colors.orange[700], size: 24),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  widget.title,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: Colors.orange[700],
                  ),
                ),
              ),
              GestureDetector(
                onTap: _dismiss,
                child: Icon(Icons.close, color: Colors.grey[600], size: 20),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            osDenied
                ? '${widget.message} They are currently turned off for Read the '
                    'Room in your device Settings.'
                : widget.message,
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: Colors.orange[600]),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _enable,
              icon: Icon(
                  osDenied ? Icons.open_in_new : Icons.notifications_active,
                  size: 18),
              label: Text(osDenied ? 'Open Settings' : 'Enable Notifications'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.orange[700],
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
