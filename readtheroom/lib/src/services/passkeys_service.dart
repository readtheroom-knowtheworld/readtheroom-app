// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:crypto/crypto.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:math';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:webauthn/webauthn.dart';
import 'device_id_provider.dart';

class PasskeysService {
  final _supabase = Supabase.instance.client;
  static const String _userIdKey = 'passkey_user_id';
  static const String _credentialIdKey = 'passkey_credential_id';
  final _uuid = Uuid();
  final _authenticator = Authenticator(true, false); // biometric required, strongbox optional

  // Helper method for consistent debug logging
  void _debugLog(String message) {
    print('🔐 PASSKEY_DEBUG [${Platform.isAndroid ? 'ANDROID' : 'iOS'}]: $message');
  }

  Future<String?> getStoredUserId() async {
    final prefs = await SharedPreferences.getInstance();
    final userId = prefs.getString(_userIdKey);
    _debugLog('getStoredUserId() -> $userId');
    return userId;
  }

  Future<String?> getStoredCredentialId() async {
    final prefs = await SharedPreferences.getInstance();
    final credentialId = prefs.getString(_credentialIdKey);
    _debugLog('getStoredCredentialId() -> ${credentialId?.substring(0, 20)}...');
    return credentialId;
  }

  Future<void> storeCredentials(String userId, String credentialId) async {
    _debugLog('storeCredentials() - userId: $userId, credentialId: ${credentialId.substring(0, 20)}...');
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_userIdKey, userId);
    await prefs.setString(_credentialIdKey, credentialId);
    _debugLog('storeCredentials() - Successfully stored to SharedPreferences');
  }

  Future<String?> _getDeviceId() async {
    _debugLog('_getDeviceId() - Getting device ID for platform: ${Platform.isAndroid ? 'Android' : 'iOS'}');
    
    if (Platform.isAndroid) {
      // Use DeviceIdProvider for Android to get AppSetID/UUID with fallback
      final deviceId = await DeviceIdProvider.getOrCreateDeviceId();
      final deviceIdInfo = await DeviceIdProvider.getDeviceIdInfo();
      _debugLog('_getDeviceId() - Android Device ID: $deviceId (type: ${deviceIdInfo['device_id_type']})');
      return deviceId;
    } else if (Platform.isIOS) {
      // Continue using vendor ID for iOS
      final deviceInfo = DeviceInfoPlugin();
      final iosInfo = await deviceInfo.iosInfo;
      final deviceId = iosInfo.identifierForVendor;
      _debugLog('_getDeviceId() - iOS Vendor ID: $deviceId');
      return deviceId; // Apple Vendor ID
    }
    
    _debugLog('_getDeviceId() - No device ID available for this platform');
    return null;
  }

  Future<Map<String, dynamic>?> findExistingPasskeyForDevice() async {
    _debugLog('findExistingPasskeyForDevice() - Starting search');
    try {
      final deviceId = await _getDeviceId();
      
      if (deviceId == null) {
        _debugLog('findExistingPasskeyForDevice() - No device ID available');
        return null;
      }

      _debugLog('findExistingPasskeyForDevice() - Looking for existing user with device ID: $deviceId');

      Map<String, dynamic>? userData;
      
      if (Platform.isAndroid) {
        _debugLog('findExistingPasskeyForDevice() - Querying users table for Android device');
        final response = await _supabase
            .from('users')
            .select('*')
            .eq('android_id', deviceId)
            .eq('auth_method', 'passkey')
            .eq('is_fully_registered', true) // Only return fully registered users
            .maybeSingle();
        userData = response;
        _debugLog('findExistingPasskeyForDevice() - Android query result: ${userData != null ? 'FOUND USER' : 'NO USER'} ${userData != null ? '(UUID: ${userData['uuid']}, is_fully_registered: ${userData['is_fully_registered']})' : ''}');
      } else if (Platform.isIOS) {
        _debugLog('findExistingPasskeyForDevice() - Querying users table for iOS device');
        final response = await _supabase
            .from('users')
            .select('*')
            .eq('apple_vendor_id', deviceId)
            .eq('auth_method', 'passkey')
            .eq('is_fully_registered', true) // Only return fully registered users
            .maybeSingle();
        userData = response;
        _debugLog('findExistingPasskeyForDevice() - iOS query result: ${userData != null ? 'FOUND USER' : 'NO USER'} ${userData != null ? '(UUID: ${userData['uuid']}, is_fully_registered: ${userData['is_fully_registered']})' : ''}');
      }

      if (userData != null) {
        _debugLog('findExistingPasskeyForDevice() - Found existing fully registered user: ${userData['uuid']}');
        _debugLog('findExistingPasskeyForDevice() - User details: auth_method=${userData['auth_method']}, created_at=${userData['created_at']}, last_passkey_use=${userData['last_passkey_use']}, is_fully_registered=${userData['is_fully_registered']}');
      } else {
        _debugLog('findExistingPasskeyForDevice() - No existing fully registered user found for device ID: $deviceId');
        
        // Check if there are any broken registrations for this device that need cleanup
        Map<String, dynamic>? brokenUser;
        if (Platform.isAndroid) {
          _debugLog('findExistingPasskeyForDevice() - Checking for broken Android registrations');
          final response = await _supabase
              .from('users')
              .select('*')
              .eq('android_id', deviceId)
              .eq('auth_method', 'passkey')
              .eq('is_fully_registered', false)
              .maybeSingle();
          brokenUser = response;
        } else if (Platform.isIOS) {
          _debugLog('findExistingPasskeyForDevice() - Checking for broken iOS registrations');
          final response = await _supabase
              .from('users')
              .select('*')
              .eq('apple_vendor_id', deviceId)
              .eq('auth_method', 'passkey')
              .eq('is_fully_registered', false)
              .maybeSingle();
          brokenUser = response;
        }
        
        if (brokenUser != null) {
          _debugLog('findExistingPasskeyForDevice() - ⚠️ FOUND BROKEN REGISTRATION: ${brokenUser['uuid']} (is_fully_registered=false, created_at=${brokenUser['created_at']})');
        } else {
          _debugLog('findExistingPasskeyForDevice() - No broken registrations found');
        }
      }

      return userData;
    } catch (e) {
      _debugLog('findExistingPasskeyForDevice() - ❌ ERROR: $e');
      return null;
    }
  }

  Future<bool> register() async {
    _debugLog('register() - 🚀 STARTING PASSKEY REGISTRATION');
    try {
      // First, check if there's already a passkey for this device
      _debugLog('register() - Step 1: Checking for existing passkey');
      final existingPasskey = await findExistingPasskeyForDevice();
      
      if (existingPasskey != null) {
        // Authenticate with existing passkey instead of creating a new one
        _debugLog('register() - Found existing passkey for this device, attempting authentication first...');
        try {
          final authResult = await _authenticateWithExistingPasskey(existingPasskey);
          if (authResult) {
            _debugLog('register() - ✅ Authentication successful with existing passkey');
            return true;
          } else {
            _debugLog('register() - ❌ Authentication failed with existing passkey');
          }
        } catch (e) {
          _debugLog('register() - ❌ Authentication failed with error: $e');
          
          // Check if this is the "No credentials exist" error - indicates database/device mismatch
          if (e.toString().contains('No credentials exist for rpId')) {
            _debugLog('register() - 🔧 DETECTED GHOST USER: Database has user but device has no credential');
            _debugLog('register() - Attempting automatic cleanup of stale database record...');
            
            try {
              // Force delete the stale database record
              final deviceId = await _getDeviceId();
              if (deviceId != null) {
                _debugLog('register() - Force deleting stale record for device: $deviceId');
                
                if (Platform.isAndroid) {
                  final deleteResult = await _supabase
                      .from('users')
                      .delete()
                      .eq('android_id', deviceId)
                      .eq('auth_method', 'passkey')
                      .select();
                  _debugLog('register() - Deleted ${deleteResult?.length ?? 0} stale Android users');
                } else if (Platform.isIOS) {
                  final deleteResult = await _supabase
                      .from('users')
                      .delete()
                      .eq('apple_vendor_id', deviceId)
                      .eq('auth_method', 'passkey')
                      .select();
                  _debugLog('register() - Deleted ${deleteResult?.length ?? 0} stale iOS users');
                }
                
                _debugLog('register() - ✅ Stale database record cleaned up, proceeding with fresh registration...');
                // Continue with registration flow below
              }
            } catch (cleanupError) {
              _debugLog('register() - ❌ Failed to cleanup stale record: $cleanupError');
              throw Exception('Database has stale user record that could not be cleaned up. Please try the Reset option.');
            }
          } else {
            // Different error - re-throw it
            rethrow;
          }
        }
      }

      _debugLog('register() - Step 2: No existing passkey found, creating new one');
      
      final deviceId = await _getDeviceId();
      if (deviceId == null) {
        _debugLog('register() - ❌ ERROR: Unable to get device ID');
        throw Exception('Unable to get device ID');
      }

      // Generate UUID for the user
      final userUuid = _uuid.v4();
      final userName = 'User${userUuid.substring(0, 8)}';
      _debugLog('register() - Step 3: Generated user UUID: $userUuid, userName: $userName');

      // Create proper challenge and client data
      _debugLog('register() - Step 4: Creating WebAuthn challenge and client data');
      final random = Random.secure();
      final challengeBytes = List<int>.generate(32, (i) => random.nextInt(256));
      final clientData = {
        'type': 'webauthn.create',
        'challenge': base64Encode(challengeBytes),
        'origin': 'https://readtheroom.app',
        'crossOrigin': false,
      };
      final clientDataJson = jsonEncode(clientData);
      final clientDataHash = sha256.convert(utf8.encode(clientDataJson)).bytes;
      _debugLog('register() - Step 4: Challenge created (${challengeBytes.length} bytes), clientDataHash created (${clientDataHash.length} bytes)');

      // Create WebAuthn registration options using the webauthn package format
      final makeCredentialOptions = MakeCredentialOptions.fromJson({
        "authenticatorExtensions": "",
        "clientDataHash": base64Encode(clientDataHash), // Now properly 32 bytes
        "credTypesAndPubKeyAlgs": [
          ["public-key", -7], // ES256
          ["public-key", -257], // RS256
        ],
        "excludeCredentials": [],
        "requireResidentKey": true,
        "requireUserPresence": false,
        "requireUserVerification": true,
        "rp": {
          "name": "ReadTheRoom",
          "id": "readtheroom.app"
        },
        "user": {
          "name": userName,
          "displayName": userName,
          "id": base64Encode(utf8.encode(userUuid))
        }
      });

      _debugLog('register() - Step 5: Starting WebAuthn credential creation...');

      // Create credential using platform authenticator
      final attestation = await _authenticator.makeCredential(makeCredentialOptions);

      if (attestation == null) {
        _debugLog('register() - ❌ ERROR: Failed to create credential - user may have cancelled');
        throw Exception('Failed to create credential - user may have cancelled');
      }

      _debugLog('register() - Step 6: ✅ Credential created successfully');

      // Extract credential information
      final credentialId = attestation.getCredentialIdBase64();
      
      // Get the CBOR attestation data and extract public key from it
      final attestationBytes = attestation.asCBOR();
      
      // For storage, we'll use the credential ID as a reference
      // The actual public key verification will be handled by the webauthn package
      final publicKeyBase64 = base64Encode(attestationBytes);

      _debugLog('register() - Step 7: Extracted credential data:');
      _debugLog('register() - Attestation data length: ${attestationBytes.length} bytes');
      _debugLog('register() - Credential ID: ${credentialId.substring(0, 20)}...');
      _debugLog('register() - Public key length: ${publicKeyBase64.length} chars');

      // Skip immediate verification test to avoid double biometric prompt
      // Instead, we'll verify on first authentication attempt
      _debugLog('register() - Step 8: ✅ Credential created successfully - skipping immediate verification to avoid double prompt');

      // NOW create database records since we know the passkey works
      _debugLog('register() - Step 9: 💾 Creating database records (passkey verified)...');
      try {
        _debugLog('register() - Step 9a: Creating Supabase auth user...');
        
        // Create user in Supabase auth with anonymous signup.
        //
        // KNOWN LIMITATION — Deterministic password derivation:
        // Supabase Auth requires an email+password pair, but our actual auth
        // mechanism is WebAuthn passkeys. We synthesize credentials from the
        // user's custom UUID. The password has no server-side salt, so anyone
        // with access to a user's UUID and this source code could derive it.
        //
        // Risk assessment (accepted):
        //  - users.uuid is protected by Supabase RLS — no policy grants SELECT
        //    on the uuid column to other authenticated or anonymous users.
        //  - auth.users.id (the PK exposed in foreign keys like author_id) is a
        //    separate value from users.uuid; knowing one does not yield the other.
        //  - Supabase Auth applies rate-limiting to signInWithPassword, making
        //    brute-force enumeration of UUIDs impractical.
        //  - The account payload contains no sensitive personal data (no payment
        //    info, no private messages) — the blast radius of a compromised
        //    account is limited to question and comment activity, no user answers can be de-anonymized due to the database architecture.
        //
        // Future hardening: introduce a per-user salt stored server-side and
        // migrate existing passwords via an Edge Function batch update.
        final email = '$userUuid@passkey.local';
        final password = 'passkey_${sha256.convert(utf8.encode(userUuid)).toString()}';
        
        final authResponse = await _supabase.auth.signUp(
          email: email,
          password: password,
        );

        if (authResponse.user == null) {
          _debugLog('register() - ❌ ERROR: Failed to create auth user - no user returned');
          throw Exception('Failed to create auth user');
        }

        _debugLog('register() - Step 9b: ✅ Auth user created with ID: ${authResponse.user!.id}');

        // Store user data with attestation data in users table
        // IMPORTANT: Set is_fully_registered = TRUE since makeCredential() succeeded
        // We trust that platform authenticator properly bound the credential to device
        _debugLog('register() - Step 9c: Inserting user record into users table...');
        final userRecord = {
          'id': authResponse.user!.id,
          'uuid': userUuid,
          'public_key': publicKeyBase64, // Store the full attestation for verification
          'credential_id': credentialId,
          'auth_method': 'passkey',
          'android_id': Platform.isAndroid ? deviceId : null,
          'apple_vendor_id': Platform.isIOS ? deviceId : null,
          'device_info': {
            'platform': Platform.isAndroid ? 'android' : 'ios',
            'device_id': deviceId,
          },
          'last_passkey_use': DateTime.now().toIso8601String(),
          'is_fully_registered': true, // Trust that makeCredential() success means passkey works
        };
        
        _debugLog('register() - Step 9c: User record to insert: ${jsonEncode(userRecord)}');
        
        await _supabase.from('users').insert(userRecord);
        
        _debugLog('register() - Step 9d: ✅ User record inserted successfully');

        // Store credentials locally
        _debugLog('register() - Step 10: Storing credentials locally...');
        await storeCredentials(userUuid, credentialId);
        
        _debugLog('register() - 🎉 SUCCESS: Passkey registered successfully for user: $userUuid');
        return true;
        
      } catch (dbError) {
        _debugLog('register() - ❌ ERROR: Database creation failed after successful passkey creation: $dbError');
        
        // If we get a unique constraint violation, it means the user already exists
        // Let's try to find them and authenticate instead
        if (dbError.toString().contains('duplicate key value violates unique constraint')) {
          _debugLog('register() - 🔄 User already exists for this device, attempting to authenticate...');
          _debugLog('register() - Constraint violation details: $dbError');
          
          // The device already has a passkey, so let's find the existing user
          // and sign them in instead of creating a new auth user
          
          Map<String, dynamic>? existingUser;
          try {
            _debugLog('register() - Searching for existing user with device ID: $deviceId');
            if (Platform.isAndroid) {
              final response = await _supabase
                  .from('users')
                  .select('*')
                  .eq('android_id', deviceId)
                  .maybeSingle();
              existingUser = response;
            } else if (Platform.isIOS) {
              final response = await _supabase
                  .from('users')
                  .select('*')
                  .eq('apple_vendor_id', deviceId)
                  .maybeSingle();
              existingUser = response;
            }
            
            _debugLog('register() - Query result: ${existingUser != null ? 'FOUND' : 'NOT FOUND'}');
            if (existingUser != null) {
              _debugLog('register() - Existing user details: UUID=${existingUser['uuid']}, is_fully_registered=${existingUser['is_fully_registered']}, auth_method=${existingUser['auth_method']}');
            }
            
            if (existingUser != null) {
              _debugLog('register() - Found existing user in database: ${existingUser['uuid']}');
              
              // Check if this user is fully registered
              if (existingUser['is_fully_registered'] != true) {
                _debugLog('register() - 🔧 Existing user is not fully registered, updating...');
                // Update the existing user to mark them as fully registered
                await _supabase
                    .from('users')
                    .update({
                      'is_fully_registered': true,
                      'last_passkey_use': DateTime.now().toIso8601String(),
                    })
                    .eq('uuid', existingUser['uuid']);
                _debugLog('register() - ✅ Updated existing user to fully registered');
              }
              
              // Sign in to the existing auth user instead of creating new one.
              // See register() Step 9a for risk assessment on deterministic derivation.
              final userUuid = existingUser['uuid'];
              final email = '$userUuid@passkey.local';
              final password = 'passkey_${sha256.convert(utf8.encode(userUuid)).toString()}';
              
              _debugLog('register() - 🔑 Attempting to sign in with existing auth user...');
              final authResponse = await _supabase.auth.signInWithPassword(
                email: email,
                password: password,
              );
              
              if (authResponse.user != null) {
                // Store credentials locally
                await storeCredentials(userUuid, existingUser['credential_id']);
                
                _debugLog('register() - 🎉 SUCCESS: Successfully signed in existing user: $userUuid');
                return true;
              } else {
                _debugLog('register() - ❌ Auth sign in failed - no user returned');
              }
            } else {
              _debugLog('register() - No existing user found in database');
            }
          } catch (findError) {
            _debugLog('register() - Error finding existing user: $findError');
          }
          
          throw Exception('User exists but could not be authenticated - please use the "Reset Passkey" option to resolve this issue');
        }
        // Re-throw other database errors
        throw dbError;
      }
    } catch (e) {
      _debugLog('register() - ❌ FINAL ERROR: $e');
      return false;
    }
  }

  Future<bool> authenticate() async {
    _debugLog('authenticate() - 🔐 STARTING AUTHENTICATION');
    try {
      // Check for existing passkey for this device
      _debugLog('authenticate() - Step 1: Looking for existing passkey for device');
      final existingPasskey = await findExistingPasskeyForDevice();
      
      if (existingPasskey != null) {
        _debugLog('authenticate() - Step 2: Found existing passkey, proceeding with authentication');
        try {
          return await _authenticateWithExistingPasskey(existingPasskey);
        } catch (e) {
          if (e.toString().contains('No credentials exist for rpId')) {
            _debugLog('authenticate() - ❌ ERROR: GHOST USER DETECTED - Database has user but device has no credential');
            _debugLog('authenticate() - This indicates the passkey was deleted from device but database record remains');
            _debugLog('authenticate() - User UUID: ${existingPasskey['uuid']}, is_fully_registered: ${existingPasskey['is_fully_registered']}');
            // Don't auto-register - let the authentication screen handle this with user choice
            throw Exception('No credentials exist for this device. Database has stale record. Please use the Reset option to clean up.');
          }
          rethrow;
        }
      } else {
        _debugLog('authenticate() - ❌ ERROR: No passkey found for this device');
        throw Exception('No passkey found for this device');
      }
    } catch (e) {
      _debugLog('authenticate() - ❌ FINAL ERROR: $e');
      return false;
    }
  }

  Future<bool> _authenticateWithExistingPasskey(Map<String, dynamic> userData) async {
    final userUuid = userData['uuid'];
    final credentialId = userData['credential_id'];
    final storedPublicKey = userData['public_key'];

    _debugLog('_authenticateWithExistingPasskey() - 🔑 STARTING AUTHENTICATION WITH EXISTING PASSKEY');
    _debugLog('_authenticateWithExistingPasskey() - User UUID: $userUuid');
    _debugLog('_authenticateWithExistingPasskey() - Credential ID: ${credentialId.substring(0, 20)}...');
    _debugLog('_authenticateWithExistingPasskey() - User data: auth_method=${userData['auth_method']}, is_fully_registered=${userData['is_fully_registered']}');

    try {
      // Create proper challenge and client data
      _debugLog('_authenticateWithExistingPasskey() - Step 1: Creating WebAuthn challenge');
      final random = Random.secure();
      final challengeBytes = List<int>.generate(32, (i) => random.nextInt(256));
      final clientData = {
        'type': 'webauthn.get',
        'challenge': base64Encode(challengeBytes),
        'origin': 'https://readtheroom.app',
        'crossOrigin': false,
      };
      final clientDataJson = jsonEncode(clientData);
      final clientDataHash = sha256.convert(utf8.encode(clientDataJson)).bytes;

      // Create WebAuthn authentication options using the webauthn package format
      final getAssertionOptions = GetAssertionOptions.fromJson({
        "allowCredentialDescriptorList": [{
          "id": credentialId,
          "type": "public-key"
        }],
        "authenticatorExtensions": "",
        "clientDataHash": base64Encode(clientDataHash), // Now properly 32 bytes
        "requireUserPresence": false,
        "requireUserVerification": true,
        "rpId": "readtheroom.app"
      });

      _debugLog('_authenticateWithExistingPasskey() - Step 2: Starting WebAuthn authentication...');

      // Get assertion using platform authenticator
      final assertion = await _authenticator.getAssertion(getAssertionOptions);

      if (assertion == null) {
        _debugLog('_authenticateWithExistingPasskey() - ❌ ERROR: Authentication cancelled or failed');
        throw Exception('Authentication cancelled or failed');
      }

      _debugLog('_authenticateWithExistingPasskey() - Step 3: ✅ Authentication assertion received');

      // The webauthn package handles signature verification internally
      _debugLog('_authenticateWithExistingPasskey() - Step 4: ✅ Signature verification passed');

      // Store credentials locally
      _debugLog('_authenticateWithExistingPasskey() - Step 5: Storing credentials locally...');
      await storeCredentials(userUuid, credentialId);

      // Sign in to Supabase auth.
      // See register() Step 9a for risk assessment on deterministic derivation.
      final email = '$userUuid@passkey.local';
      final password = 'passkey_${sha256.convert(utf8.encode(userUuid)).toString()}';

      _debugLog('_authenticateWithExistingPasskey() - Step 6: Attempting Supabase auth sign in...');
      final authResponse = await _supabase.auth.signInWithPassword(
        email: email,
        password: password,
      );

      if (authResponse.user != null) {
        _debugLog('_authenticateWithExistingPasskey() - Step 7: ✅ Supabase auth successful, user ID: ${authResponse.user!.id}');
        
        // Update last_used timestamp
        _debugLog('_authenticateWithExistingPasskey() - Step 8: Updating last_passkey_use timestamp...');
        await _supabase
            .from('users')
            .update({'last_passkey_use': DateTime.now().toIso8601String()})
            .eq('uuid', userUuid);
            
        // Check if this Android user needs migration from legacy Android ID to UUID v4
        if (Platform.isAndroid) {
          _debugLog('_authenticateWithExistingPasskey() - Step 9: Checking if Android device needs ID migration...');
          final isLegacy = await DeviceIdProvider.isLegacyAndroidId();
          if (isLegacy) {
            _debugLog('_authenticateWithExistingPasskey() - Device has legacy Android ID, attempting automatic migration...');
            try {
              final migrationSuccess = await _attemptAutomaticAndroidIdMigration(userUuid);
              if (migrationSuccess) {
                _debugLog('_authenticateWithExistingPasskey() - ✅ Android ID migration successful');
              } else {
                _debugLog('_authenticateWithExistingPasskey() - ⚠️ Android ID migration failed, but authentication continues');
              }
            } catch (e) {
              _debugLog('_authenticateWithExistingPasskey() - ⚠️ Android ID migration error: $e, but authentication continues');
            }
          }
        }

        _debugLog('_authenticateWithExistingPasskey() - 🎉 SUCCESS: Authentication completed for user: $userUuid');
        return true;
      } else {
        _debugLog('_authenticateWithExistingPasskey() - ❌ ERROR: Supabase auth failed - no user returned');
      }

      return false;
    } catch (e) {
      _debugLog('_authenticateWithExistingPasskey() - ❌ ERROR: $e');
      return false;
    }
  }

  Future<bool> isPasskeySetup() async {
    _debugLog('isPasskeySetup() - Checking if passkey is set up for device');
    // Check if there's an existing passkey for this device
    final existingPasskey = await findExistingPasskeyForDevice();
    final isSetup = existingPasskey != null;
    _debugLog('isPasskeySetup() - Result: $isSetup');
    return isSetup;
  }

  Future<bool> signIn() async {
    _debugLog('signIn() - Starting sign in process');
    // This is specifically for signing in with an existing passkey
    return await authenticate();
  }

  Future<void> logout() async {
    _debugLog('logout() - 🚪 STARTING LOGOUT PROCESS');
    
    // Check current user before logout for debugging
    final currentUser = await getCurrentUser();
    _debugLog('logout() - Current user before logout: ${currentUser?['uuid']}');
    _debugLog('logout() - Current user is_fully_registered: ${currentUser?['is_fully_registered']}');
    _debugLog('logout() - Current user auth_method: ${currentUser?['auth_method']}');
    _debugLog('logout() - Current user last_passkey_use: ${currentUser?['last_passkey_use']}');
    
    // Clear local stored credentials first
    _debugLog('logout() - Step 1: Clearing local credentials...');
    await clearStoredCredentials();
    _debugLog('logout() - Step 1: ✅ Local credentials cleared');
    
    // Only clear the local session - DO NOT trigger any server-side deletions
    _debugLog('logout() - Step 2: Signing out from Supabase auth (local scope only)...');
    await _supabase.auth.signOut(scope: SignOutScope.local);
    _debugLog('logout() - Step 2: ✅ Supabase auth signed out with local scope only');
    
    // DO NOT call cleanup here - logout should never trigger user deletion
    // The user should be able to log back in with their passkey after logout
    
    _debugLog('logout() - 🎉 SUCCESS: User logged out successfully (server records preserved)');
  }

  Future<void> clearStoredCredentials() async {
    _debugLog('clearStoredCredentials() - Clearing SharedPreferences...');
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_userIdKey);
    await prefs.remove(_credentialIdKey);
    _debugLog('clearStoredCredentials() - ✅ SharedPreferences cleared');
  }

  Future<Map<String, dynamic>?> getCurrentUser() async {
    _debugLog('getCurrentUser() - Getting current user data');
    try {
      final userUuid = await getStoredUserId();
      if (userUuid == null) {
        _debugLog('getCurrentUser() - No stored user ID found');
        return null;
      }

      _debugLog('getCurrentUser() - Querying database for user: $userUuid');
      final userData = await _supabase
          .from('users')
          .select('*')
          .eq('uuid', userUuid)
          .single();

      _debugLog('getCurrentUser() - Found user data: auth_method=${userData['auth_method']}, is_fully_registered=${userData['is_fully_registered']}');
      return userData;
    } catch (e) {
      _debugLog('getCurrentUser() - ❌ ERROR: $e');
      return null;
    }
  }

  /// Triggers cleanup of broken user registrations
  /// WARNING: This function can delete users! Only call manually, never automatically on auth failure
  /// Use this ONLY for scheduled cleanup or explicit user-requested reset
  Future<void> cleanupBrokenUsers({bool forceCleanup = false}) async {
    _debugLog('cleanupBrokenUsers() - 🧹 CLEANUP REQUESTED (forceCleanup: $forceCleanup)');
    try {
      if (!forceCleanup) {
        _debugLog('cleanupBrokenUsers() - ⚠️ WARNING: cleanupBrokenUsers called but forceCleanup not set to true');
        _debugLog('cleanupBrokenUsers() - Skipping cleanup to prevent accidental user deletion');
        return;
      }
      
      _debugLog('cleanupBrokenUsers() - 🧹 Triggering FORCED cleanup of broken user registrations...');
      _debugLog('cleanupBrokenUsers() - ⚠️ This will delete incomplete registrations older than 10 minutes');
      
      // Call the database function to clean up broken users
      // The DB function should have these safety conditions:
      // - is_fully_registered = FALSE
      // - last_passkey_use IS NULL (never successfully used)
      // - created_at < now() - interval '10 minutes' (old enough to be truly broken)
      final result = await _supabase.rpc('cleanup_broken_users');
      
      if (result != null && result.isNotEmpty) {
        final cleanupResult = result.first;
        final usersDeleted = cleanupResult['cleaned_users_count'] ?? 0;
        final authUsersDeleted = cleanupResult['cleaned_auth_users_count'] ?? 0;
        
        _debugLog('cleanupBrokenUsers() - ✅ Cleanup completed: $usersDeleted users deleted, $authUsersDeleted auth users deleted');
      } else {
        _debugLog('cleanupBrokenUsers() - ✅ Cleanup completed with no results returned');
      }
    } catch (e) {
      _debugLog('cleanupBrokenUsers() - ❌ ERROR: $e');
      // Don't throw - cleanup is best effort
    }
  }

  /// User-facing function to reset their passkey when something goes wrong
  /// This is safer because it only affects the current device's user
  Future<bool> resetPasskeyForCurrentDevice() async {
    _debugLog('resetPasskeyForCurrentDevice() - 🔄 USER REQUESTED PASSKEY RESET');
    try {
      final deviceId = await _getDeviceId();
      if (deviceId == null) {
        _debugLog('resetPasskeyForCurrentDevice() - ❌ Cannot reset - no device ID available');
        return false;
      }

      // Find any users for this device
      _debugLog('resetPasskeyForCurrentDevice() - Looking for users to delete for device: $deviceId');
      Map<String, dynamic>? existingUser;
      if (Platform.isAndroid) {
        final response = await _supabase
            .from('users')
            .select('*')
            .eq('android_id', deviceId)
            .eq('auth_method', 'passkey')
            .maybeSingle();
        existingUser = response;
      } else if (Platform.isIOS) {
        final response = await _supabase
            .from('users')
            .select('*')
            .eq('apple_vendor_id', deviceId)
            .eq('auth_method', 'passkey')
            .maybeSingle();
        existingUser = response;
      }

      if (existingUser != null) {
        _debugLog('resetPasskeyForCurrentDevice() - 🗑️ Found existing user for device, deleting: ${existingUser['uuid']} (is_fully_registered: ${existingUser['is_fully_registered']})');
        
        // Delete from users table first
        _debugLog('resetPasskeyForCurrentDevice() - Attempting to delete from users table...');
        final deleteResult = await _supabase
            .from('users')
            .delete()
            .eq('uuid', existingUser['uuid'])
            .select();
        
        _debugLog('resetPasskeyForCurrentDevice() - Users table delete result: ${deleteResult?.length ?? 0} rows deleted');
        
        // Then delete from auth.users if we have the auth ID
        if (existingUser['id'] != null) {
          try {
            _debugLog('resetPasskeyForCurrentDevice() - Attempting to delete auth user: ${existingUser['id']}');
            await _supabase.rpc('reset_passkey_user', params: {
              'p_user_id': existingUser['id']
            });
            _debugLog('resetPasskeyForCurrentDevice() - ✅ Deleted auth user: ${existingUser['id']}');
          } catch (e) {
            _debugLog('resetPasskeyForCurrentDevice() - ⚠️ Warning: Could not delete auth user: $e');
            // Continue anyway - the important part is clearing the users table
          }
        }
        
        // Verify the deletion worked by querying again
        _debugLog('resetPasskeyForCurrentDevice() - Verifying deletion...');
        Map<String, dynamic>? verifyUser;
        if (Platform.isAndroid) {
          final response = await _supabase
              .from('users')
              .select('*')
              .eq('android_id', deviceId)
              .eq('auth_method', 'passkey')
              .maybeSingle();
          verifyUser = response;
        } else if (Platform.isIOS) {
          final response = await _supabase
              .from('users')
              .select('*')
              .eq('apple_vendor_id', deviceId)
              .eq('auth_method', 'passkey')
              .maybeSingle();
          verifyUser = response;
        }
        
        if (verifyUser != null) {
          _debugLog('resetPasskeyForCurrentDevice() - ❌ ERROR: User still exists after deletion! UUID: ${verifyUser['uuid']}, is_fully_registered: ${verifyUser['is_fully_registered']}');
          throw Exception('Failed to delete user record - user still exists in database');
        } else {
          _debugLog('resetPasskeyForCurrentDevice() - ✅ Verified: User successfully deleted from database');
        }
        
        _debugLog('resetPasskeyForCurrentDevice() - ✅ Deleted existing user for device');
      } else {
        _debugLog('resetPasskeyForCurrentDevice() - No existing user found for device');
      }

      // Clear local credentials
      _debugLog('resetPasskeyForCurrentDevice() - Clearing local credentials...');
      await clearStoredCredentials();
      
      _debugLog('resetPasskeyForCurrentDevice() - 🎉 SUCCESS: Passkey reset complete - ready for new registration');
      return true;
      
    } catch (e) {
      _debugLog('resetPasskeyForCurrentDevice() - ❌ ERROR: $e');
      return false;
    }
  }
  
  /// Migrate device ID from legacy Android ID to UUID v4
  /// This updates the database record to use the new device ID
  /// Returns true on success, false on failure
  Future<bool> migrateDeviceId() async {
    _debugLog('migrateDeviceId() - Starting device ID migration');
    
    try {
      // Check if migration is applicable
      if (!Platform.isAndroid) {
        _debugLog('migrateDeviceId() - Migration only applicable to Android devices');
        return false;
      }
      
      // Check if user is authenticated
      final currentUser = _supabase.auth.currentUser;
      if (currentUser == null) {
        _debugLog('migrateDeviceId() - No authenticated user, cannot migrate');
        return false;
      }
      
      // Check if device has legacy Android ID
      final isLegacy = await DeviceIdProvider.isLegacyAndroidId();
      if (!isLegacy) {
        _debugLog('migrateDeviceId() - Device ID is already migrated');
        return false;
      }
      
      // Get current device ID before migration
      final oldDeviceId = await DeviceIdProvider.getOrCreateDeviceId();
      _debugLog('migrateDeviceId() - Current device ID: $oldDeviceId');
      
      // Check if there's a passkey for this device
      final existingUser = await findExistingPasskeyForDevice();
      if (existingUser == null) {
        _debugLog('migrateDeviceId() - No passkey found for this device');
        return false;
      }
      
      _debugLog('migrateDeviceId() - Found existing user: ${existingUser['uuid']}');
      
      // Perform the migration
      final migrationResult = await DeviceIdProvider.migrateToUuidV4();
      if (migrationResult == null) {
        _debugLog('migrateDeviceId() - Migration failed in DeviceIdProvider');
        return false;
      }
      
      final oldId = migrationResult['old_id'];
      final newId = migrationResult['new_id'];
      
      _debugLog('migrateDeviceId() - Updating database: $oldId -> $newId');
      
      // Update the database record
      // First, try to find the user record by android_id since authentication might be mismatched
      _debugLog('migrateDeviceId() - Looking for user record with android_id: $oldId');
      final userLookup = await _supabase
          .from('users')
          .select('id, uuid, android_id')
          .eq('android_id', oldId!)
          .maybeSingle();
      
      if (userLookup == null) {
        _debugLog('migrateDeviceId() - ❌ No user found with android_id: $oldId');
        // Rollback the local migration
        await DeviceIdProvider.clearDeviceId();
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('device_id', oldId);
        await prefs.setString('device_id_type', 'legacy');
        return false;
      }
      
      _debugLog('migrateDeviceId() - Found user record: ${userLookup['id']} with UUID: ${userLookup['uuid']}');
      
      // Update the database record using the found user ID
      final updateResult = await _supabase
          .from('users')
          .update({'android_id': newId})
          .eq('id', userLookup['id'])
          .select();
      
      if (updateResult == null || updateResult.isEmpty) {
        _debugLog('migrateDeviceId() - Database update failed');
        // Rollback the local migration
        await DeviceIdProvider.clearDeviceId();
        // Restore the old ID
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('device_id', oldId);
        await prefs.setString('device_id_type', 'legacy');
        return false;
      }
      
      _debugLog('migrateDeviceId() - Database updated successfully');
      
      // Verify the migration by checking if we can still find the passkey
      final verifyUser = await findExistingPasskeyForDevice();
      if (verifyUser == null) {
        _debugLog('migrateDeviceId() - ❌ Verification failed - cannot find user with new ID');
        // This shouldn't happen, but if it does, we're in trouble
        return false;
      }
      
      // Update local authentication state if needed
      // If the current authenticated user doesn't match the migrated user, this could cause issues
      if (currentUser.id != userLookup['id']) {
        _debugLog('migrateDeviceId() - ⚠️ Authentication mismatch detected: currentUser.id=${currentUser.id}, actual user=${userLookup['id']}');
        _debugLog('migrateDeviceId() - This might cause authentication issues after migration');
      }
      
      _debugLog('migrateDeviceId() - ✅ Migration successful and verified');
      return true;
      
    } catch (e) {
      _debugLog('migrateDeviceId() - ❌ ERROR: $e');
      return false;
    }
  }
  
  /// Attempt automatic Android device ID migration during authentication
  /// This is called after successful authentication to migrate legacy Android IDs to UUID v4
  Future<bool> _attemptAutomaticAndroidIdMigration(String userUuid) async {
    try {
      _debugLog('_attemptAutomaticAndroidIdMigration() - Starting automatic migration for user: $userUuid');
      
      // Double-check this is Android and has legacy ID
      if (!Platform.isAndroid) {
        _debugLog('_attemptAutomaticAndroidIdMigration() - Not Android platform, skipping');
        return false;
      }
      
      final isLegacy = await DeviceIdProvider.isLegacyAndroidId();
      if (!isLegacy) {
        _debugLog('_attemptAutomaticAndroidIdMigration() - Device ID already migrated');
        return false;
      }
      
      // Get current device ID before migration
      final oldDeviceId = await DeviceIdProvider.getOrCreateDeviceId();
      _debugLog('_attemptAutomaticAndroidIdMigration() - Current device ID: $oldDeviceId');
      
      // Perform the migration
      final migrationResult = await DeviceIdProvider.migrateToUuidV4();
      if (migrationResult == null) {
        _debugLog('_attemptAutomaticAndroidIdMigration() - Migration failed in DeviceIdProvider');
        return false;
      }
      
      final oldId = migrationResult['old_id']!;
      final newId = migrationResult['new_id']!;
      
      _debugLog('_attemptAutomaticAndroidIdMigration() - Updating database: $oldId -> $newId');
      
      // Update the database record for this specific user
      final updateResult = await _supabase
          .from('users')
          .update({'android_id': newId})
          .eq('uuid', userUuid)
          .eq('android_id', oldId)
          .select();
      
      if (updateResult == null || updateResult.isEmpty) {
        _debugLog('_attemptAutomaticAndroidIdMigration() - Database update failed, rolling back');
        // Rollback the local migration
        await DeviceIdProvider.clearDeviceId();
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('device_id', oldId);
        await prefs.setString('device_id_type', 'legacy');
        await prefs.setString('device_id_generated_at', DateTime.now().toIso8601String());
        return false;
      }
      
      _debugLog('_attemptAutomaticAndroidIdMigration() - Database updated successfully');
      
      // Verify the migration
      final verifyUser = await findExistingPasskeyForDevice();
      if (verifyUser == null) {
        _debugLog('_attemptAutomaticAndroidIdMigration() - ❌ Verification failed - cannot find user with new ID');
        return false;
      }
      
      _debugLog('_attemptAutomaticAndroidIdMigration() - ✅ Migration successful and verified');
      return true;

    } catch (e) {
      _debugLog('_attemptAutomaticAndroidIdMigration() - ❌ ERROR: $e');
      return false;
    }
  }

  /// Recover a user's account after app reinstall by creating a new passkey
  /// and updating the existing user record. This preserves all user data
  /// (questions, comments, streaks, etc.) instead of creating a new account.
  ///
  /// This is used when:
  /// - User reinstalled the app (passkey private key was deleted)
  /// - Database has the user record but device has no credential
  /// - User chooses "Recover Account" instead of "Reset"
  ///
  /// Returns true if recovery was successful, false otherwise.
  Future<bool> recoverPasskeyForDevice() async {
    _debugLog('recoverPasskeyForDevice() - 🔄 STARTING PASSKEY RECOVERY');
    try {
      final deviceId = await _getDeviceId();
      if (deviceId == null) {
        _debugLog('recoverPasskeyForDevice() - ❌ Cannot recover - no device ID available');
        throw Exception('Unable to get device ID');
      }

      // First, verify there's an existing user for this device
      _debugLog('recoverPasskeyForDevice() - Step 1: Checking for existing user...');
      Map<String, dynamic>? existingUser;

      if (Platform.isAndroid) {
        final response = await _supabase
            .from('users')
            .select('*')
            .eq('android_id', deviceId)
            .eq('auth_method', 'passkey')
            .maybeSingle();
        existingUser = response;
      } else if (Platform.isIOS) {
        final response = await _supabase
            .from('users')
            .select('*')
            .eq('apple_vendor_id', deviceId)
            .eq('auth_method', 'passkey')
            .maybeSingle();
        existingUser = response;
      }

      if (existingUser == null) {
        _debugLog('recoverPasskeyForDevice() - ❌ No existing user found for this device - cannot recover');
        throw Exception('No account found for this device. Please register as a new user.');
      }

      _debugLog('recoverPasskeyForDevice() - Step 1: ✅ Found existing user: ${existingUser['uuid']}');
      _debugLog('recoverPasskeyForDevice() - User has is_fully_registered=${existingUser['is_fully_registered']}, last_passkey_use=${existingUser['last_passkey_use']}');

      // Step 2: Create a NEW passkey on the device
      _debugLog('recoverPasskeyForDevice() - Step 2: Creating new passkey on device...');

      final userUuid = existingUser['uuid'];
      final userName = 'User${userUuid.substring(0, 8)}';

      // Create proper challenge and client data
      final random = Random.secure();
      final challengeBytes = List<int>.generate(32, (i) => random.nextInt(256));
      final clientData = {
        'type': 'webauthn.create',
        'challenge': base64Encode(challengeBytes),
        'origin': 'https://readtheroom.app',
        'crossOrigin': false,
      };
      final clientDataJson = jsonEncode(clientData);
      final clientDataHash = sha256.convert(utf8.encode(clientDataJson)).bytes;

      // Create WebAuthn registration options
      final makeCredentialOptions = MakeCredentialOptions.fromJson({
        "authenticatorExtensions": "",
        "clientDataHash": base64Encode(clientDataHash),
        "credTypesAndPubKeyAlgs": [
          ["public-key", -7], // ES256
          ["public-key", -257], // RS256
        ],
        "excludeCredentials": [],
        "requireResidentKey": true,
        "requireUserPresence": false,
        "requireUserVerification": true,
        "rp": {
          "name": "ReadTheRoom",
          "id": "readtheroom.app"
        },
        "user": {
          "name": userName,
          "displayName": userName,
          "id": base64Encode(utf8.encode(userUuid))
        }
      });

      _debugLog('recoverPasskeyForDevice() - Step 2: Starting WebAuthn credential creation...');

      // Create new credential using platform authenticator (will prompt biometric)
      final attestation = await _authenticator.makeCredential(makeCredentialOptions);

      if (attestation == null) {
        _debugLog('recoverPasskeyForDevice() - ❌ Failed to create credential - user may have cancelled');
        throw Exception('Failed to create new passkey - user may have cancelled');
      }

      _debugLog('recoverPasskeyForDevice() - Step 2: ✅ New passkey created successfully');

      // Extract credential information
      final newCredentialId = attestation.getCredentialIdBase64();
      final attestationBytes = attestation.asCBOR();
      final newPublicKey = base64Encode(attestationBytes);

      _debugLog('recoverPasskeyForDevice() - Step 3: New credential ID: ${newCredentialId.substring(0, 20)}...');

      // Step 3: Call RPC to update the existing user record
      _debugLog('recoverPasskeyForDevice() - Step 4: Calling recover_passkey_for_device RPC...');

      final platform = Platform.isAndroid ? 'android' : 'ios';
      final rpcResult = await _supabase.rpc('recover_passkey_for_device', params: {
        'p_device_id': deviceId,
        'p_platform': platform,
        'p_new_credential_id': newCredentialId,
        'p_new_public_key': newPublicKey,
      });

      _debugLog('recoverPasskeyForDevice() - Step 4: RPC result: $rpcResult');

      if (rpcResult == null || rpcResult['success'] != true) {
        final error = rpcResult?['error'] ?? 'Unknown error';
        _debugLog('recoverPasskeyForDevice() - ❌ RPC failed: $error');
        throw Exception('Failed to update account credentials: $error');
      }

      _debugLog('recoverPasskeyForDevice() - Step 4: ✅ User record updated successfully');

      // Step 4: Sign in with the existing auth credentials.
      // See register() Step 9a for risk assessment on deterministic derivation.
      _debugLog('recoverPasskeyForDevice() - Step 5: Signing in with existing auth credentials...');

      final email = '$userUuid@passkey.local';
      final password = 'passkey_${sha256.convert(utf8.encode(userUuid)).toString()}';

      final authResponse = await _supabase.auth.signInWithPassword(
        email: email,
        password: password,
      );

      if (authResponse.user == null) {
        _debugLog('recoverPasskeyForDevice() - ❌ Auth sign in failed');
        throw Exception('Failed to sign in after recovery');
      }

      _debugLog('recoverPasskeyForDevice() - Step 5: ✅ Signed in successfully as user: ${authResponse.user!.id}');

      // Step 5: Store credentials locally
      _debugLog('recoverPasskeyForDevice() - Step 6: Storing credentials locally...');
      await storeCredentials(userUuid, newCredentialId);

      _debugLog('recoverPasskeyForDevice() - 🎉 SUCCESS: Account recovered! User: $userUuid');
      _debugLog('recoverPasskeyForDevice() - All user data (questions, comments, streaks) has been preserved.');

      return true;

    } catch (e) {
      _debugLog('recoverPasskeyForDevice() - ❌ FINAL ERROR: $e');
      rethrow; // Re-throw so caller can show appropriate error message
    }
  }
} 
