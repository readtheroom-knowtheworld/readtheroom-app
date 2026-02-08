// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/user_service.dart';
import '../services/guest_user_tracking_service.dart';
import '../utils/time_utils.dart';
import 'report_question_screen.dart';
import 'package:share_plus/share_plus.dart';
import 'base_results_screen.dart';
import '../widgets/country_approval_map.dart';
import '../services/question_service.dart';
import '../services/country_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../services/location_service.dart';
import '../services/room_service.dart';
import '../services/room_sharing_service.dart';
import 'dart:math' as math;
import 'dart:math' show Random;
import '../models/category.dart';
import 'dart:async';
import '../widgets/notification_bell.dart';
import '../widgets/swipe_navigation_wrapper.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../utils/category_navigation.dart';
import '../widgets/comments_section.dart';
import '../widgets/add_comment_dialog.dart';
import '../widgets/question_reactions_widget.dart';
import '../widgets/linked_questions_section.dart';
import '../widgets/country_filter_dialog.dart';
import '../widgets/country_comparison_dialog.dart';
import 'main_screen.dart';

class ApprovalResultsScreen extends BaseResultsScreen {
  final FeedContext? feedContext;
  
  const ApprovalResultsScreen({
    Key? key,
    required super.question,
    required super.responses,
    this.feedContext,
    super.fromSearch = false,
    super.fromUserScreen = false,
    super.isGuestMode = false,
  }) : super(key: key, feedContext: feedContext);

  @override
  State<ApprovalResultsScreen> createState() => _ApprovalResultsScreenState();
}

class _ApprovalResultsScreenState extends BaseResultsScreenState<ApprovalResultsScreen> {
  String? selectedCountry;
  List<Map<String, dynamic>> _responsesByCountry = [];
  List<Map<String, dynamic>> _myNetworkResponses = [];
  Map<String, int> _roomResponseCounts = {};
  Map<String, List<Map<String, dynamic>>> _roomResponses = {};
  Map<String, String> _roomNames = {}; // Map room IDs to room names
  QuestionService? _questionService;
  bool _isLoadingMap = true;
  String? _countrySearchQuery;
  final _supabase = Supabase.instance.client;
  bool _isReporting = false;
  String? _errorMessage;
  String? _actualCityName; // Store the fetched city name
  bool _loadingCityName = false;
  Timer? _pollTimer;
  int _lastResponseCount = 0;
  DateTime _lastUpdated = DateTime.now();
  bool _isQuestionExpanded = false; // Track question text expansion
  List<Map<String, dynamic>> _comments = []; // Store comments for linked questions
  final GlobalKey<State<CommentsSection>> _commentsSectionKey = GlobalKey<State<CommentsSection>>();
  int _immediateCheckCount = 0; // Track immediate checks for lower threshold
  final ScrollController _scrollController = ScrollController();
  bool _showQuestionInTitle = false;
  
  // Comparison mode variables
  bool _isComparisonMode = false;
  String? _comparisonCountry1;
  String? _comparisonCountry2;

  // Get Country 1 color based on theme
  Color get _country1Color {
    return Theme.of(context).brightness == Brightness.light 
        ? Theme.of(context).primaryColor 
        : Color(0xFF55C5B4);
  }

  // Get display name for a filter (country/room/network)
  String _getDisplayName(String filter) {
    if (filter == 'My Network') return 'My Network';
    if (filter == 'World') return 'World';
    if (filter.startsWith('Room:')) {
      final roomId = filter.substring(5);
      return _roomNames[roomId] ?? 'Room';
    }
    return filter; // Regular country name
  }

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
           _responsesByCountry.isNotEmpty &&
           _getUniqueCountriesWithResponses().length > 1;
  }

  List<String> _getUniqueCountriesWithResponses() {
    final countries = <String>{};
    for (var response in _responsesByCountry) {
      final country = response['country']?.toString();
      if (country != null && country.isNotEmpty && country != 'Unknown') {
        countries.add(country);
      }
    }
    return countries.toList();
  }

  Map<String, Map<String, dynamic>> _getCountryResponseData() {
    final countryTotalResponses = <String, int>{};
    
    // Count total responses per country
    for (var response in _responsesByCountry) {
      final country = response['country']?.toString() ?? 'Unknown';
      if (country != 'Unknown') {
        countryTotalResponses[country] = (countryTotalResponses[country] ?? 0) + 1;
      }
    }

    // Convert to the format expected by the dialog
    final result = <String, Map<String, dynamic>>{};
    countryTotalResponses.forEach((country, total) {
      if (total > 0) {
        result[country] = {
          'total': total,
        };
      }
    });
    return result;
  }

  Future<void> _showCountryFilterDialog() async {
    final countryData = _getCountryResponseData();
    if (countryData.isEmpty) return;

    final questionTitle = widget.question['prompt'] ?? widget.question['title'] ?? 'Question';
    
    final selectedCountryResult = await CountryFilterDialog.show(
      context: context,
      countryResponses: countryData,
      currentSelectedCountry: selectedCountry,
      questionTitle: questionTitle,
      questionId: widget.question['id'].toString(),
      questionType: 'approval',
      countryAverages: _countryAverages,
      allResponses: _responsesByCountry,
      myNetworkResponseCount: _myNetworkResponses.length, // Pass accurate My Network count
      roomResponseCounts: _roomResponseCounts, // Pass accurate room response counts
      roomNames: _roomNames, // Pass room names for instant display
    );

    if (selectedCountryResult != null || selectedCountryResult == null) {
      // Update the selected country (null means global)
      _onCountrySelected(selectedCountryResult);
    }
  }

  @override
  void initState() {
    super.initState();
    _setupScrollListener();
    
    // Auto-filter to country for country-targeted questions
    if (isCountryTargeted && widget.question['country_code'] != null) {
      selectedCountry = _getCountryNameFromCode(widget.question['country_code']);
    }
    
    _loadMapData();
    _loadCityNameIfNeeded();
    _loadMyNetworkData();
    // Record this question view with current vote count
    _recordQuestionView();
    
    // Auto-set comparison mode for room feed questions
    _autoSetComparisonModeIfFromRoom();
    // Polling is now started conditionally in _loadMapData()
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _pollTimer?.cancel();
    _pollTimer = null;
    // Note: Don't try to access ScaffoldMessenger in dispose() as the widget tree may be deactivated
    // ScaffoldMessenger snackbars will be automatically dismissed when the screen is popped
    super.dispose();
  }

  Future<void> _loadMapData() async {
    if (!mounted) return;
    
    setState(() {
      _isLoadingMap = true;
      _errorMessage = null;
    });

    try {
      // Check if we have preloaded responses first
      if (widget.responses.isNotEmpty) {
        print('⚡ Using ${widget.responses.length} preloaded approval responses');
        _responsesByCountry = widget.responses;
        
        if (mounted) {
          setState(() {
            _isLoadingMap = false;
            _lastResponseCount = _responsesByCountry.length;
            _lastUpdated = DateTime.now();
            // Don't override vote count - it should already be set correctly by navigateToResultsScreen
          });
          
          print('📊 Approval results loaded: ${_responsesByCountry.length} responses, setting baseline for polling');
          // Start polling only after initial data is displayed
          _startPolling();
          
          // Delay setting loading to false to ensure smooth transition
          Future.delayed(Duration(milliseconds: 100), () {
            if (mounted) {
              setState(() {
                _isLoadingMap = false;
              });
            }
          });
          
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
          Future.delayed(Duration(milliseconds: 1500), () {
            if (mounted) {
              print('⚡ Third immediate check for fresh user vote');
              _checkForUpdates();
            }
          });
        }
        return;
      }
      
      print('Loading real approval responses for question ID: ${widget.question['id']}');
      
      // Only fetch from database if no preloaded data exists
      await _loadFreshApprovalDataFromDatabase();
      
    } catch (e) {
      print('Error loading approval responses: $e');
      if (mounted) {
        setState(() {
          _responsesByCountry = [];
          _isLoadingMap = false;
          _errorMessage = 'Error loading responses. Please try again.';
          // Don't override vote count - keep the value set by navigateToResultsScreen
        });
        // Start polling even on error - might recover
        _startPolling();
      }
    }
  }

  Future<void> _loadFreshApprovalDataFromDatabase() async {
    // Fetch real approval responses from the database with country names
    final response = await _supabase
        .from('responses')
        .select('''
          score,
          created_at,
          countries!responses_country_code_fkey(country_name_en)
        ''')
        .eq('question_id', widget.question['id'])
        .not('score', 'is', null)
        .order('created_at', ascending: false);
    
    if (response != null && response.isNotEmpty) {
      // Convert to the format expected by the rest of the code
      // Convert score from -100 to 100 range to -1 to 1 range for display
      _responsesByCountry = response.map((r) => {
        'country': r['countries']?['country_name_en'] ?? 'Unknown',
        'answer': (r['score'] as int).toDouble() / 100.0, // Convert to -1 to 1 range
        'created_at': r['created_at'],
      }).toList();
      
      print('Found ${_responsesByCountry.length} real approval responses from database');
    } else {
      print('No approval responses found in database for this question');
      _responsesByCountry = [];
      _errorMessage = 'No responses yet for this question';
    }
    
    if (mounted) {
      setState(() {
        _isLoadingMap = false;
        _lastResponseCount = _responsesByCountry.length;
        _lastUpdated = DateTime.now();
        // Don't override vote count - it should already be set correctly by navigateToResultsScreen
      });
      
      print('📊 Fresh approval data loaded from DB: ${_responsesByCountry.length} responses, setting baseline for polling');
      // Start polling only after data is loaded
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
      Future.delayed(Duration(milliseconds: 1500), () {
        if (mounted) {
          print('⚡ Third immediate check for fresh user vote');
          _checkForUpdates();
        }
      });
    }
  }

  Future<void> _loadMyNetworkData() async {
    try {
      _questionService ??= Provider.of<QuestionService>(context, listen: false);
      final networkResponses = await _questionService!.getMyNetworkResponses(
        widget.question['id'].toString(), 
        'approval_rating'
      );
      
      // Also load room response counts for filtering
      await _loadRoomResponseCounts();
      
      if (mounted) {
        setState(() {
          _myNetworkResponses = networkResponses;
        });
        print('🎪 Loaded ${networkResponses.length} My Network responses for approval question');
        print('🔍 DEBUG: My Network responses received: $networkResponses');
      }
    } catch (e) {
      print('Error loading My Network responses: $e');
      if (mounted) {
        setState(() {
          _myNetworkResponses = [];
        });
      }
    }
  }

  Future<void> _loadRoomResponseCounts() async {
    try {
      // Import RoomService to get user's rooms
      final roomService = RoomService();
      final userRooms = await roomService.getUserRooms();
      
      final Map<String, int> roomCounts = {};
      final Map<String, List<Map<String, dynamic>>> roomResponses = {};
      final Map<String, String> roomNames = {};
      
      for (final room in userRooms) {
        // Store room name for display
        roomNames[room.id] = room.name;
        // Get room response count
        final count = await _questionService!.getRoomResponseCount(
          room.id, 
          widget.question['id'].toString()
        );
        roomCounts[room.id] = count;
        print('🔍 DEBUG: Room ${room.name} (${room.id}) has $count responses');
        
        // Get actual room responses for filtering if count > 0
        if (count > 0) {
          try {
            print('🔍 DEBUG: Loading approval responses for room ${room.name} (${room.id}) with $count responses');
            final responses = await Supabase.instance.client
                .from('room_shared_responses')
                .select('''
                  response_id,
                  responses!inner(
                    score,
                    created_at,
                    countries!inner(country_name_en)
                  )
                ''')
                .eq('room_id', room.id)
                .eq('question_id', widget.question['id'].toString());
            
            print('🔍 DEBUG: Raw approval room responses: $responses');
            
            // Convert to expected format
            final roomResponsesList = responses.map((shared) {
              final response = shared['responses'];
              if (response == null) return null;
              return {
                'answer': (response['score'] as int).toDouble() / 100.0, // Convert to -1 to 1 range
                'country': response['countries']?['country_name_en'] ?? 'Unknown',
                'created_at': response['created_at'],
              };
            }).where((r) => r != null).cast<Map<String, dynamic>>().toList();
            
            roomResponses[room.id] = roomResponsesList;
            print('🎪 Room ${room.name} has $count responses for this question');
            print('🔍 DEBUG: Room ${room.id} response data: ${roomResponsesList.take(2).toList()}');
          } catch (e) {
            print('Error loading responses for room ${room.name}: $e');
            roomResponses[room.id] = [];
          }
        } else {
          roomResponses[room.id] = [];
        }
      }
      
      if (mounted) {
        setState(() {
          _roomResponseCounts = roomCounts;
          _roomResponses = roomResponses;
          _roomNames = roomNames;
        });
      }
    } catch (e) {
      print('Error loading room response counts: $e');
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
          .not('score', 'is', null);
      
      final currentCount = response?.length ?? 0;
      final actualDisplayedCount = _responsesByCountry.length;
      
      print('🗕 Polling check - DB: $currentCount, Last tracked: $_lastResponseCount, Currently displayed: $actualDisplayedCount');
      
      // If counts are the same, no need to refresh
      if (currentCount == _lastResponseCount && currentCount == actualDisplayedCount) {
        return;
      }
      
      // Check if our displayed data is already current (avoid false positives from stale _lastResponseCount)
      if (currentCount == actualDisplayedCount && actualDisplayedCount > _lastResponseCount) {
        print('🔄 Updating baseline: displayed data is already current ($actualDisplayedCount), updating tracked count');
        _lastResponseCount = actualDisplayedCount;
        return;
      }
      
      // Check if there's a significant change
      // Use lower threshold for immediate checks to catch user's fresh vote quickly
      final isImmediateCheck = _immediateCheckCount < 3;
      final threshold = isImmediateCheck ? 0.01 : 0.05; // 1% vs 5% threshold
      
      final percentChange = (_lastResponseCount > 0) 
          ? ((currentCount - _lastResponseCount).abs() / _lastResponseCount) 
          : (currentCount > 0 ? 1.0 : 0.0);
      
      if (isImmediateCheck) {
        _immediateCheckCount++;
        print('🔄 Immediate check #$_immediateCheckCount using ${(threshold * 100).toStringAsFixed(1)}% threshold');
      }
      
      // Only refresh if there's a real change and it's significant
      if (percentChange > threshold || (_lastResponseCount == 0 && currentCount > 0)) {
        print('⚠️ Significant change detected: $currentCount vs $_lastResponseCount (${(percentChange * 100).toStringAsFixed(1)}% change)');
        if (mounted) {
          await _refreshMapData();
        }
      }
    } catch (e) {
      print('Error checking for updates: $e');
    }
  }

  // Helper method to determine if expand button should be shown
  bool _shouldShowExpandButton() {
    final descriptionText = widget.question['description'];
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

  Future<void> _refreshMapData() async {
    try {
      print('Auto-refreshing approval responses for question ID: ${widget.question['id']}');
      
      // Fetch fresh approval responses from the database with country names
      final response = await _supabase
          .from('responses')
          .select('''
            score,
            created_at,
            countries!responses_country_code_fkey(country_name_en)
          ''')
          .eq('question_id', widget.question['id'])
          .not('score', 'is', null)
          .order('created_at', ascending: false);
      
      if (response != null && response.isNotEmpty) {
        // Convert to the format expected by the rest of the code
        final freshResponses = response.map((r) => {
          'country': r['countries']?['country_name_en'] ?? 'Unknown',
          'answer': (r['score'] as int).toDouble() / 100.0, // Convert to -1 to 1 range
          'created_at': r['created_at'],
        }).toList();
        
        if (mounted) {
          setState(() {
            _responsesByCountry = freshResponses;
            _lastResponseCount = freshResponses.length;
            // Update vote count to match the actual responses
            widget.question['votes'] = freshResponses.length;
            _lastUpdated = DateTime.now();
          });
          
          print('Auto-refreshed with ${freshResponses.length} approval responses');
        }
      }
    } catch (e) {
      print('Error auto-refreshing map data: $e');
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
    if (!mounted || !isCityTargeted || widget.question['city_id'] == null) {
      return;
    }

    // Check if we already have the city name from joined data
    if (widget.question['cities'] != null && widget.question['cities']['name'] != null) {
      if (mounted) {
        setState(() {
          _actualCityName = widget.question['cities']['name'].toString();
        });
      }
      return;
    }

    // If not, fetch it from the database
    if (mounted) {
      setState(() {
        _loadingCityName = true;
      });
    } else {
      return; // Exit if widget is no longer mounted
    }

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

  // Get filtered responses based on selected country
  List<Map<String, dynamic>> get filteredResponses {
    // For private questions, never filter by country - always show all responses
    if (isPrivateQuestion || selectedCountry == null) {
      return _responsesByCountry;
    }
    
    // Handle My Network filtering
    if (selectedCountry == 'My Network') {
      // Return My Network responses (loaded separately via _loadMyNetworkData)
      return _myNetworkResponses;
    }
    
    // Handle Room filtering
    if (selectedCountry?.startsWith('Room:') == true) {
      final roomId = selectedCountry!.substring(5); // Remove 'Room:' prefix
      return _roomResponses[roomId] ?? [];
    }
    
    // Handle regular country filtering
    return _responsesByCountry.where((r) => r['country'] == selectedCountry).toList();
  }

  // Calculate statistics
  double get average {
    final values = filteredResponses.map((r) => r['answer'] as double).toList();
    return values.isEmpty ? 0 : values.reduce((a, b) => a + b) / values.length;
  }
  
  int get totalResponses => filteredResponses.length;
  
  // Group responses into bins for histogram
  Map<String, int> get _binnedResponses {
    final bins = {
      'Strongly Approve': 0,
      'Approve': 0,
      'Neutral': 0,
      'Disapprove': 0,
      'Strongly Disapprove': 0,
    };

    for (var response in filteredResponses) {
      final value = response['answer'] as double;
      if (value <= -0.8) {
        bins['Strongly Disapprove'] = (bins['Strongly Disapprove'] ?? 0) + 1;
      } else if (value <= -0.3) {
        bins['Disapprove'] = (bins['Disapprove'] ?? 0) + 1;
      } else if (value <= 0.3) {
        bins['Neutral'] = (bins['Neutral'] ?? 0) + 1;
      } else if (value <= 0.8) {
        bins['Approve'] = (bins['Approve'] ?? 0) + 1;
      } else {
        bins['Strongly Approve'] = (bins['Strongly Approve'] ?? 0) + 1;
      }
    }

    return bins;
  }

  // Get responses for a specific country in comparison mode
  List<Map<String, dynamic>> _getCountryResponses(String country) {
    if (country == 'World') {
      // Return all responses for world comparison
      return _responsesByCountry;
    }
    
    // Handle My Network filtering
    if (country == 'My Network') {
      // Return My Network responses (loaded separately via _loadMyNetworkData)
      return _myNetworkResponses;
    }
    
    // Handle Room filtering
    if (country.startsWith('Room:')) {
      final roomId = country.substring(5); // Remove 'Room:' prefix
      return _roomResponses[roomId] ?? [];
    }
    
    // Handle regular country filtering
    return _responsesByCountry.where((r) => r['country'] == country).toList();
  }

  // Get binned responses for a specific country
  Map<String, int> _getBinnedResponsesForCountry(String country) {
    final countryResponses = _getCountryResponses(country);
    final bins = {
      'Strongly Approve': 0,
      'Approve': 0,
      'Neutral': 0,
      'Disapprove': 0,
      'Strongly Disapprove': 0,
    };

    for (var response in countryResponses) {
      final value = response['answer'] as double;
      if (value <= -0.8) {
        bins['Strongly Disapprove'] = (bins['Strongly Disapprove'] ?? 0) + 1;
      } else if (value <= -0.3) {
        bins['Disapprove'] = (bins['Disapprove'] ?? 0) + 1;
      } else if (value <= 0.3) {
        bins['Neutral'] = (bins['Neutral'] ?? 0) + 1;
      } else if (value <= 0.8) {
        bins['Approve'] = (bins['Approve'] ?? 0) + 1;
      } else {
        bins['Strongly Approve'] = (bins['Strongly Approve'] ?? 0) + 1;
      }
    }

    return bins;
  }

  // Get average for a specific country
  double _getCountryAverage(String country) {
    final countryResponses = _getCountryResponses(country);
    final values = countryResponses.map((r) => r['answer'] as double).toList();
    return values.isEmpty ? 0 : values.reduce((a, b) => a + b) / values.length;
  }

  // Build chart bars for comparison or single view
  List<Widget> _buildChartBars() {
    if (_isComparisonMode && _comparisonCountry1 != null && _comparisonCountry2 != null) {
      // Comparison mode
      final country1Data = _getBinnedResponsesForCountry(_comparisonCountry1!);
      final country2Data = _getBinnedResponsesForCountry(_comparisonCountry2!);
      final country1Total = country1Data.values.fold<int>(0, (sum, count) => sum + count);
      final country2Total = country2Data.values.fold<int>(0, (sum, count) => sum + count);
      
      return country1Data.keys.map((category) {
        final country1Count = country1Data[category] ?? 0;
        final country2Count = country2Data[category] ?? 0;
        final country1Percentage = country1Total > 0 ? (country1Count / country1Total * 100).round() : 0;
        final country2Percentage = country2Total > 0 ? (country2Count / country2Total * 100).round() : 0;
        
        return Padding(
          padding: EdgeInsets.only(bottom: 20),
          child: Row(
            children: [
              SizedBox(
                width: 60,
                child: Center(
                  child: ColorFiltered(
                    colorFilter: ColorFilter.matrix([
                      0.2126, 0.7152, 0.0722, 0, 0,
                      0.2126, 0.7152, 0.0722, 0, 0,
                      0.2126, 0.7152, 0.0722, 0, 0,
                      0, 0, 0, 1, 0,
                    ]),
                    child: _getIconForLabel(category),
                  ),
                ),
              ),
              SizedBox(width: 12),
              Expanded(
                child: Column(
                  children: [
                    // Country 1 bar
                    LinearProgressIndicator(
                      value: country1Total > 0 ? country1Count / country1Total : 0,
                      backgroundColor: Theme.of(context).colorScheme.surface,
                      valueColor: AlwaysStoppedAnimation<Color>(_country1Color),
                      minHeight: 8,
                    ),
                    SizedBox(height: 2),
                    // Country 2 bar
                    LinearProgressIndicator(
                      value: country2Total > 0 ? country2Count / country2Total : 0,
                      backgroundColor: Theme.of(context).colorScheme.surface,
                      valueColor: AlwaysStoppedAnimation<Color>(Color(0xFFFF6569)),
                      minHeight: 8,
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      }).toList();
    } else {
      // Single view mode
      return _binnedResponses.entries.map((entry) {
        final percentage = totalResponses > 0
            ? (entry.value / totalResponses * 100).round().toString()
            : '0';
        
        return Padding(
          padding: EdgeInsets.only(bottom: 20),
          child: Row(
            children: [
              SizedBox(
                width: 60,
                child: Center(
                  child: _getIconForLabel(entry.key),
                ),
              ),
              Container(
                width: 1,
                height: 20,
                color: Colors.grey[300],
                margin: EdgeInsets.symmetric(horizontal: 12),
              ),
              Expanded(
                child: LinearProgressIndicator(
                  value: totalResponses > 0 ? entry.value / totalResponses : 0,
                  backgroundColor: Theme.of(context).colorScheme.surface,
                  valueColor: AlwaysStoppedAnimation<Color>(
                    _getColorForLabel(entry.key),
                  ),
                  minHeight: 8,
                ),
              ),
              SizedBox(width: 12),
              Text('$percentage% (${entry.value})'),
            ],
          ),
        );
      }).toList();
    }
  }

  // Get average sentiment for each country
  Map<String, double> get _countryAverages {
    final countryVotes = <String, List<double>>{};
    
    // Collect votes per country
    for (var response in _responsesByCountry) {
      final country = response['country'] as String;
      final value = response['answer'] as double;
      
      if (!countryVotes.containsKey(country)) {
        countryVotes[country] = [];
      }
      countryVotes[country]!.add(value);
    }
    
    // Calculate averages
    final result = <String, double>{};
    countryVotes.forEach((country, votes) {
      result[country] = votes.reduce((a, b) => a + b) / votes.length;
    });
    
    return result;
  }

  // Get sorted list of countries by response count
  List<MapEntry<String, double>> get _sortedCountryAverages {
    final countryCounts = <String, int>{};
    for (var response in _responsesByCountry) {
      final country = response['country'] as String;
      countryCounts[country] = (countryCounts[country] ?? 0) + 1;
    }
    
    return _countryAverages.entries.toList()
      ..sort((a, b) => countryCounts[b.key]!.compareTo(countryCounts[a.key]!));
  }

  String _getSentimentLabel(double value) {
    if (value <= -0.8) return 'Strongly Disapprove';
    if (value <= -0.3) return 'Disapprove';
    if (value <= 0.3) return 'Neutral';
    if (value <= 0.8) return 'Approve';
    return 'Strongly Approve';
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

  Widget _getIconForLabel(String label) {
    switch (label) {
      case 'Strongly Disapprove':
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.thumb_down, color: Colors.red, size: 20),
            SizedBox(width: 2),
            Icon(Icons.thumb_down, color: Colors.red, size: 20),
          ],
        );
      case 'Disapprove':
        return Icon(Icons.thumb_down, color: Colors.red[200], size: 20);
      case 'Neutral':
        return Icon(Icons.sentiment_neutral, color: Colors.grey[600], size: 20);
      case 'Approve':
        return Icon(Icons.thumb_up, color: Colors.green[200], size: 20);
      case 'Strongly Approve':
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.thumb_up, color: Colors.green, size: 20),
            SizedBox(width: 2),
            Icon(Icons.thumb_up, color: Colors.green, size: 20),
          ],
        );
      default:
        return Icon(Icons.sentiment_neutral, color: Colors.grey[300], size: 20);
    }
  }

  Color _getColorForValue(double value) {
    // Normalize the value from -1 to 1 range to 0 to 1 range
    final normalizedValue = (value + 1) / 2;
    
    if (normalizedValue < 0.2) {
      return Colors.red;
    } else if (normalizedValue < 0.4) {
      return Colors.red[300]!;
    } else if (normalizedValue < 0.6) {
      return Colors.grey.shade300;
    } else if (normalizedValue < 0.8) {
      return Colors.lightGreen;
    } else {
      return Colors.green;
    }
  }

  Color _getColorForLabel(String label) {
    switch (label) {
      case 'Strongly Disapprove':
        return Colors.red;
      case 'Disapprove':
        return Colors.red[300]!;
      case 'Neutral':
        return Colors.grey[300]!; // Changed to light gray
      case 'Approve':
        return Colors.green[300]!;
      case 'Strongly Approve':
        return Colors.green;
      default:
        return Colors.grey[300]!;
    }
  }

  void _onCountrySelected(String? country) {
    // Dismiss any current snackbar before showing a new one
    if (mounted) {
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
    }
    
    // Exit comparison mode when a single country is selected
    setState(() {
      _isComparisonMode = false;
      _comparisonCountry1 = null;
      _comparisonCountry2 = null;
    });
    
    if (country == null) {
      if (mounted) {
        setState(() {
          selectedCountry = country;
        });
        // Show snackbar for Global selection
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Showing global responses'),
            backgroundColor: Theme.of(context).primaryColor,
            duration: Duration(seconds: 2),
          ),
        );
      }
      return;
    }
    
    // Handle My Network filtering
    if (country == 'My Network') {
      if (_myNetworkResponses.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('No responses from your network yet'),
              backgroundColor: Colors.orange,
              duration: Duration(seconds: 3),
            ),
          );
        }
        return; // Don't change the selection
      }
      
      if (mounted) {
        setState(() {
          selectedCountry = country;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Showing ${_myNetworkResponses.length} responses from your network'),
            backgroundColor: Theme.of(context).primaryColor,
            duration: Duration(seconds: 2),
          ),
        );
      }
      return;
    }
    
    // Handle Room filtering
    if (country.startsWith('Room:')) {
      final roomId = country.substring(5); // Remove 'Room:' prefix
      final roomResponses = _roomResponses[roomId] ?? [];
      
      if (roomResponses.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('No responses from room:$roomId yet'),
              backgroundColor: Colors.orange,
              duration: Duration(seconds: 3),
            ),
          );
        }
        return; // Don't change the selection
      }
      
      if (mounted) {
        setState(() {
          selectedCountry = country;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Showing ${roomResponses.length} responses from room'),
            backgroundColor: Theme.of(context).primaryColor,
            duration: Duration(seconds: 2),
          ),
        );
      }
      return;
    }
    
    // Handle regular country filtering
    final countryResponses = _responsesByCountry.where((r) => r['country'] == country).toList();
    
    if (countryResponses.isEmpty) {
      // Show message that there are no responses from this country
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('No responses from $country yet'),
            backgroundColor: Colors.orange,
            duration: Duration(seconds: 3),
          ),
        );
      }
      return; // Don't change the selection
    }
    
    // Show informative message when selecting a country
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Showing results from $country'),
          backgroundColor: Theme.of(context).primaryColor,
          duration: Duration(seconds: 2),
        ),
      );
      
      setState(() {
        selectedCountry = country;
      });
    }
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

  @override
  Widget buildResultsScreen(BuildContext context) {
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
        controller: _scrollController,
        child: Padding(
          padding: EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (widget.isGuestMode) ...[
                _buildGuestModeBanner(),
                const SizedBox(height: 16),
              ],
              Card(
                child: Padding(
                  padding: EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Question title - always shown in full
                      Text(
                        widget.question['title'] ?? widget.question['prompt'] ?? 'No Title',
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      if (widget.question['description'] != null) ...[
                        SizedBox(height: 8),
                        InkWell(
                          onTap: _shouldShowExpandButton() ? () {
                            setState(() {
                              _isQuestionExpanded = !_isQuestionExpanded;
                            });
                          } : null,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                widget.question['description'],
                                style: Theme.of(context).textTheme.bodyMedium,
                                maxLines: _isQuestionExpanded ? null : 1,
                                overflow: _isQuestionExpanded ? TextOverflow.visible : TextOverflow.ellipsis,
                              ),
                              if (_shouldShowExpandButton()) ...[
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
                                final questionCountryCode = widget.question['country_code']?.toString();
                                String targetingEmoji;
                                String dialogTitle;
                                String dialogMessage;
                                
                                switch (targeting) {
                                  case 'globe':
                                    targetingEmoji = '🌍';
                                    dialogTitle = 'Global Question';
                                    dialogMessage = 'This question is addressed to people in the world.';
                                    break;
                                  case 'country':
                                    if (questionCountryCode != null && questionCountryCode.isNotEmpty) {
                                      final flagEmoji = _getCountryFlagEmoji(questionCountryCode);
                                      targetingEmoji = flagEmoji.isNotEmpty ? flagEmoji : '🇺🇳';
                                    } else {
                                      targetingEmoji = '🇺🇳';
                                    }
                                    final countryName = questionCountryCode != null && questionCountryCode.isNotEmpty 
                                        ? _getCountryNameFromCode(questionCountryCode)
                                        : (widget.question['country_name'] ?? 
                                           widget.question['countries']?['country_name_en'] ?? 
                                           'a specific country');
                                    dialogTitle = 'Country Question';
                                    dialogMessage = 'This question is addressed to people in $countryName.';
                                    break;
                                  case 'city':
                                    targetingEmoji = '🏙️';
                                    final cityName = widget.question['city_name'] ?? 
                                                   widget.question['cities']?['name'] ?? 
                                                   'a specific city';
                                    dialogTitle = 'City Question';
                                    dialogMessage = 'This question is addressed to people in $cityName.';
                                    break;
                                  default:
                                    targetingEmoji = '🌍';
                                    dialogTitle = 'Global Question';
                                    dialogMessage = 'This question is addressed to people in the world.';
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
                                  child: Text(
                                    targetingEmoji,
                                    style: TextStyle(fontSize: 16),
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
              ),
              SizedBox(height: 24),
              Card(
                child: Padding(
                  padding: EdgeInsets.all(16.0),
                  child: Column(
                    children: [
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
                      SizedBox(height: 16),
                      _isComparisonMode 
                        ? RichText(
                            text: TextSpan(
                              style: Theme.of(context).textTheme.titleMedium,
                              children: [
                                TextSpan(
                                  text: _getDisplayName(_comparisonCountry1 ?? ''),
                                  style: TextStyle(color: _country1Color),
                                ),
                                TextSpan(text: ' vs '),
                                TextSpan(
                                  text: _getDisplayName(_comparisonCountry2 ?? ''),
                                  style: TextStyle(color: Color(0xFFFF6569)),
                                ),
                              ],
                            ),
                          )
                        : SizedBox.shrink(), // Remove the title completely for single view
                      SizedBox(height: 8),
                      _isComparisonMode && _comparisonCountry1 != null && _comparisonCountry2 != null
                        ? Column(
                            children: [
                              // Country 1 average
                              Row(
                                children: [
                                  SizedBox(
                                    width: 60,
                                    child: Center(
                                      child: Transform.scale(
                                        scale: 1.5,
                                        child: ColorFiltered(
                                          colorFilter: ColorFilter.matrix([
                                            0.2126, 0.7152, 0.0722, 0, 0,
                                            0.2126, 0.7152, 0.0722, 0, 0,
                                            0.2126, 0.7152, 0.0722, 0, 0,
                                            0, 0, 0, 1, 0,
                                          ]),
                                          child: _getIconForLabel(_getSentimentLabel(_getCountryAverage(_comparisonCountry1!))),
                                        ),
                                      ),
                                    ),
                                  ),
                                  SizedBox(width: 12),
                                  Expanded(
                                    child: LinearProgressIndicator(
                                      value: (_getCountryAverage(_comparisonCountry1!) + 1) / 2,
                                      backgroundColor: Theme.of(context).colorScheme.surface,
                                      valueColor: AlwaysStoppedAnimation<Color>(_country1Color),
                                      minHeight: 8,
                                    ),
                                  ),
                                ],
                              ),
                              SizedBox(height: 16),
                              // Country 2 average
                              Row(
                                children: [
                                  SizedBox(
                                    width: 60,
                                    child: Center(
                                      child: Transform.scale(
                                        scale: 1.5,
                                        child: ColorFiltered(
                                          colorFilter: ColorFilter.matrix([
                                            0.2126, 0.7152, 0.0722, 0, 0,
                                            0.2126, 0.7152, 0.0722, 0, 0,
                                            0.2126, 0.7152, 0.0722, 0, 0,
                                            0, 0, 0, 1, 0,
                                          ]),
                                          child: _getIconForLabel(_getSentimentLabel(_getCountryAverage(_comparisonCountry2!))),
                                        ),
                                      ),
                                    ),
                                  ),
                                  SizedBox(width: 12),
                                  Expanded(
                                    child: LinearProgressIndicator(
                                      value: (_getCountryAverage(_comparisonCountry2!) + 1) / 2,
                                      backgroundColor: Theme.of(context).colorScheme.surface,
                                      valueColor: AlwaysStoppedAnimation<Color>(Color(0xFFFF6569)),
                                      minHeight: 8,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          )
                        : Column(
                            children: [
                              Transform.scale(
                                scale: 2.0,
                                child: _getIconForLabel(_getSentimentLabel(average)),
                              ),
                              SizedBox(height: 16),
                              LinearProgressIndicator(
                                value: (average + 1) / 2,
                                backgroundColor: Theme.of(context).colorScheme.surface,
                                valueColor: AlwaysStoppedAnimation<Color>(_getColorForValue(average)),
                                minHeight: 10,
                              ),
                            ],
                          ),
                    ],
                  ),
                ),
              ),
              SizedBox(height: 12),
              
              // Question Reactions
              QuestionReactionsWidget(
                questionId: widget.question['id']?.toString() ?? '',
                useDummyData: false,
                margin: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              ),
              
              SizedBox(height: 24),
              Card(
                child: Padding(
                  padding: EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
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
                      SizedBox(height: 8),
                      Center(
                        child: _isComparisonMode 
                          ? RichText(
                              text: TextSpan(
                                style: Theme.of(context).textTheme.titleMedium,
                                children: [
                                  TextSpan(
                                    text: _getDisplayName(_comparisonCountry1 ?? ''),
                                    style: TextStyle(color: _country1Color),
                                  ),
                                  TextSpan(text: ' vs '),
                                  TextSpan(
                                    text: _getDisplayName(_comparisonCountry2 ?? ''),
                                    style: TextStyle(color: Color(0xFFFF6569)),
                                  ),
                                ],
                              ),
                            )
                          : Text(
                              isPrivateQuestion
                                ? 'Responses (Private)'
                                : isCityTargeted
                                  ? 'Responses ($cityName)'
                                  : isCountryTargeted && selectedCountry != null
                                    ? 'Responses ($selectedCountry)'
                                    : 'Responses ${selectedCountry != null ? ' (${_getDisplayName(selectedCountry!)})' : ' (Global)'}',
                              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                color: Colors.grey[600],
                                fontSize: 14,
                              ),
                            ),
                      ),
                      if (_shouldShowFilterButton() && _getUniqueCountriesWithResponses().length > 1) ...[
                        const SizedBox(height: 12),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            TextButton.icon(
                              onPressed: _showCountryFilterDialog,
                              icon: Icon(Icons.filter_list, size: 18),
                              label: Text('Filter'),
                              style: TextButton.styleFrom(
                                foregroundColor: _country1Color,
                                side: selectedCountry != null 
                                  ? BorderSide(color: _country1Color, width: 1.5)
                                  : null,
                              ),
                            ),
                            const SizedBox(width: 16),
                            TextButton.icon(
                              onPressed: () async {
                                // If already in comparison mode, exit to global view
                                if (_isComparisonMode) {
                                  setState(() {
                                    _isComparisonMode = false;
                                    _comparisonCountry1 = null;
                                    _comparisonCountry2 = null;
                                    selectedCountry = null; // Set to global view
                                  });
                                  return;
                                }
                                
                                final countryData = _getCountryResponseData();
                                if (countryData.isEmpty) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        'Not enough country data to compare',
                                        style: TextStyle(color: Colors.white),
                                      ),
                                      backgroundColor: Theme.of(context).primaryColor,
                                    ),
                                  );
                                  return;
                                }
                                
                                final questionTitle = widget.question['prompt'] ?? widget.question['title'] ?? 'Question';
                                final selectedCountries = await CountryComparisonDialog.show(
                                  context: context,
                                  countryResponses: countryData,
                                  questionTitle: questionTitle,
                                  questionId: widget.question['id'].toString(),
                                  questionType: 'approval',
                                  countryAverages: _countryAverages,
                                  allResponses: _responsesByCountry,
                                  roomResponseCounts: _roomResponseCounts,
                                  myNetworkResponseCount: _myNetworkResponses.length,
                                  roomNames: _roomNames,
                                );
                                
                                if (selectedCountries != null && selectedCountries.length == 2) {
                                  setState(() {
                                    _isComparisonMode = true;
                                    _comparisonCountry1 = selectedCountries[0];
                                    _comparisonCountry2 = selectedCountries[1];
                                    selectedCountry = null; // Clear single country filter
                                  });
                                }
                              },
                              icon: Icon(_isComparisonMode ? Icons.close : Icons.compare_arrows, size: 18),
                              label: Text(_isComparisonMode ? 'Exit Comparison' : 'Compare'),
                              style: TextButton.styleFrom(
                                foregroundColor: _country1Color,
                                side: _isComparisonMode 
                                  ? BorderSide(color: _country1Color, width: 1.5)
                                  : null,
                              ),
                            ),
                          ],
                        ),
                      ],
                      SizedBox(height: 16),
                      ..._buildChartBars(),
                    ],
                  ),
                ),
              ),
              
              // Add world map visualization - only for non-city-targeted questions and non-private questions
              if (!isCityTargeted && !isPrivateQuestion) ...[
                              // Only show map if there are 20+ responses from 5+ countries
              if (_shouldShowMap()) ...[
                if (_isLoadingMap) 
                  Card(
                    child: Container(
                      height: 200,
                      child: Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            CircularProgressIndicator(),
                            SizedBox(height: 16),
                            Text(
                              'Loading world map...',
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                          ],
                        ),
                      ),
                    ),
                  )
                else if (_errorMessage != null)
                  Card(
                    child: Container(
                      height: 200,
                      child: Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.info_outline, size: 48, color: Colors.grey),
                            SizedBox(height: 16),
                            Text(
                              _errorMessage!,
                              style: TextStyle(color: Colors.grey),
                              textAlign: TextAlign.center,
                            ),
                          ],
                        ),
                      ),
                    ),
                  )
                else
                  CountryApprovalMap(
                    key: ValueKey('approval_map_${_responsesByCountry.length}_${_lastUpdated.millisecondsSinceEpoch}'),
                    responsesByCountry: _responsesByCountry,
                    questionTitle: widget.question['title'] ?? widget.question['prompt'] ?? 'No Title',
                    questionId: widget.question['id']?.toString() ?? '',
                    onCountryTap: (String? countryCode) async {
                      if (countryCode != null) {
                        final countryName = await CountryService.getCountryNameFromIso(countryCode);
                        if (countryName != null) {
                          _onCountrySelected(countryName);
                        }
                      }
                    },
                  ),
              ],
                SizedBox(height: 24),
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
                questionId: widget.question['id']?.toString() ?? '',
                onAddCommentTap: () => _handleAddComment(),
                onCommentsLoaded: (comments) {
                  setState(() {
                    _comments = comments;
                  });
                },
                useDummyData: false, // Use real data
                questionContext: widget.question,
                margin: EdgeInsets.zero, // Remove default margin to align with other widgets
              ),
              
              // Swipe to next indicator
              SizedBox(height: 40),
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
                    SizedBox(width: 8),
                    Icon(
                      Icons.swipe_left,
                      color: Colors.grey[600],
                      size: 16,
                    ),
                  ],
                ),
              ),
              
              // Bottom action buttons
              SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  TextButton.icon(
                    icon: Icon(Icons.share),
                    label: Text('Share'),
                    onPressed: () {
                      final questionTitle = widget.question['prompt'] ?? widget.question['title'] ?? 'Check out this question';
                      final questionId = widget.question['id']?.toString() ?? '';
                      final shareText = questionId.isNotEmpty 
                          ? 'Check out this question on Read the Room:\n\n$questionTitle\n\nhttps://readtheroom.site/question/$questionId'
                          : 'Check out this question on Read the Room:\n\n$questionTitle';
                      
                      final box = context.findRenderObject() as RenderBox?;
                      Share.share(
                        shareText,
                        sharePositionOrigin: box != null 
                            ? box.localToGlobal(Offset.zero) & box.size
                            : null,
                      );
                    },
                  ),
                  TextButton.icon(
                    icon: Icon(Icons.report),
                    label: Text('Report'),
                    onPressed: () {
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

                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => ReportQuestionScreen(
                            question: widget.question,
                          ),
                        ),
                      );
                    },
                  ),
                ],
              ),
            ],
            ),
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


  bool _shouldShowMap() {
    // Check if we have enough responses and countries to show the map
    final totalResponses = _responsesByCountry.length;
    final uniqueCountries = _getUniqueCountriesWithResponses().length;
    
    return totalResponses >= 10 && uniqueCountries >= 3;
  }

  // Auto-set comparison mode if accessed from room feed
  void _autoSetComparisonModeIfFromRoom() {
    // Check if this question was accessed from a room feed
    if (widget.feedContext?.feedType == 'room' && widget.feedContext?.roomId != null) {
      // Delay setting comparison mode until after initial data loads
      Future.delayed(Duration(milliseconds: 500), () {
        if (mounted && !_isComparisonMode) {
          setState(() {
            _isComparisonMode = true;
            _comparisonCountry1 = 'World';
            _comparisonCountry2 = 'Room:${widget.feedContext!.roomId}';
          });
        }
      });
    }
  }

  // Helper method to record question view for vote count and comment count delta tracking
  Future<void> _recordQuestionView() async {
    try {
      final currentVotes = widget.question['votes'] as int? ?? 0;
      final currentComments = _getCommentCount(widget.question);
      final questionId = widget.question['id'].toString();
      
      print('🔍 Debug: Recording view for question $questionId with $currentVotes votes, $currentComments comments (approval results)');
      
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

  void _handleAddComment() async {
    final questionTitle = widget.question['prompt'] ?? widget.question['title'] ?? 'Question';
    final questionId = widget.question['id']?.toString() ?? '';

    if (questionId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Unable to add comment: Question ID not found'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    await AddCommentDialog.show(
      context: context,
      questionId: questionId,
      questionTitle: questionTitle,
      question: widget.question,
      onCommentAdded: (newComment) {
        // Refresh the comments section immediately
        (_commentsSectionKey.currentState as dynamic)?.refreshComments();
      },
    );
  }

  String _getCountryFlagEmoji(String countryCode) {
    // Map of country codes to flag emojis
    final countryFlags = <String, String>{
      'US': '🇺🇸',
      'CA': '🇨🇦', 
      'GB': '🇬🇧',
      'AU': '🇦🇺',
      'DE': '🇩🇪',
      'FR': '🇫🇷',
      'IT': '🇮🇹',
      'ES': '🇪🇸',
      'JP': '🇯🇵',
      'CN': '🇨🇳',
      'IN': '🇮🇳',
      'BR': '🇧🇷',
      'MX': '🇲🇽',
      'RU': '🇷🇺',
      'KR': '🇰🇷',
      'NL': '🇳🇱',
      'BE': '🇧🇪',
      'CH': '🇨🇭',
      'AT': '🇦🇹',
      'SE': '🇸🇪',
      'NO': '🇳🇴',
      'DK': '🇩🇰',
      'FI': '🇫🇮',
      'PL': '🇵🇱',
      'CZ': '🇨🇿',
      'HU': '🇭🇺',
      'GR': '🇬🇷',
      'PT': '🇵🇹',
      'IE': '🇮🇪',
      'NZ': '🇳🇿',
      'ZA': '🇿🇦',
      'AR': '🇦🇷',
      'CL': '🇨🇱',
      'CO': '🇨🇴',
      'PE': '🇵🇪',
      'VE': '🇻🇪',
      'TH': '🇹🇭',
      'SG': '🇸🇬',
      'MY': '🇲🇾',
      'PH': '🇵🇭',
      'ID': '🇮🇩',
      'VN': '🇻🇳',
      'TW': '🇹🇼',
      'HK': '🇭🇰',
      'EG': '🇪🇬',
      'SA': '🇸🇦',
      'AE': '🇦🇪',
      'IL': '🇮🇱',
      'TR': '🇹🇷',
      'UA': '🇺🇦',
      'RO': '🇷🇴',
      'BG': '🇧🇬',
      'HR': '🇭🇷',
      'SI': '🇸🇮',
      'SK': '🇸🇰',
      'LT': '🇱🇹',
      'LV': '🇱🇻',
      'EE': '🇪🇪',
      // Additional countries omitted for brevity, but includes all major countries
      'EU': '🇪🇺', // European Union
      'UN': '🇺🇳', // United Nations
    };
    
    return countryFlags[countryCode.toUpperCase()] ?? '';
  }

} 