// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

// lib/src/screens/settings_screen.dart
import 'package:flutter/foundation.dart' show kReleaseMode;
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../services/user_service.dart';
import '../services/passkeys_service.dart';
import '../services/analytics_service.dart';
import '../services/notification_service.dart';
import '../services/post_answer_prompts.dart';
import '../utils/post_answer_prompt_logic.dart';
import '../widgets/authentication_dialog.dart';
import '../widgets/notification_permission_dialog.dart';
import '../widgets/notification_permission_status_row.dart';
import '../widgets/notification_settings_tile.dart';
import '../widgets/question_activity_permission_dialog.dart';
import '../widgets/whats_new_dialog.dart';
import '../services/theme_service.dart';
import '../config/build_config.dart';
import 'authentication_screen.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'dart:io';
import '../services/device_id_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../widgets/location_settings_widget.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import '../utils/demo_friends_mode.dart';
import '../services/app_review_service.dart';

class SettingsScreen extends StatefulWidget {
  @override
  _SettingsScreenState createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen>
    with WidgetsBindingObserver {
  final _supabase = Supabase.instance.client;
  final _passkeysService = PasskeysService();
  bool _showMigrationButton = false;
  bool _isMigrating = false;

  /// The live OS permission. Drives [NotificationPermissionStatusRow] and stops
  /// the toggles from offering a system prompt that iOS will ignore.
  OsNotificationPermission _osPermission = OsNotificationPermission.unknown;

  /// Server `notification_settings` row, for the quiet-hours window (which has
  /// no local equivalent — only the send-side edge functions read it).
  Map<String, dynamic>? _serverNotificationSettings;

  NotificationSettingsUiState get _notificationUiState =>
      notificationSettingsUiState(
        isAuthenticated: _supabase.auth.currentUser != null,
        osStatus: _osPermission,
      );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkMigrationEligibility();
    _refreshNotificationState();
    // Debug-only: the "Demo friends" toggle needs its persisted value. The
    // getter is clamped to false outside debug, so this never matters in
    // release — and the section that reads it is not built there either.
    if (kDebugMode) DemoFriendsMode.instance.load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// The OS permission can change while the app is backgrounded — that is the
  /// whole point of the "Open Settings" deep link. Without this the user comes
  /// back to a screen still insisting notifications are off.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed) {
      _refreshNotificationState(resyncOnGrant: true);
    }
  }

  /// Reads the OS permission and the server settings row.
  ///
  /// When [resyncOnGrant] is set and the permission has just become usable
  /// (the user granted it in the system Settings app), the stored preferences
  /// are re-applied to the FCM topics and the server row: the grant happened
  /// outside the app, so nothing had re-subscribed them.
  Future<void> _refreshNotificationState({bool resyncOnGrant = false}) async {
    final previous = _osPermission;
    final current = await PostAnswerPrompts.osPermission();

    if (mounted && current != previous) {
      setState(() => _osPermission = current);
    } else {
      _osPermission = current;
    }

    if (resyncOnGrant &&
        !osPermissionAllowsDelivery(previous) &&
        osPermissionAllowsDelivery(current) &&
        _supabase.auth.currentUser != null) {
      if (!mounted) return;
      await Provider.of<UserService>(context, listen: false)
          .resyncNotificationState();
    }

    if (_supabase.auth.currentUser == null) return;
    final row = await NotificationService().fetchNotificationSettings();
    if (mounted) {
      setState(() => _serverNotificationSettings = row);
    }
  }

  /// Opens the OS Settings page for this app.
  Future<void> _openSystemSettings() async {
    final uri = Uri.parse('app-settings:');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    }
  }

  /// The SnackBar that replaces a dead permission request when the OS has
  /// already refused. White on primary, per the house rule.
  void _showOsDeniedSnackbar(String what) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Notifications are off in your device Settings, so $what cannot be '
          'delivered. Turn them on there first.',
          style: const TextStyle(color: Colors.white),
        ),
        backgroundColor: Theme.of(context).primaryColor,
        duration: const Duration(seconds: 6),
        action: SnackBarAction(
          label: 'Open Settings',
          textColor: Colors.white,
          onPressed: _openSystemSettings,
        ),
      ),
    );
  }

  Future<void> _checkMigrationEligibility() async {
    if (!Platform.isAndroid) return;
    if (_supabase.auth.currentUser == null) return;
    
    final isLegacy = await DeviceIdProvider.isLegacyAndroidId();
    if (mounted) {
      setState(() {
        _showMigrationButton = isLegacy;
      });
    }
  }


  /// Parses a Postgres `time` (`HH:MM[:SS]`) into a [TimeOfDay], or null.
  TimeOfDay? _parseServerTime(dynamic raw) {
    if (raw is! String) return null;
    final m = RegExp(r'^(\d{1,2}):(\d{2})').firstMatch(raw);
    if (m == null) return null;
    final h = int.tryParse(m.group(1)!);
    final min = int.tryParse(m.group(2)!);
    if (h == null || min == null || h > 23 || min > 59) return null;
    return TimeOfDay(hour: h, minute: min);
  }

  String _formatServerTime(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:00';

  /// Quiet hours: a window in which the server defers pushes instead of sending
  /// them. Only shown to an authenticated user, because the window lives on
  /// their `notification_settings` row.
  ///
  /// The window is stored with an IANA timezone name from `flutter_timezone` —
  /// the edge function feeds it to `Intl.DateTimeFormat`, which needs a real zone
  /// id, not `DateTime.timeZoneName`'s abbreviation.
  List<Widget> _buildQuietHoursTiles() {
    if (_supabase.auth.currentUser == null) return const [];

    final row = _serverNotificationSettings;
    final start = _parseServerTime(row?['quiet_hours_start']);
    final end = _parseServerTime(row?['quiet_hours_end']);
    final isSet = start != null && end != null;

    Future<void> saveWindow(TimeOfDay? newStart, TimeOfDay? newEnd) async {
      await NotificationService().setQuietHours(
        start: newStart == null ? null : _formatServerTime(newStart),
        end: newEnd == null ? null : _formatServerTime(newEnd),
        timezone: newStart == null ? null : await _localTimezoneName(),
      );
      await _refreshNotificationState();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            newStart == null || newEnd == null
                ? 'Quiet hours turned off.'
                : 'Quiet hours set: ${newStart.format(context)} – ${newEnd.format(context)}.',
            style: const TextStyle(color: Colors.white),
          ),
          backgroundColor: Theme.of(context).primaryColor,
          duration: const Duration(seconds: 3),
        ),
      );
    }

    return [
      NotificationSettingsTile(
        id: 'quiet-hours',
        icon: isSet ? Icons.bedtime : Icons.bedtime_outlined,
        title: 'Quiet hours',
        subtitle: 'Hold push notifications.',
        value: isSet,
        // The window itself is the row's inline chip: one row that gains a
        // control when it is on, rather than a second indented block.
        chipLabel: isSet
            ? '${start.format(context)} – ${end.format(context)}'
            : null,
        onChipTap: () async {
          // Captured non-null: promotion through `isSet` does not reach inside
          // this closure.
          final currentStart = start ?? const TimeOfDay(hour: 22, minute: 0);
          final currentEnd = end ?? const TimeOfDay(hour: 7, minute: 0);
          final newStart = await showTimePicker(
            context: context,
            initialTime: currentStart,
            helpText: 'Quiet hours start',
          );
          if (newStart == null || !mounted) return;
          final newEnd = await showTimePicker(
            context: context,
            initialTime: currentEnd,
            helpText: 'Quiet hours end',
          );
          if (newEnd == null || !mounted) return;
          await saveWindow(newStart, newEnd);
        },
        onChanged: (bool value) async {
          if (value) {
            // A sensible default beats making the user pick twice before the
            // switch does anything.
            await saveWindow(
              const TimeOfDay(hour: 22, minute: 0),
              const TimeOfDay(hour: 7, minute: 0),
            );
          } else {
            await saveWindow(null, null);
          }
        },
      ),
    ];
  }

  /// The device's IANA timezone name, falling back to UTC (the column default)
  /// rather than guessing — a wrong zone would shift the window.
  Future<String> _localTimezoneName() async {
    try {
      return await FlutterTimezone.getLocalTimezone();
    } catch (e) {
      print('Settings: could not read local timezone: $e');
      return 'UTC';
    }
  }

  Widget _buildThemeOption(
    BuildContext context,
    String label,
    IconData icon,
    ThemeMode themeMode, {
    bool isFirst = false,
    bool isLast = false,
  }) {
    final themeService = Provider.of<ThemeService>(context);
    final isSelected = themeService.themeMode == themeMode;
    
    return GestureDetector(
      onTap: () {
        themeService.setThemeMode(themeMode);
      },
      child: Container(
        padding: EdgeInsets.symmetric(vertical: 12, horizontal: 8),
        decoration: BoxDecoration(
          color: isSelected 
              ? Theme.of(context).primaryColor.withOpacity(0.1)
              : Colors.transparent,
          borderRadius: BorderRadius.only(
            topLeft: isFirst ? Radius.circular(7) : Radius.zero,
            bottomLeft: isFirst ? Radius.circular(7) : Radius.zero,
            topRight: isLast ? Radius.circular(7) : Radius.zero,
            bottomRight: isLast ? Radius.circular(7) : Radius.zero,
          ),
          border: isSelected ? Border.all(
            color: Theme.of(context).primaryColor,
            width: 2,
          ) : null,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              color: isSelected 
                  ? Theme.of(context).primaryColor
                  : Theme.of(context).iconTheme.color,
              size: 20,
            ),
            SizedBox(height: 4),
            Text(
              label,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: isSelected 
                    ? Theme.of(context).primaryColor
                    : Theme.of(context).textTheme.bodyMedium?.color,
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _logout() async {
    try {
      // Check if user is authenticated with passkey
      final isPasskeyUser = await _passkeysService.isPasskeySetup();
      
      if (isPasskeyUser) {
        // For passkey users, use the PasskeysService logout method
        // This preserves the user data and only clears local session
        await _passkeysService.logout();
      } else {
        // For other auth methods (OAuth), use regular signOut
        await _supabase.auth.signOut();
      }
      
      // Update UserService with new auth state
      final userService = Provider.of<UserService>(context, listen: false);
      await userService.onAuthStateChanged();
      
      // Re-check migration eligibility after logout
      await _checkMigrationEligibility();
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Logged out successfully'),
          backgroundColor: Theme.of(context).primaryColor,
        ),
      );
      
      // Navigate back to main screen
      Navigator.pop(context);
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error logging out: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _performDeviceIdMigration() async {
    setState(() {
      _isMigrating = true;
    });
    
    try {
      final success = await _passkeysService.migrateDeviceId();
      
      if (success) {
        if (mounted) {
          setState(() {
            _showMigrationButton = false;
            _isMigrating = false;
          });
          
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Row(
                children: [
                  Icon(Icons.check_circle, color: Colors.white, size: 20),
                  SizedBox(width: 8),
                  Text('Device ID migration successful!'),
                ],
              ),
              backgroundColor: Colors.green,
              duration: Duration(seconds: 3),
            ),
          );
        }
      } else {
        if (mounted) {
          setState(() {
            _isMigrating = false;
          });
          
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Row(
                children: [
                  Icon(Icons.error, color: Colors.white, size: 20),
                  SizedBox(width: 8),
                  Expanded(child: Text('Migration failed. Please try again or contact support.')),
                ],
              ),
              backgroundColor: Colors.red,
              duration: Duration(seconds: 4),
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isMigrating = false;
        });
        
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error during migration: $e'),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 4),
          ),
        );
      }
    }
  }

  Future<void> _deleteUserData() async {
    try {
      final currentUser = _supabase.auth.currentUser;
      if (currentUser == null) {
        print('No authenticated user found');
        return;
      }

      print('Starting data deletion for user: ${currentUser.id}');
      print('User email: ${currentUser.email}');

      // Clear passkey credentials FIRST to prevent recreation
      try {
        final isPasskeyUser = await _passkeysService.isPasskeySetup();
        if (isPasskeyUser) {
          await _passkeysService.clearStoredCredentials();
          print('Cleared passkey credentials first');
        }
      } catch (e) {
        print('Error clearing passkey credentials: $e');
      }

      // Get all questions authored by this user first
      final userQuestions = await _supabase
          .from('questions')
          .select('id')
          .eq('author_id', currentUser.id);
      
      final questionIds = userQuestions.map((q) => q['id']).toList();
      print('Found ${questionIds.length} questions to delete: $questionIds');

      // Delete each question and its related data individually
      for (final questionId in questionIds) {
        try {
          print('Deleting data for question: $questionId');
          
          // Delete question_categories for this question
          await _supabase
              .from('question_categories')
              .delete()
              .eq('question_id', questionId);
          print('Deleted question_categories for $questionId');

          // Delete question_options for this question  
          await _supabase
              .from('question_options')
              .delete()
              .eq('question_id', questionId);
          print('Deleted question_options for $questionId');

          // Delete responses to this question
          await _supabase
              .from('responses')
              .delete()
              .eq('question_id', questionId);
          print('Deleted responses for $questionId');

        } catch (e) {
          print('Error deleting related data for question $questionId: $e');
        }
      }

      // Now delete the questions themselves
      try {
        final questionsResult = await _supabase
            .from('questions')
            .delete()
            .eq('author_id', currentUser.id);
        print('Deleted user questions: $questionsResult');
        
        // Verify questions are deleted
        final remainingQuestions = await _supabase
            .from('questions')
            .select('id')
            .eq('author_id', currentUser.id);
        print('Remaining questions after deletion: ${remainingQuestions.length}');
      } catch (e) {
        print('Error deleting questions: $e');
      }

      // Transfer or delete rooms created by user
      try {
        final userRooms = await _supabase
            .from('rooms')
            .select('id')
            .eq('created_by', currentUser.id);

        for (final room in userRooms) {
          final roomId = room['id'];
          // Find another member to transfer ownership to
          final otherMembers = await _supabase
              .from('room_members')
              .select('user_id')
              .eq('room_id', roomId)
              .neq('user_id', currentUser.id)
              .order('joined_at', ascending: true)
              .limit(1);

          if (otherMembers.isNotEmpty) {
            // Transfer ownership to oldest other member
            await _supabase
                .from('rooms')
                .update({'created_by': otherMembers.first['user_id']})
                .eq('id', roomId);
            print('Transferred room $roomId ownership');
          } else {
            // No other members — delete the room
            await _supabase.from('rooms').delete().eq('id', roomId);
            print('Deleted empty room $roomId');
          }
        }
      } catch (e) {
        print('Error handling rooms: $e');
      }

      // Delete other user-related data. `suggestions` is the retired public
      // suggestions table — the feature is gone from the app but the rows are
      // still the user's, so keep purging them until the table is dropped.
      final tablesToClean = [
        'saved_questions',
        'suggestions', 
        'user_preferences',
        'user_answered_questions'
      ];

      for (final table in tablesToClean) {
        try {
          await _supabase.from(table).delete().eq('user_id', currentUser.id);
          print('Deleted from $table');
        } catch (e) {
          print('Error deleting from $table: $e');
        }
      }

      // Delete the user record from users table
      try {
        print('Attempting to delete user record...');
        final userDeleteResult = await _supabase
            .from('users')
            .delete()
            .eq('id', currentUser.id);
        print('User deletion result: $userDeleteResult');
        
        // Verify user is deleted
        final remainingUser = await _supabase
            .from('users')
            .select('id')
            .eq('id', currentUser.id);
        print('Remaining user records: ${remainingUser.length}');
      } catch (e) {
        print('Error deleting user record: $e');
      }
      
      // Clear local user service data BEFORE signing out
      try {
        final userService = Provider.of<UserService>(context, listen: false);
        await userService.clearAllData();
        print('Cleared local user data');
      } catch (e) {
        print('Error clearing local data: $e');
      }
      
      // Reset PostHog analytics
      try {
        await AnalyticsService().reset();
        print('Reset PostHog analytics');
      } catch (e) {
        print('Error resetting analytics: $e');
      }

      // Delete auth.users record (triggers CASCADE for ~12 remaining tables)
      try {
        await _supabase.rpc('reset_passkey_user', params: {'p_user_id': currentUser.id});
        print('Deleted auth user record');
      } catch (e) {
        print('Error deleting auth user: $e');
      }

      // Sign out from Supabase Auth LAST
      try {
        await _supabase.auth.signOut();
        print('Signed out user from auth');
      } catch (e) {
        print('Error signing out: $e');
      }
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Account and data deleted successfully'),
            backgroundColor: Theme.of(context).primaryColor,
            duration: Duration(seconds: 3),
          ),
        );
        
        // Navigate back to main screen
        Navigator.pop(context);
      }
    } catch (e) {
      print('Major error in data deletion: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error during deletion: $e'),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 4),
          ),
        );
      }
    }
  }

  // --- notification section -------------------------------------------------
  //
  // One screen, not six. The section is: the OS-permission status row (owned by
  // the build method above), one master switch, then a compact row per
  // category. Every row is a [NotificationSettingsTile] — icon, title, one
  // short line, an optional inline chip, switch — so the quiet-hours window
  // lives *in* its row instead of in a second indented block below it.
  //
  // This is layout and copy only. Every handler below drives the same
  // UserService / NotificationService calls the old `SwitchListTile`s did: the
  // auth gate, the OS-denied guard, the pre-prompt dialogs, the topic
  // subscribe/unsubscribe and the server writes are unchanged.

  /// The auth gate shared by every row. Returns `true` when the tap was
  /// swallowed because there is no signed-in user.
  bool _requireAuthForNotifications({String? customMessage}) {
    if (_supabase.auth.currentUser != null) return false;
    AuthenticationDialog.show(
      context,
      customMessage: customMessage ??
          'To manage notification settings, you need to authenticate as a real person.',
      onComplete: () {
        // The toggles re-read UserService when the screen rebuilds after auth.
        if (mounted) setState(() {});
      },
    );
    return true;
  }

  /// White-on-primary confirmation, the house SnackBar style.
  void _showNotificationSnackbar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message, style: const TextStyle(color: Colors.white)),
        backgroundColor: Theme.of(context).primaryColor,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  List<Widget> _buildNotificationTiles(UserService userService) {
    // A guest sees the QOTD default (`true`) rather than a dead `false`, which
    // is the behaviour the old toggle had; the onChanged is gated anyway.
    final isGuest = _supabase.auth.currentUser == null;
    final qotdOn = isGuest ? true : userService.notifyQOTD;
    final masterOn = notificationsMasterEnabled(
      qotd: qotdOn,
      responses: userService.notifyResponses,
      friendEvents: userService.notifyFriendEvents,
    );

    return [
      NotificationSettingsTile(
        id: 'master',
        icon: masterOn ? Icons.notifications_active : Icons.notifications_off,
        title: 'Notifications',
        subtitle: masterOn ? 'On — refine below.' : 'Off — nothing is sent.',
        value: masterOn,
        emphasised: true,
        onChanged: _onMasterChanged,
      ),
      const Divider(height: 8, indent: 16, endIndent: 16),
      // No time chip: the question drops at a random moment chosen by the
      // server, the same instant for everyone, so there is nothing to pick.
      NotificationSettingsTile(
        id: 'qotd',
        icon: Icons.bolt,
        title: 'Question of the Day',
        subtitle: 'The question drops at a random moment each day. '
            "The first few who answer get to vote on the next day's question.",
        value: qotdOn,
        onChanged: (value) => _onQotdChanged(userService, value),
      ),
      NotificationSettingsTile(
        id: 'activity',
        icon: Icons.mode_comment_outlined,
        title: 'Responses & comments',
        subtitle: 'Replies on your questions and comments.',
        value: userService.notifyResponses,
        onChanged: (value) => _onActivityChanged(userService, value),
      ),
      NotificationSettingsTile(
        id: 'friends',
        icon: Icons.groups_outlined,
        title: 'Friends',
        subtitle: 'Requests, licks 🦎 and forwarded questions.',
        value: userService.notifyFriendEvents,
        onChanged: (value) => _onFriendsChanged(userService, value),
      ),
      ..._buildQuietHoursTiles(),
    ];
  }

  /// The master switch. On: run the one permission flow and turn the push
  /// categories on. Off: every category off, which is the only reading of
  /// "Notifications: off" that is not a lie.
  ///
  /// Composed from the existing setters — `notification_settings.
  /// notifications_enabled` is still deliberately not written by the client
  /// (see the 2026-09-11 audit §4).
  Future<void> _onMasterChanged(bool value) async {
    if (_requireAuthForNotifications()) return;
    final userService = Provider.of<UserService>(context, listen: false);

    if (!value) {
      await userService.setNotifyQOTD(false);
      await userService.setNotifyResponses(false);
      await userService.setNotifyFriendEvents(false);
      if (mounted) _showNotificationSnackbar('Notifications off.');
      return;
    }

    // OS-denied: a request is a dead call on iOS, so send the user where it can
    // actually be fixed rather than to a success message for nothing.
    if (_osPermission == OsNotificationPermission.denied) {
      _showOsDeniedSnackbar('notifications');
      return;
    }

    Future<void> enableAll() async {
      // Owns QOTD + responses (topics, server row, local reminders).
      await userService.onNotificationPermissionsGranted();
      await userService.setNotifyFriendEvents(true);
      await _refreshNotificationState();
      if (mounted) _showNotificationSnackbar('Notifications on.');
    }

    if (osPermissionAllowsDelivery(_osPermission)) {
      await enableAll();
      return;
    }

    if (!mounted) return;
    await NotificationPermissionDialog.show(
      context,
      onPermissionGranted: enableAll,
      onPermissionDenied: () async {
        await userService.onNotificationPermissionsDenied();
        await _refreshNotificationState();
        if (mounted) {
          _showNotificationSnackbar(
              'Notifications stay off. You can turn them on any time.');
        }
      },
    );
  }

  Future<void> _onQotdChanged(UserService userService, bool value) async {
    if (_requireAuthForNotifications()) return;

    if (!value) {
      await userService.setNotifyQOTD(false);
      if (mounted) _showNotificationSnackbar('Drop alerts off.');
      return;
    }

    if (_osPermission == OsNotificationPermission.denied) {
      _showOsDeniedSnackbar('the daily question');
      return;
    }
    if (osPermissionAllowsDelivery(_osPermission)) {
      await userService.setNotifyQOTD(true);
      if (mounted) {
        _showNotificationSnackbar(
            'Drop alerts on — the question lands at a random moment each day.');
      }
      return;
    }

    if (!mounted) return;
    await NotificationPermissionDialog.show(
      context,
      onPermissionGranted: () async {
        await userService.onNotificationPermissionsGranted();
        await _refreshNotificationState();
        if (mounted) _showNotificationSnackbar('Notifications on.');
      },
      onPermissionDenied: () async {
        await userService.onNotificationPermissionsDenied();
        await _refreshNotificationState();
        if (mounted) {
          _showNotificationSnackbar(
              'Notifications stay off — turn them on in device Settings.');
        }
      },
    );
  }

  Future<void> _onActivityChanged(UserService userService, bool value) async {
    if (_requireAuthForNotifications()) return;

    if (!value) {
      AnalyticsService().trackQuestionSubscriptionNotificationEnabled(false);
      await userService.setNotifyResponses(false);
      if (mounted) _showQuestionActivitySnackbar(false);
      return;
    }

    if (_osPermission == OsNotificationPermission.denied) {
      _showOsDeniedSnackbar('comment and activity updates');
      return;
    }

    // The educational dialog is shown whenever enabling, as before: it explains
    // what "question activity" covers, not just the permission.
    if (!mounted) return;
    await QuestionActivityPermissionDialog.show(
      context,
      onPermissionGranted: () async {
        AnalyticsService().trackQuestionSubscriptionNotificationEnabled(true);
        await userService.setNotifyResponses(true);
        await _refreshNotificationState();
        if (mounted) _showQuestionActivitySnackbar(true);
      },
      onPermissionDenied: () async {
        AnalyticsService().trackQuestionSubscriptionNotificationEnabled(false);
        await userService.setNotifyResponses(false);
        if (mounted) {
          _showNotificationSnackbar(
              'Activity alerts stay off. Enable them any time.');
        }
      },
    );
  }

  Future<void> _onFriendsChanged(UserService userService, bool value) async {
    if (_requireAuthForNotifications()) return;
    // The preference is saved even when the OS refuses — the intent is real,
    // and the row above already explains why nothing will arrive.
    await userService.setNotifyFriendEvents(value);
    if (!mounted) return;
    if (value && _osPermission == OsNotificationPermission.denied) {
      _showOsDeniedSnackbar('friend activity');
      return;
    }
    _showFriendEventsSnackbar(value);
  }

  // Helper method to show question activity toggle snackbar
  void _showFriendEventsSnackbar(bool enabled) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          enabled
              ? 'Friend alerts enabled 🦎'
              : "Friend alerts off — you'll still see them in the app",
          style: const TextStyle(color: Colors.white),
        ),
        backgroundColor: Theme.of(context).primaryColor,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  void _showQuestionActivitySnackbar(bool enabled) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(
              enabled ? Icons.notifications_active : Icons.notifications_none,
              color: Colors.white,
              size: 20,
            ),
            SizedBox(width: 8),
            Text(enabled 
                ? 'Question activity alerts enabled!'
                : 'Question activity alerts disabled :('),
          ],
        ),
        backgroundColor: Theme.of(context).primaryColor,
        duration: Duration(seconds: 2),
      ),
    );
  }


  // Helper method to get device ID
  Future<String?> _getDeviceId() async {
    try {
      if (Platform.isAndroid) {
        // Use DeviceIdProvider to get the current device ID (whether legacy or migrated)
        return await DeviceIdProvider.getOrCreateDeviceId();
      } else if (Platform.isIOS) {
        final deviceInfo = DeviceInfoPlugin();
        final iosInfo = await deviceInfo.iosInfo;
        return iosInfo.identifierForVendor; // iOS identifier for vendor
      } else {
        return 'Unsupported platform';
      }
    } catch (e) {
      print('Error getting device ID: $e');
      return null;
    }
  }

  // Enhanced device ID display with migration status and clickable legacy IDs
  Widget _buildEnhancedDeviceIdDisplay() {
    return Padding(
      padding: EdgeInsets.fromLTRB(16.0, 0.0, 16.0, 16.0),
      child: FutureBuilder<Map<String, dynamic>>(
        future: _getEnhancedDeviceIdInfo(),
        builder: (context, snapshot) {
          if (snapshot.hasData && snapshot.data != null) {
            final data = snapshot.data!;
            final deviceId = data['device_id'] as String;
            final deviceType = data['device_id_type'] as String?;
            final isLegacy = data['is_legacy'] as bool;
            final platform = data['platform'] as String;
            
            // Determine the label based on device type and platform
            String label;
            Color? labelColor;
            bool isClickable = false;
            
            if (platform == 'android') {
              if (isLegacy) {
                label = 'Android ID (legacy)';
                labelColor = Colors.orange;
                isClickable = true;
              } else {
                label = 'Android ID';
                labelColor = Theme.of(context).primaryColor;
              }
            } else if (platform == 'ios') {
              label = 'iOS ID';
            } else {
              label = 'Device ID';
            }
            
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$label (for debugging):',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: labelColor ?? Colors.grey[600],
                    fontWeight: FontWeight.w500,
                  ),
                ),
                SizedBox(height: 4),
                GestureDetector(
                  onTap: () {
                    if (isClickable && _supabase.auth.currentUser != null) {
                      // Show migration dialog for legacy Android IDs
                      showDialog(
                        context: context,
                        builder: (BuildContext context) {
                          return AlertDialog(
                            title: Text('Migrate Device ID'),
                            content: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('This will upgrade your device identifier to a more privacy-friendly format.'),
                                SizedBox(height: 12),
                                Text('Benefits:', style: TextStyle(fontWeight: FontWeight.bold)),
                                SizedBox(height: 4),
                                Text('• Enhanced privacy protection'),
                                Text('• Not trackable across apps'),
                                Text('• Unique to this app only'),
                                SizedBox(height: 12),
                                Text('Your authentication and all data will be preserved.', 
                                     style: TextStyle(color: Theme.of(context).primaryColor)),
                              ],
                            ),
                            actions: [
                              TextButton(
                                child: Text('Cancel'),
                                onPressed: () => Navigator.of(context).pop(),
                              ),
                              TextButton(
                                child: Text('Migrate'),
                                onPressed: () async {
                                  Navigator.of(context).pop();
                                  await _performDeviceIdMigration();
                                },
                              ),
                            ],
                          );
                        },
                      );
                    } else {
                      // Copy to clipboard and show feedback
                      Clipboard.setData(ClipboardData(text: deviceId));
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('Device ID copied to clipboard'),
                          duration: Duration(seconds: 2),
                          backgroundColor: Colors.orange,
                        ),
                      );
                    }
                  },
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          deviceId,
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: isClickable ? (labelColor ?? Colors.grey[500]) : Colors.grey[500],
                            fontStyle: FontStyle.italic,
                            decoration: TextDecoration.underline,
                            decorationStyle: TextDecorationStyle.dotted,
                          ),
                        ),
                      ),
                      if (isClickable) ...[
                        SizedBox(width: 8),
                        Icon(
                          Icons.arrow_forward_ios,
                          size: 12,
                          color: labelColor,
                        ),
                      ],
                    ],
                  ),
                ),
                if (isClickable) ...[
                  SizedBox(height: 4),
                  Text(
                    'Tap to migrate to enhanced privacy',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: labelColor,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ],
              ],
            );
          } else if (snapshot.hasError) {
            return Text(
              'Device ID: Error loading',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Colors.grey[500],
                fontStyle: FontStyle.italic,
              ),
            );
          } else {
            return Text(
              'Device ID: Loading...',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Colors.grey[500],
                fontStyle: FontStyle.italic,
              ),
            );
          }
        },
      ),
    );
  }

  // Get enhanced device ID information including type and migration status
  Future<Map<String, dynamic>> _getEnhancedDeviceIdInfo() async {
    try {
      final deviceId = await _getDeviceId();
      final deviceInfo = await DeviceIdProvider.getDeviceIdInfo();
      final isLegacy = Platform.isAndroid ? await DeviceIdProvider.isLegacyAndroidId() : false;
      
      return {
        'device_id': deviceId ?? 'Unknown',
        'device_id_type': deviceInfo['device_id_type'],
        'is_legacy': isLegacy,
        'platform': Platform.isAndroid ? 'android' : (Platform.isIOS ? 'ios' : 'other'),
      };
    } catch (e) {
      return {
        'device_id': 'Error loading',
        'device_id_type': null,
        'is_legacy': false,
        'platform': 'unknown',
      };
    }
  }

  Widget _buildVersionDisplay() {
    return Padding(
      padding: EdgeInsets.fromLTRB(16.0, 8.0, 16.0, 24.0),
      child: FutureBuilder<PackageInfo>(
        future: PackageInfo.fromPlatform(),
        builder: (context, snapshot) {
          if (snapshot.hasData) {
            final packageInfo = snapshot.data!;
            return Center(
              child: GestureDetector(
                onTap: () => WhatsNewDialog.show(context),
                child: Text(
                  'App Version v${packageInfo.version}+${packageInfo.buildNumber}',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Colors.grey[500],
                  ),
                ),
              ),
            );
          } else {
            return Center(
              child: GestureDetector(
                onTap: () => WhatsNewDialog.show(context),
                child: Text(
                  'App Version: v1.0.2+64',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Colors.grey[500],
                  ),
                ),
              ),
            );
          }
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Settings'),
      ),
      body: Consumer<UserService>(
        builder: (context, userService, child) {
          return ListView(
            children: [
              // Location setting at the very top using LocationSettingsWidget
              Padding(
                padding: EdgeInsets.fromLTRB(16.0, 24.0, 16.0, 8.0),
                child: LocationSettingsWidget(
                  showTitle: true,
                  showDescription: true,
                  showGuidancePrompts: true,
                ),
              ),
              Divider(height: 32),
              
              // Theme setting
              Padding(
                padding: EdgeInsets.fromLTRB(16.0, 24.0, 16.0, 8.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Appearance',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    SizedBox(height: 12),
                  ],
                ),
              ),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Theme',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    SizedBox(height: 8),
                    Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: Theme.of(context).dividerColor,
                          width: 1,
                        ),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: _buildThemeOption(
                              context,
                              'Light',
                              Icons.light_mode,
                              ThemeMode.light,
                              isFirst: true,
                            ),
                          ),
                          Expanded(
                            child: _buildThemeOption(
                              context,
                              'Dark',
                              Icons.dark_mode,
                              ThemeMode.dark,
                            ),
                          ),
                          Expanded(
                            child: _buildThemeOption(
                              context,
                              'System',
                              Icons.settings_brightness,
                              ThemeMode.system,
                              isLast: true,
                            ),
                          ),
                        ],
                      ),
                    ),
                    SizedBox(height: 12),
                    Text(
                      'Choose your preferred theme or follow system settings',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Colors.grey[600],
                      ),
                    ),
                  ],
                ),
              ),
              Divider(height: 32),
              // Advanced settings (authenticated)
              Padding(
                padding: EdgeInsets.fromLTRB(16.0, 8.0, 16.0, 8.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Advanced Settings',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    SizedBox(height: 12),
                    if (_supabase.auth.currentUser == null)
                      RichText(
                        text: TextSpan(
                          style: Theme.of(context).textTheme.bodySmall,
                          children: [
                            TextSpan(
                              text: 'Authenticate your account',
                              style: TextStyle(
                                color: Theme.of(context).primaryColor,
                                decoration: TextDecoration.none,
                                fontWeight: FontWeight.bold,
                              ),
                              recognizer: TapGestureRecognizer()
                                ..onTap = () {
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(builder: (context) => AuthenticationScreen()),
                                  );
                                },
                            ),
                            TextSpan(text: ' to access these features.'),
                          ],
                        ),
                      )
                    else
                      Text(
                        'Nice, you\'re already authenticated!',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).primaryColor,
                        ),
                      ),
                    SizedBox(height: 12),
                  ],
                ),
              ),
              // Notification preferences section
              Padding(
                padding: EdgeInsets.fromLTRB(16.0, 8.0, 16.0, 8.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Notifications & Nudges',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    SizedBox(height: 12),
                  ],
                ),
              ),
              // What the OS actually allows, before any toggle claims otherwise.
              NotificationPermissionStatusRow(
                state: _notificationUiState,
                onOpenSettings: _openSystemSettings,
              ),
              ..._buildNotificationTiles(userService),
              // Debug-only: lets the post-answer notification prompt be retested
              // on a device that has already seen it once (the flags are
              // per-install and a simulator keeps them across hot restarts).
              if (!kReleaseMode && _supabase.auth.currentUser != null)
                ListTile(
                  contentPadding: EdgeInsets.symmetric(horizontal: 16.0),
                  leading: Icon(Icons.restart_alt, color: Colors.grey[600]),
                  title: Text('Reset notification prompts'),
                  subtitle: Text(
                    'Debug only — the next QOTD answer asks again.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Colors.grey[600],
                        ),
                  ),
                  onTap: () async {
                    await userService.resetNotificationPromptState();
                    if (!mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: const Text(
                          'Notification prompt state cleared. Answer the QOTD to see the prompt again.',
                          style: TextStyle(color: Colors.white),
                        ),
                        backgroundColor: Theme.of(context).primaryColor,
                        duration: const Duration(seconds: 4),
                      ),
                    );
                  },
                ),
              // Privacy section (F-Droid only)
              if (BuildConfig.isFDroidBuild) ...[
                Padding(
                  padding: EdgeInsets.fromLTRB(16.0, 24.0, 16.0, 8.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Privacy',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      SizedBox(height: 12),
                    ],
                  ),
                ),
                FutureBuilder<bool>(
                  future: AnalyticsService().isOptedOut(),
                  builder: (context, snapshot) {
                    final isOptedOut = snapshot.data ?? false;
                    return SwitchListTile(
                      contentPadding: EdgeInsets.symmetric(horizontal: 16.0),
                      title: Text('Anonymous Analytics'),
                      subtitle: Text(
                        'Help improve Read the Room with usage metrics (PostHog)',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Colors.grey[600],
                        ),
                      ),
                      value: !isOptedOut,
                      onChanged: (bool value) async {
                        await AnalyticsService().setOptOut(!value);
                        setState(() {});
                      },
                    );
                  },
                ),
                Divider(height: 32),
              ],
              // Mature Content section
              Padding(
                padding: EdgeInsets.fromLTRB(16.0, 24.0, 16.0, 8.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Mature Content',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    SizedBox(height: 12),
                  ],
                ),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.symmetric(horizontal: 16.0),
                title: Text('Show NSFW / 18+ content'),
                subtitle: Text(
                  'Display questions addressed to adults. You must be above the age of majority in your country to view this content.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Colors.grey[600],
                  ),
                ),
                value: userService.showNSFWContent,
                onChanged: (value) {
                  if (_supabase.auth.currentUser == null) {
                    AuthenticationDialog.show(
                      context,
                      customMessage: 'To manage content settings, you need to authenticate as a real person.',
                      onComplete: () {
                        userService.setShowNSFWContent(value);
                      },
                    );
                    return;
                  }
                  userService.setShowNSFWContent(value);
                },
              ),
              Divider(height: 32),
              // Homepage link
              ListTile(
                contentPadding: EdgeInsets.symmetric(horizontal: 16.0),
                leading: Icon(Icons.web, color: Theme.of(context).primaryColor),
                title: Text('Homepage'),
                subtitle: Text(
                  'Visit readtheroom.site',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Colors.grey[600],
                  ),
                ),
                trailing: Icon(Icons.launch, size: 18),
                onTap: () async {
                  final url = Uri.parse('https://readtheroom.site/');
                  if (await canLaunchUrl(url)) {
                    await launchUrl(url, mode: LaunchMode.externalApplication);
                  } else {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('Could not open website'),
                          backgroundColor: Colors.red,
                        ),
                      );
                    }
                  }
                },
              ),
              SizedBox(height: 24),
              if (_supabase.auth.currentUser != null) ...[
                if (_showMigrationButton) ...[
                  ListTile(
                    leading: _isMigrating 
                        ? SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation<Color>(Theme.of(context).primaryColor),
                            ),
                          )
                        : Icon(Icons.security, color: Theme.of(context).primaryColor),
                    title: Text('Migrate to Enhanced Privacy ID'),
                    subtitle: Text(
                      'One-time upgrade to a more private device identifier. Your data and authentication will be preserved.',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Colors.grey[600],
                      ),
                    ),
                    enabled: !_isMigrating,
                    onTap: _isMigrating ? null : () {
                      showDialog(
                        context: context,
                        builder: (BuildContext context) {
                          return AlertDialog(
                            title: Text('Migrate Device ID'),
                            content: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('This will upgrade your device identifier to a more privacy-friendly format.'),
                                SizedBox(height: 12),
                                Text('Benefits:', style: TextStyle(fontWeight: FontWeight.bold)),
                                SizedBox(height: 4),
                                Text('• Enhanced privacy protection'),
                                Text('• Not trackable across apps'),
                                Text('• Unique to this app only'),
                                SizedBox(height: 12),
                                Text('Your authentication and all data will be preserved.', 
                                     style: TextStyle(color: Theme.of(context).primaryColor)),
                              ],
                            ),
                            actions: [
                              TextButton(
                                child: Text('Cancel'),
                                onPressed: () => Navigator.of(context).pop(),
                              ),
                              TextButton(
                                child: Text('Migrate'),
                                onPressed: () async {
                                  Navigator.of(context).pop();
                                  await _performDeviceIdMigration();
                                },
                              ),
                            ],
                          );
                        },
                      );
                    },
                  ),
                  Divider(height: 16),
                ],
                ListTile(
                  leading: Icon(Icons.logout, color: Theme.of(context).primaryColor),
                  title: Text('Logout'),
                  subtitle: Text(
                    'Sign out of your account',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Colors.grey[600],
                    ),
                  ),
                  onTap: () {
                    showDialog(
                      context: context,
                      builder: (BuildContext context) {
                        return AlertDialog(
                          title: Text('Logout'),
                          content: Text('Are you sure you want to logout?'),
                          actions: [
                            TextButton(
                              child: Text('Cancel'),
                              onPressed: () => Navigator.of(context).pop(),
                            ),
                            TextButton(
                              child: Text('Logout'),
                              onPressed: () async {
                                Navigator.of(context).pop();
                                await _logout();
                              },
                            ),
                          ],
                        );
                      },
                    );
                  },
                ),
                ListTile(
                  leading: Icon(Icons.delete_forever, color: Colors.red),
                  title: Text(
                    'Delete account',
                    style: TextStyle(color: Colors.red),
                  ),
                  subtitle: Text(
                    'Permanently delete all your questions, answers, comments, and anything associated with your anonymous ID.',
                    style: TextStyle(color: Colors.red[300]),
                  ),
                  onTap: () {
                    showDialog(
                      context: context,
                      builder: (BuildContext context) {
                        return AlertDialog(
                          title: Text('Delete Your Data'),
                          content: Text(
                            'This will permanently delete all questions you\'ve asked, every answer and comment you\'ve left, and your profile. This action cannot be undone.',
                          ),
                          actions: [
                            TextButton(
                              child: Text('Cancel'),
                              onPressed: () => Navigator.of(context).pop(),
                            ),
                            TextButton(
                              child: Text(
                                'Delete',
                                style: TextStyle(color: Colors.red),
                              ),
                              onPressed: () async {
                                Navigator.of(context).pop();
                                await _deleteUserData();
                              },
                            ),
                          ],
                        );
                      },
                    );
                  },
                ),
                Divider(height: 32),
              ],
              // Developer section — debug builds only. `kDebugMode` is a
              // compile-time constant, so none of this is even compiled into a
              // release binary.
              if (kDebugMode) ..._buildDeveloperSection(),
              // Device ID display — debug builds only. The device id is enough
              // to look an account up before sign-in, so a release build must
              // never show it or offer to copy it (a support screenshot would
              // hand the account over). Legacy Android ids still migrate
              // automatically at sign-in (PasskeysService).
              if (kDebugMode) _buildEnhancedDeviceIdDisplay(),
              
              // App version at the bottom
              _buildVersionDisplay(),
            ],
          );
        },
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Developer section (debug builds only)
  // ---------------------------------------------------------------------------

  /// Owner-facing switches that must never exist in a shipped build. Guarded by
  /// `kDebugMode` at the call site *and* by each feature's own gate.
  List<Widget> _buildDeveloperSection() {
    final demo = DemoFriendsMode.instance;
    return [
      Divider(height: 32),
      Padding(
        padding: EdgeInsets.fromLTRB(16.0, 24.0, 16.0, 8.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Developer',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            SizedBox(height: 4),
            Text(
              'Debug builds only. These switches are compiled out of release '
              'builds entirely.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Colors.grey[600],
              ),
            ),
            SizedBox(height: 12),
          ],
        ),
      ),
      ListenableBuilder(
        listenable: demo,
        builder: (context, _) => SwitchListTile(
          contentPadding: EdgeInsets.symmetric(horizontal: 16.0),
          title: Text('Demo friends'),
          subtitle: Text(
            'Fill the Community tab with a sample friend graph and a chat you '
            'can lick, forward and react in. Nothing touches the backend; '
            'replies and notifications are simulated on this device.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Colors.grey[600],
            ),
          ),
          value: demo.enabled,
          onChanged: (value) async {
            await demo.setEnabled(value);
            if (!mounted) return;
            ScaffoldMessenger.of(context).hideCurrentSnackBar();
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  'Restart the app to apply',
                  style: TextStyle(color: Colors.white),
                ),
                backgroundColor: Theme.of(context).primaryColor,
                duration: Duration(seconds: 3),
              ),
            );
          },
        ),
      ),
      ListTile(
        contentPadding: EdgeInsets.symmetric(horizontal: 16.0),
        leading: Icon(Icons.rate_review_outlined),
        title: Text('Reset app-review prompts'),
        subtitle: Text(
          'Clears this app\'s own record of store-review requests so the '
          'prompt can be re-tested. The OS keeps its own 3-per-year counter.',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Colors.grey[600],
          ),
        ),
        onTap: () async {
          await AppReviewService().resetPromptHistory();
          if (!mounted) return;
          ScaffoldMessenger.of(context).hideCurrentSnackBar();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'App-review prompt history cleared',
                style: TextStyle(color: Colors.white),
              ),
              backgroundColor: Theme.of(context).primaryColor,
              duration: Duration(seconds: 2),
            ),
          );
        },
      ),
    ];
  }

}
