// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import '../utils/main_tab_requests.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:provider/provider.dart';
import 'home_screen.dart';
import 'user_screen.dart';
import 'settings_screen.dart';
import 'community_screen.dart';
import 'activity_screen.dart';
import '../services/friend_service.dart';
import '../widgets/app_drawer.dart';
import 'authentication_screen.dart';
import '../services/location_service.dart';
import '../services/user_service.dart';
import '../services/question_service.dart';
import '../services/friend_chat_service.dart';
import '../services/navigation_visibility_notifier.dart';
import '../services/notification_log_service.dart';
import '../services/post_answer_prompts.dart';
import '../services/analytics_service.dart';
import '../widgets/authentication_dialog.dart';
import '../widgets/friend_qr_dialog.dart';
import '../widgets/new_friend_dialog.dart';
import '../utils/friend_logic.dart';
import '../services/notification_service.dart';
import '../widgets/profile_avatar_chip.dart';
import '../widgets/profile_setup_sheet.dart';
import '../widgets/streak_card.dart';
import '../widgets/whats_new_dialog.dart';

/// Bottom-navigation tab labels in display order. Single source of truth for
/// the Networks tab restructure (design doc §4.5): Home / Community / Activity /
/// Me. Kept as a top-level const so navigation tests can assert the order
/// without pumping [MainScreen] (which needs a live Supabase + provider tree).
const List<String> kMainTabLabels = ['Home', 'Community', 'Activity', 'Me'];

/// Index of the Home tab — the only tab that shows the create-question FAB.
const int kHomeTabIndex = 0;

/// Index of the Community tab — where a scanned friend QR / friend link lands
/// (`DeepLinkService._handleFriendLink`).
const int kCommunityTabIndex = 1;

/// Index of the Activity tab — carries the unviewed-notifications badge.
const int kActivityTabIndex = 2;

/// Index of the Me tab — the destination of the app-bar identity chip.
const int kMeTabIndex = 3;

/// Key of the Community tab's unread dot (WP-F), so a widget test can assert it
/// appears and disappears without measuring 8×8 containers.
const String kCommunityUnreadDotKey = 'community-unread-dot';

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
  final NotificationLogService _notificationService = NotificationLogService();
  bool _wasInBackground = false;
  bool _hasUnviewedNotifications = false;

  @override
  void initState() {
    super.initState();
    _selectedIndex = widget.initialIndex;
    WidgetsBinding.instance.addObserver(this);
    MainTabRequests.instance.addListener(_onTabRequested);
    
    // Track screen view
    _trackScreenView();
    
    // Check for unviewed notifications
    _checkUnviewedNotifications();
    
    // Route through AnalyticsService so it respects opt-out (§4.2 privacy fix;
    // was a raw Posthog().capture() bypassing the opt-out gate).
    AnalyticsService().trackAppMainScreenLoaded({
      'initial_tab_index': widget.initialIndex,
      'timestamp': DateTime.now().toIso8601String(),
    });

    _listenForNewFriends();

    // Show "What's New?" dialog if there's a new version to announce.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await WhatsNewDialog.checkAndShow(context);
      // QOTD overlay removed in v1.3 — home IS the Question of the Day now.

      // Existing users get the chameleon identity prompt once (WP-C3 / D5).
      // Runs after What's New so the two never stack.
      if (mounted) await ProfileSetupSheet.maybeShow(context);

      // The notification ask owed by an answer that had no surface to show it
      // on. The case that matters: a brand-new user answers the QOTD on the
      // onboarding slide, the answer is stashed and replayed by
      // `PendingAnswerService` at the very end of onboarding — at which point
      // `OnboardingScreen` is being replaced by this screen, so the prompt has
      // to be picked up here. Also catches a debt left by an app that died
      // between the answer and the prompt.
      //
      // Last in the chain, so it can never stack on What's New or the identity
      // sheet.
      if (mounted) {
        await PostAnswerPrompts.maybeShow(
          context,
          userService: Provider.of<UserService>(context, listen: false),
          source: 'main_screen',
        );
      }
    });
  }
  
  /// The scanned phone's half of a QR add (owner request 2026-09-23): a
  /// friend-graph push in the foreground reloads the list, and any QR-made
  /// friend that reload (or the My QR dialog's own polling) turns up is
  /// announced with a haptic and [NewFriendDialog]. Both subscriptions are
  /// optional so a test tree without the providers still builds.
  StreamSubscription<Friend>? _newFriendSub;
  StreamSubscription<String>? _friendPushSub;

  void _listenForNewFriends() {
    try {
      final friends = context.read<FriendService>();
      _newFriendSub = friends.qrFriendAdded.listen((friend) {
        if (!mounted) return;
        NewFriendDialog.show(context, friend);
      });
      _friendPushSub = NotificationService().friendGraphChanged.listen((_) {
        if (!mounted) return;
        friends.refresh();
      });
    } catch (_) {
      // No FriendService above us (tests).
    }
  }

  void _trackScreenView() {
    String screenName;
    switch (_selectedIndex) {
      case 0:
        screenName = 'Home Tab';
        break;
      case 1:
        screenName = 'Community Tab';
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
    
    // Routed through AnalyticsService so tab views respect the analytics
    // opt-out — a raw Posthog().screen() bypassed it (same privacy bug §4.2
    // fixed for app_main_screen_loaded).
    AnalyticsService().trackScreenView(screenName);

    // The social funnel's first step. Fired here rather than in
    // CommunityScreen.initState because the tab body is kept alive, so
    // initState runs once per app launch rather than once per visit.
    if (_selectedIndex == kCommunityTabIndex) {
      int friendCount = 0;
      try {
        friendCount = context.read<FriendService>().friendCount;
      } catch (_) {
        // No FriendService above us (tests).
      }
      AnalyticsService()
          .trackEvent('community_viewed', {'friend_count': friendCount});
    }
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
    _newFriendSub?.cancel();
    _friendPushSub?.cancel();
    MainTabRequests.instance.removeListener(_onTabRequested);
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

        // Friend graph: pick up unfriends/accepts that happened while we were
        // in the background (cheap: one get_friends() RPC).
        _refreshFriendGraph();
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

  void _refreshFriendGraph() {
    try {
      final friends = context.read<FriendService>();
      if (friends.isAuthenticated) friends.refresh();
    } catch (_) {
      // No FriendService above us (tests) — nothing to refresh.
    }
  }

  /// A widget below us (the QR dialog's "My stats") asked for a tab.
  void _onTabRequested() {
    final tab = MainTabRequests.instance.take();
    if (tab == null || !mounted) return;
    _onItemTapped(tab == MainTab.me ? kMeTabIndex : tab.index);
  }

  void _onItemTapped(int index) {
    // Check if we're already on home tab and tapping home again
    if (index == 0 && _selectedIndex == 0) {
      // Already on home tab, scroll to top
      print('MainScreen: Already on home tab, scrolling to top');
      _homeKey.currentState?.scrollToTop();
      return;
    }

    // Unfocus any active text fields to prevent keyboard issues
    FocusScope.of(context).unfocus();
    
    setState(() {
      _selectedIndex = index;
    });
    // The friend graph is server-truth (an unfriend on the other side deletes
    // our row too); re-read it whenever the tab comes into view so the list
    // never shows a friendship that no longer exists.
    if (index == kCommunityTabIndex) _refreshFriendGraph();
    
    // Track screen view for the new tab
    _trackScreenView();
    
    // Check for notifications when switching to activity tab
    if (index == kActivityTabIndex) {
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

  @override
  Widget build(BuildContext context) {
    return _buildScaffold();
  }

  Widget _buildScaffold() {
    return Consumer<NavigationVisibilityNotifier>(
      // The pages ride in `child` so notifier ticks (nav hide/show, the FAB's
      // at-bottom flips) rebuild ONLY the overlay chrome below — rebuilding
      // the pages made the home map visibly flash whenever the FAB appeared.
      child: IndexedStack( // ✅ Keeps all pages alive and prevents flickering.
        index: _selectedIndex,
        children: [
          HomeScreen(key: _homeKey, onRequestTab: _onItemTapped),
          CommunityScreen(), // Phase 1 "coming soon" placeholder for Networks
          ActivityScreen(), // Activity screen
          UserScreen(), // Load immediately for city info needed for posting/answering
        ],
      ),
      builder: (context, navigationNotifier, pages) {
        return Scaffold(
          // Remove appBar and bottomNavigationBar from Scaffold - they'll be overlaid
          drawer: AppDrawer(), // Keeps the side menu accessible.
          body: Stack(
            children: [
              // Main content - always takes full screen
              pages!,
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
                      // Light mode: inherit the theme's paper-toned bar (one
                      // shade darker once content scrolls under it). Dark mode
                      // keeps its explicit scaffold colour, unchanged.
                      backgroundColor:
                          Theme.of(context).brightness == Brightness.light
                              ? null
                              : Theme.of(context).scaffoldBackgroundColor,
                      elevation: navigationNotifier.isNavigationVisible ? 4 : 0,
                      actions: [
                        // Identity chip to the right of the title: the user's
                        // chameleon avatar. Tapping it opens the friend QR
                        // dialog (the quick add-a-friend path) with a "See full
                        // profile" action to the Me tab; guests go straight to
                        // the Me tab. Sits in `actions` rather than `leading`
                        // so the drawer hamburger AppBar implies is intact.
                        Center(
                          child: ProfileAvatarChip(
                            onTap: () {
                              final friends = context.read<FriendService>();
                              if (!friends.isAuthenticated) {
                                _onItemTapped(kMeTabIndex);
                                return;
                              }
                              FriendQrDialog.show(
                                context,
                                surface: 'header',
                                onSeeProfile: () => _onItemTapped(kMeTabIndex),
                              );
                            },
                          ),
                        ),
                        const SizedBox(width: 4),
                        // The streak now lives here, replacing the old Camo
                        // Counter badge (engagement stats stay on the Me tab).
                        Padding(
                          padding: EdgeInsets.only(right: 16),
                          child: Center(
                            child: Consumer<UserService>(
                              builder: (context, userService, _) =>
                                  StreakCard(
                                userService: userService,
                                compact: true,
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
                          BottomNavigationBarItem(icon: Icon(Icons.home), label: kMainTabLabels[0]),
                          BottomNavigationBarItem(
                            icon: const CommunityTabIcon(),
                            label: kMainTabLabels[1],
                          ),
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
                            label: kMainTabLabels[kActivityTabIndex],
                          ),
                          BottomNavigationBarItem(icon: Icon(Icons.person), label: kMainTabLabels[3]),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              
              // Floating Action Button overlay (Home tab only). Fades in only
              // once the home scroll reaches its bottom, so it never sits on
              // top of the hero card's own buttons; IgnorePointer keeps the
              // invisible FAB from stealing their taps.
              if (_selectedIndex == kHomeTabIndex)
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
                      opacity: navigationNotifier.isNavigationVisible &&
                              navigationNotifier.isHomeAtBottom
                          ? 1.0
                          : 0.0,
                      child: IgnorePointer(
                        ignoring: !(navigationNotifier.isNavigationVisible &&
                            navigationNotifier.isHomeAtBottom),
                        child: FloatingActionButton(
                          backgroundColor: Theme.of(context).primaryColor,
                          child: Icon(Icons.create, color: Colors.white),
                          onPressed: _handleNewQuestion,
                        ),
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

/// The Community tab's icon, with the friend-chat unread dot (WP-F, §5.4).
///
/// A separate widget so the badge listens to [FriendChatService] on its own:
/// putting a `watch` in [MainScreen.build] would rebuild the whole IndexedStack
/// — every tab page — each time a lick arrived.
///
/// A dot, not a count, matching the Activity tab's badge exactly: the number of
/// unread pokes is not information anyone needs, and the two tabs sitting side
/// by side must not disagree about what a badge looks like. The service is
/// resolved defensively so a frame or a test without the provider renders the
/// plain icon instead of throwing.
class CommunityTabIcon extends StatelessWidget {
  const CommunityTabIcon({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    bool hasUnread = false;
    try {
      hasUnread = context.watch<FriendChatService>().hasUnread;
    } catch (_) {
      hasUnread = false;
    }

    return Stack(
      children: [
        const Icon(Icons.groups_outlined),
        if (hasUnread)
          Positioned(
            right: 0,
            top: 0,
            child: Container(
              key: const ValueKey(kCommunityUnreadDotKey),
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: Theme.of(context).primaryColor,
                shape: BoxShape.circle,
              ),
            ),
          ),
      ],
    );
  }
}
