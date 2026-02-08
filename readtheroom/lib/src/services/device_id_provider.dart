// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
// import 'package:app_set_id/app_set_id.dart'; // TODO: Fix API usage
import 'dart:io';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class DeviceIdProvider {
  static const String _deviceIdKey = 'device_id';
  static const String _deviceIdTypeKey = 'device_id_type';
  static const String _deviceIdGeneratedAtKey = 'device_id_generated_at';
  
  static const _uuid = Uuid();

  /// Get or create a stable device ID for this device
  /// Returns the existing ID if already stored (grandfathering existing users)
  /// For new users, generates UUID v4
  /// Existing users without stored ID get their actual Android ID to maintain compatibility
  static Future<String> getOrCreateDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    
    // Step 1: Check for existing ID (grandfather clause)
    final existingId = prefs.getString(_deviceIdKey);
    if (existingId != null) {
      print('🔐 DeviceIdProvider: Using existing device ID (type: ${prefs.getString(_deviceIdTypeKey) ?? 'legacy'})');
      return existingId;
    }
    
    // Step 2: For Android devices without stored ID, check if they're existing users
    if (Platform.isAndroid) {
      // Get the actual Android ID to check for existing users
      final deviceInfo = DeviceInfoPlugin();
      final androidInfo = await deviceInfo.androidInfo;
      final actualAndroidId = androidInfo.id;
      
      print('🔐 DeviceIdProvider: No stored ID found, checking if user exists with Android ID: $actualAndroidId');
      
      // Check if a user exists in the database with this Android ID
      try {
        final supabase = Supabase.instance.client;
        final existingUser = await supabase
            .from('users')
            .select('id, uuid, android_id')
            .eq('android_id', actualAndroidId)
            .maybeSingle();
            
        if (existingUser != null) {
          // Existing user found - use their Android ID for compatibility
          print('🔐 DeviceIdProvider: Found existing user with Android ID, using it for compatibility');
          await prefs.setString(_deviceIdKey, actualAndroidId);
          await prefs.setString(_deviceIdTypeKey, 'legacy');
          await prefs.setString(_deviceIdGeneratedAtKey, DateTime.now().toIso8601String());
          return actualAndroidId;
        } else {
          // No existing user - this is a new user, generate UUID v4
          print('🔐 DeviceIdProvider: No existing user found, generating UUID v4 for new Android user');
          final uuid = _uuid.v4();
          await prefs.setString(_deviceIdKey, uuid);
          await prefs.setString(_deviceIdTypeKey, 'uuid_v4');
          await prefs.setString(_deviceIdGeneratedAtKey, DateTime.now().toIso8601String());
          return uuid;
        }
      } catch (e) {
        // If database check fails, default to UUID v4 for new users
        print('🔐 DeviceIdProvider: Database check failed ($e), generating UUID v4 for safety');
        final uuid = _uuid.v4();
        await prefs.setString(_deviceIdKey, uuid);
        await prefs.setString(_deviceIdTypeKey, 'uuid_v4');
        await prefs.setString(_deviceIdGeneratedAtKey, DateTime.now().toIso8601String());
        return uuid;
      }
    }
    
    // Step 3: For iOS, use vendor ID
    if (Platform.isIOS) {
      final deviceInfo = DeviceInfoPlugin();
      final iosInfo = await deviceInfo.iosInfo;
      final vendorId = iosInfo.identifierForVendor;
      
      if (vendorId != null) {
        print('🔐 DeviceIdProvider: Using iOS vendor ID: $vendorId');
        await prefs.setString(_deviceIdKey, vendorId);
        await prefs.setString(_deviceIdTypeKey, 'ios_vendor_id');
        await prefs.setString(_deviceIdGeneratedAtKey, DateTime.now().toIso8601String());
        return vendorId;
      }
    }
    
    // Step 4: Fallback to UUID v4 for other platforms or if vendor ID is null
    print('🔐 DeviceIdProvider: Creating new UUID v4 for device ID (fallback)');
    
    final uuid = _uuid.v4();
    
    // Store the UUID and metadata
    await prefs.setString(_deviceIdKey, uuid);
    await prefs.setString(_deviceIdTypeKey, 'uuid_v4');
    await prefs.setString(_deviceIdGeneratedAtKey, DateTime.now().toIso8601String());
    
    print('🔐 DeviceIdProvider: Generated new UUID v4 as device ID');
    return uuid;
  }
  
  /// Get the type of the stored device ID
  /// Returns: 'android_id' (legacy), 'app_set_id', 'uuid_v4', or null
  static Future<String?> getDeviceIdType() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_deviceIdTypeKey);
  }
  
  /// Get when the device ID was generated
  static Future<DateTime?> getDeviceIdGeneratedAt() async {
    final prefs = await SharedPreferences.getInstance();
    final dateString = prefs.getString(_deviceIdGeneratedAtKey);
    if (dateString != null) {
      return DateTime.tryParse(dateString);
    }
    return null;
  }
  
  /// Clear stored device ID (for testing or reset scenarios)
  /// WARNING: This will cause the user to lose access to their passkey!
  static Future<void> clearDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_deviceIdKey);
    await prefs.remove(_deviceIdTypeKey);
    await prefs.remove(_deviceIdGeneratedAtKey);
    print('🔐 DeviceIdProvider: Cleared stored device ID');
  }
  
  /// Get device ID info for debugging
  static Future<Map<String, dynamic>> getDeviceIdInfo() async {
    final prefs = await SharedPreferences.getInstance();
    return {
      'device_id': prefs.getString(_deviceIdKey),
      'device_id_type': prefs.getString(_deviceIdTypeKey) ?? 'legacy',
      'generated_at': prefs.getString(_deviceIdGeneratedAtKey),
      'platform': Platform.isAndroid ? 'android' : (Platform.isIOS ? 'ios' : 'other'),
    };
  }
  
  /// Check if the current device ID is a legacy Android ID
  static Future<bool> isLegacyAndroidId() async {
    if (!Platform.isAndroid) {
      return false;
    }
    
    final prefs = await SharedPreferences.getInstance();
    final deviceIdType = prefs.getString(_deviceIdTypeKey);
    
    // If no type is stored, it's a legacy Android ID
    // If type is 'android_id' or 'legacy', it's also a legacy ID
    return deviceIdType == null || deviceIdType == 'android_id' || deviceIdType == 'legacy';
  }
  
  /// Migrate from legacy Android ID to UUID v4
  /// Returns a map with old_id and new_id for database update
  /// Returns null if migration is not applicable or fails
  static Future<Map<String, String>?> migrateToUuidV4() async {
    try {
      if (!Platform.isAndroid) {
        print('🔐 DeviceIdProvider: Migration only applicable to Android devices');
        return null;
      }
      
      final prefs = await SharedPreferences.getInstance();
      final currentId = prefs.getString(_deviceIdKey);
      final currentType = prefs.getString(_deviceIdTypeKey);
      
      if (currentId == null) {
        print('🔐 DeviceIdProvider: No existing device ID to migrate');
        return null;
      }
      
      // Check if this is actually a legacy Android ID
      if (currentType != null && currentType != 'android_id' && currentType != 'legacy') {
        print('🔐 DeviceIdProvider: Device ID is already migrated (type: $currentType)');
        return null;
      }
      
      print('🔐 DeviceIdProvider: Starting migration from legacy Android ID to UUID v4');
      
      // Generate new UUID v4
      final newId = _uuid.v4();
      
      // Store the new ID and metadata
      await prefs.setString(_deviceIdKey, newId);
      await prefs.setString(_deviceIdTypeKey, 'uuid_v4');
      await prefs.setString(_deviceIdGeneratedAtKey, DateTime.now().toIso8601String());
      
      print('🔐 DeviceIdProvider: Migration successful - Old ID: $currentId, New ID: $newId');
      
      return {
        'old_id': currentId,
        'new_id': newId,
      };
    } catch (e) {
      print('🔐 DeviceIdProvider: Migration failed with error: $e');
      return null;
    }
  }
}