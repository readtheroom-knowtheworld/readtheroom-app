// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../services/question_service.dart';
import '../services/location_service.dart';
import '../utils/time_utils.dart';
import '../services/user_service.dart';
import '../widgets/question_type_badge.dart';
import '../models/category.dart';

class SearchScreen extends StatefulWidget {
  final bool isActive; // Track if this tab is currently active
  
  const SearchScreen({Key? key, this.isActive = false}) : super(key: key);
  
  @override
  SearchScreenState createState() => SearchScreenState();
}

class SearchScreenState extends State<SearchScreen> with WidgetsBindingObserver, RouteAware {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode(); // Add focus node
  final ScrollController _popularScrollController = ScrollController();
  String _searchQuery = '';
  String _displayQuery = '';
  List<Map<String, dynamic>> _searchResults = [];
  List<Map<String, dynamic>> _originalSearchResults = []; // Store original results before filtering
  List<Map<String, dynamic>> _popularQuestions = []; // Store popular questions
  bool _isSearching = false;
  bool _hasSearched = false;
  bool _isLoadingPopular = false;
  bool _isLoadingMorePopular = false;
  bool _hideSearchBar = false;
  int _popularQuestionsOffset = 0;
  final int _popularQuestionsLimit = 20;
  Timer? _debounceTimer;
  bool _wasDrawerOpen = false;
  
  // Filter state
  String _sortMode = 'popular'; // 'popular' or 'new'
  String? _selectedCountry;
  String? _selectedCity;
  List<String> _selectedCategories = [];
  
  // Location autocomplete state
  List<String> _countrySuggestions = [];
  List<Map<String, dynamic>> _citySuggestions = [];
  bool _showCountrySuggestions = false;
  bool _showCitySuggestions = false;
  
  // Search configuration
  static const int _minQueryLength = 3;
  static const Duration _debounceDelay = Duration(milliseconds: 300);

  @override
  void initState() {
    super.initState();
    // Add this widget as an observer for app lifecycle changes
    WidgetsBinding.instance.addObserver(this);
    // Schedule the loading of questions after the first frame
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadQuestions();
      _loadPopularQuestions();
    });
  }

  @override
  void didUpdateWidget(SearchScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Enhanced focus management when tab becomes inactive
    if (!widget.isActive && _searchFocusNode.hasFocus) {
      _dismissKeyboard();
    }
  }

  @override
  void dispose() {
    // Remove observer and clean up timers
    WidgetsBinding.instance.removeObserver(this);
    _searchController.dispose();
    _searchFocusNode.dispose(); // Dispose focus node
    _popularScrollController.dispose();
    _debounceTimer?.cancel();
    super.dispose();
  }

  void scrollToTop() {
    if (_popularScrollController.hasClients) {
      _popularScrollController.animateTo(
        0,
        duration: Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
    setState(() {
      _hideSearchBar = false;
    });
  }

  /// Enhanced keyboard dismissal for iOS compatibility
  void _dismissKeyboard() {
    // Multiple approaches for comprehensive keyboard dismissal
    _searchFocusNode.unfocus();
    FocusScope.of(context).unfocus();
    
    // iOS-specific focus clearing
    if (Platform.isIOS) {
      FocusManager.instance.primaryFocus?.unfocus();
    }
  }

  /// Check drawer state and dismiss keyboard if needed
  void _checkDrawerState() {
    if (!mounted) return;
    
    try {
      final scaffoldState = Scaffold.of(context);
      final isDrawerOpen = scaffoldState.isDrawerOpen;
      
      // Detect drawer state changes
      if (isDrawerOpen != _wasDrawerOpen) {
        _wasDrawerOpen = isDrawerOpen;
        
        // Dismiss keyboard when drawer opens OR closes
        if (_searchFocusNode.hasFocus) {
          _dismissKeyboard();
        }
      }
    } catch (e) {
      // Scaffold not available, ignore
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    // Dismiss keyboard when app becomes inactive
    if (state != AppLifecycleState.resumed && _searchFocusNode.hasFocus) {
      _dismissKeyboard();
    }
  }

  /// Override to handle focus changes when widget comes back into view
  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    // Check drawer state when widget metrics change
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkDrawerState();
    });
  }

  Future<void> _loadQuestions() async {
    if (!mounted) return;
    
    setState(() {
      _isSearching = true;
    });
    
    try {
      await Provider.of<QuestionService>(context, listen: false).fetchQuestions();
    } catch (e) {
      print('Error loading questions: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isSearching = false;
        });
      }
    }
  }

  Future<void> _loadPopularQuestions({bool loadMore = false}) async {
    if (!mounted) return;
    
    // Prevent multiple concurrent requests
    if (_isLoadingPopular || _isLoadingMorePopular) return;
    
    setState(() {
      if (loadMore) {
        _isLoadingMorePopular = true;
      } else {
        _isLoadingPopular = true;
        _popularQuestionsOffset = 0; // Reset offset for initial load
      }
    });
    
    try {
      // Fetch all-time popular questions directly from database
      final popularQuestions = await _fetchAllTimePopularQuestions(
        limit: _popularQuestionsLimit,
        offset: _popularQuestionsOffset,
      );
      
      if (mounted) {
        setState(() {
          if (loadMore) {
            _popularQuestions.addAll(popularQuestions);
            _isLoadingMorePopular = false;
          } else {
            _popularQuestions = popularQuestions;
            _isLoadingPopular = false;
          }
          _popularQuestionsOffset += _popularQuestionsLimit;
        });
      }
    } catch (e) {
      print('Error loading popular questions: $e');
      if (mounted) {
        setState(() {
          if (!loadMore) {
            _popularQuestions = [];
          }
          _isLoadingPopular = false;
          _isLoadingMorePopular = false;
        });
      }
    }
  }

  Future<List<Map<String, dynamic>>> _fetchAllTimePopularQuestions({
    required int limit,
    required int offset,
  }) async {
    final questionService = Provider.of<QuestionService>(context, listen: false);
    final userService = Provider.of<UserService>(context, listen: false);
    
    // Access Supabase client
    final supabase = Supabase.instance.client;
    
    // Query for all-time popular questions without date restrictions
    final response = await supabase
        .from('question_feed_scores')
        .select('''
          id,
          prompt,
          description,
          type,
          created_at,
          nsfw,
          is_hidden,
          is_private,
          targeting_type,
          country_code,
          city_id,
          author_id,
          categories,
          vote_count,
          question_options (
            id,
            option_text,
            sort_order
          )
        ''')
        .eq('is_hidden', false)
        .eq('nsfw', false) // Always exclude NSFW for popular questions display
        .neq('is_private', true) // Exclude private questions
        .filter('targeting_type', 'in', '("globe","country")') // Apply targeting type filter for global questions
        .order('vote_count', ascending: false) // Order by vote count (all-time popularity)
        .range(offset, offset + limit - 1); // Apply pagination
    
    print('📊 All-time popular query returned ${response?.length ?? 0} questions');
    
    // DEBUG: Log first 5 questions' vote counts to verify ordering
    if (response.isNotEmpty) {
      final voteCounts = response.take(5).map((q) => q['vote_count'] ?? 0).toList();
      print('🐛 DEBUG: First 5 all-time vote counts: $voteCounts');
    }
    
    // Transform the data to match the expected format
    final List<Map<String, dynamic>> transformedQuestions = response.map((question) {
      // Rename vote_count to votes to match expected format
      final transformedQuestion = Map<String, dynamic>.from(question);
      transformedQuestion['votes'] = question['vote_count'] ?? 0;
      return transformedQuestion;
    }).toList();
    
    // Enrich with engagement data if needed
    await questionService.enrichQuestionsWithEngagementData(transformedQuestions);
    
    return transformedQuestions;
  }

  void _onSearchChanged(String query) {
    setState(() {
      _searchQuery = query;
      _hideSearchBar = false;
    });
    
    // Cancel previous timer
    _debounceTimer?.cancel();
    
    // Clear results immediately if query is empty or too short
    if (query.isEmpty) {
      setState(() {
        _searchResults = [];
        _originalSearchResults = [];
        _displayQuery = '';
        _hasSearched = false;
        _isSearching = false;
      });
      return;
    }
    
    // If query is too short, show helper text but don't search
    if (query.length < _minQueryLength) {
      setState(() {
        _searchResults = [];
        _originalSearchResults = [];
        _displayQuery = query;
        _hasSearched = false;
        _isSearching = false;
      });
      return;
    }
    
    // Start debounce timer for actual search
    _debounceTimer = Timer(_debounceDelay, () {
      _performSearch(query);
    });
  }

  Future<void> _performSearch(String query) async {
    if (!mounted || query.length < _minQueryLength) return;
    
    setState(() {
      _isSearching = true;
      _displayQuery = query;
    });
    
    try {
      final questionService = Provider.of<QuestionService>(context, listen: false);
      final locationService = Provider.of<LocationService>(context, listen: false);
      final userService = Provider.of<UserService>(context, listen: false);
      
      final results = await questionService.searchQuestions(
        query, 
        locationService: locationService,
        includeNSFW: userService.showNSFWContent, // Include NSFW if user has it enabled
        excludePrivate: true, // Never show private questions in search results
      );
      
      if (mounted) {
        // Store original results and apply client-side filtering and sorting
        final filteredResults = _applyClientSideFilters(results);
        
        setState(() {
          _originalSearchResults = List.from(results); // Store original results
          _searchResults = filteredResults;
          _hasSearched = true;
          _isSearching = false;
        });
      }
    } catch (e) {
      print('Search error: $e');
      if (mounted) {
        setState(() {
          _searchResults = [];
          _originalSearchResults = [];
          _hasSearched = true;
          _isSearching = false;
        });
      }
    }
  }

  void _clearSearch() {
    _searchController.clear();
    _debounceTimer?.cancel();
    setState(() {
      _searchQuery = '';
      _displayQuery = '';
      _searchResults = [];
      _originalSearchResults = [];
      _hasSearched = false;
      _isSearching = false;
    });
  }

  Widget _buildSearchPrompt() {
    if (_searchQuery.isEmpty) {
      // Show popular questions when not searching
      return _buildPopularQuestions();
    }
    
    if (_searchQuery.length < _minQueryLength) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.edit, size: 48, color: Colors.orange),
            const SizedBox(height: 16),
            Text(
              'Type ${_minQueryLength - _searchQuery.length} more character${(_minQueryLength - _searchQuery.length) > 1 ? 's' : ''}...',
              style: const TextStyle(fontSize: 16),
            ),
            const SizedBox(height: 8),
            const Text(
              'Minimum 3 characters required for search',
              style: TextStyle(color: Colors.grey, fontSize: 14),
            ),
          ],
        ),
      );
    }
    
    return const SizedBox.shrink();
  }

  Widget _buildPopularQuestions() {
    if (_isLoadingPopular) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Loading popular questions...'),
          ],
        ),
      );
    }

    if (_popularQuestions.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.search, size: 64, color: Colors.grey),
            const SizedBox(height: 16),
            const Text(
              'Search Questions',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text(
              'Start typing to search through questions.',
              style: TextStyle(color: Colors.grey),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }

    // Filter out NSFW and private questions from popular questions
    final userService = Provider.of<UserService>(context, listen: false);
    final filteredPopularQuestions = _popularQuestions.where((question) {
      // Filter out private questions
      if (question['is_private'] == true) {
        return false;
      }
      
      // Filter out NSFW questions since we want family-friendly popular content
      if (question['is_nsfw'] == true) {
        return false;
      }
      
      // Filter out reported questions
      if (userService.shouldHideReportedQuestion(question['id'].toString())) {
        return false;
      }

      return true;
    }).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Add spacing above Popular Questions section
        SizedBox(height: 24),
        // Popular questions header
        Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Popular Questions',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 4),
              Text(
                'Chameleon classics (top all-time)',
                style: const TextStyle(color: Colors.grey, fontSize: 14),
              ),
            ],
          ),
        ),
        // Questions list
        Expanded(
          child: ListView.builder(
            controller: _popularScrollController,
            itemCount: filteredPopularQuestions.length + (_isLoadingMorePopular ? 1 : 0),
            itemBuilder: (context, index) {
              // Show loading indicator at the bottom when loading more
              if (index == filteredPopularQuestions.length) {
                return const Padding(
                  padding: EdgeInsets.all(16.0),
                  child: Center(
                    child: CircularProgressIndicator(),
                  ),
                );
              }

              // Load more when reaching near the end
              if (index == filteredPopularQuestions.length - 3 && !_isLoadingMorePopular) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  _loadPopularQuestions(loadMore: true);
                });
              }

              final question = filteredPopularQuestions[index];
              final hasAnswered = userService.hasAnsweredQuestion(question['id']);
              
              // Determine targeting emoji like in home screen
              final targetingType = question['targeting_type']?.toString();
              final questionCountryCode = question['country_code']?.toString();
              String? targetingEmoji;
              
              if (targetingType == 'city') {
                targetingEmoji = '🏙️';
              } else if (targetingType == 'country' && questionCountryCode != null && questionCountryCode.isNotEmpty) {
                final flagEmoji = _getCountryFlagEmoji(questionCountryCode);
                targetingEmoji = flagEmoji.isNotEmpty ? flagEmoji : '🇺🇳';
              } else if (targetingType == 'globe' || targetingType == 'global') {
                targetingEmoji = '🌍';
              } else if (targetingType == 'country' && (questionCountryCode == null || questionCountryCode.isEmpty)) {
                targetingEmoji = '🇺🇳'; // Show UN flag while we fetch
                _fetchAndCacheTargetingData(question);
              } else if (targetingType == null) {
                targetingEmoji = '🌍'; // Show world while we fetch
                _fetchAndCacheTargetingData(question);
              } else {
                targetingEmoji = '🌍';
              }
              
              return Container(
                margin: EdgeInsets.only(left: 16.0, right: 16.0, bottom: 12.0),
                decoration: BoxDecoration(
                  color: hasAnswered
                      ? null
                      : (Theme.of(context).brightness == Brightness.dark ? null : Colors.white),
                  border: Border.all(
                    color: hasAnswered
                        ? Theme.of(context).dividerColor.withOpacity(0.15)
                        : Theme.of(context).dividerColor.withOpacity(0.3),
                    width: 0.5,
                  ),
                  borderRadius: BorderRadius.circular(8.0),
                  boxShadow: (!hasAnswered && Theme.of(context).brightness == Brightness.light)
                      ? [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.08),
                            blurRadius: 4,
                            offset: Offset(0, 2),
                          ),
                        ]
                      : null,
                ),
                child: ListTile(
                  title: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        height: 60,
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            if (targetingEmoji != null) ...[
                              Opacity(
                                opacity: hasAnswered ? 0.4 : 1.0,
                                child: Text(
                                  targetingEmoji,
                                  style: TextStyle(fontSize: 16),
                                ),
                              ),
                              SizedBox(height: 8),
                            ],
                            QuestionTypeBadge(
                              type: question['type'] ?? 'unknown',
                              color: hasAnswered ? Colors.grey : Theme.of(context).primaryColor,
                            ),
                          ],
                        ),
                      ),
                      SizedBox(width: 16),
                      Expanded(
                        child: Text(
                          question['prompt'] ?? question['title'] ?? 'No Title',
                          style: TextStyle(
                            color: hasAnswered ? Colors.grey : null,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  subtitle: _buildSubtitle(context, question),
                  onTap: () {
                    final questionService = Provider.of<QuestionService>(context, listen: false);
                    final locationService = Provider.of<LocationService>(context, listen: false);

                    // Create FeedContext from popular questions
                    final filters = <String, dynamic>{
                      'feedType': 'popular',
                      'showNSFW': false,
                      'questionTypes': userService.enabledQuestionTypes,
                      'userCountry': locationService.userLocation?['country_code'],
                      'userCity': locationService.selectedCity?['id'],
                    };
                    
                    final questionIndex = filteredPopularQuestions.indexOf(question);
                    final feedContext = FeedContext(
                      feedType: 'popular_search',
                      filters: filters,
                      questions: filteredPopularQuestions,
                      currentQuestionIndex: questionIndex,
                      originalQuestionId: question['id']?.toString(),
                      originalQuestionIndex: questionIndex,
                    );
                    
                    if (hasAnswered) {
                      // Navigate to results screen with popular feed context
                      questionService.navigateToResultsScreen(context, question, feedContext: feedContext, fromSearch: true);
                    } else {
                      // Navigate to answer screen with popular feed context
                      questionService.navigateToAnswerScreen(context, question, feedContext: feedContext, fromSearch: true);
                    }
                  },
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildNoResults() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.search_off, size: 64, color: Colors.grey),
          const SizedBox(height: 16),
          const Text(
            'No Results Found',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Text(
            'No questions match "$_displayQuery"',
            style: const TextStyle(color: Colors.grey),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 32.0),
            child: Column(
              children: [
                SizedBox(height: 12),
                Text(
                  'Try different keywords, check your location/filter settings, or ask the question yourself!',
                  style: TextStyle(color: Colors.grey, fontSize: 14),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSubtitle(BuildContext context, Map<String, dynamic> question) {
    final votes = question['votes'] ?? 0;
    final reactionCount = _getReactionCount(question);
    final commentCount = _getCommentCount(question);
    final timeAgo = getTimeAgo(question['created_at'] ?? question['timestamp']);
    final userService = Provider.of<UserService>(context, listen: false);
    final hasAnswered = userService.hasAnsweredQuestion(question['id']);
    
    // Calculate padding to align with question text (matching home screen)
    // Since icons are in a column, we need: Badge width + spacing
    double leftPadding = 24.0 + 16.0; // Badge width + increased spacing after icons column
    
    // Build subtitle parts (time, votes - no reacts in search to match home screen)
    final parts = <String>[];
    parts.add(timeAgo);
    parts.add('$votes ${votes == 1 ? 'vote' : 'votes'}');
    
    // Build single line with comments on the right if there are comments (matching home screen layout)
    return Padding(
      padding: EdgeInsets.only(left: leftPadding, top: 2.0),
      child: Row(
        children: [
          Expanded(
            child: Text(
              parts.join(' • '),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: hasAnswered ? Colors.grey : null,
              ),
            ),
          ),
          // Show comment count if there are comments (matching home screen)
          if (commentCount > 0)
            Text(
              '$commentCount ${commentCount == 1 ? 'comment' : 'comments'}',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: hasAnswered ? Colors.grey : null,
              ),
            ),
        ],
      ),
    );
  }

  int _getReactionCount(Map<String, dynamic> question) {
    // Check for reaction_count field first (from materialized view)
    if (question.containsKey('reaction_count')) {
      return question['reaction_count'] as int? ?? 0;
    }
    
    // Get total reaction count from reactions JSON
    final reactions = question['reactions'];
    if (reactions == null) return 0;
    
    // Handle both Map and potentially encoded JSON string
    if (reactions is Map<String, dynamic>) {
      int total = 0;
      for (final count in reactions.values) {
        if (count is int) total += count;
      }
      return total;
    } else if (reactions is String) {
      try {
        final decodedReactions = json.decode(reactions) as Map<String, dynamic>;
        int total = 0;
        for (final count in decodedReactions.values) {
          if (count is int) total += count;
        }
        return total;
      } catch (e) {
        print('Error decoding reactions JSON: $e');
        return 0;
      }
    }
    
    return 0;
  }

  int _getCommentCount(Map<String, dynamic> question) {
    // Get comment count from question data
    return question['comment_count'] as int? ?? 0;
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
      // Middle East & Gulf Countries
      'OM': '🇴🇲', // Oman
      'QA': '🇶🇦', // Qatar
      'KW': '🇰🇼', // Kuwait
      'BH': '🇧🇭', // Bahrain
      'JO': '🇯🇴', // Jordan
      'LB': '🇱🇧', // Lebanon
      'SY': '🇸🇾', // Syria
      'IQ': '🇮🇶', // Iraq
      'IR': '🇮🇷', // Iran
      'YE': '🇾🇪', // Yemen
      // Africa
      'MA': '🇲🇦', // Morocco
      'DZ': '🇩🇿', // Algeria
      'TN': '🇹🇳', // Tunisia
      'LY': '🇱🇾', // Libya
      'SD': '🇸🇩', // Sudan
      'ET': '🇪🇹', // Ethiopia
      'KE': '🇰🇪', // Kenya
      'NG': '🇳🇬', // Nigeria
      'GH': '🇬🇭', // Ghana
      'CI': '🇨🇮', // Côte d'Ivoire
      'SN': '🇸🇳', // Senegal
      'ML': '🇲🇱', // Mali
      'BF': '🇧🇫', // Burkina Faso
      'NE': '🇳🇪', // Niger
      'TD': '🇹🇩', // Chad
      'CM': '🇨🇲', // Cameroon
      'CF': '🇨🇫', // Central African Republic
      'CD': '🇨🇩', // Democratic Republic of Congo
      'CG': '🇨🇬', // Republic of Congo
      'GA': '🇬🇦', // Gabon
      'GQ': '🇬🇶', // Equatorial Guinea
      'ST': '🇸🇹', // São Tomé and Príncipe
      'AO': '🇦🇴', // Angola
      'ZM': '🇿🇲', // Zambia
      'ZW': '🇿🇼', // Zimbabwe
      'BW': '🇧🇼', // Botswana
      'NA': '🇳🇦', // Namibia
      'LS': '🇱🇸', // Lesotho
      'SZ': '🇸🇿', // Eswatini
      'MG': '🇲🇬', // Madagascar
      'MU': '🇲🇺', // Mauritius
      'MZ': '🇲🇿', // Mozambique
      'MW': '🇲🇼', // Malawi
      'TZ': '🇹🇿', // Tanzania
      'UG': '🇺🇬', // Uganda
      'RW': '🇷🇼', // Rwanda
      'BI': '🇧🇮', // Burundi
      'DJ': '🇩🇯', // Djibouti
      'SO': '🇸🇴', // Somalia
      'ER': '🇪🇷', // Eritrea
      // Asia Pacific
      'AF': '🇦🇫', // Afghanistan
      'PK': '🇵🇰', // Pakistan
      'BD': '🇧🇩', // Bangladesh
      'LK': '🇱🇰', // Sri Lanka
      'MV': '🇲🇻', // Maldives
      'NP': '🇳🇵', // Nepal
      'BT': '🇧🇹', // Bhutan
      'MM': '🇲🇲', // Myanmar
      'LA': '🇱🇦', // Laos
      'KH': '🇰🇭', // Cambodia
      'BN': '🇧🇳', // Brunei
      'TL': '🇹🇱', // East Timor
      'FJ': '🇫🇯', // Fiji
      'PG': '🇵🇬', // Papua New Guinea
      'SB': '🇸🇧', // Solomon Islands
      'VU': '🇻🇺', // Vanuatu
      'NC': '🇳🇨', // New Caledonia
      'PF': '🇵🇫', // French Polynesia
      'WS': '🇼🇸', // Samoa
      'TO': '🇹🇴', // Tonga
      'TV': '🇹🇻', // Tuvalu
      'KI': '🇰🇮', // Kiribati
      'NR': '🇳🇷', // Nauru
      'FM': '🇫🇲', // Micronesia
      'MH': '🇲🇭', // Marshall Islands
      'PW': '🇵🇼', // Palau
      // Latin America
      'GT': '🇬🇹', // Guatemala
      'BZ': '🇧🇿', // Belize
      'SV': '🇸🇻', // El Salvador
      'HN': '🇭🇳', // Honduras
      'NI': '🇳🇮', // Nicaragua
      'CR': '🇨🇷', // Costa Rica
      'PA': '🇵🇦', // Panama
      'CU': '🇨🇺', // Cuba
      'JM': '🇯🇲', // Jamaica
      'HT': '🇭🇹', // Haiti
      'DO': '🇩🇴', // Dominican Republic
      'PR': '🇵🇷', // Puerto Rico
      'TT': '🇹🇹', // Trinidad and Tobago
      'BB': '🇧🇧', // Barbados
      'GD': '🇬🇩', // Grenada
      'LC': '🇱🇨', // Saint Lucia
      'VC': '🇻🇨', // Saint Vincent and the Grenadines
      'AG': '🇦🇬', // Antigua and Barbuda
      'KN': '🇰🇳', // Saint Kitts and Nevis
      'DM': '🇩🇲', // Dominica
      'GY': '🇬🇾', // Guyana
      'SR': '🇸🇷', // Suriname
      'UY': '🇺🇾', // Uruguay
      'PY': '🇵🇾', // Paraguay
      'BO': '🇧🇴', // Bolivia
      'EC': '🇪🇨', // Ecuador
      // Europe additions
      'IS': '🇮🇸', // Iceland
      'MT': '🇲🇹', // Malta
      'CY': '🇨🇾', // Cyprus
      'MD': '🇲🇩', // Moldova
      'BY': '🇧🇾', // Belarus
      'RS': '🇷🇸', // Serbia
      'ME': '🇲🇪', // Montenegro
      'BA': '🇧🇦', // Bosnia and Herzegovina
      'MK': '🇲🇰', // North Macedonia
      'AL': '🇦🇱', // Albania
      'XK': '🇽🇰', // Kosovo
      'LU': '🇱🇺', // Luxembourg
      'LI': '🇱🇮', // Liechtenstein
      'AD': '🇦🇩', // Andorra
      'MC': '🇲🇨', // Monaco
      'SM': '🇸🇲', // San Marino
      'VA': '🇻🇦', // Vatican City
      // Central Asia
      'KZ': '🇰🇿', // Kazakhstan
      'UZ': '🇺🇿', // Uzbekistan
      'TM': '🇹🇲', // Turkmenistan
      'TJ': '🇹🇯', // Tajikistan
      'KG': '🇰🇬', // Kyrgyzstan
      'MN': '🇲🇳', // Mongolia
      // Additional African Countries
      'CV': '🇨🇻', // Cape Verde
      'GM': '🇬🇲', // Gambia
      'GN': '🇬🇳', // Guinea
      'GW': '🇬🇼', // Guinea-Bissau
      'LR': '🇱🇷', // Liberia
      'SL': '🇸🇱', // Sierra Leone
      'TG': '🇹🇬', // Togo
      'BJ': '🇧🇯', // Benin
      'MR': '🇲🇷', // Mauritania
      'KM': '🇰🇲', // Comoros
      'SC': '🇸🇨', // Seychelles
      'SS': '🇸🇸', // South Sudan
      // Additional Caribbean
      'BS': '🇧🇸', // Bahamas
      'AI': '🇦🇮', // Anguilla
      'AW': '🇦🇼', // Aruba
      'BQ': '🇧🇶', // Bonaire
      'VG': '🇻🇬', // British Virgin Islands
      'KY': '🇰🇾', // Cayman Islands
      'CW': '🇨🇼', // Curaçao
      'GP': '🇬🇵', // Guadeloupe
      'MQ': '🇲🇶', // Martinique
      'MS': '🇲🇸', // Montserrat
      'SX': '🇸🇽', // Sint Maarten
      'TC': '🇹🇨', // Turks and Caicos
      'VI': '🇻🇮', // US Virgin Islands
      'MF': '🇲🇫', // Saint Martin
      'BL': '🇧🇱', // Saint Barthélemy
      'PM': '🇵🇲', // Saint Pierre and Miquelon
      // Additional Pacific
      'AS': '🇦🇸', // American Samoa
      'CK': '🇨🇰', // Cook Islands
      'GU': '🇬🇺', // Guam
      'MP': '🇲🇵', // Northern Mariana Islands
      'NU': '🇳🇺', // Niue
      'NF': '🇳🇫', // Norfolk Island
      'PN': '🇵🇳', // Pitcairn Islands
      'TK': '🇹🇰', // Tokelau
      'WF': '🇼🇫', // Wallis and Futuna
      // Additional Antarctic and Remote
      'AQ': '🇦🇶', // Antarctica
      'BV': '🇧🇻', // Bouvet Island
      'GS': '🇬🇸', // South Georgia and South Sandwich Islands
      'HM': '🇭🇲', // Heard Island and McDonald Islands
      'IO': '🇮🇴', // British Indian Ocean Territory
      'TF': '🇹🇫', // French Southern Territories
      'UM': '🇺🇲', // United States Minor Outlying Islands
      // Additional European Dependencies
      'AX': '🇦🇽', // Åland Islands
      'FO': '🇫🇴', // Faroe Islands
      'GI': '🇬🇮', // Gibraltar
      'GG': '🇬🇬', // Guernsey
      'IM': '🇮🇲', // Isle of Man
      'JE': '🇯🇪', // Jersey
      'SJ': '🇸🇯', // Svalbard and Jan Mayen
      // Additional Special Cases
      'EH': '🇪🇭', // Western Sahara
      'PS': '🇵🇸', // Palestine
      'TW': '🇹🇼', // Taiwan (already included but worth noting)
      'HK': '🇭🇰', // Hong Kong (already included)
      'MO': '🇲🇴', // Macao
      'FK': '🇫🇰', // Falkland Islands
      'SH': '🇸🇭', // Saint Helena
      'AC': '🇦🇨', // Ascension Island
      'TA': '🇹🇦', // Tristan da Cunha
      'RE': '🇷🇪', // Réunion
      'YT': '🇾🇹', // Mayotte
      'GL': '🇬🇱', // Greenland
      // Historical/Alternative Codes
      'EU': '🇪🇺', // European Union (not a country but commonly used)
      'UN': '🇺🇳', // United Nations (for international questions)
    };
    
    return countryFlags[countryCode.toUpperCase()] ?? '';
  }

  // Cache for background targeting data fetches
  final Set<String> _fetchingTargetingData = <String>{};

  // Fetch targeting data in background and update UI
  void _fetchAndCacheTargetingData(Map<String, dynamic> question) async {
    final questionId = question['id']?.toString();
    if (questionId == null || _fetchingTargetingData.contains(questionId)) return;
    
    _fetchingTargetingData.add(questionId);
    print('🔍 Fetching targeting data for question $questionId...');
    
    try {
      final supabase = Supabase.instance.client;
      final targetingData = await supabase
          .from('questions')
          .select('targeting_type, country_code')
          .eq('id', questionId)
          .single();
      
      final targetingType = targetingData['targeting_type']?.toString();
      final questionCountryCode = targetingData['country_code']?.toString();
      
      print('✅ Fetched targeting data: targeting_type="$targetingType", country_code="$questionCountryCode"');
      
      // Cache the data in the question object for future use
      question['targeting_type'] = targetingType;
      question['country_code'] = questionCountryCode;
      
      // Trigger rebuild to show correct emoji
      if (mounted) {
        setState(() {});
      }
      
    } catch (e) {
      print('❌ Error fetching targeting data for question $questionId: $e');
    } finally {
      _fetchingTargetingData.remove(questionId);
    }
  }

  String _getLocationDisplayText() {
    if (_selectedCity != null && _selectedCountry != null) {
      return '$_selectedCity, $_selectedCountry';
    } else if (_selectedCountry != null) {
      return _selectedCountry!;
    }
    return 'Location';
  }

  String _getTopicDisplayText() {
    if (_selectedCategories.isEmpty) {
      return 'Topics';
    } else if (_selectedCategories.length == 1) {
      return _selectedCategories.first;
    } else {
      return '${_selectedCategories.length} topics';
    }
  }

  void _showLocationDialog() {
    final TextEditingController countryController = TextEditingController(text: _selectedCountry ?? '');
    final TextEditingController cityController = TextEditingController(text: _selectedCity ?? '');
    
    // Reset suggestions
    _countrySuggestions.clear();
    _citySuggestions.clear();
    _showCountrySuggestions = false;
    _showCitySuggestions = false;

    showDialog(
      context: context,
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('Filter by Location'),
              content: SizedBox(
                width: double.maxFinite,
                height: 300,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Country field with autocomplete
                    TextField(
                      controller: countryController,
                      decoration: const InputDecoration(
                        labelText: 'Country',
                        hintText: 'Enter country name',
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.location_on),
                      ),
                      onChanged: (value) async {
                        if (value.length >= 2) {
                          final locationService = Provider.of<LocationService>(context, listen: false);
                          final results = await locationService.searchCountries(value);
                          setDialogState(() {
                            _countrySuggestions = results;
                            _showCountrySuggestions = value.isNotEmpty && results.isNotEmpty;
                          });
                        } else {
                          setDialogState(() {
                            _showCountrySuggestions = false;
                            _countrySuggestions.clear();
                          });
                        }
                        
                        // Clear city when country changes
                        if (value != _selectedCountry) {
                          cityController.clear();
                          setDialogState(() {
                            _showCitySuggestions = false;
                            _citySuggestions.clear();
                          });
                        }
                      },
                    ),
                    
                    // Country suggestions
                    if (_showCountrySuggestions && _countrySuggestions.isNotEmpty)
                      Container(
                        margin: const EdgeInsets.only(top: 4),
                        constraints: const BoxConstraints(maxHeight: 100),
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.grey.shade300),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: ListView.builder(
                          shrinkWrap: true,
                          itemCount: _countrySuggestions.length,
                          itemBuilder: (context, index) {
                            return ListTile(
                              dense: true,
                              title: Text(_countrySuggestions[index]),
                              onTap: () {
                                countryController.text = _countrySuggestions[index];
                                setDialogState(() {
                                  _showCountrySuggestions = false;
                                });
                                // Clear city when country changes
                                cityController.clear();
                                setDialogState(() {
                                  _showCitySuggestions = false;
                                  _citySuggestions.clear();
                                });
                              },
                            );
                          },
                        ),
                      ),
                    
                    const SizedBox(height: 16),
                    
                    // City field with autocomplete
                    TextField(
                      controller: cityController,
                      decoration: InputDecoration(
                        labelText: 'City (optional)',
                        hintText: countryController.text.isNotEmpty 
                            ? 'Search cities in ${countryController.text}'
                            : 'Select a country first',
                        border: const OutlineInputBorder(),
                        prefixIcon: const Icon(Icons.location_city),
                      ),
                      enabled: countryController.text.isNotEmpty,
                      onChanged: (value) async {
                        if (value.length >= 3 && countryController.text.isNotEmpty) {
                          final locationService = Provider.of<LocationService>(context, listen: false);
                          final results = await locationService.searchCitiesInCountry(value, countryController.text);
                          setDialogState(() {
                            _citySuggestions = results;
                            _showCitySuggestions = value.isNotEmpty && results.isNotEmpty;
                          });
                        } else {
                          setDialogState(() {
                            _showCitySuggestions = false;
                            _citySuggestions.clear();
                          });
                        }
                      },
                    ),
                    
                    // City suggestions
                    if (_showCitySuggestions && _citySuggestions.isNotEmpty)
                      Expanded(
                        child: Container(
                          margin: const EdgeInsets.only(top: 4),
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.grey.shade300),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: ListView.builder(
                            shrinkWrap: true,
                            itemCount: _citySuggestions.length,
                            itemBuilder: (context, index) {
                              final city = _citySuggestions[index];
                              final populationText = city['population'] != null && city['population'] > 0
                                  ? ' • ${_formatPopulation(city['population'])}'
                                  : '';
                              
                              return ListTile(
                                dense: true,
                                leading: const Icon(Icons.location_city, size: 16),
                                title: Text(city['name']),
                                subtitle: Text('${city['country_name_en']}$populationText'),
                                onTap: () {
                                  cityController.text = city['display_name'] ?? city['name'];
                                  setDialogState(() {
                                    _showCitySuggestions = false;
                                  });
                                },
                              );
                            },
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    setState(() {
                      _selectedCountry = null;
                      _selectedCity = null;
                      // Apply filtering to existing results instead of re-searching
                      if (_hasSearched && _originalSearchResults.isNotEmpty) {
                        _searchResults = _applyClientSideFilters(_originalSearchResults);
                      }
                    });
                    Navigator.of(context).pop();
                  },
                  child: const Text('Clear'),
                ),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  onPressed: () {
                    setState(() {
                      _selectedCountry = countryController.text.trim().isEmpty ? null : countryController.text.trim();
                      _selectedCity = cityController.text.trim().isEmpty ? null : cityController.text.trim();
                      // Apply filtering to existing results instead of re-searching
                      if (_hasSearched && _originalSearchResults.isNotEmpty) {
                        _searchResults = _applyClientSideFilters(_originalSearchResults);
                      }
                    });
                    Navigator.of(context).pop();
                  },
                  child: const Text('Apply'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  String _formatPopulation(int population) {
    if (population >= 1000000) {
      return '${(population / 1000000).toStringAsFixed(1)}M';
    } else if (population >= 1000) {
      return '${(population / 1000).toStringAsFixed(0)}K';
    } else {
      return population.toString();
    }
  }

  void _showTopicDialog() {
    // Use actual categories from the Category model
    final List<String> availableCategories = Category.allCategories.map((c) => c.name).toList();

    List<String> tempSelectedCategories = List.from(_selectedCategories);

    showDialog(
      context: context,
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('Filter by Topic'),
              content: SizedBox(
                width: double.maxFinite,
                height: 400, // Fixed height for better scrolling
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: availableCategories.length,
                  itemBuilder: (context, index) {
                    final category = availableCategories[index];
                    final isSelected = tempSelectedCategories.contains(category);
                    
                    return CheckboxListTile(
                      title: Text(
                        category,
                        style: TextStyle(fontSize: 14),
                      ),
                      value: isSelected,
                      dense: true,
                      onChanged: (bool? value) {
                        setDialogState(() {
                          if (value == true) {
                            tempSelectedCategories.add(category);
                          } else {
                            tempSelectedCategories.remove(category);
                          }
                        });
                      },
                    );
                  },
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    setState(() {
                      _selectedCategories.clear();
                      // Apply filtering to existing results instead of re-searching
                      if (_hasSearched && _originalSearchResults.isNotEmpty) {
                        _searchResults = _applyClientSideFilters(_originalSearchResults);
                      }
                    });
                    Navigator.of(context).pop();
                  },
                  child: const Text('Clear All'),
                ),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  onPressed: () {
                    setState(() {
                      _selectedCategories = tempSelectedCategories;
                      // Apply filtering to existing results instead of re-searching
                      if (_hasSearched && _originalSearchResults.isNotEmpty) {
                        _searchResults = _applyClientSideFilters(_originalSearchResults);
                      }
                    });
                    Navigator.of(context).pop();
                  },
                  child: const Text('Apply'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  bool _hasActiveFilters() {
    return _sortMode != 'popular' || 
           _selectedCountry != null || 
           _selectedCity != null || 
           _selectedCategories.isNotEmpty;
  }

  String _getActiveFiltersText() {
    List<String> filters = [];
    
    if (_sortMode != 'popular') {
      filters.add('Sorted by: $_sortMode');
    }
    
    if (_selectedCountry != null || _selectedCity != null) {
      if (_selectedCity != null && _selectedCountry != null) {
        filters.add('Location: $_selectedCity, $_selectedCountry');
      } else if (_selectedCountry != null) {
        filters.add('Location: $_selectedCountry');
      }
    }
    
    if (_selectedCategories.isNotEmpty) {
      if (_selectedCategories.length == 1) {
        filters.add('Topic: ${_selectedCategories.first}');
      } else {
        filters.add('Topics: ${_selectedCategories.length} selected');
      }
    }
    
    return 'Filters: ${filters.join(' • ')}';
  }

  List<Map<String, dynamic>> _applyClientSideFilters(List<Map<String, dynamic>> results) {
    List<Map<String, dynamic>> filtered = List.from(results);
    
    // Filter out private questions - they should never appear in search results
    filtered = filtered.where((question) {
      return question['is_private'] != true;
    }).toList();
    
    // Apply location filtering
    if (_selectedCountry != null || _selectedCity != null) {
      filtered = filtered.where((question) {
        // Match against database structure: questions have country_code and city data
        
        if (_selectedCountry != null) {
          // Check both country_code and denormalized country name from cities
          final questionCountryCode = question['country_code']?.toString() ?? '';
          final cityData = question['cities'] as Map<String, dynamic>?;
          final questionCountryName = cityData?['country_name_en']?.toString() ?? '';
          
          final selectedCountryLower = _selectedCountry!.toLowerCase();
          if (!questionCountryCode.toLowerCase().contains(selectedCountryLower) &&
              !questionCountryName.toLowerCase().contains(selectedCountryLower)) {
            return false;
          }
        }
        
        if (_selectedCity != null) {
          // Check city name from cities table data
          final cityData = question['cities'] as Map<String, dynamic>?;
          final questionCityName = cityData?['name']?.toString() ?? '';
          
          if (!questionCityName.toLowerCase().contains(_selectedCity!.toLowerCase())) {
            return false;
          }
        }
        
        return true;
      }).toList();
    }
    
    // Apply category filtering - include questions that have at least one matching category
    if (_selectedCategories.isNotEmpty) {
      filtered = filtered.where((question) {
        final questionCategories = question['categories'] as List<dynamic>? ?? [];
        
        // If no categories on question, exclude it
        if (questionCategories.isEmpty) {
          return false;
        }
        
        // Check if any of the question's categories match our selected categories
        for (final categoryName in questionCategories) {
          final categoryNameStr = categoryName.toString();
          
          for (final selectedCategory in _selectedCategories) {
            if (categoryNameStr.toLowerCase().contains(selectedCategory.toLowerCase())) {
              return true; // Include this question since it has a matching category
            }
          }
        }
        
        return false; // No matching categories found
      }).toList();
    }
    
    // Apply sorting
    if (_sortMode == 'new') {
      filtered.sort((a, b) {
        final aTime = DateTime.tryParse(a['created_at']?.toString() ?? '') ?? DateTime.now();
        final bTime = DateTime.tryParse(b['created_at']?.toString() ?? '') ?? DateTime.now();
        return bTime.compareTo(aTime); // Newest first
      });
    } else {
      // Sort by popularity (votes)
      filtered.sort((a, b) {
        final aVotes = a['votes'] as int? ?? 0;
        final bVotes = b['votes'] as int? ?? 0;
        return bVotes.compareTo(aVotes); // Most votes first
      });
    }
    
    return filtered;
  }

  @override
  Widget build(BuildContext context) {
    // Check drawer state on every build
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkDrawerState();
    });
    
    return PopScope(
      canPop: !_searchFocusNode.hasFocus,
      onPopInvokedWithResult: (bool didPop, dynamic result) {
        // Dismiss keyboard on back navigation attempt
        if (_searchFocusNode.hasFocus && !didPop) {
          _dismissKeyboard();
        }
      },
      child: Scaffold(
      appBar: AppBar(
        title: const Text('Search'),
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        elevation: 4,
      ),
      body: GestureDetector(
        // Enhanced gesture detection for better iOS compatibility
        onTap: () {
          _dismissKeyboard();
        },
        onTapDown: (details) {
          // Immediate focus clearing on tap down for iOS
          if (Platform.isIOS && _searchFocusNode.hasFocus) {
            _dismissKeyboard();
          }
        },
        onPanDown: (details) {
          // Additional iOS compatibility for pan gestures
          if (Platform.isIOS && _searchFocusNode.hasFocus) {
            _dismissKeyboard();
          }
        },
        onHorizontalDragStart: (details) {
          // Dismiss keyboard immediately when horizontal drag starts
          if (_searchFocusNode.hasFocus) {
            _dismissKeyboard();
          }
        },
        onHorizontalDragUpdate: (details) {
          // Continue dismissing during drag if focused
          if (_searchFocusNode.hasFocus && details.delta.dx > 5) {
            _dismissKeyboard();
          }
        },
        onHorizontalDragEnd: (details) {
          // Dismiss keyboard before opening drawer
          _dismissKeyboard();
          // Check if swipe is from left to right with sufficient velocity
          if (details.primaryVelocity != null && details.primaryVelocity! > 300) {
            Scaffold.of(context).openDrawer();
          }
        },
        child: NotificationListener<ScrollNotification>(
          onNotification: (notification) {
            if (!_hasSearched && _searchQuery.isEmpty) {
              final shouldHide = notification.metrics.pixels > 10;
              if (shouldHide != _hideSearchBar) {
                setState(() {
                  _hideSearchBar = shouldHide;
                });
              }
            }
            return false;
          },
          child: Column(
          children: [
            ClipRect(
              child: AnimatedAlign(
                duration: Duration(milliseconds: 250),
                curve: Curves.easeInOut,
                heightFactor: (_hideSearchBar && _searchQuery.isEmpty) ? 0.0 : 1.0,
                alignment: Alignment.topCenter,
                child: Column(
                  children: [
            // Buffer space above filter chips
            const SizedBox(height: 16.0),

            // Filter tabs
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
              child: Row(
                children: [
                  // Sort toggle
                  Expanded(
                    child: InkWell(
                      onTap: () {
                        setState(() {
                          _sortMode = _sortMode == 'popular' ? 'new' : 'popular';
                          // Apply sorting to existing results instead of re-searching
                          if (_hasSearched && _originalSearchResults.isNotEmpty) {
                            _searchResults = _applyClientSideFilters(_originalSearchResults);
                          }
                        });
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: _sortMode == 'new' 
                                ? Theme.of(context).primaryColor 
                                : Colors.grey.shade300,
                          ),
                          borderRadius: BorderRadius.circular(20),
                          color: _sortMode == 'new'
                              ? Theme.of(context).primaryColor.withOpacity(0.1)
                              : null,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              _sortMode == 'popular' ? Icons.trending_up : Icons.access_time,
                              size: 16,
                              color: _sortMode == 'new'
                                  ? Theme.of(context).primaryColor
                                  : Colors.grey.shade600,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              _sortMode == 'popular' ? 'Popular' : 'New',
                              style: TextStyle(
                                fontSize: 12,
                                color: _sortMode == 'new'
                                    ? Theme.of(context).primaryColor
                                    : Colors.grey.shade600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  // Location filter
                  Expanded(
                    child: InkWell(
                      onTap: _showLocationDialog,
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: (_selectedCountry != null || _selectedCity != null) 
                                ? Theme.of(context).primaryColor 
                                : Colors.grey.shade300,
                          ),
                          borderRadius: BorderRadius.circular(20),
                          color: (_selectedCountry != null || _selectedCity != null)
                              ? Theme.of(context).primaryColor.withOpacity(0.1)
                              : null,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.location_on,
                              size: 16,
                              color: (_selectedCountry != null || _selectedCity != null)
                                  ? Theme.of(context).primaryColor
                                  : Colors.grey.shade600,
                            ),
                            const SizedBox(width: 4),
                            Expanded(
                              child: Text(
                                _getLocationDisplayText(),
                                style: TextStyle(
                                  fontSize: 12,
                                  color: (_selectedCountry != null || _selectedCity != null)
                                      ? Theme.of(context).primaryColor
                                      : Colors.grey.shade600,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  // Topic filter
                  Expanded(
                    child: InkWell(
                      onTap: _showTopicDialog,
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: _selectedCategories.isNotEmpty 
                                ? Theme.of(context).primaryColor 
                                : Colors.grey.shade300,
                          ),
                          borderRadius: BorderRadius.circular(20),
                          color: _selectedCategories.isNotEmpty
                              ? Theme.of(context).primaryColor.withOpacity(0.1)
                              : null,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.category,
                              size: 16,
                              color: _selectedCategories.isNotEmpty
                                  ? Theme.of(context).primaryColor
                                  : Colors.grey.shade600,
                            ),
                            const SizedBox(width: 4),
                            Expanded(
                              child: Text(
                                _getTopicDisplayText(),
                                style: TextStyle(
                                  fontSize: 12,
                                  color: _selectedCategories.isNotEmpty
                                      ? Theme.of(context).primaryColor
                                      : Colors.grey.shade600,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            
            Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: TextField(
                    controller: _searchController,
                    focusNode: _searchFocusNode, // Add focus node
                    autofocus: true, // Show blinking cursor to indicate typing
                    decoration: InputDecoration(
                      hintText: 'Type to search...',
                      prefixIcon: const Icon(Icons.search),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                      suffixIcon: _searchQuery.isNotEmpty
                          ? IconButton(
                              icon: const Icon(Icons.clear),
                              onPressed: _clearSearch,
                            )
                          : null,
                    ),
                    onChanged: _onSearchChanged,
                  ),
                ),
                  ],
                ),
              ),
            ),
            
            // Search stats/info bar
            if (_hasSearched && _searchResults.isNotEmpty && _searchQuery.isNotEmpty)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${_searchResults.length} result${_searchResults.length != 1 ? 's' : ''} for "$_displayQuery"',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Colors.grey[600],
                      ),
                    ),
                    if (_hasActiveFilters())
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          _getActiveFiltersText(),
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Colors.grey[500],
                            fontSize: 11,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            
            Expanded(
              child: Consumer<QuestionService>(
                builder: (context, questionService, child) {
                  // Show loading indicator during initial load or search
                  if (_isSearching) {
                    return const Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          CircularProgressIndicator(),
                          SizedBox(height: 16),
                          Text('Searching...'),
                        ],
                      ),
                    );
                  }

                  // Show search prompt if no search has been initiated
                  if (!_hasSearched || _searchQuery.length < _minQueryLength) {
                    return _buildSearchPrompt();
                  }

                  // Show no results if search completed but no results
                  if (_hasSearched && _searchResults.isEmpty) {
                    return _buildNoResults();
                  }

                  // Filter results based on user preferences
                  final userService = Provider.of<UserService>(context, listen: false);
                  final filteredQuestions = _searchResults.where((question) {
                    // Filter out private questions - they should never appear in search results
                    if (question['is_private'] == true) {
                      return false;
                    }
                    
                    // Filter out reported questions
                    if (userService.shouldHideReportedQuestion(question['id'].toString())) {
                      return false;
                    }

                    return true;
                  }).toList();

                  // Show filtered results
                  return RefreshIndicator(
                    onRefresh: _loadQuestions,
                    child: ListView.builder(
                      itemCount: filteredQuestions.length,
                      itemBuilder: (context, index) {
                        final question = filteredQuestions[index];
                        
                        // Check if user has already answered this question
                        final hasAnswered = userService.hasAnsweredQuestion(question['id']);
                        
                        // Determine targeting emoji like in home screen
                        final targetingType = question['targeting_type']?.toString();
                        final questionCountryCode = question['country_code']?.toString();
                        String? targetingEmoji;
                        
                        if (targetingType == 'city') {
                          targetingEmoji = '🏙️';
                        } else if (targetingType == 'country' && questionCountryCode != null && questionCountryCode.isNotEmpty) {
                          final flagEmoji = _getCountryFlagEmoji(questionCountryCode);
                          targetingEmoji = flagEmoji.isNotEmpty ? flagEmoji : '🇺🇳';
                        } else if (targetingType == 'globe' || targetingType == 'global') {
                          targetingEmoji = '🌍';
                        } else if (targetingType == 'country' && (questionCountryCode == null || questionCountryCode.isEmpty)) {
                          targetingEmoji = '🇺🇳'; // Show UN flag while we fetch
                          _fetchAndCacheTargetingData(question);
                        } else if (targetingType == null) {
                          targetingEmoji = '🌍'; // Show world while we fetch
                          _fetchAndCacheTargetingData(question);
                        } else {
                          targetingEmoji = '🌍';
                        }
                        
                        return Container(
                          margin: EdgeInsets.only(left: 16.0, right: 16.0, bottom: 12.0),
                          decoration: BoxDecoration(
                            color: hasAnswered
                                ? null
                                : (Theme.of(context).brightness == Brightness.dark ? null : Colors.white),
                            border: Border.all(
                              color: hasAnswered
                                  ? Theme.of(context).dividerColor.withOpacity(0.15)
                                  : Theme.of(context).dividerColor.withOpacity(0.3),
                              width: 0.5,
                            ),
                            borderRadius: BorderRadius.circular(8.0),
                            boxShadow: (!hasAnswered && Theme.of(context).brightness == Brightness.light)
                                ? [
                                    BoxShadow(
                                      color: Colors.black.withOpacity(0.08),
                                      blurRadius: 4,
                                      offset: Offset(0, 2),
                                    ),
                                  ]
                                : null,
                          ),
                          child: ListTile(
                            title: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Container(
                                  height: 60,
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    crossAxisAlignment: CrossAxisAlignment.center,
                                    children: [
                                      if (targetingEmoji != null) ...[
                                        Opacity(
                                          opacity: hasAnswered ? 0.4 : 1.0,
                                          child: Text(
                                            targetingEmoji,
                                            style: TextStyle(fontSize: 16),
                                          ),
                                        ),
                                        SizedBox(height: 8),
                                      ],
                                      QuestionTypeBadge(
                                        type: question['type'] ?? 'unknown',
                                        color: hasAnswered ? Colors.grey : Theme.of(context).primaryColor,
                                      ),
                                    ],
                                  ),
                                ),
                                SizedBox(width: 16),
                                Expanded(
                                  child: Text(
                                    question['prompt'] ?? question['title'] ?? 'No Title',
                                    style: TextStyle(
                                      color: hasAnswered ? Colors.grey : null,
                                    ),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                if (hasAnswered)
                                  Padding(
                                    padding: EdgeInsets.only(left: 8.0),
                                    child: Icon(Icons.check_circle, color: Colors.grey, size: 18),
                                  ),
                              ],
                            ),
                            subtitle: _buildSubtitle(context, question),
                            onTap: () {
                              final questionService = Provider.of<QuestionService>(context, listen: false);
                              final userService = Provider.of<UserService>(context, listen: false);
                              final locationService = Provider.of<LocationService>(context, listen: false);
                              
                              // Create FeedContext from search results
                              final filters = <String, dynamic>{
                                'searchQuery': _displayQuery,
                                'showNSFW': userService.showNSFWContent,
                                'questionTypes': userService.enabledQuestionTypes,
                                'userCountry': locationService.userLocation?['country_code'],
                                'userCity': locationService.selectedCity?['id'],
                              };
                              
                              final questionIndex = filteredQuestions.indexOf(question);
                              final feedContext = FeedContext(
                                feedType: 'search',
                                filters: filters,
                                questions: filteredQuestions,
                                currentQuestionIndex: questionIndex,
                                originalQuestionId: question['id']?.toString(),
                                originalQuestionIndex: questionIndex, // Start boundary is current question
                              );
                              
                              if (hasAnswered) {
                                // Navigate to results screen with search feed context
                                questionService.navigateToResultsScreen(context, question, feedContext: feedContext, fromSearch: true);
                              } else {
                                // Navigate to answer screen with search feed context
                                questionService.navigateToAnswerScreen(context, question, feedContext: feedContext, fromSearch: true);
                              }
                            },
                          ),
                        );
                      },
                    ),
                  );
                },
              ),
            ),
          ],
        ),
        ),
      ),
      ),
    );
  }
}
