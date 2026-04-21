// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../screens/answer_multiple_choice_screen.dart';
import '../screens/answer_approval_screen.dart';
import '../screens/answer_text_screen.dart';
import '../screens/multiple_choice_results_screen.dart';
import '../screens/approval_results_screen.dart';
import '../screens/text_results_screen.dart';
import '../screens/suggestion_detail_screen.dart';
import '../screens/room_details_screen.dart';
import '../screens/join_room_screen.dart';
import '../screens/main_screen.dart';
import '../models/room.dart';
import 'user_service.dart';
import 'question_service.dart';
import 'room_event_service.dart';
import '../widgets/qotd_overlay.dart';

// Helper class to track pending deep links
class _PendingDeepLink {
  final Uri uri;
  final DateTime timestamp;
  int retryCount;
  
  _PendingDeepLink(this.uri) : timestamp = DateTime.now(), retryCount = 0;
}

class DeepLinkService {
  static final DeepLinkService _instance = DeepLinkService._internal();
  factory DeepLinkService() => _instance;
  DeepLinkService._internal();

  final _appLinks = AppLinks();
  StreamSubscription<Uri>? _linkSubscription;
  final _supabase = Supabase.instance.client;
  
  // Initialization state tracking
  bool _isInitialized = false;
  final List<_PendingDeepLink> _pendingLinks = [];
  BuildContext? _activeContext;

  /// Initialize deep link handling
  Future<void> initialize(BuildContext context) async {
    print('Deep link: Initializing DeepLinkService');
    _activeContext = context;
    
    // Handle app launch from deep link
    try {
      final Uri? initialLink = await _appLinks.getInitialLink();
      if (initialLink != null) {
        print('Deep link: Found initial link: $initialLink');
        await handleIncomingLink(context, initialLink);
      }
    } catch (e) {
      print('Error getting initial link: $e');
    }

    // Handle deep links while app is running
    _linkSubscription = _appLinks.uriLinkStream.listen(
      (Uri uri) async {
        print('Deep link: Received link while app running: $uri');
        await handleIncomingLink(context, uri);
      },
      onError: (err) {
        print('Deep link error: $err');
      },
    );
    
    // Mark as initialized and process any pending links
    _isInitialized = true;
    print('Deep link: Service initialized, processing ${_pendingLinks.length} pending links');
    
    // Process pending links with a small delay to ensure UI is ready
    if (_pendingLinks.isNotEmpty) {
      Future.delayed(const Duration(milliseconds: 500), () {
        _processPendingLinks();
      });
    }
  }

  /// Dispose resources
  void dispose() {
    _linkSubscription?.cancel();
    _pendingLinks.clear();
  }
  
  /// Process pending deep links that were queued before initialization
  void _processPendingLinks() async {
    print('Deep link: Processing ${_pendingLinks.length} pending links');
    
    while (_pendingLinks.isNotEmpty && _activeContext != null) {
      final pendingLink = _pendingLinks.removeAt(0);
      
      // Skip links that are too old (more than 30 seconds)
      if (DateTime.now().difference(pendingLink.timestamp).inSeconds > 30) {
        print('Deep link: Skipping expired link: ${pendingLink.uri}');
        continue;
      }
      
      try {
        print('Deep link: Processing pending link: ${pendingLink.uri}');
        await handleIncomingLink(_activeContext!, pendingLink.uri);
        print('Deep link: Successfully processed pending link');
      } catch (e) {
        print('Deep link: Error processing pending link: $e');
        
        // Retry logic - retry up to 2 times with exponential backoff
        if (pendingLink.retryCount < 2) {
          pendingLink.retryCount++;
          final delay = Duration(milliseconds: 1000 * pendingLink.retryCount);
          print('Deep link: Scheduling retry ${pendingLink.retryCount} in ${delay.inMilliseconds}ms');
          
          Future.delayed(delay, () {
            if (_activeContext != null) {
              _pendingLinks.insert(0, pendingLink); // Insert at beginning for immediate processing
              _processPendingLinks();
            }
          });
        } else {
          print('Deep link: Max retries exceeded for link: ${pendingLink.uri}');
          if (_activeContext != null) {
            _showErrorSnackBar(_activeContext!, 'Failed to open question after multiple attempts. Please try again.');
          }
        }
      }
    }
    
    print('Deep link: Finished processing pending links');
  }

  /// Handle incoming deep link
  Future<void> handleIncomingLink(BuildContext context, Uri uri) async {
    print('Deep link: Handling incoming link: $uri');
    print('Deep link: Service initialized: $_isInitialized');
    
    // If not initialized yet, queue the link for later processing
    if (!_isInitialized) {
      print('Deep link: Service not initialized, queuing link for later processing');
      _pendingLinks.add(_PendingDeepLink(uri));
      return;
    }
    
    // Update active context
    _activeContext = context;

    try {
      // Extract content ID from various URI formats:
      // https://readtheroom.site/question/{id}
      // readtheroom://question/{id}
      // https://readtheroom.site/suggestion/{id}
      // readtheroom://suggestion/{id}
      // https://readtheroom.site/room/{id}
      // readtheroom://room/{id}
      // https://readtheroom.site/q/{id}
      // readtheroom://q/{id}

      print('Deep link: URI scheme: ${uri.scheme}');
      print('Deep link: URI host: ${uri.host}');
      print('Deep link: URI path: ${uri.path}');
      print('Deep link: URI pathSegments: ${uri.pathSegments}');
      print('Deep link: URI pathSegments length: ${uri.pathSegments.length}');

      String? questionId;
      String? suggestionId;
      String? roomId;
      String? contentType;
      
      // Handle custom scheme URIs like readtheroom://question/{id} or readtheroom://suggestion/{id}
      // In this case, 'question'/'suggestion' becomes the host and the ID is in the path
      if (uri.scheme == 'readtheroom') {
        // Handle home or QOTD link - show QOTD overlay
        // Streak widgets use readtheroom://qotd/overlay
        // QOTD widgets use readtheroom://qotd/{id}
        // Legacy streak widgets use readtheroom://home
        if (uri.host == 'home' || uri.host == 'qotd') {
          print('Deep link: ${uri.host} link received, showing QOTD overlay');
          Future.delayed(const Duration(milliseconds: 800), () {
            final ctx = _activeContext;
            if (ctx != null && ctx.mounted) {
              QotdOverlay.checkAndShow(ctx);
            }
          });
          return;
        }

        if (uri.host == 'question' || uri.host == 'q') {
          contentType = 'question';
          if (uri.pathSegments.isNotEmpty) {
            questionId = uri.pathSegments[0];
          } else if (uri.path.isNotEmpty) {
            questionId = uri.path.startsWith('/') ? uri.path.substring(1) : uri.path;
          }
        } else if (uri.host == 'suggestion' || uri.host == 's') {
          contentType = 'suggestion';
          if (uri.pathSegments.isNotEmpty) {
            suggestionId = uri.pathSegments[0];
          } else if (uri.path.isNotEmpty) {
            suggestionId = uri.path.startsWith('/') ? uri.path.substring(1) : uri.path;
          }
        } else if (uri.host == 'room') {
          contentType = 'room';
          if (uri.pathSegments.isNotEmpty) {
            roomId = uri.pathSegments[0];
          } else if (uri.path.isNotEmpty) {
            roomId = uri.path.startsWith('/') ? uri.path.substring(1) : uri.path;
          }
        } else {
          // Unrecognized readtheroom:// host (e.g. widget tap with empty/unknown host)
          print('Deep link: Unrecognized readtheroom:// host: "${uri.host}", ignoring');
          return;
        }
      } else if (uri.pathSegments.length >= 2) {
        // Handle regular URLs like https://readtheroom.site/question/{id} or https://readtheroom.site/suggestion/{id}
        if (uri.pathSegments[0] == 'question' || uri.pathSegments[0] == 'q') {
          contentType = 'question';
          questionId = uri.pathSegments[1];
        } else if (uri.pathSegments[0] == 'suggestion' || uri.pathSegments[0] == 's') {
          contentType = 'suggestion';
          suggestionId = uri.pathSegments[1];
        } else if (uri.pathSegments[0] == 'room') {
          contentType = 'room';
          roomId = uri.pathSegments[1];
        }
      } else if (uri.path.isNotEmpty) {
        // Fallback: manually parse the path
        final path = uri.path.startsWith('/') ? uri.path.substring(1) : uri.path;
        final segments = path.split('/');
        print('Deep link: Manually parsed segments: $segments');
        
        if (segments.length >= 2) {
          if (segments[0] == 'question' || segments[0] == 'q') {
            contentType = 'question';
            questionId = segments[1];
          } else if (segments[0] == 'suggestion' || segments[0] == 's') {
            contentType = 'suggestion';
            suggestionId = segments[1];
          } else if (segments[0] == 'room') {
            contentType = 'room';
            roomId = segments[1];
          }
        }
      }

      // Handle question links
      if (contentType == 'question') {
        if (questionId == null || questionId.isEmpty || questionId == 'null' || questionId == 'undefined') {
          print('Deep link: No valid question ID found in URI: $uri (questionId: $questionId)');
          _showErrorSnackBar(context, 'Invalid question link.');
          return;
        }
        
        print('Deep link: Extracted question ID: $questionId');
        final isQotd = uri.scheme == 'readtheroom' && uri.host == 'qotd';
        await _handleQuestionLink(context, questionId, isQotd: isQotd);
        return;
      }
      
      // Handle suggestion links
      if (contentType == 'suggestion') {
        if (suggestionId == null || suggestionId.isEmpty || suggestionId == 'null' || suggestionId == 'undefined') {
          print('Deep link: No valid suggestion ID found in URI: $uri (suggestionId: $suggestionId)');
          _showErrorSnackBar(context, 'Invalid suggestion link.');
          return;
        }
        
        print('Deep link: Extracted suggestion ID: $suggestionId');
        await _handleSuggestionLink(context, suggestionId);
        return;
      }
      
      // Handle room links
      if (contentType == 'room') {
        if (roomId == null || roomId.isEmpty || roomId == 'null' || roomId == 'undefined') {
          print('Deep link: No valid room ID found in URI: $uri (roomId: $roomId)');
          _showErrorSnackBar(context, 'Invalid room link.');
          return;
        }
        
        print('Deep link: Extracted room ID: $roomId');
        await _handleRoomLink(context, roomId);
        return;
      }

      // No valid content type found
      print('Deep link: No valid content type found in URI: $uri');
      _showErrorSnackBar(context, 'Invalid link format.');
      return;
      
    } catch (e) {
      print('Deep link: Error handling link: $e');
      _showErrorSnackBar(context, 'Error opening link. Please try again.');
    }
  }

  /// Handle question deep link
  Future<void> _handleQuestionLink(BuildContext context, String questionId, {bool isQotd = false}) async {
    print('Deep link: Handling question link for ID: $questionId (isQotd: $isQotd)');

    // Fetch the question details (and trending feed in parallel for QOTD)
    print('Deep link: Fetching question details for ID: $questionId');

    FeedContext? feedContext;
    Map<String, dynamic>? question;

    if (isQotd) {
      // Fetch QOTD question and trending feed in parallel
      final questionService = QuestionService();
      final results = await Future.wait([
        _fetchQuestion(questionId),
        questionService.fetchOptimizedFeed(
          feedType: 'trending',
          limit: 50,
          useCache: false,
        ).catchError((_) => <Map<String, dynamic>>[]),
      ]);

      question = results[0] as Map<String, dynamic>?;
      final trendingQuestions = results[1] as List<Map<String, dynamic>>;

      if (question != null && trendingQuestions.isNotEmpty) {
        // Deduplicate: remove QOTD from trending if present
        final deduped = trendingQuestions
            .where((q) => q['id']?.toString() != questionId)
            .toList();

        final combinedQuestions = <Map<String, dynamic>>[question, ...deduped];

        feedContext = FeedContext(
          feedType: 'trending',
          filters: {},
          questions: combinedQuestions,
          currentQuestionIndex: 0,
          originalQuestionId: questionId,
          originalQuestionIndex: 0,
        );
        print('Deep link: Built FeedContext with QOTD + ${deduped.length} trending questions');
      }
    } else {
      question = await _fetchQuestion(questionId);
    }

    if (question == null) {
      print('Deep link: Question not found for ID: $questionId');
      _showErrorSnackBar(context, 'Question not found or may have been removed.');
      return;
    }

    // Check if question is hidden (moderated)
    if (question['is_hidden'] == true) {
      print('Deep link: Question is hidden/moderated: $questionId');
      _showErrorSnackBar(context, 'This question is no longer available.');
      return;
    }

    // Determine if user has answered this question using local storage
    bool hasAnswered = false;
    try {
      final userService = Provider.of<UserService>(context, listen: false);
      hasAnswered = userService.hasAnsweredQuestion(questionId);
      print('Deep link: User has answered question $questionId: $hasAnswered');
    } catch (e) {
      print('Error checking if user answered question: $e');
      hasAnswered = false; // Default to not answered on error
    }

    // Navigate to appropriate screen
    if (hasAnswered) {
      print('Deep link: User has already answered, navigating to results screen');
      await _navigateToResultsScreen(context, question, feedContext: feedContext);
    } else {
      print('Deep link: User has not answered, navigating to answer screen');
      await _navigateToAnswerScreen(context, question, feedContext: feedContext);
    }
  }

  /// Handle suggestion deep link
  Future<void> _handleSuggestionLink(BuildContext context, String suggestionId) async {
    print('Deep link: Handling suggestion link for ID: $suggestionId');
    
    // Fetch the suggestion details
    print('Deep link: Fetching suggestion details for ID: $suggestionId');
    final suggestion = await _fetchSuggestion(suggestionId);
    if (suggestion == null) {
      print('Deep link: Suggestion not found for ID: $suggestionId');
      _showErrorSnackBar(context, 'Suggestion not found or may have been removed.');
      return;
    }
    
    print('Deep link: Successfully fetched suggestion');

    // Navigate to suggestion detail screen
    try {
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (context) => SuggestionDetailScreen(
            suggestion: suggestion,
            fromSearch: true, // Mark as coming from external link
          ),
        ),
      );
      
      print('Deep link: Successfully navigated to suggestion detail screen');
    } catch (e) {
      print('Deep link: Error navigating to suggestion screen: $e');
      _showErrorSnackBar(context, 'Error loading suggestion. Please try again.');
    }
  }

  /// Handle room deep link
  Future<void> _handleRoomLink(BuildContext context, String roomId) async {
    print('Deep link: Handling room link for ID: $roomId');
    
    // Check if user is already a member of the room
    final userId = _supabase.auth.currentUser?.id;
    bool isUserMember = false;
    
    if (userId != null) {
      try {
        final membershipResponse = await _supabase
            .from('room_members')
            .select('id')
            .eq('room_id', roomId)
            .eq('user_id', userId)
            .maybeSingle();
        
        isUserMember = membershipResponse != null;
        print('Deep link: User is${isUserMember ? '' : ' not'} already a room member');
      } catch (e) {
        print('Deep link: Error checking room membership: $e');
      }
    }

    try {
      if (isUserMember) {
        // Fetch room details for navigation
        final room = await _fetchRoom(roomId);
        if (room != null) {
          // User is already a member, navigate directly to room details
          await _navigateToRoomDetails(context, room);
        } else {
          _showErrorSnackBar(context, 'Room not found or may have been removed.');
        }
      } else {
        // Navigate to JoinRoomScreen with pre-filled room ID
        print('Deep link: Navigating to JoinRoomScreen with pre-filled room ID: $roomId');
        final joinedRoom = await Navigator.of(context).push<Room>(
          MaterialPageRoute(
            builder: (context) => JoinRoomScreen(prefilledRoomId: roomId),
          ),
        );
        
        if (joinedRoom != null) {
          print('Deep link: Room joined successfully via deep link: ${joinedRoom.name}');
          // Notify other widgets that a room was joined
          RoomEventService().notifyRoomJoined(joinedRoom);
        }
        print('Deep link: Successfully navigated to JoinRoomScreen');
      }
    } catch (e) {
      print('Deep link: Error handling room link: $e');
      _showErrorSnackBar(context, 'Error accessing room. Please try again.');
    }
  }


  /// Navigate to room details screen
  Future<void> _navigateToRoomDetails(BuildContext context, Map<String, dynamic> roomData) async {
    try {
      final room = Room.fromJson(roomData);
      
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (context) => RoomDetailsScreen(room: room),
        ),
      );
      
      print('Deep link: Successfully navigated to room details screen');
    } catch (e) {
      print('Deep link: Error navigating to room details: $e');
      _showErrorSnackBar(context, 'Error opening room. Please try again.');
    }
  }

  /// Fetch suggestion details from database
  Future<Map<String, dynamic>?> _fetchSuggestion(String suggestionId) async {
    try {
      final response = await _supabase
          .from('suggestions')
          .select('*')
          .eq('id', suggestionId)
          .maybeSingle();

      return response;
    } catch (e) {
      print('Error fetching suggestion: $e');
      return null;
    }
  }

  /// Fetch room details from database
  Future<Map<String, dynamic>?> _fetchRoom(String roomId) async {
    try {
      final response = await _supabase
          .from('rooms')
          .select('*')
          .eq('id', roomId)
          .maybeSingle();

      if (response == null) return null;

      // Add member count
      final memberCount = await _supabase
          .from('room_members')
          .select()
          .eq('room_id', roomId);
      
      response['member_count'] = memberCount.length;

      return response;
    } catch (e) {
      print('Error fetching room: $e');
      return null;
    }
  }

  /// Fetch question details from database
  Future<Map<String, dynamic>?> _fetchQuestion(String questionId) async {
    try {
      final response = await _supabase
          .from('questions')
          .select('''
            *, 
            question_options(*),
            question_categories (
              categories (
                id,
                name,
                is_nsfw
              )
            )
          ''')
          .eq('id', questionId)
          .maybeSingle();

      if (response == null) return null;

      // Process the question data
      final question = Map<String, dynamic>.from(response);
      
      // Transform categories structure
      final questionCategories = response['question_categories'] as List<dynamic>? ?? [];
      final categories = questionCategories
          .map((qc) => qc['categories'])
          .where((cat) => cat != null)
          .map((cat) => cat['name'] as String)
          .toList();

      question['categories'] = categories;
      question.remove('question_categories');

      return question;
    } catch (e) {
      print('Error fetching question: $e');
      return null;
    }
  }


  /// Navigate to appropriate answer screen based on question type
  Future<void> _navigateToAnswerScreen(BuildContext context, Map<String, dynamic> question, {FeedContext? feedContext}) async {
    final questionType = question['type'] as String;
    final questionId = question['id'] as String;

    try {
      // Update the question's vote count with current response count before navigating
      final responseCount = await _fetchResponseCount(questionId);
      question['votes'] = responseCount;

      Widget screen;
      switch (questionType.toLowerCase()) {
        case 'multiple_choice':
          screen = AnswerMultipleChoiceScreen(question: question, feedContext: feedContext);
          break;
        case 'approval_rating':
          screen = AnswerApprovalScreen(question: question, feedContext: feedContext);
          break;
        case 'text':
          screen = AnswerTextScreen(question: question, feedContext: feedContext);
          break;
        default:
          _showErrorSnackBar(context, 'Unknown question type: $questionType');
          return;
      }

      // Get navigator state before any navigation
      final navigator = Navigator.of(context);

      print('Deep link: Setting up navigation stack with MainScreen as root');

      // Clear stack and push MainScreen
      navigator.pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => MainScreen()),
        (route) => false,
      );

      // Use addPostFrameCallback to push question screen after MainScreen is rendered
      WidgetsBinding.instance.addPostFrameCallback((_) {
        print('Deep link: PostFrameCallback fired, pushing answer screen');
        navigator.push(
          MaterialPageRoute(builder: (_) => screen),
        );
      });
      print('Deep link: Successfully navigated to answer screen for question: $questionId');
    } catch (e) {
      print('Deep link: Error navigating to answer screen: $e');
      _showErrorSnackBar(context, 'Error loading question. Please try again.');
    }
  }

  /// Fetch total response count for a question (all response types)
  Future<int> _fetchResponseCount(String questionId) async {
    try {
      final response = await _supabase
          .from('responses')
          .select()
          .eq('question_id', questionId);

      print('Deep link: Found ${response?.length ?? 0} total responses');
      return response?.length ?? 0;
    } catch (e) {
      print('Error fetching response count: $e');
      return 0;
    }
  }

  /// Navigate to appropriate results screen based on question type
  Future<void> _navigateToResultsScreen(BuildContext context, Map<String, dynamic> question, {FeedContext? feedContext}) async {
    final questionType = question['type'] as String;
    final questionId = question['id'] as String;

    try {
      // Fetch responses/results for this question
      Widget screen;
      switch (questionType.toLowerCase()) {
        case 'multiple_choice':
          final responses = await _fetchMultipleChoiceResponses(questionId, question);
          // Update the question's vote count based on actual responses
          question['votes'] = responses.length;
          screen = MultipleChoiceResultsScreen(question: question, responses: responses, feedContext: feedContext);
          break;
        case 'approval_rating':
          final responses = await _fetchApprovalResponses(questionId);
          // Update the question's vote count based on actual responses
          question['votes'] = responses.length;
          screen = ApprovalResultsScreen(question: question, responses: responses, feedContext: feedContext);
          break;
        case 'text':
          // For text questions, we need to fetch the response count separately since TextResultsScreen loads its own data
          final textResponseCount = await _fetchTextResponseCount(questionId);
          question['votes'] = textResponseCount;
          screen = TextResultsScreen(question: question, feedContext: feedContext);
          break;
        default:
          _showErrorSnackBar(context, 'Unknown question type: $questionType');
          return;
      }

      // Get navigator state before any navigation
      final navigator = Navigator.of(context);

      print('Deep link: Setting up navigation stack with MainScreen as root');

      // Clear stack and push MainScreen
      navigator.pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => MainScreen()),
        (route) => false,
      );

      // Use addPostFrameCallback to push results screen after MainScreen is rendered
      WidgetsBinding.instance.addPostFrameCallback((_) {
        print('Deep link: PostFrameCallback fired, pushing results screen');
        navigator.push(
          MaterialPageRoute(builder: (_) => screen),
        );
      });
      print('Deep link: Successfully set up navigation for results screen: $questionId');
    } catch (e) {
      print('Deep link: Error navigating to results screen: $e');
      _showErrorSnackBar(context, 'Error loading results. Please try again.');
    }
  }

  /// Fetch multiple choice responses for a question
  Future<List<Map<String, dynamic>>> _fetchMultipleChoiceResponses(String questionId, Map<String, dynamic> question) async {
    try {
      // Fetch responses from database with country information
      final response = await _supabase
          .from('responses')
          .select('''
            option_id,
            created_at,
            countries!responses_country_code_fkey(country_name_en),
            question_options!responses_option_id_fkey(option_text)
          ''')
          .eq('question_id', questionId)
          .not('option_id', 'is', null);

      print('Deep link: Fetched ${response?.length ?? 0} multiple choice responses');
      return response?.map((r) => {
        'answer': r['question_options']?['option_text'] ?? 'Unknown Option',
        'country': r['countries']?['country_name_en'] ?? 'Unknown',
        'created_at': r['created_at'],
      }).toList().cast<Map<String, dynamic>>() ?? [];
    } catch (e) {
      print('Error fetching multiple choice responses: $e');
      return [];
    }
  }

  /// Fetch approval responses for a question
  Future<List<Map<String, dynamic>>> _fetchApprovalResponses(String questionId) async {
    try {
      // Fetch approval responses from database
      final response = await _supabase
          .from('responses')
          .select('''
            score,
            created_at,
            countries!responses_country_code_fkey(country_name_en)
          ''')
          .eq('question_id', questionId)
          .not('score', 'is', null);

      print('Deep link: Fetched ${response?.length ?? 0} approval responses');
      return response?.map((r) => {
        'answer': (r['score'] as int).toDouble() / 100.0, // Convert to -1 to 1 range
        'country': r['countries']?['country_name_en'] ?? 'Unknown',
        'created_at': r['created_at'],
      }).toList().cast<Map<String, dynamic>>() ?? [];
    } catch (e) {
      print('Error fetching approval responses: $e');
      return [];
    }
  }

  /// Fetch text response count for a question
  Future<int> _fetchTextResponseCount(String questionId) async {
    try {
      final response = await _supabase
          .from('responses')
          .select()
          .eq('question_id', questionId)
          .not('text_response', 'is', null);

      print('Deep link: Found ${response?.length ?? 0} text responses');
      return response?.length ?? 0;
    } catch (e) {
      print('Error fetching text response count: $e');
      return 0;
    }
  }

  /// Show error message to user
  void _showErrorSnackBar(BuildContext context, String message) {
    print('Deep link error snackbar: $message');
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.red,
        duration: const Duration(seconds: 4),
      ),
    );
  }

  /// Generate share link for a question
  static String generateQuestionShareLink(String questionId) {
    return 'https://readtheroom.site/question/$questionId';
  }

  /// Generate share link for a room
  static String generateRoomShareLink(String roomId) {
    return 'https://readtheroom.site/room/$roomId';
  }

  /// Generate fallback link for unsupported platforms
  static String generateFallbackLink(String questionId) {
    return 'readtheroom://question/$questionId';
  }
  
  /// Generate room fallback link for unsupported platforms
  static String generateRoomFallbackLink(String roomId) {
    return 'readtheroom://room/$roomId';
  }
} 