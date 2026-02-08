// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'user_service.dart';
import 'room_service.dart';

class AchievementService {
  final UserService userService;
  final BuildContext context;
  late SharedPreferences _prefs;
  final SupabaseClient _supabase = Supabase.instance.client;
  
  // Achievement keys for SharedPreferences
  static const String _achievementPrefix = 'achievement_';
  static const String _firstQuestionKey = '${_achievementPrefix}first_question';
  static const String _camoChampionKey = '${_achievementPrefix}camo_champion';
  static const String _camoSilverKey = '${_achievementPrefix}camo_silver';
  static const String _camoBronzeKey = '${_achievementPrefix}camo_bronze';
  static const String _qualityChampionKey = '${_achievementPrefix}quality_champion';
  static const String _qualitySilverKey = '${_achievementPrefix}quality_silver';
  static const String _qualityBronzeKey = '${_achievementPrefix}quality_bronze';
  static const String _qotdStarKey = '${_achievementPrefix}qotd_star';
  static const String _popularQuestionKey = '${_achievementPrefix}popular_question';
  static const String _firstLizzyKey = '${_achievementPrefix}first_lizzy';
  static const String _dragonLizzyKey = '${_achievementPrefix}dragon_lizzy';
  static const String _dinoLizzyKey = '${_achievementPrefix}dino_lizzy';
  static const String _popcornTimeKey = '${_achievementPrefix}popcorn_time';
  static const String _birthdayBuddyKey = '${_achievementPrefix}birthday_buddy';
  static const String _plantingSeedKey = '${_achievementPrefix}planting_seed';
  static const String _communityBuildingKey = '${_achievementPrefix}community_building';
  static const String _localLegendKey = '${_achievementPrefix}local_legend';
  
  AchievementService({required this.userService, required this.context});
  
  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
  }
  
  // Check if user has posted their first question
  bool hasFirstQuestion() {
    return userService.postedQuestions.isNotEmpty;
  }
  
  // Check answer count achievements
  int getAnsweredQuestionsCount() {
    return userService.answeredQuestions.length;
  }
  
  bool hasAnswered10Questions() {
    return getAnsweredQuestionsCount() >= 10;
  }
  
  bool hasAnswered100Questions() {
    return getAnsweredQuestionsCount() >= 100;
  }
  
  bool hasAnswered1000Questions() {
    return getAnsweredQuestionsCount() >= 1000;
  }
  
  // Check vote count achievements (using answered as proxy for now)
  int getVotedQuestionsCount() {
    // In the future, this should track actual votes
    // For now, using answered questions as a proxy
    return userService.answeredQuestions.length;
  }
  
  bool hasVoted100Questions() {
    return getVotedQuestionsCount() >= 100;
  }
  
  bool hasVoted1000Questions() {
    return getVotedQuestionsCount() >= 1000;
  }
  
  // Check if user is an early member
  Future<bool> isHatchling() async {
    try {
      final userId = _supabase.auth.currentUser?.id;
      if (userId == null) return false;
      
      // Check user creation date from auth.users
      final response = await _supabase
          .from('profiles')
          .select('created_at')
          .eq('id', userId)
          .single();
      
      if (response['created_at'] != null) {
        final createdAt = DateTime.parse(response['created_at']);
        final launchDate = DateTime(2024, 11, 23); // RTR launch date
        
        // User is a hatchling if created within first month of launch
        return createdAt.isBefore(launchDate.add(Duration(days: 30)));
      }
    } catch (e) {
      print('Error checking hatchling status: $e');
    }
    return false;
  }
  
  // Check if user is an alpha tester
  Future<bool> isAlphaTester() async {
    try {
      final userId = _supabase.auth.currentUser?.id;
      if (userId == null) return false;
      
      final response = await _supabase
          .from('profiles')
          .select('created_at')
          .eq('id', userId)
          .single();
      
      if (response['created_at'] != null) {
        final createdAt = DateTime.parse(response['created_at']);
        final alphaDate = DateTime(2025, 7, 21);
        return createdAt.isBefore(alphaDate);
      }
    } catch (e) {
      print('Error checking alpha tester status: $e');
    }
    return false;
  }
  
  // Check if user is a beta tester
  Future<bool> isBetaTester() async {
    try {
      final userId = _supabase.auth.currentUser?.id;
      if (userId == null) return false;
      
      final response = await _supabase
          .from('profiles')
          .select('created_at')
          .eq('id', userId)
          .single();
      
      if (response['created_at'] != null) {
        final createdAt = DateTime.parse(response['created_at']);
        final betaDate = DateTime(2025, 9, 1);
        return createdAt.isBefore(betaDate);
      }
    } catch (e) {
      print('Error checking beta tester status: $e');
    }
    return false;
  }
  
  // Check room achievements
  Future<int> getUserRoomCount() async {
    try {
      final roomService = RoomService();
      final rooms = await roomService.getUserRooms();
      return rooms.length;
    } catch (e) {
      print('Error getting user room count: $e');
      return 0;
    }
  }
  
  Future<bool> hasJoinedFirstRoom() async {
    final roomCount = await getUserRoomCount();
    return roomCount > 0;
  }
  
  Future<bool> hasCreatedFirstRoom() async {
    try {
      final userId = _supabase.auth.currentUser?.id;
      if (userId == null) return false;
      
      final response = await _supabase
          .from('rooms')
          .select('id')
          .eq('created_by', userId)
          .limit(1);
      
      return response.isNotEmpty;
    } catch (e) {
      print('Error checking room creation: $e');
      return false;
    }
  }
  
  Future<bool> isNetworker() async {
    final roomCount = await getUserRoomCount();
    return roomCount >= 5;
  }
  
  // Check for popular questions
  Future<bool> hasPopularQuestion() async {
    for (var question in userService.postedQuestions) {
      final votes = question['votes'] ?? 0;
      if (votes >= 100) return true;
    }
    return false;
  }
  
  // Check for birthday post
  Future<bool> isBirthdayBuddy() async {
    for (var question in userService.postedQuestions) {
      if (question['created_at'] != null) {
        final createdAt = DateTime.parse(question['created_at']);
        // Check if posted in November (any day, any year) - RTR's birthday month
        if (createdAt.month == 11) {
          return true;
        }
      }
    }
    return false;
  }
  
  // Fetch and cache user's comment lizzy statistics
  Future<Map<String, dynamic>> fetchCommentLizzyStats({bool forceRefresh = false}) async {
    final cacheKey = 'comment_lizzy_stats';
    final cacheTimeKey = 'comment_lizzy_stats_time';
    
    // Check cache first (unless force refresh)
    if (!forceRefresh) {
      final cachedStats = _prefs.getString(cacheKey);
      final cacheTime = _prefs.getString(cacheTimeKey);
      
      if (cachedStats != null && cacheTime != null) {
        final cacheDateTime = DateTime.parse(cacheTime);
        // Use cache if less than 1 hour old
        if (DateTime.now().difference(cacheDateTime).inHours < 1) {
          return Map<String, dynamic>.from(Uri.splitQueryString(cachedStats));
        }
      }
    }
    
    try {
      final userId = _supabase.auth.currentUser?.id;
      if (userId == null) return {'max_lizzies': 0, 'total_lizzies': 0, 'comments_with_lizzies': 0};
      
      // Query comments table for user's comments and their lizzy counts
      final response = await _supabase
          .from('comments')
          .select('id, lizzy_count')
          .eq('user_id', userId);
      
      int maxLizzies = 0;
      int totalLizzies = 0;
      int commentsWithLizzies = 0;
      
      for (var comment in response) {
        final lizzyCount = (comment['lizzy_count'] ?? 0) as int;
        if (lizzyCount > 0) {
          commentsWithLizzies++;
          totalLizzies += lizzyCount as int;
          if (lizzyCount > maxLizzies) {
            maxLizzies = lizzyCount;
          }
        }
      }
      
      final stats = {
        'max_lizzies': maxLizzies,
        'total_lizzies': totalLizzies,
        'comments_with_lizzies': commentsWithLizzies,
      };
      
      // Cache the results
      await _prefs.setString(cacheKey, Uri(queryParameters: 
        stats.map((k, v) => MapEntry(k, v.toString()))).query);
      await _prefs.setString(cacheTimeKey, DateTime.now().toIso8601String());
      
      return stats;
    } catch (e) {
      print('Error fetching lizzy stats: $e');
      return {'max_lizzies': 0, 'total_lizzies': 0, 'comments_with_lizzies': 0};
    }
  }
  
  // Check lizzy achievements based on fetched stats
  Future<bool> hasFirstLizzy() async {
    final stats = await fetchCommentLizzyStats();
    return stats['comments_with_lizzies'] > 0;
  }
  
  Future<bool> hasDragonLizzy() async {
    final stats = await fetchCommentLizzyStats();
    return stats['max_lizzies'] >= 10;
  }
  
  Future<bool> hasDinoLizzy() async {
    final stats = await fetchCommentLizzyStats();
    return stats['max_lizzies'] >= 50;
  }
  
  // Check if any user question has 5+ comments
  Future<bool> hasPopcornTime() async {
    try {
      final userId = _supabase.auth.currentUser?.id;
      if (userId == null) return false;
      
      // Check cache first
      final cacheKey = 'popcorn_time_achievement';
      final cached = _prefs.getBool(cacheKey);
      if (cached != null) return cached;
      
      // Query for questions with 5+ comments
      for (var question in userService.postedQuestions) {
        final questionId = question['id'];
        if (questionId != null) {
          final response = await _supabase
              .from('comments')
              .select('id')
              .eq('question_id', questionId)
              .limit(5);
          
          if (response.length >= 5) {
            await _prefs.setBool(cacheKey, true);
            return true;
          }
        }
      }
      
      await _prefs.setBool(cacheKey, false);
      return false;
    } catch (e) {
      print('Error checking popcorn time: $e');
      return false;
    }
  }
  
  // Fetch and cache engagement ranking achievements
  Future<Map<String, bool>> fetchRankingAchievements({bool forceRefresh = false}) async {
    final cacheKey = 'ranking_achievements';
    final cacheTimeKey = 'ranking_achievements_time';
    
    // Check cache first
    if (!forceRefresh) {
      final cached = _prefs.getString(cacheKey);
      final cacheTime = _prefs.getString(cacheTimeKey);
      
      if (cached != null && cacheTime != null) {
        final cacheDateTime = DateTime.parse(cacheTime);
        if (DateTime.now().difference(cacheDateTime).inHours < 1) {
          final data = Uri.splitQueryString(cached);
          return {
            'camo_champion': data['camo_champion'] == 'true',
            'camo_silver': data['camo_silver'] == 'true',
            'camo_bronze': data['camo_bronze'] == 'true',
            'quality_champion': data['quality_champion'] == 'true',
            'quality_silver': data['quality_silver'] == 'true',
            'quality_bronze': data['quality_bronze'] == 'true',
          };
        }
      }
    }
    
    try {
      // Get current ranking from UserService
      final rankingData = await userService.getUserEngagementRankingWithCamoQuality(forceRefresh: true);
      final camoRank = rankingData['rank'] ?? 0;
      final qualityRank = rankingData['cqiRank'] ?? 0;
      
      final achievements = {
        'camo_champion': camoRank == 1,
        'camo_silver': camoRank == 2,
        'camo_bronze': camoRank == 3,
        'quality_champion': qualityRank == 1,
        'quality_silver': qualityRank == 2,
        'quality_bronze': qualityRank == 3,
      };
      
      // Store persistent achievement status if achieved
      if (achievements['camo_champion']!) await _prefs.setBool(_camoChampionKey, true);
      if (achievements['camo_silver']!) await _prefs.setBool(_camoSilverKey, true);
      if (achievements['camo_bronze']!) await _prefs.setBool(_camoBronzeKey, true);
      if (achievements['quality_champion']!) await _prefs.setBool(_qualityChampionKey, true);
      if (achievements['quality_silver']!) await _prefs.setBool(_qualitySilverKey, true);
      if (achievements['quality_bronze']!) await _prefs.setBool(_qualityBronzeKey, true);
      
      // Cache current status
      await _prefs.setString(cacheKey, Uri(queryParameters: 
        achievements.map((k, v) => MapEntry(k, v.toString()))).query);
      await _prefs.setString(cacheTimeKey, DateTime.now().toIso8601String());
      
      return achievements;
    } catch (e) {
      print('Error fetching ranking achievements: $e');
      return {
        'camo_champion': false,
        'camo_silver': false,
        'camo_bronze': false,
        'quality_champion': false,
        'quality_silver': false,
        'quality_bronze': false,
      };
    }
  }
  
  // Refresh all achievement data (called on pull to refresh)
  Future<void> refreshAllAchievements() async {
    await fetchCommentLizzyStats(forceRefresh: true);
    await fetchRankingAchievements(forceRefresh: true);
    // Refresh other cached data as needed
  }
  
  // Check city-targeted questions
  Future<bool> hasPlantedSeed() async {
    for (var question in userService.postedQuestions) {
      // Check if question has city targeting
      if (question['city'] != null && question['city'].toString().isNotEmpty) {
        return true;
      }
    }
    return false;
  }
  
  Future<bool> hasCommunityBuilding() async {
    for (var question in userService.postedQuestions) {
      if (question['city'] != null && question['city'].toString().isNotEmpty) {
        final votes = question['votes'] ?? 0;
        if (votes >= 10) return true;
      }
    }
    return false;
  }
  
  Future<bool> isLocalLegend() async {
    for (var question in userService.postedQuestions) {
      if (question['city'] != null && question['city'].toString().isNotEmpty) {
        final votes = question['votes'] ?? 0;
        if (votes >= 100) return true;
      }
    }
    return false;
  }
  
  // Store achievement unlock in SharedPreferences
  Future<void> unlockAchievement(String key) async {
    await _prefs.setBool(key, true);
    await _prefs.setString('${key}_date', DateTime.now().toIso8601String());
  }
  
  // Check if achievement is unlocked from SharedPreferences
  bool isAchievementUnlocked(String key) {
    return _prefs.getBool(key) ?? false;
  }
  
  // Get total unlocked achievements count
  Future<int> getUnlockedCount() async {
    int count = 0;
    
    // Count basic achievements
    if (hasFirstQuestion()) count++;
    if (hasAnswered10Questions()) count++;
    if (hasAnswered100Questions()) count++;
    if (hasAnswered1000Questions()) count++;
    if (hasVoted100Questions()) count++;
    if (hasVoted1000Questions()) count++;
    
    // Count async achievements
    if (await isHatchling()) count++;
    if (await isAlphaTester()) count++;
    if (await isBetaTester()) count++;
    if (await hasJoinedFirstRoom()) count++;
    if (await hasCreatedFirstRoom()) count++;
    if (await isNetworker()) count++;
    if (await hasPopularQuestion()) count++;
    if (await isBirthdayBuddy()) count++;
    if (await hasPlantedSeed()) count++;
    if (await hasCommunityBuilding()) count++;
    if (await isLocalLegend()) count++;
    
    // Add stored achievements from SharedPreferences
    if (isAchievementUnlocked(_camoChampionKey)) count++;
    if (isAchievementUnlocked(_camoSilverKey)) count++;
    if (isAchievementUnlocked(_camoBronzeKey)) count++;
    if (isAchievementUnlocked(_qualityChampionKey)) count++;
    if (isAchievementUnlocked(_qualitySilverKey)) count++;
    if (isAchievementUnlocked(_qualityBronzeKey)) count++;
    if (isAchievementUnlocked(_qotdStarKey)) count++;
    if (isAchievementUnlocked(_firstLizzyKey)) count++;
    if (isAchievementUnlocked(_dragonLizzyKey)) count++;
    if (isAchievementUnlocked(_dinoLizzyKey)) count++;
    if (isAchievementUnlocked(_popcornTimeKey)) count++;
    
    return count;
  }
}