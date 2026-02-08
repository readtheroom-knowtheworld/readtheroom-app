// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'dart:io';
import '../services/passkeys_service.dart';
import '../services/user_service.dart';
import '../services/guest_user_tracking_service.dart';
import '../services/location_service.dart';
import '../services/device_id_provider.dart';
import '../services/analytics_service.dart';
import 'user_screen.dart';

class AuthenticationScreen extends StatefulWidget {
  final VoidCallback? onAuthComplete;
  
  const AuthenticationScreen({Key? key, this.onAuthComplete}) : super(key: key);
  
  @override
  _AuthenticationScreenState createState() => _AuthenticationScreenState();
}

class _AuthenticationScreenState extends State<AuthenticationScreen> {
  final _supabase = Supabase.instance.client;
  final _passkeysService = PasskeysService();
  bool _showPrivacy = false;
  bool _isPasskeyAvailable = false;

  // Community Guidelines content 
  static const String guidelinesText =
      "Help us keep RTR thoughtful, respectful, and fun.\n\n"
      "• Tag your questions appropriately\n\n"
      "• Report offensive or abusive content using the in-app report buttons\n\n"
      "• Use the NSFW/18+ flag for mature content\n\n"
      "We have zero tolerance for doxxing, harassment, abuse, incitement of violence, and illegal content. If you encounter any of this, please report the post immediately and write to:";

  static const String guidelinesEmailText = "support@readtheroom.site";

  @override
  void initState() {
    super.initState();
    _checkPasskeyAvailability();
    
    // Track authentication prompt viewed
    AnalyticsService().trackOnboardingStep('auth_prompted', 2);
  }

  Future<void> _checkPasskeyAvailability() async {
    final isSetup = await _passkeysService.isPasskeySetup();
    setState(() {
      _isPasskeyAvailable = isSetup;
    });
  }

  Future<void> _navigateAfterAuthentication() async {
    print('DEBUG: _navigateAfterAuthentication called');
    print('DEBUG: widget.onAuthComplete is ${widget.onAuthComplete != null ? 'not null' : 'null'}');
    
    if (widget.onAuthComplete != null) {
      // Custom callback provided - use it instead of default navigation
      print('DEBUG: Calling custom onAuthComplete callback');
      widget.onAuthComplete!();
      return;
    }
    
    // Default navigation behavior for regular auth screen usage
    print('DEBUG: Using default navigation behavior');
    final locationService = Provider.of<LocationService>(context, listen: false);
    await locationService.initialize();
    
    print('DEBUG: Location service initialized');
    print('DEBUG: selectedCountry is ${locationService.selectedCountry}');
    print('DEBUG: selectedCity is ${locationService.selectedCity}');
    
    if (locationService.selectedCountry == null || locationService.selectedCity == null) {
      // User needs to set country and/or city, navigate to Me page to set location
      print('DEBUG: Missing location data, navigating to Me page');
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(
          builder: (context) => UserScreen(fromAuthentication: true),
        ),
        (route) => false,
      );
    } else {
      // User has both country and city set, go to main screen with drawer and navigation
      print('DEBUG: Location complete, navigating to main screen');
      Navigator.pushNamedAndRemoveUntil(context, '/', (route) => false);
    }
  }

  Future<void> _signInWithGoogle() async {
    // Track auth method selection
    await AnalyticsService().trackOnboardingStep('auth_selected', 3, {
      'auth_method': 'google',
    });
    
    await _supabase.auth.signInWithOAuth(
      OAuthProvider.google,
      redirectTo: 'com.readtheroom.app://auth-callback',
    );
  }

  Future<void> _signInWithApple() async {
    // Track auth method selection
    await AnalyticsService().trackOnboardingStep('auth_selected', 3, {
      'auth_method': 'apple',
    });
    
    await _supabase.auth.signInWithOAuth(
      OAuthProvider.apple,
      redirectTo: 'com.readtheroom.app://auth-callback',
    );
  }

  Future<void> _signInWithPasskey() async {
    // Track auth method selection
    await AnalyticsService().trackOnboardingStep('auth_selected', 3, {
      'auth_method': 'passkey',
    });
    
    try {
      if (_isPasskeyAvailable) {
        // Authenticate with existing passkey
        print('DEBUG: Attempting passkey authentication...');
        final success = await _passkeysService.authenticate();
        print('DEBUG: Passkey authentication result: $success');
        
        if (success) {
          print('DEBUG: Authentication successful, checking Supabase auth state...');
          final currentUser = _supabase.auth.currentUser;
          print('DEBUG: Supabase currentUser: ${currentUser?.id}');
          
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Row(
                children: [
                  Icon(Icons.check_circle_outline, color: Colors.white, size: 20),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Successfully authenticated with passkey!',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                      ),
                    ),
                  ),
                ],
              ),
              backgroundColor: Theme.of(context).primaryColor,
              duration: Duration(seconds: 1),
              behavior: SnackBarBehavior.floating,
              margin: EdgeInsets.all(16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          );
          
          // Update UserService with new auth state
          if (mounted) {
            print('DEBUG: Updating UserService auth state...');
            final userService = Provider.of<UserService>(context, listen: false);
            final guestTrackingService = Provider.of<GuestUserTrackingService>(context, listen: false);
            await userService.onAuthStateChanged(guestTrackingService);
            print('DEBUG: UserService auth state updated');
          }
          
          // Navigate based on location settings
          print('DEBUG: Calling _navigateAfterAuthentication...');
          await _navigateAfterAuthentication();
        } else {
          // If authentication fails, DON'T automatically clean up - the user might just need to retry
          print('Authentication failed, showing user options...');

          // Show user a dialog with options instead of automatically deleting their account
          if (mounted) {
            final result = await showDialog<String>(
              context: context,
              builder: (context) => AlertDialog(
                title: Text('Passkey Authentication Failed'),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Your passkey couldn\'t be verified. This can happen after reinstalling the app.'),
                    SizedBox(height: 16),
                    Text('• Try Again - Attempt authentication again', style: TextStyle(fontSize: 13)),
                    SizedBox(height: 8),
                    Text('• Recover Account - Create a new passkey and keep all your data (questions, comments, streak)', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
                    SizedBox(height: 8),
                    Text('• Start Fresh - Delete everything and create a new account', style: TextStyle(fontSize: 13, color: Colors.grey[600])),
                  ],
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop('try_again'),
                    child: Text('Try Again'),
                  ),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop('recover'),
                    child: Text('Recover Account'),
                    style: TextButton.styleFrom(foregroundColor: Theme.of(context).primaryColor),
                  ),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop('reset'),
                    child: Text('Start Fresh'),
                    style: TextButton.styleFrom(foregroundColor: Colors.red),
                  ),
                ],
              ),
            );
            
            if (result == 'try_again') {
              // Just retry authentication without cleanup
              return _signInWithPasskey();
            } else if (result == 'recover') {
              // User wants to recover their account (preserve data)
              print('User requested account recovery...');

              try {
                final recoverySuccess = await _passkeysService.recoverPasskeyForDevice();

                if (recoverySuccess) {
                  setState(() {
                    _isPasskeyAvailable = true;
                  });

                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Row(
                        children: [
                          Icon(Icons.check_circle_outline, color: Colors.white, size: 20),
                          SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Account recovered! All your data has been preserved.',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 14,
                              ),
                            ),
                          ),
                        ],
                      ),
                      backgroundColor: Theme.of(context).primaryColor,
                      duration: Duration(seconds: 3),
                      behavior: SnackBarBehavior.floating,
                      margin: EdgeInsets.all(16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  );

                  // Update UserService with new auth state
                  if (mounted) {
                    final userService = Provider.of<UserService>(context, listen: false);
                    final guestTrackingService = Provider.of<GuestUserTrackingService>(context, listen: false);
                    await userService.onAuthStateChanged(guestTrackingService);
                  }

                  // Navigate based on location settings
                  await _navigateAfterAuthentication();
                } else {
                  throw Exception('Account recovery failed');
                }
              } catch (e) {
                print('Account recovery error: $e');
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Row(
                      children: [
                        Icon(Icons.error_outline, color: Colors.white, size: 20),
                        SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Recovery failed: ${e.toString().replaceAll('Exception: ', '')}',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                            ),
                          ),
                        ),
                      ],
                    ),
                    backgroundColor: Colors.red,
                    duration: Duration(seconds: 5),
                    behavior: SnackBarBehavior.floating,
                    margin: EdgeInsets.all(16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                );
              }
            } else if (result == 'reset') {
              // User explicitly requested reset (start fresh)
              print('User requested passkey reset (start fresh)...');
              
              final resetSuccess = await _passkeysService.resetPasskeyForCurrentDevice();
              
              // Also reset passkey in database if user is authenticated
              try {
                final currentUser = _supabase.auth.currentUser;
                if (currentUser != null) {
                  print('Calling reset_passkey_user RPC for user: ${currentUser.id}');
                  await _supabase.rpc('reset_passkey_user', params: {'p_user_id': currentUser.id});
                  print('Successfully called reset_passkey_user RPC');
                } else {
                  print('No authenticated user found, skipping database reset');
                }
              } catch (e) {
                print('Error calling reset_passkey_user RPC: $e');
                // Continue with reset even if RPC fails
              }
              
              if (resetSuccess) {
                await _passkeysService.clearStoredCredentials();
                setState(() {
                  _isPasskeyAvailable = false;
                });
                
                // Now try to register a new passkey
                final registerSuccess = await _passkeysService.register();
                
                if (registerSuccess) {
                  setState(() {
                    _isPasskeyAvailable = true;
                  });
                  
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Row(
                        children: [
                          Icon(Icons.check_circle_outline, color: Colors.white, size: 20),
                          SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Passkey reset and re-registered successfully!',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 14,
                              ),
                            ),
                          ),
                        ],
                      ),
                      backgroundColor: Theme.of(context).primaryColor,
                      duration: Duration(seconds: 3),
                      behavior: SnackBarBehavior.floating,
                      margin: EdgeInsets.all(16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  );
                  
                  // Update UserService with new auth state
                  if (mounted) {
                    final userService = Provider.of<UserService>(context, listen: false);
                    final guestTrackingService = Provider.of<GuestUserTrackingService>(context, listen: false);
                    await userService.onAuthStateChanged(guestTrackingService);
                  }
                  
                  // Navigate based on location settings
                  await _navigateAfterAuthentication();
                } else {
                  throw Exception('Passkey re-registration failed after reset');
                }
              } else {
                throw Exception('Passkey reset failed');
              }
            }
            // If user cancelled dialog, just return without doing anything
          }
        }
      } else {
        // No passkey available according to our check, but let's double-check
        // to avoid the double prompt issue in the register method
        final existingPasskey = await _passkeysService.findExistingPasskeyForDevice();
        
        if (existingPasskey != null) {
          // There's actually a passkey, but our initial check missed it
          // Authenticate directly instead of going through register
          print('Found existing passkey despite initial check, authenticating...');
          final success = await _passkeysService.authenticate();
          
          if (success) {
            setState(() {
              _isPasskeyAvailable = true;
            });
            
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Row(
                  children: [
                    Icon(Icons.check_circle_outline, color: Colors.white, size: 20),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Welcome back!',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                        ),
                      ),
                    ),
                  ],
                ),
                backgroundColor: Theme.of(context).primaryColor,
                duration: Duration(seconds: 3),
                behavior: SnackBarBehavior.floating,
                margin: EdgeInsets.all(16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            );
            
            // Update UserService with new auth state
            if (mounted) {
              final userService = Provider.of<UserService>(context, listen: false);
              final guestTrackingService = Provider.of<GuestUserTrackingService>(context, listen: false);
              await userService.onAuthStateChanged(guestTrackingService);
            }
            
            // Navigate based on location settings
            await _navigateAfterAuthentication();
          } else {
            // Authentication failed, fall back to register
            final success = await _passkeysService.register();
            if (success) {
              setState(() {
                _isPasskeyAvailable = true;
              });
              
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Row(
                    children: [
                      Icon(Icons.check_circle_outline, color: Colors.white, size: 20),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Passkey set up successfully!',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                          ),
                        ),
                      ),
                    ],
                  ),
                  backgroundColor: Theme.of(context).primaryColor,
                  duration: Duration(seconds: 3),
                  behavior: SnackBarBehavior.floating,
                  margin: EdgeInsets.all(16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              );
              
              // Update UserService with new auth state
              if (mounted) {
                final userService = Provider.of<UserService>(context, listen: false);
                await userService.onAuthStateChanged();
              }
              
              // Navigate based on location settings
              await _navigateAfterAuthentication();
            } else {
              throw Exception('Passkey operation failed');
            }
          }
        } else {
          // Truly no existing passkey, register a new one
          final success = await _passkeysService.register();
          if (success) {
            setState(() {
              _isPasskeyAvailable = true;
            });
            
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Row(
                  children: [
                    Icon(Icons.check_circle_outline, color: Colors.white, size: 20),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Passkey set up successfully!',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                        ),
                      ),
                    ),
                  ],
                ),
                backgroundColor: Theme.of(context).primaryColor,
                duration: Duration(seconds: 3),
                behavior: SnackBarBehavior.floating,
                margin: EdgeInsets.all(16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            );
            
            // Update UserService with new auth state
            if (mounted) {
              final userService = Provider.of<UserService>(context, listen: false);
              final guestTrackingService = Provider.of<GuestUserTrackingService>(context, listen: false);
              await userService.onAuthStateChanged(guestTrackingService);
            }
            
            // Navigate based on location settings
            await _navigateAfterAuthentication();
          } else {
            throw Exception('Passkey operation failed');
          }
        }
      }
    } catch (e) {
      print('Passkey operation error: $e');
      
      // Provide user-friendly error messages based on the error type
      String userMessage;
      Color backgroundColor = Colors.red;
      
      if (e.toString().contains('cancelled') || e.toString().contains('Authentication cancelled')) {
        userMessage = 'Passkey authentication was cancelled. Please try again when ready.';
        backgroundColor = Colors.orange;
      } else if (e.toString().contains('No credentials exist')) {
        userMessage = 'No passkey found on this device. Please set up a new passkey.';
        backgroundColor = Colors.orange;
      } else if (e.toString().contains('duplicate key value violates unique constraint')) {
        userMessage = 'A passkey already exists for this device but couldn\'t be accessed. Please try the "Reset Passkey" option.';
        backgroundColor = Colors.orange;
      } else if (e.toString().contains('User exists but could not be authenticated')) {
        userMessage = 'Your passkey exists but couldn\'t be verified. Please try again or reset your passkey.';
        backgroundColor = Colors.orange;
      } else if (e.toString().contains('Failed to create credential')) {
        userMessage = 'Unable to create passkey. Please check your device settings and try again.';
        backgroundColor = Colors.red;
      } else if (e.toString().contains('re-registration failed')) {
        userMessage = 'Couldn\'t set up new passkey after reset. Please try again.';
        backgroundColor = Colors.red;
      } else {
        userMessage = 'Passkey setup encountered an issue. Please try again or contact support if this continues.';
        backgroundColor = Colors.red;
      }
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                Icon(
                  backgroundColor == Colors.red ? Icons.error_outline : Icons.warning_amber_rounded,
                  color: Colors.white,
                  size: 20,
                ),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    userMessage,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                    ),
                  ),
                ),
              ],
            ),
            backgroundColor: backgroundColor,
            duration: Duration(seconds: 6),
            behavior: SnackBarBehavior.floating,
            margin: EdgeInsets.all(16),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        );
      }
    }
  }

  void _navigateToGuidelines() async {
    final url = Uri.parse('https://readtheroom.site/about/#community-guidelines');
    if (await canLaunchUrl(url)) {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    } else {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                Icon(Icons.error_outline, color: Colors.white, size: 20),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Could not open Community Guidelines. Please check your internet connection.',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                    ),
                  ),
                ),
              ],
            ),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 3),
            behavior: SnackBarBehavior.floating,
            margin: EdgeInsets.all(16),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        );
      }
    }
  }

  // Helper method to get device ID and type information
  Future<Map<String, String?>> _getDeviceIdInfo() async {
    try {
      if (Platform.isAndroid) {
        // Use DeviceIdProvider for Android to get comprehensive info
        final deviceId = await DeviceIdProvider.getOrCreateDeviceId();
        final deviceIdInfo = await DeviceIdProvider.getDeviceIdInfo();
        return {
          'id': deviceId,
          'type': deviceIdInfo['device_id_type'] ?? 'unknown',
        };
      } else if (Platform.isIOS) {
        // Continue using vendor ID for iOS
        final deviceInfo = DeviceInfoPlugin();
        final iosInfo = await deviceInfo.iosInfo;
        return {
          'id': iosInfo.identifierForVendor,
          'type': 'ios_vendor_id',
        };
      } else {
        return {
          'id': 'Unsupported platform',
          'type': 'unsupported',
        };
      }
    } catch (e) {
      print('Error getting device ID info: $e');
      return {
        'id': null,
        'type': 'error',
      };
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('User Authentication'),
      ),
      body: Center(
        child: SingleChildScrollView(
          child: Padding(
            padding: EdgeInsets.all(24.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Center(
                  child: Image.asset(
                    'assets/images/RTR-logo_Aug2025.png',
                    height: 80,
                  ),
                ),
                SizedBox(height: 24),
                Text(
                  'Welcome to Read The Room!',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                SizedBox(height: 32),
                Container(
                  width: double.infinity,
                  padding: EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surface,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    'Authenticating as a human allows you to respond to and submit questions, feedback, comment, access advanced settings. It also helps us reduce spam and abuse.',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      height: 1.6,
                      color: Theme.of(context).textTheme.bodyMedium?.color?.withOpacity(0.8),
                    ),
                  ),
                ),
                SizedBox(height: 32),
                ExpansionTile(
                  title: Text(
                    'Community Guidelines',
                    style: TextStyle(
                      color: Theme.of(context).textTheme.bodyLarge?.color,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  initiallyExpanded: false,
                  children: [
                    Padding(
                      padding: EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            guidelinesText, 
                            style: TextStyle(color: Theme.of(context).textTheme.bodyMedium?.color),
                          ),
                          TextButton(
                            onPressed: () async {
                              await Clipboard.setData(ClipboardData(text: guidelinesEmailText));
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      'Email copied to clipboard',
                                      style: TextStyle(color: Colors.white),
                                    ),
                                    duration: Duration(seconds: 3),
                                    backgroundColor: Colors.teal,
                                  ),
                                );
                              }
                            },
                            style: TextButton.styleFrom(
                              padding: EdgeInsets.zero,
                              minimumSize: Size(0, 0),
                              alignment: Alignment.centerLeft,
                            ),
                            child: Text(
                              guidelinesEmailText,
                              style: TextStyle(
                                color: Colors.teal,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                ExpansionTile(
                  title: Text(
                    'Privacy & Data Usage',
                    style: TextStyle(
                      color: Theme.of(context).textTheme.bodyLarge?.color,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  initiallyExpanded: false,
                  children: [
                    Padding(
                      padding: EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'What we collect:',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: Theme.of(context).textTheme.bodyMedium?.color,
                            ),
                          ),
                          SizedBox(height: 8),
                          Text(
                            '• Anonymous device ID (from Apple/Google), uniquely generated for use with RTR.',
                            style: TextStyle(color: Theme.of(context).textTheme.bodyMedium?.color),
                          ),
                          SizedBox(height: 16),
                          Text(
                            'How we use your data:',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: Theme.of(context).textTheme.bodyMedium?.color,
                            ),
                          ),
                          SizedBox(height: 8),
                          RichText(
                            text: TextSpan(
                              style: TextStyle(color: Theme.of(context).textTheme.bodyMedium?.color),
                              children: [
                                TextSpan(text: '• The unique ID provided by Apple/Google is used to detect and limit spam, abuse, and repeat offenders of our '),
                                TextSpan(
                                  text: 'Community Guidelines',
                                  style: TextStyle(
                                    color: Theme.of(context).primaryColor,
                                    fontWeight: FontWeight.bold,
                                  ),
                                  recognizer: TapGestureRecognizer()..onTap = _navigateToGuidelines,
                                ),
                                TextSpan(text: '.'),
                              ],
                            ),
                          ),
                          SizedBox(height: 16),
                          Text(
                            'Data storage:',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: Theme.of(context).textTheme.bodyMedium?.color,
                            ),
                          ),
                          SizedBox(height: 8),
                          Text(
                            '• We do not share your data with third parties, including Apple and Google.',
                            style: TextStyle(color: Theme.of(context).textTheme.bodyMedium?.color),
                          ),
                          Text(
                            '• You can request data deletion at any time in the Settings screen.',
                            style: TextStyle(color: Theme.of(context).textTheme.bodyMedium?.color),
                          ),
                          SizedBox(height: 16),
                          Text(
                            'We do not collect or store your profile information, email, or any other personally identifying information.\n\nWe do not associate your votes with your device ID, only the questions you have posted and the suggestions you have given are associated with your anonymous device ID so that you can delete and modify them at any time.', 
                            style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(context).textTheme.bodyMedium?.color,
                            ),
                          ),
                          SizedBox(height: 16),
                          RichText(
                            text: TextSpan(
                              style: TextStyle(
                                color: Theme.of(context).textTheme.bodyMedium?.color,
                                fontSize: 14,
                              ),
                              children: [
                                TextSpan(text: 'For more information, please see our '),
                                TextSpan(
                                  text: 'Privacy Policy',
                                  style: TextStyle(
                                    color: Theme.of(context).primaryColor,
                                    fontWeight: FontWeight.bold,
                                  ),
                                  recognizer: TapGestureRecognizer()
                                    ..onTap = () => launchUrl(Uri.parse('https://readtheroom.site/privacy')),
                                ),
                                TextSpan(text: '.'),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                SizedBox(height: 32),
                RichText(
                  textAlign: TextAlign.center,
                  text: TextSpan(
                    style: TextStyle(
                      color: Theme.of(context).textTheme.bodyMedium?.color,
                      fontSize: 14,
                    ),
                    children: [
                      TextSpan(text: 'By authenticating your account, you are agreeing to our '),
                      TextSpan(
                        text: 'Terms of Service',
                        style: TextStyle(
                          color: Theme.of(context).primaryColor,
                          fontWeight: FontWeight.bold,
                        ),
                        recognizer: TapGestureRecognizer()
                          ..onTap = () => launchUrl(Uri.parse('https://readtheroom.site/terms/')),
                      ),
                      TextSpan(text: '.'),
                    ],
                  ),
                ),
                SizedBox(height: 16),
                SizedBox(
                  width: 280,
                  child: ElevatedButton.icon(
                    onPressed: _signInWithPasskey,
                    icon: Icon(Icons.fingerprint),
                    label: Text(_isPasskeyAvailable ? 'Authenticate (Screen Unlock)' : 'Authenticate as Human'),
                    style: ElevatedButton.styleFrom(
                      padding: EdgeInsets.symmetric(vertical: 16),
                      backgroundColor: Colors.white,
                      foregroundColor: Colors.black87,
                      elevation: 2,
                      side: BorderSide(color: Colors.grey.shade300),
                    ),
                  ),
                ),
                SizedBox(height: 32),
                // Device ID display (always shown)
                Padding(
                  padding: EdgeInsets.fromLTRB(16.0, 16.0, 16.0, 24.0),
                  child: Column(
                    children: [
                      // Help text
                      Container(
                        width: double.infinity,
                        padding: EdgeInsets.only(bottom: 8),
                        child: RichText(
                          textAlign: TextAlign.center,
                          text: TextSpan(
                            style: TextStyle(
                              color: Colors.grey[600],
                              fontSize: 12,
                            ),
                            children: [
                              TextSpan(text: 'Problems? Send the ID below to\n'),
                              TextSpan(
                                text: 'dev@readtheroom.site',
                                style: TextStyle(
                                  color: Theme.of(context).primaryColor,
                                  fontWeight: FontWeight.bold,
                                  decoration: TextDecoration.underline,
                                  decorationStyle: TextDecorationStyle.dotted,
                                ),
                                recognizer: TapGestureRecognizer()
                                  ..onTap = () async {
                                    await Clipboard.setData(ClipboardData(text: 'dev@readtheroom.site'));
                                    if (context.mounted) {
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        SnackBar(
                                          content: Row(
                                            children: [
                                              Icon(Icons.check_circle_outline, color: Colors.white, size: 20),
                                              SizedBox(width: 8),
                                              Expanded(
                                                child: Text(
                                                  'Email address copied to clipboard',
                                                  style: TextStyle(
                                                    color: Colors.white,
                                                    fontSize: 14,
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                          backgroundColor: Colors.teal,
                                          duration: Duration(seconds: 3),
                                          behavior: SnackBarBehavior.floating,
                                          margin: EdgeInsets.all(16),
                                          shape: RoundedRectangleBorder(
                                            borderRadius: BorderRadius.circular(8),
                                          ),
                                        ),
                                      );
                                    }
                                  },
                              ),
                            ],
                          ),
                        ),
                      ),
                      // Device ID
                      FutureBuilder<Map<String, String?>>(
                        future: _getDeviceIdInfo(),
                        builder: (context, snapshot) {
                          if (snapshot.hasData && snapshot.data != null) {
                            final deviceInfo = snapshot.data!;
                            final deviceId = deviceInfo['id'] ?? 'Unknown';
                            final deviceIdType = deviceInfo['type'] ?? 'unknown';
                            
                            // Determine display label based on type
                            String typeLabel;
                            if (Platform.isAndroid) {
                              switch (deviceIdType) {
                                case 'app_set_id':
                                  typeLabel = 'AppSet ID';
                                  break;
                                case 'uuid_v4':
                                  typeLabel = 'UUID v4';
                                  break;
                                case 'legacy':
                                case 'android_id':
                                  typeLabel = 'Android ID';
                                  break;
                                default:
                                  typeLabel = 'Device ID';
                              }
                            } else if (Platform.isIOS) {
                              typeLabel = 'iOS Vendor ID';
                            } else {
                              typeLabel = 'Device ID';
                            }
                        
                        return GestureDetector(
                          onTap: () async {
                            await Clipboard.setData(ClipboardData(text: deviceId));
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    'Device ID copied to clipboard',
                                    style: TextStyle(color: Colors.white),
                                  ),
                                  duration: Duration(seconds: 3),
                                  backgroundColor: Colors.teal,
                                ),
                              );
                            }
                          },
                          child: Container(
                            width: double.infinity,
                            padding: EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: Theme.of(context).colorScheme.surface,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '$typeLabel (for debugging):',
                                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: Colors.grey[600],
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                                SizedBox(height: 4),
                                Text(
                                  deviceId,
                                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: Colors.grey[500],
                                    fontStyle: FontStyle.italic,
                                    fontSize: 10,
                                    decoration: TextDecoration.underline,
                                    decorationStyle: TextDecorationStyle.dotted,
                                  ),
                                ),
                                SizedBox(height: 4),
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    Text(
                                      'Tap to copy',
                                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                        color: Colors.grey[500],
                                        fontSize: 10,
                                      ),
                                    ),
                                    if (deviceIdType != 'error' && deviceIdType != 'unsupported')
                                      Text(
                                        'Type: $deviceIdType',
                                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                          color: Colors.grey[500],
                                          fontSize: 9,
                                          fontStyle: FontStyle.italic,
                                        ),
                                      ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        );
                      } else {
                        return Container(
                          width: double.infinity,
                          padding: EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.surface,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            'Device ID: Loading...',
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: Colors.grey[500],
                              fontStyle: FontStyle.italic,
                              fontSize: 10,
                            ),
                          ),
                                                    );
                          }
                        },
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
} 
