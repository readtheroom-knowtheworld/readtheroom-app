// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import '../models/notification_item.dart';

class NotificationLogService {
  static const String _storageKey = 'notification_log';
  static const int _maxNotifications = 50; // Keep only the latest 50 notifications
  
  // Add a notification to the log
  Future<void> addNotification(NotificationItem notification) async {
    final prefs = await SharedPreferences.getInstance();
    final notifications = await getAllNotifications();
    
    // Add the new notification at the beginning
    notifications.insert(0, notification);
    
    // Keep only the latest notifications
    if (notifications.length > _maxNotifications) {
      notifications.removeRange(_maxNotifications, notifications.length);
    }
    
    await _saveNotifications(notifications, prefs);
  }
  
  // Add or update a notification for vote activity
  // If a notification for the same question already exists today, update it instead of creating a new one
  Future<void> addOrUpdateVoteActivityNotification({
    required String questionId,
    required String title,
    required String body,
    required String type,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final notifications = await getAllNotifications();
    
    // Look for existing vote activity notification for this question from today
    final now = DateTime.now();
    final todayStart = DateTime(now.year, now.month, now.day);
    
    int existingIndex = notifications.indexWhere((n) => 
      n.questionId == questionId && 
      n.type == 'vote_activity' &&
      n.timestamp.isAfter(todayStart) &&
      !n.isDismissed
    );
    
    if (existingIndex != -1) {
      // Update the existing notification
      notifications[existingIndex] = notifications[existingIndex].copyWith(
        body: body,
        timestamp: DateTime.now(), // Update timestamp to now
        isViewed: false, // Mark as unviewed again since there's new activity
      );
    } else {
      // Create a new notification
      final newNotification = NotificationItem(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        title: title,
        body: body,
        type: type,
        timestamp: DateTime.now(),
        questionId: questionId,
      );
      
      // Add the new notification at the beginning
      notifications.insert(0, newNotification);
      
      // Keep only the latest notifications
      if (notifications.length > _maxNotifications) {
        notifications.removeRange(_maxNotifications, notifications.length);
      }
    }
    
    await _saveNotifications(notifications, prefs);
  }
  
  // Get all notifications
  Future<List<NotificationItem>> getAllNotifications() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonString = prefs.getString(_storageKey);
    
    if (jsonString == null) return [];
    
    try {
      final List<dynamic> jsonList = json.decode(jsonString);
      return jsonList.map((json) => NotificationItem.fromJson(json)).toList();
    } catch (e) {
      print('Error loading notifications: $e');
      return [];
    }
  }
  
  // Get notifications from today only
  Future<List<NotificationItem>> getTodaysNotifications() async {
    final allNotifications = await getAllNotifications();
    return allNotifications.where((notification) => notification.isToday).toList();
  }
  
  // Get the most recent N notifications from today
  Future<List<NotificationItem>> getRecentTodaysNotifications({int limit = 5}) async {
    final todaysNotifications = await getTodaysNotifications();
    return todaysNotifications.take(limit).toList();
  }
  
  // Mark a notification as viewed
  Future<void> markAsViewed(String notificationId) async {
    await _updateNotification(notificationId, (notification) => 
        notification.copyWith(isViewed: true));
  }
  
  // Mark a notification as dismissed
  Future<void> markAsDismissed(String notificationId) async {
    await _updateNotification(notificationId, (notification) => 
        notification.copyWith(isDismissed: true));
  }
  
  // Undo dismissal of a notification
  Future<void> undismissNotification(String notificationId) async {
    await _updateNotification(notificationId, (notification) => 
        notification.copyWith(isDismissed: false));
  }
  
  // Mark all today's notifications as viewed
  Future<void> markAllTodaysNotificationsAsViewed() async {
    final prefs = await SharedPreferences.getInstance();
    final notifications = await getAllNotifications();
    
    bool hasChanges = false;
    for (int i = 0; i < notifications.length; i++) {
      if (notifications[i].isToday && !notifications[i].isViewed) {
        notifications[i] = notifications[i].copyWith(isViewed: true);
        hasChanges = true;
      }
    }
    
    if (hasChanges) {
      await _saveNotifications(notifications, prefs);
    }
  }
  
  // Get count of unviewed notifications from today
  Future<int> getUnviewedTodaysCount() async {
    final todaysNotifications = await getTodaysNotifications();
    return todaysNotifications.where((n) => !n.isViewed && !n.isDismissed).length;
  }
  
  // Check if there are any unviewed notifications from today
  Future<bool> hasUnviewedTodaysNotifications() async {
    final count = await getUnviewedTodaysCount();
    return count > 0;
  }
  
  // Clear all notifications (useful for testing or privacy)
  Future<void> clearAllNotifications() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_storageKey);
  }
  
  // Private helper to update a specific notification
  Future<void> _updateNotification(String notificationId, 
      NotificationItem Function(NotificationItem) updateFunction) async {
    final prefs = await SharedPreferences.getInstance();
    final notifications = await getAllNotifications();
    
    for (int i = 0; i < notifications.length; i++) {
      if (notifications[i].id == notificationId) {
        notifications[i] = updateFunction(notifications[i]);
        break;
      }
    }
    
    await _saveNotifications(notifications, prefs);
  }
  
  // Private helper to save notifications to storage
  Future<void> _saveNotifications(List<NotificationItem> notifications, 
      SharedPreferences prefs) async {
    final jsonString = json.encode(notifications.map((n) => n.toJson()).toList());
    await prefs.setString(_storageKey, jsonString);
  }
  
  // Helper method to create a notification from remote message data
  static NotificationItem createFromRemoteMessage({
    required String title,
    required String body,
    required String type,
    String? questionId,
    String? suggestionId,
    Map<String, dynamic>? additionalMetadata,
  }) {
    return NotificationItem(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      title: title,
      body: body,
      type: type,
      timestamp: DateTime.now(),
      questionId: questionId,
      suggestionId: suggestionId,
      metadata: additionalMetadata,
    );
  }
}