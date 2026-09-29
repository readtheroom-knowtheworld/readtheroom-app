// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../services/question_service.dart';
import '../services/location_service.dart';
import '../utils/time_utils.dart';
import '../utils/review_tag_navigation.dart';
import '../utils/search_history.dart';
import '../utils/archive_logic.dart';
import '../utils/haptic_utils.dart';
import '../services/user_service.dart';
import '../services/analytics_service.dart';
import '../widgets/boost_dialog.dart';
import '../widgets/question_type_badge.dart';

/// Shared Hero tag so the Home search pill morphs into the real search field.
const String kSearchHeroTag = 'home_search_bar';

class SearchScreen extends StatefulWidget {
  final bool isActive; // Track if this screen is currently active/visible
  final bool autofocus; // Autofocus the field (e.g. when opened from the Home pill)
  final String source; // Analytics source: 'home_bar' | 'deeplink' | 'archive_icon' | 'topic_chip' | 'review_chip'

  // Chip-driven entry (topic / review chips on answer & results screens push the
  // Archive with a filter pre-applied — see [CategoryNavigation.onCategoryChipTap]
  // and [ReviewTagNavigation.onReviewTagChipTap]).
  final String? initialCategoryFilter; // Topic name to filter the default view by.
  final String? initialReviewTagFilter; // Review tag key to filter by.
  final List<String>? initialReviewQuestionIds; // Question ids qualifying for the review tag.

  const SearchScreen({
    Key? key,
    this.isActive = true,
    this.autofocus = true,
    this.source = 'home_bar',
    this.initialCategoryFilter,
    this.initialReviewTagFilter,
    this.initialReviewQuestionIds,
  }) : super(key: key);

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
  // "Unanswered — most answered first" archive queue (backs the default view),
  // fetched from QuestionService.fetchArchiveQueue with client-side pagination.
  List<Map<String, dynamic>> _archiveQueue = [];
  bool _isSearching = false;
  bool _hasSearched = false;
  bool _isLoadingArchive = false;
  bool _isLoadingMoreArchive = false;
  bool _archiveExhausted = false; // Underlying source drained → stop paginating.
  bool _hideSearchBar = false;
  int _archiveOffset = 0;
  final int _archiveLimit = 20;
  Timer? _debounceTimer;
  bool _wasDrawerOpen = false;

  // Chip-driven filter (topic / review) applied client-side to the archive queue
  // AND search results, with a dismissible header. Seeded from the constructor.
  String? _activeCategoryFilter;
  String? _activeReviewTagFilter;
  Set<String> _activeReviewTagIds = {};
  bool get _hasChipFilter =>
      _activeCategoryFilter != null || _activeReviewTagFilter != null;
  
  // Filter state. The sort/location/reviews chip row was removed from the
  // Archive UI; these remain (at their defaults) because the client-side
  // filter pipeline still consults them.
  final String _sortMode = 'popular';
  String? _selectedCountry;
  String? _selectedCity;
  final List<String> _selectedReviewTags = [];
  final Set<String> _reviewFilterQuestionIds = {};

  // Search configuration
  static const int _minQueryLength = 3;
  static const Duration _debounceDelay = Duration(milliseconds: 300);

  // Search history (device-local, LRU of last 10 submitted-or-tapped queries)
  static const String _historyPrefsKey = 'search_history';
  static const int _historyMaxLength = 10;
  List<String> _searchHistory = [];
  // False until the async SharedPreferences read completes, so the empty state
  // doesn't flash Top All Time before we know whether history exists.
  bool _historyLoaded = false;

  // Archive Answered/Unanswered toggle. Screen-state only (never persisted) —
  // always defaults to Unanswered on open. 'unanswered' shows the queue of
  // questions the user hasn't answered; 'answered' shows the ones they have.
  String _archiveView = kArchiveUnansweredSection;

  // Per-section sort, flipped by tapping the already-selected toggle chip and
  // persisted in SharedPreferences (see [_loadArchiveSorts]). Unanswered opens
  // on Popular (most answered first), Your answers on New (newest first).
  static const String _unansweredSortPrefsKey = 'archive_sort_unanswered';
  static const String _answeredSortPrefsKey = 'archive_sort_answered';
  ArchiveSort _unansweredSort = defaultArchiveSort(kArchiveUnansweredSection);
  ArchiveSort _answeredSort = defaultArchiveSort(kArchiveAnsweredSection);

  // Monotonic id for archive-queue fetches, so the response of a request that a
  // sort flip has superseded is discarded instead of repopulating the list in
  // the old order.
  int _archiveRequestId = 0;

  // Fresh vote counts for the user's answered questions, fetched lazily the
  // first time the Answered view is shown (keyed by question id). Merged over
  // the stored answer-time votes so the Answered view ranks by current
  // popularity; on fetch failure the stored value is used as a fallback.
  Map<String, int> _answeredFreshCounts = {};
  bool _answeredCountsLoaded = false;
  bool _isLoadingAnsweredCounts = false;

  @override
  void initState() {
    super.initState();
    // Add this widget as an observer for app lifecycle changes
    WidgetsBinding.instance.addObserver(this);
    // Seed the chip-driven filter (topic / review) from the constructor.
    _activeCategoryFilter = widget.initialCategoryFilter;
    _activeReviewTagFilter = widget.initialReviewTagFilter;
    _activeReviewTagIds = (widget.initialReviewQuestionIds ?? const <String>[]).toSet();
    // Track that the search surface was opened (never records query text).
    AnalyticsService().trackEvent('search_opened', {'source': widget.source});
    // Dedicated Archive open event for the non-search entry points.
    if (widget.source == 'archive_icon' ||
        widget.source == 'topic_chip' ||
        widget.source == 'review_chip') {
      AnalyticsService().trackEvent('archive_opened', {'source': widget.source});
    }
    // Load device-local search history for the empty state
    _loadSearchHistory();
    // Schedule the loading of questions after the first frame
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadQuestions();
      // Restore the persisted per-section sorts first, so the queue is fetched
      // once — in the user's chosen order — rather than fetched then re-fetched.
      _loadArchiveSorts().then((_) => _loadArchiveQueue());
    });
  }

  // ---- Search history (SharedPreferences, LRU with dedup) -------------------

  Future<void> _loadSearchHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_historyPrefsKey);
      final history = SearchHistory.decode(raw, max: _historyMaxLength);
      if (mounted) {
        setState(() {
          _searchHistory = history;
          _historyLoaded = true;
        });
      }
    } catch (e) {
      print('Error loading search history: $e');
      if (mounted) {
        setState(() {
          _historyLoaded = true;
        });
      }
    }
  }

  Future<void> _addToHistory(String rawQuery) async {
    // LRU with case-insensitive dedup, newest first, capped at the max length.
    final trimmed = SearchHistory.add(
      _searchHistory,
      rawQuery,
      max: _historyMaxLength,
      minLength: _minQueryLength,
    );

    // add() returns the input unchanged for blank/too-short queries.
    if (trimmed.length == _searchHistory.length &&
        (rawQuery.trim().isEmpty || rawQuery.trim().length < _minQueryLength)) {
      return;
    }

    setState(() {
      _searchHistory = trimmed;
    });

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_historyPrefsKey, SearchHistory.encode(trimmed));
    } catch (e) {
      print('Error saving search history: $e');
    }
  }

  Future<void> _removeHistoryItem(String query) async {
    final updated = SearchHistory.remove(_searchHistory, query);
    setState(() {
      _searchHistory = updated;
    });
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_historyPrefsKey, SearchHistory.encode(updated));
    } catch (e) {
      print('Error saving search history: $e');
    }
  }

  Future<void> _clearHistory() async {
    setState(() {
      _searchHistory = [];
    });
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_historyPrefsKey);
    } catch (e) {
      print('Error clearing search history: $e');
    }
  }

  /// Re-run a search from a tapped recent-search entry.
  void _runHistoryQuery(String query) {
    _searchController.text = query;
    _searchController.selection = TextSelection.fromPosition(
      TextPosition(offset: query.length),
    );
    _onSearchChanged(query);
    _addToHistory(query);
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

    // NOTE: this only warms the QuestionService provider — it is NOT a text
    // search, so it must not toggle `_isSearching`. Doing so would mask the
    // empty state (recent searches / Top All Time) behind the "Searching…"
    // spinner every time the screen is opened.
    try {
      await Provider.of<QuestionService>(context, listen: false).fetchQuestions();
    } catch (e) {
      print('Error loading questions: $e');
    }
  }

  // ---- Archive per-section sort (SharedPreferences) -------------------------

  /// Restores the persisted Unanswered / Answered sorts. A missing or
  /// unrecognised stored value falls back to the section default, so a first run
  /// (and a read failure) behaves exactly as before the flip existed.
  Future<void> _loadArchiveSorts() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final unanswered = ArchiveSort.fromWireName(
        prefs.getString(_unansweredSortPrefsKey),
        fallback: defaultArchiveSort(kArchiveUnansweredSection),
      );
      final answered = ArchiveSort.fromWireName(
        prefs.getString(_answeredSortPrefsKey),
        fallback: defaultArchiveSort(kArchiveAnsweredSection),
      );
      if (!mounted) return;
      setState(() {
        _unansweredSort = unanswered;
        _answeredSort = answered;
      });
    } catch (e) {
      print('Error loading archive sort preferences: $e');
    }
  }

  Future<void> _saveArchiveSort(String section, ArchiveSort sort) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        section == kArchiveAnsweredSection
            ? _answeredSortPrefsKey
            : _unansweredSortPrefsKey,
        sort.wireName,
      );
    } catch (e) {
      print('Error saving archive sort preference: $e');
    }
  }

  /// The sort currently applied to [section].
  ArchiveSort _archiveSortFor(String section) =>
      section == kArchiveAnsweredSection ? _answeredSort : _unansweredSort;

  /// Loads the Unanswered archive queue via the shared
  /// [QuestionService.fetchArchiveQueue] (question_feed_scores by vote_count or
  /// created_at desc — see [_unansweredSort] — with client-side
  /// answered/reported/NSFW subtraction). Paginates with the same offset pattern
  /// the old Top All Time list used.
  ///
  /// [force] bypasses the concurrency guard for a sort flip: the in-flight
  /// request is superseded (its response is dropped by the [_archiveRequestId]
  /// check) rather than leaving the list in the previous order.
  Future<void> _loadArchiveQueue({bool loadMore = false, bool force = false}) async {
    if (!mounted) return;

    // Prevent concurrent requests; stop paginating once the source is drained.
    if (!force && (_isLoadingArchive || _isLoadingMoreArchive)) return;
    if (loadMore && _archiveExhausted) return;

    final int requestId = ++_archiveRequestId;
    final ArchiveSort sort = _unansweredSort;

    setState(() {
      if (loadMore) {
        _isLoadingMoreArchive = true;
      } else {
        _isLoadingArchive = true;
        // A superseded load-more response is discarded, so clear its spinner.
        _isLoadingMoreArchive = false;
        _archiveOffset = 0;
        _archiveExhausted = false;
      }
    });

    try {
      final questionService = Provider.of<QuestionService>(context, listen: false);
      final userService = Provider.of<UserService>(context, listen: false);

      final page = await questionService.fetchArchiveQueue(
        userService: userService,
        limit: _archiveLimit,
        offset: _archiveOffset,
        showNSFW: userService.showNSFWContent,
        sort: sort,
      );

      if (mounted && requestId == _archiveRequestId) {
        setState(() {
          if (loadMore) {
            // Dedup against what we already have (the service over-fetches, so
            // pages can overlap at the offset boundary).
            final existing = _archiveQueue
                .map((q) => q['id']?.toString())
                .whereType<String>()
                .toSet();
            _archiveQueue.addAll(
              page.where((q) => !existing.contains(q['id']?.toString())),
            );
            _isLoadingMoreArchive = false;
          } else {
            _archiveQueue = page;
            _isLoadingArchive = false;
          }
          // A short page means the underlying source is exhausted.
          if (page.length < _archiveLimit) _archiveExhausted = true;
          _archiveOffset += _archiveLimit;
        });
      }
    } catch (e) {
      print('Error loading archive queue: $e');
      if (mounted && requestId == _archiveRequestId) {
        setState(() {
          if (!loadMore) _archiveQueue = [];
          _isLoadingArchive = false;
          _isLoadingMoreArchive = false;
        });
      }
    }
  }

  /// The archive queue as rendered: defensively re-subtract answered / reported
  /// questions (the local answered set can change after the fetch) and apply the
  /// active topic / review chip filter.
  List<Map<String, dynamic>> _visibleArchiveQueue(UserService userService) {
    final answeredIds = userService.answeredQuestions
        .map((q) => q['id']?.toString())
        .whereType<String>()
        .toSet();
    var list = archiveQueueExcludingAnswered(_archiveQueue, answeredIds);
    list = list
        .where((q) => !userService.shouldHideReportedQuestion(q['id'].toString()))
        .toList();
    return _applyChipFilter(list);
  }

  /// The "Answered" view: the user's answered questions in the section's chosen
  /// order — newest answered first, or by vote count (fresh server counts merged
  /// over the stored answer-time value) — guest-migration stubs excluded, then
  /// narrowed by the active topic / review chip filter (which applies to
  /// whichever view is showing). The list is local, so both sorts are applied
  /// client-side.
  List<Map<String, dynamic>> _visibleYourAnswers(UserService userService) {
    final merged = mergeAnsweredWithFreshCounts(
      userService.answeredQuestions,
      _answeredFreshCounts,
    );
    return _applyChipFilter(sortYourAnswers(merged, _answeredSort));
  }

  /// Lazily fetches fresh vote counts for the user's answered questions the
  /// first time the Answered view is shown, so it can rank by current
  /// popularity rather than the votes frozen at answer time. Batched into one
  /// query; on failure it silently falls back to the stored votes (handled by
  /// [mergeAnsweredWithFreshCounts]).
  Future<void> _loadAnsweredVoteCounts() async {
    if (!mounted || _answeredCountsLoaded || _isLoadingAnsweredCounts) return;

    final userService = Provider.of<UserService>(context, listen: false);
    final ids = userService.answeredQuestions
        .map((q) => q['id']?.toString())
        .whereType<String>()
        .where((id) => id.isNotEmpty)
        .toList();
    if (ids.isEmpty) {
      setState(() => _answeredCountsLoaded = true);
      return;
    }

    setState(() => _isLoadingAnsweredCounts = true);
    try {
      final questionService =
          Provider.of<QuestionService>(context, listen: false);
      final counts = await questionService.fetchVoteCountsForIds(ids);
      if (mounted) {
        setState(() {
          _answeredFreshCounts = counts;
          _answeredCountsLoaded = true;
          _isLoadingAnsweredCounts = false;
        });
      }
    } catch (e) {
      print('Error loading answered vote counts: $e');
      if (mounted) {
        setState(() {
          _answeredCountsLoaded = true; // fall back to stored votes
          _isLoadingAnsweredCounts = false;
        });
      }
    }
  }

  /// Applies the active topic / review chip filter to [list]. Category match:
  /// the question's `categories` list contains the topic name (tolerant of both
  /// the `List<String>` and `List<{name}>` shapes). Review match: the question
  /// id is in the qualifying id set.
  List<Map<String, dynamic>> _applyChipFilter(List<Map<String, dynamic>> list) {
    var result = list;
    if (_activeCategoryFilter != null) {
      result = result
          .where((q) => _questionHasCategory(q, _activeCategoryFilter!))
          .toList();
    }
    if (_activeReviewTagFilter != null) {
      result = result
          .where((q) => _activeReviewTagIds.contains(q['id']?.toString()))
          .toList();
    }
    return result;
  }

  bool _questionHasCategory(Map<String, dynamic> question, String categoryName) {
    final cats = question['categories'];
    if (cats is! List) return false;
    final target = categoryName.toLowerCase();
    for (final c in cats) {
      final name = c is String
          ? c
          : (c is Map ? c['name']?.toString() : null);
      if (name != null && name.toLowerCase() == target) return true;
    }
    return false;
  }

  void _clearChipFilter() {
    setState(() {
      _activeCategoryFilter = null;
      _activeReviewTagFilter = null;
      _activeReviewTagIds = {};
      // Re-apply (now empty) chip filter to any active search results.
      if (_hasSearched && _originalSearchResults.isNotEmpty) {
        _searchResults = _applyClientSideFilters(_originalSearchResults);
      }
    });
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

        // Analytics: never records the raw query text, only its length.
        AnalyticsService().trackEvent('search_performed', {
          'query_length': query.length,
          'result_count': filteredResults.length,
          'filters_active': _hasActiveFilters(),
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
      // Empty-query default view: the full Archive surface (recent searches when
      // present, then the Unanswered queue, then Your answers).
      return _buildDefaultView();
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

  // ---- Default (empty-query) Archive view ----------------------------------

  /// The empty-query default view: a single scrollable with the recent-searches
  /// block (when history exists), the Answered / Unanswered toggle, and the
  /// active view's questions. Pagination for the Unanswered queue is driven by
  /// the outer scroll NotificationListener (see [build]).
  Widget _buildDefaultView() {
    final userService = Provider.of<UserService>(context, listen: false);
    final children = <Widget>[];

    // Dismissible topic / review filter header.
    if (_hasChipFilter) children.add(_buildFilterHeader());

    // Recent searches (compact) — respects the no-flash-while-loading rule.
    switch (searchEmptyState(
      historyLoaded: _historyLoaded,
      hasHistory: _searchHistory.isNotEmpty,
    )) {
      case SearchEmptyState.loadingHistory:
      case SearchEmptyState.archiveQueue:
        break; // No recent-searches block.
      case SearchEmptyState.recentSearches:
        children.add(_buildRecentSearchesCompact());
        break;
    }

    // Answered / Unanswered toggle, with the active section's sort spelled out
    // beneath it ("Unanswered — most answered first", …).
    children.add(_buildArchiveToggle());
    children.add(_buildArchiveSectionHeader());

    if (_archiveView == kArchiveUnansweredSection) {
      _buildUnansweredView(children, userService);
    } else {
      _buildAnsweredView(children, userService);
    }

    children.add(const SizedBox(height: 24));

    return ListView(
      controller: _popularScrollController,
      children: children,
    );
  }

  /// The one-line section header under the toggle, spelling out the active
  /// section's sort ("Unanswered — most answered first", "Your answers — newest
  /// first", …) so the flip is legible as words and not only as the chip's
  /// indicator.
  Widget _buildArchiveSectionHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Text(
        archiveSectionHeader(_archiveView, _archiveSortFor(_archiveView)),
        style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
      ),
    );
  }

  /// Appends the Unanswered queue tiles (in [_unansweredSort]'s order, with the
  /// load-more spinner) to [children]. Infinite scroll is driven by the build's
  /// NotificationListener.
  void _buildUnansweredView(
    List<Widget> children,
    UserService userService,
  ) {
    final archive = _visibleArchiveQueue(userService);
    if (_isLoadingArchive && archive.isEmpty) {
      children.add(const Padding(
        padding: EdgeInsets.all(24.0),
        child: Center(child: CircularProgressIndicator()),
      ));
    } else if (archive.isEmpty) {
      children.add(_buildEmptyArchiveNotice());
    } else {
      for (int i = 0; i < archive.length; i++) {
        children.add(_buildQuestionTile(
          context,
          archive[i],
          userService,
          orderedList: archive,
          rank: i,
          feedType: 'archive',
          entrySource: 'archive',
          analyticsSection: 'archive',
        ));
      }
      if (_isLoadingMoreArchive) {
        children.add(const Padding(
          padding: EdgeInsets.all(16.0),
          child: Center(child: CircularProgressIndicator()),
        ));
      }
    }
  }

  /// Appends the "Answered" view tiles (in [_answeredSort]'s order,
  /// guest-migration stubs excluded, routing straight to results) to [children].
  void _buildAnsweredView(
    List<Widget> children,
    UserService userService,
  ) {
    final yours = _visibleYourAnswers(userService);
    if (_isLoadingAnsweredCounts && yours.isEmpty) {
      children.add(const Padding(
        padding: EdgeInsets.all(24.0),
        child: Center(child: CircularProgressIndicator()),
      ));
    } else if (yours.isEmpty) {
      children.add(_buildEmptyAnsweredNotice());
    } else {
      for (int i = 0; i < yours.length; i++) {
        children.add(_buildQuestionTile(
          context,
          yours[i],
          userService,
          orderedList: yours,
          rank: i,
          feedType: 'archive',
          entrySource: 'archive',
          analyticsSection: 'your_answers',
          forceResults: true,
        ));
      }
    }
  }

  /// The Answered / Unanswered segmented toggle, styled to match the screen's
  /// existing pill chips (rounded, primaryColor-tinted when active). The
  /// selected chip carries its section's sort ("Popular ⇅" / "New ⇅"), which
  /// tapping that chip again flips.
  Widget _buildArchiveToggle() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
      child: Row(
        children: [
          Expanded(
            child: _buildToggleChip(
              label: 'Unanswered',
              value: kArchiveUnansweredSection,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _buildToggleChip(
              label: 'Answered',
              value: kArchiveAnsweredSection,
            ),
          ),
        ],
      ),
    );
  }

  /// Handles a toggle-chip tap: the other chip selects that section, the
  /// already-selected chip flips that section's sort between Popular and New
  /// (persisted, with a haptic and an `archive_sort_changed` event).
  void _onArchiveTogglePressed(String value) {
    final outcome = archiveToggleTap(
      currentView: _archiveView,
      tappedView: value,
      tappedSectionSort: _archiveSortFor(value),
    );

    if (outcome.sortFlipped) {
      AppHaptics.lightImpact();
      AnalyticsService().trackEvent('archive_sort_changed', {
        'section': value,
        'sort': outcome.sort.wireName,
      });
      setState(() {
        if (value == kArchiveAnsweredSection) {
          _answeredSort = outcome.sort;
        } else {
          _unansweredSort = outcome.sort;
          // The queue's order comes from the server, so drop the page we have
          // rather than show it in the sort the user just left.
          _archiveQueue = [];
        }
      });
      _saveArchiveSort(value, outcome.sort);
      if (value == kArchiveUnansweredSection) {
        _loadArchiveQueue(force: true);
      }
      return;
    }

    if (!outcome.viewChanged) return;
    setState(() => _archiveView = outcome.view);
    // Lazily fetch fresh answered vote counts the first time Answered shows.
    if (outcome.view == kArchiveAnsweredSection) _loadAnsweredVoteCounts();
  }

  Widget _buildToggleChip({required String label, required String value}) {
    final selected = _archiveView == value;
    final primary = Theme.of(context).primaryColor;
    final sort = _archiveSortFor(value);
    final chip = InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: () => _onArchiveTogglePressed(value),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          border: Border.all(
            color: selected ? primary : Colors.grey.shade300,
          ),
          borderRadius: BorderRadius.circular(20),
          color: selected ? primary.withOpacity(0.1) : null,
        ),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                  color: selected ? primary : Colors.grey.shade600,
                ),
              ),
              // Sort indicator on the selected chip only — the affordance for
              // "tap again to flip".
              if (selected) ...[
                const SizedBox(width: 6),
                Text(
                  archiveSortChipLabel(sort),
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: primary.withOpacity(0.8),
                  ),
                ),
                const SizedBox(width: 2),
                Icon(Icons.swap_vert, size: 14, color: primary.withOpacity(0.8)),
              ],
            ],
          ),
        ),
      ),
    );

    if (!selected) return chip;
    return Tooltip(
      message: 'Tap again to sort by ${archiveSortChipLabel(sort.flipped)}',
      child: chip,
    );
  }

  Widget _buildEmptyAnsweredNotice() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 32.0),
      child: Center(
        child: Column(
          children: [
            const Icon(Icons.history_toggle_off, size: 48, color: Colors.grey),
            const SizedBox(height: 12),
            Text(
              _hasChipFilter
                  ? 'None of your answers match this filter.'
                  : 'You haven\'t answered any questions yet.',
              style: const TextStyle(color: Colors.grey),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFilterHeader() {
    final String label;
    if (_activeCategoryFilter != null) {
      label = 'Topic: $_activeCategoryFilter';
    } else {
      final tag = _activeReviewTagFilter;
      label = 'Review: ${ReviewTagNavigation.chipLabels[tag] ?? tag}';
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Align(
        alignment: Alignment.centerLeft,
        child: InputChip(
          label: Text(label),
          onDeleted: _clearChipFilter,
          deleteIcon: const Icon(Icons.close, size: 18),
          backgroundColor: Theme.of(context).primaryColor.withOpacity(0.1),
          side: BorderSide(
            color: Theme.of(context).primaryColor.withOpacity(0.3),
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyArchiveNotice() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 32.0),
      child: Center(
        child: Column(
          children: [
            const Icon(Icons.inbox, size: 48, color: Colors.grey),
            const SizedBox(height: 12),
            Text(
              _hasChipFilter
                  ? 'No unanswered questions match this filter.'
                  : 'You\'re all caught up — no unanswered questions right now.',
              style: const TextStyle(color: Colors.grey),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  /// Compact recent-searches block (no nested scroll view — it composes inside
  /// the default view's single ListView).
  Widget _buildRecentSearchesCompact() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 16),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
          child: Row(
            children: [
              const Expanded(
                child: Text(
                  'Recent searches',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
              ),
              TextButton(
                onPressed: _clearHistory,
                child: const Text('Clear all'),
              ),
            ],
          ),
        ),
        ..._searchHistory.map((query) => ListTile(
              dense: true,
              leading: const Icon(Icons.history, color: Colors.grey),
              title: Text(
                query,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: IconButton(
                icon: const Icon(Icons.close, size: 18, color: Colors.grey),
                tooltip: 'Remove',
                onPressed: () => _removeHistoryItem(query),
              ),
              onTap: () => _runHistoryQuery(query),
            )),
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

  /// Builds a single search-result tile, shared by the "Posted by me" and
  /// "All results" sections. [rank] is the position within its section and
  /// [section] is 'mine' | 'all' (used for analytics only).
  /// Shared question tile for every section: genuine text-search results
  /// ([feedType] 'search', [entrySource] 'search', records history on tap), the
  /// Archive "Unanswered" queue and "Your answers" ([feedType] 'archive',
  /// [entrySource] 'archive'). [orderedList] backs the swipe-navigation
  /// FeedContext so swipe walks that section. [forceResults] routes straight to
  /// the results screen (used by "Your answers", which are all answered).
  Widget _buildQuestionTile(
    BuildContext context,
    Map<String, dynamic> question,
    UserService userService, {
    required List<Map<String, dynamic>> orderedList,
    required int rank,
    required String feedType,
    required String entrySource,
    required String analyticsSection,
    bool recordHistoryOnTap = false,
    bool forceResults = false,
  }) {
    final hasAnswered =
        forceResults || userService.hasAnsweredQuestion(question['id']);

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
      child: InkWell(
        borderRadius: BorderRadius.circular(8.0),
        onLongPress: () => BoostDialog.show(context, question),
        onTap: () {
          final questionService = Provider.of<QuestionService>(context, listen: false);
          final locationService = Provider.of<LocationService>(context, listen: false);

          // A tapped text-search result counts as a "used" query → record it.
          if (recordHistoryOnTap) {
            _addToHistory(_displayQuery);
          }

          AnalyticsService().trackEvent('search_result_tapped', {
            'result_rank': rank,
            'section': analyticsSection,
          });

          // FeedContext over this section so swipe navigation walks it.
          final filters = <String, dynamic>{
            'feedType': feedType,
            'showNSFW': userService.showNSFWContent,
            'userCountry': locationService.userLocation?['country_code'],
            'userCity': locationService.selectedCity?['id'],
            if (feedType == 'search') 'searchQuery': _displayQuery,
          };

          final questionIndex = orderedList.indexOf(question);
          final feedContext = FeedContext(
            feedType: feedType,
            filters: filters,
            questions: orderedList,
            currentQuestionIndex: questionIndex,
            originalQuestionId: question['id']?.toString(),
            originalQuestionIndex: questionIndex,
          );

          // Answered → results, unanswered → answer screen (guest gating and
          // answered/unanswered routing preserved by the service navigators).
          if (forceResults || userService.hasAnsweredQuestion(question['id'])) {
            questionService.navigateToResultsScreen(context, question, feedContext: feedContext, fromSearch: true);
          } else {
            questionService.navigateToAnswerScreen(context, question, feedContext: feedContext, fromSearch: true, entrySource: entrySource);
          }
        },
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
        ),
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
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


  bool _hasActiveFilters() {
    return _sortMode != 'popular' ||
           _selectedCountry != null ||
           _selectedCity != null ||
           _selectedReviewTags.isNotEmpty;
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

    if (_selectedReviewTags.isNotEmpty) {
      if (_selectedReviewTags.length == 1) {
        final label = ReviewTagNavigation.chipLabels[_selectedReviewTags.first] ?? _selectedReviewTags.first;
        filters.add('Review: $label');
      } else {
        filters.add('Reviews: ${_selectedReviewTags.length} selected');
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

    // Apply the active topic / review chip filter (from a chip-driven entry).
    filtered = _applyChipFilter(filtered);

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
    
    // Apply review tag filtering - include questions whose IDs match the qualifying set
    if (_selectedReviewTags.isNotEmpty && _reviewFilterQuestionIds.isNotEmpty) {
      filtered = filtered.where((question) {
        return _reviewFilterQuestionIds.contains(question['id']?.toString());
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
        title: const Text('Archive'),
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
              // Infinite-scroll pagination for the Unanswered archive queue
              // only (the Answered view is a fixed, fully-loaded list).
              if (_archiveView == kArchiveUnansweredSection &&
                  notification.metrics.pixels >=
                      notification.metrics.maxScrollExtent - 300 &&
                  !_isLoadingArchive &&
                  !_isLoadingMoreArchive &&
                  !_archiveExhausted) {
                _loadArchiveQueue(loadMore: true);
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

            Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: Hero(
                    tag: kSearchHeroTag,
                    // Keep the field interactive during/after the flight.
                    flightShuttleBuilder: (context, animation, direction,
                        fromContext, toContext) {
                      return Material(
                        color: Colors.transparent,
                        child: toContext.widget,
                      );
                    },
                    child: Material(
                      color: Colors.transparent,
                      child: TextField(
                        controller: _searchController,
                        focusNode: _searchFocusNode, // Add focus node
                        autofocus: widget.autofocus, // Focus when opened from the Home pill
                        textInputAction: TextInputAction.search,
                        decoration: InputDecoration(
                          hintText: 'Search Read the Room…',
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
                        onSubmitted: (value) {
                          // "Submitted" query → record in device-local history.
                          _addToHistory(value);
                        },
                      ),
                    ),
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

                  // Group "Posted by me" first, then "All results".
                  // Both sections already respect the sort/location/reviews
                  // filters applied in _applyClientSideFilters().
                  final currentUserId = Supabase.instance.client.auth.currentUser?.id;
                  final groups =
                      partitionByAuthor(filteredQuestions, currentUserId);
                  final mine = groups.mine;
                  final others = groups.others;
                  // Ordered list backs swipe-navigation FeedContext across sections.
                  final orderedResults = groups.ordered;

                  // Build a flat entry list of headers + tiles for lazy rendering.
                  final entries = <_SearchEntry>[];
                  final bool showSectionHeaders = groups.hasMine;
                  if (showSectionHeaders) {
                    entries.add(_SearchEntry.header('Posted by me'));
                    for (int i = 0; i < mine.length; i++) {
                      entries.add(_SearchEntry.tile(mine[i], i, 'mine'));
                    }
                    entries.add(_SearchEntry.header('All results'));
                    for (int i = 0; i < others.length; i++) {
                      entries.add(_SearchEntry.tile(others[i], i, 'all'));
                    }
                  } else {
                    for (int i = 0; i < others.length; i++) {
                      entries.add(_SearchEntry.tile(others[i], i, 'all'));
                    }
                  }

                  // Show grouped results
                  return RefreshIndicator(
                    onRefresh: _loadQuestions,
                    child: ListView.builder(
                      itemCount: entries.length,
                      itemBuilder: (context, index) {
                        final entry = entries[index];
                        if (entry.isHeader) {
                          return Padding(
                            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                            child: Text(
                              entry.headerLabel!,
                              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.bold,
                                color: Theme.of(context).primaryColor,
                              ),
                            ),
                          );
                        }
                        return _buildQuestionTile(
                          context,
                          entry.question!,
                          userService,
                          orderedList: orderedResults,
                          rank: entry.rank,
                          feedType: 'search',
                          entrySource: 'search',
                          analyticsSection: entry.section!,
                          recordHistoryOnTap: true,
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

/// A single row in the grouped search results list: either a section header
/// ("Posted by me" / "All results") or a question tile.
class _SearchEntry {
  final bool isHeader;
  final String? headerLabel;
  final Map<String, dynamic>? question;
  final int rank; // position within the section (tiles only)
  final String? section; // 'mine' | 'all' (tiles only)

  _SearchEntry.header(this.headerLabel)
      : isHeader = true,
        question = null,
        rank = -1,
        section = null;

  _SearchEntry.tile(this.question, this.rank, this.section)
      : isHeader = false,
        headerLabel = null;
}
