// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:shared_preferences/shared_preferences.dart';

class LizzyVoteService {
  static const String _lizzyVotesKey = 'user_lizzy_votes';
  late SharedPreferences _prefs;
  Set<String> _userLizzyVotes = {};

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    final votes = _prefs.getStringList(_lizzyVotesKey) ?? [];
    _userLizzyVotes = Set<String>.from(votes);
  }

  /// Check if user has given a lizzy vote to a specific comment
  bool hasUserLizzied(String commentId) {
    return _userLizzyVotes.contains(commentId);
  }

  /// Toggle lizzy vote for a comment
  Future<bool> toggleLizzy(String commentId) async {
    bool wasLizzied = _userLizzyVotes.contains(commentId);
    
    if (wasLizzied) {
      _userLizzyVotes.remove(commentId);
    } else {
      _userLizzyVotes.add(commentId);
    }
    
    await _saveLizzyVotes();
    return !wasLizzied; // Return new state
  }

  /// Save lizzy votes to SharedPreferences
  Future<void> _saveLizzyVotes() async {
    await _prefs.setStringList(_lizzyVotesKey, _userLizzyVotes.toList());
  }

  /// Get all user's lizzy votes
  Set<String> getUserLizzyVotes() {
    return Set<String>.from(_userLizzyVotes);
  }

  /// Add a lizzy vote (used for syncing with database)
  Future<void> addLizzy(String commentId) async {
    if (!_userLizzyVotes.contains(commentId)) {
      _userLizzyVotes.add(commentId);
      await _saveLizzyVotes();
    }
  }

  /// Remove a lizzy vote (used when comment is deleted or syncing with database)
  Future<void> removeLizzy(String commentId) async {
    if (_userLizzyVotes.contains(commentId)) {
      _userLizzyVotes.remove(commentId);
      await _saveLizzyVotes();
    }
  }
}