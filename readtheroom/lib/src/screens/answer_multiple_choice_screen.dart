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
import 'multiple_choice_results_screen.dart';
import '../utils/time_utils.dart';
import '../utils/haptic_utils.dart';
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

class AnswerMultipleChoiceScreen extends StatefulWidget {
  final Map<String, dynamic> question;
  final FeedContext? feedContext;
  final bool fromSearch;
  final bool fromUserScreen;

  const AnswerMultipleChoiceScreen({Key? key, required this.question, this.feedContext, this.fromSearch = false, this.fromUserScreen = false}) : super(key: key);

  @override
  _AnswerMultipleChoiceScreenState createState() => _AnswerMultipleChoiceScreenState();
}

class _AnswerMultipleChoiceScreenState extends State<AnswerMultipleChoiceScreen> {
  String? _selectedOption;
  bool _isSubmitting = false;
  final ScrollController _scrollController = ScrollController();
  bool _showQuestionInTitle = false;

  // Cache for options to avoid recomputation and hot reload issues
  List<String>? _cachedOptions;

  List<String> get _options {
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
    final options = widget.question['options'] as List<dynamic>?;
    if (options != null && options.isNotEmpty) {
      _cachedOptions = options.map((option) => option.toString()).toList();
      return _cachedOptions!;
    }
    
    // Last resort: provide default options
    print('⚠️ No options found in question data for answering, using defaults');
    _cachedOptions = ['Option 1', 'Option 2', 'Option 3'];
    return _cachedOptions!;
  }

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
  final List<String> _dummyResponses = [
    'Red',
    'Blue',
    'Blue',
    'Green',
    'Yellow',
    'Purple',
    'Orange',
    'Red',
    'Blue',
    'Green',
  ];

  int _getCommentCount(Map<String, dynamic> question) {
    return question['comment_count'] as int? ?? 0;
  }

  void _submitAnswer() async {
    // Check if an option is selected
    if (_selectedOption == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Please select an option'),
        ),
      );
      return;
    }
    
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
      print('DEBUG: LocationService not initialized in answer_multiple_choice_screen _submitAnswer, initializing now...');
      await locationService.initialize();
      print('DEBUG: LocationService initialized, selectedCity: ${locationService.selectedCity}');
    }
    
    final isAuthenticated = supabase.auth.currentUser != null;
    final hasCity = locationService.selectedCity != null;
    
    print('DEBUG: answer_multiple_choice_screen checks - isAuthenticated: $isAuthenticated, hasCity: $hasCity, selectedCity: ${locationService.selectedCity}');
    
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
      // Get the user service first
      final userService = Provider.of<UserService>(context, listen: false);

      // Create a properly typed copy of the question for user service
      final answeredQuestion = <String, dynamic>{
        'id': widget.question['id'].toString(),
        'prompt': widget.question['prompt']?.toString() ?? widget.question['title']?.toString() ?? 'Unknown question',
        'type': widget.question['type']?.toString() ?? 'multiple_choice',
        'timestamp': DateTime.now().toIso8601String(),
        'votes': widget.question['votes'] ?? 0
      };

      // Get the question service
      final questionService = Provider.of<QuestionService>(context, listen: false);

      // Get the current country
      final currentCountry = locationService.userLocation?['country_name_en'] ?? 'Unknown';
      final countryCode = locationService.userLocation?['country_code'] ?? 'US';

      // Run API call in PARALLEL with minimum animation duration (3 seconds)
      // This ensures the animation plays smoothly while work happens in background
      final submitFuture = questionService.submitMultipleChoiceResponse(
        widget.question['id'].toString(),
        _selectedOption!,
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
        // Check if the failure was due to missing city selection
        if (mounted) {
          if (locationService.selectedCity == null) {
            showDialog(
              context: context,
              builder: (context) => AlertDialog(
                title: Text('City Selection Required'),
                content: Text(
                  'To submit responses, please select your city in the "Me" page. '
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
        return; // Don't continue with navigation if submission failed
      }
      
      // ONLY mark as answered if database submission was successful
      await userService.addAnsweredQuestion(answeredQuestion, context: context);
      
      // Record that the user has answered this question to prevent duplicate voting
      await questionService.recordUserResponse(widget.question['id'].toString(), userService: userService, context: context);
      
      // Check if this is QOTD and show subscription prompt if needed
      await questionService.checkQOTDSubscriptionPrompt(context, widget.question);

      // Haptic feedback on successful submission
      await AppHaptics.mediumImpact();

      print('SUCCESS: Response submitted to database successfully');
      
      // Now get the actual responses from the database
      List<Map<String, dynamic>> responses = [];
      
      try {
        // Try to get individual responses from API (not country-summarized)
        final questionId = widget.question['id'].toString();
        final apiResponses = await questionService.getMultipleChoiceIndividualResponses(questionId);
        
        // Use API responses
        responses = List<Map<String, dynamic>>.from(apiResponses);
        print('SUCCESS: Loaded ${responses.length} individual responses from database');
      } catch (e) {
        print('ERROR: Error getting multiple choice responses: $e');
        // If we can't get responses, show error instead of fake data
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Your response was saved, but we couldn\'t load the results. Please try refreshing.'),
              backgroundColor: Colors.orange,
              duration: Duration(seconds: 4),
            ),
          );
          setState(() {
            _isSubmitting = false;
          });
        }
        return;
      }

      // Navigate to results screen
      if (mounted) {
        try {
          // Update the question's vote count to match actual valid responses
          final updatedQuestion = Map<String, dynamic>.from(widget.question);
          final validResponseCount = questionService.getValidResponseCount(widget.question['id'].toString());
          updatedQuestion['votes'] = validResponseCount > 0 ? validResponseCount : responses.length;
          
          print('Updated vote count to match valid responses: ${updatedQuestion['votes']}');
          
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(
              builder: (context) => MultipleChoiceResultsScreen(
                question: updatedQuestion,
                responses: responses,
                feedContext: widget.feedContext,
                fromSearch: widget.fromSearch,
                fromUserScreen: widget.fromUserScreen,
              ),
            ),
          );
        } catch (e) {
          print('Error navigating to results screen: $e');
          // Show error to user
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error showing results: ${e.toString()}')),
          );
        }
      }
    } catch (e) {
      print('Error in _submitAnswer: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error submitting answer. Please try again.')),
        );
        setState(() {
          _isSubmitting = false;
        });
      }
    }
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

  void _shareQuestion() {
    final questionId = widget.question['id']?.toString();
    if (questionId == null) return;

    final shareLink = DeepLinkService.generateQuestionShareLink(questionId);
    final questionTitle = widget.question['prompt'] ?? 'Check out this question';
    
    final box = context.findRenderObject() as RenderBox?;
    Share.share(
      'Check out this question on Read the Room:\n\n$questionTitle\n$shareLink',
      subject: 'Read the Room',
      sharePositionOrigin: box != null 
          ? box.localToGlobal(Offset.zero) & box.size
          : null,
    );
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
                QuestionTypeBadge(type: widget.question['type'] ?? 'multiple_choice'),
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
                  Consumer<QuestionService>(
                    builder: (context, questionService, child) {
                      final validCount = questionService.getValidResponseCount(widget.question['id'].toString());
                      final displayVotes = validCount > 0 ? validCount : (widget.question['votes'] ?? 0);
                      
                      return Expanded(
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                '${getTimeAgo(widget.question['created_at'] ?? widget.question['timestamp'])} • $displayVotes ${displayVotes == 1 ? 'vote' : 'votes'}',
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
                      );
                    },
                  ),
                ],
              ),
            ] else ...[
            Consumer<LocationService>(
              builder: (context, locationService, child) {
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
                    Consumer<QuestionService>(
                      builder: (context, questionService, child) {
                        // Use valid response count if available, otherwise fall back to raw count
                        final validCount = questionService.getValidResponseCount(widget.question['id'].toString());
                        final displayVotes = validCount > 0 ? validCount : (widget.question['votes'] ?? 0);
                        
                        return Expanded(
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  '${getTimeAgo(widget.question['created_at'] ?? widget.question['timestamp'])} • $displayVotes ${displayVotes == 1 ? 'vote' : 'votes'}',
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
                        );
                      },
                    ),
                  ],
                );
              },
            ),
            ],
            
            SizedBox(height: 24),
            Text(
              'Choose one:',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            SizedBox(height: 16),
            if (_options.isEmpty)
              Center(
                child: Padding(
                  padding: EdgeInsets.all(16.0),
                  child: Text(
                    'No options available for this question.',
                    style: TextStyle(color: Colors.grey[600]),
                  ),
                ),
              )
            else
              ..._options.asMap().entries.map((entry) {
                final index = entry.key;
                final option = entry.value;
                final letter = String.fromCharCode(65 + index);
                
                return Container(
                  margin: EdgeInsets.only(bottom: 8),
                  child: RadioListTile<String>(
                    title: Row(
                      children: [
                        Container(
                          width: 24,
                          height: 24,
                          decoration: BoxDecoration(
                            color: _selectedOption == option
                                ? Theme.of(context).primaryColor
                                : Colors.grey.withOpacity(0.3),
                            shape: BoxShape.circle,
                          ),
                          child: Center(
                            child: Text(
                              letter,
                              style: TextStyle(
                                color: _selectedOption == option
                                    ? Colors.white
                                    : Colors.grey[600],
                                fontWeight: FontWeight.bold,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        ),
                        SizedBox(width: 12),
                        Expanded(child: Text(option)),
                      ],
                    ),
                    value: option,
                    groupValue: _selectedOption,
                    onChanged: (value) async {
                      await AppHaptics.lightImpact();
                      setState(() {
                        _selectedOption = value;
                      });
                    },
                    controlAffinity: ListTileControlAffinity.leading,
                    contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                      side: BorderSide(
                        color: _selectedOption == option
                            ? Theme.of(context).primaryColor
                            : Theme.of(context).dividerColor,
                      ),
                    ),
                  ),
                );
              }).toList(),
            SizedBox(height: 24),
            AnimatedSubmitButton(
              onPressed: (_isSubmitting || _options.isEmpty || wasViewedAsGuest) ? null : _submitAnswer,
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
                  onPressed: _shareQuestion,
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

  String _getCountryNameFromCode(String countryCode) {
    // Map of country codes to country names
    final countryNames = <String, String>{
      'US': 'the United States',
      'GB': 'the United Kingdom',
      'CA': 'Canada',
      'AU': 'Australia',
      'DE': 'Germany',
      'FR': 'France',
      'IT': 'Italy',
      'ES': 'Spain',
      'NL': 'the Netherlands',
      'BE': 'Belgium',
      'CH': 'Switzerland',
      'AT': 'Austria',
      'SE': 'Sweden',
      'NO': 'Norway',
      'DK': 'Denmark',
      'FI': 'Finland',
      'IE': 'Ireland',
      'PT': 'Portugal',
      'GR': 'Greece',
      'PL': 'Poland',
      'CZ': 'the Czech Republic',
      'HU': 'Hungary',
      'SK': 'Slovakia',
      'SI': 'Slovenia',
      'HR': 'Croatia',
      'BG': 'Bulgaria',
      'RO': 'Romania',
      'LT': 'Lithuania',
      'LV': 'Latvia',
      'EE': 'Estonia',
      'LU': 'Luxembourg',
      'MT': 'Malta',
      'CY': 'Cyprus',
      'JP': 'Japan',
      'KR': 'South Korea',
      'CN': 'China',
      'IN': 'India',
      'BR': 'Brazil',
      'MX': 'Mexico',
      'AR': 'Argentina',
      'CL': 'Chile',
      'CO': 'Colombia',
      'PE': 'Peru',
      'VE': 'Venezuela',
      'UY': 'Uruguay',
      'PY': 'Paraguay',
      'BO': 'Bolivia',
      'EC': 'Ecuador',
      'GY': 'Guyana',
      'SR': 'Suriname',
      'ZA': 'South Africa',
      'NG': 'Nigeria',
      'EG': 'Egypt',
      'MA': 'Morocco',
      'KE': 'Kenya',
      'GH': 'Ghana',
      'ET': 'Ethiopia',
      'TZ': 'Tanzania',
      'UG': 'Uganda',
      'ZW': 'Zimbabwe',
      'ZM': 'Zambia',
      'MW': 'Malawi',
      'MZ': 'Mozambique',
      'BW': 'Botswana',
      'NA': 'Namibia',
      'SZ': 'Eswatini',
      'LS': 'Lesotho',
      'RU': 'Russia',
      'TR': 'Turkey',
      'SA': 'Saudi Arabia',
      'AE': 'the UAE',
      'IL': 'Israel',
      'JO': 'Jordan',
      'LB': 'Lebanon',
      'SY': 'Syria',
      'IQ': 'Iraq',
      'IR': 'Iran',
      'KW': 'Kuwait',
      'QA': 'Qatar',
      'BH': 'Bahrain',
      'OM': 'Oman',
      'YE': 'Yemen',
      'TH': 'Thailand',
      'VN': 'Vietnam',
      'MY': 'Malaysia',
      'SG': 'Singapore',
      'ID': 'Indonesia',
      'PH': 'the Philippines',
      'MM': 'Myanmar',
      'KH': 'Cambodia',
      'LA': 'Laos',
      'BN': 'Brunei',
      'TL': 'Timor-Leste',
      'NZ': 'New Zealand',
      'FJ': 'Fiji',
      'PG': 'Papua New Guinea',
      'SB': 'Solomon Islands',
      'VU': 'Vanuatu',
      'NC': 'New Caledonia',
      'PF': 'French Polynesia',
      'AS': 'American Samoa',
      'GU': 'Guam',
      'MP': 'Northern Mariana Islands',
      'PW': 'Palau',
      'FM': 'Micronesia',
      'MH': 'Marshall Islands',
      'KI': 'Kiribati',
      'NR': 'Nauru',
      'TV': 'Tuvalu',
      'TO': 'Tonga',
      'WS': 'Samoa',
      'CK': 'Cook Islands',
      'NU': 'Niue',
      'TK': 'Tokelau',
      'WF': 'Wallis and Futuna',
      'PK': 'Pakistan',
      'BD': 'Bangladesh',
      'LK': 'Sri Lanka',
      'MV': 'the Maldives',
      'AF': 'Afghanistan',
      'UZ': 'Uzbekistan',
      'KZ': 'Kazakhstan',
      'KG': 'Kyrgyzstan',
      'TJ': 'Tajikistan',
      'TM': 'Turkmenistan',
      'MN': 'Mongolia',
      'NP': 'Nepal',
      'BT': 'Bhutan',
      'IS': 'Iceland',
      'UA': 'Ukraine',
      'BY': 'Belarus',
      'MD': 'Moldova',
      'GE': 'Georgia',
      'AM': 'Armenia',
      'AZ': 'Azerbaijan',
      'AL': 'Albania',
      'BA': 'Bosnia and Herzegovina',
      'ME': 'Montenegro',
      'MK': 'North Macedonia',
      'XK': 'Kosovo',
      'RS': 'Serbia',
      'AD': 'Andorra',
      'MC': 'Monaco',
      'SM': 'San Marino',
      'VA': 'Vatican City',
      'LI': 'Liechtenstein',
    };
    
    return countryNames[countryCode.toUpperCase()] ?? countryCode;
  }


}
