// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:io' show Platform;
import 'achievement_service.dart';
import 'user_service.dart';
import '../screens/congratulations_curio_screen.dart';

enum AchievementType {
  firstQuestion,
  answered20Questions,
  qotdBadge,
  camoTop20
}

class CongratulationsService {
  static const String _lastPromptPrefix = 'congratulations_last_prompt_';
  static const String _appStoreReviewClickedKey = 'app_store_review_clicked';
  static const Duration _cooldownPeriod = Duration(days: 30);
  
  // Testing flag - set to true to bypass cooldown and achievement checks
  static const bool _testingMode = false;

  final UserService userService;
  final AchievementService achievementService;
  late SharedPreferences _prefs;

  CongratulationsService({
    required this.userService,
    required this.achievementService,
  });

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
  }

  String _getLastPromptKey(AchievementType type) {
    switch (type) {
      case AchievementType.firstQuestion:
        return '${_lastPromptPrefix}first_question';
      case AchievementType.answered20Questions:
        return '${_lastPromptPrefix}answered_10';
      case AchievementType.qotdBadge:
        return '${_lastPromptPrefix}qotd';
      case AchievementType.camoTop20:
        return '${_lastPromptPrefix}camo_top20';
    }
  }

  bool _hasReviewedApp() {
    return _prefs.getBool(_appStoreReviewClickedKey) ?? false;
  }

  Future<void> markAppStoreReviewClicked() async {
    await _prefs.setBool(_appStoreReviewClickedKey, true);
  }

  bool _isInCooldownPeriod(AchievementType type) {
    final lastPromptString = _prefs.getString(_getLastPromptKey(type));
    if (lastPromptString == null) return false;

    final lastPrompt = DateTime.parse(lastPromptString);
    final now = DateTime.now();
    return now.difference(lastPrompt) < _cooldownPeriod;
  }

  Future<void> _recordPromptShown(AchievementType type) async {
    await _prefs.setString(_getLastPromptKey(type), DateTime.now().toIso8601String());
  }

  Future<bool> shouldShowCongratulations(AchievementType type) async {
    // In testing mode, always show (bypass all checks)
    if (_testingMode) return true;
    
    // Never show again if user has already reviewed the app
    if (_hasReviewedApp()) return false;

    // Don't show if in cooldown period
    if (_isInCooldownPeriod(type)) return false;

    // Check if achievement has been reached
    switch (type) {
      case AchievementType.firstQuestion:
        return achievementService.hasFirstQuestion();
      
      case AchievementType.answered20Questions:
        return achievementService.getAnsweredQuestionsCount() >= 10;
      
      case AchievementType.qotdBadge:
        return achievementService.isAchievementUnlocked('qotd_star');
      
      case AchievementType.camoTop20:
        return await _checkCamoTop20Achievement();
    }
  }

  Future<bool> _checkCamoTop20Achievement() async {
    try {
      final rankingData = await userService.getUserEngagementRankingWithCamoQuality(forceRefresh: true);
      final rank = rankingData['rank'] ?? 0;
      return rank > 0 && rank <= 20;
    } catch (e) {
      // Log error in production - consider using a proper logging service
      print('Error checking Camo Counter ranking: $e');
      return false;
    }
  }

  String getAchievementTitle(AchievementType type) {
    switch (type) {
      case AchievementType.firstQuestion:
        return 'Congratulations!';
      case AchievementType.answered20Questions:
        return 'Amazing Progress!';
      case AchievementType.qotdBadge:
        return 'Question of the Day!';
      case AchievementType.camoTop20:
        return 'Top Chameleon!';
    }
  }

  String getAchievementMessage(AchievementType type) {
    switch (type) {
      case AchievementType.firstQuestion:
        return 'You\'ve posted your first question!\n\nWelcome to the community of curious minds exploring the world together.';
      case AchievementType.answered20Questions:
        return 'You\'ve answered 10 questions!\n\nYour voice is helping shape our understanding of the world\'s perspectives.';
      case AchievementType.qotdBadge:
        return 'Your question became Question of the Day!\n\nYou\'ve sparked conversations that matter to people worldwide.';
      case AchievementType.camoTop20:
        return 'You\'re in the top 20 for Camo Counter this month!\n\nYour engagement is making Read the Room a better place.';
    }
  }

  String getShareMessage(AchievementType type) {
    switch (type) {
      case AchievementType.firstQuestion:
        return 'I just posted my first question on Read the Room! Join me in exploring what the world really thinks. 🦎';
      case AchievementType.answered20Questions:
        return 'I\'ve answered 10 questions on Read the Room! My voice is part of a global conversation. 🦎';
      case AchievementType.qotdBadge:
        return 'My question became Question of the Day on Read the Room! Join the conversation and see what the world thinks. 🦎';
      case AchievementType.camoTop20:
        return 'I\'m in the top 20 chameleons this month on Read the Room! See how your opinions compare to the world. 🦎';
    }
  }

  String getAppStoreUrl() {
    if (Platform.isIOS) {
      return 'https://apps.apple.com/us/app/read-the-room-know-the-world/id6747105473';
    } else {
      return 'https://play.google.com/store/apps/details?id=com.readtheroom.app';
    }
  }

  Future<void> showCongratulationsIfEligible(BuildContext context, AchievementType type) async {
    if (await shouldShowCongratulations(type)) {
      await _recordPromptShown(type);
      await CongratulationsCurioScreen.show(context, type, this);
    }
  }
  
  // Testing method to show congratulations for any achievement type
  Future<void> showCongratulationsForTesting(BuildContext context, AchievementType type) async {
    await CongratulationsCurioScreen.show(context, type, this);
  }
}
