// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../services/analytics_service.dart';
import '../services/pending_answer_service.dart';
import '../services/profile_service.dart';
import '../services/question_service.dart';
import '../services/user_service.dart';
import '../services/location_service.dart';
import '../widgets/onboarding/onboarding_slide.dart';
import '../widgets/onboarding/welcome_slide.dart';
import '../widgets/onboarding/analytics_consent_slide.dart';
import '../widgets/onboarding/authentication_slide.dart';
import '../config/build_config.dart';
import '../widgets/onboarding/location_setup_slide.dart';
import '../widgets/onboarding/profile_setup_slide.dart';
import '../widgets/onboarding/qotd_question_slide.dart';
import 'authentication_screen.dart';
import 'main_screen.dart';

class OnboardingScreen extends StatefulWidget {
  final String? triggeredFrom;
  
  const OnboardingScreen({Key? key, this.triggeredFrom}) : super(key: key);

  @override
  _OnboardingScreenState createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final PageController _pageController = PageController();
  int _currentPage = 0;
  int get _totalPages =>
      onboardingTotalPages(isFDroid: BuildConfig.isFDroidBuild);
  DateTime? _onboardingStartTime;
  bool _isTouching = false;

  @override
  void initState() {
    super.initState();
    _onboardingStartTime = DateTime.now();
    
    // Track onboarding started (canonical §4.2 + legacy dual-write).
    AnalyticsService().trackOnboardingStepCanonical(
      OnboardingStep.onboardingStarted,
      legacyStepName: 'onboarding_started',
      legacyStepNumber: 0,
      properties: {
        'triggered_from': widget.triggeredFrom ?? 'unknown',
        'total_slides': _totalPages,
      },
    );
    // The welcome slide (page 0) is visible immediately; onPageChanged does not
    // fire for the initial page, so record welcome_viewed here.
    AnalyticsService().trackOnboardingStepCanonical(
      OnboardingStep.welcomeViewed,
      legacyStepName: 'onboarding_slide_viewed',
      legacyStepNumber: 1,
      properties: {
        'slide_number': 1,
        'total_slides': _totalPages,
        'triggered_from': widget.triggeredFrom ?? 'unknown',
      },
    );
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _nextPage() {
    if (_currentPage < _totalPages - 1) {
      _pageController.nextPage(
        duration: Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    }
  }

  bool _shouldShowSkipButton() {
    final locationService = Provider.of<LocationService>(context, listen: false);
    final isAuthenticated = Supabase.instance.client.auth.currentUser != null;
    final hasLocation = locationService.hasLocation;
    return isAuthenticated && hasLocation;
  }

  void _skipOnboarding() async {
    // Track skip event. The canonical funnel gets `onboarding_abandoned` with
    // the step the user bailed on, so the drop-off is readable without
    // reverse-engineering `slides_viewed`; the legacy `onboarding_skipped`
    // name is kept alongside for the existing dashboards.
    final abandonedAt =
        onboardingStepForPage(_currentPage, isFDroid: BuildConfig.isFDroidBuild);
    AnalyticsService().trackOnboardingStepCanonical(
      OnboardingStep.onboardingAbandoned,
      legacyStepName: 'onboarding_skipped',
      legacyStepNumber: _currentPage + 1,
      properties: {
        'abandoned_at_step_id': abandonedAt == null
            ? 'unknown'
            : kOnboardingStepInfo[abandonedAt]!.stepId,
        'slides_viewed': _currentPage + 1,
        'total_slides': _totalPages,
        'triggered_from': widget.triggeredFrom ?? 'unknown',
      },
    );
    
    // Mark onboarding as completed
    await _markOnboardingCompleted();
    
    // Navigate to authentication if not authenticated
    final userService = Provider.of<UserService>(context, listen: false);
    if (Supabase.instance.client.auth.currentUser == null) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (context) => AuthenticationScreen(
            onAuthComplete: () => _navigateAfterAuth(),
          ),
        ),
      );
    } else {
      _navigateAfterAuth();
    }
  }

  void _onPageChanged(int page) {
    setState(() {
      _currentPage = page;
    });

    // Track slide viewed — map the page index to the canonical step (§4.2),
    // keeping the legacy 'onboarding_slide_viewed' name for old dashboards.
    final step = onboardingStepForPage(page, isFDroid: BuildConfig.isFDroidBuild);
    if (step != null) {
      AnalyticsService().trackOnboardingStepCanonical(
        step,
        legacyStepName: 'onboarding_slide_viewed',
        legacyStepNumber: page + 1,
        properties: {
          'slide_number': page + 1,
          'total_slides': _totalPages,
          'triggered_from': widget.triggeredFrom ?? 'unknown',
        },
      );
    }
  }

  Future<void> _markOnboardingCompleted() async {
    print('🦎 ONBOARDING: _markOnboardingCompleted() - Getting SharedPreferences...');
    final prefs = await SharedPreferences.getInstance();
    print('🦎 ONBOARDING: _markOnboardingCompleted() - Setting onboarding_completed = true');
    await prefs.setBool('onboarding_completed', true);
    await prefs.setString('onboarding_completed_at', DateTime.now().toIso8601String());
    print('🦎 ONBOARDING: _markOnboardingCompleted() - SharedPreferences updated successfully');
  }

  void _navigateAfterAuth() async {
    // Every terminal path (finish, skip, already-authenticated) lands here, so
    // this is where the deferred writes are settled: the staged avatar/handle,
    // and the guest QOTD answer — which needed BOTH an account and a city and
    // therefore could not be submitted any earlier.
    if (mounted) {
      try {
        await Provider.of<ProfileService>(context, listen: false)
            .flushPendingSelection();
      } catch (e) {
        print('🦎 ONBOARDING: profile flush failed: $e');
      }
    }
    if (mounted) await _submitPendingAnswer();
    if (mounted) await _flushNotificationState();

    print('🦎 ONBOARDING: _navigateAfterAuth() - Adding delay to ensure SharedPreferences is flushed');
    // Add a small delay to ensure SharedPreferences write is completed before navigation
    await Future.delayed(Duration(milliseconds: 100));
    
    print('🦎 ONBOARDING: _navigateAfterAuth() - Navigating directly to MainScreen');
    // Navigate directly to MainScreen instead of relying on home route
    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(builder: (context) => MainScreen()),
      (route) => false,
    );
    print('🦎 ONBOARDING: _navigateAfterAuth() - Navigation completed');
  }

  /// Passkey slide done: an account now exists, so the avatar/handle the user
  /// staged on the profile slide can finally be written to `user_profiles`. The
  /// stashed QOTD answer still cannot go anywhere — its insert needs a
  /// `city_id` from the location slide that follows — so it waits for
  /// [_onAuthenticationCompleted].
  void _onPasskeyRegistered() async {
    try {
      await Provider.of<ProfileService>(context, listen: false)
          .flushPendingSelection();
    } catch (e) {
      print('🦎 ONBOARDING: profile flush failed: $e');
    }
    if (mounted) _nextPage();
  }

  /// Submits the guest's stashed QOTD answer. Only reachable once auth AND a
  /// city exist, which is exactly what the insert requires.
  Future<void> _submitPendingAnswer() async {
    try {
      final pendingAnswers =
          Provider.of<PendingAnswerService>(context, listen: false);
      if (!pendingAnswers.hasPending) await pendingAnswers.load();
      if (!pendingAnswers.hasPending) return;

      await pendingAnswers.submitIfReady(
        questionService: Provider.of<QuestionService>(context, listen: false),
        locationService: Provider.of<LocationService>(context, listen: false),
        userService: Provider.of<UserService>(context, listen: false),
      );
    } catch (e) {
      print('🦎 ONBOARDING: pending answer submit failed: $e');
    }
  }

  /// Re-applies the notification preferences now that an account exists.
  ///
  /// A guest can accept the notification ask on the QOTD slide — the OS
  /// permission and the `qotd` FCM topic are not user-scoped, so that part
  /// genuinely works. The two writes that *are* user-scoped bail out with a log
  /// line for a guest: `notification_settings.qotd_enabled` (and
  /// `friend_events_enabled`) and the personal `user_{id}` topic. Both are
  /// idempotent and both are exactly what `resyncNotificationState()` re-asserts
  /// from the stored prefs, so running it here is the deferred half of the
  /// guest's grant — the same flush point as the profile and the stashed answer.
  ///
  /// A no-op when nothing was granted (the prefs say off, and the resync
  /// unsubscribes what is already unsubscribed).
  Future<void> _flushNotificationState() async {
    if (Supabase.instance.client.auth.currentUser == null) return;
    try {
      await Provider.of<UserService>(context, listen: false)
          .resyncNotificationState();
    } catch (e) {
      print('🦎 ONBOARDING: notification resync failed: $e');
    }
  }

  void _onAuthenticationCompleted() async {
    print('🦎 ONBOARDING: _onAuthenticationCompleted() called');
    
    // Mark onboarding as completed
    print('🦎 ONBOARDING: Marking onboarding as completed...');
    await _markOnboardingCompleted();
    print('🦎 ONBOARDING: Onboarding marked as completed');
    
    // Track onboarding completion
    final timeSpent = _onboardingStartTime != null 
        ? DateTime.now().difference(_onboardingStartTime!).inSeconds 
        : 0;
    
    AnalyticsService().trackOnboardingStepCanonical(
      OnboardingStep.onboardingCompleted,
      legacyStepName: 'onboarding_completed',
      legacyStepNumber: _totalPages,
      properties: {
        'time_spent_seconds': timeSpent,
        'triggered_from': widget.triggeredFrom ?? 'unknown',
      },
    );
    
    print('🦎 ONBOARDING: Calling _navigateAfterAuth()...');
    _navigateAfterAuth();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: SafeArea(
        child: Column(
          children: [
            // Header with progress and skip button
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 20, vertical: 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  // Progress indicator
                  Text(
                    '${_currentPage + 1}/$_totalPages',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).primaryColor,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  // Skip button (only show if user has location AND is authenticated)
                  if (_shouldShowSkipButton())
                    TextButton(
                      onPressed: _skipOnboarding,
                      child: Text(
                        'Skip',
                        style: TextStyle(
                          color: Colors.grey[600],
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  // Invisible placeholder to maintain layout when skip is hidden
                  if (!_shouldShowSkipButton())
                    SizedBox(width: 48),
                ],
              ),
            ),
            
            // Progress bar
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 20),
              child: LinearProgressIndicator(
                value: (_currentPage + 1) / _totalPages,
                backgroundColor: Colors.grey[300],
                valueColor: AlwaysStoppedAnimation<Color>(
                  Theme.of(context).primaryColor,
                ),
              ),
            ),
            
            // Page content
            Expanded(
              child: Listener(
                behavior: HitTestBehavior.translucent,
                onPointerDown: (_) {
                  if (!_isTouching) setState(() => _isTouching = true);
                },
                onPointerUp: (_) {
                  if (_isTouching) setState(() => _isTouching = false);
                },
                onPointerCancel: (_) {
                  if (_isTouching) setState(() => _isTouching = false);
                },
                child: OnboardingTouchingScope(
                  isTouching: _isTouching,
                  child: PageView(
                    controller: _pageController,
                    onPageChanged: _onPageChanged,
                    children: [
                      // Order (2026-09-17, revising decision D5): welcome →
                      // pick a chameleon + name → answer today's QOTD as a
                      // guest → passkey → location. Both the profile and the
                      // answer are staged locally until the passkey exists.
                      // The F-Droid consent slide keeps its existing position
                      // between auth and location.
                      WelcomeSlide(onNext: _nextPage),
                      ProfileSetupSlide(onNext: _nextPage),
                      QotdQuestionSlide(onNext: _nextPage),
                      AuthenticationSlide(onNext: _onPasskeyRegistered),
                      if (BuildConfig.isFDroidBuild)
                        AnalyticsConsentSlide(onNext: _nextPage),
                      LocationSetupSlide(
                        onComplete: _onAuthenticationCompleted,
                        triggeredFrom: widget.triggeredFrom,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}