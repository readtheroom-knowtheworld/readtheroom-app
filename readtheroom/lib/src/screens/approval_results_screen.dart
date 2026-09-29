// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/user_service.dart';
import '../services/guest_user_tracking_service.dart';
import '../utils/approval_labels.dart';
import '../utils/time_utils.dart';
import '../utils/results_colors.dart';
import 'report_question_screen.dart';
import 'package:share_plus/share_plus.dart';
import 'base_results_screen.dart';
import '../widgets/network_results_section.dart';
import '../widgets/country_approval_map.dart';
import '../services/question_service.dart';
import '../services/country_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../services/location_service.dart';
import 'dart:math' as math;
import 'dart:math' show Random;
import '../models/category.dart';
import 'dart:async';
import '../widgets/notification_bell.dart';
import '../widgets/swipe_navigation_wrapper.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../utils/category_navigation.dart';
import '../widgets/comments_section.dart';
import '../widgets/comments_overlay.dart';
import '../widgets/question_reactions_widget.dart';
import '../widgets/linked_questions_section.dart';
import '../widgets/country_filter_dialog.dart';
import '../widgets/country_comparison_dialog.dart';
import '../widgets/question_rating_section.dart';
import '../utils/generation_utils.dart';
import '../utils/network_breakdown.dart';
import '../models/network_results.dart';
import '../services/network_service.dart';
import '../services/analytics_service.dart';
import '../widgets/approval_dot_plot.dart';
import '../widgets/mc_dot_row.dart';
import '../utils/dot_plot_threshold.dart';
import 'main_screen.dart';
import '../widgets/send_to_friend_sheet.dart';
import '../models/question_results.dart';
import '../services/results_service.dart';

class ApprovalResultsScreen extends BaseResultsScreen {
  final FeedContext? feedContext;

  const ApprovalResultsScreen({
    Key? key,
    required super.question,
    super.results,
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

  /// The server-computed results for this question. Since the answers read
  /// lockdown (2026-09-22) this screen never holds answer rows — every number
  /// below is a slice of this object.
  late QuestionResults _results = initialResults;
  final ResultsService _resultsService = ResultsService();
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
  int _ratingSectionRefreshKey = 0;

  // Comparison mode variables
  bool _isComparisonMode = false;
  String? _comparisonCountry1;
  String? _comparisonCountry2;

  /// "My Network": the viewer's friends and friends-of-friends as one slice,
  /// from `get_network_results`. Null until it lands, and gated or unavailable
  /// for most viewers — [networkBreakdown] is the only thing the screen reads.
  NetworkResults? _network;

  /// The network as a results slice, or null when there is nothing to show.
  /// Null is the signal everywhere: no dialog row, no compare side, and a
  /// silent fall back to World if a `Network` token is somehow still selected.
  ResultsBreakdown? get networkBreakdown => networkBreakdownFrom(_network);

  bool get _hasNetworkSlice => networkBreakdown != null;

  // Tracks the last-reported results visualization mode (dots vs histogram) so
  // results_viz_mode fires once per mode change rather than on every build.
  String? _lastVizMode;

  /// The small-sample beeswarm needs per-answer scores, and a network slice has
  /// none by design — it draws the histogram at any size.
  bool get _useDotPlot =>
      !_isComparisonMode &&
      !isNetworkFilter(selectedCountry) &&
      totalResponses < kDotPlotThreshold;

  // Fire results_viz_mode when the dot/histogram mode changes (e.g. as filters
  // move the response count across kDotPlotThreshold).
  void _maybeTrackVizMode() {
    final count = totalResponses;
    final mode = _useDotPlot ? 'dots' : 'histogram';
    if (mode != _lastVizMode) {
      _lastVizMode = mode;
      AnalyticsService().trackEvent('results_viz_mode', {
        'mode': mode,
        'respondent_count': count,
      });
    }
  }

  // Get Country 1 color based on theme
  Color get _country1Color {
    return Theme.of(context).brightness == Brightness.light 
        ? Theme.of(context).primaryColor 
        : Color(0xFF55C5B4);
  }

  // Get display name for a filter (country/city/generation/network)
  String _getDisplayName(String filter) {
    if (filter == 'World') return 'World';
    if (isNetworkFilter(filter)) return kNetworkFilterLabel;
    if (filter.startsWith('Gen:')) {
      final genId = filter.substring(4);
      return getGenerationLabel(genId);
    }
    if (filter.startsWith('City:')) return filter.substring(5);
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
           _results.total > 0 &&
           (_getUniqueCountriesWithResponses().length > 1 || _hasNetworkSlice);
  }

  List<String> _getUniqueCountriesWithResponses() =>
      _results.countriesWithResponses;

  Map<String, Map<String, dynamic>> _getCountryResponseData() =>
      _results.countryResponseData;

  /// Generation totals for the filter dialog. The server has already dropped
  /// every generation group with fewer than five respondents, so a group that
  /// would identify someone never reaches this screen at all.
  Map<String, Map<String, dynamic>> _getGenerationResponseData() =>
      _results.generationResponseData;

  Map<String, double> _getGenerationAverages() => _results.generationAverages;

  Future<void> _showCountryFilterDialog() async {
    final countryData = _getCountryResponseData();
    if (countryData.isEmpty && !_hasNetworkSlice) return;

    final questionTitle = widget.question['prompt'] ?? widget.question['title'] ?? 'Question';
    
    final generationData = _getGenerationResponseData();

    final selectedCountryResult = await CountryFilterDialog.show(
      context: context,
      countryResponses: countryData,
      currentSelectedCountry: selectedCountry,
      questionTitle: questionTitle,
      questionId: widget.question['id'].toString(),
      questionType: 'approval',
      countryAverages: _countryAverages,
      generationResponses: generationData.isNotEmpty ? generationData : null,
      generationAverages: generationData.isNotEmpty ? _getGenerationAverages() : null,
      networkBreakdown: networkBreakdown,
      networkHidden: _network?.hidden ?? 0,
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
    _loadNetwork();
    // Record this question view with current vote count
    _recordQuestionView();
    // Polling is now started conditionally in _loadMapData()
  }

  /// The "My Network" slice, for the filter and the compare sides.
  ///
  /// One call, shared with `NetworkResultsSection` further down the page
  /// through `NetworkService`'s 45-second per-question cache. Guests never ask:
  /// the network surface needs a session, and the service would only answer
  /// "unavailable".
  Future<void> _loadNetwork() async {
    if (widget.isGuestMode) return;
    final questionId = widget.question['id']?.toString() ?? '';
    if (questionId.isEmpty) return;
    final results = await NetworkService.shared().getNetworkResults(
      questionId,
      questionType: widget.question['type']?.toString() ?? 'approval_rating',
    );
    if (!mounted) return;
    setState(() {
      _network = results;
      // A network that turned out to be gated or unavailable cannot back a
      // selection: drop it silently rather than label World "My Network".
      _dropUnbackedNetworkSelection();
    });
  }

  /// Clear any `Network` filter or compare side that no longer has a slice.
  /// Silent by design — the viewer never asked for an explanation of a gate.
  void _dropUnbackedNetworkSelection() {
    if (_hasNetworkSlice) return;
    selectedCountry = clearedNetworkFilter(selectedCountry, null);
    if (isNetworkFilter(_comparisonCountry1) ||
        isNetworkFilter(_comparisonCountry2)) {
      _isComparisonMode = false;
      _comparisonCountry1 = null;
      _comparisonCountry2 = null;
    }
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
      // Check if we were handed results already
      if (initialResults.total > 0) {
        print('⚡ Using preloaded approval results (${initialResults.total} answers)');
        _results = initialResults;

        if (mounted) {
          setState(() {
            _isLoadingMap = false;
            _lastResponseCount = _results.total;
            _lastUpdated = DateTime.now();
            // Don't override vote count - it should already be set correctly by navigateToResultsScreen
          });

          print('📊 Approval results loaded: ${_results.total} answers, setting baseline for polling');
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
          _results = QuestionResults.emptyFor(
              widget.question['id']?.toString() ?? '', 'approval_rating');
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
    // Ask the server for the results. The client has no read access to the
    // answers themselves since the lockdown — only to what they add up to.
    final results = await _resultsService.fetchResults(
      widget.question['id'].toString(),
      questionType: 'approval_rating',
      forceRefresh: true,
    );

    _results = results;
    if (results.total > 0) {
      print('Found ${results.total} approval answers for this question');
    } else {
      print('No approval responses found in database for this question');
      _errorMessage = 'No responses yet for this question';
    }

    if (mounted) {
      setState(() {
        _isLoadingMap = false;
        _lastResponseCount = _results.total;
        _lastUpdated = DateTime.now();
        // Don't override vote count - it should already be set correctly by navigateToResultsScreen
      });

      print('📊 Fresh approval results loaded: ${_results.total} answers, setting baseline for polling');
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
            // Ask the server for the current answer count
      final currentCount = await _resultsService
          .fetchAnsweredCount(widget.question['id'].toString());
      final actualDisplayedCount = _results.total;
      
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
      
            // Fetch fresh results from the server
      final fresh = await _resultsService.fetchResults(
        widget.question['id'].toString(),
        questionType: 'approval_rating',
        forceRefresh: true,
      );

      if (fresh.total > 0 && mounted) {
        setState(() {
          _results = fresh;
          _lastResponseCount = fresh.total;
          // Update vote count to match the actual responses
          widget.question['votes'] = fresh.total;
          _lastUpdated = DateTime.now();
        });

        print('Auto-refreshed with ${fresh.total} approval answers');
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

    /// The slice of the results the current filter selects.
  ///
  /// Private questions are never filtered by country, so they always read the
  /// whole-question slice. A filter for a group the server has since suppressed
  /// resolves to an empty slice, not to everybody.
  ResultsBreakdown get filteredBreakdown => resolveResultsFilter(
        results: _results,
        filter: selectedCountry,
        network: networkBreakdown,
        isPrivate: isPrivateQuestion,
      );

  // Calculate statistics
  double get average => filteredBreakdown.averageOrZero;

  int get totalResponses => filteredBreakdown.count;

  // Group responses into bins for histogram
  Map<String, int> get _binnedResponses => filteredBreakdown.binsByLabel;

  // Get the results slice for one comparison side: a country, a generation, a
  // city, World, or 'Network' (My Network).
  ResultsBreakdown _getCountryBreakdown(String country) => resolveResultsFilter(
        results: _results,
        filter: country,
        network: networkBreakdown,
      );

  // Get binned responses for a specific country
  Map<String, int> _getBinnedResponsesForCountry(String country) =>
      _getCountryBreakdown(country).binsByLabel;

  // Build chart bars for comparison or single view
  List<Widget> _buildChartBars() {
    // Nothing to chart yet: hold a fixed-height placeholder instead of letting
    // the empty small-sample dot plot (axis + average marker) flash for a frame
    // before the histogram replaces it. Same height as five histogram rows so
    // the card doesn't jump when the data lands.
    if (_isLoadingMap && _results.isEmpty) {
      return [
        SizedBox(
          height: 5 * 28.0,
          child: Center(
            child: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        ),
      ];
    }
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
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Country 1 bar
                    Container(
                      height: 8,
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.surface,
                      ),
                      child: FractionallySizedBox(
                        alignment: Alignment.centerLeft,
                        widthFactor: country1Total > 0 ? country1Count / country1Total : 0,
                        child: Container(
                          decoration: BoxDecoration(
                            color: _country1Color,
                            borderRadius: BorderRadius.only(
                              topRight: Radius.circular(4),
                              bottomRight: Radius.circular(4),
                            ),
                          ),
                        ),
                      ),
                    ),
                    SizedBox(height: 2),
                    // Country 2 bar
                    Container(
                      height: 8,
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.surface,
                      ),
                      child: FractionallySizedBox(
                        alignment: Alignment.centerLeft,
                        widthFactor: country2Total > 0 ? country2Count / country2Total : 0,
                        child: Container(
                          decoration: BoxDecoration(
                            color: Color(0xFFFF6569),
                            borderRadius: BorderRadius.only(
                              topRight: Radius.circular(4),
                              bottomRight: Radius.circular(4),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      }).toList();
    } else if (_useDotPlot) {
      // Small sample: per-response beeswarm dot plot instead of a histogram.
      return [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
                    child: ApprovalDotPlot(
            // The sorted score multiset the server sends for small slices —
            // the same dots, with nothing attached to them.
            values: filteredBreakdown.scoreValues,
            average: average,
            labels: approvalLabelsFrom(widget.question),
          ),
        ),
      ];
    } else {
      // Single view mode — histogram bars (≥ kDotPlotThreshold responses),
      // growing in a top-to-bottom cascade exactly like the MC results bars.
      var delayMs = 0;
      return _binnedResponses.entries.map((entry) {
        final percentage = totalResponses > 0
            ? (entry.value / totalResponses * 100).round().toString()
            : '0';
        final barDelay = delayMs;
        delayMs += (McResultBar.fillDurationMs * 0.6).round();

        return Padding(
          key: ValueKey('approval_bar_${entry.key}'),
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
                child: McResultBar(
                  widthFactor:
                      totalResponses > 0 ? entry.value / totalResponses : 0,
                  color: _getColorForLabel(entry.key),
                  delayMs: barDelay,
                  height: 8,
                  backgroundColor: Theme.of(context).colorScheme.surface,
                  fillRadius: BorderRadius.only(
                    topRight: Radius.circular(4),
                    bottomRight: Radius.circular(4),
                  ),
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
  Map<String, double> get _countryAverages => _results.countryAverages;

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

  Widget _getIconForLabel(String label) =>
      ResultsColors.iconForApprovalLabel(context, label);

  Color _getColorForLabel(String label) =>
      ResultsColors.forApprovalLabel(context, label);

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
    
    // My Network — friends and friends-of-friends, aggregated. When the slice
    // is gone (a gate, or the RPC went away) fall back to World without a word.
    if (isNetworkFilter(country)) {
      final network = networkBreakdown;
      if (mounted) {
        setState(() {
          selectedCountry = network == null ? null : kNetworkFilter;
        });
      }
      if (network == null) return;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Showing your network',
              style: TextStyle(color: Colors.white),
            ),
            backgroundColor: Theme.of(context).primaryColor,
            duration: Duration(seconds: 2),
          ),
        );
      }
      // Aggregate only: no question id, no counts — the network↔question link
      // must not reach PostHog (networks client doc, analytics rule).
      AnalyticsService().trackEventAnonymous('results_filter_applied', {
        'filter': 'network',
        'question_type': 'approval',
      });
      return;
    }

    // Handle Generation filtering
    if (country.startsWith('Gen:')) {
      final genId = country.substring(4);
            final genCount = _results.forGeneration(genId)?.count ?? 0;

      if (genCount == 0) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('No responses from ${getGenerationLabel(genId)} yet'),
              backgroundColor: Colors.orange,
              duration: Duration(seconds: 3),
            ),
          );
        }
        return;
      }

      if (mounted) {
        setState(() {
          selectedCountry = country;
        });
                ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Showing $genCount responses from ${getGenerationLabel(genId)}'),
            backgroundColor: Theme.of(context).primaryColor,
            duration: Duration(seconds: 2),
          ),
        );
        AnalyticsService().trackEvent('generation_filter_applied', {
          'generation': genId,
          'question_type': 'approval',
          'question_id': widget.question['id'].toString(),
        });
      }
      return;
    }

    // Handle city filtering (from the map's "Filter to here")
    if (country.startsWith('City:')) {
      final cityName = country.substring(5);
            final cityCount = _results.forCity(cityName)?.count ?? 0;

      if (cityCount == 0) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('No responses from $cityName yet'),
              backgroundColor: Colors.orange,
              duration: Duration(seconds: 3),
            ),
          );
        }
        return;
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Showing results from $cityName'),
            backgroundColor: Theme.of(context).primaryColor,
            duration: Duration(seconds: 2),
          ),
        );
        setState(() {
          selectedCountry = country;
        });
      }
      return;
    }

    // Handle regular country filtering
        final countryCount = _results.forCountry(country)?.count ?? 0;

    if (countryCount == 0) {
      // Reset to all countries if not already showing global
      if (mounted) {
        if (selectedCountry != null) {
          setState(() {
            selectedCountry = null;
          });
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('No responses from $country — showing all countries'),
            backgroundColor: Colors.orange,
            duration: Duration(seconds: 3),
          ),
        );
      }
      return;
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

  /// True when the map card is on screen (so the reactions live inside it).
  bool get _hasMapCard =>
      !isCityTargeted &&
      !isPrivateQuestion &&
      _shouldShowMap() &&
      !_isLoadingMap &&
      _errorMessage == null;

  /// The compact reactions row (top emoji + the add chip, no "Reactions"
  /// title) used inside the map card and, when there is no map, on its own.
  Widget _buildReactions() => QuestionReactionsWidget(
        questionId: widget.question['id']?.toString() ?? '',
        useDummyData: false,
        compact: true,
        margin: EdgeInsets.zero,
      );

  @override
  Widget buildResultsScreen(BuildContext context) {
    _maybeTrackVizMode();
    return Scaffold(
      appBar: AppBar(
        title: Text(_appBarTitle),
        actions: [
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
                      // Question prompt + description, centred as one block.
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          // Question title - always shown in full
                          Text(
                            widget.question['title'] ?? widget.question['prompt'] ?? 'No Title',
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
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
                                crossAxisAlignment: CrossAxisAlignment.center,
                                children: [
                                  Text(
                                    widget.question['description'],
                                    textAlign: TextAlign.center,
                                    style: Theme.of(context).textTheme.bodyMedium,
                                    maxLines: _isQuestionExpanded ? null : 1,
                                    overflow: _isQuestionExpanded ? TextOverflow.visible : TextOverflow.ellipsis,
                                  ),
                                  if (_shouldShowExpandButton()) ...[
                                    SizedBox(height: 4),
                                    Text(
                                      _isQuestionExpanded ? '(show less)' : '(show more)',
                                      textAlign: TextAlign.center,
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
                        ],
                      ),
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
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
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
                                    ? 'Responses (${_getDisplayName(selectedCountry!)})'
                                    : 'Responses ${selectedCountry != null ? ' (${_getDisplayName(selectedCountry!)})' : ' (Global)'}',
                              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                color: Colors.grey[600],
                                fontSize: 14,
                              ),
                            ),
                      ),
                      if (_shouldShowFilterButton()) ...[
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
                                if (countryData.isEmpty && !_hasNetworkSlice) {
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
                                  generationResponses: _getGenerationResponseData(),
                                  generationAverages: _getGenerationAverages(),
                                  networkBreakdown: networkBreakdown,
                                  networkHidden: _network?.hidden ?? 0,
                                );

                                if (selectedCountries != null && selectedCountries.length == 2) {
                                  setState(() {
                                    _isComparisonMode = true;
                                    _comparisonCountry1 = selectedCountries[0];
                                    _comparisonCountry2 = selectedCountries[1];
                                    selectedCountry = null; // Clear single country filter
                                    _dropUnbackedNetworkSelection();
                                  });
                                  if (selectedCountries.any(isNetworkFilter)) {
                                    AnalyticsService().trackEventAnonymous(
                                        'results_comparison_applied', {
                                      'filter': 'network',
                                      'question_type': 'approval',
                                    });
                                  }
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
              SizedBox(height: 24),

              // Add world map visualization - only for non-city-targeted questions and non-private questions
              if (!isCityTargeted && !isPrivateQuestion) ...[
                              // Dot map shows once there are >= 3 responses
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
                                        key: ValueKey('approval_map_${_results.total}_${_lastUpdated.millisecondsSinceEpoch}'),
                    responsesByCountry: const [],
                    questionTitle: widget.question['title'] ?? widget.question['prompt'] ?? 'No Title',
                    questionId: widget.question['id']?.toString() ?? '',
                    labels: approvalLabelsFrom(widget.question),
                    // Reactions live inside the map card, under the credit
                    // line (owner, 2026-09-22): the compact row, no title.
                    footer: _buildReactions(),
                    onCountryTap: (String? filter) async {
                      if (filter == null) {
                        _onCountrySelected(null);
                      } else if (filter.startsWith('City:')) {
                        _onCountrySelected(filter);
                      } else {
                        final countryName = await CountryService.getCountryNameFromIso(filter);
                        if (countryName != null) {
                          _onCountrySelected(countryName);
                        }
                      }
                    },
                  ),
              ],
                SizedBox(height: 24),
              ],

              // Reactions sit inside the map card when there is one; a
              // question with no map (city-targeted, private, or too few
              // answers) keeps them here, below the numbers.
              if (!_hasMapCard) ...[
                _buildReactions(),
                const SizedBox(height: 16),
              ],

              // "Your network" - the ego graph, the quantised aggregate and the
              // close-friend row, or the nudge card when the viewer has not earned
              // one yet. Renders nothing at all until the linkage RPCs are deployed.
              NetworkResultsSection(
                questionId: widget.question['id']?.toString() ?? '',
                questionType: widget.question['type']?.toString() ?? '',
                prompt: widget.question['prompt']?.toString(),
                emoji: widget.question['emoji']?.toString(),
                approvalLabels: approvalLabelsFrom(widget.question),
                padding: EdgeInsets.zero,
              ),

              const SizedBox(height: 16),

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

              // Comments Section
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
                questionTitle: widget.question['prompt']?.toString() ?? 'Question',
                isAuthor: _questionService?.isCurrentUserAuthor(widget.question) ?? false,
                onRatingSubmitted: () {
                  if (mounted) setState(() => _ratingSectionRefreshKey++);
                },
              ),

              const SizedBox(height: 16),

              // Question Rating results (only shown after rating, or to authors / signed-out viewers)
              QuestionRatingSection(
                key: ValueKey('rating_${widget.question['id']}_$_ratingSectionRefreshKey'),
                questionId: widget.question['id']?.toString() ?? '',
                isAuthor: _questionService?.isCurrentUserAuthor(widget.question) ?? false,
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
                // WP-F: forward this question inside the app. Hides itself
                // when the viewer has no accepted friends.
                SendToFriendButton(
                  questionId: widget.question['id']?.toString() ?? '',
                ),
                  TextButton.icon(
                    icon: Icon(Icons.share),
                    label: Text('Share'),
                    onPressed: () {
                      final questionTitle = widget.question['prompt'] ?? widget.question['title'] ?? 'Check out this question';
                      final questionId = widget.question['id']?.toString() ?? '';
                      AnalyticsService().trackShareInitiated('results', method: 'system', questionId: questionId.isNotEmpty ? questionId : null);
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
            // Navigate to community tab
            Navigator.pushAndRemoveUntil(
              context,
              MaterialPageRoute(builder: (context) => MainScreen(initialIndex: 1)),
              (route) => false,
            );
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
          BottomNavigationBarItem(icon: Icon(Icons.groups_outlined), label: 'Community'),
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
    // Dot maps degrade gracefully where choropleths looked empty, so the gate
    // relaxes to >= 3 responses (city-targeted / private questions are already
    // excluded by the caller).
        return _results.total >= 3;
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

    final isAuthor = _questionService?.isCurrentUserAuthor(widget.question) ?? false;

    await CommentsOverlay.show(
      context: context,
      questionId: questionId,
      questionTitle: questionTitle,
      question: widget.question,
      isAuthor: isAuthor,
      focusInput: true,
      onCommentAdded: (newComment) {
        (_commentsSectionKey.currentState as dynamic)?.refreshComments();
      },
      onRatingSubmitted: () {
        if (mounted) {
          setState(() => _ratingSectionRefreshKey++);
        }
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