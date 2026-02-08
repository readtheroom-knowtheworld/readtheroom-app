// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/room.dart';

class ActivityService {
  final SupabaseClient _supabase = Supabase.instance.client;

  Future<List<UserActivityItem>> getUserActivity({
    int limit = 20,
    int offset = 0,
  }) async {
    try {
      final userId = _supabase.auth.currentUser?.id;
      if (userId == null) {
        throw Exception('User not authenticated');
      }

      final response = await _supabase
          .from('user_activity_items')
          .select('*')
          .eq('user_id', userId)
          .eq('is_dismissed', false)
          .order('created_at', ascending: false)
          .range(offset, offset + limit - 1);

      return response.map<UserActivityItem>((json) => UserActivityItem.fromJson(json)).toList();
    } catch (e) {
      throw Exception('Error fetching user activity: $e');
    }
  }

  Future<List<UserActivityItem>> getUnreadActivity() async {
    try {
      final userId = _supabase.auth.currentUser?.id;
      if (userId == null) {
        throw Exception('User not authenticated');
      }

      final response = await _supabase
          .from('user_activity_items')
          .select('*')
          .eq('user_id', userId)
          .eq('is_read', false)
          .eq('is_dismissed', false)
          .order('created_at', ascending: false);

      return response.map<UserActivityItem>((json) => UserActivityItem.fromJson(json)).toList();
    } catch (e) {
      throw Exception('Error fetching unread activity: $e');
    }
  }

  Future<int> getUnreadCount() async {
    try {
      final userId = _supabase.auth.currentUser?.id;
      if (userId == null) {
        return 0;
      }

      final response = await _supabase
          .from('user_activity_items')
          .select('*')
          .eq('user_id', userId)
          .eq('is_read', false)
          .eq('is_dismissed', false);

      return response.length;
    } catch (e) {
      return 0;
    }
  }

  Future<void> markAsRead(String activityId) async {
    try {
      await _supabase
          .from('user_activity_items')
          .update({'is_read': true})
          .eq('id', activityId);
    } catch (e) {
      throw Exception('Error marking activity as read: $e');
    }
  }

  Future<void> markAllAsRead() async {
    try {
      final userId = _supabase.auth.currentUser?.id;
      if (userId == null) {
        throw Exception('User not authenticated');
      }

      await _supabase
          .from('user_activity_items')
          .update({'is_read': true})
          .eq('user_id', userId)
          .eq('is_read', false);
    } catch (e) {
      throw Exception('Error marking all activities as read: $e');
    }
  }

  Future<void> dismissActivity(String activityId) async {
    try {
      await _supabase
          .from('user_activity_items')
          .update({'is_dismissed': true})
          .eq('id', activityId);
    } catch (e) {
      throw Exception('Error dismissing activity: $e');
    }
  }

  Future<void> createManualShareActivity({
    required String roomId,
    required String questionId,
    required String questionText,
  }) async {
    try {
      final userId = _supabase.auth.currentUser?.id;
      if (userId == null) {
        throw Exception('User not authenticated');
      }

      await _supabase.rpc('generate_manual_share_activities', params: {
        'target_room_id': roomId,
        'target_question_id': questionId,
        'question_text': questionText,
      });
    } catch (e) {
      throw Exception('Error creating manual share activity: $e');
    }
  }

  Stream<List<UserActivityItem>> watchUserActivity() {
    final userId = _supabase.auth.currentUser?.id;
    if (userId == null) {
      throw Exception('User not authenticated');
    }

    return _supabase
        .from('user_activity_items')
        .stream(primaryKey: ['id'])
        .map((data) => data
            .where((item) => item['user_id'] == userId && item['is_dismissed'] == false)
            .map<UserActivityItem>((json) => UserActivityItem.fromJson(json))
            .toList()
            ..sort((a, b) => b.createdAt.compareTo(a.createdAt)));
  }

  Stream<int> watchUnreadCount() {
    final userId = _supabase.auth.currentUser?.id;
    if (userId == null) {
      return Stream.value(0);
    }

    return _supabase
        .from('user_activity_items')
        .stream(primaryKey: ['id'])
        .map((data) => data
            .where((item) => 
                item['user_id'] == userId && 
                item['is_read'] == false && 
                item['is_dismissed'] == false)
            .length);
  }

  Future<void> cleanupExpiredActivities() async {
    try {
      await _supabase
          .from('user_activity_items')
          .delete()
          .lt('expires_at', DateTime.now().toIso8601String());
    } catch (e) {
      // Silently fail for cleanup operations
    }
  }
}