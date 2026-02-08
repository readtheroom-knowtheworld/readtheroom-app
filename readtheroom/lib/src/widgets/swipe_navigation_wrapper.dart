// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../utils/haptic_utils.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../services/question_service.dart';
import '../services/user_service.dart';
import '../services/question_cache_service.dart';
import '../screens/answer_approval_screen.dart';
import '../screens/answer_multiple_choice_screen.dart';
import '../screens/answer_text_screen.dart';
import '../screens/approval_results_screen.dart';
import '../screens/multiple_choice_results_screen.dart';
import '../screens/text_results_screen.dart';
import '../screens/main_screen.dart';

class SwipeNavigationWrapper extends StatefulWidget {
  final Widget child;
  final FeedContext? feedContext;
  final Map<String, dynamic>? currentQuestion;
  final bool enableRightSwipe;
  final bool enableLeftSwipe;
  final bool enableBackButtonIntercept;
  final bool enablePullToGoBack;
  final bool fromSearch;
  final bool fromUserScreen;
  
  const SwipeNavigationWrapper({
    Key? key,
    required this.child,
    this.feedContext,
    this.currentQuestion,
    this.enableRightSwipe = true,
    this.enableLeftSwipe = true,
    this.enableBackButtonIntercept = true,
    this.enablePullToGoBack = true,
    this.fromSearch = false,
    this.fromUserScreen = false,
  }) : super(key: key);

  @override
  SwipeNavigationWrapperState createState() => SwipeNavigationWrapperState();
}

class SwipeNavigationWrapperState extends State<SwipeNavigationWrapper> {
  Offset? _dragStartPosition;
  bool _isPullDownTriggered = false;
  DateTime? _pullDownStartTime;
  final QuestionCacheService _cacheService = QuestionCacheService();

  @override
  void initState() {
    super.initState();
    _initializeCacheAndPrefetch();
  }

  @override
  void dispose() {
    _isPullDownTriggered = false;
    _pullDownStartTime = null;
    super.dispose();
  }

  // Initialize cache service and start prefetching
  void _initializeCacheAndPrefetch() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final questionService = Provider.of<QuestionService>(context, listen: false);
      _cacheService.initialize(questionService);
      
      // Start prefetching next questions
      _prefetchNextQuestions();
    });
  }

  // Prefetch next 3 questions for faster navigation
  void _prefetchNextQuestions() {
    if (widget.feedContext == null || widget.currentQuestion == null) return;
    
    final currentQuestionId = widget.currentQuestion!['id']?.toString();
    if (currentQuestionId == null) return;
    
    final questions = widget.feedContext!.questions;
    final currentIndex = questions.indexWhere((q) => q['id']?.toString() == currentQuestionId);
    
    if (currentIndex >= 0) {
      final nextIds = _cacheService.getNextQuestionIds(questions, currentIndex, count: 3);
      if (nextIds.isNotEmpty) {
        print('🚀 Prefetching next ${nextIds.length} questions for faster navigation');
        _cacheService.prefetchQuestions(nextIds);
      }
    }
  }

  // Helper method to navigate to appropriate screen based on whether question is answered
  Widget _buildQuestionScreen(Map<String, dynamic> question, FeedContext updatedFeedContext, UserService userService) {
    final questionType = question['type']?.toString().toLowerCase() ?? 'text';
    final isAnswered = userService.hasAnsweredQuestion(question['id']);
    
    if (isAnswered) {
      // For results screens, we need to fetch complete question data first
      print('🔍 Building results screen for question: ${question['id']} (type: ${question['type']})');
      return FutureBuilder<Map<String, dynamic>?>(
        future: _fetchCompleteQuestionData(question['id'].toString()),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return Scaffold(
              appBar: AppBar(title: Text('Loading...')),
              body: Center(child: CircularProgressIndicator()),
            );
          }
          
          // Fall back to original if fetch fails, but try to preserve/merge important fields
          Map<String, dynamic> completeQuestion;
          if (snapshot.data != null) {
            completeQuestion = snapshot.data!;
            // If the fetched data is missing question_options but the original has them, preserve them
            if (!completeQuestion.containsKey('question_options') && question.containsKey('question_options')) {
              print('⚠️ Database query missing question_options, preserving from original data');
              completeQuestion['question_options'] = question['question_options'];
            }
            // Also preserve options field if it exists
            if (!completeQuestion.containsKey('options') && question.containsKey('options')) {
              print('⚠️ Database query missing options field, preserving from original data');
              completeQuestion['options'] = question['options'];
            }
          } else {
            completeQuestion = question; // Complete fallback to original
            print('⚠️ Database fetch failed, using original question data');
          }
          
                     // Navigate to results screen with complete question data and preloaded responses
           final preloadedResponses = completeQuestion['preloaded_responses'] as List<Map<String, dynamic>>? ?? [];
           print('🎯 Using ${preloadedResponses.length} preloaded responses for ${questionType} question');
           
           if (questionType == 'approval_rating' || questionType == 'approval') {
             return ApprovalResultsScreen(
               question: completeQuestion,
               responses: preloadedResponses, // Use preloaded responses for instant display
               feedContext: updatedFeedContext,
               fromSearch: widget.fromSearch,
               fromUserScreen: widget.fromUserScreen,
             );
           } else if (questionType == 'multiple_choice') {
             return MultipleChoiceResultsScreen(
               question: completeQuestion,
               responses: preloadedResponses, // Use preloaded responses for instant display
               feedContext: updatedFeedContext,
               fromSearch: widget.fromSearch,
               fromUserScreen: widget.fromUserScreen,
             );
           } else {
             // For text results, we need to handle the special case where responses are stored differently
             // Remove preloaded_responses from question and pass separately since TextResultsScreen loads its own
             final questionForTextResults = Map<String, dynamic>.from(completeQuestion);
             if (preloadedResponses.isNotEmpty) {
               questionForTextResults['preloaded_text_responses'] = preloadedResponses;
             }
             questionForTextResults.remove('preloaded_responses'); // Clean up
             
             return TextResultsScreen(
               question: questionForTextResults,
               feedContext: updatedFeedContext,
               fromSearch: widget.fromSearch,
               fromUserScreen: widget.fromUserScreen,
             );
           }
        },
      );
    } else {
      // For answer screens, we can use the question data as-is since they don't need to fetch responses
      if (questionType == 'approval_rating' || questionType == 'approval') {
        return AnswerApprovalScreen(
          question: question,
          feedContext: updatedFeedContext,
          fromSearch: widget.fromSearch,
          fromUserScreen: widget.fromUserScreen,
        );
      } else if (questionType == 'multiple_choice') {
        return AnswerMultipleChoiceScreen(
          question: question,
          feedContext: updatedFeedContext,
          fromSearch: widget.fromSearch,
          fromUserScreen: widget.fromUserScreen,
        );
      } else {
        return AnswerTextScreen(
          question: question,
          feedContext: updatedFeedContext,
          fromSearch: widget.fromSearch,
          fromUserScreen: widget.fromUserScreen,
        );
      }
    }
  }

  // Helper method to fetch complete question data and responses (with caching)
  Future<Map<String, dynamic>?> _fetchCompleteQuestionData(String questionId) async {
    try {
      // Check cache first for instant response
      final cachedQuestion = _cacheService.getCachedQuestionWithResponses(questionId);
      if (cachedQuestion != null) {
        print('⚡ Using cached data for question ${questionId.substring(0, 8)}... (instant)');
        _continuePrefetching(); // Continue prefetching in background
        return cachedQuestion;
      }
      
      print('📡 Cache miss - fetching question ${questionId.substring(0, 8)}... from database');
      
      // Fallback to database with original logic
      final questionService = Provider.of<QuestionService>(context, listen: false);
      final completeQuestion = await questionService.getQuestionById(questionId);
      
      if (completeQuestion != null) {
        print('📋 Fetched complete question data for ID $questionId:');
        print('   - Type: ${completeQuestion['type']}');
        print('   - Title: ${completeQuestion['prompt'] ?? completeQuestion['title']}');
        print('   - Has question_options: ${completeQuestion.containsKey('question_options')}');
        if (completeQuestion.containsKey('question_options')) {
          final options = completeQuestion['question_options'] as List<dynamic>?;
          print('   - Options count: ${options?.length ?? 0}');
          if (options != null && options.isNotEmpty) {
            print('   - Options: ${options.map((o) => o['option_text']).join(', ')}');
          }
        }
        
        // Pre-fetch responses for answered questions to avoid loading delay
        final userService = Provider.of<UserService>(context, listen: false);
        if (userService.hasAnsweredQuestion(completeQuestion['id'])) {
          print('🚀 Pre-fetching responses for answered question...');
          final responses = await _fetchResponsesForQuestion(completeQuestion);
          if (responses != null) {
            completeQuestion['preloaded_responses'] = responses;
            print('✅ Pre-loaded ${responses.length} responses');
          }
        }
        
        _continuePrefetching(); // Continue prefetching in background
      } else {
        print('❌ Failed to fetch complete question data for ID $questionId');
      }
      
      return completeQuestion;
    } catch (e) {
      print('Error fetching complete question data: $e');
      return null;
    }
  }

  // Continue prefetching after navigation
  void _continuePrefetching() {
    if (widget.feedContext == null) return;
    
    final questions = widget.feedContext!.questions;
    final currentIndex = widget.feedContext!.currentQuestionIndex;
    
    // Prefetch next 3 questions
    final nextIds = _cacheService.getNextQuestionIds(questions, currentIndex, count: 3);
    if (nextIds.isNotEmpty) {
      _cacheService.prefetchQuestions(nextIds);
    }
  }

  // Helper method to fetch responses based on question type
  Future<List<Map<String, dynamic>>?> _fetchResponsesForQuestion(Map<String, dynamic> question) async {
    try {
      final questionId = question['id'].toString();
      final questionType = question['type']?.toString().toLowerCase() ?? 'text';
      final supabase = Supabase.instance.client;
      
      switch (questionType) {
        case 'multiple_choice':
          // Use the existing method from QuestionService
          final questionService = Provider.of<QuestionService>(context, listen: false);
          return await questionService.getMultipleChoiceIndividualResponses(questionId);
          
        case 'approval_rating':
        case 'approval':
          // Fetch approval responses (same query as ApprovalResultsScreen)
          final response = await supabase
              .from('responses')
              .select('''
                score,
                created_at,
                countries!responses_country_code_fkey(country_name_en)
              ''')
              .eq('question_id', questionId)
              .not('score', 'is', null)
              .order('created_at', ascending: false);
          
          if (response != null && response.isNotEmpty) {
            return response.map((r) => {
              'country': r['countries']?['country_name_en'] ?? 'Unknown',
              'answer': (r['score'] as int).toDouble() / 100.0, // Convert to -1 to 1 range
              'created_at': r['created_at'],
            }).toList();
          }
          return [];
          
        case 'text':
        default:
          // Fetch text responses (same query as TextResultsScreen)
          final response = await supabase
              .from('responses')
              .select('''
                text_response, 
                created_at,
                countries!responses_country_code_fkey(country_name_en)
              ''')
              .eq('question_id', questionId)
              .not('text_response', 'is', null)
              .order('created_at', ascending: false);
          
          if (response != null && response.isNotEmpty) {
            return response.map((r) => {
              'text_response': r['text_response'],
              'country': r['countries']?['country_name_en'] ?? 'Unknown',
              'created_at': r['created_at'],
            }).toList();
          }
          return [];
      }
    } catch (e) {
      print('Error fetching responses for question: $e');
      return null;
    }
  }

  Future<void> _handleSwipeLeft(BuildContext context) async {
    if (widget.feedContext == null) return;

    // Reset pull-down state when navigating
    _isPullDownTriggered = false;
    _pullDownStartTime = null;

    final userService = Provider.of<UserService>(context, listen: false);

    // Use different navigation methods based on feed type
    final nextQuestion = (widget.fromSearch || widget.fromUserScreen)
        ? widget.feedContext!.getNextQuestionInSearchFeed(userService)
        : widget.feedContext!.getNextQuestion(userService);
    
    if (nextQuestion != null) {
      // Navigate to the next question's answer screen with right-to-left slide (forward motion)
      Navigator.pushReplacement(
        context,
        PageRouteBuilder(
          pageBuilder: (context, animation, secondaryAnimation) {
            // Create updated feed context for the next question
            final nextQuestionIndex = widget.feedContext!.questions.indexOf(nextQuestion);
            final updatedFeedContext = FeedContext(
              feedType: widget.feedContext!.feedType,
              filters: widget.feedContext!.filters,
              questions: widget.feedContext!.questions,
              currentQuestionIndex: nextQuestionIndex,
              originalQuestionId: widget.feedContext!.originalQuestionId, // Preserve original question ID
              originalQuestionIndex: widget.feedContext!.originalQuestionIndex, // Preserve original starting boundary
            );
            
            // Navigate to appropriate screen (answer or results) based on question type and answered status
            return _buildQuestionScreen(nextQuestion, updatedFeedContext, userService);
          },
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            // Slide from right to left (swipe left = next question, forward motion)
            const begin = Offset(1.0, 0.0);
            const end = Offset.zero;
            const curve = Curves.ease;
            
            var tween = Tween(begin: begin, end: end).chain(CurveTween(curve: curve));
            
            return SlideTransition(
              position: animation.drive(tween),
              child: child,
            );
          },
        ),
      );
    } else {
      // No more questions
      if (widget.fromSearch) {
        // For search results, go back to search
        print('🔍 No more search results - going back to search');
        Navigator.of(context).pop();
      } else if (widget.fromUserScreen) {
        // For user screen results, go back to user screen
        print('👤 No more user questions - going back to user screen');
        Navigator.of(context).pop();
      } else {
        // For home feed, return to home with nice message
        Navigator.popUntil(context, (route) => route.isFirst);
        
        // Show thank you message
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                SizedBox(width: 8),
                Text("That's all, for now..."),
              ],
            ),
            backgroundColor: Theme.of(context).primaryColor,
            duration: Duration(seconds: 4),
          ),
        );
      }
    }
  }

  Future<void> _handleSwipeRight(BuildContext context) async {
    if (!widget.enableRightSwipe || widget.feedContext == null) return;

    // Reset pull-down state when navigating
    _isPullDownTriggered = false;
    _pullDownStartTime = null;

    final userService = Provider.of<UserService>(context, listen: false);

    // Check if user is at their original starting question
    if (widget.feedContext!.isAtOriginalStartingQuestion()) {
      if (widget.fromSearch) {
        // For search results, go back to search
        print('🔍 At original search question - going back to search');
        Navigator.of(context).pop();
      } else if (widget.fromUserScreen) {
        // For user screen results, go back to user screen
        print('👤 At original user question - going back to user screen');
        Navigator.of(context).pop();
      } else {
        // For home feed, go home with clean feed view
        _handleReturnToFeedClean(context);
      }
      return;
    }

    // Use different navigation methods based on feed type
    final previousQuestion = (widget.fromSearch || widget.fromUserScreen)
        ? widget.feedContext!.getPreviousQuestionInSearchFeed(userService)
        : widget.feedContext!.getPreviousQuestion(userService);
    
    if (previousQuestion != null) {
      // Navigate to the previous question's answer screen with left-to-right slide (backward motion)
      Navigator.pushReplacement(
        context,
        PageRouteBuilder(
          pageBuilder: (context, animation, secondaryAnimation) {
            // Create updated feed context for the previous question
            final previousQuestionIndex = widget.feedContext!.questions.indexOf(previousQuestion);
            final updatedFeedContext = FeedContext(
              feedType: widget.feedContext!.feedType,
              filters: widget.feedContext!.filters,
              questions: widget.feedContext!.questions,
              currentQuestionIndex: previousQuestionIndex,
              originalQuestionId: widget.feedContext!.originalQuestionId, // Preserve original question ID
              originalQuestionIndex: widget.feedContext!.originalQuestionIndex, // Preserve original starting boundary
            );
            
            // Navigate to appropriate screen (answer or results) based on question type and answered status
            return _buildQuestionScreen(previousQuestion, updatedFeedContext, userService);
          },
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            // Slide from left to right (swipe right = previous question, backward motion)
            const begin = Offset(-1.0, 0.0);
            const end = Offset.zero;
            const curve = Curves.ease;
            
            var tween = Tween(begin: begin, end: end).chain(CurveTween(curve: curve));
            
            return SlideTransition(
              position: animation.drive(tween),
              child: child,
            );
          },
        ),
      );
    } else {
      // No more previous questions within boundary
      if (widget.fromSearch) {
        // For search results, go back to search
        print('🔍 No more previous search results - going back to search');
        Navigator.of(context).pop();
      } else if (widget.fromUserScreen) {
        // For user screen results, go back to user screen
        print('👤 No more previous user questions - going back to user screen');
        Navigator.of(context).pop();
      } else {
        // For home feed, return to home with clean feed view
        _handleReturnToFeedClean(context);
      }
    }
  }

  void _handlePullDown(BuildContext context) {
    if (!widget.enablePullToGoBack) return;
    
    // Reset pull-down state
    _isPullDownTriggered = false;
    _pullDownStartTime = null;
    
    // Check if this question came from search - go back to search
    if (widget.fromSearch) {
      Navigator.of(context).pop();
      return;
    }
    
    // Check if this question came from user screen - go back to user screen
    if (widget.fromUserScreen) {
      Navigator.of(context).pop();
      return;
    }
    
    _handleReturnToFeed(context);
  }

  void _handleReturnToFeed(BuildContext context) {
    _handleReturnToFeedWithAnimation(context, restoreScrollPosition: true);
  }

  void _navigateToHome(BuildContext context) {
    print('SwipeNavigationWrapper: Navigating to home');
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => MainScreen()),
      (route) => false,
    );
  }

  void _handleReturnToFeedClean(BuildContext context) {
    _handleReturnToFeedWithAnimation(context, restoreScrollPosition: false);
  }

  void _handleReturnToFeedWithAnimation(BuildContext context, {bool restoreScrollPosition = true}) {
    // Simple scroll restoration - just remember where the user started
    Map<String, dynamic>? scrollInfo;
    
    if (restoreScrollPosition && widget.feedContext != null && widget.currentQuestion != null) {
      // Use the original question ID from feedContext for position storage lookup
      final originalId = widget.feedContext!.originalQuestionId ?? widget.currentQuestion!['id'];
      
      scrollInfo = {
        'type': 'scroll_to_question',
        'question_id': originalId, // For looking up stored scroll position
      };
    }
    
    // Use popUntil to avoid reloading home screen, even though animation may be inconsistent
    // This prioritizes performance over perfect animation direction
    Navigator.of(context).popUntil((route) => route.isFirst);
    
    // Use event system to communicate scroll position to home screen
    if (scrollInfo != null) {
      ScrollPositionEvent.notifyScrollRequest(scrollInfo);
    }
  }



  @override
  Widget build(BuildContext context) {
    // If no feedContext (e.g. deep link), add basic gesture handling to go home
    if (widget.feedContext == null) {
      return NotificationListener<ScrollNotification>(
        onNotification: (notification) {
          // Handle pull-to-go-back via scroll over-extension
          if (notification is ScrollUpdateNotification) {
            if (notification.metrics.pixels < 0) {
              final overscrollAmount = notification.metrics.pixels.abs();

              if (overscrollAmount > 80 && _pullDownStartTime == null) {
                _pullDownStartTime = DateTime.now();
              }

              if (overscrollAmount > 120 && _pullDownStartTime != null && !_isPullDownTriggered) {
                final holdDuration = DateTime.now().difference(_pullDownStartTime!);

                if (holdDuration.inMilliseconds > 300) {
                  _isPullDownTriggered = true;
                  print('Deep link screen: Pull-down triggered - going home');
                  AppHaptics.mediumImpact();
                  _navigateToHome(context);
                  return true;
                }
              }
            } else {
              _pullDownStartTime = null;
            }
          }
          return false;
        },
        child: Stack(
          children: [
            widget.child,
            // Invisible gesture detector on left edge for back swipe (below app bar)
            Positioned(
              left: 0,
              top: MediaQuery.of(context).padding.top + kToolbarHeight,
              bottom: 0,
              width: 40,
              child: GestureDetector(
                onHorizontalDragStart: (details) {
                  print('Deep link screen: Edge drag started at ${details.globalPosition}');
                  _dragStartPosition = details.globalPosition;
                },
                onHorizontalDragUpdate: (details) {
                  // Optional: could add visual feedback here
                },
                onHorizontalDragEnd: (details) {
                  print('Deep link screen: Edge drag ended, velocity: ${details.velocity.pixelsPerSecond.dx}');
                  if (details.velocity.pixelsPerSecond.dx > 100) {
                    print('Deep link screen: Edge swipe detected - going home');
                    _navigateToHome(context);
                  }
                },
                behavior: HitTestBehavior.translucent,
                child: Container(color: Colors.transparent),
              ),
            ),
          ],
        ),
      );
    }

    Widget wrappedChild = NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        // Handle pull-to-go-back via scroll over-extension
        if (widget.enablePullToGoBack) {
          if (notification is ScrollUpdateNotification) {
            // Check if user is trying to scroll past the top (negative pixels)
            if (notification.metrics.pixels < 0) {
              final overscrollAmount = notification.metrics.pixels.abs();

              // Start timing when significant overscroll begins
              if (overscrollAmount > 80 && _pullDownStartTime == null) {
                _pullDownStartTime = DateTime.now();
              }

              // If deep overscroll maintained for enough time, go home immediately
              if (overscrollAmount > 120 && _pullDownStartTime != null && !_isPullDownTriggered) {
                final holdDuration = DateTime.now().difference(_pullDownStartTime!);

                // Must hold overscroll for at least 300ms to prevent accidents
                if (holdDuration.inMilliseconds > 300) {
                  _isPullDownTriggered = true;

                  print('🎯 Pull-down triggered - going home after ${holdDuration.inMilliseconds}ms hold');

                  // Add haptic feedback and go home immediately
                  AppHaptics.mediumImpact();
                  _handlePullDown(context);
                  return true;
                }
              }
            } else {
              // Reset timing if user stops overscrolling
              _pullDownStartTime = null;
            }
          }
        }
        return false;
      },
      child: GestureDetector(
        onPanStart: (details) {
          // Store the starting position for validation in onPanEnd
          _dragStartPosition = details.globalPosition;
        },
        onPanEnd: (details) {
          if (_dragStartPosition == null) return;

          // Get screen dimensions
          final screenWidth = MediaQuery.of(context).size.width;
          final screenHeight = MediaQuery.of(context).size.height;

          final startX = _dragStartPosition!.dx;
          final startY = _dragStartPosition!.dy;

          // Get velocity components
          final horizontalVelocity = details.velocity.pixelsPerSecond.dx;
          final verticalVelocity = details.velocity.pixelsPerSecond.dy;

          // For search/user-originated questions, be more lenient with gesture detection
          if (widget.fromSearch || widget.fromUserScreen) {
            // For search/user questions, allow swipes from anywhere on screen with lower velocity threshold
            final isHorizontalGesture = horizontalVelocity.abs() > 150; // Lower threshold

            if (isHorizontalGesture) {
              if (horizontalVelocity < -150) { // Left swipe
                _handleSwipeLeft(context);
              } else if (horizontalVelocity > 150) { // Right swipe
                _handleSwipeRight(context);
              }
            }
            return;
          }

          // Regular feed navigation - use strict constraints
          // Check for horizontal swipe gestures (center area only)
          final edgeThreshold = screenWidth * 0.15; // 15% from each edge
          final topBottomThreshold = screenHeight * 0.1; // 10% from top/bottom

          final isInCenterArea = startX > edgeThreshold &&
                                startX < (screenWidth - edgeThreshold) &&
                                startY > topBottomThreshold &&
                                startY < (screenHeight - topBottomThreshold);

          // Handle horizontal swipes (left/right navigation)
          if (isInCenterArea) {
            // Determine if this is primarily a horizontal gesture
            final isHorizontalGesture = horizontalVelocity.abs() > verticalVelocity.abs();

            if (isHorizontalGesture) {
              if (widget.enableLeftSwipe && horizontalVelocity < -300) {
                _handleSwipeLeft(context);
              } else if (widget.enableRightSwipe && horizontalVelocity > 300) {
                _handleSwipeRight(context);
              }
            }
          }
        },
        child: widget.child,
      ),
    );

    // Wrap with PopScope to intercept back button if enabled and feedContext is available
    // But skip PopScope entirely for search/user questions to avoid interference
    if (widget.enableBackButtonIntercept && !widget.fromSearch && !widget.fromUserScreen) {
      wrappedChild = PopScope(
        canPop: false, // Intercept for feed questions only
        onPopInvokedWithResult: (didPop, result) {
          if (!didPop) {
            _handleReturnToFeed(context);
          }
        },
        child: wrappedChild,
      );
    }

    // Add left edge gesture detector for going home on all screens (below app bar)
    return Stack(
      children: [
        wrappedChild,
        // Invisible gesture detector on left edge for home swipe (below app bar)
        Positioned(
          left: 0,
          top: MediaQuery.of(context).padding.top + kToolbarHeight,
          bottom: 0,
          width: 40,
          child: GestureDetector(
            onHorizontalDragEnd: (details) {
              if (details.velocity.pixelsPerSecond.dx > 100) {
                _navigateToHome(context);
              }
            },
            behavior: HitTestBehavior.translucent,
            child: Container(color: Colors.transparent),
          ),
        ),
      ],
    );
  }
}