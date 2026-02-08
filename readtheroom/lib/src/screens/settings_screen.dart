// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

// lib/src/screens/settings_screen.dart
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../services/user_service.dart';
import '../services/passkeys_service.dart';
import '../services/analytics_service.dart';
import '../services/notification_service.dart';
import '../widgets/authentication_dialog.dart';
import '../widgets/notification_permission_dialog.dart';
import '../widgets/question_activity_permission_dialog.dart';
import '../widgets/whats_new_dialog.dart';
import '../services/theme_service.dart';
import 'authentication_screen.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'dart:io';
import '../services/device_id_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../widgets/location_settings_widget.dart';
import 'package:package_info_plus/package_info_plus.dart';

class SettingsScreen extends StatefulWidget {
  @override
  _SettingsScreenState createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _supabase = Supabase.instance.client;
  final _passkeysService = PasskeysService();
  bool _showMigrationButton = false;
  bool _isMigrating = false;
  

  @override
  void initState() {
    super.initState();
_checkMigrationEligibility();
  }
  
@override
  void dispose() {
    super.dispose();
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

      // Delete other user-related data
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

  // Helper method to show question activity toggle snackbar
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
              SwitchListTile(
                contentPadding: EdgeInsets.symmetric(horizontal: 16.0),
                title: Row(
                  children: [
                    Icon(
                      Icons.today, 
                      size: 20, 
                      color: (_supabase.auth.currentUser == null ? true : userService.notifyQOTD) 
                          ? Theme.of(context).primaryColor 
                          : Colors.grey,
                    ),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text('Question of the Day'),
                    ),
                  ],
                ),
                subtitle: Text(
                  'Get a nudge when a new Question of the Day is available and you haven\'t answered it yet.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Colors.grey[600],
                  ),
                ),
                value: _supabase.auth.currentUser == null ? true : userService.notifyQOTD,
                onChanged: (bool value) async {
                  if (_supabase.auth.currentUser == null) {
                    AuthenticationDialog.show(
                      context,
                      customMessage: 'To manage notification settings, you need to authenticate as a real person.',
                      onComplete: () {
                        // The toggle will be updated when the screen rebuilds after auth
                      },
                    );
                    return;
                  }
                  
                  if (value) {
                    // Show our custom permission dialog when enabling
                    NotificationPermissionDialog.show(
                      context,
                      onPermissionGranted: () async {
                        // Permission was granted - enable BOTH notification types
                        await userService.onNotificationPermissionsGranted();
                        
                        // Show success message
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Row(
                                children: [
                                  Icon(Icons.notifications_active, color: Colors.white, size: 20),
                                  SizedBox(width: 8),
                                  Expanded(child: Text('All notifications enabled! You\'re all set.')),
                                ],
                              ),
                              backgroundColor: Theme.of(context).primaryColor,
                              duration: Duration(seconds: 3),
                            ),
                          );
                        }
                      },
                      onPermissionDenied: () async {
                        // Permission was denied - keep both toggles off
                        await userService.onNotificationPermissionsDenied();
                        
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Row(
                                children: [
                                  Icon(Icons.notifications_off, color: Colors.white, size: 20),
                                  SizedBox(width: 8),
                                  Expanded(child: Text('Notifications are disabled. You can enable them in device Settings.')),
                                ],
                              ),
                              backgroundColor: Colors.orange,
                              duration: Duration(seconds: 4),
                            ),
                          );
                        }
                      },
                    );
                  } else {
                    // Disabling QOTD notifications independently
                    final notificationService = NotificationService();
                    await notificationService.unsubscribeFromQOTD();
                    userService.setNotifyQOTD(false);
                    
                    // Show feedback for disabling
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Row(
                          children: [
                            Icon(Icons.today, color: Colors.white, size: 20),
                            SizedBox(width: 8),
                            Text('QotD notifications disabled :('),
                          ],
                        ),
                        backgroundColor: Theme.of(context).primaryColor,
                        duration: Duration(seconds: 2),
                      ),
                    );
                  }
                },
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.symmetric(horizontal: 16.0),
                title: Row(
                  children: [
                    Icon(
                      userService.notifyResponses ? Icons.notifications_active : Icons.notifications_none,
                      size: 20, 
                      color: userService.notifyResponses 
                          ? Theme.of(context).primaryColor 
                          : Colors.grey,
                    ),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text('Comments & Activity'),
                    ),
                  ],
                ),
                subtitle: Text(
                  'Get notified when someone comments on your question, or responds to your comments. You can subscribe to individual questions by tapping the bell icon on any question\'s page.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Colors.grey[600],
                  ),
                ),
                value: userService.notifyResponses,
                onChanged: (bool value) async {
                  if (_supabase.auth.currentUser == null) {
                    AuthenticationDialog.show(
                      context,
                      customMessage: 'To manage notification settings, you need to authenticate as a real person.',
                      onComplete: () async {
                        // After authentication, if user was trying to enable, show the dialog
                        if (value) {
                          QuestionActivityPermissionDialog.show(
                            context,
                            onPermissionGranted: () async {
                              AnalyticsService().trackQuestionSubscriptionNotificationEnabled(true);
                              userService.setNotifyResponses(true);
                              final notificationService = NotificationService();
                              await notificationService.subscribeToQuestionActivity();
                              _showQuestionActivitySnackbar(true);
                            },
                            onPermissionDenied: () async {
                              AnalyticsService().trackQuestionSubscriptionNotificationEnabled(false);
                              userService.setNotifyResponses(false);
                              if (mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Row(
                                      children: [
                                        Icon(Icons.notifications_off, color: Colors.white, size: 20),
                                        SizedBox(width: 8),
                                        Expanded(child: Text('Question activity notifications are disabled. You can enable them in device Settings.')),
                                      ],
                                    ),
                                    backgroundColor: Colors.orange,
                                    duration: Duration(seconds: 4),
                                  ),
                                );
                              }
                            },
                          );
                        } else {
                          // Just disable if they were turning it off
                          AnalyticsService().trackQuestionSubscriptionNotificationEnabled(false);
                          userService.setNotifyResponses(false);
                          final notificationService = NotificationService();
                          await notificationService.unsubscribeFromQuestionActivity();
                          _showQuestionActivitySnackbar(false);
                        }
                      },
                    );
                    return;
                  }
                  
                  if (value) {
                    // Always show our custom question activity permission dialog when enabling
                    // This is educational and explains how question activity works
                    QuestionActivityPermissionDialog.show(
                      context,
                      onPermissionGranted: () async {
                        // Permission was granted - enable question activity notifications
                        AnalyticsService().trackQuestionSubscriptionNotificationEnabled(true);
                        userService.setNotifyResponses(true);
                        final notificationService = NotificationService();
                        await notificationService.subscribeToQuestionActivity();
                        _showQuestionActivitySnackbar(true);
                      },
                      onPermissionDenied: () async {
                        // Permission was denied - keep toggle off
                        AnalyticsService().trackQuestionSubscriptionNotificationEnabled(false);
                        userService.setNotifyResponses(false);
                        
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Row(
                                children: [
                                  Icon(Icons.notifications_off, color: Colors.white, size: 20),
                                  SizedBox(width: 8),
                                  Expanded(child: Text('Question activity notifications are disabled. You can enable them in Settings.')),
                                ],
                              ),
                              backgroundColor: Colors.orange,
                              duration: Duration(seconds: 4),
                            ),
                          );
                        }
                      },
                    );
                  } else {
                    // Disabling question activity notifications independently
                    AnalyticsService().trackQuestionSubscriptionNotificationEnabled(false);
                    final notificationService = NotificationService();
                    await notificationService.unsubscribeFromQuestionActivity();
                    userService.setNotifyResponses(false);
                    _showQuestionActivitySnackbar(false);
                  }
                },
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SwitchListTile(
                    contentPadding: EdgeInsets.symmetric(horizontal: 16.0),
                    title: Row(
                      children: [
                        Icon(
                          userService.notifyStreakReminders ? Icons.local_fire_department : Icons.local_fire_department_outlined,
                          size: 20, 
                          color: userService.notifyStreakReminders 
                              ? Theme.of(context).primaryColor 
                              : Colors.grey,
                        ),
                        SizedBox(width: 8),
                        Expanded(
                          child: Text('Streak Reminders'),
                        ),
                      ],
                    ),
                    subtitle: Text(
                      userService.notifyStreakReminders
                          ? 'Get reminded at ${userService.streakReminderTime.format(context)} if you haven\'t answered a question today (only if you have an active streak)'
                          : 'Get reminded if you haven\'t answered a question today (only if you have an active streak)',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Colors.grey[600],
                      ),
                    ),
                    value: userService.notifyStreakReminders,
                    onChanged: (bool value) async {
                      if (_supabase.auth.currentUser == null) {
                        AuthenticationDialog.show(
                          context,
                          customMessage: 'To manage streak reminder settings, you need to authenticate as a real person.',
                          onComplete: () {
                            // The toggle will be updated when the screen rebuilds after auth
                          },
                        );
                        return;
                      }

                      if (value) {
                        // Check current notification permission status
                        final notificationService = NotificationService();
                        final permissionStatus = await notificationService.getPermissionStatus();

                        if (permissionStatus == AuthorizationStatus.authorized || permissionStatus == AuthorizationStatus.provisional) {
                          // Already authorized - skip dialog, enable directly
                          userService.setNotifyStreakReminders(true);
                          AnalyticsService().trackEvent('streak_reminder_changed', {'enabled': true, 'source': 'settings'});

                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Row(
                                  children: [
                                    Icon(Icons.local_fire_department, color: Colors.white, size: 20),
                                    SizedBox(width: 8),
                                    Text('Streak reminders enabled! 🔥'),
                                  ],
                                ),
                                backgroundColor: Theme.of(context).primaryColor,
                                duration: Duration(seconds: 2),
                              ),
                            );
                          }
                        } else if (permissionStatus == AuthorizationStatus.denied) {
                          // Previously denied - show snackbar with Open Settings action
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Row(
                                  children: [
                                    Icon(Icons.notifications_off, color: Colors.white, size: 20),
                                    SizedBox(width: 8),
                                    Expanded(child: Text('Notifications are disabled. Enable them in your device Settings to use streak reminders.')),
                                  ],
                                ),
                                backgroundColor: Colors.orange,
                                duration: Duration(seconds: 6),
                                action: SnackBarAction(
                                  label: 'Open Settings',
                                  textColor: Colors.white,
                                  onPressed: () async {
                                    final uri = Uri.parse('app-settings:');
                                    if (await canLaunchUrl(uri)) {
                                      await launchUrl(uri);
                                    }
                                  },
                                ),
                              ),
                            );
                          }
                        } else {
                          // Not determined - show the permission dialog (existing flow)
                          NotificationPermissionDialog.show(
                            context,
                            onPermissionGranted: () async {
                              userService.setNotifyStreakReminders(true);
                              AnalyticsService().trackEvent('streak_reminder_changed', {'enabled': true, 'source': 'settings'});

                              if (mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Row(
                                      children: [
                                        Icon(Icons.local_fire_department, color: Colors.white, size: 20),
                                        SizedBox(width: 8),
                                        Text('Streak reminders enabled! 🔥'),
                                      ],
                                    ),
                                    backgroundColor: Theme.of(context).primaryColor,
                                    duration: Duration(seconds: 2),
                                  ),
                                );
                              }
                            },
                            onPermissionDenied: () async {
                              if (mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Row(
                                      children: [
                                        Icon(Icons.notifications_off, color: Colors.white, size: 20),
                                        SizedBox(width: 8),
                                        Expanded(child: Text('Notifications required for streak reminders. Enable in Settings.')),
                                      ],
                                    ),
                                    backgroundColor: Colors.orange,
                                    duration: Duration(seconds: 4),
                                  ),
                                );
                              }
                            },
                          );
                        }
                      } else {
                        // Disabling - just turn it off
                        userService.setNotifyStreakReminders(false);
                        AnalyticsService().trackEvent('streak_reminder_changed', {'enabled': false, 'source': 'settings'});

                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Row(
                              children: [
                                Icon(Icons.local_fire_department_outlined, color: Colors.white, size: 20),
                                SizedBox(width: 8),
                                Text('Streak reminders disabled'),
                              ],
                            ),
                            backgroundColor: Theme.of(context).primaryColor,
                            duration: Duration(seconds: 2),
                          ),
                        );
                      }
                    },
                  ),
                  // Time picker for streak reminders (only show when enabled)
                  if (userService.notifyStreakReminders) 
                    Padding(
                      padding: EdgeInsets.only(left: 16.0, right: 16.0, bottom: 16.0),
                      child: ListTile(
                        contentPadding: EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
                        leading: Icon(Icons.schedule, color: Theme.of(context).primaryColor),
                        title: Text('Reminder Time'),
                        subtitle: Text(
                          'Tap to change when you\'d like to be reminded',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Colors.grey[600],
                          ),
                        ),
                        trailing: Container(
                          padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                          decoration: BoxDecoration(
                            color: Theme.of(context).primaryColor.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: Theme.of(context).primaryColor.withOpacity(0.3),
                              width: 1,
                            ),
                          ),
                          child: Text(
                            userService.streakReminderTime.format(context),
                            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                              color: Theme.of(context).primaryColor,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        onTap: () async {
                          final TimeOfDay? newTime = await showTimePicker(
                            context: context,
                            initialTime: userService.streakReminderTime,
                            helpText: 'Select reminder time',
                            builder: (context, child) {
                              return MediaQuery(
                                data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: false),
                                child: child!,
                              );
                            },
                          );
                          
                          if (newTime != null && newTime != userService.streakReminderTime) {
                            userService.setStreakReminderTime(newTime);
                            AnalyticsService().trackEvent('streak_reminder_time_changed', {'hour': newTime.hour, 'minute': newTime.minute, 'source': 'settings'});
                            
                            // Show confirmation
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Row(
                                  children: [
                                    Icon(Icons.schedule, color: Colors.white, size: 20),
                                    SizedBox(width: 8),
                                    Text('Reminder time updated to ${newTime.format(context)} ⏰'),
                                  ],
                                ),
                                backgroundColor: Theme.of(context).primaryColor,
                                duration: Duration(seconds: 2),
                              ),
                            );
                          }
                        },
                      ),
                    ),
                ],
              ),
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
                    'Permanently delete all your questions, suggestions, and anything associated with your anonymous ID.',
                    style: TextStyle(color: Colors.red[300]),
                  ),
                  onTap: () {
                    showDialog(
                      context: context,
                      builder: (BuildContext context) {
                        return AlertDialog(
                          title: Text('Delete Your Data'),
                          content: Text(
                            'This will permanently delete all questions you\'ve asked and all feedback you\'ve given. This action cannot be undone.',
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
              // Enhanced Device ID display with migration capability
              _buildEnhancedDeviceIdDisplay(),
              
              // App version at the bottom
              _buildVersionDisplay(),
            ],
          );
        },
      ),
    );
  }

}
