// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:supabase_flutter/supabase_flutter.dart';
import 'room_service.dart';
import 'activity_service.dart';
import 'local_response_storage_service.dart';
import '../models/room.dart';

class RoomSharingService {
  final SupabaseClient _supabase = Supabase.instance.client;
  final RoomService _roomService = RoomService();
  final ActivityService _activityService = ActivityService();
  final LocalResponseStorageService _localStorageService = LocalResponseStorageService();

  Future<void> handleResponseSubmission({
    required String questionId,
    required String responseId,
    String? questionText,
    String? responseText,
    String? questionType,
    String? selectedOption,
    double? ratingScore,
  }) async {
    try {
      final userId = _supabase.auth.currentUser?.id;
      if (userId == null) return;

      // Store response locally for potential manual sharing later
      // This is critical for the manual sharing functionality to work
      await _storeResponseLocally(
        questionId: questionId,
        responseId: responseId,
        questionText: questionText,
        responseText: responseText,
        questionType: questionType,
        selectedOption: selectedOption,
        ratingScore: ratingScore,
      );

      // Get user's rooms where they have auto-sharing enabled
      final userRooms = await _roomService.getUserRooms();
      final autoShareRooms = await _getAutoShareRooms(userRooms);

      // Auto-share to rooms with auto-sharing enabled (with NSFW filtering)
      for (final room in autoShareRooms) {
        // Check if NSFW content can be shared to this room
        final canShare = await _canShareToRoom(
          roomId: room.id,
          questionId: questionId,
          userId: userId,
        );
        
        if (canShare) {
          await _shareResponseToRoom(
            roomId: room.id,
            questionId: questionId,
            responseId: responseId,
            isAutoShare: true,
          );
        } else {
          print('🎪 NSFW content blocked from auto-sharing to room ${room.name}');
        }
      }

      // Create manual share activities for rooms with manual sharing (with NSFW filtering)
      final manualShareRooms = await _getManualShareRooms(userRooms);
      for (final room in manualShareRooms) {
        // Check if NSFW content can be shared to this room
        final canShare = await _canShareToRoom(
          roomId: room.id,
          questionId: questionId,
          userId: userId,
        );
        
        if (canShare) {
          await _createManualShareActivity(
            roomId: room.id,
            questionId: questionId,
            responseId: responseId,
          );
        } else {
          print('🎪 NSFW content blocked from manual share activity for room ${room.name}');
        }
      }
    } catch (e) {
      // Log error but don't throw - response submission should succeed even if sharing fails
      print('Error in room sharing service: $e');
    }
  }

  /// Store response locally for potential manual room sharing
  Future<void> _storeResponseLocally({
    required String questionId,
    required String responseId,
    String? questionText,
    String? responseText,
    String? questionType,
    String? selectedOption,
    double? ratingScore,
  }) async {
    try {
      // Get question details if not provided
      if (questionText == null || questionType == null) {
        final questionData = await _supabase
            .from('questions')
            .select('question_text, question_type')
            .eq('id', questionId)
            .single();
        
        questionText ??= questionData['question_text'] as String?;
        questionType ??= questionData['question_type'] as String?;
      }

      await _localStorageService.storeResponse(
        questionId: questionId,
        responseId: responseId,
        questionText: questionText ?? 'Unknown question',
        responseText: responseText ?? '',
        questionType: questionType ?? 'text',
        answeredAt: DateTime.now(),
        selectedOption: selectedOption,
        ratingScore: ratingScore,
      );

      print('🎪 Stored response locally for question $questionId');
    } catch (e) {
      print('🎪 Warning: Failed to store response locally: $e');
      // Don't throw - this is just for local convenience
    }
  }

  Future<List<Room>> _getAutoShareRooms(List<Room> userRooms) async {
    try {
      final userId = _supabase.auth.currentUser?.id;
      if (userId == null) return [];

      final response = await _supabase
          .from('room_members')
          .select('room_id')
          .eq('user_id', userId)
          .eq('sharing_preference', 'auto_share_all');

      final autoShareRoomIds = response.map<String>((row) => row['room_id'] as String).toSet();
      
      return userRooms.where((room) => autoShareRoomIds.contains(room.id)).toList();
    } catch (e) {
      print('Error getting auto-share rooms: $e');
      return [];
    }
  }

  Future<List<Room>> _getManualShareRooms(List<Room> userRooms) async {
    try {
      final userId = _supabase.auth.currentUser?.id;
      if (userId == null) return [];

      final response = await _supabase
          .from('room_members')
          .select('room_id')
          .eq('user_id', userId)
          .eq('sharing_preference', 'manual');

      final manualShareRoomIds = response.map<String>((row) => row['room_id'] as String).toSet();
      
      return userRooms.where((room) => manualShareRoomIds.contains(room.id)).toList();
    } catch (e) {
      print('Error getting manual-share rooms: $e');
      return [];
    }
  }

  Future<void> _shareResponseToRoom({
    required String roomId,
    required String questionId,
    required String responseId,
    required bool isAutoShare,
  }) async {
    try {
      await _supabase.from('room_shared_responses').insert({
        'room_id': roomId,
        'question_id': questionId,
        'response_id': responseId,
        'shared_at': DateTime.now().toIso8601String(),
        'is_auto_share': isAutoShare,
      });

      // Update room stats
      await _supabase.rpc('update_room_stats', params: {
        'target_room_id': roomId,
      });
    } catch (e) {
      print('Error sharing response to room $roomId: $e');
      // Don't throw - let other rooms still get shared
    }
  }

  Future<void> _createManualShareActivity({
    required String roomId,
    required String questionId,
    required String responseId,
  }) async {
    try {
      // Get question text for the activity
      final questionResponse = await _supabase
          .from('questions')
          .select('question_text')
          .eq('id', questionId)
          .single();

      final questionText = questionResponse['question_text'] as String;

      // Get room name for the activity
      final roomResponse = await _supabase
          .from('rooms')
          .select('name')
          .eq('id', roomId)
          .single();

      final roomName = roomResponse['name'] as String;

      // Create manual share activity
      await _activityService.createManualShareActivity(
        roomId: roomId,
        questionId: questionId,
        questionText: questionText,
      );
    } catch (e) {
      print('Error creating manual share activity: $e');
      // Don't throw - this is just for user convenience
    }
  }

  Future<void> shareResponseManually({
    required String roomId,
    required String questionId,
    required String responseId,
  }) async {
    try {
      final userId = _supabase.auth.currentUser?.id;
      if (userId == null) {
        throw Exception('User not authenticated');
      }

      // Check if NSFW content can be shared to this room
      final canShare = await _canShareToRoom(
        roomId: roomId,
        questionId: questionId,
        userId: userId,
      );
      
      if (!canShare) {
        throw Exception('Cannot share NSFW content to this room. Either the room has NSFW disabled or you need to enable NSFW in your settings.');
      }

      await _shareResponseToRoom(
        roomId: roomId,
        questionId: questionId,
        responseId: responseId,
        isAutoShare: false,
      );
    } catch (e) {
      throw Exception('Failed to share response: $e');
    }
  }

  Future<List<Room>> getUserRoomsForSharing() async {
    try {
      return await _roomService.getUserRooms();
    } catch (e) {
      print('Error getting user rooms for sharing: $e');
      return [];
    }
  }


  /// Share a locally stored response to a room manually
  /// This is called when user taps an activity feed item
  Future<void> shareLocalResponseToRoom({
    required String roomId,
    required String questionId,
  }) async {
    try {
      final userId = _supabase.auth.currentUser?.id;
      if (userId == null) {
        throw Exception('User not authenticated');
      }

      // Get the locally stored response
      final localResponse = await _localStorageService.getStoredResponse(questionId);
      if (localResponse == null) {
        throw Exception('No local response found for this question');
      }

      final responseId = localResponse['response_id'] as String;

      // Check if NSFW content can be shared to this room
      final canShare = await _canShareToRoom(
        roomId: roomId,
        questionId: questionId,
        userId: userId,
      );
      
      if (!canShare) {
        throw Exception('Cannot share NSFW content to this room. Either the room has NSFW disabled or you need to enable NSFW in your settings.');
      }

      // Share the response to the room
      await _shareResponseToRoom(
        roomId: roomId,
        questionId: questionId,
        responseId: responseId,
        isAutoShare: false,
      );

      print('Successfully shared local response to room $roomId');
    } catch (e) {
      throw Exception('Failed to share response: $e');
    }
  }

  /// Check if user has answered a question (using local storage)
  Future<bool> hasUserAnsweredQuestion(String questionId) async {
    return await _localStorageService.hasStoredResponse(questionId);
  }

  /// Get user's stored response data for a question
  Future<Map<String, dynamic>?> getUserResponseData(String questionId) async {
    return await _localStorageService.getStoredResponse(questionId);
  }

  /// Check if NSFW content can be shared to a specific room
  /// Returns true if content can be shared, false if NSFW restrictions apply
  Future<bool> _canShareToRoom({
    required String roomId,
    required String questionId,
    required String userId,
  }) async {
    try {
      print('🎪 Checking NSFW sharing permissions for room $roomId, question $questionId, user $userId');
      
      // First check if this is NSFW content using the backend function
      final result = await _supabase.rpc('can_share_nsfw_to_room', params: {
        'target_room_id': roomId,
        'target_question_id': questionId,
        'target_user_id': userId,
      });
      
      print('🎪 Backend NSFW sharing check result: $result');
      
      // If backend allows it, also check user's per-room NSFW sharing preference
      if (result == true) {
        final userNsfwPreference = await _roomService.getNsfwSharingPreference(roomId);
        print('🎪 User NSFW sharing preference for room $roomId: $userNsfwPreference');
        
        // If user has disabled NSFW sharing for this room, we need to check if the question is NSFW
        if (!userNsfwPreference) {
          // Get question details to check if it's NSFW
          final questionResponse = await _supabase
              .from('questions')
              .select('nsfw')
              .eq('id', questionId)
              .single();
          
          final isNsfw = questionResponse['nsfw'] as bool? ?? false;
          print('🎪 Question $questionId is NSFW: $isNsfw');
          
          // If question is NSFW and user disabled NSFW sharing for this room, don't share
          if (isNsfw) {
            print('🎪 NSFW content blocked due to user preference for room $roomId');
            return false;
          }
        }
      }
      
      return result == true;
    } catch (e) {
      print('🎪 ERROR: NSFW sharing check failed: $e');
      // On error, allow sharing to prevent blocking non-NSFW content
      return true;
    }
  }

  /// Check if room responses should be visible for a question
  /// Requires >5 responses from room members AND current user has answered
  Future<bool> canViewRoomResults({
    required String roomId,
    required String questionId,
    required bool userHasAnswered,
  }) async {
    try {
      // User must have answered the question to see room results
      if (!userHasAnswered) {
        return false;
      }

      // Count responses shared to this room for this question
      final roomResponseCount = await getRoomResponseCount(
        roomId: roomId,
        questionId: questionId,
      );

      // Require >5 responses to show results
      return roomResponseCount > 5;
    } catch (e) {
      print('Error checking room results visibility: $e');
      return false;
    }
  }

  /// Get count of responses shared to a room for a specific question
  Future<int> getRoomResponseCount({
    required String roomId,
    required String questionId,
  }) async {
    try {
      final result = await _supabase
          .from('room_shared_responses')
          .select('id')
          .eq('room_id', roomId)
          .eq('question_id', questionId);

      print('🎪 Room $roomId has ${result.length} shared responses for question $questionId');
      return result.length;
    } catch (e) {
      print('Error getting room response count: $e');
      return 0;
    }
  }
}