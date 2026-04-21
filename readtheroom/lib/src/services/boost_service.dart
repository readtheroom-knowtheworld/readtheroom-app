// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

enum BoostError {
  notAuthenticated,
  ownQuestion,
  tooRecent,
  recentlyBoosted,
  dailyLimit,
  questionNotFound,
  unknown,
}

class BoostResult {
  final bool success;
  final BoostError? error;

  BoostResult({required this.success, this.error});

  String get errorMessage {
    switch (error) {
      case BoostError.notAuthenticated:
        return 'You must be signed in to boost a question.';
      case BoostError.ownQuestion:
        return "You can't boost your own question.";
      case BoostError.tooRecent:
        return 'This question must be over 1 month old to boost.';
      case BoostError.recentlyBoosted:
        return 'This question was boosted recently. It can only be boosted once every 3 months.';
      case BoostError.dailyLimit:
        return "You've already boosted a question today. Try again tomorrow!";
      case BoostError.questionNotFound:
        return 'Question not found.';
      default:
        return 'Something went wrong. Please try again.';
    }
  }
}

class BoostService extends ChangeNotifier {
  final _supabase = Supabase.instance.client;
  DateTime? _lastBoostTime;

  bool get isAuthenticated => _supabase.auth.currentUser != null;

  /// Client-side check: has the user already boosted today?
  bool canBoostToday() {
    if (_lastBoostTime == null) return true;
    return DateTime.now().difference(_lastBoostTime!).inHours >= 24;
  }

  /// Client-side pre-check for quick UX feedback.
  /// Server-side RPC is the source of truth.
  BoostError? checkEligibility(Map<String, dynamic> question) {
    if (!isAuthenticated) return BoostError.notAuthenticated;

    final currentUser = _supabase.auth.currentUser;
    final authorId = question['author_id']?.toString();
    if (authorId != null && authorId == currentUser!.id) {
      return BoostError.ownQuestion;
    }

    final createdAt = question['created_at'];
    if (createdAt != null) {
      final questionDate = DateTime.tryParse(createdAt.toString());
      if (questionDate != null) {
        final age = DateTime.now().difference(questionDate);
        if (age.inDays < 30) return BoostError.tooRecent;
      }
    }

    if (!canBoostToday()) return BoostError.dailyLimit;

    return null; // eligible
  }

  /// Call the server-side boost_question RPC.
  Future<BoostResult> boostQuestion(String questionId) async {
    try {
      final result = await _supabase.rpc(
        'boost_question',
        params: {'p_question_id': questionId},
      );

      if (result is Map && result['success'] == true) {
        _lastBoostTime = DateTime.now();
        notifyListeners();
        return BoostResult(success: true);
      }

      final errorCode = result is Map ? result['error']?.toString() : null;
      final error = _parseError(errorCode);
      return BoostResult(success: false, error: error);
    } catch (e) {
      print('Boost error: $e');
      return BoostResult(success: false, error: BoostError.unknown);
    }
  }

  BoostError _parseError(String? code) {
    switch (code) {
      case 'not_authenticated':
        return BoostError.notAuthenticated;
      case 'own_question':
        return BoostError.ownQuestion;
      case 'too_recent':
        return BoostError.tooRecent;
      case 'recently_boosted':
        return BoostError.recentlyBoosted;
      case 'daily_limit':
        return BoostError.dailyLimit;
      case 'question_not_found':
        return BoostError.questionNotFound;
      default:
        return BoostError.unknown;
    }
  }
}
