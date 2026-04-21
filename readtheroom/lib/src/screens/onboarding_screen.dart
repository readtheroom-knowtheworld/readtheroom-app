// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../services/analytics_service.dart';
import '../services/user_service.dart';
import '../services/location_service.dart';
import '../widgets/onboarding/onboarding_slide.dart';
import '../widgets/onboarding/welcome_slide.dart';
import '../widgets/onboarding/anonymous_questions_slide.dart';
import '../widgets/onboarding/voting_slide.dart';
import '../widgets/onboarding/daily_question_slide.dart';
import '../widgets/onboarding/privacy_slide.dart';
import '../widgets/onboarding/analytics_consent_slide.dart';
import '../widgets/onboarding/authentication_slide.dart';
import '../config/build_config.dart';
import '../widgets/onboarding/community_guidelines_slide.dart';
import '../widgets/onboarding/location_setup_slide.dart';
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
  int get _totalPages => BuildConfig.isFDroidBuild ? 9 : 8;
  DateTime? _onboardingStartTime;
  bool _isTouching = false;

  @override
  void initState() {
    super.initState();
    _onboardingStartTime = DateTime.now();
    
    // Track onboarding started
    AnalyticsService().trackOnboardingStep('onboarding_started', 0, {
      'triggered_from': widget.triggeredFrom ?? 'unknown',
      'total_slides': _totalPages,
    });
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
    // Track skip event
    AnalyticsService().trackOnboardingStep('onboarding_skipped', _currentPage + 1, {
      'slides_viewed': _currentPage + 1,
      'total_slides': _totalPages,
      'triggered_from': widget.triggeredFrom ?? 'unknown',
    });
    
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

    // Track slide viewed
    AnalyticsService().trackOnboardingStep('onboarding_slide_viewed', page + 1, {
      'slide_number': page + 1,
      'total_slides': _totalPages,
      'triggered_from': widget.triggeredFrom ?? 'unknown',
    });
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
    
    AnalyticsService().trackOnboardingStep('onboarding_completed', _totalPages, {
      'time_spent_seconds': timeSpent,
      'triggered_from': widget.triggeredFrom ?? 'unknown',
    });
    
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
                      WelcomeSlide(onNext: _nextPage),
                      AnonymousQuestionsSlide(onNext: _nextPage),
                      VotingSlide(onNext: _nextPage),
                      DailyQuestionSlide(onNext: _nextPage),
                      PrivacySlide(onNext: _nextPage),
                      AuthenticationSlide(onNext: _nextPage),
                      CommunityGuidelinesSlide(onNext: _nextPage),
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