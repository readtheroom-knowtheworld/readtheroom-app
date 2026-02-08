// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:provider/provider.dart';
import 'package:posthog_flutter/posthog_flutter.dart';
import 'home_screen.dart';
import 'user_screen.dart';
import 'settings_screen.dart';
import 'search_screen.dart'; 
import 'activity_screen.dart';
import '../widgets/app_drawer.dart';
import 'authentication_screen.dart';
import '../services/location_service.dart';
import '../services/user_service.dart';
import '../services/question_service.dart';
import '../services/navigation_visibility_notifier.dart';
import '../services/notification_log_service.dart';
import '../services/streak_reminder_service.dart';
import '../widgets/authentication_dialog.dart';
import '../widgets/whats_new_dialog.dart';

class MainScreen extends StatefulWidget {
  final int initialIndex;
  
  const MainScreen({Key? key, this.initialIndex = 0}) : super(key: key);
  
  @override
  _MainScreenState createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> with WidgetsBindingObserver {
  late int _selectedIndex;
  final _supabase = Supabase.instance.client;
  final GlobalKey<HomeScreenState> _homeKey = GlobalKey<HomeScreenState>();
  final GlobalKey<SearchScreenState> _searchKey = GlobalKey<SearchScreenState>();
  final NotificationLogService _notificationService = NotificationLogService();
  bool _wasInBackground = false;
  bool _hasUnviewedNotifications = false;

  @override
  void initState() {
    super.initState();
    _selectedIndex = widget.initialIndex;
    WidgetsBinding.instance.addObserver(this);
    
    // Track screen view
    _trackScreenView();
    
    // Check for unviewed notifications
    _checkUnviewedNotifications();
    
    // Send a test event to validate PostHog integration
    Posthog().capture(
      eventName: 'app_main_screen_loaded',
      properties: {
        'initial_tab_index': widget.initialIndex,
        'timestamp': DateTime.now().toIso8601String(),
      },
    );

    // Show "What's New?" dialog if there's a new version to announce
    WidgetsBinding.instance.addPostFrameCallback((_) {
      WhatsNewDialog.checkAndShow(context);
    });
  }
  
  void _trackScreenView() {
    String screenName;
    switch (_selectedIndex) {
      case 0:
        screenName = 'Home Tab';
        break;
      case 1:
        screenName = 'Search Tab';
        break;
      case 2:
        screenName = 'Activity Tab';
        break;
      case 3:
        screenName = 'User Profile Tab';
        break;
      default:
        screenName = 'Main Screen';
    }
    
    Posthog().screen(screenName: screenName);
  }

  Future<void> _checkUnviewedNotifications() async {
    final isAuthenticated = _supabase.auth.currentUser != null;
    if (isAuthenticated) {
      final hasUnviewed = await _notificationService.hasUnviewedTodaysNotifications();
      if (mounted) {
        setState(() {
          _hasUnviewedNotifications = hasUnviewed;
        });
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    
    switch (state) {
      case AppLifecycleState.resumed:
        // App came to foreground - no automatic refresh
        // Refreshes should only happen on:
        // 1. Pull-down refresh
        // 2. Refresh button at bottom of feed
        // 3. App cold-start
        _wasInBackground = false;
        print('MainScreen: App resumed from background');

        // Verify streak reminder notifications are still scheduled
        // This handles cases where notifications were cleared or device was rebooted
        _verifyStreakReminders();
        break;
      case AppLifecycleState.paused:
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
        // App went to background
        _wasInBackground = true;
        break;
    }
  }

  /// Verify streak reminder notifications are still scheduled and reschedule if missing
  /// This handles cases where notifications were cleared by the user or lost after device reboot
  void _verifyStreakReminders() async {
    try {
      final streakReminderService = StreakReminderService();
      await streakReminderService.verifyAndRescheduleIfNeeded();
    } catch (e) {
      print('MainScreen: Error verifying streak reminders: $e');
      // Don't let this error affect the app
    }
  }

  void _onItemTapped(int index) {
    // Check if we're already on home tab and tapping home again
    if (index == 0 && _selectedIndex == 0) {
      // Already on home tab, scroll to top
      print('MainScreen: Already on home tab, scrolling to top');
      _homeKey.currentState?.scrollToTop();
      return;
    }

    if (index == 1 && _selectedIndex == 1) {
      // Already on search tab, scroll to top
      print('MainScreen: Already on search tab, scrolling to top');
      _searchKey.currentState?.scrollToTop();
      return;
    }
    
    // Unfocus any active text fields to prevent keyboard issues
    FocusScope.of(context).unfocus();
    
    setState(() {
      _selectedIndex = index;
    });
    
    // Track screen view for the new tab
    _trackScreenView();
    
    // Check for notifications when switching to activity tab
    if (index == 2) {
      _checkUnviewedNotifications();
    }
    
    // Show navigation when switching tabs
    final navigationNotifier = Provider.of<NavigationVisibilityNotifier>(context, listen: false);
    navigationNotifier.showNavigation(reason: 'tab_switch');
    
    // Just switch tabs without triggering any refresh
    // Refreshes should only happen on:
    // 1. Pull-down refresh
    // 2. Refresh button at bottom of feed
    // 3. App cold-start
    print('MainScreen: Switched to tab $index');
  }


  void _handleNewQuestion() async {
    final locationService = Provider.of<LocationService>(context, listen: false);
    
    // Ensure LocationService is initialized
    if (!locationService.isInitialized) {
      print('DEBUG: LocationService not initialized in _handleNewQuestion, initializing now...');
      await locationService.initialize();
      print('DEBUG: LocationService initialized, selectedCity: ${locationService.selectedCity}');
    }
    
    final isAuthenticated = _supabase.auth.currentUser != null;
    final hasCity = locationService.selectedCity != null;
    
    print('DEBUG: _handleNewQuestion checks - isAuthenticated: $isAuthenticated, hasCity: $hasCity, selectedCity: ${locationService.selectedCity}');
    
    if (!isAuthenticated || !hasCity) {
      AuthenticationDialog.show(
        context,
        customMessage: 'To submit a question, you need to authenticate as a real person and set your city.',
        onComplete: () {
          Navigator.pushNamed(context, '/new_question');
        },
      );
      return;
    }
    
    Navigator.pushNamed(context, '/new_question');
  }

  // Calculate total engagement from posted questions
  int _calculateTotalEngagement(List<Map<String, dynamic>> postedQuestions) {
    int totalEngagement = 0;
    for (final question in postedQuestions) {
      final votes = question['votes'] as int? ?? 0;
      totalEngagement += votes;
    }
    return totalEngagement;
  }

  // Format engagement count for display
  String _formatCount(int count) {
    if (count >= 10000) {
      final kValue = count / 1000;
      if (kValue == kValue.roundToDouble()) {
        return '${kValue.round()}K+';
      } else {
        return '${kValue.toStringAsFixed(1)}K+';
      }
    } else {
      return count.toString();
    }
  }

  // Get color based on user's rank
  Color _getCounterColor(int rank) {
    if (rank > 0) {
      return Theme.of(context).primaryColor; // Primary color for all ranked users
    } else {
      return Colors.grey; // Grey for unranked
    }
  }

  // Get special badge border decoration for top performers
  BoxDecoration? _getBadgeBorderDecoration(int rank) {
    if (rank >= 1 && rank <= 10) {
      // Rainbow gradient border for ranks 1-10
      return BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        gradient: LinearGradient(
          colors: [
            Colors.red,
            Colors.orange,
            Colors.yellow,
            Colors.green,
            Colors.blue,
            Colors.indigo,
            Colors.purple,
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      );
    }
    return null; // No special border for ranks >10
  }

  // Get special dialog border decoration for top performers
  BoxDecoration? _getDialogBorderDecoration(int rank) {
    if (rank >= 1 && rank <= 10) {
      // Rainbow gradient border for ranks 1-10
      return BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        gradient: LinearGradient(
          colors: [
            Colors.red,
            Colors.orange,
            Colors.yellow,
            Colors.green,
            Colors.blue,
            Colors.indigo,
            Colors.purple,
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      );
    }
    return null; // No special border for ranks >10
  }

  // Calculate percentile rounded to nearest 5%
  String _getPercentileText(int rank, int totalChameleons) {
    if (rank <= 0 || totalChameleons <= 0) return "Unranked";
    
    // Calculate what percentile group they're in (rank position as percentage)
    final percentilePosition = (rank / totalChameleons) * 100;
    
    // Round to nearest 5%
    final roundedPercentile = (percentilePosition / 5).round() * 5;
    
    // Ensure it's between 5 and 100 (don't show "Top 0%")
    final clampedPercentile = roundedPercentile.clamp(5, 100);
    
    return "Top $clampedPercentile%";
  }

  // Show engagement score dialog with ranking
  void _showEngagementDialog(int engagementScore, Map<String, dynamic> rankingData) {
    if (!mounted) return;
    
    final rank = rankingData['recent_30d_rank'] ?? 0;
    final totalUsers = rankingData['totalUsers'] ?? 0;
    final totalChameleons = rankingData['totalChameleons'] ?? 0;
    final userEngagement = rankingData['userEngagement'] ?? 0;
    
    final dialogBorder = _getDialogBorderDecoration(rank);
    
    showDialog(
      context: context,
      builder: (context) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: Container(
          decoration: dialogBorder,
          padding: (rank >= 1 && rank <= 10) ? EdgeInsets.all(3) : EdgeInsets.zero, // 3px padding for rainbow gradient border
          child: Container(
            decoration: BoxDecoration(
              color: Theme.of(context).dialogBackgroundColor,
              borderRadius: BorderRadius.circular((rank >= 1 && rank <= 10) ? 9 : 12),
            ),
            padding: EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Title
                Text(
                  'Camo Counter 🦎',
                  style: Theme.of(context).textTheme.titleLarge,
                  textAlign: TextAlign.center,
                ),
                SizedBox(height: 12),
                // Centered number
                Text(
                  _formatCount(engagementScore),
                  style: Theme.of(context).textTheme.displayLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: Theme.of(context).primaryColor,
                  ),
                  textAlign: TextAlign.center,
                ),
                SizedBox(height: 20),
                // Content
                Text(
                  'The total number of responses to your questions (excluding your own)\n',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                SizedBox(height: 16),
                if (engagementScore == 0) ...[
                  Container(
                    width: double.infinity,
                    padding: EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.grey.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: Colors.grey.withOpacity(0.3),
                      ),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.sentiment_dissatisfied,
                          color: Colors.grey[600],
                          size: 20,
                        ),
                        SizedBox(width: 8),
                        Text(
                          'Your questions haven\'t received responses yet...',
                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: Colors.grey[600],
                            fontWeight: FontWeight.w600,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                ] else if (totalChameleons > 0) ...[
                  Container(
                    width: double.infinity,
                    padding: EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: (rank > 0 && rank <= 100) 
                          ? Theme.of(context).primaryColor.withOpacity(0.1)
                          : Colors.grey.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: (rank > 0 && rank <= 100) 
                            ? Theme.of(context).primaryColor.withOpacity(0.3)
                            : Colors.grey.withOpacity(0.3),
                      ),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.emoji_events,
                          color: (rank > 0 && rank <= 100) 
                              ? Theme.of(context).primaryColor
                              : Colors.grey,
                          size: 20,
                        ),
                        SizedBox(height: 8),
                        Text(
                          rank > 0 
                            ? (rank <= 100 
                                ? 'You are ranked #$rank !'
                                : 'You are in the ${_getPercentileText(rank, totalChameleons)} :D')
                            : 'Post a question to get started!',
                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: (rank > 0 && rank <= 100) 
                                ? Theme.of(context).primaryColor
                                : Colors.grey,
                            fontWeight: FontWeight.w600,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        if (rank > 0) ...[
                          SizedBox(height: 8),
                          Text(
                            'Based on your last 30 days of questions',
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: Colors.grey[600],
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
                SizedBox(height: 16),
                if (engagementScore > 10) ...[
                  Text(
                    (rank > 0 && rank <= 100) 
                        ? 'You seem to be asking the right questions!'
                        : 'Generating some interest...',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).primaryColor,
                      fontWeight: FontWeight.w600,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  SizedBox(height: 16),
                ],
                if (totalUsers > 0) ...[
                  Text(
                    'There are currently $totalUsers chameleons on RTR.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Colors.grey[600],
                    ),
                  ),
                  SizedBox(height: 16),
                ],
                // Action button
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text('Got it'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<UserService>(
      builder: (context, userService, child) {
        return FutureBuilder<Map<String, dynamic>>(
          future: userService.getUserEngagementRanking(),
          builder: (context, snapshot) {
            // Show loading state while fetching data
            if (snapshot.connectionState == ConnectionState.waiting) {
              // Use cached ranking data if available, otherwise fallback to manual calculation
              final cachedRanking = userService.cachedEngagementRanking;
              if (cachedRanking != null) {
                final cachedEngagementScore = cachedRanking['userEngagement'] as int? ?? 0;
                final cachedRank = cachedRanking['rank'] as int? ?? 0;
                return _buildScaffoldWithScore(cachedEngagementScore, cachedRank, rankingData: cachedRanking, isLoading: true);
              } else {
                // Final fallback: calculate from posted questions
                final cachedQuestions = userService.postedQuestions;
                final cachedEngagementScore = _calculateTotalEngagement(cachedQuestions);
                return _buildScaffoldWithScore(cachedEngagementScore, 0, rankingData: {}, isLoading: true);
              }
            }
            
            // Show error state if data fetch failed
            if (snapshot.hasError) {
              print('Error loading engagement ranking: ${snapshot.error}');
              // Try cached data first, then fallback to manual calculation
              final cachedRanking = userService.cachedEngagementRanking;
              if (cachedRanking != null) {
                final cachedEngagementScore = cachedRanking['userEngagement'] as int? ?? 0;
                final cachedRank = cachedRanking['rank'] as int? ?? 0;
                return _buildScaffoldWithScore(cachedEngagementScore, cachedRank, rankingData: cachedRanking, isLoading: false);
              } else {
                // Final fallback: calculate from posted questions
                final cachedQuestions = userService.postedQuestions;
                final cachedEngagementScore = _calculateTotalEngagement(cachedQuestions);
                return _buildScaffoldWithScore(cachedEngagementScore, 0, rankingData: {}, isLoading: false);
              }
            }
            
            // Use engagement score from materialized view (most accurate)
            final rankingData = snapshot.data ?? {};
            final engagementScore = rankingData['userEngagement'] as int? ?? 0;
            final rank = rankingData['rank'] as int? ?? 0;
        
            return _buildScaffoldWithScore(engagementScore, rank, rankingData: rankingData, isLoading: false);
          },
        );
      },
    );
  }

  Widget _buildScaffoldWithScore(int engagementScore, int rank, {Map<String, dynamic>? rankingData, bool isLoading = false}) {
    return Consumer<NavigationVisibilityNotifier>(
      builder: (context, navigationNotifier, child) {
        return Scaffold(
          // Remove appBar and bottomNavigationBar from Scaffold - they'll be overlaid
          drawer: AppDrawer(), // Keeps the side menu accessible.
          body: Stack(
            children: [
              // Main content - always takes full screen
              IndexedStack( // ✅ Keeps all pages alive and prevents flickering.
                index: _selectedIndex,
                children: [
                  HomeScreen(key: _homeKey),
                  SearchScreen(key: _searchKey, isActive: _selectedIndex == 1), // Pass active state
                  ActivityScreen(), // Activity screen
                  UserScreen(), // Load immediately for city info needed for posting/answering
                ],
              ),
              // Left edge gesture detector for opening drawer
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                width: 40,
                child: GestureDetector(
                  onHorizontalDragEnd: (details) {
                    if (details.velocity.pixelsPerSecond.dx > 100) {
                      Scaffold.of(context).openDrawer();
                    }
                  },
                  behavior: HitTestBehavior.translucent,
                  child: Container(color: Colors.transparent),
                ),
              ),
              
              // Top AppBar overlay
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: AnimatedSlide(
                  duration: Duration(milliseconds: 400),
                  curve: Curves.easeOutCubic,
                  offset: navigationNotifier.isNavigationVisible ? Offset.zero : Offset(0, -1),
                  child: AnimatedOpacity(
                    duration: Duration(milliseconds: 350),
                    curve: Curves.easeOutCubic,
                    opacity: navigationNotifier.isNavigationVisible ? 1.0 : 0.0,
                    child: AppBar(
                      title: GestureDetector(
                        onTap: () {
                          // Act like home button tap - scroll to top if already on home
                          if (_selectedIndex == 0) {
                            print('AppBar title tapped: scrolling to top');
                            _homeKey.currentState?.scrollToTop();
                          } else {
                            // Switch to home tab if not already there
                            _onItemTapped(0);
                          }
                        },
                        child: Text('Read The Room'),
                      ),
                      centerTitle: false,
                      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
                      elevation: navigationNotifier.isNavigationVisible ? 4 : 0,
                      actions: [
                        Padding(
                          padding: EdgeInsets.only(right: 16),
                          child: Center(
                            child: GestureDetector(
                              onTap: () => _showEngagementDialog(engagementScore, rankingData ?? {}),
                              child: Container(
                                decoration: _getBadgeBorderDecoration(rank),
                                padding: (rank >= 1 && rank <= 10) ? EdgeInsets.all(2) : EdgeInsets.zero,
                                child: Container(
                                  padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: _getCounterColor(rank),
                                    borderRadius: BorderRadius.circular((rank >= 1 && rank <= 10) ? 10 : 12),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                    if (isLoading) ...[
                                      SizedBox(
                                        width: 12,
                                        height: 12,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                                        ),
                                      ),
                                      SizedBox(width: 4),
                                    ] else ...[
                                        if (rank >= 1 && rank <= 3) ...[
                                          Text(
                                            rank == 1 ? '🥇' : rank == 2 ? '🥈' : '🥉',
                                            style: TextStyle(fontSize: 14),
                                          ),
                                        ] else ...[
                                          Icon(
                                            Icons.favorite,
                                            size: 14,
                                            color: Colors.white,
                                          ),
                                        ],
                                        SizedBox(width: 4),
                                      ],
                                    Text(
                                      _formatCount(engagementScore),
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 12,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              
              // Bottom Navigation Bar overlay
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: AnimatedSlide(
                  duration: Duration(milliseconds: 400),
                  curve: Curves.easeOutCubic,
                  offset: navigationNotifier.isNavigationVisible ? Offset.zero : Offset(0, 1),
                  child: AnimatedOpacity(
                    duration: Duration(milliseconds: 350),
                    curve: Curves.easeOutCubic,
                    opacity: navigationNotifier.isNavigationVisible ? 1.0 : 0.0,
                    child: Container(
                      decoration: BoxDecoration(
                        color: Theme.of(context).scaffoldBackgroundColor,
                        boxShadow: navigationNotifier.isNavigationVisible ? [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.1),
                            blurRadius: 8,
                            offset: Offset(0, -2),
                          ),
                        ] : [],
                      ),
                      child: BottomNavigationBar(
                        currentIndex: _selectedIndex,
                        onTap: _onItemTapped,
                        selectedItemColor: Theme.of(context).primaryColor,
                        unselectedItemColor: Colors.grey,
                        type: BottomNavigationBarType.fixed,
                        backgroundColor: Colors.transparent,
                        elevation: 0,
                        items: [
                          BottomNavigationBarItem(icon: Icon(Icons.home), label: 'Home'),
                          BottomNavigationBarItem(icon: Icon(Icons.search), label: 'Search'),
                          BottomNavigationBarItem(
                            icon: Stack(
                              children: [
                                Icon(Icons.notifications_outlined),
                                if (_hasUnviewedNotifications)
                                  Positioned(
                                    right: 0,
                                    top: 0,
                                    child: Container(
                                      width: 8,
                                      height: 8,
                                      decoration: BoxDecoration(
                                        color: Theme.of(context).primaryColor,
                                        shape: BoxShape.circle,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                            label: 'Activity',
                          ),
                          BottomNavigationBarItem(icon: Icon(Icons.person), label: 'Me'),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              
              // Floating Action Button overlay
              if (_selectedIndex == 0)
                Positioned(
                  bottom: navigationNotifier.isNavigationVisible ? 96 : 16, // More space above bottom nav
                  right: 16,
                  child: AnimatedSlide(
                    duration: Duration(milliseconds: 400),
                    curve: Curves.easeOutCubic,
                    offset: navigationNotifier.isNavigationVisible ? Offset.zero : Offset(0, 2),
                    child: AnimatedOpacity(
                      duration: Duration(milliseconds: 350),
                      curve: Curves.easeOutCubic,
                      opacity: navigationNotifier.isNavigationVisible ? 1.0 : 0.0,
                      child: FloatingActionButton(
                        backgroundColor: Theme.of(context).primaryColor,
                        child: Icon(Icons.create, color: Colors.white),
                        onPressed: _handleNewQuestion,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
