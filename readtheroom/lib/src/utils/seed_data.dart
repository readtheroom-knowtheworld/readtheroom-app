// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';
import 'dart:math';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

/// Comprehensive utility for seeding the database with diverse sample data
class DataSeeder {
  static final Random _random = Random();
  static final List<String> countries = [
    'US', 'CA', 'OM', 'GB', 'FR', 'DE', 'JP', 'AU', 'NZ', 'BR', 
    'AR', 'MX', 'ZA', 'EG', 'NG', 'IN', 'CN', 'RU', 'KR', 'SA'
  ];

  static final List<Map<String, dynamic>> textQuestions = [
    {'prompt': 'What is your favorite book and why?', 'description': 'Share a book that had a significant impact on you.'},
    {'prompt': 'How do you think AI will impact society in the next decade?', 'description': 'Consider both positive and negative implications.'},
    {'prompt': 'What\'s your go-to recipe when cooking at home?', 'description': 'Share your favorite homemade dish.'},
    {'prompt': 'What\'s the most beautiful place you\'ve ever visited?', 'description': 'Describe what made it special.'},
    {'prompt': 'If you could live in any fictional world, which would you choose?', 'description': 'From books, movies, games, etc.'},
    {'prompt': 'What\'s your earliest childhood memory?', 'description': 'Share your first recollection.'},
    {'prompt': 'How do you think education will change in the future?', 'description': 'Consider technology, teaching methods, etc.'},
  ];

  static final List<Map<String, dynamic>> approvalQuestions = [
    {'prompt': 'Do you support a four-day work week?', 'description': 'Working four days with the same pay as five.'},
    {'prompt': 'Should public transportation be free?', 'description': 'Consider the economic and social impacts.'},
    {'prompt': 'Do you approve of your country\'s current healthcare system?', 'description': 'Think about costs, accessibility, and quality.'},
    {'prompt': 'Should schools ban smartphones in classrooms?', 'description': 'Consider learning impacts and emergency needs.'},
    {'prompt': 'Is social media having a positive impact on society?', 'description': 'Consider connection vs. division.'},
    {'prompt': 'Should voting be mandatory?', 'description': 'With penalties for not participating.'},
  ];

  static final List<Map<String, dynamic>> multipleChoiceQuestions = [
    {
      'prompt': 'What\'s your preferred work environment?',
      'description': 'Where do you feel most productive?',
      'options': ['Office with colleagues', 'Remote from home', 'Coffee shop/coworking', 'Hybrid arrangement']
    },
    {
      'prompt': 'Which global challenge should receive more attention?',
      'description': 'What deserves more resources and focus?',
      'options': ['Climate change', 'Economic inequality', 'Education access', 'Healthcare', 'Food security']
    },
    {
      'prompt': 'How often do you exercise?',
      'description': 'Your regular physical activity frequency.',
      'options': ['Daily', 'Several times a week', 'Once a week', 'Occasionally', 'Rarely/Never']
    },
    {
      'prompt': 'What\'s your preferred mode of transportation?',
      'description': 'For your regular commute or travel.',
      'options': ['Car', 'Public transport', 'Walking', 'Cycling', 'Rideshare services']
    },
    {
      'prompt': 'How do you prefer to consume news?',
      'description': 'Your main source of current events.',
      'options': ['Social media', 'News websites', 'TV news', 'Newspapers/magazines', 'Podcasts', 'Friends/family']
    },
    {
      'prompt': 'Which cuisine do you enjoy most?',
      'description': 'Your favorite type of food.',
      'options': ['Italian', 'Chinese', 'Mexican', 'Indian', 'Japanese', 'Thai', 'French', 'Mediterranean']
    },
    {
      'prompt': 'How much time do you spend on social media daily?',
      'description': 'Your typical usage across platforms.',
      'options': ['Less than 30 minutes', '30-60 minutes', '1-2 hours', '2-4 hours', 'More than 4 hours']
    },
  ];

  static final List<String> textResponses = [
    "I think this is a complex issue with many perspectives.",
    "From my experience, I've found this to be true in many cases.",
    "This is something I'm quite passionate about, actually!",
    "I've thought about this a lot and my conclusion is that it depends on the context.",
    "This question reminds me of something that happened in my childhood.",
    "I believe we need to approach this with more nuance than most discussions allow.",
    "My perspective has evolved significantly over the years on this topic.",
    "I think the answer varies greatly depending on cultural context.",
    "This is something I've researched extensively for my work.",
    "I'd like to offer a perspective that might not be as commonly considered.",
    "Having lived in several countries, I've seen different approaches to this.",
    "My professional background gives me a unique perspective on this question.",
    "I've changed my mind on this several times as I've learned more.",
    "This is actually a topic I studied in university.",
    "My family has a tradition related to this that shapes my view.",
  ];

  /// Seed the database with diverse sample data
  static Future<void> seedComprehensiveData() async {
    print('=== COMPREHENSIVE DATA SEEDING START ===');
    
    final serviceKey = const String.fromEnvironment('SUPABASE_SERVICE_KEY');
    if (serviceKey.isEmpty) {
      print('No service key provided, skipping data seeding');
      return;
    }
    
    final supabase = Supabase.instance.client;
    final baseUrl = supabase.rest.url;
    
    try {
      // First check if we already have 20+ questions
      final countResponse = await http.get(
        Uri.parse('$baseUrl/questions?select=count'),
        headers: {
          'apikey': serviceKey,
          'Authorization': 'Bearer $serviceKey',
        },
      );
      
      if (countResponse.statusCode >= 200 && countResponse.statusCode < 300) {
        final countData = jsonDecode(countResponse.body);
        if (countData is List && countData.isNotEmpty) {
          final count = countData[0]['count'] as int? ?? 0;
          if (count >= 20) {
            print('Database already has $count questions, skipping seeding');
            print('=== COMPREHENSIVE DATA SEEDING END ===');
            return;
          }
        }
      }
      
      // Create questions of different types
      final createdQuestionIds = <String>[];
      
      // Add text questions
      for (final question in textQuestions) {
        final id = await _seedQuestion(
          baseUrl, 
          serviceKey, 
          question['prompt'], 
          question['description'], 
          'text',
        );
        if (id != null) createdQuestionIds.add(id);
      }
      
      // Add approval questions
      for (final question in approvalQuestions) {
        final id = await _seedQuestion(
          baseUrl, 
          serviceKey, 
          question['prompt'], 
          question['description'], 
          'approval_rating',
        );
        if (id != null) createdQuestionIds.add(id);
      }
      
      // Add multiple choice questions with options
      for (final question in multipleChoiceQuestions) {
        final id = await _seedQuestion(
          baseUrl, 
          serviceKey, 
          question['prompt'], 
          question['description'], 
          'multiple_choice',
        );
        
        if (id != null) {
          createdQuestionIds.add(id);
          
          // Add options for multiple choice questions
          await _seedQuestionOptions(
            baseUrl, 
            serviceKey, 
            id, 
            question['options'],
          );
        }
      }
      
      print('Created ${createdQuestionIds.length} questions');
      
      // Now seed responses for each question
      int totalResponses = 0;
      for (final questionId in createdQuestionIds) {
        // Get question details to determine type
        final questionResponse = await http.get(
          Uri.parse('$baseUrl/questions?id=eq.$questionId&select=*,question_options(*)'),
          headers: {
            'apikey': serviceKey,
            'Authorization': 'Bearer $serviceKey',
          },
        );
        
        if (questionResponse.statusCode >= 200 && questionResponse.statusCode < 300) {
          final questionData = jsonDecode(questionResponse.body);
          if (questionData is List && questionData.isNotEmpty) {
            final question = questionData[0];
            final questionType = question['type'];
            
            // Seed random number of responses (5-20) per question
            final responsesCount = 5 + _random.nextInt(16); // 5-20 responses
            
            for (int i = 0; i < responsesCount; i++) {
              // Pick a random country
              final country = countries[_random.nextInt(countries.length)];
              
              bool success = false;
              if (questionType == 'text') {
                // For text questions, use random text response
                final textResponse = textResponses[_random.nextInt(textResponses.length)];
                success = await _seedTextResponse(baseUrl, serviceKey, questionId, country, textResponse);
              } else if (questionType == 'approval_rating') {
                // For approval questions, random score between -100 and 100
                final score = -100 + _random.nextInt(201); // -100 to 100
                success = await _seedApprovalResponse(baseUrl, serviceKey, questionId, country, score);
              } else if (questionType == 'multiple_choice') {
                // For multiple choice, randomly select an option
                final options = question['question_options'] as List;
                if (options.isNotEmpty) {
                  final optionId = options[_random.nextInt(options.length)]['id'];
                  success = await _seedMultipleChoiceResponse(baseUrl, serviceKey, questionId, country, optionId);
                }
              }
              
              if (success) totalResponses++;
            }
          }
        }
      }
      
      print('Created $totalResponses responses across ${createdQuestionIds.length} questions');
    } catch (e) {
      print('Error in comprehensive data seeding: $e');
    }
    
    print('=== COMPREHENSIVE DATA SEEDING END ===');
  }
  
  static Future<String?> _seedQuestion(
    String baseUrl, 
    String serviceKey, 
    String prompt, 
    String description, 
    String type
  ) async {
    try {
      final question = {
        'prompt': prompt,
        'description': description,
        'type': type,
        'nsfw': false,
        'country_code': countries[_random.nextInt(countries.length)],
        'is_hidden': false,
      };
      
      final response = await http.post(
        Uri.parse('$baseUrl/questions'),
        headers: {
          'apikey': serviceKey,
          'Authorization': 'Bearer $serviceKey',
          'Content-Type': 'application/json',
          'Prefer': 'return=representation',
        },
        body: jsonEncode(question),
      );
      
      if (response.statusCode >= 200 && response.statusCode < 300 && response.body.isNotEmpty) {
        try {
          final data = jsonDecode(response.body);
          if (data is List && data.isNotEmpty && data[0]['id'] != null) {
            print('Created $type question: ${data[0]['id']}');
            return data[0]['id'];
          }
        } catch (e) {
          print('Error parsing question response: $e');
        }
      } else {
        print('Failed to create question (Status: ${response.statusCode}): ${response.body}');
      }
    } catch (e) {
      print('Error creating question: $e');
    }
    return null;
  }
  
  static Future<bool> _seedQuestionOptions(
    String baseUrl, 
    String serviceKey, 
    String questionId, 
    List<String> options
  ) async {
    try {
      final optionObjects = options.asMap().entries.map((entry) => {
        'question_id': questionId,
        'option_text': entry.value,
        'sort_order': entry.key + 1,
      }).toList();
      
      final response = await http.post(
        Uri.parse('$baseUrl/question_options'),
        headers: {
          'apikey': serviceKey,
          'Authorization': 'Bearer $serviceKey',
          'Content-Type': 'application/json',
          'Prefer': 'return=representation',
        },
        body: jsonEncode(optionObjects),
      );
      
      if (response.statusCode >= 200 && response.statusCode < 300) {
        print('Created ${options.length} options for question $questionId');
        return true;
      } else {
        print('Failed to create options (Status: ${response.statusCode}): ${response.body}');
      }
    } catch (e) {
      print('Error creating options: $e');
    }
    return false;
  }
  
  static Future<bool> _seedTextResponse(
    String baseUrl, 
    String serviceKey, 
    String questionId, 
    String countryCode, 
    String textResponse
  ) async {
    try {
      final response = {
        'question_id': questionId,
        'country_code': countryCode,
        'text_response': textResponse,
        'is_authenticated': false,
      };
      
      final apiResponse = await http.post(
        Uri.parse('$baseUrl/responses'),
        headers: {
          'apikey': serviceKey,
          'Authorization': 'Bearer $serviceKey',
          'Content-Type': 'application/json',
        },
        body: jsonEncode(response),
      );
      
      return apiResponse.statusCode >= 200 && apiResponse.statusCode < 300;
    } catch (e) {
      print('Error creating text response: $e');
      return false;
    }
  }
  
  static Future<bool> _seedApprovalResponse(
    String baseUrl, 
    String serviceKey, 
    String questionId, 
    String countryCode, 
    int score
  ) async {
    try {
      final response = {
        'question_id': questionId,
        'country_code': countryCode,
        'score': score,
        'is_authenticated': false,
      };
      
      final apiResponse = await http.post(
        Uri.parse('$baseUrl/responses'),
        headers: {
          'apikey': serviceKey,
          'Authorization': 'Bearer $serviceKey',
          'Content-Type': 'application/json',
        },
        body: jsonEncode(response),
      );
      
      return apiResponse.statusCode >= 200 && apiResponse.statusCode < 300;
    } catch (e) {
      print('Error creating approval response: $e');
      return false;
    }
  }
  
  static Future<bool> _seedMultipleChoiceResponse(
    String baseUrl, 
    String serviceKey, 
    String questionId, 
    String countryCode, 
    String optionId
  ) async {
    try {
      final response = {
        'question_id': questionId,
        'country_code': countryCode,
        'option_id': optionId,
        'is_authenticated': false,
      };
      
      final apiResponse = await http.post(
        Uri.parse('$baseUrl/responses'),
        headers: {
          'apikey': serviceKey,
          'Authorization': 'Bearer $serviceKey',
          'Content-Type': 'application/json',
        },
        body: jsonEncode(response),
      );
      
      return apiResponse.statusCode >= 200 && apiResponse.statusCode < 300;
    } catch (e) {
      print('Error creating multiple choice response: $e');
      return false;
    }
  }
} 