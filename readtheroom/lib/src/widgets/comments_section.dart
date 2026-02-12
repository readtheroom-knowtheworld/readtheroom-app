// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:provider/provider.dart';
import '../services/user_service.dart';
import '../services/comment_service.dart';
import '../services/lizzy_vote_service.dart';
import '../utils/theme_utils.dart';
import 'comment_widget.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

class CommentsSection extends StatefulWidget {
  final String? questionId;
  final String? suggestionId;
  final List<Map<String, dynamic>>? initialComments;
  final bool showAddCommentButton;
  final VoidCallback? onAddCommentTap;
  final int previewCommentsCount;
  final EdgeInsetsGeometry? margin;
  final bool useDummyData; // For testing UI
  final Function(List<Map<String, dynamic>>)? onCommentsLoaded; // Callback for comments
  final Map<String, dynamic>? questionContext; // Question data for NSFW checking
  final Map<String, dynamic>? suggestionContext; // Suggestion data for context

  const CommentsSection({
    Key? key,
    this.questionId,
    this.suggestionId,
    this.initialComments,
    this.showAddCommentButton = true,
    this.onAddCommentTap,
    this.previewCommentsCount = 2,
    this.margin,
    this.useDummyData = false,
    this.onCommentsLoaded,
    this.questionContext,
    this.suggestionContext,
  }) : assert(questionId != null || suggestionId != null, 'Either questionId or suggestionId must be provided'),
       assert(questionId == null || suggestionId == null, 'Only one of questionId or suggestionId should be provided'),
       super(key: key);

  @override
  State<CommentsSection> createState() => _CommentsSectionState();
}

class _CommentsSectionState extends State<CommentsSection> {
  List<Map<String, dynamic>> _comments = [];
  bool _isLoading = false;
  int _displayedCommentsCount = 0; // Track how many comments to display
  bool _hasMoreComments = false;
  int _currentPage = 0;
  final int _commentsPerPage = 20;
  final int _commentsPerLoad = 5; // Show 5 more comments each time
  Set<String> _expandedCommentIds = {};
  String _sortBy = 'top'; // 'top' or 'chrono'
  final LizzyVoteService _lizzyVoteService = LizzyVoteService();

  @override
  void initState() {
    super.initState();
    _initializeLizzyService();
    _displayedCommentsCount = widget.previewCommentsCount; // Start with preview count (usually 2)
    
    if (widget.useDummyData) {
      // Use dummy data for testing
      _comments = CommentService.generateDummyComments(count: 8);
      _sortComments();
      _hasMoreComments = _comments.length >= widget.previewCommentsCount;
      // Notify parent about loaded comments after build is complete
      if (widget.onCommentsLoaded != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          widget.onCommentsLoaded!(_comments);
        });
      }
    } else if (widget.initialComments != null) {
      _comments = List<Map<String, dynamic>>.from(widget.initialComments!);
      _sortComments();
      _hasMoreComments = _comments.length >= widget.previewCommentsCount;
      // Notify parent about initial comments after build is complete
      if (widget.onCommentsLoaded != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          widget.onCommentsLoaded!(_comments);
        });
      }
    } else {
      _loadComments();
    }
  }

  Future<void> _initializeLizzyService() async {
    await _lizzyVoteService.init();
    // Update comment states with user's lizzy votes
    if (mounted) {
      setState(() {
        _updateCommentsWithLizzyStates();
      });
    }
  }

  Future<void> _loadComments({bool loadMore = false}) async {
    if (_isLoading) return;

    setState(() {
      _isLoading = true;
    });

    try {
      final commentService = CommentService();
      final page = loadMore ? _currentPage + 1 : 0;
      
      List<Map<String, dynamic>> newComments;
      if (widget.questionId != null) {
        newComments = await commentService.getCommentsForQuestion(
          widget.questionId!,
          page: page,
          limit: _commentsPerPage,
        );
      } else {
        newComments = await commentService.getCommentsForSuggestion(
          widget.suggestionId!,
          page: page,
          limit: _commentsPerPage,
        );
      }

      if (mounted) {
        setState(() {
          if (loadMore) {
            _comments.addAll(newComments);
            _currentPage = page;
          } else {
            _comments = newComments;
            _currentPage = 0;
          }
          _sortComments();
          _updateCommentsWithLizzyStates();
          _hasMoreComments = newComments.length >= _commentsPerPage;
          _isLoading = false;
        });
        // Notify parent about loaded comments after build is complete
        if (widget.onCommentsLoaded != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            widget.onCommentsLoaded!(_comments);
          });
        }
      }
    } catch (e) {
      print('Error loading comments: $e');
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
        
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to load comments. Please try again.'),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 3),
          ),
        );
      }
    }
  }

  /// Public method to refresh comments (can be called from parent)
  Future<void> refreshComments() async {
    if (widget.useDummyData) return; // Don't refresh dummy data
    await _loadComments();
  }

  /// Sync local lizzy vote states with database state (database is source of truth)
  void _updateCommentsWithLizzyStates() {
    for (final comment in _comments) {
      final commentId = comment['id']?.toString();
      if (commentId != null) {
        final dbState = comment['user_has_upvoted'] as bool? ?? false;
        final localState = _lizzyVoteService.hasUserLizzied(commentId);
        
        // If database and local state differ, trust database and update local
        if (dbState != localState) {
          print('Syncing lizzy state for comment $commentId: local=$localState, db=$dbState');
          if (dbState) {
            _lizzyVoteService.addLizzy(commentId);
          } else {
            _lizzyVoteService.removeLizzy(commentId);
          }
        }
        
        // Ensure comment reflects database state
        comment['user_has_upvoted'] = dbState;
      }
    }
  }

  List<Map<String, dynamic>> get _displayedComments {
    // Filter out hidden comments that shouldn't be shown to users
    final visibleComments = _comments.where((comment) {
      final isHidden = comment['is_hidden'] as bool? ?? false;
      return !isHidden;
    }).toList();
    
    return visibleComments.take(_displayedCommentsCount).toList();
  }

  bool get _hasHiddenComments {
    final visibleComments = _comments.where((comment) {
      final isHidden = comment['is_hidden'] as bool? ?? false;
      return !isHidden;
    }).toList();
    return visibleComments.length > _displayedCommentsCount;
  }

  bool get _isShowingAllComments {
    final visibleComments = _comments.where((comment) {
      final isHidden = comment['is_hidden'] as bool? ?? false;
      return !isHidden;
    }).toList();
    return _displayedCommentsCount >= visibleComments.length;
  }

  Future<void> _handleUpvoteLizard(String commentId) async {
    // Handle dummy data interactions
    if (widget.useDummyData || commentId.startsWith('dummy_comment_')) {
      // For dummy data, just show a message instead of making API calls
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('This is dummy data for UI testing'),
            backgroundColor: Colors.blue,
            duration: Duration(seconds: 2),
          ),
        );
      }
      return;
    }
    
    try {
      final commentService = CommentService();
      
      // Find the comment and check permissions
      final commentIndex = _comments.indexWhere((comment) => comment['id']?.toString() == commentId);
      if (commentIndex == -1) return;
      
      // Check if user is trying to vote on their own comment
      final currentUserId = Supabase.instance.client.auth.currentUser?.id;
      final commentAuthorId = _comments[commentIndex]['author_id']?.toString();
      
      if (currentUserId != null && currentUserId == commentAuthorId) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('You can\'t lizzy your own comment 🦎'),
              backgroundColor: Colors.orange,
              duration: Duration(seconds: 2),
            ),
          );
        }
        return;
      }
      
      // Check current state from comment data (database is source of truth)
      final currentState = _comments[commentIndex]['user_has_upvoted'] as bool? ?? false;
      
      // First, try to update the server
      bool serverUpdateSuccess = false;
      if (!currentState) {
        // Adding a lizzy vote
        try {
          await commentService.addUpvoteLizard(commentId);
          serverUpdateSuccess = true;
          print('Successfully added lizzy vote to server for comment $commentId');
        } catch (e) {
          print('Error adding lizzy vote to server: $e');
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Failed to lizzy comment. Please try again.'),
                backgroundColor: Colors.red,
                duration: Duration(seconds: 2),
              ),
            );
          }
          return;
        }
      } else {
        // Removing a lizzy vote
        try {
          await commentService.removeUpvoteLizard(commentId);
          serverUpdateSuccess = true;
          print('Successfully removed lizzy vote from server for comment $commentId');
        } catch (e) {
          print('Error removing lizzy vote from server: $e');
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Failed to remove lizzy. Please try again.'),
                backgroundColor: Colors.red,
                duration: Duration(seconds: 2),
              ),
            );
          }
          return;
        }
      }
      
      // Only update local state if server update succeeded
      if (serverUpdateSuccess) {
        final newState = !currentState; // Toggle the current state
        
        // Update local storage to match
        if (newState) {
          await _lizzyVoteService.addLizzy(commentId);
        } else {
          await _lizzyVoteService.removeLizzy(commentId);
        }
        
        // Update the comment in our local list
        if (mounted) {
          setState(() {
            _comments[commentIndex]['user_has_upvoted'] = newState;
            
            // Update the count to match server state
            final currentCount = _comments[commentIndex]['upvote_lizard_count'] as int? ?? 0;
            _comments[commentIndex]['upvote_lizard_count'] = newState ? currentCount + 1 : (currentCount - 1).clamp(0, double.infinity).toInt();
          });
        }
      }
    } catch (e) {
      print('Error handling lizzy vote: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Network error. Please try again.'),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 2),
          ),
        );
      }
    }
  }

  Future<void> _handleReportComment(String commentId) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Report Comment'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Are you sure you want to report this comment?'),
            SizedBox(height: 8),
            RichText(
              text: TextSpan(
                style: DefaultTextStyle.of(context).style,
                children: [
                  TextSpan(text: 'Does it violate our '),
                  WidgetSpan(
                    child: GestureDetector(
                      onTap: () async {
                        final url = Uri.parse('https://readtheroom.site/about/#community-guidelines');
                        if (await canLaunchUrl(url)) {
                          await launchUrl(url, mode: LaunchMode.externalApplication);
                        }
                      },
                      child: Text(
                        'community guidelines',
                        style: TextStyle(
                          color: Theme.of(context).primaryColor,
                        ),
                      ),
                    ),
                  ),
                  TextSpan(text: '?'),
                ],
              ),
            ),
          ],
        ),
        actions: [
          Center(
            child: TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              style: TextButton.styleFrom(
                foregroundColor: Colors.white,
                backgroundColor: Colors.orange,
                padding: EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              ),
              child: Text('Submit Report'),
            ),
          ),
        ],
      ),
    );

    if (result == true) {
      // Handle dummy data interactions
      if (widget.useDummyData || commentId.startsWith('dummy_comment_')) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('This is dummy data for UI testing'),
              backgroundColor: Colors.blue,
              duration: Duration(seconds: 2),
            ),
          );
        }
        return;
      }
      
      try {
        final commentService = CommentService();
        await commentService.reportComment(commentId, ['inappropriate_content']);
        
        // Hide the comment immediately from the current user
        if (mounted) {
          setState(() {
            _comments.removeWhere((comment) => comment['id']?.toString() == commentId);
          });
          
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Comment reported. Thank you for helping keep our community safe.'),
              backgroundColor: Theme.of(context).primaryColor,
              duration: Duration(seconds: 3),
            ),
          );
        }
      } catch (e) {
        print('Error reporting comment: $e');
        if (mounted) {
          // Check if it's a duplicate report error
          if (e.toString().contains('duplicate key value violates unique constraint')) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('You have already reported this comment.'),
                backgroundColor: Colors.orange,
                duration: Duration(seconds: 3),
              ),
            );
          } else {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Failed to report comment. Please try again.'),
                backgroundColor: Colors.red,
                duration: Duration(seconds: 3),
              ),
            );
          }
        }
      }
    }
  }

  Future<void> _handleDeleteComment(String commentId) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete Comment'),
        content: Text('Are you sure you want to delete this comment? This action cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: Text('Delete'),
          ),
        ],
      ),
    );

    if (result == true) {
      // Handle dummy data interactions
      if (widget.useDummyData || commentId.startsWith('dummy_comment_')) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('This is dummy data for UI testing'),
              backgroundColor: Colors.blue,
              duration: Duration(seconds: 2),
            ),
          );
        }
        return;
      }
      
      try {
        final commentService = CommentService();
        await commentService.deleteComment(commentId);
        
        // Remove the comment from the local list
        if (mounted) {
          setState(() {
            _comments.removeWhere((comment) => comment['id']?.toString() == commentId);
          });
          
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Comment deleted successfully.'),
              backgroundColor: Theme.of(context).primaryColor,
              duration: Duration(seconds: 2),
            ),
          );
        }
      } catch (e) {
        print('Error deleting comment: $e');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Failed to delete comment. Please try again.'),
              backgroundColor: Colors.red,
              duration: Duration(seconds: 3),
            ),
          );
        }
      }
    }
  }

  void _sortComments() {
    if (_sortBy == 'top') {
      // Sort by upvote lizard count descending
      _comments.sort((a, b) => (b['upvote_lizard_count'] as int? ?? 0).compareTo(a['upvote_lizard_count'] as int? ?? 0));
    } else {
      // Sort by created_at ascending (oldest first) - chronological
      _comments.sort((a, b) {
        try {
          final aTime = DateTime.parse(a['created_at']?.toString() ?? '');
          final bTime = DateTime.parse(b['created_at']?.toString() ?? '');
          return aTime.compareTo(bTime); // Oldest first (top), newest last (bottom)
        } catch (e) {
          return 0;
        }
      });
    }
  }

  void _toggleSort() {
    setState(() {
      _sortBy = _sortBy == 'top' ? 'chrono' : 'top';
      _sortComments();
    });
  }

  void _toggleCommentExpanded(String commentId) {
    setState(() {
      if (_expandedCommentIds.contains(commentId)) {
        _expandedCommentIds.remove(commentId);
      } else {
        _expandedCommentIds.add(commentId);
      }
    });
  }

  Widget _buildHeader() {
    final commentCount = _comments.length;
    
    return Row(
      children: [
        Icon(
          Icons.comment,
          size: 18,
          color: Theme.of(context).primaryColor,
        ),
        SizedBox(width: 8),
        Text(
          'Comments',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w600,
            fontSize: 16,
          ),
        ),
        if (commentCount > 1) ...[ // Only show sort toggle if there are multiple comments
          SizedBox(width: 12),
          GestureDetector(
            onTap: _toggleSort,
            child: Container(
              padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Theme.of(context).primaryColor.withOpacity(0.1),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: Theme.of(context).primaryColor.withOpacity(0.3),
                  width: 1,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _sortBy == 'top' ? Icons.people : Icons.schedule,
                    size: 14,
                    color: Theme.of(context).primaryColor,
                  ),
                  SizedBox(width: 4),
                  Text(
                    _sortBy == 'top' ? 'Top' : 'Chrono',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: Theme.of(context).primaryColor,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
        Spacer(),
        if (widget.showAddCommentButton && Supabase.instance.client.auth.currentUser != null)
          TextButton.icon(
            onPressed: widget.onAddCommentTap,
            icon: Icon(Icons.add_comment, size: 18),
            label: Text('Add'),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).primaryColor,
              padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            ),
          ),
      ],
    );
  }

  Widget _buildEmptyState() {
    return Container(
      padding: EdgeInsets.all(24),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Icon(
              Icons.comment_outlined,
              size: 48,
              color: Colors.grey[400],
            ),
            SizedBox(height: 12),
            Text(
              'No comments yet',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: Colors.grey[600],
                fontWeight: FontWeight.w500,
              ),
              textAlign: TextAlign.center,
            ),
            SizedBox(height: 8),
            Text(
              'Be the first to share your thoughts!',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Colors.grey[500],
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildShowMoreButton() {
    // Show collapse button when showing more than the initial preview count
    if (_displayedCommentsCount > widget.previewCommentsCount) {
      return Container(
        margin: EdgeInsets.symmetric(vertical: 8),
        width: double.infinity,
        child: TextButton(
          onPressed: () {
            setState(() {
              _displayedCommentsCount = widget.previewCommentsCount; // Reset to initial preview count
            });
          },
          style: TextButton.styleFrom(
            foregroundColor: Theme.of(context).primaryColor,
            padding: EdgeInsets.symmetric(vertical: 12),
          ),
          child: Text(
            'Collapse',
            style: TextStyle(fontWeight: FontWeight.w500),
          ),
        ),
      );
    }

    // Show "Show more" button when there are hidden comments locally
    if (_hasHiddenComments) {
      return Container(
        margin: EdgeInsets.symmetric(vertical: 8),
        width: double.infinity,
        child: TextButton(
          onPressed: () {
            setState(() {
              // Show 5 more comments, but don't exceed total available comments
              final visibleComments = _comments.where((comment) {
                final isHidden = comment['is_hidden'] as bool? ?? false;
                return !isHidden;
              }).toList();
              
              _displayedCommentsCount = (_displayedCommentsCount + _commentsPerLoad)
                  .clamp(widget.previewCommentsCount, visibleComments.length);
            });
          },
          style: TextButton.styleFrom(
            foregroundColor: Theme.of(context).primaryColor,
            padding: EdgeInsets.symmetric(vertical: 12),
          ),
          child: Text(
            'Show more',
            style: TextStyle(fontWeight: FontWeight.w500),
          ),
        ),
      );
    }

    // Show load more button when there are more comments to load from server
    if (_hasMoreComments) {
      return Container(
        margin: EdgeInsets.symmetric(vertical: 8),
        width: double.infinity,
        child: TextButton(
          onPressed: _isLoading ? null : () {
            _loadComments(loadMore: true);
          },
          style: TextButton.styleFrom(
            foregroundColor: Theme.of(context).primaryColor,
            padding: EdgeInsets.symmetric(vertical: 12),
          ),
          child: _isLoading 
              ? SizedBox(
                  height: 20,
                  width: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(
                  'Load more comments',
                  style: TextStyle(fontWeight: FontWeight.w500),
                ),
        ),
      );
    }

    return SizedBox.shrink();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: widget.margin ?? EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: Theme.of(context).dividerColor.withOpacity(0.2),
          width: 0.5,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.all(16),
            child: _buildHeader(),
          ),
          
          if (_comments.isEmpty && !_isLoading)
            _buildEmptyState()
          else ...[
            ...(_displayedComments.map((comment) => CommentWidget(
              key: ValueKey(comment['id']),
              comment: comment,
              isExpanded: _expandedCommentIds.contains(comment['id']?.toString()),
              onExpandToggle: () => _toggleCommentExpanded(comment['id']?.toString() ?? ''),
              onUpvoteLizardTap: () => _handleUpvoteLizard(
                comment['id']?.toString() ?? '',
              ),
              onReportTap: () => _handleReportComment(comment['id']?.toString() ?? ''),
              onDeleteTap: () => _handleDeleteComment(comment['id']?.toString() ?? ''),
              margin: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              questionContext: widget.questionContext,
            ))),
            
            if (_isLoading && _currentPage == 0)
              Container(
                padding: EdgeInsets.all(24),
                child: Center(
                  child: CircularProgressIndicator(),
                ),
              ),
            
            _buildShowMoreButton(),
            
            SizedBox(height: 8),
          ],
        ],
      ),
    );
  }
}
