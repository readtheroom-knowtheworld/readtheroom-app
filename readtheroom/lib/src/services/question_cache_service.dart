// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'question_service.dart';

class QuestionCacheService extends ChangeNotifier {
  static final QuestionCacheService _instance = QuestionCacheService._internal();
  factory QuestionCacheService() => _instance;
  QuestionCacheService._internal();

  // Cache storage
  final Map<String, Map<String, dynamic>> _questionCache = {};
  final Map<String, List<Map<String, dynamic>>> _responseCache = {};
  final Map<String, DateTime> _cacheTimestamps = {};
  
  // Prefetch queue
  final Set<String> _prefetchQueue = {};
  bool _isPrefetching = false;
  
  // Cache configuration
  static const Duration _cacheExpiry = Duration(minutes: 5);
  static const int _maxCacheSize = 50; // Limit memory usage
  
  QuestionService? _questionService;
  
  void initialize(QuestionService questionService) {
    _questionService = questionService;
  }

  // Get cached question data with responses
  Map<String, dynamic>? getCachedQuestionWithResponses(String questionId) {
    if (!_isValidCache(questionId)) {
      return null;
    }
    
    final question = _questionCache[questionId];
    if (question == null) return null;
    
    // Add cached responses if available
    final responses = _responseCache[questionId];
    if (responses != null) {
      question['preloaded_responses'] = responses;
    }
    
    return Map<String, dynamic>.from(question);
  }

  // Check if question is cached and valid
  bool isQuestionCached(String questionId) {
    return _isValidCache(questionId) && _questionCache.containsKey(questionId);
  }

  // Prefetch questions in background
  Future<void> prefetchQuestions(List<String> questionIds, {bool priority = false}) async {
    final uncachedIds = questionIds.where((id) => !isQuestionCached(id)).toList();
    
    if (uncachedIds.isEmpty) return;
    
    print('🚀 Prefetching ${uncachedIds.length} questions: ${uncachedIds.map((id) => id.substring(0, 8)).join(', ')}...');
    
    if (priority) {
      // For priority prefetch, do it immediately
      await _prefetchQuestionsInternal(uncachedIds);
    } else {
      // For background prefetch, add to queue
      _prefetchQueue.addAll(uncachedIds);
      _processPrefetchQueue();
    }
  }

  // Process prefetch queue in background
  void _processPrefetchQueue() {
    if (_isPrefetching || _prefetchQueue.isEmpty) return;
    
    _isPrefetching = true;
    
    // Process queue in small batches to avoid blocking
    Timer.periodic(Duration(milliseconds: 500), (timer) {
      if (_prefetchQueue.isEmpty) {
        timer.cancel();
        _isPrefetching = false;
        return;
      }
      
      // Take next batch of 2 questions
      final batch = _prefetchQueue.take(2).toList();
      _prefetchQueue.removeAll(batch);
      
      _prefetchQuestionsInternal(batch).catchError((e) {
        print('Background prefetch error: $e');
      });
    });
  }

  // Internal prefetch implementation
  Future<void> _prefetchQuestionsInternal(List<String> questionIds) async {
    if (_questionService == null) return;
    
    final futures = questionIds.map((questionId) => _fetchAndCacheQuestion(questionId));
    await Future.wait(futures);
  }

  // Fetch and cache individual question
  Future<void> _fetchAndCacheQuestion(String questionId) async {
    try {
      // Skip if already cached and valid
      if (isQuestionCached(questionId)) return;
      
      // Fetch complete question data
      final question = await _questionService!.getQuestionById(questionId);
      if (question == null) return;
      
      // Cache question data
      _questionCache[questionId] = Map<String, dynamic>.from(question);
      _cacheTimestamps[questionId] = DateTime.now();
      
      // Fetch responses asynchronously for answered questions
      _fetchAndCacheResponses(questionId, question);
      
      print('✅ Cached question ${questionId.substring(0, 8)}... (${question['type']})');
      
    } catch (e) {
      print('❌ Failed to cache question $questionId: $e');
    }
  }

  // Fetch and cache responses
  Future<void> _fetchAndCacheResponses(String questionId, Map<String, dynamic> question) async {
    try {
      final questionType = question['type']?.toString().toLowerCase() ?? 'text';
      final supabase = Supabase.instance.client;
      List<Map<String, dynamic>>? responses;
      
      switch (questionType) {
        case 'multiple_choice':
          responses = await _questionService!.getMultipleChoiceIndividualResponses(questionId);
          break;
          
        case 'approval_rating':
        case 'approval':
          final response = await supabase
              .from('responses')
              .select('''
                score,
                created_at,
                countries!responses_country_code_fkey(country_name_en)
              ''')
              .eq('question_id', questionId)
              .not('score', 'is', null)
              .order('created_at', ascending: false);
          
          if (response != null && response.isNotEmpty) {
            responses = response.map((r) => {
              'country': r['countries']?['country_name_en'] ?? 'Unknown',
              'answer': (r['score'] as int).toDouble() / 100.0,
              'created_at': r['created_at'],
            }).toList();
          }
          break;
          
        case 'text':
        default:
          final response = await supabase
              .from('responses')
              .select('''
                text_response, 
                created_at,
                countries!responses_country_code_fkey(country_name_en)
              ''')
              .eq('question_id', questionId)
              .not('text_response', 'is', null)
              .order('created_at', ascending: false);
          
          if (response != null && response.isNotEmpty) {
            responses = response.map((r) => {
              'text_response': r['text_response'],
              'country': r['countries']?['country_name_en'] ?? 'Unknown',
              'created_at': r['created_at'],
            }).toList();
          }
          break;
      }
      
      if (responses != null) {
        _responseCache[questionId] = responses;
        print('✅ Cached ${responses.length} responses for ${questionId.substring(0, 8)}...');
      }
      
    } catch (e) {
      print('❌ Failed to cache responses for $questionId: $e');
    }
  }

  // Check if cache entry is valid
  bool _isValidCache(String questionId) {
    final timestamp = _cacheTimestamps[questionId];
    if (timestamp == null) return false;
    
    return DateTime.now().difference(timestamp) < _cacheExpiry;
  }

  // Clean expired cache entries
  void _cleanExpiredCache() {
    final now = DateTime.now();
    final expiredIds = _cacheTimestamps.entries
        .where((entry) => now.difference(entry.value) >= _cacheExpiry)
        .map((entry) => entry.key)
        .toList();
    
    for (final id in expiredIds) {
      _questionCache.remove(id);
      _responseCache.remove(id);
      _cacheTimestamps.remove(id);
    }
    
    if (expiredIds.isNotEmpty) {
      print('🧹 Cleaned ${expiredIds.length} expired cache entries');
    }
  }

  // Limit cache size to prevent memory issues
  void _limitCacheSize() {
    if (_questionCache.length <= _maxCacheSize) return;
    
    // Remove oldest entries
    final sortedEntries = _cacheTimestamps.entries.toList()
      ..sort((a, b) => a.value.compareTo(b.value));
    
    final toRemove = sortedEntries.take(_questionCache.length - _maxCacheSize);
    
    for (final entry in toRemove) {
      final id = entry.key;
      _questionCache.remove(id);
      _responseCache.remove(id);
      _cacheTimestamps.remove(id);
    }
    
    print('🗑️ Removed ${toRemove.length} old cache entries to limit memory');
  }

  // Get next questions for prefetching (handles both List<dynamic> and List<Map<String, dynamic>>)
  List<String> getNextQuestionIds(List<dynamic> questions, int currentIndex, {int count = 3}) {
    final nextIds = <String>[];
    
    for (int i = 1; i <= count && (currentIndex + i) < questions.length; i++) {
      final nextQuestion = questions[currentIndex + i];
      if (nextQuestion is Map<String, dynamic>) {
        final questionId = nextQuestion['id']?.toString();
        if (questionId != null) {
          nextIds.add(questionId);
        }
      }
    }
    
    return nextIds;
  }

  // Clear all cache
  void clearCache() {
    _questionCache.clear();
    _responseCache.clear();
    _cacheTimestamps.clear();
    _prefetchQueue.clear();
    print('🗑️ Cleared all cache');
  }

  // Maintenance - call periodically
  void performMaintenance() {
    _cleanExpiredCache();
    _limitCacheSize();
  }

  // Get cache stats for debugging
  Map<String, dynamic> getCacheStats() {
    return {
      'questions_cached': _questionCache.length,
      'responses_cached': _responseCache.length,
      'prefetch_queue': _prefetchQueue.length,
      'is_prefetching': _isPrefetching,
    };
  }
}