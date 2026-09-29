// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import '../services/location_service.dart';
import '../services/question_service.dart';
import 'package:provider/provider.dart';
import './report_question_screen.dart';
import '../services/user_service.dart';
import '../utils/time_utils.dart';
import '../widgets/question_type_badge.dart';
import '../widgets/swipe_navigation_wrapper.dart';
import '../services/watchlist_service.dart';
import '../services/notification_service.dart';
import '../widgets/question_activity_permission_dialog.dart';
import '../widgets/comments_section.dart';
import '../widgets/question_rating_section.dart';
import '../utils/category_navigation.dart';
import '../services/analytics_service.dart';
import 'main_screen.dart';
import '../widgets/send_to_friend_sheet.dart';

class AnswerTextScreen extends StatefulWidget {
  final Map<String, dynamic> question;
  final FeedContext? feedContext;
  final bool fromSearch;
  final bool fromUserScreen;
  /// Where this screen was entered from — see [AnswerSource] vocabulary.
  /// Discussion (text) questions have no submit funnel, but the property is
  /// kept for constructor parity with the other answer screens.
  final String entrySource;

  const AnswerTextScreen({
    Key? key,
    required this.question,
    this.feedContext,
    this.fromSearch = false,
    this.fromUserScreen = false,
    this.entrySource = 'other',
  }) : super(key: key);

  @override
  _AnswerTextScreenState createState() => _AnswerTextScreenState();
}

class _AnswerTextScreenState extends State<AnswerTextScreen> {
  final ScrollController _scrollController = ScrollController();
  bool _isReporting = false;
  bool _showQuestionInTitle = false;
  int _ratingSectionRefreshKey = 0;

  @override
  void initState() {
    super.initState();
    print('AnswerTextScreen initialized with question ID: ${widget.question['id']}');
    _setupScrollListener();
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

  @override
  void dispose() {
    print('AnswerTextScreen disposed');
    _scrollController.dispose();
    super.dispose();
  }

  int _getCommentCount(Map<String, dynamic> question) {
    return question['comment_count'] as int? ?? 0;
  }


  Future<void> _reportQuestion() async {
    if (_isReporting || !mounted) return;

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

    setState(() => _isReporting = true);
    try {
      // Navigate to report question screen
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => ReportQuestionScreen(
            question: widget.question,
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error opening report screen: ${e.toString()}'),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _isReporting = false);
      }
    }
  }

  Future<void> _shareQuestion() async {
    if (!mounted) return;
    
    final questionTitle = widget.question['prompt'] ?? widget.question['title'] ?? 'Check out this question';
    final questionId = widget.question['id']?.toString() ?? '';
    AnalyticsService().trackShareInitiated('question', method: 'system', questionId: questionId.isNotEmpty ? questionId : null);
    final shareText = questionId.isNotEmpty
        ? 'Check out this question on Read the Room:\n\n$questionTitle\n\nhttps://readtheroom.site/question/$questionId'
        : 'Check out this question on Read the Room:\n\n$questionTitle';

    try {
      final box = context.findRenderObject() as RenderBox?;
      await Share.share(
        shareText,
        sharePositionOrigin: box != null 
            ? box.localToGlobal(Offset.zero) & box.size
            : null,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error sharing question: ${e.toString()}'),
          backgroundColor: Colors.red,
        ),
      );
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
                                  Text('Re-subscribed'),
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
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Question header
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.question['title'] ?? widget.question['prompt'] ?? 'No Title',
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
                  QuestionTypeBadge(type: widget.question['type'] ?? 'text'),
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
              
              const SizedBox(height: 16),

              // Discussion comments section
              Consumer2<QuestionService, UserService>(
                builder: (context, questionService, userService, child) {
                  final isAuthor = questionService.isCurrentUserAuthor(widget.question);
                  return CommentsSection(
                    questionId: widget.question['id'].toString(),
                    previewCommentsCount: 3,
                    questionContext: widget.question,
                    questionTitle: widget.question['prompt']?.toString() ?? 'Question',
                    isAuthor: isAuthor,
                    onRatingSubmitted: () {
                      if (mounted) setState(() => _ratingSectionRefreshKey++);
                    },
                    margin: EdgeInsets.zero,
                  );
                },
              ),

              const SizedBox(height: 16),

              // Question rating — optional slider for unrated viewers, results
              // for everyone else (the section decides; nothing gated here).
              Consumer<QuestionService>(
                builder: (context, questionService, child) {
                  final isAuthor = questionService.isCurrentUserAuthor(widget.question);
                  return QuestionRatingSection(
                    key: ValueKey('rating_${widget.question['id']}_$_ratingSectionRefreshKey'),
                    questionId: widget.question['id']?.toString() ?? '',
                    isAuthor: isAuthor,
                  );
                },
              ),

              // Swipe to next indicator
              const SizedBox(height: 40),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    'Swipe to next',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Colors.grey[600],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(
                    Icons.swipe_left,
                    size: 16,
                    color: Colors.grey[600],
                  ),
                ],
              ),
              
              // Bottom action buttons as part of scrollable content
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                // WP-F: forward this question inside the app. Hides itself
                // when the viewer has no accepted friends.
                SendToFriendButton(
                  questionId: widget.question['id']?.toString() ?? '',
                ),
                  TextButton.icon(
                    icon: const Icon(Icons.share),
                    label: const Text('Share'),
                    onPressed: _shareQuestion,
                  ),
                  TextButton.icon(
                    icon: const Icon(Icons.report),
                    label: const Text('Report'),
                    onPressed: _isReporting ? null : _reportQuestion,
                  ),
                ],
              ),
              const SizedBox(height: 100), // Extra space for bottom navigation
            ],
          ),
        ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: 0, // Default to Home
        onTap: (index) {
          if (index == 0) {
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
            Navigator.pushNamed(context, '/user');
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
      'MO': '🇲🇴', // Macao
      'FK': '🇫🇰', // Falkland Islands
      'SH': '🇸🇭', // Saint Helena
      'AC': '🇦🇨', // Ascension Island
      'TA': '🇹🇦', // Tristan da Cunha
      'RE': '🇷🇪', // Réunion
      'YT': '🇾🇹', // Mayotte
      'GL': '🇬🇱', // Greenland
      // Historical/Alternative Codes
      'EU': '🇪🇺', // European Union
      'UN': '🇺🇳', // United Nations
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