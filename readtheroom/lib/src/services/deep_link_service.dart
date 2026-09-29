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
import '../screens/join_beta_screen.dart';
import '../screens/main_screen.dart';
import '../utils/friend_logic.dart';
import '../utils/main_tab_requests.dart';
import '../widgets/authentication_dialog.dart';
import '../widgets/friend_chat_overlay.dart';
import 'analytics_service.dart';
import 'friend_service.dart';
import 'user_service.dart';
import 'question_service.dart';
import 'results_service.dart';

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

      // Friend links are claimed before the question routing below.
      // Both `https://readtheroom.site/friend/{token}` (scanned QR, shared
      // link) and `readtheroom://friend/{token}` (custom-scheme fallback) are
      // recognised; parseFriendToken also validates the token's shape, so a
      // malformed link falls through to the generic error rather than
      // reaching the RPC. See networks-update-design §5.2 / §7.
      final friendToken = parseFriendToken(uri.toString());
      if (friendToken != null) {
        print('Deep link: friend link received');
        // Only the routing category — never the token, which is a credential.
        AnalyticsService().trackDeepLinkOpened('friend_token');
        await _handleFriendLink(context, friendToken);
        return;
      }

      String? questionId;
      String? contentType;
      
      // Handle custom scheme URIs like readtheroom://question/{id}. In this
      // case 'question' becomes the host and the ID is in the path. The
      // retired `suggestion` host is still recognised (below) so an old link
      // or push lands somewhere sensible instead of erroring.
      if (uri.scheme == 'readtheroom') {
        // Widget taps just open the app (owner decision 2026-09-19): every
        // `readtheroom://home` and `readtheroom://qotd[/...]` link lands on
        // home, where the Question of the Day already sits at the top. The
        // widgets now ship `readtheroom://home`; the `qotd/overlay` and
        // `qotd/{id}` forms are still recognised because widgets rendered by
        // an older build keep their old URL until the OS refreshes them.
        // Nothing else uses the `qotd` host: pushes navigate by questionId in
        // NotificationService, shared links use `question/{id}`.
        final isWidgetOpen = uri.host == 'qotd';
        if (uri.host == 'home' || isWidgetOpen) {
          print('Deep link: host-only ${uri.host} link received, routing to home');
          // The widgets tag themselves (`?src=qotd_widget|streak_widget`) so
          // widget opens stay countable now that they share the home link; a
          // tapped QOTD push arrives as `?src=qotd_push` (owner decision
          // 2026-09-22: the Drop opens home, not the question).
          final src = uri.queryParameters['src'];
          final kind = (src == 'qotd_widget' ||
                  src == 'streak_widget' ||
                  src == 'qotd_push')
              ? src!
              : (uri.host == 'home' ? 'home' : 'qotd_widget');
          AnalyticsService().trackDeepLinkOpened(kind);
          // Review 2026-09-22 A4: home is the surface the Drop now lands on,
          // and it is never told how it was opened. `qotd_home_viewed` reads
          // this once.
          AppEntry.record(kind);
          Future.delayed(const Duration(milliseconds: 800), () {
            final ctx = _activeContext;
            if (ctx != null && ctx.mounted) {
              Navigator.of(ctx).popUntil((route) => route.isFirst);
            }
            // "Home" means the home tab, not whichever tab the app was
            // backgrounded on. No-op when no MainScreen is mounted.
            MainTabRequests.instance.goTo(MainTab.home);
          });
          return;
        }

        // WP-F: `readtheroom://friend/{userId}` opens the Community tab and
        // that friend's chat overlay — where every lick / forward / reaction
        // push lands. It cannot collide with the WP-E friend *token* link
        // above: `parseFriendToken` only matches 32 hex characters, and a user
        // id is a dashed uuid, so a token was already claimed before we got
        // here. `readtheroom://community` (what WP-E's request pushes carry)
        // lands on the tab with nothing opened.
        if (uri.host == 'friend' && uri.pathSegments.isNotEmpty) {
          AnalyticsService().trackDeepLinkOpened('friend_chat');
          await _handleFriendChatLink(context, uri.pathSegments[0]);
          return;
        }
        if (uri.host == 'community') {
          AnalyticsService().trackDeepLinkOpened('community');
          _landOnCommunityTab(context);
          return;
        }

        if (uri.host == 'question' || uri.host == 'q' || uri.host == 'qotd') {
          contentType = 'question';
          if (uri.pathSegments.isNotEmpty) {
            questionId = uri.pathSegments[0];
          } else if (uri.path.isNotEmpty) {
            questionId = uri.path.startsWith('/') ? uri.path.substring(1) : uri.path;
          }
        } else if (uri.host == 'suggestion' || uri.host == 's') {
          // Retired: still detected so old links land on Join the beta.
          contentType = 'suggestion';
        } else if (uri.host == 'room') {
          // Retired: still detected so old links show the retirement dialog.
          contentType = 'room';
        } else {
          // Unrecognized readtheroom:// host (e.g. widget tap with empty/unknown host)
          print('Deep link: Unrecognized readtheroom:// host: "${uri.host}", ignoring');
          return;
        }
      } else if (uri.pathSegments.length >= 2) {
        // Handle regular URLs like https://readtheroom.site/question/{id}
        if (uri.pathSegments[0] == 'question' || uri.pathSegments[0] == 'q') {
          contentType = 'question';
          questionId = uri.pathSegments[1];
        } else if (uri.pathSegments[0] == 'suggestion' || uri.pathSegments[0] == 's') {
          contentType = 'suggestion';
        } else if (uri.pathSegments[0] == 'room') {
          contentType = 'room';
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
          } else if (segments[0] == 'room') {
            contentType = 'room';
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
        AnalyticsService().trackDeepLinkOpened(isQotd ? 'qotd' : 'question');
        await _handleQuestionLink(context, questionId, isQotd: isQotd);
        return;
      }
      
      // Handle suggestion links — public suggestions were removed, so an old
      // link or a stale push must not error out. Land on Join the beta, which
      // is where feedback goes now.
      if (contentType == 'suggestion') {
        print('Deep link: suggestion link received but public suggestions are retired: $uri');
        // `suggestion` left the vocabulary with public suggestions; a stale
        // link now counts as `unknown` (review 2026-09-22 §4.3).
        AnalyticsService().trackDeepLinkOpened('unknown');
        _landOnJoinBeta(context);
        return;
      }
      
      // Handle room links — Rooms has been retired (Phase 1 removal).
      // Old/stale QR codes and share links still point at /room/{id};
      // show an info dialog instead of crashing or navigating.
      if (contentType == 'room') {
        print('Deep link: Room link received but Rooms is retired: $uri');
        _showRoomsRetiredDialog(context);
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

    // Fetch the question details.
    print('Deep link: Fetching question details for ID: $questionId');

    // v1.3: QOTD deep links route directly by id (home IS the QOTD now).
    // No trending prefetch / FeedContext — swipe context is null.
    final question = await _fetchQuestion(questionId);

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
      await _navigateToResultsScreen(context, question);
    } else {
      print('Deep link: User has not answered, navigating to answer screen');
      await _navigateToAnswerScreen(context, question, entrySource: isQotd ? 'qotd' : 'deeplink');
    }
  }

  /// Handle a friend QR / share link: `…/friend/{token}`.
  ///
  /// Authenticated → redeem the token (an instantly accepted pair, §5.2) and
  /// land on the Community tab with a success SnackBar.
  ///
  /// Guest → every friend RPC is granted to `authenticated` only, so the token
  /// is stashed and the existing sign-in prompt is shown; the redeem is retried
  /// from its `onComplete`. `FriendService` also drains the stash on the next
  /// auth event, which covers a user who dismisses the prompt here and signs in
  /// later through onboarding.
  Future<void> _handleFriendLink(BuildContext context, String token) async {
    FriendService friendService;
    try {
      friendService = Provider.of<FriendService>(context, listen: false);
    } catch (e) {
      print('Deep link: FriendService unavailable: $e');
      _showErrorSnackBar(context, 'Could not open that friend link.');
      return;
    }

    if (!friendService.isAuthenticated) {
      print('Deep link: friend link received while a guest — stashing token');
      await friendService.stashQrToken(token);
      if (!context.mounted) return;
      await AuthenticationDialog.show(
        context,
        customMessage: 'To add a friend, you need to authenticate as a real '
            'person first. Your friend request is saved until you do.',
        onComplete: () {
          // Fire-and-forget: the dialog's completion callback is synchronous.
          _redeemAndLand(_activeContext ?? context, friendService, token);
        },
      );
      return;
    }

    // A friend link can arrive from anywhere — a web page can redirect to
    // it without the user tapping anything — and redeeming it creates an
    // accepted friendship. Ask first. (The in-app scanner is an intentional
    // scan and does not come through here.)
    if (!context.mounted) return;
    final confirmed = await _confirmFriendLink(context);
    if (confirmed != true) {
      print('Deep link: friend link declined');
      return;
    }

    final ctx = _activeContext ?? context;
    if (!ctx.mounted) return;
    await _redeemAndLand(ctx, friendService, token);
  }

  Future<bool?> _confirmFriendLink(BuildContext context) {
    return showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Add a friend?'),
        content: const Text(
          'This link adds you as friends with the person who shared it. '
          'Friends can see your handle and message you. Only continue if you '
          'trust where the link came from.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Add friend'),
          ),
        ],
      ),
    );
  }

  Future<void> _redeemAndLand(
    BuildContext context,
    FriendService friendService,
    String token,
  ) async {
    final result = await friendService.addFriendViaQr(token);
    await friendService.clearStashedQrToken();

    final ctx = _activeContext ?? context;
    if (!ctx.mounted) return;

    if (!result.success) {
      _showErrorSnackBar(ctx, result.message);
      return;
    }

    final handle = result.friend?.displayHandle ?? 'your new friend';
    _landOnCommunityTab(ctx);

    // Let the tab switch settle before the SnackBar, so it is attached to the
    // ScaffoldMessenger that survives the navigation.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final current = _activeContext;
      if (current == null || !current.mounted) return;
      ScaffoldMessenger.of(current).hideCurrentSnackBar();
      ScaffoldMessenger.of(current).showSnackBar(
        SnackBar(
          content: Text(
            result.alreadyFriends
                ? "You're already friends with $handle 🦎"
                : "You're friends with $handle now 🦎",
            style: const TextStyle(color: Colors.white),
          ),
          backgroundColor: Theme.of(current).primaryColor,
          duration: const Duration(seconds: 3),
        ),
      );
    });
  }

  /// `readtheroom://friend/{userId}` — the Community tab, plus that friend's
  /// chat overlay (§7). Notification taps for licks, forwards and reactions all
  /// arrive here.
  ///
  /// If the id is not an accepted friend (unfriended since the push, blocked,
  /// or a stale notification) we land on the tab and stop, per the WP-F brief —
  /// opening a chat with someone who is no longer a friend would be a dead end
  /// whose every control fails.
  Future<void> _handleFriendChatLink(
      BuildContext context, String rawUserId) async {
    final userId = rawUserId.trim();
    if (userId.isEmpty) return;

    FriendService friendService;
    try {
      friendService = Provider.of<FriendService>(context, listen: false);
    } catch (e) {
      print('Deep link: FriendService unavailable: $e');
      _landOnCommunityTab(context);
      return;
    }

    if (!friendService.isAuthenticated) {
      _landOnCommunityTab(context);
      return;
    }

    var friend = friendService.friendById(userId);
    if (friend == null || !friend.isAccepted) {
      // A cold start from a notification can beat the first get_friends().
      await friendService.load();
      friend = friendService.friendById(userId);
    }

    final ctx = _activeContext ?? context;
    if (!ctx.mounted) return;
    _landOnCommunityTab(ctx);

    if (friend == null || !friend.isAccepted) return;
    final target = friend;

    // Let the tab switch settle before the sheet, so the overlay is pushed on
    // the navigator that survives the navigation.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final current = _activeContext;
      if (current == null || !current.mounted) return;
      FriendChatOverlay.show(current, target);
    });
  }

  /// Opens a question the way a deep link would: the existing smart routing
  /// decides answer screen vs results from whether the viewer has answered.
  ///
  /// Public so the chat overlay can hand a tapped forward to exactly the same
  /// path a notification tap takes — a forwarded question must not behave
  /// differently from a shared link. Note that, like every deep link, this
  /// clears the navigation stack, so callers presenting a sheet should dismiss
  /// it first.
  Future<void> openQuestion(BuildContext context, String questionId) {
    _activeContext = context;
    return _handleQuestionLink(context, questionId);
  }

  /// Clears the stack and lands on Join the beta — where a retired
  /// `readtheroom://suggestion/{id}` link now goes.
  void _landOnJoinBeta(BuildContext context) {
    try {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(
          builder: (_) => const JoinBetaScreen(source: 'deep_link'),
        ),
        (route) => false,
      );
    } catch (e) {
      print('Deep link: could not navigate to Join the beta: $e');
    }
  }

  /// Clears the stack and lands on the Community tab.
  void _landOnCommunityTab(BuildContext context) {
    try {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(
          builder: (_) => const MainScreen(initialIndex: kCommunityTabIndex),
        ),
        (route) => false,
      );
    } catch (e) {
      print('Deep link: could not navigate to Community tab: $e');
    }
  }

  /// Show an info dialog when an old Rooms link/QR is opened.
  /// Rooms was removed in Phase 1; DB objects are dropped in Phase 2.
  void _showRoomsRetiredDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Rooms has been retired'),
        content: const Text(
          'Rooms is no longer part of Read the Room. We\'re replacing it '
          'with Friends in an upcoming update, so this link no longer opens '
          'a room. Thanks for your patience!',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
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
  Future<void> _navigateToAnswerScreen(BuildContext context, Map<String, dynamic> question, {FeedContext? feedContext, String entrySource = 'deeplink'}) async {
    final questionType = question['type'] as String;
    final questionId = question['id'] as String;

    try {
      // Update the question's vote count with current response count before navigating
      final responseCount = await _fetchResponseCount(questionId);
      question['votes'] = responseCount;

      Widget screen;
      switch (questionType.toLowerCase()) {
        case 'multiple_choice':
          screen = AnswerMultipleChoiceScreen(question: question, feedContext: feedContext, entrySource: entrySource);
          break;
        case 'approval_rating':
          screen = AnswerApprovalScreen(question: question, feedContext: feedContext, entrySource: entrySource);
          break;
        case 'text':
          screen = AnswerTextScreen(question: question, feedContext: feedContext, entrySource: entrySource);
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
      final count = await ResultsService().fetchTotalCount(questionId);
      print('Deep link: Found $count total responses');
      return count;
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
          final results = await ResultsService()
              .fetchResults(questionId, questionType: 'multiple_choice');
          // Update the question's vote count based on actual responses
          question['votes'] = results.total;
          screen = MultipleChoiceResultsScreen(
              question: question, results: results, feedContext: feedContext);
          break;
        case 'approval_rating':
          final results = await ResultsService()
              .fetchResults(questionId, questionType: 'approval_rating');
          // Update the question's vote count based on actual responses
          question['votes'] = results.total;
          screen = ApprovalResultsScreen(
              question: question, results: results, feedContext: feedContext);
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

  /// Fetch text response count for a question
  Future<int> _fetchTextResponseCount(String questionId) async {
    try {
      final count = await ResultsService().fetchTextCount(questionId);
      print('Deep link: Found $count text responses');
      return count;
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

  /// Generate fallback link for unsupported platforms
  static String generateFallbackLink(String questionId) {
    return 'readtheroom://question/$questionId';
  }
} 