// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// Service to manage on-device storage of user responses for manual room sharing
/// This enables users to share their responses to rooms after answering questions
class LocalResponseStorageService {
  static const String _responsesKey = 'user_responses';
  static const String _responsePrefix = 'response_';
  
  // Maximum age for stored responses (30 days)
  static const Duration _maxResponseAge = Duration(days: 30);
  
  /// Save a user's response locally after they submit it
  Future<void> storeResponse({
    required String questionId,
    required String responseId,
    required String questionText,
    required String responseText,
    required String questionType,
    required DateTime answeredAt,
    String? selectedOption,
    double? ratingScore,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      
      final responseData = {
        'question_id': questionId,
        'response_id': responseId,
        'question_text': questionText,
        'response_text': responseText,
        'question_type': questionType,
        'answered_at': answeredAt.toIso8601String(),
        'selected_option': selectedOption,
        'rating_score': ratingScore,
      };
      
      // Store individual response
      final responseKey = '$_responsePrefix$questionId';
      await prefs.setString(responseKey, jsonEncode(responseData));
      
      // Update the master list of response keys
      final responsesList = await _getStoredResponsesList();
      if (!responsesList.contains(questionId)) {
        responsesList.add(questionId);
        await prefs.setStringList(_responsesKey, responsesList);
      }
      
      // Clean up old responses
      await _cleanupOldResponses();
      
      print('Stored local response for question $questionId');
    } catch (e) {
      print('Error storing local response: $e');
    }
  }
  
  /// Get a stored response for a specific question
  Future<Map<String, dynamic>?> getStoredResponse(String questionId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final responseKey = '$_responsePrefix$questionId';
      final responseJson = prefs.getString(responseKey);
      
      if (responseJson != null) {
        final responseData = jsonDecode(responseJson) as Map<String, dynamic>;
        
        // Check if response is not too old
        final answeredAt = DateTime.parse(responseData['answered_at']);
        if (DateTime.now().difference(answeredAt) <= _maxResponseAge) {
          return responseData;
        } else {
          // Remove expired response
          await _removeStoredResponse(questionId);
          return null;
        }
      }
      
      return null;
    } catch (e) {
      print('Error getting stored response: $e');
      return null;
    }
  }
  
  /// Check if we have a stored response for a question
  Future<bool> hasStoredResponse(String questionId) async {
    final response = await getStoredResponse(questionId);
    return response != null;
  }
  
  /// Get all stored responses (for debugging/cleanup)
  Future<List<Map<String, dynamic>>> getAllStoredResponses() async {
    try {
      final responsesList = await _getStoredResponsesList();
      final responses = <Map<String, dynamic>>[];
      
      for (final questionId in responsesList) {
        final response = await getStoredResponse(questionId);
        if (response != null) {
          responses.add(response);
        }
      }
      
      return responses;
    } catch (e) {
      print('Error getting all stored responses: $e');
      return [];
    }
  }
  
  /// Remove a stored response
  Future<void> _removeStoredResponse(String questionId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final responseKey = '$_responsePrefix$questionId';
      await prefs.remove(responseKey);
      
      // Update master list
      final responsesList = await _getStoredResponsesList();
      responsesList.remove(questionId);
      await prefs.setStringList(_responsesKey, responsesList);
      
      print('Removed stored response for question $questionId');
    } catch (e) {
      print('Error removing stored response: $e');
    }
  }
  
  /// Get the list of stored response question IDs
  Future<List<String>> _getStoredResponsesList() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_responsesKey) ?? [];
  }
  
  /// Clean up responses older than the maximum age
  Future<void> _cleanupOldResponses() async {
    try {
      final responsesList = await _getStoredResponsesList();
      final now = DateTime.now();
      final toRemove = <String>[];
      
      for (final questionId in responsesList) {
        final response = await getStoredResponse(questionId);
        if (response != null) {
          final answeredAt = DateTime.parse(response['answered_at']);
          if (now.difference(answeredAt) > _maxResponseAge) {
            toRemove.add(questionId);
          }
        } else {
          // Response doesn't exist, mark for removal from list
          toRemove.add(questionId);
        }
      }
      
      // Remove expired responses
      for (final questionId in toRemove) {
        await _removeStoredResponse(questionId);
      }
      
      if (toRemove.isNotEmpty) {
        print('Cleaned up ${toRemove.length} old responses');
      }
    } catch (e) {
      print('Error cleaning up old responses: $e');
    }
  }
  
  /// Clear all stored responses (for logout/reset)
  Future<void> clearAllResponses() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final responsesList = await _getStoredResponsesList();
      
      // Remove all individual response entries
      for (final questionId in responsesList) {
        final responseKey = '$_responsePrefix$questionId';
        await prefs.remove(responseKey);
      }
      
      // Clear the master list
      await prefs.remove(_responsesKey);
      
      print('Cleared all stored responses');
    } catch (e) {
      print('Error clearing stored responses: $e');
    }
  }
  
  /// Get storage statistics for debugging
  Future<Map<String, dynamic>> getStorageStats() async {
    try {
      final responses = await getAllStoredResponses();
      final totalResponses = responses.length;
      final oldestResponse = responses.isNotEmpty 
          ? responses.map((r) => DateTime.parse(r['answered_at'])).reduce((a, b) => a.isBefore(b) ? a : b)
          : null;
      final newestResponse = responses.isNotEmpty
          ? responses.map((r) => DateTime.parse(r['answered_at'])).reduce((a, b) => a.isAfter(b) ? a : b)
          : null;
      
      return {
        'total_responses': totalResponses,
        'oldest_response': oldestResponse?.toIso8601String(),
        'newest_response': newestResponse?.toIso8601String(),
        'max_age_days': _maxResponseAge.inDays,
      };
    } catch (e) {
      print('Error getting storage stats: $e');
      return {'error': e.toString()};
    }
  }
}