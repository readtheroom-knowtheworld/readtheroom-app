// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'user_service.dart';

/// Thin read-only helper for [CongratulationsService].
///
/// Badge unlock rules live in `utils/badge_logic.dart` and the Me screen
/// gathers their inputs. This class used to carry a second, unused copy of
/// those rules (with stale column names and a total count nobody called);
/// that was removed on 2026-09-28 so there is one catalog to maintain.
class AchievementService {
  final UserService userService;
  final BuildContext context;
  late SharedPreferences _prefs;

  static const String _achievementPrefix = 'achievement_';

  AchievementService({required this.userService, required this.context});

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
  }

  int getAnsweredQuestionsCount() {
    return userService.answeredQuestions.length;
  }

  /// Whether a sticky badge flag is set. Accepts the bare flag name
  /// (`qotd_star`) or the stored key (`achievement_qotd_star`). Before
  /// 2026-09-28 only the stored key worked, so the QOTD congratulations,
  /// which passes the bare name, never fired.
  bool isAchievementUnlocked(String key) {
    final storedKey =
        key.startsWith(_achievementPrefix) ? key : '$_achievementPrefix$key';
    return _prefs.getBool(storedKey) ?? false;
  }
}
