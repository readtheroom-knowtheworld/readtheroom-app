// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter/services.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'dart:math' as Math;
import '../services/user_service.dart';
import '../services/profanity_filter_service.dart';
import 'authentication_screen.dart';
import '../widgets/authentication_dialog.dart';
import 'suggestion_detail_screen.dart';
import 'base_suggestion_screen.dart';

class FeedbackScreen extends StatefulWidget {
  @override
  _FeedbackScreenState createState() => _FeedbackScreenState();
}

class _FeedbackScreenState extends State<FeedbackScreen> {
  final _formKey = GlobalKey<FormState>();
  final _suggestionController = TextEditingController();
  final _searchController = TextEditingController();
  final _searchFocusNode = FocusNode();
  final _suggestionFocusNode = FocusNode();
  final _profanityFilter = ProfanityFilterService();
  final _supabase = Supabase.instance.client;
  bool _isSubmitting = false;
  String _searchQuery = '';
  bool _containsProfanity = false;
  String _sortBy = 'top'; // 'top' or 'chrono'
  
  // Track voting operations to prevent double-clicking
  final Set<String> _votingInProgress = <String>{};

  // Helper function to launch a URL.
  Future<void> _launchURL(String url) async {
    try {
      final Uri uri = Uri.parse(url);
      
      // For mailto URLs, try with external application mode first
      if (url.startsWith('mailto:')) {
        try {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
          return; // Success!
        } catch (e) {
          print('External app launch failed: $e');
          // Try with platform default
          try {
            await launchUrl(uri, mode: LaunchMode.platformDefault);
            return; // Success!
          } catch (e2) {
            print('Platform default launch failed: $e2');
            // Fall back to clipboard
            await Clipboard.setData(ClipboardData(text: 'dev@readtheroom.site'));
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    'No email app found. Email address copied to clipboard: dev@readtheroom.site',
                    style: TextStyle(color: Colors.white),
                  ),
                  duration: Duration(seconds: 4),
                  backgroundColor: Colors.orange,
                ),
              );
            }
            return;
          }
        }
      }
      
      // For non-mailto URLs, use standard launch
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri);
      } else {
        throw 'Could not launch $url';
      }
    } catch (e) {
      print('Error launching URL: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Could not open link. Please email dev@readtheroom.site manually.',
              style: TextStyle(color: Colors.white),
            ),
            duration: Duration(seconds: 3),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _launchAppStore() async {
    try {
      final url = Platform.isIOS
          ? 'https://apps.apple.com/us/app/read-the-room-know-the-world/id6747105473'
          : 'https://play.google.com/store/apps/details?id=com.readtheroom.app';

      final Uri uri = Uri.parse(url);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      } else {
        throw 'Could not launch $url';
      }
    } catch (e) {
      print('Error launching App Store: $e');
    }
  }

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onSearchChanged);
    _suggestionController.addListener(_checkForProfanity);
  }

  void _onSearchChanged() {
    final newQuery = _searchController.text;
    if (newQuery != _searchQuery) {
      setState(() {
        _searchQuery = newQuery;
      });
    }
  }

  void _checkForProfanity() {
    final hasProfanity = _profanityFilter.containsProfanity(_suggestionController.text);
    
    if (hasProfanity != _containsProfanity) {
      setState(() {
        _containsProfanity = hasProfanity;
      });
      
      // Notify user if profanity is detected
      if (hasProfanity && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Please use civil and appropriate language in your feedback.',
              style: TextStyle(color: Colors.white),
            ),
            backgroundColor: Colors.orange,
            duration: Duration(seconds: 3),
          ),
        );
      }
    }
  }

  @override
  void dispose() {
    _suggestionController.removeListener(_checkForProfanity);
    _suggestionController.dispose();
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    _searchFocusNode.dispose();
    _suggestionFocusNode.dispose();
    super.dispose();
  }

  void _submitSuggestion() {
    if (!_formKey.currentState!.validate()) return;

    // Final check for profanity
    _checkForProfanity();
    
    // Block submission if profanity is detected
    if (_containsProfanity) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Your feedback contains inappropriate language. Please revise before submitting.',
            style: TextStyle(color: Colors.white),
          ),
          backgroundColor: Colors.red,
          duration: Duration(seconds: 3),
        ),
      );
      return;
    }

    // Check if user is authenticated
    if (_supabase.auth.currentUser == null) {
      AuthenticationDialog.show(
        context,
        customMessage: 'To submit feedback, you need to authenticate as a real person.',
        onComplete: () {
          // Retry submission after authentication
          _submitSuggestion();
        },
      );
      return;
    }

    setState(() {
      _isSubmitting = true;
    });

    // Get the user service
    final userService = Provider.of<UserService>(context, listen: false);
    
    // Create new suggestion
    final suggestion = {
      'id': DateTime.now().millisecondsSinceEpoch.toString(),
      'text': _suggestionController.text,
      'votes': 0,
      'timestamp': DateTime.now().toIso8601String(),
      'userId': userService.userId,
    };

    // Add suggestion to user service
    userService.addSuggestion(suggestion);

    // Clear form and show success message
    _suggestionController.clear();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Feedback submitted successfully!',
          style: TextStyle(color: Colors.white),
        ),
        backgroundColor: Theme.of(context).primaryColor,
      ),
    );

    setState(() {
      _isSubmitting = false;
    });
  }

  List<Map<String, dynamic>> _filterSuggestions(List<Map<String, dynamic>> suggestions) {
    if (_searchQuery.isEmpty) return suggestions;
    
    final query = _searchQuery.toLowerCase().trim();
    return suggestions.where((suggestion) {
      final text = suggestion['text'].toString().toLowerCase();
      return text.contains(query);
    }).toList();
  }

  List<Map<String, dynamic>> _sortSuggestions(List<Map<String, dynamic>> suggestions) {
    final sortedSuggestions = List<Map<String, dynamic>>.from(suggestions);
    
    if (_sortBy == 'top') {
      // Sort by like count in descending order (most liked first)
      sortedSuggestions.sort((a, b) => (b['votes'] ?? 0).compareTo(a['votes'] ?? 0));
    } else {
      // Sort by timestamp in descending order (newest first)
      sortedSuggestions.sort((a, b) {
        try {
          final aTime = DateTime.parse(a['timestamp']?.toString() ?? '');
          final bTime = DateTime.parse(b['timestamp']?.toString() ?? '');
          return bTime.compareTo(aTime); // Newest first
        } catch (e) {
          return 0;
        }
      });
    }
    
    return sortedSuggestions;
  }

  void _toggleSort() {
    setState(() {
      _sortBy = _sortBy == 'top' ? 'chrono' : 'top';
    });
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
              customMessage: 'To like suggestions, you need to authenticate as a real person.',
              onComplete: () {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      'You can now like suggestions!',
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

  Future<void> _handleVote(String suggestionId, bool hasVoted) async {
    // Prevent double-clicking
    if (_votingInProgress.contains(suggestionId)) {
      print('DEBUG: Voting already in progress for suggestion $suggestionId');
      return;
    }

    _votingInProgress.add(suggestionId);
    
    try {
      final userService = Provider.of<UserService>(context, listen: false);
      bool success;

      if (hasVoted) {
        success = await userService.removeVoteSuggestion(suggestionId);
      } else {
        success = await userService.voteSuggestion(suggestionId);
      }

      if (!success) {
        _showAuthenticationSnackBar();
      }
    } finally {
      _votingInProgress.remove(suggestionId);
    }
  }

  void _navigateToSuggestionDetail(Map<String, dynamic> suggestion) {
    print('🚀 Navigating to suggestion detail: ${suggestion['id']}');
    try {
      // Create suggestion feed context for navigation
      final userService = Provider.of<UserService>(context, listen: false);
      final suggestions = _sortSuggestions(userService.suggestions);
      
      final suggestionFeedContext = SuggestionFeedContext(
        suggestions: suggestions,
        feedType: 'feedback',
        sortBy: _sortBy,
        searchQuery: _searchQuery.isEmpty ? null : _searchQuery,
      );
      
      print('🚀 About to push SuggestionDetailScreen');
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) {
            print('🚀 Building SuggestionDetailScreen');
            return SuggestionDetailScreen(
              suggestion: suggestion,
              feedContext: suggestionFeedContext,
              fromSearch: false,
              fromUserScreen: false,
            );
          },
        ),
      ).then((_) {
        print('🚀 Navigation completed');
      }).catchError((error) {
        print('🚨 Navigation error: $error');
      });
    } catch (e) {
      print('🚨 Error in navigation: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error opening suggestion: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Feedback & Suggestions'),
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          print('=== SUGGESTIONS DEBUG: User pull-to-refresh ===');
          
          // Get the user service
          final userService = Provider.of<UserService>(context, listen: false);
          
          print('SUGGESTIONS: About to call userService.refreshFeedback()');
          
          // Reload suggestions from database
          await userService.refreshFeedback();
          
          print('SUGGESTIONS: refreshFeedback() completed');
        },
        child: GestureDetector(
          onHorizontalDragEnd: (details) {
            // Check if swipe is from left to right with sufficient velocity
            if (details.primaryVelocity != null && details.primaryVelocity! > 300) {
              Scaffold.of(context).openDrawer();
            }
          },
          child: Consumer<UserService>(
            builder: (context, userService, child) {
              final suggestions = userService.suggestions;
              
              print('=== SUGGESTIONS DEBUG: Feedback screen builder ===');
              print('SUGGESTIONS: Got ${suggestions.length} suggestions from UserService');
              
              // Sort suggestions based on current sort mode
              final sortedSuggestions = _sortSuggestions(suggestions);
              
              if (sortedSuggestions.isNotEmpty) {
                print('SUGGESTIONS: Top 3 suggestions by $_sortBy:');
                for (int i = 0; i < sortedSuggestions.length && i < 3; i++) {
                  final s = sortedSuggestions[i];
                  print('  ${i+1}. ID: ${s['id']}, Likes: ${s['votes']}, Text: "${s['text']?.toString().substring(0, Math.min(50, s['text']?.toString().length ?? 0))}..."');
                }
              } else {
                print('SUGGESTIONS: No suggestions found');
              }
              
              // Filter suggestions based on search query
              final filteredSuggestions = _filterSuggestions(sortedSuggestions);
              
              return CustomScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                slivers: [
                  // Contact email info at top
                  SliverToBoxAdapter(
                    child: Container(
                      width: double.infinity,
                      margin: EdgeInsets.fromLTRB(16, 12, 16, 16),
                      padding: EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Theme.of(context).primaryColor.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: Theme.of(context).primaryColor.withOpacity(0.3),
                        ),
                      ),
                      child: Column(
                        children: [
                          Text(
                            'Please report any bugs you find by email!',
                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: Theme.of(context).primaryColor.withOpacity(0.8),
                          ),
                            textAlign: TextAlign.center,
                          ),
                          SizedBox(height: 8),
                          TextButton(
                            onPressed: () async {
                              await Clipboard.setData(ClipboardData(text: 'dev@readtheroom.site'));
                              if (mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      'Email copied to clipboard',
                                      style: TextStyle(color: Colors.white),
                                    ),
                                    duration: Duration(seconds: 2),
                                    backgroundColor: Colors.teal,
                                  ),
                                );
                              }
                            },
                            style: TextButton.styleFrom(
                              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                              minimumSize: Size(0, 0),
                            ),
                                child: Text(
                                  'dev@readtheroom.site',
                                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                    color: Theme.of(context).primaryColor,
                                    fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ],
                      ),
                    ),
                  ),

                  // Suggestion submission form
                  SliverToBoxAdapter(
                    child: Card(
                      margin: EdgeInsets.symmetric(horizontal: 16),
                      child: Padding(
                        padding: EdgeInsets.all(12),
                        child: _supabase.auth.currentUser == null
                          ? Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  'Please authenticate your account to submit feedback!',
                                  style: Theme.of(context).textTheme.titleMedium,
                                  textAlign: TextAlign.center,
                                ),
                                SizedBox(height: 12),
                                ElevatedButton(
                                  onPressed: () {
                                    AuthenticationDialog.show(
                                      context,
                                      customMessage: 'To submit feedback, you need to authenticate as a real person.',
                                      onComplete: () {
                                        // Just show a message, the form will be available after auth
                                        ScaffoldMessenger.of(context).showSnackBar(
                                          SnackBar(
                                            content: Text(
                                              'You can now submit feedback!',
                                              style: TextStyle(color: Colors.white),
                                            ),
                                            backgroundColor: Theme.of(context).primaryColor,
                                          ),
                                        );
                                      },
                                    );
                                  },
                                  child: Text('Continue'),
                                  style: ElevatedButton.styleFrom(
                                    padding: EdgeInsets.symmetric(vertical: 12),
                                  ),
                                ),
                              ],
                            )
                          : Form(
                              key: _formKey,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    'Your suggestions are important to us <3',
                                    style: Theme.of(context).textTheme.titleMedium,
                                  ),
                                  SizedBox(height: 12),
                                  TextFormField(
                                    controller: _suggestionController,
                                    focusNode: _suggestionFocusNode,
                                    maxLines: 3,
                                    textCapitalization: TextCapitalization.sentences,
                                    decoration: InputDecoration(
                                      hintText: 'What would you like to see in the app?',
                                      border: OutlineInputBorder(),
                                      contentPadding: EdgeInsets.all(12),
                                      // Show warning icon if profanity is detected
                                      suffixIcon: _containsProfanity 
                                        ? Tooltip(
                                            message: 'Your feedback contains potentially inappropriate language',
                                            child: Icon(Icons.warning_amber_rounded, color: Colors.orange),
                                          )
                                        : null,
                                      errorStyle: TextStyle(color: Colors.red),
                                    ),
                                    validator: (value) {
                                      if (value == null || value.isEmpty) {
                                        return 'Please enter your feedback';
                                      }
                                      if (_containsProfanity) {
                                        return 'Please use appropriate language';
                                      }
                                      return null;
                                    },
                                  ),
                                  SizedBox(height: 12),
                                  ElevatedButton(
                                    onPressed: _isSubmitting ? null : _submitSuggestion,
                                    child: _isSubmitting
                                        ? SizedBox(
                                            height: 20,
                                            width: 20,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                              valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                                            ),
                                          )
                                        : Text('Submit Public Suggestion'),
                                    style: ElevatedButton.styleFrom(
                                      padding: EdgeInsets.symmetric(vertical: 12),
                                      backgroundColor: Theme.of(context).primaryColor,
                                      foregroundColor: Colors.white,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                      ),
                    ),
                  ),

                  // Spacing
                  SliverToBoxAdapter(child: SizedBox(height: 16)),

                  // Sort toggle (only show if there are suggestions to sort)
                  if (filteredSuggestions.length > 1)
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                        child: Row(
                          children: [
                            Text(
                              'Sort by:',
                              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                fontWeight: FontWeight.w500,
                                color: Colors.grey[600],
                              ),
                            ),
                            SizedBox(width: 12),
                            GestureDetector(
                              onTap: _toggleSort,
                              child: Container(
                                padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
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
                                      _sortBy == 'top' ? Icons.trending_up : Icons.access_time,
                                      size: 16,
                                      color: Theme.of(context).primaryColor,
                                    ),
                                    SizedBox(width: 4),
                                    Text(
                                      _sortBy == 'top' ? 'Top Voted' : 'Newest',
                                      style: TextStyle(
                                        color: Theme.of(context).primaryColor,
                                        fontWeight: FontWeight.w600,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),

                  // Search bar
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                      child: TextField(
                        controller: _searchController,
                        focusNode: _searchFocusNode,
                        decoration: InputDecoration(
                          hintText: 'Search suggestions...',
                          prefixIcon: Icon(Icons.search),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                          contentPadding: EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                          suffixIcon: _searchQuery.isNotEmpty
                              ? IconButton(
                                  icon: Icon(Icons.clear),
                                  onPressed: () {
                                    _searchController.clear();
                                    setState(() {
                                      _searchQuery = '';
                                    });
                                  },
                                )
                              : null,
                        ),
                        onChanged: (value) {
                          setState(() {
                            _searchQuery = value;
                          });
                        },
                      ),
                    ),
                  ),

                  // Suggestions list or empty state
                  filteredSuggestions.isEmpty
                      ? SliverToBoxAdapter(
                          child: Center(
                            child: Padding(
                              padding: EdgeInsets.all(32),
                              child: Column(
                                children: [
                                  Icon(
                                    Icons.feedback_outlined,
                                    size: 64,
                                    color: Colors.grey,
                                  ),
                                  SizedBox(height: 16),
                                  Text(
                                    _searchQuery.isEmpty
                                        ? 'No suggestions yet. Be the first to submit!'
                                        : 'No suggestions match your search.',
                                    style: TextStyle(color: Colors.grey),
                                    textAlign: TextAlign.center,
                                  ),
                                  if (_searchQuery.isEmpty) ...[
                                    SizedBox(height: 16),
                                    Text(
                                      'Pull down to refresh',
                                      style: TextStyle(
                                        color: Colors.grey,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                        )
                      : SliverList(
                          delegate: SliverChildBuilderDelegate(
                            (context, index) {
                              final suggestion = filteredSuggestions[index];
                              final hasVoted = userService.hasVotedSuggestion(suggestion['id']);
                              
                              return Card(
                                margin: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12.0),
                                  side: BorderSide(
                                    color: Theme.of(context).brightness == Brightness.dark 
                                        ? Colors.white 
                                        : Colors.black,
                                    width: 1.0,
                                  ),
                                ),
                                child: ListTile(
                                  onTap: () => _navigateToSuggestionDetail(suggestion),
                                  title: Text(
                                    suggestion['text'],
                                    maxLines: 3,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  subtitle: Row(
                                    children: [
                                      // Votes
                                      Icon(
                                        Icons.thumb_up_outlined,
                                        size: 14,
                                        color: Colors.grey[600],
                                      ),
                                      SizedBox(width: 4),
                                      Text(
                                        '${suggestion['votes']}',
                                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                          color: Colors.grey[600],
                                        ),
                                      ),
                                      SizedBox(width: 16),
                                      
                                      // Comments
                                      Icon(
                                        Icons.comment_outlined,
                                        size: 14,
                                        color: Colors.grey[600],
                                      ),
                                      SizedBox(width: 4),
                                      Text(
                                        '${suggestion['comment_count'] ?? 0}',
                                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                          color: Colors.grey[600],
                                        ),
                                      ),
                                      SizedBox(width: 16),
                                      
                                      // Time
                                      Expanded(
                                        child: Text(
                                          _getTimeAgo(suggestion['timestamp']),
                                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                            color: Colors.grey[600],
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                  trailing: IconButton(
                                    icon: Icon(
                                      hasVoted ? Icons.thumb_up : Icons.thumb_up_outlined,
                                      color: hasVoted ? Theme.of(context).primaryColor : null,
                                    ),
                                    onPressed: _votingInProgress.contains(suggestion['id']) 
                                        ? null // Disable button while voting is in progress
                                        : () async {
                                            await _handleVote(suggestion['id'], hasVoted);
                                          },
                                  ),
                                ),
                              );
                            },
                            childCount: filteredSuggestions.length,
                          ),
                        ),

                  // Social Media Section
                  SliverToBoxAdapter(
                    child: Container(
                      margin: EdgeInsets.fromLTRB(16, 16, 16, 0),
                      padding: EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: Theme.of(context).dividerColor.withOpacity(0.3),
                        ),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(
                                Icons.share,
                                color: Theme.of(context).primaryColor,
                                size: 24,
                              ),
                              SizedBox(width: 12),
                              Text(
                                'Connect',
                                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                                  fontWeight: FontWeight.bold,
                                  color: Theme.of(context).primaryColor,
                                ),
                              ),
                            ],
                          ),
                          SizedBox(height: 16),
                          Center(
                            child: Text(
                              'Support us? Toss a follow <3',
                              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                                fontWeight: FontWeight.w500,
                                height: 1.4,
                              ),
                            ),
                          ),
                          SizedBox(height: 16),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                            children: [
                              _buildSocialIcon(
                                context,
                                icon: FontAwesomeIcons.instagram,
                                url: 'https://instagram.com/readtheroom.site',
                                color: Color(0xFFE4405F),
                              ),
                              _buildSocialIcon(
                                context,
                                icon: FontAwesomeIcons.bluesky,
                                url: 'https://bsky.app/profile/read-theroom.bsky.social',
                                color: Color(0xFF0085ff),
                              ),
                              _buildSocialIcon(
                                context,
                                icon: FontAwesomeIcons.linkedin,
                                url: 'https://www.linkedin.com/company/read-the-room-know-the-world',
                                color: Color(0xFF0077B5),
                              ),
                            ],
                          ),
                          SizedBox(height: 16),
                          SizedBox(
                            width: double.infinity,
                            height: 48,
                            child: ElevatedButton.icon(
                              onPressed: () => _launchAppStore(),
                              icon: Icon(Icons.star_rate),
                              label: Text('Please rate us on the app store <3'),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Theme.of(context).primaryColor,
                                foregroundColor: Colors.white,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(8),
                                ),
                              ),
                            ),
                          ),
                          SizedBox(height: 16),
                          Center(
                            child: RichText(
                              textAlign: TextAlign.center,
                              text: TextSpan(
                                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                  color: Theme.of(context).brightness == Brightness.dark 
                                      ? Colors.white 
                                      : Colors.black,
                                ),
                                children: [
                                  TextSpan(text: 'Psst! Positive app store reviews really help us out '),
                                  WidgetSpan(
                                    child: Icon(
                                      Icons.favorite,
                                      size: 14,
                                      color: Theme.of(context).brightness == Brightness.dark 
                                          ? Colors.white 
                                          : Colors.black,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                  // Bottom padding
                  SliverToBoxAdapter(child: SizedBox(height: 16)),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildSocialIcon(BuildContext context, {required IconData icon, required String url, required Color color}) {
    return GestureDetector(
      onTap: () => _launchURL(url),
      child: Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          color: color.withOpacity(0.1),
          shape: BoxShape.circle,
          border: Border.all(
            color: color.withOpacity(0.3),
          ),
        ),
        child: Icon(
          icon,
          color: color,
          size: 20,
        ),
      ),
    );
  }

  Widget _buildSocialLink(BuildContext context, {required IconData icon, required String platform, required String handle, required String url, required Color color}) {
    return GestureDetector(
      onTap: () => _launchURL(url),
      child: Container(
        padding: EdgeInsets.all(12),
        decoration: BoxDecoration(
          border: Border.all(
            color: color.withOpacity(0.3),
          ),
          borderRadius: BorderRadius.circular(8),
          color: color.withOpacity(0.05),
        ),
        child: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: color.withOpacity(0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(
                icon,
                color: color,
                size: 18,
              ),
            ),
            SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    platform,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    handle,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: color,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.open_in_new,
              size: 16,
              color: Colors.grey[600],
            ),
          ],
        ),
      ),
    );
  }
}

