// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:profanity_filter/profanity_filter.dart';

class ProfanityFilterService {
  // Singleton implementation
  static final ProfanityFilterService _instance = ProfanityFilterService._internal();
  
  factory ProfanityFilterService() {
    return _instance;
  }
  
  ProfanityFilterService._internal() {
    _initializeFilter();
  }
  
  // The actual filter instance
  late final ProfanityFilter _filter;
  
  void _initializeFilter() {
    // Initialize the profanity filter with default list
    _filter = ProfanityFilter();
  }
  
  // Check if a string contains profanity
  bool containsProfanity(String text) {
    if (text.isEmpty) return false;
    // Strip punctuation so "badword." is caught the same as "badword"
    final stripped = text.replaceAll(RegExp(r'[^\w\s]'), '');
    return _filter.hasProfanity(stripped);
  }
  
  // Get a censored version of the text (replace profane words with asterisks)
  String censorText(String text) {
    if (text.isEmpty) return text;
    return _filter.censor(text);
  }
  
  // Get all profane words found in the text
  List<String> getAllProfanity(String text) {
    if (text.isEmpty) return [];
    return _filter.getAllProfanity(text);
  }
  
  // Filter with additional custom words
  // Note: This creates a new filter instance with the additional words
  ProfanityFilter getFilterWithAdditionalWords(List<String> words) {
    return ProfanityFilter.filterAdditionally(words);
  }
  
  // Filter with only custom words (ignoring default list)
  // Note: This creates a new filter instance with only the specified words
  ProfanityFilter getFilterForCustomWordsOnly(List<String> words) {
    return ProfanityFilter.filterOnly(words);
  }
  
  // Filter with exclusions from the default list
  // Note: This creates a new filter instance with the specified words excluded
  ProfanityFilter getFilterWithExclusions(List<String> words) {
    return ProfanityFilter.ignore(words);
  }
} 