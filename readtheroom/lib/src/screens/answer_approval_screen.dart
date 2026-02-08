// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../services/location_service.dart';
import '../services/question_service.dart';
import '../services/guest_user_tracking_service.dart';
import '../services/watchlist_service.dart';
import '../services/notification_service.dart';
import '../services/user_service.dart';
import '../services/deep_link_service.dart';
import 'approval_results_screen.dart';
import '../utils/time_utils.dart';
import '../utils/haptic_utils.dart';
import '../services/user_service.dart';
import 'report_question_screen.dart';
import '../widgets/authentication_dialog.dart';
import '../widgets/question_activity_permission_dialog.dart';
import 'package:share_plus/share_plus.dart';
import '../widgets/question_type_badge.dart';
import '../models/category.dart';
import '../widgets/swipe_navigation_wrapper.dart';
import '../utils/category_navigation.dart';
import '../widgets/animated_submit_button.dart';
import 'main_screen.dart';

class AnswerApprovalScreen extends StatefulWidget {
  final Map<String, dynamic> question;
  final FeedContext? feedContext;
  final bool fromSearch;
  final bool fromUserScreen;

  const AnswerApprovalScreen({
    Key? key,
    required this.question,
    this.feedContext,
    this.fromSearch = false,
    this.fromUserScreen = false,
  }) : super(key: key);

  @override
  _AnswerApprovalScreenState createState() => _AnswerApprovalScreenState();
}

class _AnswerApprovalScreenState extends State<AnswerApprovalScreen> {
  double _sliderValue = 0.0;
  bool _isSubmitting = false;
  bool _wasViewedAsGuest = false;
  final ScrollController _scrollController = ScrollController();
  bool _showQuestionInTitle = false;
  int _lastHapticZone = 0; // 0 = neutral, 1 = single thumbs, 2 = double thumbs

  @override
  void initState() {
    super.initState();
    _setupScrollListener();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
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
    if (_showQuestionInTitle) {
      final prompt = widget.question['prompt'] ?? widget.question['title'] ?? 'Read the Room';
      return prompt.length > 35 ? '${prompt.substring(0, 32)}...' : prompt;
    }
    return 'Read the Room';
  }

  // Dummy responses for demonstration. In a real app, these would come from your API.
  final List<Map<String, dynamic>> _dummyResponses = [
    {'answer': -1.0, 'country': 'United States'},  // Strongly Disapprove
    {'answer': -0.8, 'country': 'Canada'},         // Strongly Disapprove
    {'answer': -0.5, 'country': 'United Kingdom'}, // Disapprove
    {'answer': -0.3, 'country': 'Australia'},      // Disapprove
    {'answer': -0.2, 'country': 'Germany'},        // Neutral
    {'answer': 0.0, 'country': 'France'},          // Neutral
    {'answer': 0.2, 'country': 'Japan'},           // Neutral
    {'answer': 0.3, 'country': 'Brazil'},          // Approve
    {'answer': 0.5, 'country': 'India'},           // Approve
    {'answer': 0.8, 'country': 'South Africa'},    // Strongly Approve
    {'answer': 0.9, 'country': 'Mexico'},          // Strongly Approve
    {'answer': 1.0, 'country': 'China'},           // Strongly Approve
  ];

  int _getCommentCount(Map<String, dynamic> question) {
    return question['comment_count'] as int? ?? 0;
  }

  Widget _getIconForValue(double value) {
    if (value <= -0.8) {
      // Strongly Disapprove - double thumbs down (red)
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.thumb_down, color: Colors.red, size: 24),
          SizedBox(width: 2),
          Icon(Icons.thumb_down, color: Colors.red, size: 24),
        ],
      );
    } else if (value <= -0.3) {
      // Disapprove - single thumbs down (light red)
      return Icon(Icons.thumb_down, color: Colors.red[200], size: 24);
    } else if (value <= 0.3) {
      // Neutral - neutral face (grey)
      return Icon(Icons.sentiment_neutral, color: Colors.grey[600], size: 24);
    } else if (value <= 0.8) {
      // Approve - single thumbs up (light green)
      return Icon(Icons.thumb_up, color: Colors.green[200], size: 24);
    } else {
      // Strongly Approve - double thumbs up (green)
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.thumb_up, color: Colors.green, size: 24),
          SizedBox(width: 2),
          Icon(Icons.thumb_up, color: Colors.green, size: 24),
        ],
      );
    }
  }

  Color _getColorForValue(double value) {
    if (value < 0) {
      return Colors.red.withOpacity(value.abs());
    } else {
      return Colors.green.withOpacity(value);
    }
  }

  Widget _buildSliderWithBinMarkers() {
    // Bin edge positions (same as in approval_results_screen.dart)
    final binEdges = [-0.8, -0.3, 0.3, 0.8];
    
    return Column(
      children: [
        // Bin markers above the slider
        LayoutBuilder(
          builder: (context, constraints) {
            final sliderWidth = constraints.maxWidth - 48; // Account for slider padding
            
            return Container(
              height: 12,
              child: Stack(
                children: [
                  // Draw tick marks for each bin edge
                  ...binEdges.map((edge) {
                    // Convert slider value (-1 to 1) to position (0 to 1)
                    final position = (edge + 1.0) / 2.0;
                    final leftOffset = 24 + (position * sliderWidth); // 24 is half of slider padding
                    
                    return Positioned(
                      left: leftOffset - 1, // Center the 2px line
                      child: Container(
                        width: 2,
                        height: 12,
                        decoration: BoxDecoration(
                          color: Colors.grey[600],
                          borderRadius: BorderRadius.circular(1),
                        ),
                      ),
                    );
                  }).toList(),
                ],
              ),
            );
          },
        ),
        
        // The actual slider
        Slider(
          value: _sliderValue,
          min: -1.0,
          max: 1.0,
          divisions: 100,
          onChanged: (value) {
            final distanceFromCenter = value.abs();

            // Determine current zone: 0 = neutral, 1 = single thumbs, 2 = double thumbs
            int currentZone;
            if (distanceFromCenter >= 0.8) {
              currentZone = 2; // Double thumbs
            } else if (distanceFromCenter >= 0.3) {
              currentZone = 1; // Single thumbs
            } else {
              currentZone = 0; // Neutral
            }

            // Trigger haptic only when entering a new zone (away from center)
            if (currentZone > _lastHapticZone) {
              if (currentZone == 2) {
                AppHaptics.mediumImpact();
              } else if (currentZone == 1) {
                AppHaptics.lightImpact();
              }
            }
            _lastHapticZone = currentZone;

            setState(() {
              _sliderValue = value;
            });
          },
        ),
        
        // Current selection icon
        SizedBox(height: 12),
        _getIconForValue(_sliderValue),
      ],
    );
  }

  Future<void> _submitAnswer() async {
    // Check if this question was viewed as a guest
    final guestTrackingService = Provider.of<GuestUserTrackingService>(context, listen: false);
    final questionId = widget.question['id']?.toString();
    
    if (questionId != null && guestTrackingService.wasViewedAsGuest(questionId)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('You cannot vote on questions you viewed as a guest'),
          backgroundColor: Colors.orange,
          duration: Duration(seconds: 3),
        ),
      );
      return;
    }
    
    // Check if user is authenticated and has city set before submission
    final supabase = Supabase.instance.client;
    final locationService = Provider.of<LocationService>(context, listen: false);
    
    // Ensure LocationService is initialized
    if (!locationService.isInitialized) {
      print('DEBUG: LocationService not initialized in answer_approval_screen _submitAnswer, initializing now...');
      await locationService.initialize();
      print('DEBUG: LocationService initialized, selectedCity: ${locationService.selectedCity}');
    }
    
    final isAuthenticated = supabase.auth.currentUser != null;
    final hasCity = locationService.selectedCity != null;
    
    print('DEBUG: answer_approval_screen checks - isAuthenticated: $isAuthenticated, hasCity: $hasCity, selectedCity: ${locationService.selectedCity}');
    
    if (!isAuthenticated || !hasCity) {
      // Show authentication dialog
      await AuthenticationDialog.show(
        context,
        customMessage: 'To submit your response, you need to authenticate as a real person and set your city.',
        onComplete: () {
          // Retry submission after authentication
          _submitAnswer();
        },
      );
      return;
    }

    setState(() {
      _isSubmitting = true;
    });

    try {
      // Create a properly typed copy of the question for user service
      final answeredQuestion = <String, dynamic>{
        'id': widget.question['id'].toString(),
        'prompt': widget.question['prompt']?.toString() ?? widget.question['title']?.toString() ?? 'Unknown question',
        'type': widget.question['type']?.toString() ?? 'approval_rating',
        'timestamp': DateTime.now().toIso8601String(),
        'votes': widget.question['votes'] ?? 0
      };

      // Get the question service
      final questionService = Provider.of<QuestionService>(context, listen: false);

      // Get country code for API submission
      final countryCode = locationService.userLocation?['country_code'] ?? 'US';

      // Run API call in PARALLEL with minimum animation duration (3 seconds)
      // This ensures the animation plays smoothly while work happens in background
      final submitFuture = questionService.submitApprovalResponse(
        widget.question['id'].toString(),
        _sliderValue,
        countryCode,
        locationService: locationService,
      );
      final minAnimationFuture = Future.delayed(const Duration(seconds: 2));

      // Wait for both: API must succeed AND animation must complete
      final results = await Future.wait([
        submitFuture,
        minAnimationFuture.then((_) => true),
      ]);

      final submitted = results[0];
      
      if (!submitted) {
        print('ERROR: Failed to submit response to database');
        if (mounted) {
          if (locationService.selectedCity == null) {
            showDialog(
              context: context,
              builder: (context) => AlertDialog(
                title: Text('City Selection Required'),
                content: Text(
                  'To submit responses, please select your city in the "My Stuff" section. '
                  'This helps us provide location-based insights while keeping your responses anonymous.'
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text('Cancel'),
                  ),
                  TextButton(
                    onPressed: () {
                      Navigator.of(context).pop();
                      Navigator.of(context).pushNamed('/user'); // Navigate to user screen
                    },
                    child: Text('Select City'),
                  ),
                ],
              ),
            );
          } else {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Failed to submit your response. Please try again.'),
                backgroundColor: Colors.red,
                duration: Duration(seconds: 4),
              ),
            );
          }
          setState(() {
            _isSubmitting = false;
          });
        }
        return; // Don't continue if submission failed
      }
      
      // ONLY mark as answered if database submission was successful
      await Provider.of<UserService>(context, listen: false)
          .addAnsweredQuestion(answeredQuestion, context: context);
      
      // Update the question's vote count
      await questionService.updateQuestionVoteCount(widget.question['id'].toString());
      
      // Record that the user has answered this question to prevent duplicate voting
      final userService = Provider.of<UserService>(context, listen: false);
      await questionService.recordUserResponse(widget.question['id'].toString(), userService: userService, context: context);
      
      // Check if this is QOTD and show subscription prompt if needed
      await questionService.checkQOTDSubscriptionPrompt(context, widget.question);

      // Haptic feedback on successful submission
      await AppHaptics.mediumImpact();

      // For now, use dummy responses
      final responses = List<Map<String, dynamic>>.from(_dummyResponses)
        ..add({
          'answer': _sliderValue,
          'country': locationService.userLocation?['country_name_en'] ?? 'Unknown',
        });

      // Navigate to results screen
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (context) => ApprovalResultsScreen(
            question: widget.question,
            responses: responses,
            feedContext: widget.feedContext,
            fromSearch: widget.fromSearch,
            fromUserScreen: widget.fromUserScreen,
          ),
        ),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error submitting answer. Please try again.')),
      );
      setState(() {
        _isSubmitting = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return SwipeNavigationWrapper(
      feedContext: widget.feedContext,
      currentQuestion: widget.question,
      fromSearch: widget.fromSearch,
      fromUserScreen: widget.fromUserScreen,
      child: Scaffold(
      appBar: AppBar(
        title: Text(_appBarTitle),
        actions: [
          // Subscribe/notification bell button
          Consumer<WatchlistService>(
            builder: (context, watchlistService, child) {
              final isSubscribed = watchlistService.isWatching(widget.question['id'].toString());
              final currentVotes = widget.question['votes'] as int? ?? 0;
              final currentComments = _getCommentCount(widget.question);
              return IconButton(
                icon: Icon(
                  isSubscribed ? Icons.notifications_active : Icons.notifications_off,
                  color: isSubscribed ? Theme.of(context).primaryColor : null,
                ),
                onPressed: () async {
                  if (isSubscribed) {
                    // Unsubscribe and show snackbar with undo
                    await watchlistService.unsubscribeFromQuestion(widget.question['id'].toString());
                    final scaffoldMessenger = ScaffoldMessenger.of(context);
                    final primaryColor = Theme.of(context).primaryColor;
                    scaffoldMessenger.showSnackBar(
                      SnackBar(
                        content: Row(
                          children: [
                            Icon(Icons.notifications_off, color: Colors.white, size: 20),
                            SizedBox(width: 8),
                            Expanded(child: Text('Unsubscribed from question')),
                            TextButton(
                              onPressed: () async {
                                // Check permissions before re-subscribing
                                final notificationService = NotificationService();
                                final userService = Provider.of<UserService>(context, listen: false);
                                final permissionsGranted = await notificationService.arePermissionsGranted();
                                final notificationsEnabled = userService.notifyResponses;
                                
                                if (!permissionsGranted || !notificationsEnabled) {
                                  // Show the q-activity permission dialog
                                  await QuestionActivityPermissionDialog.show(
                                    context,
                                    onPermissionGranted: () async {
                                      // Permission granted - enable notifications and subscribe to the question
                                      final userService = Provider.of<UserService>(context, listen: false);
                                      userService.setNotifyResponses(true);
                                      
                                      await watchlistService.subscribeToQuestion(widget.question['id'].toString(), currentVotes, currentComments);
                                      scaffoldMessenger.showSnackBar(
                                        SnackBar(
                                          content: Row(
                                            children: [
                                              Icon(Icons.notifications_active, color: Colors.white, size: 20),
                                              SizedBox(width: 8),
                                              Text('Re-subscribed'),
                                            ],
                                          ),
                                          backgroundColor: primaryColor,
                                          duration: Duration(seconds: 1),
                                        ),
                                      );
                                    },
                                    onPermissionDenied: () async {
                                      // Permission denied - don't subscribe
                                      scaffoldMessenger.showSnackBar(
                                        SnackBar(
                                          content: Row(
                                            children: [
                                              Icon(Icons.notifications_off, color: Colors.white, size: 20),
                                              SizedBox(width: 8),
                                              Expanded(child: Text('Notifications are disabled. You can enable them in Settings.')),
                                            ],
                                          ),
                                          backgroundColor: Colors.orange,
                                          duration: Duration(seconds: 4),
                                        ),
                                      );
                                    },
                                  );
                                } else {
                                  // Permissions already granted - subscribe directly
                                  await watchlistService.subscribeToQuestion(widget.question['id'].toString(), currentVotes, currentComments);
                                  scaffoldMessenger.showSnackBar(
                                    SnackBar(
                                      content: Row(
                                        children: [
                                          Icon(Icons.notifications_active, color: Colors.white, size: 20),
                                          SizedBox(width: 8),
                                          Text('Re-subscribed'),
                                        ],
                                      ),
                                      backgroundColor: primaryColor,
                                      duration: Duration(seconds: 1),
                                    ),
                                  );
                                }
                              },
                              style: TextButton.styleFrom(
                                padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                minimumSize: Size(0, 0),
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                              child: Text(
                                'UNDO',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ],
                        ),
                        backgroundColor: primaryColor,
                      ),
                    );
                  } else {
                    // Check permissions before subscribing
                    final notificationService = NotificationService();
                    final userService = Provider.of<UserService>(context, listen: false);
                    final permissionsGranted = await notificationService.arePermissionsGranted();
                    final notificationsEnabled = userService.notifyResponses;
                    
                    if (!permissionsGranted || !notificationsEnabled) {
                      // Show the q-activity permission dialog
                      await QuestionActivityPermissionDialog.show(
                        context,
                        onPermissionGranted: () async {
                          // Permission granted - enable notifications and subscribe to the question
                          final userService = Provider.of<UserService>(context, listen: false);
                          userService.setNotifyResponses(true);
                          
                          await watchlistService.subscribeToQuestion(widget.question['id'].toString(), currentVotes, currentComments);
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Row(
                                children: [
                                  Icon(Icons.notifications_active, color: Colors.white, size: 20),
                                  SizedBox(width: 8),
                                  Text('Subscribed to question'),
                                ],
                              ),
                              backgroundColor: Theme.of(context).primaryColor,
                              duration: Duration(seconds: 2),
                            ),
                          );
                        },
                        onPermissionDenied: () async {
                          // Permission denied - don't subscribe
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Row(
                                children: [
                                  Icon(Icons.notifications_off, color: Colors.white, size: 20),
                                  SizedBox(width: 8),
                                  Expanded(child: Text('Notifications are disabled. You can enable them in Settings.')),
                                ],
                              ),
                              backgroundColor: Colors.orange,
                              duration: Duration(seconds: 4),
                            ),
                          );
                        },
                      );
                    } else {
                      // Permissions already granted - subscribe directly
                      await watchlistService.subscribeToQuestion(widget.question['id'].toString(), currentVotes, currentComments);
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Row(
                            children: [
                              Icon(Icons.notifications_active, color: Colors.white, size: 20),
                              SizedBox(width: 8),
                              Text('Subscribed to question'),
                            ],
                          ),
                          backgroundColor: Theme.of(context).primaryColor,
                          duration: Duration(seconds: 2),
                        ),
                      );
                    }
                  }
                },
              );
            },
          ),
          // Save/bookmark button
          Consumer<UserService>(
            builder: (context, userService, child) {
              final isSaved = userService.savedQuestions
                  .any((q) => q['id'] == widget.question['id']);
              return IconButton(
                icon: Icon(
                  isSaved ? Icons.bookmark : Icons.bookmark_border,
                  color: isSaved ? Theme.of(context).primaryColor : null,
                ),
                onPressed: () {
                  if (isSaved) {
                    userService.removeSavedQuestion(widget.question['id']);
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Row(
                          children: [
                            Icon(Icons.bookmark_border, color: Colors.white, size: 20),
                            SizedBox(width: 8),
                            Text('Question removed from saved'),
                          ],
                        ),
                        backgroundColor: Theme.of(context).primaryColor,
                      ),
                    );
                  } else {
                    userService.addSavedQuestion(widget.question);
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Row(
                          children: [
                            Icon(Icons.bookmark, color: Colors.white, size: 20),
                            SizedBox(width: 8),
                            Text('Question saved'),
                          ],
                        ),
                        backgroundColor: Theme.of(context).primaryColor,
                      ),
                    );
                  }
                },
              );
            },
          ),
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
      body: Consumer<GuestUserTrackingService>(
        builder: (context, guestService, child) {
          final questionId = widget.question['id']?.toString();
          final wasViewedAsGuest = questionId != null && guestService.wasViewedAsGuest(questionId);
          
          return SingleChildScrollView(
            controller: _scrollController,
            padding: EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Show warning banner if question was viewed as guest
                if (wasViewedAsGuest) ...[
                  Container(
                    padding: EdgeInsets.all(12),
                    margin: EdgeInsets.only(bottom: 16),
                    decoration: BoxDecoration(
                      color: Colors.orange.shade50,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.orange.shade200),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.block, color: Colors.orange, size: 20),
                        SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'You cannot vote on this question because you viewed it as a guest',
                            style: TextStyle(
                              color: Colors.orange.shade700,
                              fontSize: 14,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                // Question header
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.question['prompt'] ?? widget.question['title'] ?? 'No Title',
                        style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      if (widget.question['description'] != null) ...[
                        SizedBox(height: 8),
                        Text(
                          widget.question['description'],
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      ],
                    ],
                  ),
                ),
                SizedBox(width: 16),
                QuestionTypeBadge(type: widget.question['type'] ?? 'approval_rating'),
              ],
            ),
            
            SizedBox(height: 16),
            
            // Categories and targeting info
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
            if (widget.question['is_private'] == true) ...[
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
            // Show link icon for private questions, otherwise show location targeting
            if (widget.question['is_private'] == true) ...[
              Row(
                children: [
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
                              child: Text('Got it!'),
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
                  Expanded(
                    child: Text(
                      '${getTimeAgo(widget.question['created_at'] ?? widget.question['timestamp'])} • ${widget.question['votes'] ?? 0} ${(widget.question['votes'] ?? 0) == 1 ? 'vote' : 'votes'}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
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
                    dialogMessage = 'This question is addressed to people around the world.';
                    break;
                  case 'country':
                    if (questionCountryCode != null && questionCountryCode.isNotEmpty) {
                      final flagEmoji = _getCountryFlagEmoji(questionCountryCode);
                      targetingEmoji = flagEmoji.isNotEmpty ? flagEmoji : '🇺🇳';
                      final countryName = _getCountryNameFromCode(questionCountryCode);
                      dialogTitle = 'Country Question';
                      dialogMessage = 'This question is addressed to people in $countryName.';
                    } else {
                      targetingEmoji = '🇺🇳';
                      // Fallback to try getting country name from question data
                      final countryName = widget.question['country_name'] ?? 
                                         widget.question['countries']?['country_name_en'] ?? 
                                         'a specific country';
                      dialogTitle = 'Country Question';
                      dialogMessage = 'This question is addressed to people in $countryName.';
                    }
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
                    dialogMessage = 'This question is addressed to people around the world.';
                }
                
                return Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
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
                                child: Text('Got it!'),
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
                    Expanded(
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              '${getTimeAgo(widget.question['created_at'] ?? widget.question['timestamp'])} • ${widget.question['votes'] ?? 0} ${(widget.question['votes'] ?? 0) == 1 ? 'vote' : 'votes'}',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ),
                          if ((widget.question['comment_count'] as int? ?? 0) > 0)
                            Text(
                              '${widget.question['comment_count']} ${(widget.question['comment_count'] as int? ?? 0) == 1 ? 'comment' : 'comments'}',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),
            ],
            
            SizedBox(height: 32),
            Text(
              'Your response:',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            SizedBox(height: 16),
            Container(
              padding: EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: Theme.of(context).dividerColor,
                ),
              ),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Icon(Icons.thumb_down, color: Colors.red),
                      Icon(Icons.thumb_up, color: Colors.green),
                    ],
                  ),
                  SizedBox(height: 8),
                  
                  // Custom slider with bin markers
                  _buildSliderWithBinMarkers(),
                ],
              ),
            ),
            SizedBox(height: 32),
            AnimatedSubmitButton(
              onPressed: (_isSubmitting || wasViewedAsGuest) ? null : _submitAnswer,
              isLoading: _isSubmitting,
              buttonText: 'Submit Answer',
              disabledText: wasViewedAsGuest ? 'Cannot Vote (Viewed as Guest)' : 'Submit Answer',
              backgroundColor: wasViewedAsGuest ? Colors.grey : Theme.of(context).primaryColor,
              foregroundColor: Colors.white,
              padding: EdgeInsets.symmetric(vertical: 16),
            ),
            
            // Swipe to next indicator
            SizedBox(height: 40),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  'Swipe to next',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Colors.grey[600],
                  ),
                ),
                SizedBox(width: 8),
                Icon(
                  Icons.swipe_left,
                  size: 16,
                  color: Colors.grey[600],
                ),
              ],
            ),
            
            // Bottom action buttons as part of scrollable content
            SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                                  TextButton.icon(
                    icon: Icon(Icons.share),
                    label: Text('Share'),
                    onPressed: () {
                      final questionTitle = widget.question['prompt'] ?? widget.question['title'] ?? 'Check out this question';
                      final questionId = widget.question['id']?.toString() ?? '';
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
          );
        },
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: 0, // Default to Home
        onTap: (index) {
          if (index == 0) {
            Navigator.pushNamedAndRemoveUntil(context, '/', (route) => false);
          } else if (index == 1) {
            Navigator.pushNamedAndRemoveUntil(context, '/', (route) => false);
            // Navigate to search tab - this would need to be handled in main screen
          } else if (index == 2) {
            // Navigate to activity tab
            Navigator.pushAndRemoveUntil(
              context,
              MaterialPageRoute(builder: (context) => MainScreen(initialIndex: 2)),
              (route) => false,
            );
          } else if (index == 3) {
            Navigator.pushNamed(context, '/user');
          }
        },
        selectedItemColor: Theme.of(context).primaryColor,
        unselectedItemColor: Colors.grey,
        type: BottomNavigationBarType.fixed,
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.home), label: 'Home'),
          BottomNavigationBarItem(icon: Icon(Icons.search), label: 'Search'),
          BottomNavigationBarItem(icon: Icon(Icons.notifications_outlined), label: 'Activity'),
          BottomNavigationBarItem(icon: Icon(Icons.person), label: 'Me'),
        ],
      ),
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

  String _getCountryNameFromCode(String countryCode) {
    // Map of country codes to country names
    final countryNames = <String, String>{
      'US': 'United States',
      'CA': 'Canada',
      'GB': 'United Kingdom',
      'AU': 'Australia',
      'DE': 'Germany',
      'FR': 'France',
      'IT': 'Italy',
      'ES': 'Spain',
      'JP': 'Japan',
      'CN': 'China',
      'IN': 'India',
      'BR': 'Brazil',
      'MX': 'Mexico',
      'RU': 'Russia',
      'KR': 'South Korea',
      'NL': 'Netherlands',
      'BE': 'Belgium',
      'CH': 'Switzerland',
      'AT': 'Austria',
      'SE': 'Sweden',
      'NO': 'Norway',
      'DK': 'Denmark',
      'FI': 'Finland',
      'PL': 'Poland',
      'CZ': 'Czech Republic',
      'HU': 'Hungary',
      'GR': 'Greece',
      'PT': 'Portugal',
      'IE': 'Ireland',
      'NZ': 'New Zealand',
      'ZA': 'South Africa',
      'AR': 'Argentina',
      'CL': 'Chile',
      'CO': 'Colombia',
      'PE': 'Peru',
      'VE': 'Venezuela',
      'TH': 'Thailand',
      'SG': 'Singapore',
      'MY': 'Malaysia',
      'PH': 'Philippines',
      'ID': 'Indonesia',
      'VN': 'Vietnam',
      'TW': 'Taiwan',
      'HK': 'Hong Kong',
      'EG': 'Egypt',
      'SA': 'Saudi Arabia',
      'AE': 'United Arab Emirates',
      'IL': 'Israel',
      'TR': 'Turkey',
      'UA': 'Ukraine',
      'RO': 'Romania',
      'BG': 'Bulgaria',
      'HR': 'Croatia',
      'SI': 'Slovenia',
      'SK': 'Slovakia',
      'LT': 'Lithuania',
      'LV': 'Latvia',
      'EE': 'Estonia',
      'OM': 'Oman',
      'QA': 'Qatar',
      'KW': 'Kuwait',
      'BH': 'Bahrain',
      'JO': 'Jordan',
      'LB': 'Lebanon',
      'SY': 'Syria',
      'IQ': 'Iraq',
      'IR': 'Iran',
      'YE': 'Yemen',
      'MA': 'Morocco',
      'DZ': 'Algeria',
      'TN': 'Tunisia',
      'LY': 'Libya',
      'SD': 'Sudan',
      'ET': 'Ethiopia',
      'KE': 'Kenya',
      'NG': 'Nigeria',
      'GH': 'Ghana',
      'CI': 'Côte d\'Ivoire',
      'SN': 'Senegal',
      'ML': 'Mali',
      'BF': 'Burkina Faso',
      'NE': 'Niger',
      'TD': 'Chad',
      'CM': 'Cameroon',
      'CF': 'Central African Republic',
      'CD': 'Democratic Republic of Congo',
      'CG': 'Republic of Congo',
      'GA': 'Gabon',
      'GQ': 'Equatorial Guinea',
      'ST': 'São Tomé and Príncipe',
      'AO': 'Angola',
      'ZM': 'Zambia',
      'ZW': 'Zimbabwe',
      'BW': 'Botswana',
      'NA': 'Namibia',
      'LS': 'Lesotho',
      'SZ': 'Eswatini',
      'MG': 'Madagascar',
      'MU': 'Mauritius',
      'MZ': 'Mozambique',
      'MW': 'Malawi',
      'TZ': 'Tanzania',
      'UG': 'Uganda',
      'RW': 'Rwanda',
      'BI': 'Burundi',
      'DJ': 'Djibouti',
      'SO': 'Somalia',
      'ER': 'Eritrea',
      'AF': 'Afghanistan',
      'PK': 'Pakistan',
      'BD': 'Bangladesh',
      'LK': 'Sri Lanka',
      'MV': 'Maldives',
      'NP': 'Nepal',
      'BT': 'Bhutan',
      'MM': 'Myanmar',
      'LA': 'Laos',
      'KH': 'Cambodia',
      'BN': 'Brunei',
      'TL': 'East Timor',
      'FJ': 'Fiji',
      'PG': 'Papua New Guinea',
      'SB': 'Solomon Islands',
      'VU': 'Vanuatu',
      'NC': 'New Caledonia',
      'PF': 'French Polynesia',
      'WS': 'Samoa',
      'TO': 'Tonga',
      'TV': 'Tuvalu',
      'KI': 'Kiribati',
      'NR': 'Nauru',
      'FM': 'Micronesia',
      'MH': 'Marshall Islands',
      'PW': 'Palau',
      'GT': 'Guatemala',
      'BZ': 'Belize',
      'SV': 'El Salvador',
      'HN': 'Honduras',
      'NI': 'Nicaragua',
      'CR': 'Costa Rica',
      'PA': 'Panama',
      'CU': 'Cuba',
      'JM': 'Jamaica',
      'HT': 'Haiti',
      'DO': 'Dominican Republic',
      'PR': 'Puerto Rico',
      'TT': 'Trinidad and Tobago',
      'BB': 'Barbados',
      'GD': 'Grenada',
      'LC': 'Saint Lucia',
      'VC': 'Saint Vincent and the Grenadines',
      'AG': 'Antigua and Barbuda',
      'KN': 'Saint Kitts and Nevis',
      'DM': 'Dominica',
      'GY': 'Guyana',
      'SR': 'Suriname',
      'UY': 'Uruguay',
      'PY': 'Paraguay',
      'BO': 'Bolivia',
      'EC': 'Ecuador',
      'IS': 'Iceland',
      'MT': 'Malta',
      'CY': 'Cyprus',
      'MD': 'Moldova',
      'BY': 'Belarus',
      'RS': 'Serbia',
      'ME': 'Montenegro',
      'BA': 'Bosnia and Herzegovina',
      'MK': 'North Macedonia',
      'AL': 'Albania',
      'XK': 'Kosovo',
      'LU': 'Luxembourg',
      'LI': 'Liechtenstein',
      'AD': 'Andorra',
      'MC': 'Monaco',
      'SM': 'San Marino',
      'VA': 'Vatican City',
      'KZ': 'Kazakhstan',
      'UZ': 'Uzbekistan',
      'TM': 'Turkmenistan',
      'TJ': 'Tajikistan',
      'KG': 'Kyrgyzstan',
      'MN': 'Mongolia',
      'CV': 'Cape Verde',
      'GM': 'Gambia',
      'GN': 'Guinea',
      'GW': 'Guinea-Bissau',
      'LR': 'Liberia',
      'SL': 'Sierra Leone',
      'TG': 'Togo',
      'BJ': 'Benin',
      'MR': 'Mauritania',
      'KM': 'Comoros',
      'SC': 'Seychelles',
      'SS': 'South Sudan',
    };
    
    return countryNames[countryCode.toUpperCase()] ?? countryCode.toUpperCase();
  }
}
