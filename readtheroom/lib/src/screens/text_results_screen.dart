// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:share_plus/share_plus.dart';
import '../services/question_service.dart';
import '../services/location_service.dart';
import '../utils/time_utils.dart';
import '../utils/theme_utils.dart';
import 'dart:math' as math;
import 'dart:math' show Random;
import 'package:word_cloud/word_cloud_view.dart';
import 'package:word_cloud/word_cloud_data.dart';
import 'package:word_cloud/word_cloud_shape.dart';
import './report_question_screen.dart';
import 'package:provider/provider.dart';
import '../services/user_service.dart';
import '../services/guest_user_tracking_service.dart';
import '../services/profanity_filter_service.dart';
import '../models/category.dart';
import 'dart:async';
import '../widgets/notification_bell.dart';
import '../widgets/swipe_navigation_wrapper.dart';
import '../widgets/question_reactions_widget.dart';
import '../widgets/comments_section.dart';
import '../widgets/linked_questions_section.dart';
import '../widgets/add_comment_dialog.dart';
import '../widgets/country_filter_dialog.dart';
import 'base_results_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../utils/category_navigation.dart';
import 'main_screen.dart';

class TextResultsScreen extends BaseResultsScreen {
  const TextResultsScreen({
    Key? key,
    required Map<String, dynamic> question,
    FeedContext? feedContext,
    bool fromSearch = false,
    bool fromUserScreen = false,
    bool isGuestMode = false,
  }) : super(
          key: key,
          question: question,
          responses: const [], // Will be loaded dynamically
          feedContext: feedContext,
          fromSearch: fromSearch,
          fromUserScreen: fromUserScreen,
          isGuestMode: isGuestMode,
        );

  @override
  _TextResultsScreenState createState() => _TextResultsScreenState();
}

class _TextResultsScreenState extends BaseResultsScreenState<TextResultsScreen> {
  final _supabase = Supabase.instance.client;
  QuestionService? _questionService;
  bool _isLoading = true;
  List<Map<String, dynamic>> _responses = [];
  WordCloudData _wordCloudData = WordCloudData(data: []);
  bool _isReporting = false;
  String? _errorMessage;
  String? _selectedCountry;
  String? _actualCityName; // Store the fetched city name
  bool _loadingCityName = false;
  Timer? _pollTimer;
  int _lastResponseCount = 0;
  DateTime _lastUpdated = DateTime.now();
  bool _isQuestionExpanded = false; // Track question text expansion
  List<Map<String, dynamic>> _comments = []; // Store comments for linked questions
  final GlobalKey<State<CommentsSection>> _commentsSectionKey = GlobalKey<State<CommentsSection>>();
  final ScrollController _scrollController = ScrollController();
  bool _showQuestionInTitle = false;

  void _setupScrollListener() {
    _scrollController.addListener(() {
      final showQuestion = _scrollController.offset > 100;
      if (showQuestion != _showQuestionInTitle) {
        setState(() {
          _showQuestionInTitle = showQuestion;
        });
      }
    });
  }

  String get _appBarTitle {
    return 'Results';
  }

  bool _shouldShowFilterButton() {
    return !isPrivateQuestion && 
           !isCityTargeted && 
           _responses.isNotEmpty &&
           _getUniqueCountriesWithResponses().length > 1;
  }

  List<String> _getUniqueCountriesWithResponses() {
    final countries = <String>{};
    for (var response in _responses) {
      final country = response['country']?.toString();
      if (country != null && country.isNotEmpty && country != 'Unknown') {
        countries.add(country);
      }
    }
    return countries.toList();
  }

  Map<String, Map<String, dynamic>> _getCountryResponseData() {
    final countryResponses = <String, int>{};
    for (var response in _responses) {
      final country = response['country'] as String? ?? 'Unknown';
      countryResponses[country] = (countryResponses[country] ?? 0) + 1;
    }

    // Convert to the format expected by the dialog
    final result = <String, Map<String, dynamic>>{};
    countryResponses.forEach((country, count) {
      if (country != 'Unknown' && count > 0) {
        result[country] = {
          'total': count,
        };
      }
    });
    return result;
  }

  Future<void> _showCountryFilterDialog() async {
    final countryData = _getCountryResponseData();
    if (countryData.isEmpty) return;

    final questionTitle = widget.question['prompt'] ?? widget.question['title'] ?? 'Question';
    
    final selectedCountry = await CountryFilterDialog.show(
      context: context,
      countryResponses: countryData,
      currentSelectedCountry: _selectedCountry,
      questionTitle: questionTitle,
      questionId: widget.question['id'].toString(),
      questionType: 'text',
    );

    if (selectedCountry != null || selectedCountry == null) {
      // Update the selected country (null means global)
      _onCountrySelected(selectedCountry);
    }
  }

  @override
  void initState() {
    super.initState();
    print('TextResultsScreen initialized with question ID: ${widget.question['id']}');
    _questionService = Provider.of<QuestionService>(context, listen: false);
    _setupScrollListener();
    
    // Auto-filter to country for country-targeted questions
    if (isCountryTargeted && widget.question['country_code'] != null) {
      _selectedCountry = _getCountryNameFromCode(widget.question['country_code']);
    }
    
    _loadData();
    _loadCityNameIfNeeded();
    // _startPolling() is now called conditionally in _loadData()
    // Record this question view with current vote count
    _recordQuestionView();
  }
  
  @override
  void dispose() {
    print('Disposing TextResultsScreen');
    _scrollController.dispose();
    _pollTimer?.cancel();
    _pollTimer = null;
    // Note: Don't try to access ScaffoldMessenger in dispose() as the widget tree may be deactivated
    // ScaffoldMessenger snackbars will be automatically dismissed when the screen is popped
    // Make sure to clean up any resources when the widget is disposed
    _isLoading = false; // Prevent any pending setState calls
    super.dispose();
  }
  
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Show error message if there is one
    if (_errorMessage != null && mounted) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) { // Check if still mounted before showing SnackBar
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(_errorMessage!),
              backgroundColor: Colors.red,
            ),
          );
          _errorMessage = null;
        }
      });
    }
  }

  Future<void> _loadData() async {
    if (!mounted) return; // Don't proceed if widget is no longer mounted
    
    setState(() => _isLoading = true);
    try {
      // Check if we have preloaded text responses first
      if (widget.question['preloaded_text_responses'] != null) {
        final preloadedResponses = widget.question['preloaded_text_responses'] as List<Map<String, dynamic>>;
        print('⚡ Using ${preloadedResponses.length} preloaded text responses');
        
        // Generate word cloud data from preloaded responses
        final wordCloudData = _generateWordCloudData(preloadedResponses);
        
        if (mounted) {
          setState(() {
            _responses = preloadedResponses;
            _wordCloudData = wordCloudData;
            _isLoading = false;
            _lastResponseCount = preloadedResponses.length;
            _lastUpdated = DateTime.now();
            // Don't override vote count - it should already be set correctly by navigateToResultsScreen
          });
        }
        
        // Start polling to check for updates after displaying preloaded data
        _startPolling();
        
        // Check for updates immediately to catch user's fresh vote
        // Multiple quick checks to ensure we catch the user's vote ASAP
        Future.delayed(Duration(milliseconds: 200), () {
          if (mounted) {
            print('⚡ First immediate check for fresh user vote');
            _checkForUpdates();
          }
        });
        Future.delayed(Duration(milliseconds: 800), () {
          if (mounted) {
            print('⚡ Second immediate check for fresh user vote');
            _checkForUpdates();
          }
        });
        return;
      }
      
      print('Loading real responses for question ID: ${widget.question['id']}');
      
      // Only fetch from database if no preloaded data exists
      await _loadFreshDataFromDatabase();
      
    } catch (e) {
      print('Error loading responses: $e');
      if (mounted) {
        setState(() {
          _responses = []; // Empty responses will trigger fallback
          _wordCloudData = WordCloudData(data: []); // Empty word cloud data will trigger fallback
          _isLoading = false;
          _errorMessage = 'Error loading results: ${e.toString()}';
          // Don't override vote count - keep the value set by navigateToResultsScreen
        });
      }
    }
  }

  Future<void> _loadFreshDataFromDatabase() async {
    // Try to fetch real text responses from the database
    List<Map<String, dynamic>> realResponses = [];
    
    try {
      // Query the responses table for text responses to this question
      // Join with countries table to get full country names instead of codes
      final response = await _supabase
          .from('responses')
          .select('''
            text_response, 
            created_at,
            countries!responses_country_code_fkey(country_name_en)
          ''')
          .eq('question_id', widget.question['id'])
          .not('text_response', 'is', null)
          .order('created_at', ascending: false);
      
      if (response != null && response.isNotEmpty) {
        // Convert to the format expected by the rest of the code
        realResponses = response.map((r) => {
          'text_response': r['text_response'],
          'country': r['countries']?['country_name_en'] ?? 'Unknown', // Use full country name
          'created_at': r['created_at'],
        }).toList();
        
        print('Found ${realResponses.length} real text responses from database');
      } else {
        print('No text responses found in database for this question');
      }
    } catch (dbError) {
      print('Error fetching responses from database: $dbError');
      // realResponses remains empty, will trigger fallback
    }
    
    // Also check if responses are already in the question data (from previous submissions)
    if (widget.question['responses'] != null) {
      final questionResponses = widget.question['responses'] as List<dynamic>?;
      if (questionResponses != null) {
        final textResponses = questionResponses
            .where((r) => r['text_response'] != null && r['text_response'].toString().trim().isNotEmpty)
            .map((r) => Map<String, dynamic>.from(r))
            .toList();
        
        // Merge with database responses, avoiding duplicates
        for (var localResponse in textResponses) {
          // Check if this response is already in realResponses based on content and timestamp
          // Use a more flexible duplicate check - if timestamps are within 5 seconds, consider them the same
          bool isDuplicate = realResponses.any((dbResponse) {
            if (dbResponse['text_response'] != localResponse['text_response']) return false;
            
            // If timestamps are both available, check if they're close enough
            if (dbResponse['created_at'] != null && localResponse['created_at'] != null) {
              try {
                final dbTime = DateTime.parse(dbResponse['created_at']);
                final localTime = DateTime.parse(localResponse['created_at']);
                final timeDiff = dbTime.difference(localTime).abs();
                // If the same text and within 5 seconds, consider it a duplicate
                return timeDiff.inSeconds < 5;
              } catch (e) {
                // If parsing fails, fall back to exact match
                return dbResponse['created_at'] == localResponse['created_at'];
              }
            }
            
            // If timestamps not available or same, check exact match
            return dbResponse['created_at'] == localResponse['created_at'];
          });
          
          if (!isDuplicate) {
            realResponses.add(localResponse);
          }
        }
        
        print('Added ${textResponses.length} responses from question data (total: ${realResponses.length})');
      }
    }
    
    // Generate word cloud data from real responses only
    final wordCloudData = _generateWordCloudData(realResponses);
    print('Generated word cloud data with ${realResponses.length} real responses');

    if (mounted) {
      setState(() {
        _responses = realResponses;
        _wordCloudData = wordCloudData;
        _isLoading = false;
        _lastResponseCount = realResponses.length;
        _lastUpdated = DateTime.now();
        // Don't override vote count - it should already be set correctly by navigateToResultsScreen
      });
    }
  }

  void _startPolling() {
    // Cancel existing timer if any
    _pollTimer?.cancel();
    
    _pollTimer = Timer.periodic(Duration(seconds: 5), (timer) async {
      if (!mounted) {
        timer.cancel();
        _pollTimer = null;
        return;
      }
      await _checkForUpdates();
    });
  }

  Future<void> _checkForUpdates() async {
    try {
      // Get current response count from database
      final response = await _supabase
          .from('responses')
          .select('id')
          .eq('question_id', widget.question['id'])
          .not('text_response', 'is', null);
      
      final currentCount = response?.length ?? 0;
      
      // Check if there's a significant change (>5% difference)
      final percentChange = (_lastResponseCount > 0) 
          ? ((currentCount - _lastResponseCount).abs() / _lastResponseCount) 
          : (currentCount > 0 ? 1.0 : 0.0);
      
      if (percentChange > 0.05) {
        print('Significant change detected: $currentCount vs $_lastResponseCount (${(percentChange * 100).toStringAsFixed(1)}% change)');
        if (mounted) {
          await _refreshData();
        }
      }
    } catch (e) {
      print('Error checking for updates: $e');
    }
  }

  Future<void> _refreshData() async {
    try {
      print('Auto-refreshing text responses for question ID: ${widget.question['id']}');
      
      // Fetch fresh text responses from the database
      final response = await _supabase
          .from('responses')
          .select('''
            text_response, 
            created_at,
            countries!responses_country_code_fkey(country_name_en)
          ''')
          .eq('question_id', widget.question['id'])
          .not('text_response', 'is', null)
          .order('created_at', ascending: false);
      
      if (response != null && response.isNotEmpty) {
        // Convert to the format expected by the rest of the code
        final freshResponses = response.map((r) => {
          'text_response': r['text_response'],
          'country': r['countries']?['country_name_en'] ?? 'Unknown',
          'created_at': r['created_at'],
        }).toList();
        
        // Generate word cloud data from fresh responses
        final wordCloudData = _generateWordCloudData(freshResponses);
        
        if (mounted) {
          setState(() {
            _responses = freshResponses;
            _wordCloudData = wordCloudData;
            _lastResponseCount = freshResponses.length;
            // Don't override vote count - let answer screen handle vote count updates
            // widget.question['votes'] = freshResponses.length;
            _lastUpdated = DateTime.now();
          });
          
          print('Auto-refreshed with ${freshResponses.length} text responses');
        }
      }
    } catch (e) {
      print('Error auto-refreshing data: $e');
    }
  }

  void _handleReturnToFeed() {
    // Simple scroll restoration - just remember where the user started
    Map<String, dynamic>? scrollInfo;
    
    if (widget.feedContext != null) {
      // Use the original question ID from feedContext for position storage lookup
      final originalId = widget.feedContext!.originalQuestionId ?? widget.question['id'];
      
      scrollInfo = {
        'type': 'scroll_to_question',
        'question_id': originalId, // For looking up stored scroll position
      };
    }
    
    // Navigate back to the home screen
    Navigator.of(context).popUntil((route) => route.isFirst);
    
    // Use event system to communicate scroll position to home screen
    if (scrollInfo != null) {
      ScrollPositionEvent.notifyScrollRequest(scrollInfo);
    }
  }

  WordCloudData _generateWordCloudData(List<dynamic> responses) {
    if (responses.isEmpty) {
      print('No responses to generate word cloud from');
      return WordCloudData(data: []);
    }
    
    // Simple word frequency counter
    final wordFreq = <String, int>{};
    final stopWords = {
      "the", "be", "to", "of", "and", "a", "in", "that", "have", "i",
      "it", "for", "not", "on", "with", "he", "as", "you", "do", "at",
      "this", "but", "his", "by", "from", "they", "we", "say", "her", "she",
      "or", "an", "will", "my", "one", "all", "would", "there", "their", "what",
      "so", "up", "out", "if", "about", "who", "get", "which", "go", "me",
      "when", "make", "can", "like", "time", "no", "just", "him", "know", "take",
      "people", "into", "year", "your", "good", "some", "could", "them", "see", "other",
      "than", "then", "now", "look", "only", "come", "its", "over", "think", "also",
      "back", "after", "use", "two", "how", "our", "work", "first", "well", "way",
      "even", "new", "want", "because", "any", "these", "give", "day", "most", "us",
      "are", "is", "was", "were", "am", "been", "being", "has", "had", "having", 
      "do", "does", "did", "doing", "will", "would", "should", "could", "may", 
      "might", "must", "shall", "can", "im", "dont", "lot", "very", "really"
    };
    
    // Initialize profanity filter
    final profanityFilter = ProfanityFilterService();

    try {
      // Process each response
      for (var response in responses) {
        final responseMap = Map<String, dynamic>.from(response);
        final text = responseMap['text_response'] as String?;
        if (text == null || text.trim().isEmpty) continue;

        // Split into words and count frequencies
        final words = text.toLowerCase().split(RegExp(r"[^\w']+"));
        for (var word in words) {
          word = word.trim();
          // Skip empty words
          if (word.isEmpty) continue;
          
          // For very short responses (<= 5), include all words except profanity
          if (responses.length <= 5) {
            if (!profanityFilter.containsProfanity(word)) {
              wordFreq[word] = (wordFreq[word] ?? 0) + 1;
            }
          } else {
            // For longer responses, use stricter filtering
            if (word.length > 2 && 
                !stopWords.contains(word) && 
                !profanityFilter.containsProfanity(word)) {
              wordFreq[word] = (wordFreq[word] ?? 0) + 1;
            }
          }
        }
      }

      // If we don't have any words, return empty data
      if (wordFreq.isEmpty) {
        print('No words found, skipping word cloud');
        return WordCloudData(data: []);
      }

      // Convert to list and sort by frequency
      final sortedWords = wordFreq.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));

      // Take top 40 words or all words if less than 40
      final List<Map<String, dynamic>> wordCloudDataList = sortedWords
          .take(math.min(40, sortedWords.length))
          .map((entry) {
        return {
          'word': entry.key,
          'value': entry.value.toDouble(),
        };
      }).toList();
      
      return WordCloudData(data: wordCloudDataList);
    } catch (e) {
      print('Error generating word cloud: $e');
      return WordCloudData(data: []);
    }
  }

  Future<void> _reportQuestion() async {
    if (_isReporting || !mounted) return;

    // Check if user is on report cooldown
    final userService = Provider.of<UserService>(context, listen: false);
    if (!userService.canReport()) {
      final cooldownSeconds = userService.getReportCooldownSeconds();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Please wait $cooldownSeconds seconds before reporting another question'),
          backgroundColor: Colors.orange,
          duration: Duration(seconds: 3),
        ),
      );
      return;
    }

    setState(() => _isReporting = true);
    try {
      // Navigate to report question screen
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => ReportQuestionScreen(
            question: widget.question,
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error opening report screen: ${e.toString()}'),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _isReporting = false);
      }
    }
  }

  Future<void> _shareQuestion() async {
    if (!mounted) return;
    
    final questionTitle = widget.question['prompt'] ?? widget.question['title'] ?? 'Check out this question';
    final questionId = widget.question['id']?.toString() ?? '';
    final shareText = questionId.isNotEmpty 
        ? 'Check out this question on Read the Room:\n\n$questionTitle\nhttps://readtheroom.site/question/$questionId'
        : 'Check out this question on Read the Room:\n\n$questionTitle';
    
    try {
      final box = context.findRenderObject() as RenderBox?;
      await Share.share(
        shareText,
        sharePositionOrigin: box != null 
            ? box.localToGlobal(Offset.zero) & box.size
            : null,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error sharing question: ${e.toString()}'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  // Helper method to determine if expand button should be shown
  bool _shouldShowExpandButton(String? descriptionText) {
    // Show expand button only if description exists, is not empty, and would overflow one line
    if (descriptionText == null || descriptionText.isEmpty) {
      return false;
    }
    
    // Use TextPainter to measure if text would overflow one line
    final textPainter = TextPainter(
      text: TextSpan(
        text: descriptionText,
        style: Theme.of(context).textTheme.bodyMedium,
      ),
      maxLines: 1,
      textDirection: TextDirection.ltr,
    );
    
    // Calculate available width (screen width minus card margins and padding)
    final screenWidth = MediaQuery.of(context).size.width;
    final cardPadding = 16.0 * 2; // 16px on each side
    final screenMargin = 16.0 * 2; // 8px margins around cards
    final availableWidth = screenWidth - cardPadding - screenMargin;
    
    textPainter.layout(maxWidth: availableWidth);
    
    // If the text was truncated (didExceedMaxLines), show the expand button
    return textPainter.didExceedMaxLines;
  }

  Widget _buildGuestModeBanner() {
    return Consumer<GuestUserTrackingService>(
      builder: (context, guestService, child) {
        return Container(
          width: double.infinity,
          padding: EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.orange.withOpacity(0.05),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.orange.withOpacity(0.3)),
          ),
          child: Row(
            children: [
              Icon(Icons.visibility, color: Colors.orange, size: 20),
              SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      guestService.getGuestViewTitle(),
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Colors.orange,
                        fontSize: 14,
                      ),
                    ),
                    Text(
                      guestService.getRemainingViewsText(),
                      style: TextStyle(
                        color: Colors.orange.withOpacity(0.8),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              TextButton(
                onPressed: () {
                  Navigator.pushNamed(context, '/authentication');
                },
                child: Text(
                  'Authenticate',
                  style: TextStyle(
                    color: Colors.orange,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildQuestionCard() {
    final questionText = widget.question['title'] ?? widget.question['prompt'] ?? 'No Title';
    final descriptionText = widget.question['description'];
    
    return Card(
      child: Padding(
        padding: EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Question title - always shown in full
            Text(
              questionText,
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            if (descriptionText != null) ...[
              SizedBox(height: 8),
              InkWell(
                onTap: _shouldShowExpandButton(descriptionText) ? () {
                  setState(() {
                    _isQuestionExpanded = !_isQuestionExpanded;
                  });
                } : null,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      descriptionText,
                      style: Theme.of(context).textTheme.bodyMedium,
                      maxLines: _isQuestionExpanded ? null : 1,
                      overflow: _isQuestionExpanded ? TextOverflow.visible : TextOverflow.ellipsis,
                    ),
                    if (_shouldShowExpandButton(descriptionText)) ...[
                      SizedBox(height: 4),
                      Text(
                        _isQuestionExpanded ? '(show less)' : '(show more)',
                        style: TextStyle(
                          color: Theme.of(context).primaryColor,
                          fontWeight: FontWeight.w500,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
            SizedBox(height: 16),
            
            // Categories
            Wrap(
              spacing: 8.0,
              runSpacing: 8.0,
              children: [
                // Show categories if available
                if (widget.question['categories'] != null)
                  ...((widget.question['categories'] as List<dynamic>?) ?? []).map((categoryData) {
                    final categoryName = categoryData is String 
                        ? categoryData 
                        : categoryData['name']?.toString() ?? 'Unknown';
                    return CategoryNavigation.buildClickableCategoryChip(
                      context,
                      categoryName,
                    );
                  }).toList(),
                if (widget.question['nsfw'] == true)
                  Chip(
                    label: Text('18+', style: TextStyle(fontSize: 12)),
                    backgroundColor: Colors.red.withOpacity(0.1),
                  ),
              ],
            ),
            
            // Private question disclaimer banner
            if (isPrivateQuestion) ...[
              SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.orange.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: Colors.orange.withOpacity(0.3),
                    width: 1,
                  ),
                ),
                child: Row(
                  children: [
                    Icon(Icons.lock, color: Colors.orange, size: 20),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'This is a private question. Only those with the link can view and answer it',
                        style: TextStyle(
                          color: Colors.orange.shade700,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            
            SizedBox(height: 12),
            
            SizedBox(height: 8),
            Row(
              children: [
                // Show link icon for private questions, otherwise show location targeting
                if (isPrivateQuestion) ...[
                  GestureDetector(
                    onTap: () {
                      showDialog(
                        context: context,
                        builder: (context) => AlertDialog(
                          title: Text('Private Question'),
                          content: Text('This is a private question that can only be accessed via a direct link.'),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.of(context).pop(),
                              child: Text('OK'),
                            ),
                          ],
                        ),
                      );
                    },
                    child: Icon(
                      Icons.link,
                      size: 16,
                      color: Theme.of(context).primaryColor,
                    ),
                  ),
                  SizedBox(width: 6),
                ] else ...[
                  Consumer<LocationService>(
                    builder: (context, locationService, child) {
                      final targeting = widget.question['targeting_type'] ?? 'globe';
                      IconData targetingIcon;
                      String dialogTitle;
                      String dialogMessage;
                      
                      switch (targeting) {
                        case 'globe':
                          targetingIcon = Icons.public;
                          dialogTitle = 'Global Question';
                          dialogMessage = 'This question was addressed to everyone in the world.';
                          break;
                                                      case 'country':
                                  targetingIcon = Icons.flag;
                                  final countryName = widget.question['country_name'] ?? 
                                                     widget.question['countries']?['country_name_en'] ?? 
                                                     locationService.selectedCountry ?? 
                                                     'a specific country';
                                  dialogTitle = 'Country Question';
                                  dialogMessage = 'This question was addressed to everyone in $countryName.';
                                  break;
                                case 'city':
                                  targetingIcon = Icons.location_city;
                                  final cityName = widget.question['city_name'] ?? 
                                                 widget.question['cities']?['name'] ?? 
                                                 locationService.selectedCity?['name'] ?? 
                                                 'a specific city';
                                  dialogTitle = 'City Question';
                                  dialogMessage = 'This question was addressed to everyone in $cityName.';
                                  break;
                        default:
                          targetingIcon = Icons.public;
                          dialogTitle = 'Global Question';
                          dialogMessage = 'This question was addressed to everyone in the world.';
                      }
                      
                      return GestureDetector(
                        onTap: () {
                          showDialog(
                            context: context,
                            builder: (context) => AlertDialog(
                              title: Text(dialogTitle),
                              content: Text(dialogMessage),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.of(context).pop(),
                                  child: Text('OK'),
                                ),
                              ],
                            ),
                          );
                        },
                        child: Icon(
                          targetingIcon,
                          size: 16,
                          color: Theme.of(context).primaryColor,
                        ),
                      );
                    },
                  ),
                  SizedBox(width: 6),
                ],
                Text(
                  'Votes: ${widget.question['votes'] ?? 0} • ${_formatDateOnly(widget.question['created_at'] ?? widget.question['timestamp'])}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSummaryCard() {
    // Only show summary if it exists in the database
    final summary = widget.question['summary'] as String?;
    
    if (summary == null || summary.trim().isEmpty) {
      return SizedBox.shrink(); // Return empty widget if no summary
    }
    
    return Card(
      child: Padding(
        padding: EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Global Summary',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            SizedBox(height: 8),
            Text(
              summary,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }


  @override
  Widget buildResultsScreen(BuildContext context) {
    print('Building TextResultsScreen with ${_responses.length} responses');
    print('Question data: ${widget.question}');
    
    if (_isLoading) {
      return Scaffold(
        appBar: AppBar(
          title: Text(_appBarTitle),
        ),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    // Check if we have enough data for a word cloud
    final bool hasEnoughDataForWordCloud = _responses.length >= 10 && _wordCloudData.data.length >= 10;
    final bool hasFewResponses = _responses.length < 10;

    return Scaffold(
        appBar: AppBar(
        title: Text(_appBarTitle),
        actions: [
          Consumer<UserService>(
            builder: (context, userService, child) {
              final isSaved = userService.savedQuestions
                  .any((q) => q['id'] == widget.question['id']);
              return IconButton(
                icon: Icon(
                  isSaved ? Icons.bookmark : Icons.bookmark_border,
                  color: isSaved ? Theme.of(context).primaryColor : null,
                ),
                onPressed: () {
                  if (isSaved) {
                    userService.removeSavedQuestion(widget.question['id']);
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Row(
                          children: [
                            Icon(Icons.bookmark_border, color: Colors.white, size: 20),
                            SizedBox(width: 8),
                            Text('Question removed from saved'),
                          ],
                        ),
                        backgroundColor: Theme.of(context).primaryColor,
                      ),
                    );
                  } else {
                    userService.addSavedQuestion(widget.question);
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Row(
                          children: [
                            Icon(Icons.bookmark, color: Colors.white, size: 20),
                            SizedBox(width: 8),
                            Text('Question saved'),
                          ],
                        ),
                        backgroundColor: Theme.of(context).primaryColor,
                      ),
                    );
                    // Auto-subscribe to saved question
                    AutoSubscriptionHelper.autoSubscribeToSavedQuestion(context, widget.question);
                  }
                },
              );
            },
          ),
          // Notification bell for subscribing to question updates
          NotificationBell(question: widget.question),
          // Show delete icon only if current user is the author
          Consumer<QuestionService>(
            builder: (context, questionService, child) {
              if (questionService.isCurrentUserAuthor(widget.question)) {
                return IconButton(
                  icon: Icon(Icons.delete),
                  onPressed: _showDeleteConfirmation,
                );
              }
              return SizedBox.shrink();
            },
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildQuestionCard(),
            if (widget.isGuestMode) ...[
              const SizedBox(height: 8),
              _buildGuestModeBanner(),
            ],
            const SizedBox(height: 16),
            
            // Show word cloud section - always show if there are responses
            if (_responses.isNotEmpty) ...[
              // Question prompt in larger white text
              Center(
                child: Text(
                  widget.question['prompt'] ?? widget.question['title'] ?? 'Question',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    color: Theme.of(context).brightness == Brightness.dark 
                        ? Colors.white 
                        : Colors.black,
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                  ),
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Text(
                      isPrivateQuestion
                        ? 'Responses (Private)'
                        : isCityTargeted
                          ? 'Responses ($cityName)'
                          : isCountryTargeted && _selectedCountry != null
                            ? 'Responses ($_selectedCountry)'
                            : 'Responses ${_selectedCountry != null ? ' ($_selectedCountry)' : ' (Global)'}',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Colors.grey[600],
                        fontSize: 14,
                      ),
                    ),
                  ),
                  if (_shouldShowFilterButton() && _getUniqueCountriesWithResponses().length > 1)
                    TextButton.icon(
                      onPressed: _showCountryFilterDialog,
                      icon: Icon(Icons.filter_list, size: 18),
                      label: Text('Filter'),
                      style: TextButton.styleFrom(
                        foregroundColor: Theme.of(context).primaryColor,
                        side: _selectedCountry != null 
                            ? BorderSide(color: Theme.of(context).primaryColor, width: 2)
                            : null,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              _renderWordCloud(),
              const SizedBox(height: 16),
            ],
            
            // Question Reactions
            QuestionReactionsWidget(
              questionId: widget.question['id'].toString(),
              useDummyData: false,
              margin: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            ),
            
            const SizedBox(height: 16),
            
            // Only show summary card if summary exists in database
            if (widget.question['summary'] != null && 
                (widget.question['summary'] as String).trim().isNotEmpty) ...[
              _buildSummaryCard(),
              const SizedBox(height: 16),
            ],
            
            // No responses message - only show if there are no responses
            if (_responses.isEmpty) ...[
              Center(
                child: Padding(
                  padding: const EdgeInsets.all(32.0),
                  child: Column(
                    children: [
                      Icon(Icons.comment_bank_outlined, size: 48, color: Colors.grey[400]),
                      const SizedBox(height: 16),
                      Text(
                        'No responses yet',
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          color: Colors.grey[600],
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Be the first to answer this question!',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Colors.grey[500],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
            
            
            // Linked Questions Section
            LinkedQuestionsSection(
              questionId: widget.question['id']?.toString() ?? '',
              comments: _comments,
              useDummyData: false, // Use real data
              originalFeedContext: widget.feedContext,
              fromSearch: widget.fromSearch,
              fromUserScreen: widget.fromUserScreen,
              margin: EdgeInsets.zero, // Remove default margin to align with comments section
            ),
            
            const SizedBox(height: 16), // Add spacing between sections
            
            // Comments Section - always at the end
            CommentsSection(
              key: _commentsSectionKey,
              questionId: widget.question['id'].toString(),
              onAddCommentTap: _handleAddComment,
              useDummyData: false, // Use real data
              questionContext: widget.question,
              margin: EdgeInsets.zero, // Remove default margin to align with other widgets
              onCommentsLoaded: (comments) {
                setState(() {
                  _comments = comments;
                });
              },
            ),
            
            // Swipe to next indicator
            const SizedBox(height: 32),
            Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Swipe to next',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Colors.grey[600],
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(
                    Icons.swipe_left,
                    color: Colors.grey[600],
                    size: 16,
                  ),
                ],
              ),
            ),
            
            // Bottom action buttons
            const SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                TextButton.icon(
                  icon: const Icon(Icons.share),
                  label: const Text('Share'),
                  onPressed: _shareQuestion,
                ),
                TextButton.icon(
                  icon: const Icon(Icons.report),
                  label: const Text('Report'),
                  onPressed: _isReporting ? null : _reportQuestion,
                ),
              ],
            ),
            const SizedBox(height: 100), // Extra space for bottom navigation
          ],
          ),
        ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: 0, // Default to Home
        onTap: (index) {
          if (index == 0) {
            // Home - clear stack and go to home
            Navigator.pushNamedAndRemoveUntil(context, '/', (route) => false);
          } else if (index == 1) {
            // Search - clear stack and go to home
            Navigator.pushNamedAndRemoveUntil(context, '/', (route) => false);
          } else if (index == 2) {
            // Navigate to activity tab
            Navigator.pushAndRemoveUntil(
              context,
              MaterialPageRoute(builder: (context) => MainScreen(initialIndex: 2)),
              (route) => false,
            );
          } else if (index == 3) {
            // Me - clear stack and go to user screen
            Navigator.pushNamedAndRemoveUntil(context, '/user', (route) => false);
          }
        },
        selectedItemColor: Theme.of(context).primaryColor,
        unselectedItemColor: Colors.grey,
        type: BottomNavigationBarType.fixed,
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.home), label: 'Home'),
          BottomNavigationBarItem(icon: Icon(Icons.search), label: 'Search'),
          BottomNavigationBarItem(icon: Icon(Icons.notifications_outlined), label: 'Activity'),
          BottomNavigationBarItem(icon: Icon(Icons.person), label: 'Me'),
        ],
      ),
    );
  }

  // Helper method to calculate average response length in words
  double _calculateAverageResponseLength(List<Map<String, dynamic>> responses) {
    if (responses.isEmpty) return 0.0;
    
    int totalWords = 0;
    int validResponses = 0;
    
    for (final response in responses) {
      final text = response['text_response'] as String? ?? '';
      if (text.trim().isNotEmpty) {
        final words = text.trim().split(RegExp(r'\s+'));
        totalWords += words.length;
        validResponses++;
      }
    }
    
    return validResponses > 0 ? totalWords / validResponses : 0.0;
  }

  // Helper method to render the word cloud or a fallback
  Widget _renderWordCloud() {
    if (!mounted) {
      print('Not rendering word cloud because widget is not mounted');
      return Container(); // Return empty container if widget is not mounted
    }
    
    // Use filtered responses based on selected country
    final responsesToUse = filteredResponses;
    final isGlobalView = _selectedCountry == null;
    
    // Calculate average response length
    final averageLength = _calculateAverageResponseLength(responsesToUse);
    
    // For any view with <10 responses OR average length ≤5 words, show raw responses directly instead of word cloud
    if (responsesToUse.length < 10 || averageLength <= 5.0) {
      if (responsesToUse.isNotEmpty) {
        return _buildRawResponsesList(responsesToUse);
      }
    }
    
    // Check if we have enough real data for a proper word cloud (minimum 10 responses AND >5 words average)
    final bool hasEnoughData = responsesToUse.length >= 10 && averageLength > 5.0;
    
    if (hasEnoughData) {
      // Generate word cloud data from filtered responses
      final wordCloudData = _generateWordCloudData(responsesToUse);
      
      // Check if word cloud generation was successful
      if (wordCloudData.data.isNotEmpty) {
        // Show teal word cloud with real data
        try {
          // Normalize the data for proper rendering
          final List<Map<String, dynamic>> normalizedData = [];
          
          // Find the max value to normalize against
          double maxValue = 1.0; // Start with 1.0 to avoid division by zero
          for (final item in wordCloudData.data) {
            final value = item['value'] is double 
                ? (item['value'] as double) 
                : double.parse(item['value'].toString());
            if (value > maxValue) maxValue = value;
          }
          
          // Normalize values to a reasonable range (10-40) to avoid extreme sizes
          for (final item in wordCloudData.data) {
            final word = item['word'] as String;
            final rawValue = item['value'] is double 
                ? (item['value'] as double) 
                : double.parse(item['value'].toString());
            
            // Scale to 10-40 range (ensures minimum font size of 10)
            final scaledValue = 10 + (rawValue / maxValue * 30);
            
            normalizedData.add({
              'word': word,
              'value': scaledValue,
            });
          }
          
          // Only proceed if we have enough normalized data
          if (normalizedData.length < 1) {
            throw Exception('Not enough valid words for word cloud');
          }
          
          final normalizedWordCloudData = WordCloudData(data: normalizedData);
          
          return ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Container(
              height: 300,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                borderRadius: BorderRadius.circular(12),
                boxShadow: ThemeUtils.getCardShadow(context),
              ),
              child: Center(
                child: WordCloudView(
                  key: ValueKey('wordcloud_${_selectedCountry ?? 'global'}_${responsesToUse.length}'),
                  data: normalizedWordCloudData,
                  mapwidth: 270,
                  mapheight: 270,
                  colorlist: [
                    Colors.teal[800]!,
                    Colors.teal[700]!,
                    Colors.teal[600]!,
                    Colors.teal[500]!,
                    Colors.teal[400]!,
                  ],
                  mapcolor: Theme.of(context).colorScheme.surface,
                  shape: WordCloudCircle(radius: 115), 
                  mintextsize: 10,
                  maxtextsize: 40,
                  attempt: 100,
                ),
              ),
            ),
          );
        } catch (e) {
          print('Error rendering teal word cloud: $e');
          // If global view and we have responses, show raw responses instead of "Not Enough Data"
          if (isGlobalView && responsesToUse.isNotEmpty) {
            return _buildRawResponsesList(responsesToUse);
          }
          // Fall through to "Not Enough Data" fallback for country-specific views
        }
      }
    }
    
    // If we have responses but not enough for word cloud, show raw responses
    if (responsesToUse.isNotEmpty) {
      return _buildRawResponsesList(responsesToUse);
    }
    
    // Final fallback for no responses at all - simple centered text
    return Container(
      height: 300,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface, 
        borderRadius: BorderRadius.circular(12),
        boxShadow: ThemeUtils.getCardShadow(context),
      ),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              'No Responses Yet',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                color: Colors.grey[600],
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _selectedCountry != null 
                  ? 'No responses from $_selectedCountry yet'
                  : 'Be the first to answer this question!',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Colors.grey[500],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Helper method to build a list of raw responses
  Widget _buildRawResponsesList(List<Map<String, dynamic>> responses) {
    // Group responses by text content (case-insensitive)
    final Map<String, List<Map<String, dynamic>>> groupedResponses = {};
    final Map<String, String> preferredCasing = {}; // Maps lowercase key to preferred display text
    
    for (final response in responses) {
      final text = response['text_response'] as String? ?? '';
      if (text.trim().isNotEmpty) {
        final lowercaseKey = text.trim().toLowerCase();
        
        if (!groupedResponses.containsKey(lowercaseKey)) {
          groupedResponses[lowercaseKey] = [];
          // Choose preferred casing: first non-all-lowercase version, or first occurrence
          preferredCasing[lowercaseKey] = text.trim();
        } else {
          // Update preferred casing if current text is not all lowercase and stored one is
          final currentText = text.trim();
          final storedText = preferredCasing[lowercaseKey]!;
          if (storedText == storedText.toLowerCase() && currentText != currentText.toLowerCase()) {
            preferredCasing[lowercaseKey] = currentText;
          }
        }
        groupedResponses[lowercaseKey]!.add(response);
      }
    }

    // Convert to list and sort by count (most frequent first)
    final List<MapEntry<String, List<Map<String, dynamic>>>> sortedEntries = 
        groupedResponses.entries.toList()
          ..sort((a, b) => b.value.length.compareTo(a.value.length));

    // Separate grouped responses (count > 1) from individual responses
    final groupedEntries = sortedEntries.where((entry) => entry.value.length > 1).toList();
    final individualEntries = sortedEntries.where((entry) => entry.value.length == 1).toList();

    // Get the most recent 15 individual responses
    final List<Map<String, dynamic>> recentIndividualResponses = [];
    for (final entry in individualEntries) {
      recentIndividualResponses.addAll(entry.value);
    }
    // Sort by date (most recent first) and take 15
    recentIndividualResponses.sort((a, b) {
      final aTime = DateTime.tryParse(a['created_at'] ?? '') ?? DateTime(1970);
      final bTime = DateTime.tryParse(b['created_at'] ?? '') ?? DateTime(1970);
      return bTime.compareTo(aTime);
    });
    final recentResponses = recentIndividualResponses.take(15).toList();

    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        boxShadow: ThemeUtils.getCardShadow(context),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            height: 300, // Increased height to accommodate more content
            child: (groupedEntries.isEmpty && recentResponses.isEmpty)
                ? Center(
                    child: Text(
                      'No responses to display',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Colors.grey[600],
                      ),
                    ),
                  )
                : ListView(
                    padding: const EdgeInsets.all(16.0),
                    children: [
                      // Show grouped responses first (with counts) - only if they exist
                      if (groupedEntries.isNotEmpty) ...[
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12.0),
                          child: Text(
                            'Popular Responses',
                            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                              color: Theme.of(context).primaryColor,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        ...groupedEntries.map((entry) {
                          final lowercaseKey = entry.key;
                          final responseGroup = entry.value;
                          final count = responseGroup.length;
                          final displayText = preferredCasing[lowercaseKey] ?? lowercaseKey;
                          
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8.0),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: Text(
                                    displayText,
                                    style: Theme.of(context).textTheme.bodyMedium,
                                    maxLines: 3,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: Theme.of(context).primaryColor,
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Text(
                                    'x$count',
                                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                      color: Colors.white,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 12,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          );
                        }).toList(),
                        
                        // Add divider between grouped and individual responses (only if both exist)
                        if (recentResponses.isNotEmpty) 
                          const Divider(height: 24),
                      ],
                      
                      // Show recent individual responses (only if they exist)
                      if (recentResponses.isNotEmpty) ...[
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12.0),
                          child: Text(
                            'Recent Responses',
                            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                              color: Theme.of(context).primaryColor,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        ...recentResponses.map((response) {
                          final text = response['text_response'] as String? ?? '';
                          final createdAt = response['created_at'] as String?;
                          
                          String timeAgo = 'Unknown time';
                          if (createdAt != null) {
                            try {
                              final dateTime = DateTime.parse(createdAt);
                              final now = DateTime.now();
                              final difference = now.difference(dateTime);
                              
                              if (difference.inDays > 0) {
                                timeAgo = '${difference.inDays}d ago';
                              } else if (difference.inHours > 0) {
                                timeAgo = '${difference.inHours}h ago';
                              } else if (difference.inMinutes > 0) {
                                timeAgo = '${difference.inMinutes}m ago';
                              } else {
                                timeAgo = 'Just now';
                              }
                            } catch (e) {
                              timeAgo = 'Unknown time';
                            }
                          }
                          
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 6.0),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  text,
                                  style: Theme.of(context).textTheme.bodyMedium,
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  timeAgo,
                                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: Colors.grey[600],
                                  ),
                                ),
                              ],
                            ),
                          );
                        }).toList(),
                      ],
                    ],
                  ),
          ),
          // Show summary of hidden responses
          if (recentIndividualResponses.length > 15 || groupedEntries.length > 20)
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Text(
                'Showing ${groupedEntries.length} popular responses and ${recentResponses.length} recent responses',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Colors.grey[600],
                  fontStyle: FontStyle.italic,
                ),
                textAlign: TextAlign.center,
              ),
            ),
        ],
      ),
    );
  }

  // Helper method to get the proper question ID for Supabase
  Future<String> _getProperQuestionId(dynamic originalId) async {
    final originalIdStr = originalId.toString();
    
    // If it's already a valid UUID, use it directly
    if (_isUuid(originalIdStr)) {
      return originalIdStr;
    }
    
    // Otherwise generate a UUID based on the string
    return _generateUuidFromString(originalIdStr);
  }
  
  // Helper method to check if a string is a valid UUID
  bool _isUuid(String str) {
    return RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
        .hasMatch(str.toLowerCase());
  }
  
  // Helper method to generate a UUID from a string - must match the one in QuestionService
  String _generateUuidFromString(String str) {
    final random = Random(str.hashCode);
    return '${_generateRandomHex(random, 8)}-${_generateRandomHex(random, 4)}-${_generateRandomHex(random, 4)}-${_generateRandomHex(random, 4)}-${_generateRandomHex(random, 12)}';
  }
  
  String _generateRandomHex(Random random, int length) {
    final buffer = StringBuffer();
    for (var i = 0; i < length; i++) {
      buffer.write(random.nextInt(16).toRadixString(16));
    }
    return buffer.toString();
  }

  String _formatDateOnly(String? dateTimeStr) {
    if (dateTimeStr == null) return 'Unknown date';
    
    try {
      final dateTime = DateTime.parse(dateTimeStr);
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final yesterday = today.subtract(Duration(days: 1));
      final questionDate = DateTime(dateTime.year, dateTime.month, dateTime.day);
      
      if (questionDate == today) {
        return 'Today';
      } else if (questionDate == yesterday) {
        return 'Yesterday';
      } else {
        // Format as "Jan 15, 2024"
        const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
                       'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
        return '${months[dateTime.month - 1]} ${dateTime.day}, ${dateTime.year}';
      }
    } catch (e) {
      return 'Unknown date';
    }
  }

  String _formatTimeAgo(DateTime dateTime) {
    final now = DateTime.now();
    final difference = now.difference(dateTime);
    
    if (difference.inMinutes < 1) {
      return '<1 min ago';
    } else if (difference.inMinutes < 60) {
      return '${difference.inMinutes} min${difference.inMinutes == 1 ? '' : 's'} ago';
    } else if (difference.inHours < 24) {
      return '${difference.inHours} hr${difference.inHours == 1 ? '' : 's'} ago';
    } else {
      return '${difference.inDays} day${difference.inDays == 1 ? '' : 's'} ago';
    }
  }

  List<Map<String, dynamic>> get filteredResponses {
    // For private questions, never filter by country - always show all responses
    if (isPrivateQuestion || _selectedCountry == null) {
      return _responses;
    }
    return _responses.where((r) => r['country'] == _selectedCountry).toList();
  }

  void _onCountrySelected(String? country) {
    // Dismiss any current snackbar before showing a new one
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    
    if (country == null) {
      setState(() {
        _selectedCountry = country;
      });
      // Show snackbar for Global selection
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Showing global responses'),
          backgroundColor: Theme.of(context).primaryColor,
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }
    
    // Check if there are actual responses from this country
    final countryResponses = _responses.where((r) => r['country'] == country).toList();
    
    if (countryResponses.isEmpty) {
      // Show message that there are no responses from this country
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('No responses from $country yet'),
          backgroundColor: Colors.orange,
          duration: Duration(seconds: 3),
        ),
      );
      return; // Don't change the selection
    }
    
    // For countries with < 10 responses, show an informative message
    if (countryResponses.length < 10) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Showing responses from $country'),
          backgroundColor: Theme.of(context).primaryColor,
          duration: Duration(seconds: 2),
        ),
      );
    }
    
    setState(() {
      _selectedCountry = country;
      // Force word cloud refresh by clearing the cached data
      // The _renderWordCloud method will regenerate it based on filtered responses
    });
    
    print('Country selected: $country, filtered responses: ${countryResponses.length}');
  }

  // Helper method to check if this question is city-targeted
  bool get isCityTargeted {
    return widget.question['targeting_type']?.toString().toLowerCase() == 'city';
  }

  // Helper method to check if this question is country-targeted
  bool get isCountryTargeted {
    return widget.question['targeting_type']?.toString().toLowerCase() == 'country';
  }

  // Helper method to check if this question is private
  bool get isPrivateQuestion {
    return widget.question['is_private'] == true;
  }

  // Helper method to get the city name for city-targeted questions
  String get cityName {
    if (!isCityTargeted) {
      return 'World';
    }
    
    // First try to get city name from question data (if it was joined)
    if (widget.question['city_name'] != null) {
      return widget.question['city_name'].toString();
    }
    
    // Try the joined cities data
    if (widget.question['cities'] != null && widget.question['cities']['name'] != null) {
      return widget.question['cities']['name'].toString();
    }
    
    // Use the fetched city name if available
    if (_actualCityName != null) {
      return _actualCityName!;
    }
    
    // If still loading, show loading state
    if (_loadingCityName) {
      return 'Loading...';
    }
    
    // Fallback to 'World' if we can't get the city name
    return 'World';
  }

  // Helper method to get country name from country code
  String _getCountryNameFromCode(String countryCode) {
    // Common ISO_A2 country codes to names
    final countryCodeToName = {
      'US': 'United States',
      'GB': 'United Kingdom',
      'CA': 'Canada',
      'AU': 'Australia',
      'DE': 'Germany',
      'FR': 'France',
      'JP': 'Japan',
      'CN': 'China',
      'IN': 'India',
      'BR': 'Brazil',
      'MX': 'Mexico',
      'ES': 'Spain',
      'IT': 'Italy',
      'KR': 'South Korea',
      'RU': 'Russia',
      'NL': 'Netherlands',
      'CH': 'Switzerland',
      'SE': 'Sweden',
      'NO': 'Norway',
      'DK': 'Denmark',
      'FI': 'Finland',
      'PL': 'Poland',
      'PT': 'Portugal',
      'IE': 'Ireland',
      'NZ': 'New Zealand',
      'SG': 'Singapore',
      'HK': 'Hong Kong',
      'MY': 'Malaysia',
      'TH': 'Thailand',
      'ID': 'Indonesia',
      'PH': 'Philippines',
      'VN': 'Vietnam',
      'EG': 'Egypt',
      'ZA': 'South Africa',
      'NG': 'Nigeria',
      'KE': 'Kenya',
      'AR': 'Argentina',
      'CL': 'Chile',
      'CO': 'Colombia',
      'PE': 'Peru',
      'VE': 'Venezuela',
      'AE': 'United Arab Emirates',
      'SA': 'Saudi Arabia',
      'IL': 'Israel',
      'TR': 'Turkey',
      'GR': 'Greece',
      'OM': 'Oman',
      'AT': 'Austria',
      'BE': 'Belgium',
      'CZ': 'Czech Republic',
      'HU': 'Hungary',
      'UA': 'Ukraine',
      'RO': 'Romania',
      'PK': 'Pakistan',
      'BD': 'Bangladesh',
      'LK': 'Sri Lanka',
    };
    
    return countryCodeToName[countryCode.toUpperCase()] ?? countryCode;
  }

  // Load the actual city name if this is a city-targeted question
  Future<void> _loadCityNameIfNeeded() async {
    if (!isCityTargeted || widget.question['city_id'] == null) {
      return;
    }

    // Check if we already have the city name from joined data
    if (widget.question['cities'] != null && widget.question['cities']['name'] != null) {
      setState(() {
        _actualCityName = widget.question['cities']['name'].toString();
      });
      return;
    }

    // If not, fetch it from the database
    setState(() {
      _loadingCityName = true;
    });

    try {
      final response = await _supabase
          .from('cities')
          .select('name')
          .eq('id', widget.question['city_id'])
          .single();

      if (response != null && response['name'] != null && mounted) {
        setState(() {
          _actualCityName = response['name'].toString();
          _loadingCityName = false;
        });
      }
    } catch (e) {
      print('Error fetching city name: $e');
      if (mounted) {
        setState(() {
          _actualCityName = null; // Will fall back to 'World'
          _loadingCityName = false;
        });
      }
    }
  }

  void _showDeleteConfirmation() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete Question'),
        content: Text('Are you sure you want to delete this question? This action cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(context).pop(); // Close dialog first
              _deleteQuestion(); // Then delete
            },
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: Text('Delete'),
          ),
        ],
      ),
    );
  }

  Future<void> _deleteQuestion() async {
    try {
      final questionService = Provider.of<QuestionService>(context, listen: false);
      final success = await questionService.deleteQuestion(widget.question['id'].toString());
      
      if (success) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Question deleted successfully'),
            backgroundColor: Colors.teal,
          ),
        );
        // Navigate back to home screen
        Navigator.pushNamedAndRemoveUntil(context, '/', (route) => false);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to delete question. Please try again.'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error deleting question: ${e.toString()}'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  // Helper method to record question view for vote count and comment count delta tracking
  Future<void> _recordQuestionView() async {
    try {
      final currentVotes = widget.question['votes'] as int? ?? 0;
      final currentComments = _getCommentCount(widget.question);
      final questionId = widget.question['id'].toString();
      
      print('🔍 Debug: Recording view for question $questionId with $currentVotes votes, $currentComments comments (text results)');
      
      final prefs = await SharedPreferences.getInstance();
      final key = 'question_view_$questionId';
      final now = DateTime.now().millisecondsSinceEpoch;
      
      // Store: timestamp, vote count, comment count at time of view
      await prefs.setString(key, '$now:$currentVotes:$currentComments');
      print('🔍 Debug: Stored view data: $key = $now:$currentVotes:$currentComments');
    } catch (e) {
      print('Error recording question view: $e');
    }
  }
  
  int _getCommentCount(Map<String, dynamic> question) {
    return question['comment_count'] as int? ?? 0;
  }

  Future<void> _handleAddComment() async {
    try {
      final questionTitle = widget.question['prompt']?.toString() ?? 'Question';
      final result = await AddCommentDialog.show(
        context: context,
        questionId: widget.question['id'].toString(),
        questionTitle: questionTitle,
        question: widget.question,
        onCommentAdded: (newComment) {
          // Refresh the comments section immediately
          (_commentsSectionKey.currentState as dynamic)?.refreshComments();
        },
      );

      // No need to show additional snackbar or setState - the dialog handles everything
    } catch (e) {
      print('Error adding comment: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to add comment. Please try again.'),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 3),
          ),
        );
      }
    }
  }
} 