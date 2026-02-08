// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:provider/provider.dart';
import '../services/location_service.dart';
import '../screens/authentication_screen.dart';
import '../screens/settings_screen.dart';

class AuthenticationDialog extends StatelessWidget {
  final String? title;
  final String? message;
  final String? actionButtonText;

  const AuthenticationDialog({
    Key? key,
    this.title,
    this.message,
    this.actionButtonText,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: title != null ? Text(title!) : null,
      content: message != null ? Text(message!) : null,
      actions: [
        Center(
          child: ElevatedButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Theme.of(context).primaryColor,
              foregroundColor: Colors.white,
            ),
            child: Text(actionButtonText ?? 'Continue'),
          ),
        ),
      ],
    );
  }

  static Future<void> show(
    BuildContext context, {
    required VoidCallback onComplete,
    String? customMessage,
  }) async {
    final supabase = Supabase.instance.client;
    final locationService = Provider.of<LocationService>(context, listen: false);
    
    // Ensure LocationService is initialized
    if (!locationService.isInitialized) {
      print('DEBUG: LocationService not initialized in AuthenticationDialog, initializing now...');
      await locationService.initialize();
      print('DEBUG: LocationService initialized, selectedCity: ${locationService.selectedCity}');
    }
    
    // Check what the user needs to do
    final isAuthenticated = supabase.auth.currentUser != null;
    final hasCity = locationService.selectedCity != null;
    
    print('DEBUG: AuthenticationDialog checks - isAuthenticated: $isAuthenticated, hasCity: $hasCity, selectedCity: ${locationService.selectedCity}');
    
    String message;
    String actionText;
    
    if (!isAuthenticated && !hasCity) {
      message = customMessage ?? 'To participate, you need to authenticate as a real person and set your city.';
      actionText = 'Continue';
    } else if (!isAuthenticated) {
      message = customMessage ?? 'To participate, you need to authenticate as a real person.';
      actionText = 'Continue';
    } else if (!hasCity) {
      message = customMessage ?? 'To participate, you need to set your city.';
      actionText = 'Set City';
    } else {
      // User is already authenticated and has city - call onComplete directly
      onComplete();
      return;
    }

    return showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Row(
            children: [
              Icon(
                Icons.person_add,
                color: Theme.of(context).primaryColor,
                size: 24,
              ),
              SizedBox(width: 12),
              Text('Welcome!'),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                message,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  height: 1.4,
                ),
              ),
              SizedBox(height: 16),
              Container(
                padding: EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(context).primaryColor.withOpacity(0.05),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: Theme.of(context).primaryColor.withOpacity(0.3),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.info_outline,
                      color: Theme.of(context).primaryColor,
                      size: 20,
                    ),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'This helps us reduce spam and keeps your responses anonymous.',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).primaryColor,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          actions: [
            Center(
              child: ElevatedButton(
                onPressed: () async {
                  Navigator.of(context).pop();
                  
                  // Navigate to authentication flow
                  await _handleAuthenticationFlow(context, onComplete);
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: Theme.of(context).primaryColor,
                  foregroundColor: Colors.white,
                ),
                child: Text(actionText),
              ),
            ),
          ],
        );
      },
    );
  }

  static Future<void> _handleAuthenticationFlow(
    BuildContext context,
    VoidCallback onComplete,
  ) async {
    final supabase = Supabase.instance.client;
    final locationService = Provider.of<LocationService>(context, listen: false);
    
    final isAuthenticated = supabase.auth.currentUser != null;
    final hasCity = locationService.selectedCity != null;
    
    if (!isAuthenticated) {
      // Navigate to authentication screen with special callback
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => AuthenticationScreen(
            onAuthComplete: () async {
              try {
                print('DEBUG: AuthenticationDialog onAuthComplete called');
                
                // After auth, check if user needs to set city
                print('DEBUG: Initializing location service...');
                await locationService.initialize();
                print('DEBUG: Location service initialized, selectedCity: ${locationService.selectedCity}');
                
                if (locationService.selectedCity == null) {
                  print('DEBUG: No city set, navigating to user screen');
                  // Navigate to user screen to set city, then pop auth screen
                  if (context.mounted) {
                    print('DEBUG: Context is mounted, navigating to user screen');
                    await Navigator.pushReplacement(
                      context,
                      MaterialPageRoute(
                        builder: (context) => SettingsScreen(),
                      ),
                    );
                    print('DEBUG: Navigation to user screen completed');
                  } else {
                    print('ERROR: Context is not mounted, cannot navigate');
                  }
                } else {
                  print('DEBUG: City already set, completing flow');
                  // User already has city, pop auth screen and complete the original action
                  if (context.mounted) {
                    print('DEBUG: Popping authentication screen');
                    Navigator.of(context).pop();
                    print('DEBUG: Authentication screen popped, calling onComplete callback');
                    onComplete();
                    print('DEBUG: onComplete callback finished');
                  } else {
                    print('ERROR: Context not mounted, cannot pop authentication screen');
                  }
                }
              } catch (e) {
                print('ERROR: Exception in onAuthComplete: $e');
                print('ERROR: Stack trace: ${StackTrace.current}');
              }
            },
          ),
        ),
      );
    } else if (!hasCity) {
      // User is authenticated but needs to set city
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => SettingsScreen(),
        ),
      );
      // Check if city was set after returning
      await locationService.initialize();
      if (locationService.selectedCity != null) {
        onComplete();
      }
    } else {
      // Both conditions met
      onComplete();
    }
  }
} 