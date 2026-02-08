// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/user_service.dart';
import '../screens/suggestion_detail_screen.dart';

class LinkedSuggestionsSection extends StatefulWidget {
  final String suggestionId;
  final List<Map<String, dynamic>>? comments; // Get linked suggestions from comments
  final EdgeInsetsGeometry? margin;
  final bool useDummyData; // For testing UI
  final bool fromSearch; // Whether we came from search
  final bool fromUserScreen; // Whether we came from user screen

  const LinkedSuggestionsSection({
    Key? key,
    required this.suggestionId,
    this.comments,
    this.margin,
    this.useDummyData = false,
    this.fromSearch = false,
    this.fromUserScreen = false,
  }) : super(key: key);

  @override
  State<LinkedSuggestionsSection> createState() => _LinkedSuggestionsSectionState();
}

class _LinkedSuggestionsSectionState extends State<LinkedSuggestionsSection> {
  List<Map<String, dynamic>> _linkedSuggestions = [];
  bool _isLoading = false;
  bool _showAllLinkedSuggestions = false;

  @override
  void initState() {
    super.initState();
    _extractLinkedSuggestions();
  }

  @override
  void didUpdateWidget(LinkedSuggestionsSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.comments != oldWidget.comments) {
      _extractLinkedSuggestions();
    }
  }

  void _extractLinkedSuggestions() {
    if (widget.useDummyData) {
      _linkedSuggestions = _generateDummyLinkedSuggestions();
      return;
    }

    if (widget.comments == null || widget.comments!.isEmpty) {
      setState(() {
        _linkedSuggestions = [];
      });
      return;
    }

    // Extract linked suggestions from comments, sorted by upvote count
    final linkedSuggestionIds = <String>{};
    final commentUpvotes = <String, int>{};
    
    // Sort comments by lizzy vote count descending first
    final sortedComments = List<Map<String, dynamic>>.from(widget.comments!)
      ..sort((a, b) => (b['upvote_lizard_count'] as int? ?? 0).compareTo(a['upvote_lizard_count'] as int? ?? 0));
    
    // Extract linked suggestion IDs from highest-voted comments first
    for (final comment in sortedComments) {
      final linkedIds = comment['linked_suggestion_ids'] as List<dynamic>?;
      if (linkedIds != null && linkedIds.isNotEmpty) {
        final upvoteCount = comment['upvote_lizard_count'] as int? ?? 0;
        for (final id in linkedIds) {
          final suggestionId = id.toString();
          if (!linkedSuggestionIds.contains(suggestionId)) {
            linkedSuggestionIds.add(suggestionId);
            commentUpvotes[suggestionId] = upvoteCount;
          }
        }
      }
    }

    // Convert to list and sort by the upvote count of the comment that linked them
    final sortedLinkedSuggestions = linkedSuggestionIds.map((id) => {
      'id': id,
      'comment_upvotes': commentUpvotes[id] ?? 0,
    }).toList()
      ..sort((a, b) => (b['comment_upvotes'] as int).compareTo(a['comment_upvotes'] as int));

    _loadLinkedSuggestionsData(sortedLinkedSuggestions.map((s) => s['id'] as String).toList());
  }

  Future<void> _loadLinkedSuggestionsData(List<String> suggestionIds) async {
    if (suggestionIds.isEmpty) {
      setState(() {
        _linkedSuggestions = [];
      });
      return;
    }

    setState(() {
      _isLoading = true;
    });

    try {
      // Get linked suggestions from UserService
      final userService = Provider.of<UserService>(context, listen: false);
      final suggestions = await userService.getSuggestionsByIds(suggestionIds);
      
      if (mounted) {
        setState(() {
          _linkedSuggestions = suggestions;
          _isLoading = false;
        });
      }
    } catch (e) {
      print('Error loading linked suggestions: $e');
      if (mounted) {
        setState(() {
          _linkedSuggestions = [];
          _isLoading = false;
        });
      }
    }
  }

  List<Map<String, dynamic>> _generateDummyLinkedSuggestions() {
    return [
      {
        'id': 'dummy-1',
        'suggestion': 'Add dark mode toggle in settings',
        'votes': 15,
        'created_at': DateTime.now().subtract(Duration(days: 2)).toIso8601String(),
      },
      {
        'id': 'dummy-2',
        'suggestion': 'Implement push notifications for new questions',
        'votes': 8,
        'created_at': DateTime.now().subtract(Duration(hours: 5)).toIso8601String(),
      },
    ];
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

  void _navigateToLinkedSuggestion(Map<String, dynamic> suggestion) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => SuggestionDetailScreen(
          suggestion: suggestion,
          fromSearch: widget.fromSearch,
          fromUserScreen: widget.fromUserScreen,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_linkedSuggestions.isEmpty && !_isLoading) {
      return SizedBox.shrink();
    }

    final displayedSuggestions = _showAllLinkedSuggestions 
        ? _linkedSuggestions 
        : _linkedSuggestions.take(3).toList();

    return Container(
      margin: widget.margin ?? EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Section header
          Padding(
            padding: EdgeInsets.only(bottom: 12),
            child: Row(
              children: [
                Icon(
                  Icons.link,
                  color: Theme.of(context).primaryColor,
                  size: 20,
                ),
                SizedBox(width: 8),
                Text(
                  'Linked Suggestions',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: Theme.of(context).primaryColor,
                  ),
                ),
                if (_linkedSuggestions.length > 3) ...[
                  Spacer(),
                  TextButton(
                    onPressed: () {
                      setState(() {
                        _showAllLinkedSuggestions = !_showAllLinkedSuggestions;
                      });
                    },
                    style: TextButton.styleFrom(
                      minimumSize: Size(0, 0),
                      padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    ),
                    child: Text(
                      _showAllLinkedSuggestions ? 'Show Less' : 'Show All (${_linkedSuggestions.length})',
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).primaryColor,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          
          // Loading indicator
          if (_isLoading)
            Center(
              child: Padding(
                padding: EdgeInsets.all(20),
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else
            // Linked suggestions list
            Column(
              children: displayedSuggestions.map((suggestion) {
                final userService = Provider.of<UserService>(context);
                final hasVoted = userService.hasVotedSuggestion(suggestion['id']);
                
                return Container(
                  margin: EdgeInsets.only(bottom: 8),
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: () => _navigateToLinkedSuggestion(suggestion),
                      borderRadius: BorderRadius.circular(8),
                      child: Container(
                        padding: EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: Theme.of(context).dividerColor,
                          ),
                          borderRadius: BorderRadius.circular(8),
                          color: Theme.of(context).cardColor.withOpacity(0.5),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Suggestion preview text
                            Text(
                              suggestion['suggestion'] ?? '',
                              style: Theme.of(context).textTheme.bodyMedium,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            SizedBox(height: 8),
                            
                            // Metadata row
                            Row(
                              children: [
                                // Upvote count
                                Icon(
                                  hasVoted ? Icons.thumb_up : Icons.thumb_up_outlined,
                                  size: 14,
                                  color: hasVoted 
                                    ? Theme.of(context).primaryColor 
                                    : Colors.grey[600],
                                ),
                                SizedBox(width: 4),
                                Text(
                                  '${suggestion['votes'] ?? 0}',
                                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: hasVoted 
                                      ? Theme.of(context).primaryColor 
                                      : Colors.grey[600],
                                  ),
                                ),
                                
                                Spacer(),
                                
                                // Time ago
                                Text(
                                  _getTimeAgo(suggestion['created_at']),
                                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: Colors.grey[600],
                                  ),
                                ),
                                
                                SizedBox(width: 8),
                                Icon(
                                  Icons.arrow_forward_ios,
                                  size: 12,
                                  color: Colors.grey[600],
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
        ],
      ),
    );
  }
}