// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/room.dart';

class RoomService {
  final SupabaseClient _supabase = Supabase.instance.client;

  Future<Room> createRoom({
    required String name,
    String? description,
    String? avatarUrl,
  }) async {
    try {
      print('🎪 Creating room with name: $name, description: $description, avatarUrl: $avatarUrl');
      
      final response = await _supabase.rpc('create_room', params: {
        'room_name': name,
        'room_description': description,
        'room_avatar_url': avatarUrl,
      });

      print('🎪 Create room response: $response');

      if (response == null) {
        print('🎪 ERROR: Create room response is null');
        throw Exception('Failed to create room');
      }

      final room = Room.fromJson(response);
      print('🎪 Successfully created room: ${room.id}');
      return room;
    } catch (e) {
      print('🎪 ERROR: Exception creating room: $e');
      print('🎪 ERROR: Exception type: ${e.runtimeType}');
      print('🎪 ERROR: Exception toString: ${e.toString()}');
      throw Exception('Error creating room: $e');
    }
  }

  Future<Room> joinRoomWithCode(String inviteCode) async {
    try {
      print('🎪 Joining room with invite code: $inviteCode');
      
      final response = await _supabase.rpc('join_room_with_code', params: {
        'room_invite_code': inviteCode,
      });

      print('🎪 Join room response: $response');

      if (response == null) {
        print('🎪 ERROR: Join room response is null');
        throw Exception('Room not found or invite code invalid');
      }

      final room = Room.fromJson(response);
      print('🎪 Successfully joined room: ${room.id}');
      return room;
    } catch (e) {
      print('🎪 ERROR: Exception joining room: $e');
      print('🎪 ERROR: Exception type: ${e.runtimeType}');
      print('🎪 ERROR: Exception toString: ${e.toString()}');
      throw Exception('Error joining room: $e');
    }
  }

  Future<List<Room>> getUserRooms() async {
    try {
      final userId = _supabase.auth.currentUser?.id;
      if (userId == null) {
        print('🎪 ERROR: User not authenticated when fetching rooms');
        throw Exception('User not authenticated');
      }

      print('🎪 Fetching rooms for user: $userId');

      // WORKAROUND: Use an RPC function to bypass RLS issues
      try {
        final response = await _supabase.rpc('get_user_rooms', params: {
          'target_user_id': userId,
        });
        
        print('🎪 RPC response: $response');
        
        if (response == null || response is! List) {
          print('🎪 No rooms found via RPC');
          return [];
        }
        
        final rooms = <Room>[];
        for (final roomData in response) {
          try {
            // Get the room ID from the RPC response
            final roomId = roomData['id'] as String;
            
            // Fetch complete room details including nsfw_enabled field
            final completeRoom = await getRoom(roomId);
            rooms.add(completeRoom);
            // print('🎪 Added room via RPC: ${completeRoom.name} (NSFW: ${completeRoom.nsfwEnabled})');  // Commented out excessive logging
          } catch (e) {
            print('🎪 ERROR: Failed to fetch complete room data for: $roomData, error: $e');
            // Fallback to incomplete room data if complete fetch fails
            try {
              final room = Room.fromJson(roomData as Map<String, dynamic>);
              rooms.add(room);
              // print('🎪 Added room via RPC (fallback): ${room.name}');  // Commented out excessive logging
            } catch (fallbackError) {
              print('🎪 ERROR: Failed to parse room from RPC: $roomData, error: $fallbackError');
            }
          }
        }
        
        // print('🎪 Successfully loaded ${rooms.length} rooms via RPC');  // Commented out excessive logging
        return rooms;
        
      } catch (rpcError) {
        print('🎪 RPC failed, trying direct query: $rpcError');
        
        // Fallback: try direct query with different approach
        final allRooms = await _supabase
            .from('rooms')
            .select('*')
            .eq('created_by', userId);
            
        print('🎪 Direct query found ${allRooms.length} rooms created by user');
        
        final rooms = allRooms.map<Room>((json) => Room.fromJson(json)).toList();
        return rooms;
      }
    } catch (e) {
      print('🎪 ERROR: Exception fetching user rooms: $e');
      print('🎪 ERROR: Exception type: ${e.runtimeType}');
      throw Exception('Error fetching user rooms: $e');
    }
  }

  Future<Room> getRoom(String roomId) async {
    try {
      final response = await _supabase
          .from('rooms')
          .select('*')
          .eq('id', roomId)
          .single();

      final room = Room.fromJson(response);
      // print('🎪 Room ${room.name}: Member count from DB: ${room.memberCount}');  // Commented out excessive logging
      
      // Try to verify member count using RPC to avoid RLS issues
      try {
        final memberCountCheck = await _supabase.rpc('verify_room_member_count', params: {
          'room_id_param': roomId,
        });
        
        if (memberCountCheck != null && memberCountCheck is Map) {
          final actualCount = memberCountCheck['actual_count'] as int? ?? room.memberCount;
          final cachedCount = memberCountCheck['cached_count'] as int? ?? room.memberCount;
          
          if (actualCount != cachedCount) {
            print('🎪 Member count corrected for ${room.name}: $cachedCount -> $actualCount');
            // Return corrected room data
            return Room(
              id: room.id,
              name: room.name,
              description: room.description,
              avatarUrl: room.avatarUrl,
              inviteCode: room.inviteCode,
              inviteCodeActive: room.inviteCodeActive,
              nsfwEnabled: room.nsfwEnabled,
              memberCount: actualCount,
              rqiScore: room.rqiScore,
              globalRank: room.globalRank,
              createdBy: room.createdBy,
              createdAt: room.createdAt,
              updatedAt: room.updatedAt,
            );
          }
        }
      } catch (e) {
        print('🎪 Member count verification not available (RPC not implemented): $e');
        // Silently fall back to using cached count - this is expected if RPC doesn't exist
      }
      
      return room;
    } catch (e) {
      throw Exception('Error fetching room: $e');
    }
  }

  Future<List<RoomMember>> getRoomMembers(String roomId) async {
    try {
      final response = await _supabase
          .from('room_members')
          .select('*')
          .eq('room_id', roomId)
          .order('joined_at', ascending: true);

      return response.map<RoomMember>((json) => RoomMember.fromJson(json)).toList();
    } catch (e) {
      throw Exception('Error fetching room members: $e');
    }
  }

  Future<void> updateSharingPreference(String roomId, String preference) async {
    try {
      print('🎪 Updating sharing preference via RPC: $roomId, preference: $preference');
      
      await _supabase.rpc('update_user_sharing_preference', params: {
        'target_room_id': roomId,
        'new_preference': preference,
      });

      print('🎪 Successfully updated sharing preference via RPC');
    } catch (e) {
      print('🎪 ERROR: Exception updating sharing preference via RPC: $e');
      throw Exception('Error updating sharing preference: $e');
    }
  }

  Future<void> updateNsfwSharingPreference(String roomId, bool shareNsfw) async {
    try {
      print('🎪 Updating NSFW sharing preference: $roomId, shareNsfw: $shareNsfw');
      
      // For now, we'll store this preference in SharedPreferences per room
      // Later this could be extended to a backend field if needed
      final prefs = await SharedPreferences.getInstance();
      final key = 'nsfw_sharing_${roomId}';
      await prefs.setBool(key, shareNsfw);
      
      print('🎪 Successfully updated NSFW sharing preference locally');
    } catch (e) {
      print('🎪 ERROR: Exception updating NSFW sharing preference: $e');
      throw Exception('Error updating NSFW sharing preference: $e');
    }
  }

  Future<bool> getNsfwSharingPreference(String roomId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = 'nsfw_sharing_${roomId}';
      return prefs.getBool(key) ?? true; // Default to true (share NSFW)
    } catch (e) {
      print('🎪 ERROR: Exception getting NSFW sharing preference: $e');
      return true; // Default to true on error
    }
  }

  Future<void> leaveRoom(String roomId) async {
    try {
      final userId = _supabase.auth.currentUser?.id;
      if (userId == null) {
        throw Exception('User not authenticated');
      }

      await _supabase
          .from('room_members')
          .delete()
          .eq('room_id', roomId)
          .eq('user_id', userId);
    } catch (e) {
      throw Exception('Error leaving room: $e');
    }
  }

  Future<void> muteRoom(String roomId, bool muted) async {
    try {
      print('🎪 Updating room mute status via RPC: $roomId, muted: $muted');
      
      await _supabase.rpc('update_room_mute_status', params: {
        'target_room_id': roomId,
        'mute_status': muted,
      });

      print('🎪 Successfully updated room mute status via RPC');
    } catch (e) {
      print('🎪 ERROR: Exception updating room mute status via RPC: $e');
      throw Exception('Error updating room mute status: $e');
    }
  }

  Future<void> toggleRoomInvites(String roomId, bool enableInvites) async {
    try {
      print('🎪 Toggling room invites: $roomId, enabled: $enableInvites');
      
      await _supabase.rpc('toggle_room_invites', params: {
        'room_id': roomId,
        'enable_invites': enableInvites,
      });

      print('🎪 Successfully toggled room invites');
    } catch (e) {
      print('🎪 ERROR: Exception toggling room invites: $e');
      throw Exception('Error toggling room invites: $e');
    }
  }

  Future<void> toggleRoomNsfw(String roomId, bool enableNsfw) async {
    try {
      print('🎪 Toggling room NSFW: $roomId, enabled: $enableNsfw');
      
      await _supabase.rpc('toggle_room_nsfw', params: {
        'target_room_id': roomId,
        'enable_nsfw': enableNsfw,
      });

      print('🎪 Successfully toggled room NSFW setting');
    } catch (e) {
      print('🎪 ERROR: Exception toggling room NSFW: $e');
      throw Exception('Error toggling room NSFW: $e');
    }
  }

  Future<void> deleteRoom(String roomId) async {
    try {
      print('🎪 Deleting room: $roomId');
      
      // Use RPC function to handle proper deletion with cascading
      await _supabase.rpc('delete_room', params: {
        'room_id': roomId,
      });

      print('🎪 Successfully deleted room: $roomId');
    } catch (e) {
      print('🎪 ERROR: Exception deleting room: $e');
      throw Exception('Error deleting room: $e');
    }
  }

  Future<void> updateRoomDescription(String roomId, String description) async {
    try {
      print('🎪 Updating room description via RPC: $roomId, description: $description');
      
      await _supabase.rpc('update_room_description', params: {
        'target_room_id': roomId,
        'new_description': description,
      });

      print('🎪 Successfully updated room description via RPC');
    } catch (e) {
      print('🎪 ERROR: Exception updating room description via RPC: $e');
      throw Exception('Error updating room description: $e');
    }
  }

  Future<bool> isRoomAdmin(String roomId) async {
    try {
      final userId = _supabase.auth.currentUser?.id;
      if (userId == null) {
        return false;
      }

      // Check if user is the room creator
      final room = await getRoom(roomId);
      if (room.createdBy == userId) {
        return true;
      }

      // Check if user has admin role in room_members
      final members = await getRoomMembers(roomId);
      final currentMember = members.where((member) => member.userId == userId).firstOrNull;
      return currentMember?.isAdmin == true;
    } catch (e) {
      print('🎪 ERROR: Exception checking admin status: $e');
      return false;
    }
  }

  String getRoomInviteUrl(String roomId) {
    return 'https://readtheroom.site/room/$roomId';
  }

  Future<Map<String, dynamic>> getUserNetworkRank() async {
    try {
      final userId = _supabase.auth.currentUser?.id;
      if (userId == null) {
        print('🎪 ERROR: User not authenticated when fetching network rank');
        return {'rank': 0, 'totalNetworkUsers': 0, 'camoCounter': 0};
      }

      print('🎪 Fetching network rank for user: $userId');
      
      // Call RPC function to get user's rank in their network
      final response = await _supabase.rpc('get_user_network_rank', params: {
        'target_user_id': userId,
      });
      
      print('🎪 Network rank response: $response');
      
      if (response == null) {
        print('🎪 No network rank data found');
        return {'rank': 0, 'totalNetworkUsers': 0, 'camoCounter': 0};
      }
      
      return {
        'rank': response['rank'] ?? 0,
        'totalNetworkUsers': response['total_network_users'] ?? 0,
        'camoCounter': response['camo_counter'] ?? 0,
      };
    } catch (e) {
      print('🎪 ERROR: Exception fetching network rank: $e');
      // Return default values on error
      return {'rank': 0, 'totalNetworkUsers': 0, 'camoCounter': 0};
    }
  }

  Stream<List<Room>> watchUserRooms() {
    final userId = _supabase.auth.currentUser?.id;
    if (userId == null) {
      throw Exception('User not authenticated');
    }

    return _supabase
        .from('rooms')
        .stream(primaryKey: ['id'])
        .eq('room_members.user_id', userId)
        .order('updated_at', ascending: false)
        .map((data) => data.map<Room>((json) => Room.fromJson(json)).toList());
  }

  Stream<Room> watchRoom(String roomId) {
    return _supabase
        .from('rooms')
        .stream(primaryKey: ['id'])
        .eq('id', roomId)
        .map((data) => Room.fromJson(data.first));
  }
}