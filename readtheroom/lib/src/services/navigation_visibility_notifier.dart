// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

// lib/src/services/navigation_visibility_notifier.dart
import 'dart:async';
import 'package:flutter/material.dart';

/// Service to manage the visibility state of navigation bars (top app bar and bottom navigation)
/// based on scroll behavior in the home screen
class NavigationVisibilityNotifier extends ChangeNotifier {
  bool _isNavigationVisible = true;
  bool _isAtTop = true;
  double _lastScrollOffset = 0.0;
  bool _isScrollingDown = false;
  bool _isUserTouching = false; // Track if user is actively touching the screen
  Timer? _delayTimer; // Timer for 5-second delay before showing navigation
  
  // Getters
  bool get isNavigationVisible => _isNavigationVisible;
  bool get isAtTop => _isAtTop;
  bool get isScrollingDown => _isScrollingDown;
  bool get isUserTouching => _isUserTouching;
  
  // Constants for scroll behavior
  static const double _scrollThreshold = 8.0; // Increased threshold for more deliberate hiding
  static const double _topThreshold = 100.0; // Increased top threshold
  
  /// Update navigation visibility based on scroll position and direction
  void updateScrollPosition({
    required double currentOffset,
    required double maxScrollExtent,
    required bool isUserScrolling,
  }) {
    final bool wasAtTop = _isAtTop;
    final bool wasNavigationVisible = _isNavigationVisible;
    
    // Update "at top" status
    _isAtTop = currentOffset <= _topThreshold;
    
    // Calculate scroll direction
    final double scrollDelta = currentOffset - _lastScrollOffset;
    final bool isScrollingDown = scrollDelta > 0;
    final bool isScrollingUp = scrollDelta < 0;
    
    // Update scroll direction tracking
    _isScrollingDown = isScrollingDown;
    
    // Determine navigation visibility
    bool shouldShowNavigation = _isNavigationVisible;
    
    if (_isAtTop) {
      // Always show navigation when at top
      shouldShowNavigation = true;
      _cancelDelayTimer(); // Cancel any pending timer
    } else if (_isUserTouching) {
      // While user is actively touching
      if (isScrollingUp && scrollDelta.abs() > _scrollThreshold) {
        // Show navigation immediately on upward scroll
        shouldShowNavigation = true;
        _cancelDelayTimer(); // Cancel any pending timer
      } else if (isScrollingDown && scrollDelta.abs() > _scrollThreshold) {
        // Hide navigation on significant downward scroll
        shouldShowNavigation = false;
        _cancelDelayTimer(); // Cancel any pending timer
      }
      // Keep current state for small movements
    } else {
      // User has released touch - start 3-second delay before showing navigation
      // But only if navigation is currently hidden and we're not at top
      if (!_isNavigationVisible && !_isAtTop) {
        _startDelayTimer();
        // Don't change shouldShowNavigation yet, wait for timer
      } else if (_isNavigationVisible) {
        // Navigation is already visible, keep it that way
        shouldShowNavigation = true;
      }
    }
    
    // Update state and notify listeners if anything changed
    if (shouldShowNavigation != _isNavigationVisible) {
      _isNavigationVisible = shouldShowNavigation;
    }
    _lastScrollOffset = currentOffset;
    
    // Only notify if there was an actual change
    if (wasAtTop != _isAtTop || wasNavigationVisible != _isNavigationVisible) {
      print('Navigation visibility: visible=$_isNavigationVisible, atTop=$_isAtTop, scrollingDown=$_isScrollingDown, touching=$_isUserTouching');
      notifyListeners();
    }
  }
  
  /// Update whether user is actively touching the screen
  void setUserTouching(bool isTouching) {
    if (_isUserTouching != isTouching) {
      _isUserTouching = isTouching;
      print('User touch state changed: touching=$isTouching');
      
      // If user released touch, show navigation after a brief delay
      if (!isTouching && !_isAtTop) {
        // Navigation will be shown on next scroll position update
      }
    }
  }
  
  /// Force navigation to be visible (e.g., when switching tabs, refreshing)
  void showNavigation({String? reason}) {
    if (!_isNavigationVisible) {
      _isNavigationVisible = true;
      print('Navigation forced visible: ${reason ?? 'manual'}');
      notifyListeners();
    }
  }
  
  /// Reset state (e.g., when returning to home screen)
  void reset() {
    final bool hadChanges = !_isNavigationVisible || !_isAtTop;
    
    _cancelDelayTimer();
    _isNavigationVisible = true;
    _isAtTop = true;
    _lastScrollOffset = 0.0;
    _isScrollingDown = false;
    
    if (hadChanges) {
      print('Navigation visibility reset');
      notifyListeners();
    }
  }

  /// Start the 3-second delay timer
  void _startDelayTimer() {
    _cancelDelayTimer(); // Cancel any existing timer
    
    _delayTimer = Timer(Duration(seconds: 3), () {
      if (!_isNavigationVisible && !_isAtTop) {
        _isNavigationVisible = true;
        print('Navigation visibility: shown after 3-second delay');
        notifyListeners();
      }
    });
    
    print('Navigation visibility: started 3-second delay timer');
  }

  /// Cancel the delay timer
  void _cancelDelayTimer() {
    if (_delayTimer != null) {
      _delayTimer!.cancel();
      _delayTimer = null;
      print('Navigation visibility: cancelled delay timer');
    }
  }

  @override
  void dispose() {
    _cancelDelayTimer();
    super.dispose();
  }
}