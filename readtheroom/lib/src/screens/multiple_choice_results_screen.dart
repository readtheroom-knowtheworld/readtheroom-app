// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:fl_chart/fl_chart.dart';
import '../services/user_service.dart';
import '../services/guest_user_tracking_service.dart';
import '../services/location_service.dart';
import '../utils/time_utils.dart';
import '../utils/results_colors.dart';
import '../data/countries_data.dart';
import 'report_question_screen.dart';
import 'package:share_plus/share_plus.dart';
import 'base_results_screen.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../services/question_service.dart';
import '../models/category.dart';
import 'dart:async';
import '../widgets/network_results_section.dart';
import '../widgets/notification_bell.dart';
import '../widgets/country_multiple_choice_map.dart';
import '../services/country_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../utils/category_navigation.dart';
import '../widgets/question_reactions_widget.dart';
import '../widgets/comments_section.dart';
import '../widgets/linked_questions_section.dart';
import '../widgets/comments_overlay.dart';
import '../widgets/country_filter_dialog.dart';
import '../widgets/country_comparison_dialog.dart';
import '../widgets/question_rating_section.dart';
import '../utils/generation_utils.dart';
import '../utils/network_breakdown.dart';
import '../models/network_results.dart';
import '../services/network_service.dart';
import '../services/analytics_service.dart';
import '../widgets/mc_dot_row.dart';
import '../utils/dot_plot_threshold.dart';
import 'main_screen.dart';
import '../widgets/send_to_friend_sheet.dart';
import '../models/question_results.dart';
import '../services/results_service.dart';

class MultipleChoiceResultsScreen extends BaseResultsScreen {
  const MultipleChoiceResultsScreen({
    Key? key,
    required Map<String, dynamic> question,
    QuestionResults? results,
    FeedContext? feedContext,
    bool fromSearch = false,
    bool fromUserScreen = false,
    bool isGuestMode = false,
  }) : super(key: key, question: question, results: results, feedContext: feedContext, fromSearch: fromSearch, fromUserScreen: fromUserScreen, isGuestMode: isGuestMode);

  @override
  State<MultipleChoiceResultsScreen> createState() => _MultipleChoiceResultsScreenState();
}

class _MultipleChoiceResultsScreenState extends BaseResultsScreenState<MultipleChoiceResultsScreen> {
  String? selectedCountry;

  /// The server-computed results. Since the answers read lockdown (2026-09-22)
  /// this screen never holds answer rows — every count below is a slice of this.
  late QuestionResults _results = initialResults;
  final ResultsService _resultsService = ResultsService();
  String? _countrySearchQuery;
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
  int _ratingSectionRefreshKey = 0;

  // Comparison mode variables
  bool _isComparisonMode = false;
  String? _comparisonCountry1;
  String? _comparisonCountry2;

  /// "My Network": the viewer's friends and friends-of-friends as one slice,
  /// from `get_network_results`. Null until it lands, and gated or unavailable
  /// for most viewers — [networkBreakdown] is the only thing the screen reads.
  NetworkResults? _network;

  /// The network as a results slice, with this question's options in this
  /// question's order, or null when there is nothing to show.
  ResultsBreakdown? get networkBreakdown =>
      networkBreakdownFrom(_network, optionTexts: options);

  bool get _hasNetworkSlice => networkBreakdown != null;

  // Tracks the last-reported results visualization mode (dots vs histogram) so
  // results_viz_mode fires once per mode change rather than on every build.
  String? _lastVizMode;

  void _maybeTrackVizMode() {
    final count = totalResponses;
    final mode = (!_isComparisonMode && count < kDotPlotThreshold)
        ? 'dots'
        : 'histogram';
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

    // Get the results slice for one comparison side: a country, a generation, a
  // city, World, or 'Network' (My Network).
  ResultsBreakdown _getCountryBreakdown(String country) => resolveResultsFilter(
        results: _results,
        filter: country,
        network: networkBreakdown,
      );

  // Get response counts for a specific country, every option present
  Map<String, int> _getResponseCountsForCountry(String country) =>
      _getCountryBreakdown(country).optionCountsFor(options);

  // Build chart bars for comparison or single view
  List<Widget> _buildChartBars() {
    if (_isComparisonMode && _comparisonCountry1 != null && _comparisonCountry2 != null) {
      // Comparison mode
      final country1Counts = _getResponseCountsForCountry(_comparisonCountry1!);
      final country2Counts = _getResponseCountsForCountry(_comparisonCountry2!);
      final country1Total = country1Counts.values.fold<int>(0, (sum, count) => sum + count);
      final country2Total = country2Counts.values.fold<int>(0, (sum, count) => sum + count);
      
      return options.map((option) {
        final country1Count = country1Counts[option] ?? 0;
        final country2Count = country2Counts[option] ?? 0;
        final country1Percentage = country1Total > 0 ? (country1Count / country1Total * 100).round() : 0;
        final country2Percentage = country2Total > 0 ? (country2Count / country2Total * 100).round() : 0;
        
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(
                    option,
                    style: TextStyle(
                      fontWeight: FontWeight.normal,
                      color: Theme.of(context).textTheme.bodyLarge?.color,
                    ),
                  ),
                ),
              ],
            ),
            SizedBox(height: 8),
            // Country 1 bar
            Row(
              children: [
                Expanded(
                  child: Container(
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
                ),
              ],
            ),
            SizedBox(height: 4),
            // Country 2 bar
            Row(
              children: [
                Expanded(
                  child: Container(
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
                ),
              ],
            ),
            SizedBox(height: 16),
          ],
        );
      }).toList();
    } else if (totalResponses < kDotPlotThreshold) {
      // Small sample: one dot per vote per option instead of percentage bars.
      // Highest-voted option first; rows fill in a top-to-bottom cascade.
      final counts = _responseCounts;
      final sorted = _optionsByVotesDesc(counts);
      var delayMs = 0;
      return sorted.map((option) {
        final count = counts[option] ?? 0;
        final row = McDotRow(
          key: ValueKey('mc_dots_$option'),
          label: option,
          voteCount: count,
          totalResponses: totalResponses,
          color: getColorForOption(option),
          delayMs: delayMs,
        );
        // Next row starts once this one is ~2/3 filled — a rolling cascade
        // rather than a full stop-and-wait.
        delayMs += (McDotRow.fillDurationMs(count) * 0.65).round();
        return row;
      }).toList();
    } else {
      // Single view mode — percentage bars, highest-voted first, growing in a
      // top-to-bottom cascade.
      final counts = _responseCounts;
      final sorted = _optionsByVotesDesc(counts);
      var delayMs = 0;
      return sorted.map((option) {
        final count = counts[option] ?? 0;
        final percentage = totalResponses > 0
            ? (count / totalResponses * 100).round().toString()
            : '0';
        final barDelay = delayMs;
        delayMs += (McResultBar.fillDurationMs * 0.6).round();

        return Column(
          key: ValueKey('mc_bar_$option'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(
                    option,
                    style: TextStyle(
                      fontWeight: FontWeight.normal,
                      color: Theme.of(context).textTheme.bodyLarge?.color,
                    ),
                  ),
                ),
                Text(
                  '$percentage% ($count)',
                  style: TextStyle(
                    fontWeight: FontWeight.normal,
                    color: Theme.of(context).textTheme.bodySmall?.color,
                  ),
                ),
              ],
            ),
            SizedBox(height: 8),
            McResultBar(
              widthFactor: totalResponses > 0 ? count / totalResponses : 0,
              color: getColorForOption(option),
              delayMs: barDelay,
            ),
            SizedBox(height: 16),
          ],
        );
      }).toList();
    }
  }

  /// Options sorted by vote count descending; ties keep the question's
  /// original option order (List.sort isn't stable, so tie-break on index).
  List<String> _optionsByVotesDesc(Map<String, int> counts) {
    final indexed = options.asMap().entries.toList()
      ..sort((a, b) {
        final byVotes =
            (counts[b.value] ?? 0).compareTo(counts[a.value] ?? 0);
        return byVotes != 0 ? byVotes : a.key.compareTo(b.key);
      });
    return indexed.map((e) => e.value).toList();
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

  String? _getGenerationMostPopular(String genId) {
    final breakdown = _results.forGeneration(genId);
    if (breakdown == null || breakdown.count == 0) return null;
    final top = breakdown.topOption;
    return top == 'TIE' ? null : top;
  }

  Future<void> _showCountryFilterDialog() async {
    final countryData = _getCountryResponseData();
    if (countryData.isEmpty && !_hasNetworkSlice) return;

    final questionTitle = widget.question['prompt'] ?? widget.question['title'] ?? 'Question';
    
    // Get most popular option for each country
    final countryMostPopular = <String, String?>{};
    for (var country in countryData.keys) {
      countryMostPopular[country] = getMostPopularOptionForCountry(country);
    }

    final generationData = _getGenerationResponseData();
    Map<String, String?>? genMostPopular;
    if (generationData.isNotEmpty) {
      genMostPopular = {};
      for (var gen in generationData.keys) {
        genMostPopular[gen] = _getGenerationMostPopular(gen);
      }
    }

    final selectedCountryResult = await CountryFilterDialog.show(
      context: context,
      countryResponses: countryData,
      currentSelectedCountry: selectedCountry,
      questionTitle: questionTitle,
      questionId: widget.question['id'].toString(),
      questionType: 'multiple_choice',
      questionOptions: options,
      countryMostPopular: countryMostPopular,
      generationResponses: generationData.isNotEmpty ? generationData : null,
      generationMostPopular: genMostPopular,
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
    
        _loadCityNameIfNeeded();
    _loadNetwork();
    _lastResponseCount = _results.total;
    // Only start polling if we have data (which indicates we're displaying real data)
    if (_results.total > 0) {
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
    }
    // Record this question view with current vote count
    _recordQuestionView();
    // Don't override vote count - it should already be set correctly by navigateToResultsScreen
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _pollTimer?.cancel();
    // Note: Don't try to access ScaffoldMessenger in dispose() as the widget tree may be deactivated
    // ScaffoldMessenger snackbars will be automatically dismissed when the screen is popped
    super.dispose();
  }

  void _startPolling() {
    _pollTimer = Timer.periodic(Duration(seconds: 5), (timer) async {
      if (!mounted) {
        timer.cancel();
        return;
      }
      await _checkForUpdates();
    });
  }

  Future<void> _checkForUpdates() async {
    try {
      final questionService = Provider.of<QuestionService>(context, listen: false);
      
      // Get current response count from database
      final currentCount = await questionService.getAccurateVoteCount(
        widget.question['id'].toString(), 
        'multiple_choice'
      );
      
      // Check if there's a significant change (>5% difference)
      final percentChange = (_lastResponseCount > 0) 
          ? ((currentCount - _lastResponseCount).abs() / _lastResponseCount) 
          : (currentCount > 0 ? 1.0 : 0.0);
      
      if (percentChange > 0.05) {
        print('Significant change detected: $currentCount vs $_lastResponseCount (${(percentChange * 100).toStringAsFixed(1)}% change)');
        await _refreshData();
        _lastResponseCount = currentCount;
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

  Future<void> _refreshData() async {
    try {
      final questionService = Provider.of<QuestionService>(context, listen: false);

            // Fetch fresh results from the server
      final fresh = await questionService.fetchQuestionResults(
        widget.question['id'].toString(),
        questionType: 'multiple_choice',
        forceRefresh: true,
      );

      if (mounted && fresh.total > 0) {
        setState(() {
          // Clear cached options since the question's options may have changed
          _cachedOptions = null;
          _results = fresh;
          // Update vote count to match the actual valid responses
          if (fresh.answered > 0) {
            widget.question['votes'] = fresh.answered;
          }
          _lastUpdated = DateTime.now();
        });

        print('Auto-refreshed with ${fresh.total} answers');
      }
    } catch (e) {
      print('Error refreshing data: $e');
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

  String _getCountryFlagEmoji(String countryCode) {
    // Map of country codes to flag emojis - COMPLETE LIST
    final countryFlags = <String, String>{
      'US': '🇺🇸',
      'CA': '🇨🇦',
      'GB': '🇬🇧',
      'AU': '🇦🇺',
      'DE': '🇩🇪',
      'FR': '🇫🇷',
      'IT': '🇮🇹',
      'ES': '🇪🇸',
      'NL': '🇳🇱',
      'BE': '🇧🇪',
      'LU': '🇱🇺',
      'CH': '🇨🇭',
      'AT': '🇦🇹',
      'SE': '🇸🇪',
      'NO': '🇳🇴',
      'DK': '🇩🇰',
      'FI': '🇫🇮',
      'IE': '🇮🇪',
      'PT': '🇵🇹',
      'GR': '🇬🇷',
      'PL': '🇵🇱',
      'CZ': '🇨🇿',
      'HU': '🇭🇺',
      'SK': '🇸🇰',
      'SI': '🇸🇮',
      'HR': '🇭🇷',
      'BG': '🇧🇬',
      'RO': '🇷🇴',
      'LT': '🇱🇹',
      'LV': '🇱🇻',
      'EE': '🇪🇪',
      'MT': '🇲🇹',
      'CY': '🇨🇾',
      'JP': '🇯🇵',
      'KR': '🇰🇷',
      'CN': '🇨🇳',
      'IN': '🇮🇳',
      'BR': '🇧🇷',
      'MX': '🇲🇽',
      'AR': '🇦🇷',
      'CL': '🇨🇱',
      'CO': '🇨🇴',
      'PE': '🇵🇪',
      'VE': '🇻🇪',
      'UY': '🇺🇾',
      'PY': '🇵🇾',
      'BO': '🇧🇴',
      'EC': '🇪🇨',
      'GY': '🇬🇾',
      'SR': '🇸🇷',
      'GF': '🇬🇫',
      'ZA': '🇿🇦',
      'NG': '🇳🇬',
      'EG': '🇪🇬',
      'MA': '🇲🇦',
      'DZ': '🇩🇿',
      'TN': '🇹🇳',
      'LY': '🇱🇾',
      'SD': '🇸🇩',
      'SS': '🇸🇸',
      'ET': '🇪🇹',
      'KE': '🇰🇪',
      'UG': '🇺🇬',
      'TZ': '🇹🇿',
      'RW': '🇷🇼',
      'BI': '🇧🇮',
      'SO': '🇸🇴',
      'DJ': '🇩🇯',
      'ER': '🇪🇷',
      'GH': '🇬🇭',
      'CI': '🇨🇮',
      'BF': '🇧🇫',
      'ML': '🇲🇱',
      'NE': '🇳🇪',
      'TD': '🇹🇩',
      'CF': '🇨🇫',
      'CM': '🇨🇲',
      'GQ': '🇬🇶',
      'GA': '🇬🇦',
      'CG': '🇨🇬',
      'CD': '🇨🇩',
      'AO': '🇦🇴',
      'ZM': '🇿🇲',
      'ZW': '🇿🇼',
      'BW': '🇧🇼',
      'NA': '🇳🇦',
      'LS': '🇱🇸',
      'SZ': '🇸🇿',
      'MZ': '🇲🇿',
      'MW': '🇲🇼',
      'MG': '🇲🇬',
      'MU': '🇲🇺',
      'SC': '🇸🇨',
      'KM': '🇰🇲',
      'CV': '🇨🇻',
      'ST': '🇸🇹',
      'SN': '🇸🇳',
      'GM': '🇬🇲',
      'GW': '🇬🇼',
      'GN': '🇬🇳',
      'SL': '🇸🇱',
      'LR': '🇱🇷',
      'BJ': '🇧🇯',
      'TG': '🇹🇬',
      'MR': '🇲🇷',
      'RU': '🇷🇺',
      'UA': '🇺🇦',
      'BY': '🇧🇾',
      'MD': '🇲🇩',
      'GE': '🇬🇪',
      'AM': '🇦🇲',
      'AZ': '🇦🇿',
      'KZ': '🇰🇿',
      'UZ': '🇺🇿',
      'TM': '🇹🇲',
      'KG': '🇰🇬',
      'TJ': '🇹🇯',
      'MN': '🇲🇳',
      'TR': '🇹🇷',
      'SA': '🇸🇦',
      'AE': '🇦🇪',
      'IL': '🇮🇱',
      'JO': '🇯🇴',
      'LB': '🇱🇧',
      'SY': '🇸🇾',
      'IQ': '🇮🇶',
      'IR': '🇮🇷',
      'KW': '🇰🇼',
      'QA': '🇶🇦',
      'BH': '🇧🇭',
      'OM': '🇴🇲',
      'YE': '🇾🇪',
      'TH': '🇹🇭',
      'VN': '🇻🇳',
      'MY': '🇲🇾',
      'SG': '🇸🇬',
      'ID': '🇮🇩',
      'PH': '🇵🇭',
      'MM': '🇲🇲',
      'KH': '🇰🇭',
      'LA': '🇱🇦',
      'BN': '🇧🇳',
      'TL': '🇹🇱',
      'TW': '🇹🇼',
      'HK': '🇭🇰',
      'MO': '🇲🇴',
      'AF': '🇦🇫',
      'PK': '🇵🇰',
      'BD': '🇧🇩',
      'LK': '🇱🇰',
      'MV': '🇲🇻',
      'NP': '🇳🇵',
      'BT': '🇧🇹',
      'NZ': '🇳🇿',
      'FJ': '🇫🇯',
      'PG': '🇵🇬',
      'SB': '🇸🇧',
      'VU': '🇻🇺',
      'NC': '🇳🇨',
      'PF': '🇵🇫',
      'AS': '🇦🇸',
      'GU': '🇬🇺',
      'MP': '🇲🇵',
      'PW': '🇵🇼',
      'FM': '🇫🇲',
      'MH': '🇲🇭',
      'KI': '🇰🇮',
      'NR': '🇳🇷',
      'TV': '🇹🇻',
      'TO': '🇹🇴',
      'WS': '🇼🇸',
      'CK': '🇨🇰',
      'NU': '🇳🇺',
      'TK': '🇹🇰',
      'WF': '🇼🇫',
      'AQ': '🇦🇶',
      'BV': '🇧🇻',
      'GS': '🇬🇸',
      'HM': '🇭🇲',
      'IO': '🇮🇴',
      'TF': '🇹🇫',
      'UM': '🇺🇲',
      'AX': '🇦🇽',
      'FO': '🇫🇴',
      'GI': '🇬🇮',
      'GG': '🇬🇬',
      'IM': '🇮🇲',
      'JE': '🇯🇪',
      'SJ': '🇸🇯',
      'EH': '🇪🇭',
      'PS': '🇵🇸',
      'FK': '🇫🇰',
      'SH': '🇸🇭',
      'AC': '🇦🇨',
      'TA': '🇹🇦',
      'RE': '🇷🇪',
      'YT': '🇾🇹',
      'GL': '🇬🇱',
      'EU': '🇪🇺',
      'UN': '🇺🇳',
    };
    
    return countryFlags[countryCode.toUpperCase()] ?? '';
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
      final response = await Supabase.instance.client
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

  // Cache for options to avoid recomputation and hot reload issues
  List<String>? _cachedOptions;

  // Get all possible options from the question
  List<String> get options {
    // Return cached options if available
    if (_cachedOptions != null) {
      return _cachedOptions!;
    }
    
    // Get options from question_options which is the field name in Supabase
    final optionsData = widget.question['question_options'] as List<dynamic>?;
    if (optionsData != null && optionsData.isNotEmpty) {
      // Extract option_text from each option
      _cachedOptions = optionsData
          .map((option) => option['option_text'].toString())
          .toList();
      return _cachedOptions!;
    }
    
    // Fallback to options field if present
    final legacyOptions = widget.question['options'] as List<dynamic>?;
    if (legacyOptions != null && legacyOptions.isNotEmpty) {
      _cachedOptions = legacyOptions.map((option) => option.toString()).toList();
      return _cachedOptions!;
    }
    
        // If no options found in question data, take the ones the results carry —
    // the RPC returns every option the question defines, in sort order.
    final fromResults = _results.optionTexts.where((o) => o.isNotEmpty).toList();
    if (fromResults.isNotEmpty) {
      _cachedOptions = fromResults;
      print('📋 Took ${_cachedOptions!.length} options from the results: $_cachedOptions');
      return _cachedOptions!;
    }
    
    // Last resort: provide default options
    print('⚠️ No options found in question data or responses, using defaults');
    _cachedOptions = ['Option 1', 'Option 2', 'Option 3'];
    return _cachedOptions!;
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

  // Response counts for each option, every option present even at zero
  Map<String, int> get _responseCounts =>
      filteredBreakdown.optionCountsFor(options);

    // Get the most popular response for each country and their response counts
  Map<String, Map<String, dynamic>> get _countryResponses {
    final result = <String, Map<String, dynamic>>{};
    for (final c in _results.byCountry) {
      final counts = c.breakdown.optionCounts;
      if (counts.isEmpty) continue;
      final top = c.breakdown.topOption;
      // 'TIE' is not an option, so report the shared maximum as the count.
      final topCount = counts.values.isEmpty
          ? 0
          : counts.values.reduce((a, b) => a > b ? a : b);
      result[c.country] = {
        'mostPopular': top,
        'count': top == 'TIE' ? topCount : (counts[top] ?? 0),
        'total': c.breakdown.count,
      };
    }
    return result;
  }

  // Get sorted list of countries by response count. `by_country` already
  // arrives ordered by volume, so map insertion order is that order.
  List<MapEntry<String, Map<String, dynamic>>> get _sortedCountryResponses =>
      _countryResponses.entries.toList();

  int get totalResponses => filteredBreakdown.count;

    // Get the most selected option globally (always uses all responses, not filtered)
  String get globalMostSelectedOption {
    if (_results.total == 0) return 'No responses yet';
    final counts = _results.overall.optionCounts;
    if (counts.isEmpty || counts.values.every((v) => v == 0)) {
      return 'No responses yet';
    }
    return _results.overall.topOption;
  }

  // Helper method to get most popular option for a country (returns null if tie)
  String? getMostPopularOptionForCountry(String country) {
    final breakdown = _results.forCountry(country);
    if (breakdown == null || breakdown.count == 0) return null;
    final top = breakdown.topOption;
    return top == 'TIE' ? null : top;
  }

  // Get color for an option
  Color getColorForOption(String? option) {
    if (option == null || option == 'TIE') {
      return Colors.grey[400]!;
    }
    final index = options.indexOf(option);
    if (index == -1) {
      return Colors.grey[400]!;
    }
    return ResultsColors.forOptionIndex(context, index);
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
      questionType: widget.question['type']?.toString() ?? 'multiple_choice',
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

  void _onCountrySelected(String? country) {
    print('Multiple Choice: Country selected: $country');
    
    // Dismiss any current snackbar before showing a new one
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    
    // Exit comparison mode when a single country is selected
    setState(() {
      _isComparisonMode = false;
      _comparisonCountry1 = null;
      _comparisonCountry2 = null;
    });
    
    if (country == null) {
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
      return;
    }
    
    // My Network — friends and friends-of-friends, aggregated. When the slice
    // is gone (a gate, or the RPC went away) fall back to World without a word.
    if (isNetworkFilter(country)) {
      final network = networkBreakdown;
      setState(() {
        selectedCountry = network == null ? null : kNetworkFilter;
      });
      if (network == null) return;
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
      // Aggregate only: no question id, no counts — the network↔question link
      // must not reach PostHog (networks client doc, analytics rule).
      AnalyticsService().trackEventAnonymous('results_filter_applied', {
        'filter': 'network',
        'question_type': 'multiple_choice',
      });
      return;
    }

    // Handle Generation filtering
    if (country.startsWith('Gen:')) {
      final genId = country.substring(4);
            final genCount = _results.forGeneration(genId)?.count ?? 0;

      if (genCount == 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('No responses from ${getGenerationLabel(genId)} yet'),
            backgroundColor: Colors.orange,
            duration: Duration(seconds: 3),
          ),
        );
        return;
      }

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
        'question_type': 'multiple_choice',
        'question_id': widget.question['id'].toString(),
      });
      return;
    }

    // Handle city filtering (from the map's "Filter to here")
    if (country.startsWith('City:')) {
      final cityName = country.substring(5);
            final cityCount = _results.forCity(cityName)?.count ?? 0;

      if (cityCount == 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('No responses from $cityName yet'),
            backgroundColor: Colors.orange,
            duration: Duration(seconds: 3),
          ),
        );
        return;
      }

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
      return;
    }

    // Handle regular country filtering
        final countryCount = _results.forCountry(country)?.count ?? 0;

    if (countryCount == 0) {
      // Reset to all countries if not already showing global
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
      return;
    }
    
    // Show informative message when selecting a country
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

  /// True when the map card is on screen (so the reactions live inside it).
  bool get _hasMapCard =>
      !isCityTargeted && !isPrivateQuestion && _shouldShowMap();

  /// The compact reactions row (top emoji + the add chip, no "Reactions"
  /// title) used inside the map card and, when there is no map, on its own.
  Widget _buildReactions() => QuestionReactionsWidget(
        questionId: widget.question['id'].toString(),
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
                          widget.question['prompt'] ?? widget.question['title'] ?? 'No Title',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.titleLarge?.copyWith(
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
                    
                    SizedBox(height: 12),
                    
                    SizedBox(height: 8),
                    Consumer<QuestionService>(
                      builder: (context, questionService, child) {
                        return FutureBuilder<int>(
                          future: questionService.getAccurateVoteCount(
                            widget.question['id'].toString(), 
                            'multiple_choice'
                          ),
                          builder: (context, snapshot) {
                            final voteCount = snapshot.data ?? widget.question['votes'] ?? 0;
                            
                            // Determine targeting emoji and dialog content
                            final targeting = widget.question['targeting_type'] ?? 'globe';
                            final questionCountryCode = widget.question['country_code'] ?? widget.question['countries']?['country_code'];
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
                                final cityNameForDialog = widget.question['city_name'] ?? 
                                                         widget.question['cities']?['name'] ?? 
                                                         'a specific city';
                                dialogTitle = 'City Question';
                                dialogMessage = 'This question is addressed to people in $cityNameForDialog.';
                                break;
                              default:
                                targetingEmoji = '🌍';
                                dialogTitle = 'Global Question';
                                dialogMessage = 'This question is addressed to people in the world.';
                            }
                            
                            return Row(
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
                                  GestureDetector(
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
                                  ),
                                  SizedBox(width: 6),
                                ],
                                Text(
                                  'Votes: $voteCount • ${_formatDateOnly(widget.question['created_at'] ?? widget.question['timestamp'])}',
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ],
                            );
                          },
                        );
                      },
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
                              final genData = _getGenerationResponseData();
                              Map<String, String?>? genMostPop;
                              if (genData.isNotEmpty) {
                                genMostPop = {};
                                for (var gen in genData.keys) {
                                  genMostPop[gen] = _getGenerationMostPopular(gen);
                                }
                              }
                              final selectedCountries = await CountryComparisonDialog.show(
                                context: context,
                                countryResponses: countryData,
                                questionTitle: questionTitle,
                                questionId: widget.question['id'].toString(),
                                questionType: 'multiple_choice',
                                generationResponses: genData,
                                generationMostPopular: genMostPop,
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
                                    'question_type': 'multiple_choice',
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
                CountryMultipleChoiceMap(
                                    key: ValueKey('mc_map_${_results.total}_${_lastUpdated.millisecondsSinceEpoch}'),
                  responsesByCountry: const [],
                  questionTitle: widget.question['prompt'] ?? widget.question['title'] ?? 'No Title',
                  questionId: widget.question['id']?.toString() ?? '',
                  options: options,
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
                SizedBox(height: 24),
              ],
            ],

            // Reactions sit inside the map card when there is one; a question
            // with no map (city-targeted, private, or too few answers) keeps
            // them here, below the numbers.
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
              questionId: widget.question['id'].toString(),
              onAddCommentTap: _handleAddComment,
              useDummyData: false, // Use real data
              questionContext: widget.question,
              margin: EdgeInsets.zero, // Remove default margin to align with other widgets
              questionTitle: widget.question['prompt']?.toString() ?? 'Question',
              isAuthor: Provider.of<QuestionService>(context, listen: false).isCurrentUserAuthor(widget.question),
              onRatingSubmitted: () {
                if (mounted) setState(() => _ratingSectionRefreshKey++);
              },
              onCommentsLoaded: (comments) {
                setState(() {
                  _comments = comments;
                });
              },
            ),

            const SizedBox(height: 16),

            // Question Rating results (only shown after rating, or to authors / signed-out viewers)
            QuestionRatingSection(
              key: ValueKey('rating_${widget.question['id']}_$_ratingSectionRefreshKey'),
              questionId: widget.question['id']?.toString() ?? '',
              isAuthor: Provider.of<QuestionService>(context, listen: false).isCurrentUserAuthor(widget.question),
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
            SizedBox(height: 100), // Extra space for bottom navigation
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
    // Only show for non-city-targeted questions (private questions are excluded
    // by the caller). Dot maps relax the gate to >= 3 responses.
    if (isCityTargeted) {
      return false;
    }
        return _results.total >= 3;
  }

  // Helper method to record question view for vote count and comment count delta tracking
  Future<void> _recordQuestionView() async {
    try {
      final currentVotes = widget.question['votes'] as int? ?? 0;
      final currentComments = _getCommentCount(widget.question);
      final questionId = widget.question['id'].toString();
      
      print('🔍 Debug: Recording view for question $questionId with $currentVotes votes, $currentComments comments (multiple choice results)');
      
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
    final questionTitle = widget.question['prompt']?.toString() ?? 'Question';
    final isAuthor = Provider.of<QuestionService>(context, listen: false).isCurrentUserAuthor(widget.question);

    await CommentsOverlay.show(
      context: context,
      questionId: widget.question['id'].toString(),
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
}