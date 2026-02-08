// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:provider/provider.dart';
import 'dart:async';
import '../services/user_service.dart';
import '../services/comment_service.dart';
import '../widgets/comments_section.dart';
import '../widgets/linked_suggestions_section.dart';
import 'base_suggestion_screen.dart';
import '../widgets/authentication_dialog.dart';
import '../widgets/suggestion_notification_bell.dart';

class SuggestionDetailScreen extends BaseSuggestionScreen {
  const SuggestionDetailScreen({
    Key? key,
    required Map<String, dynamic> suggestion,
    SuggestionFeedContext? feedContext,
    bool fromSearch = false,
    bool fromUserScreen = false,
    bool isGuestMode = false,
  }) : super(
          key: key,
          suggestion: suggestion,
          feedContext: feedContext,
          fromSearch: fromSearch,
          fromUserScreen: fromUserScreen,
          isGuestMode: isGuestMode,
        );

  @override
  _SuggestionDetailScreenState createState() => _SuggestionDetailScreenState();
}

class _SuggestionDetailScreenState extends BaseSuggestionScreenState<SuggestionDetailScreen> {
  final _supabase = Supabase.instance.client;
  bool _isLoading = true;
  bool _isVoting = false;
  String? _errorMessage;
  Timer? _pollTimer;
  int _lastUpvoteCount = 0;
  DateTime _lastUpdated = DateTime.now();
  bool _isSuggestionExpanded = false; // Track suggestion text expansion
  List<Map<String, dynamic>> _comments = []; // Store comments for linked suggestions
  Map<String, dynamic> _suggestionData = {};

  @override
  void initState() {
    super.initState();
    print('🟢 SuggestionDetailScreen initialized with suggestion ID: ${widget.suggestion['id']}');
    print('🟢 Suggestion data: ${widget.suggestion}');
    _suggestionData = Map<String, dynamic>.from(widget.suggestion);
    _loadData();
    _recordSuggestionView();
  }
  
  @override
  void dispose() {
    print('Disposing SuggestionDetailScreen');
    _pollTimer?.cancel();
    _pollTimer = null;
    _isLoading = false; // Prevent any pending setState calls
    super.dispose();
  }

  Future<void> _recordSuggestionView() async {
    try {
      // TODO: Implement suggestion view recording when backend is ready
      print('Recording suggestion view for: ${widget.suggestion['id']}');
    } catch (e) {
      print('Error recording suggestion view: $e');
    }
  }

  Future<void> _loadData() async {
    if (!mounted) return;
    
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      // Load fresh suggestion data from backend
      final suggestionResponse = await _supabase
          .from('suggestions')
          .select('*, suggestion_votes(*)')
          .eq('id', widget.suggestion['id'])
          .single();

      if (suggestionResponse != null) {
        _suggestionData = suggestionResponse;
        _lastUpvoteCount = (suggestionResponse['suggestion_votes'] as List?)?.length ?? 0;
        _lastUpdated = DateTime.now();
      }
      
      // Start polling for real-time updates
      _startPolling();
      
    } catch (e) {
      print('Error loading suggestion data: $e');
      if (mounted) {
        setState(() {
          _errorMessage = 'Failed to load suggestion data. Please try again.';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(Duration(seconds: 30), (timer) async {
      if (!mounted) {
        timer.cancel();
        return;
      }
      await _pollForUpdates();
    });
  }

  Future<void> _pollForUpdates() async {
    try {
      final response = await _supabase
          .from('suggestions')
          .select('*, suggestion_votes(*)')
          .eq('id', widget.suggestion['id'])
          .single();

      if (response != null && mounted) {
        final newUpvoteCount = (response['suggestion_votes'] as List?)?.length ?? 0;
        
        if (newUpvoteCount != _lastUpvoteCount) {
          setState(() {
            _suggestionData = response;
            _lastUpvoteCount = newUpvoteCount;
            _lastUpdated = DateTime.now();
          });
        }
      }
    } catch (e) {
      print('Polling error: $e');
    }
  }

  Future<void> _handleUpvote() async {
    if (_isVoting) return;
    
    final userService = Provider.of<UserService>(context, listen: false);
    final hasVoted = userService.hasVotedSuggestion(widget.suggestion['id']);
    
    setState(() {
      _isVoting = true;
    });

    try {
      bool success;
      if (hasVoted) {
        success = await userService.removeVoteSuggestion(widget.suggestion['id']);
      } else {
        success = await userService.voteSuggestion(widget.suggestion['id']);
      }

      if (!success) {
        _showAuthenticationSnackBar();
      } else {
        // Refresh data after vote
        await _loadData();
      }
    } finally {
      if (mounted) {
        setState(() {
          _isVoting = false;
        });
      }
    }
  }

  void _showAuthenticationSnackBar() {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Please authenticate to upvote suggestions',
          style: TextStyle(color: Colors.white),
        ),
        backgroundColor: Colors.orange,
        action: SnackBarAction(
          label: 'Authenticate',
          textColor: Colors.white,
          onPressed: () {
            AuthenticationDialog.show(
              context,
              customMessage: 'To upvote suggestions, you need to authenticate as a real person.',
              onComplete: () {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      'You can now upvote suggestions!',
                      style: TextStyle(color: Colors.white),
                    ),
                    backgroundColor: Theme.of(context).primaryColor,
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }

  String _getTimeAgo(String? timestamp) {
    if (timestamp == null || timestamp.isEmpty) {
      return 'Unknown time';
    }
    
    final now = DateTime.now();
    DateTime date;
    
    try {
      date = DateTime.parse(timestamp);
    } catch (e) {
      return 'Invalid date';
    }
    
    final difference = now.difference(date);

    if (difference.inDays > 0) {
      return '${difference.inDays}d ago';
    } else if (difference.inHours > 0) {
      return '${difference.inHours}h ago';
    } else if (difference.inMinutes > 0) {
      return '${difference.inMinutes}m ago';
    } else {
      return 'Just now';
    }
  }


  void _reportSuggestion() {
    // TODO: Navigate to report suggestion screen
    // Similar to report_question_screen.dart
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Report Suggestion'),
        content: Text('This feature will be available soon. Please email dev@readtheroom.site to report inappropriate content.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('OK'),
          ),
        ],
      ),
    );
  }

  void _showAddCommentDialog() {
    if (_supabase.auth.currentUser == null) {
      AuthenticationDialog.show(
        context,
        customMessage: 'To comment on suggestions, you need to authenticate as a real person.',
        onComplete: () {
          _showAddCommentDialog();
        },
      );
      return;
    }

    showDialog(
      context: context,
      builder: (context) {
        final TextEditingController commentController = TextEditingController();
        bool isSubmitting = false;
        
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              title: Text('Add Comment'),
              content: TextField(
                controller: commentController,
                maxLines: 3,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  hintText: 'Share your thoughts about this suggestion...',
                  border: OutlineInputBorder(),
                ),
                enabled: !isSubmitting,
              ),
              actions: [
                TextButton(
                  onPressed: isSubmitting ? null : () => Navigator.pop(context),
                  child: Text('Cancel'),
                ),
                ElevatedButton(
                  onPressed: isSubmitting ? null : () async {
                    final commentText = commentController.text.trim();
                    if (commentText.isNotEmpty) {
                      setState(() {
                        isSubmitting = true;
                      });
                      
                      try {
                        final commentService = CommentService();
                        await commentService.addSuggestionComment(
                          suggestionId: widget.suggestion['id'],
                          content: commentText,
                        );
                        
                        Navigator.pop(context);
                        
                        // Refresh comments
                        if (mounted) {
                          setState(() {
                            // Trigger rebuild to reload comments
                          });
                        }
                        
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text('Comment added successfully! 🦎'),
                            backgroundColor: Theme.of(context).primaryColor,
                          ),
                        );
                      } catch (e) {
                        Navigator.pop(context);
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text('Failed to add comment: $e'),
                            backgroundColor: Colors.red,
                          ),
                        );
                      }
                    }
                  },
                  child: isSubmitting 
                    ? SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                        ),
                      )
                    : Text('Add Comment'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  @override
  Widget buildSuggestionScreen(BuildContext context) {
    print('🟢 Building suggestion screen UI');
    final userService = Provider.of<UserService>(context);
    final hasVoted = userService.hasVotedSuggestion(widget.suggestion['id']);
    final upvoteCount = _suggestionData['votes'] ?? _lastUpvoteCount;

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: Text('Suggestion'),
        actions: [
          SuggestionNotificationBell(suggestion: _suggestionData),
          PopupMenuButton<String>(
            onSelected: (value) {
              switch (value) {
                case 'report':
                  _reportSuggestion();
                  break;
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: 'report',
                child: Row(
                  children: [
                    Icon(Icons.flag_outlined, color: Colors.red),
                    SizedBox(width: 8),
                    Text('Report'),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: _isLoading 
        ? Center(child: CircularProgressIndicator())
        : _errorMessage != null
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(_errorMessage!, style: TextStyle(color: Colors.red)),
                  SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: _loadData,
                    child: Text('Retry'),
                  ),
                ],
              ),
            )
          : RefreshIndicator(
              onRefresh: _loadData,
              child: CustomScrollView(
                physics: AlwaysScrollableScrollPhysics(),
                slivers: [
                  // Main suggestion content
                  SliverToBoxAdapter(
                    child: Container(
                      margin: EdgeInsets.all(16),
                      padding: EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Theme.of(context).cardColor,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: Theme.of(context).dividerColor,
                          width: 1,
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Suggestion metadata
                          Row(
                            children: [
                              Icon(
                                Icons.lightbulb_outlined,
                                color: Theme.of(context).primaryColor,
                                size: 20,
                              ),
                              SizedBox(width: 8),
                              Text(
                                'Suggestion',
                                style: TextStyle(
                                  color: Theme.of(context).primaryColor,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 14,
                                ),
                              ),
                              Spacer(),
                              Text(
                                _getTimeAgo(_suggestionData['created_at']),
                                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                  color: Colors.grey[600],
                                ),
                              ),
                            ],
                          ),
                          SizedBox(height: 16),
                          
                          // Suggestion text
                          GestureDetector(
                            onTap: () {
                              setState(() {
                                _isSuggestionExpanded = !_isSuggestionExpanded;
                              });
                            },
                            child: Text(
                              _suggestionData['suggestion'] ?? '',
                              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                                height: 1.5,
                              ),
                              maxLines: _isSuggestionExpanded ? null : 10,
                              overflow: _isSuggestionExpanded ? null : TextOverflow.ellipsis,
                            ),
                          ),
                          
                          SizedBox(height: 20),
                          
                          // Action bar (upvotes, comments)
                          Row(
                            children: [
                              // Upvote button
                              Material(
                                color: Colors.transparent,
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(8),
                                  onTap: _isVoting ? null : _handleUpvote,
                                  child: Container(
                                    padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(
                                        color: hasVoted 
                                          ? Theme.of(context).primaryColor
                                          : Theme.of(context).dividerColor,
                                      ),
                                      color: hasVoted 
                                        ? Theme.of(context).primaryColor.withOpacity(0.1)
                                        : Colors.transparent,
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        if (_isVoting) ...[
                                          SizedBox(
                                            width: 16,
                                            height: 16,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                              valueColor: AlwaysStoppedAnimation<Color>(
                                                Theme.of(context).primaryColor,
                                              ),
                                            ),
                                          ),
                                        ] else ...[
                                          Icon(
                                            hasVoted ? Icons.thumb_up : Icons.thumb_up_outlined,
                                            size: 18,
                                            color: hasVoted 
                                              ? Theme.of(context).primaryColor
                                              : Theme.of(context).textTheme.bodyMedium?.color,
                                          ),
                                        ],
                                        SizedBox(width: 6),
                                        Text(
                                          '$upvoteCount',
                                          style: TextStyle(
                                            color: hasVoted 
                                              ? Theme.of(context).primaryColor
                                              : Theme.of(context).textTheme.bodyMedium?.color,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                              
                              SizedBox(width: 16),
                              
                              // Comments count (will be updated by CommentsSection)
                              Container(
                                padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(
                                    color: Theme.of(context).dividerColor,
                                  ),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      Icons.comment_outlined,
                                      size: 18,
                                      color: Theme.of(context).textTheme.bodyMedium?.color,
                                    ),
                                    SizedBox(width: 6),
                                    Text(
                                      '${_comments.length}',
                                      style: TextStyle(
                                        color: Theme.of(context).textTheme.bodyMedium?.color,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  
                  // Linked suggestions section (if any)
                  SliverToBoxAdapter(
                    child: LinkedSuggestionsSection(
                      suggestionId: widget.suggestion['id'],
                      comments: _comments,
                      fromSearch: widget.fromSearch,
                      fromUserScreen: widget.fromUserScreen,
                    ),
                  ),
                  
                  // Comments section
                  SliverToBoxAdapter(
                    child: Container(
                      margin: EdgeInsets.fromLTRB(16, 0, 16, 16),
                      child: CommentsSection(
                        suggestionId: widget.suggestion['id'],
                        showAddCommentButton: true,
                        onAddCommentTap: _showAddCommentDialog,
                        previewCommentsCount: 3,
                        onCommentsLoaded: (comments) {
                          setState(() {
                            _comments.clear();
                            _comments.addAll(comments);
                          });
                        },
                        suggestionContext: _suggestionData,
                      ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}