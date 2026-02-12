// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

// lib/src/screens/new_question_screen.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../utils/haptic_utils.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../services/user_service.dart';
import '../services/location_service.dart';
import '../services/profanity_filter_service.dart';
import '../widgets/notification_bell.dart';
import '../models/category.dart';
import 'authentication_screen.dart';
import '../services/question_service.dart';
import '../utils/time_utils.dart';
import '../utils/theme_utils.dart';
import 'question_preview_screen.dart';
import 'answer_approval_screen.dart';
import 'answer_multiple_choice_screen.dart';
import 'answer_text_screen.dart';
import '../widgets/first_question_notification_dialog.dart';
import '../services/analytics_service.dart';
import '../services/congratulations_service.dart';
import '../services/achievement_service.dart';

class NewQuestionScreen extends StatefulWidget {
  @override
  _NewQuestionScreenState createState() => _NewQuestionScreenState();
}

class _NewQuestionScreenState extends State<NewQuestionScreen> {
  final _formKey = GlobalKey<FormState>();
  final _titleController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _newOptionController = TextEditingController();
  final _titleFocusNode = FocusNode();
  final _descriptionFocusNode = FocusNode();
  String _selectedType = '';
  List<String> _options = [];
  List<TextEditingController> _optionControllers = [];
  List<FocusNode> _optionFocusNodes = [];
  String _newOption = '';
  bool _isSubmitting = false;
  List<Category> _selectedCategories = [];
  bool _isNSFW = false;
  bool _profanityDetected = false;
  final _profanityFilter = ProfanityFilterService();
  List<String> _mentionedCountries = [];
  String _selectedTargeting = 'globe'; // globe, country, city
  bool _isPrivate = false; // Private question flag
  
  // Button width constant
  static const double _buttonWidth = 100.0;
  
  // Country autocomplete variables
  List<String> _countrySuggestions = [];
  bool _showCountrySuggestions = false;
  int _mentionStartPosition = -1;
  String _currentMentionText = '';
  // Focus nodes for options (kept for potential future use)
  
  // Category ordering based on feed usage
  Map<String, int> _categoryCounts = {};
  bool _categoryCountsLoaded = false;
  bool _showAllCategories = false;

  @override
  void initState() {
    super.initState();
    
    // Add focus listeners to check for profanity when user finishes typing
    _titleFocusNode.addListener(_onTitleFocusChange);
    _descriptionFocusNode.addListener(_onDescriptionFocusChange);
    
    // Keep existing listeners for country autocomplete
    _descriptionController.addListener(() => _checkForCountryMentions(_descriptionController.text));
    _descriptionController.addListener(_handleCountryAutocomplete);
    
    // Load category counts for ordering
    _loadCategoryCounts();
  }
  
  void _loadCategoryCounts() async {
    try {
      final userService = Provider.of<UserService>(context, listen: false);
      final locationService = Provider.of<LocationService>(context, listen: false);
      final questionService = Provider.of<QuestionService>(context, listen: false);
      
      final filters = <String, dynamic>{
        'showNSFW': userService.showNSFWContent,
        'questionTypes': userService.enabledQuestionTypes,
        'userCountry': locationService.userLocation?['country_code'],
        'userCity': locationService.selectedCity?['id'],
      };
      
      final categoryCounts = await questionService.getCurrentFeedCategoryCounts(
        feedType: 'trending', // Default to trending for new questions
        filters: filters,
      );
      
      if (mounted) {
        setState(() {
          _categoryCounts = categoryCounts;
          _categoryCountsLoaded = true;
        });
      }
    } catch (e) {
      print('Error loading category counts: $e');
      if (mounted) {
        setState(() {
          _categoryCountsLoaded = true; // Still mark as loaded even if failed
        });
      }
    }
  }

  @override
  void dispose() {
    _titleFocusNode.removeListener(_onTitleFocusChange);
    _descriptionFocusNode.removeListener(_onDescriptionFocusChange);
    _descriptionController.removeListener(() => _checkForCountryMentions(_descriptionController.text));
    _descriptionController.removeListener(_handleCountryAutocomplete);
    
    _titleController.dispose();
    _descriptionController.dispose();
    _newOptionController.dispose();
    _titleFocusNode.dispose();
    _descriptionFocusNode.dispose();
    
    // Dispose option controllers and focus nodes
    for (final controller in _optionControllers) {
      controller.dispose();
    }
    _optionControllers.clear();
    
    for (final focusNode in _optionFocusNodes) {
      focusNode.dispose();
    }
    _optionFocusNodes.clear();
    
    super.dispose();
  }

  void _onTitleFocusChange() {
    if (!_titleFocusNode.hasFocus) {
      _checkForProfanity();
    }
  }
  
  void _onDescriptionFocusChange() {
    if (!_descriptionFocusNode.hasFocus) {
      _checkForProfanity();
    }
  }
  
  void _checkForProfanity() {
    final titleHasProfanity = _profanityFilter.containsProfanity(_titleController.text);
    final descriptionHasProfanity = _profanityFilter.containsProfanity(_descriptionController.text);
    
    // Check for profanity in multiple choice options
    bool optionsHaveProfanity = false;
    for (final controller in _optionControllers) {
      if (_profanityFilter.containsProfanity(controller.text)) {
        optionsHaveProfanity = true;
        break;
      }
    }
    
    // Also check current option being added
    final newOptionHasProfanity = _newOption.isNotEmpty && _profanityFilter.containsProfanity(_newOption);
    
    final hasProfanity = titleHasProfanity || descriptionHasProfanity || optionsHaveProfanity || newOptionHasProfanity;
    
    if (hasProfanity != _profanityDetected) {
      setState(() {
        _profanityDetected = hasProfanity;
        
        // If profanity is detected, force NSFW to be true
        if (hasProfanity) {
          _isNSFW = true;
        }
      });
      
      // Show a notification if profanity is detected
      if (hasProfanity && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Profanity detected. This question will be marked as NSFW.'),
            backgroundColor: Colors.orange,
            duration: Duration(seconds: 3),
          ),
        );
      }
    }
  }

  void _checkForCountryMentions(String text) async {
    final RegExp countryMentionRegex = RegExp(r'@([A-Za-z\s]+)');
    final matches = countryMentionRegex.allMatches(text);
    final mentionedCountries = <String>{};
    final locationService = Provider.of<LocationService>(context, listen: false);
    
    for (final match in matches) {
      final countryName = match.group(1)?.trim() ?? '';
      final searchResults = await locationService.searchCountries(countryName);
      if (searchResults.contains(countryName)) {
        mentionedCountries.add(countryName);
      }
    }
    
    if (mounted) {
      setState(() {
        _mentionedCountries = mentionedCountries.toList();
      });
    }
  }

  void _searchCountriesForAutocomplete(String mentionText, int mentionStart) async {
    final locationService = Provider.of<LocationService>(context, listen: false);
    final suggestions = await locationService.searchCountries(mentionText);
    
    if (mounted) {
      setState(() {
        _mentionStartPosition = mentionStart;
        _currentMentionText = mentionText;
        _countrySuggestions = suggestions.take(5).toList(); // Limit to 5 suggestions
        _showCountrySuggestions = mentionText.isNotEmpty && suggestions.isNotEmpty;
      });
    }
  }

  void _handleCountryAutocomplete() {
    final text = _descriptionController.text;
    final cursorPosition = _descriptionController.selection.baseOffset;
    
    // Check if there's already a country mention in the text
    final RegExp countryMentionRegex = RegExp(r'@([A-Za-z\s]+)');
    final existingMentions = countryMentionRegex.allMatches(text);
    
    // Find if we're currently in a mention (after @)
    int mentionStart = -1;
    for (int i = cursorPosition - 1; i >= 0; i--) {
      if (text[i] == '@') {
        // Check if this @ is part of an existing complete mention
        bool isPartOfExistingMention = false;
        for (final match in existingMentions) {
          if (i >= match.start && i <= match.end) {
            isPartOfExistingMention = true;
            break;
          }
        }
        
        // If this is a new @ (not part of existing mention) and we already have mentions, show warning
        if (!isPartOfExistingMention && existingMentions.isNotEmpty) {
          // Show popup warning
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _showSingleTagWarning();
          });
          return;
        }
        
        mentionStart = i;
        break;
      } else if (text[i] == ' ' || text[i] == '\n') {
        // Hit whitespace before @, not in a mention
        break;
      }
    }
    
    if (mentionStart != -1) {
      // We're in a mention, get the text after @
      final mentionText = text.substring(mentionStart + 1, cursorPosition);
      
      // Check if we already have a completed country mention and this is a new one
      final completedMentions = _mentionedCountries.length;
      final isNewMention = !existingMentions.any((match) => 
        mentionStart >= match.start && mentionStart <= match.end);
      
      if (completedMentions > 0 && isNewMention) {
        // Show popup warning and don't show suggestions
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _showSingleTagWarning();
        });
        return;
      }
      
      // Search for countries
      _searchCountriesForAutocomplete(mentionText, mentionStart);
    } else {
      // Not in a mention, hide suggestions
      setState(() {
        _showCountrySuggestions = false;
        _mentionStartPosition = -1;
        _currentMentionText = '';
        _countrySuggestions = [];
      });
    }
  }
  
  void _showSingleTagWarning() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Single Country Tag Only'),
        content: Text(
          'You can only mention one country per question. Please remove the existing @country tag if you want to mention a different country.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text('Got it!'),
          ),
        ],
      ),
    );
  }

  void _selectCountryFromAutocomplete(String countryName) {
    final text = _descriptionController.text;
    final cursorPosition = _descriptionController.selection.baseOffset;
    
    // Replace the current mention text with the selected country
    final beforeMention = text.substring(0, _mentionStartPosition + 1); // Include @
    final afterMention = text.substring(cursorPosition);
    final newText = '$beforeMention$countryName $afterMention'; // Add space after country
    
    // Update the text and cursor position
    final newCursorPosition = beforeMention.length + countryName.length + 1; // +1 for the space
    
    _descriptionController.text = newText;
    _descriptionController.selection = TextSelection.fromPosition(
      TextPosition(offset: newCursorPosition),
    );
    
    // Hide suggestions
    setState(() {
      _showCountrySuggestions = false;
      _mentionStartPosition = -1;
      _currentMentionText = '';
      _countrySuggestions = [];
    });
    
    // Trigger country mentions check
    _checkForCountryMentions(newText);
  }

  void _addOption() {
    if (_newOption.trim().isEmpty || _options.length >= 6) return;
    
    // Check for profanity in the new option
    if (_profanityFilter.containsProfanity(_newOption)) {
      // Update profanity detection state
      _checkForProfanity();
    }
    
    setState(() {
      _options.add(_newOption.trim());
      // Create a new controller and focus node for this option
      final controller = TextEditingController(text: _newOption.trim());
      controller.addListener(_checkForProfanity);
      _optionControllers.add(controller);
      
      final focusNode = FocusNode();
      _optionFocusNodes.add(focusNode);
      
      _newOption = '';
    });
    
    // Clear the text field
    _newOptionController.clear();
  }

  void _removeOption(int index) {
    setState(() {
      _options.removeAt(index);
      // Dispose and remove the corresponding controller and focus node
      _optionControllers[index].dispose();
      _optionControllers.removeAt(index);
      
      _optionFocusNodes[index].dispose();
      _optionFocusNodes.removeAt(index);
      
      // Focus node cleanup handled above
    });
  }

  void _toggleCategory(Category category) {
    setState(() {
      if (_selectedCategories.contains(category)) {
        _selectedCategories.remove(category);
      } else if (_selectedCategories.length < 5) {
        _selectedCategories.add(category);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'You can select up to five categories',
              style: TextStyle(color: Colors.white),
            ),
            backgroundColor: Colors.orange,
          ),
        );
      }
    });
  }

  bool _canPreview() {
    // Basic validation for preview
    if (_selectedType.isEmpty) return false;
    if (_titleController.text.trim().length < 10) return false;
    if (_selectedCategories.isEmpty) return false;
    
    // For multiple choice, check that we have at least 2 non-empty options
    if (_selectedType == 'multiple_choice') {
      final validOptions = _optionControllers
          .map((controller) => controller.text.trim())
          .where((text) => text.isNotEmpty)
          .length;
      if (validOptions < 2) return false;
    }
    
    // Check word count for title
    final wordCount = _titleController.text.trim().split(RegExp(r'\s+')).where((word) => word.isNotEmpty).length;
    if (wordCount > 30) return false;
    
    return true;
  }

  void _showPreview() {
    // Get current option values from controllers
    final currentOptions = _selectedType == 'multiple_choice' 
      ? _optionControllers.map((controller) => controller.text.trim()).where((text) => text.isNotEmpty).toList()
      : null;
      
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => QuestionPreviewScreen(
          title: _titleController.text.trim(),
          description: _descriptionController.text.trim().isNotEmpty ? _descriptionController.text.trim() : null,
          type: _selectedType,
          options: currentOptions,
          categories: _selectedCategories.map((c) => c.name).toList(),
          isNSFW: _isNSFW,
          mentionedCountries: _mentionedCountries.isNotEmpty ? _mentionedCountries : null,
          targeting: _selectedTargeting,
          isPrivate: _isPrivate,
          onSubmit: _submitQuestion,
        ),
      ),
    );
  }

  void _showPreviewRequirements() {
    List<String> missing = [];
    
    if (_selectedType.isEmpty) {
      missing.add('• Select a question type');
    }
    
    if (_titleController.text.trim().length < 10) {
      missing.add('• Question must be at least 10 characters long');
    }
    
    // Check word count for title
    final wordCount = _titleController.text.trim().split(RegExp(r'\s+')).where((word) => word.isNotEmpty).length;
    if (wordCount > 30) {
      missing.add('• Question must be 30 words or less (currently $wordCount words)');
    }
    
    if (_selectedCategories.isEmpty) {
      missing.add('• Select at least one category');
    }
    
    if (_selectedType == 'multiple_choice') {
      final validOptions = _optionControllers
          .map((controller) => controller.text.trim())
          .where((text) => text.isNotEmpty)
          .length;
      if (validOptions < 2) {
        missing.add('• Add at least 2 answer options for multiple choice');
      }
    }
    
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Incomplete Question!'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'To submit your question, please complete the following:',
              style: TextStyle(fontWeight: FontWeight.w500),
            ),
            SizedBox(height: 12),
            ...missing.map((item) => Padding(
              padding: EdgeInsets.only(bottom: 4),
              child: Text(
                item,
                style: TextStyle(color: Colors.orange, fontSize: 14),
              ),
            )),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text('Got it!'),
          ),
        ],
      ),
    );
  }

  Future<void> _navigateToAnswerScreen(Map<String, dynamic> question, {Future<List<Map<String, dynamic>>>? trendingFeedFuture}) async {
    // Dismiss any active keyboards before navigation
    FocusScope.of(context).unfocus();

    // Build FeedContext from trending feed if available
    FeedContext? feedContext;
    if (trendingFeedFuture != null) {
      try {
        final trendingQuestions = await trendingFeedFuture;
        if (trendingQuestions.isNotEmpty) {
          final questionId = question['id']?.toString();
          final deduped = trendingQuestions
              .where((q) => q['id']?.toString() != questionId)
              .toList();

          feedContext = FeedContext(
            feedType: 'trending',
            filters: {},
            questions: <Map<String, dynamic>>[question, ...deduped],
            currentQuestionIndex: 0,
            originalQuestionId: questionId,
            originalQuestionIndex: 0,
          );
        }
      } catch (_) {
        // Navigate without feedContext on failure
      }
    }

    Widget answerScreen;

    switch (question['type']) {
      case 'approval_rating':
        answerScreen = AnswerApprovalScreen(question: question, feedContext: feedContext);
        break;
      case 'multiple_choice':
        answerScreen = AnswerMultipleChoiceScreen(question: question, feedContext: feedContext);
        break;
      case 'text':
        answerScreen = AnswerTextScreen(question: question, feedContext: feedContext);
        break;
      default:
        // Fallback to approval screen
        answerScreen = AnswerApprovalScreen(question: question, feedContext: feedContext);
    }

    // Navigate to answer screen but preserve main screen in stack
    // Remove only the new question screen and question preview screen
    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(builder: (context) => answerScreen),
      (route) => route.settings.name == '/' || route.settings.name == '/main', // Keep main screen
    );
  }

  Future<String?> _submitQuestion() async {
    if (!_formKey.currentState!.validate()) return null;

    // Check if user selected a question type
    if (_selectedType.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Please select a question type'),
          backgroundColor: Colors.orange,
        ),
      );
      return null;
    }

    // Authentication and city checks are now handled by the main screen before navigation
    // No need to check again here

    if (_selectedCategories.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Please select at least one category')),
      );
      return null;
    }
    if (_selectedType == 'multiple_choice') {
      final validOptions = _optionControllers
          .map((controller) => controller.text.trim())
          .where((text) => text.isNotEmpty)
          .length;
      if (validOptions < 2) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Please add at least two options')),
        );
        return null;
      }
    }

    final locationService = Provider.of<LocationService>(context, listen: false);
    if (!locationService.hasLocation) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Please set your location in Settings before posting'),
          action: SnackBarAction(
            label: 'Set Location',
            onPressed: () {
              Navigator.pushNamed(context, '/settings');
            },
          ),
        ),
      );
      return null;
    }

    // Final check for profanity before submitting
    _checkForProfanity();

    setState(() {
      _isSubmitting = true;
    });

    try {
      // Get user's country from location service
      final countryCode = locationService.userLocation?['country_code'] ?? 'US';
      
      // Get city ID if targeting is set to city
      String? cityId;
      if (_selectedTargeting == 'city') {
        if (locationService.selectedCity == null) {
          // User selected city targeting but has no city set
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Please set your city in Settings to target local audience'),
              backgroundColor: Colors.orange,
              action: SnackBarAction(
                label: 'Set City',
                onPressed: () {
                  Navigator.pushNamed(context, '/settings');
                },
              ),
            ),
          );
          setState(() {
            _isSubmitting = false;
          });
          return null;
        }
        
        // Validate city data and extract ID
        final cityData = locationService.selectedCity!;
        cityId = cityData['id']?.toString();
        
        print('City targeting selected. City data: $cityData');
        print('Extracted cityId: $cityId');
        
        // Additional validation for city ID
        if (cityId == null || cityId.isEmpty) {
          print('Error: City ID is null or empty. Full city data: $cityData');
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Error: City data is invalid. Please reselect your city in Settings.'),
              backgroundColor: Colors.red,
              action: SnackBarAction(
                label: 'Fix City',
                onPressed: () {
                  Navigator.pushNamed(context, '/settings');
                },
              ),
            ),
          );
          setState(() {
            _isSubmitting = false;
          });
          return null;
        }
        
        // Validate UUID format (basic check)
        final uuidRegex = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$', caseSensitive: false);
        if (!uuidRegex.hasMatch(cityId)) {
          print('Error: City ID is not a valid UUID format: $cityId');
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Error: Invalid city ID format. Please reselect your city.'),
              backgroundColor: Colors.red,
              action: SnackBarAction(
                label: 'Fix City',
                onPressed: () {
                  Navigator.pushNamed(context, '/settings');
                },
              ),
            ),
          );
          setState(() {
            _isSubmitting = false;
          });
          return null;
        }
      }
      
      // Get current option values from controllers
      final currentOptions = _selectedType == 'multiple_choice' 
        ? _optionControllers.map((controller) => controller.text.trim()).where((text) => text.isNotEmpty).toList()
        : null;
      
      // Submit question to database using QuestionService
      final questionService = Provider.of<QuestionService>(context, listen: false);
      final submittedQuestion = await questionService.submitQuestion(
        title: _titleController.text,
        description: _descriptionController.text.isNotEmpty ? _descriptionController.text : null,
        type: _selectedType,
        options: currentOptions,
        countryCode: countryCode,
        categories: _selectedCategories.map((c) => c.name).toList(),
        isNSFW: _isNSFW,
        mentionedCountries: _mentionedCountries.isNotEmpty ? _mentionedCountries : null,
        targeting: _selectedTargeting,
        cityId: cityId,
        isPrivate: _isPrivate,
      );

      if (submittedQuestion != null) {
        // Kick off trending feed fetch in parallel with post-submission work
        final trendingFeedFuture = questionService.fetchOptimizedFeed(
          feedType: 'trending',
          limit: 50,
          useCache: false,
        ).catchError((_) => <Map<String, dynamic>>[]);

        // Haptic feedback on successful submission
        await AppHaptics.mediumImpact();

        // Check if this is the user's first question BEFORE adding to posted questions
        final userService = Provider.of<UserService>(context, listen: false);
        final isFirstQuestion = userService.postedQuestions.isEmpty;
        
        // Also add to user's posted questions for tracking
        userService.addPostedQuestion({
          'id': submittedQuestion['id'],
          'author_id': submittedQuestion['author_id'], // Include author_id for delete button
        'title': _titleController.text,
        'description': _descriptionController.text,
        'type': _selectedType,
          'options': currentOptions ?? [],
          'timestamp': submittedQuestion['created_at'],
        'votes': 0,
        'categories': _selectedCategories.map((c) => c.name).toList(),
        'isNSFW': _isNSFW,
          'mentioned_countries': _mentionedCountries,
        });

        // Show success message
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Question posted!'),
            backgroundColor: Theme.of(context).primaryColor,
          ),
        );
        
        // Track question asked event
        AnalyticsService().trackEvent('question_asked', {
          'question_id': submittedQuestion['id'],
          'question_type': _selectedType,
          'categories': _selectedCategories.map((c) => c.name).toList(),
          'targeting': _selectedTargeting,
          'is_private': _isPrivate,
          'is_nsfw': _isNSFW,
          'has_description': _descriptionController.text.isNotEmpty,
          'mentioned_countries_count': _mentionedCountries.length,
          'is_first_question': isFirstQuestion,
        });
        
        // Track feature adoption for question type
        AnalyticsService().trackQuestionTypeAdoption(_selectedType, {
          'is_first_question': isFirstQuestion,
          'targeting': _selectedTargeting,
        });
        
        // Track private question feature adoption if used
        if (_isPrivate) {
          AnalyticsService().trackPrivateQuestionAdoption({
            'question_type': _selectedType,
            'is_first_question': isFirstQuestion,
          });
        }

        // Trigger materialized view refresh for immediate feed updates
        try {
          await questionService.refreshMaterializedView();
        } catch (e) {
          print('Non-critical: Failed to refresh materialized view: $e');
          // Continue with normal flow even if refresh fails
        }

        // Check for congratulations prompt (every 2nd question + camo top 20)
        try {
          final achievementService = AchievementService(
            userService: userService,
            context: context,
          );
          await achievementService.init();

          final congratulationsService = CongratulationsService(
            userService: userService,
            achievementService: achievementService,
          );
          await congratulationsService.init();

          // Show congratulations if eligible (will handle cooldown logic internally)
          await congratulationsService.showCongratulationsIfEligible(
            context,
            AchievementType.firstQuestion,
          );

          // Also check for Camo Counter top 20 since posting questions affects ranking
          await congratulationsService.showCongratulationsIfEligible(
            context,
            AchievementType.camoTop20,
          );
        } catch (e) {
          print('Error showing congratulations: $e');
          // Don't let this error interrupt the normal flow
        }

        // Show notification dialog for first-time question posters
        if (isFirstQuestion) {
          // Show first-time notification dialog
          await FirstQuestionNotificationDialog.show(
            context,
            onCompleted: () {
              // Auto-subscribe to posted question after dialog completes
              AutoSubscriptionHelper.autoSubscribeToPostedQuestion(context, submittedQuestion);

              // Navigate to the appropriate answer screen
              _navigateToAnswerScreen(submittedQuestion, trendingFeedFuture: trendingFeedFuture);
            },
          );
        } else {
          // For subsequent questions, just auto-subscribe and navigate
          AutoSubscriptionHelper.autoSubscribeToPostedQuestion(context, submittedQuestion);

          // Navigate to the appropriate answer screen for the newly posted question
          _navigateToAnswerScreen(submittedQuestion, trendingFeedFuture: trendingFeedFuture);
        }
        
        // Return the question ID
        return submittedQuestion['id']?.toString();
      } else {
        throw Exception('Question submission returned null');
      }
    } catch (e) {
      print('Error submitting question: $e');
      
      // Handle specific database enum error for question type
      if (e.toString().contains('invalid input value for enum question_type') || 
          e.toString().contains('22P02')) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Please select a valid question type before submitting.'),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 4),
          ),
        );
      } else if (e.toString().contains('city_id is required when targeting_type is "city"')) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Please set your city to target local audience, or choose a different targeting option.'),
            backgroundColor: Colors.orange,
            duration: Duration(seconds: 4),
            action: SnackBarAction(
              label: 'Set City',
              onPressed: () {
                Navigator.pushNamed(context, '/settings');
              },
            ),
          ),
        );
      } else if (e.toString().contains('Invalid city_id') || e.toString().contains('city not found')) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('The selected city is invalid. Please reselect your city.'),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 4),
            action: SnackBarAction(
              label: 'Fix City',
              onPressed: () {
                Navigator.pushNamed(context, '/settings');
              },
            ),
          ),
        );
      } else if (e.toString().contains('violates foreign key constraint') && e.toString().contains('city')) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('City data error. Please refresh the app and reselect your city.'),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 4),
            action: SnackBarAction(
              label: 'Refresh',
              onPressed: () {
                // Clear location service cache and reload
                Provider.of<LocationService>(context, listen: false).refreshCities();
              },
            ),
          ),
        );
      } else if (e.toString().contains('prompt_length') || 
                 e.toString().contains('23514')) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Question title must be at least 10 characters long.'),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 4),
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error submitting question: ${e.toString()}'),
            backgroundColor: Colors.red,
          ),
        );
      }
      return null; // Return null on error
    } finally {
      setState(() {
        _isSubmitting = false;
      });
    }
    return null; // Fallback return
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('New Question'),
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: EdgeInsets.all(16.0),
          children: [
            Text(
              '🦎 Start the conversation',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            SizedBox(height: 8),
            TextFormField(
              controller: _titleController,
              focusNode: _titleFocusNode,
              decoration: InputDecoration(
                labelText: 'Question prompt',
                hintText: 'Enter your question',
              ),
              maxLines: null,
              maxLength: 140,
              keyboardType: TextInputType.multiline,
              textCapitalization: TextCapitalization.sentences,
              onChanged: (value) {
                setState(() {
                  // Trigger rebuild to update counter colors
                });
              },
              buildCounter: (context, {required currentLength, required isFocused, maxLength}) {
                return Text(
                  '$currentLength/$maxLength',
                  style: TextStyle(
                    fontSize: 12,
                    color: currentLength < 10 
                        ? Colors.orange 
                        : Theme.of(context).textTheme.bodySmall?.color,
                  ),
                );
              },
              validator: (value) {
                if (value == null || value.isEmpty) {
                  return 'Please enter a question';
                }
                if (value.trim().length < 10) {
                  return 'Question must be at least 10 characters long';
                }
                
                // Check word count (split by whitespace and filter out empty strings)
                final wordCount = value.trim().split(RegExp(r'\s+')).where((word) => word.isNotEmpty).length;
                if (wordCount > 30) {
                  return 'Question must be 30 words or less (currently $wordCount words)';
                }
                
                return null;
              },
            ),
            SizedBox(height: 24),
            
            // 2. Question Type
            Text(
              'Question Type',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Container(
                    height: 80,
                    child: ChoiceChip(
                      label: SizedBox(
                        width: double.infinity,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.check_box, 
                              size: 24,
                              color: _selectedType == 'multiple_choice' ? Colors.white : null,
                            ),
                            SizedBox(height: 4),
                            Text(
                              'Pick One',
                              style: TextStyle(
                                fontSize: 10, 
                                fontWeight: FontWeight.bold,
                                color: _selectedType == 'multiple_choice' ? Colors.white : null,
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ],
                        ),
                      ),
                      selected: _selectedType == 'multiple_choice',
                      showCheckmark: false,
                      onSelected: (selected) {
                        if (selected) {
                          setState(() {
                            _selectedType = 'multiple_choice';
                            // Clear default approval rating text if present
                            if (_descriptionController.text == '👎🏽 = against, 👍🏽 = for') {
                              _descriptionController.clear();
                            }
                          });
                        }
                      },
                      selectedColor: Theme.of(context).primaryColor,
                      padding: EdgeInsets.symmetric(vertical: 12, horizontal: 8),
                      materialTapTargetSize: MaterialTapTargetSize.padded,
                    ),
                  ),
                ),
                SizedBox(width: 8),
                Expanded(
                  child: Container(
                    height: 96,
                    child: ChoiceChip(
                      label: SizedBox(
                        width: double.infinity,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.thumbs_up_down, 
                              size: 24,
                              color: _selectedType == 'approval_rating' ? Colors.white : null,
                            ),
                            SizedBox(height: 4),
                            Text(
                              'Thumbs?',
                              style: TextStyle(
                                fontSize: 10, 
                                fontWeight: FontWeight.bold,
                                color: _selectedType == 'approval_rating' ? Colors.white : null,
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ],
                        ),
                      ),
                      selected: _selectedType == 'approval_rating',
                      showCheckmark: false,
                      onSelected: (selected) {
                        if (selected) {
                          setState(() {
                            _selectedType = 'approval_rating';
                            // Set default description text for approval rating
                            if (_descriptionController.text.isEmpty) {
                              _descriptionController.text = '👎🏽 = against, 👍🏽 = for';
                            }
                          });
                        }
                      },
                      selectedColor: Theme.of(context).primaryColor,
                      padding: EdgeInsets.symmetric(vertical: 12, horizontal: 8),
                      materialTapTargetSize: MaterialTapTargetSize.padded,
                    ),
                  ),
                ),
                SizedBox(width: 8),
                Expanded(
                  child: Container(
                    height: 80,
                    child: ChoiceChip(
                      label: SizedBox(
                        width: double.infinity,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.text_fields, 
                              size: 24,
                              color: _selectedType == 'text' ? Colors.white : null,
                            ),
                            SizedBox(height: 4),
                            Text(
                              'Text response',
                              style: TextStyle(
                                fontSize: 10, 
                                fontWeight: FontWeight.bold,
                                color: _selectedType == 'text' ? Colors.white : null,
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ],
                        ),
                      ),
                      selected: _selectedType == 'text',
                      showCheckmark: false,
                      onSelected: (selected) {
                        if (selected) {
                          setState(() {
                            _selectedType = 'text';
                            // Clear default approval rating text if present
                            if (_descriptionController.text == '👎🏽 = against, 👍🏽 = for') {
                              _descriptionController.clear();
                            }
                          });
                        }
                      },
                      selectedColor: Theme.of(context).primaryColor,
                      padding: EdgeInsets.symmetric(vertical: 12, horizontal: 8),
                      materialTapTargetSize: MaterialTapTargetSize.padded,
                    ),
                  ),
                ),
              ],
            ),
            
            // Question type explanation
            Container(
              margin: EdgeInsets.only(top: 8),
              padding: EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: Theme.of(context).dividerColor,
                ),
              ),
              child: Builder(
                builder: (context) {
                  String explanationText;
                  IconData explanationIcon;
                  Color explanationColor;
                  
                  switch (_selectedType) {
                    case 'approval_rating':
                      explanationText = 'A sliding scale...';
                      explanationIcon = Icons.thumbs_up_down;
                      explanationColor = Theme.of(context).primaryColor;
                      break;
                    case 'multiple_choice':
                      explanationText = 'If you had to choose... (multiple choice)';
                      explanationIcon = Icons.check_box;
                      explanationColor = Theme.of(context).primaryColor;
                      break;
                    case 'text':
                      explanationText = 'Nuanced. A blank canvas...';
                      explanationIcon = Icons.text_fields;
                      explanationColor = Theme.of(context).primaryColor;
                      break;
                    default:
                      explanationText = 'Select a question type above';
                      explanationIcon = Icons.info_outline;
                      explanationColor = Theme.of(context).primaryColor;
                  }
                  
                  return Row(
                    children: [
                      Icon(
                        explanationIcon,
                        size: 16,
                        color: explanationColor,
                      ),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          explanationText,
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: explanationColor,
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
            SizedBox(height: 24),
            
            // 3. Description
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextFormField(
                  controller: _descriptionController,
                  focusNode: _descriptionFocusNode,
                  decoration: InputDecoration(
                    labelText: 'Description (optional)',
                    hintText: 'Add more context to your question.',
                    helperText: _showCountrySuggestions 
                        ? 'Type to search countries...'
                        : _mentionedCountries.isNotEmpty 
                            ? 'Country tagged: ${_mentionedCountries.join(", ")}'
                            : 'Use @ to tag countries aside from your own (optional)',
                    helperStyle: TextStyle(
                      color: _showCountrySuggestions ? Theme.of(context).primaryColor : null,
                    ),
                    counterText: '', // Hide the default counter
                  ),
                  maxLines: null,
                  maxLength: 500,
                  keyboardType: TextInputType.multiline,
                  // Only auto-capitalize if it's not approval rating (which has default text)
                  textCapitalization: _selectedType != 'approval_rating' 
                      ? TextCapitalization.sentences 
                      : TextCapitalization.none,
                ),
                SizedBox(height: 4),
                Align(
                  alignment: Alignment.centerRight,
                  child: Text(
                    '${_descriptionController.text.length}/500',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: _descriptionController.text.length > 500 
                          ? Theme.of(context).colorScheme.error
                          : Theme.of(context).textTheme.bodySmall?.color,
                    ),
                  ),
                ),
              ],
            ),
            
            // Country autocomplete dropdown
            if (_showCountrySuggestions && _countrySuggestions.isNotEmpty)
              Container(
                margin: EdgeInsets.only(top: 4),
                decoration: BoxDecoration(
                  color: ThemeUtils.getDropdownBackgroundColor(context),
                  borderRadius: BorderRadius.circular(4),
                  boxShadow: ThemeUtils.getDropdownShadow(context),
                ),
                constraints: BoxConstraints(
                  maxHeight: 200,
                ),
                child: ListView.builder(
                  shrinkWrap: true,
                  padding: EdgeInsets.zero,
                  itemCount: _countrySuggestions.length,
                  itemBuilder: (context, index) {
                    return ListTile(
                      dense: true,
                      leading: Icon(Icons.flag, size: 16),
                      title: Text(_countrySuggestions[index]),
                      onTap: () => _selectCountryFromAutocomplete(_countrySuggestions[index]),
                    );
                  },
                ),
              ),
              
                          SizedBox(height: 24),
            
            // 4. Answer Options (if multiple choice)
            if (_selectedType == 'multiple_choice') ...[
              Row(
                children: [
                  Text(
                    'Answer Options',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  SizedBox(width: 8),
                  Container(
                    padding: EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: _options.length >= 2 
                          ? Theme.of(context).primaryColor.withOpacity(0.1)
                          : Colors.orange.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: _options.length >= 2 
                            ? Theme.of(context).primaryColor
                            : Colors.orange,
                        width: 1,
                      ),
                    ),
                    child: Text(
                      '${_options.length}/6',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: _options.length >= 2 
                            ? Theme.of(context).primaryColor
                            : Colors.orange,
                      ),
                    ),
                  ),
                ],
              ),
              SizedBox(height: 8),
              if (_options.length < 2)
                Container(
                  padding: EdgeInsets.all(12),
                  margin: EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: Colors.orange.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.orange.withOpacity(0.3)),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.info_outline, color: Colors.orange, size: 20),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Add at least 2 options (up to 6 total)',
                          style: TextStyle(
                            color: Colors.orange.shade700,
                            fontSize: 14,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              
              // Display existing options with better styling and drag-and-drop
              if (_options.isNotEmpty)
                ReorderableListView.builder(
                  shrinkWrap: true,
                  physics: NeverScrollableScrollPhysics(),
                  padding: EdgeInsets.zero,
                  itemCount: _options.length,
                  onReorder: (int oldIndex, int newIndex) {
                    setState(() {
                      if (oldIndex < newIndex) {
                        newIndex -= 1;
                      }
                      final String item = _options.removeAt(oldIndex);
                      final TextEditingController controller = _optionControllers.removeAt(oldIndex);
                      final FocusNode focusNode = _optionFocusNodes.removeAt(oldIndex);
                      _options.insert(newIndex, item);
                      _optionControllers.insert(newIndex, controller);
                      _optionFocusNodes.insert(newIndex, focusNode);
                    });
                  },
                  itemBuilder: (context, index) {
                    return Container(
                      key: ValueKey('option_$index'),
                      margin: EdgeInsets.only(bottom: 8),
                      constraints: BoxConstraints(
                        minHeight: 80, // Increase minimum height for better touch targets
                      ),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.surface,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: Theme.of(context).dividerColor,
                        ),
                      ),
                      child: Row(
                        children: [
                          // Leading circle with letter
                          Container(
                            margin: EdgeInsets.only(left: 16, right: 12),
                            width: 24,
                            height: 24,
                            decoration: BoxDecoration(
                              color: Theme.of(context).primaryColor,
                              shape: BoxShape.circle,
                            ),
                            child: Center(
                              child: Text(
                                String.fromCharCode(65 + index), // A, B, C, etc.
                                style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                          ),
                          // Expanded text field
                          Expanded(
                            child: Container(
                              alignment: Alignment.centerLeft,
                              child: TextField(
                                controller: _optionControllers[index],
                                focusNode: _optionFocusNodes[index],
                                style: TextStyle(fontSize: 16),
                                textAlign: TextAlign.left,
                                textAlignVertical: TextAlignVertical.center,
                                maxLines: null, // Allow multiple lines
                                minLines: 1,   // Start with single line
                                decoration: InputDecoration(
                                  border: InputBorder.none,
                                  hintText: 'Enter option ${String.fromCharCode(65 + index)}...',
                                  errorText: _profanityFilter.containsProfanity(_optionControllers[index].text)
                                      ? 'Please use appropriate language'
                                      : null,
                                  errorStyle: TextStyle(color: Colors.red, fontSize: 12),
                                  contentPadding: EdgeInsets.symmetric(vertical: 12, horizontal: 8),
                                  isDense: true,
                                ),
                                textCapitalization: TextCapitalization.sentences,
                                maxLength: 60,
                                onChanged: (value) {
                                  setState(() {
                                    _options[index] = value;
                                  });
                                },
                                onEditingComplete: () {
                                  _checkForProfanity();
                                },
                                buildCounter: (context, {required currentLength, required isFocused, maxLength}) {
                                  return null; // Remove counter from TextField
                                },
                              ),
                            ),
                          ),
                          // Trailing actions with drag handle
                          ReorderableDragStartListener(
                            index: index,
                            child: Container(
                              padding: EdgeInsets.all(8),
                              child: Icon(
                                Icons.drag_handle,
                                color: Theme.of(context).hintColor,
                              ),
                            ),
                          ),
                          // Delete button and character counter column
                          Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: Icon(Icons.close, color: Colors.red.shade400),
                                onPressed: () => _removeOption(index),
                                tooltip: 'Remove option',
                              ),
                              // No character counter on existing options
                            ],
                          ),
                        ],
                      ),
                    );
                  },
                ),
              
              // Add new option field
              if (_options.length < 6)
                Container(
                  margin: EdgeInsets.only(top: 8),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surface,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: Theme.of(context).primaryColor.withOpacity(0.3),
                      style: BorderStyle.solid,
                    ),
                  ),
                  child: ListTile(
                    contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                    leading: Container(
                      width: 24,
                      height: 24,
                      decoration: BoxDecoration(
                        color: Theme.of(context).primaryColor.withOpacity(0.3),
                        shape: BoxShape.circle,
                      ),
                      child: Center(
                        child: Text(
                          String.fromCharCode(65 + _options.length), // Next letter
                          style: TextStyle(
                            color: Theme.of(context).primaryColor,
                            fontWeight: FontWeight.bold,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ),
                                         title: TextField(
                       controller: _newOptionController,
                       decoration: InputDecoration(
                         hintText: 'Enter option ${String.fromCharCode(65 + _options.length)}...',
                         border: InputBorder.none,
                         errorText: _newOption.isNotEmpty && _profanityFilter.containsProfanity(_newOption)
                           ? 'Please use appropriate language'
                           : null,
                         errorStyle: TextStyle(color: Colors.red, fontSize: 12),
                       ),
                       textCapitalization: TextCapitalization.sentences,
                       onChanged: (value) {
                         setState(() {
                           _newOption = value;
                         });
                       },
                       onEditingComplete: () {
                         if (_newOption.isNotEmpty) {
                           _checkForProfanity();
                         }
                       },
                       onSubmitted: (_) => _addOption(),
                       maxLength: 60,
                       buildCounter: (context, {required currentLength, required isFocused, maxLength}) {
                         return null; // Remove counter from TextField
                       },
                     ),
                    trailing: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        _newOption.trim().isNotEmpty
                            ? IconButton(
                                icon: Icon(Icons.add_circle, color: Theme.of(context).primaryColor),
                                onPressed: _addOption,
                                tooltip: 'Add option',
                              )
                            : Icon(Icons.add_circle_outline, color: Colors.grey),
                        // Character counter positioned below the icon
                        if (_newOption.isNotEmpty)
                          Positioned(
                            bottom: -8,
                            right: 8,
                            child: Text(
                              '${_newOption.length}/60',
                              style: TextStyle(
                                fontSize: 9,
                                color: _newOption.length > 40 
                                    ? Colors.orange 
                                    : Colors.grey,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                )
              else
                Container(
                  padding: EdgeInsets.all(12),
                  margin: EdgeInsets.only(top: 8),
                  decoration: BoxDecoration(
                    color: Colors.blue.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.blue.withOpacity(0.3)),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.check_circle, color: Colors.blue, size: 20),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Maximum of 6 options reached',
                          style: TextStyle(
                            color: Colors.blue.shade700,
                            fontSize: 14,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
            SizedBox(height: 24),
            
            // 5. Audience (Who should see this question)
            Text(
              'Who should see this question?',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            SizedBox(height: 8),
            
            // Private question switch
            Container(
              margin: EdgeInsets.only(bottom: 16),
              padding: EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: _isPrivate 
                    ? Theme.of(context).primaryColor.withOpacity(0.1)
                    : Theme.of(context).colorScheme.surface,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: _isPrivate 
                      ? Theme.of(context).primaryColor.withOpacity(0.3)
                      : Theme.of(context).dividerColor,
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    _isPrivate ? Icons.lock : Icons.lock_open,
                    color: _isPrivate 
                        ? Theme.of(context).primaryColor 
                        : Theme.of(context).hintColor,
                    size: 20,
                  ),
                  SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Private Question',
                          style: TextStyle(
                            fontWeight: FontWeight.w500,
                            color: _isPrivate 
                                ? Theme.of(context).primaryColor 
                                : Theme.of(context).textTheme.bodyLarge?.color,
                          ),
                        ),
                        if (_isPrivate) ...[
                          SizedBox(height: 4),
                          Text(
                            'Only those with the link will be able to vote or see this question',
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: Theme.of(context).primaryColor.withOpacity(0.8),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  Switch(
                    value: _isPrivate,
                    onChanged: (bool value) {
                      setState(() {
                        _isPrivate = value;
                        // Set targeting to city when making private (for testing safety)
                        // Reset to global when turning off private mode
                        if (_isPrivate) {
                          _selectedTargeting = 'city';
                        } else {
                          _selectedTargeting = 'globe';
                        }
                      });
                    },
                    activeColor: Theme.of(context).primaryColor,
                  ),
                ],
              ),
            ),
            // Only show targeting chips if not private
            if (!_isPrivate)
              Consumer<LocationService>(
                builder: (context, locationService, child) {
                  final hasCountry = locationService.selectedCountry != null;
                  final hasCity = locationService.selectedCity != null;
                  final countryName = locationService.selectedCountry ?? 'My Country';
                  final cityName = locationService.selectedCity?['name'] ?? 'Set City';
                  
                  return Row(
                    children: [
                    Expanded(
                      child: Container(
                        height: 80,
                        child: ChoiceChip(
                          label: SizedBox(
                            width: double.infinity,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.public, 
                                  size: 24,
                                  color: _selectedTargeting == 'globe' ? Colors.white : null,
                                ),
                                SizedBox(height: 4),
                                Text(
                                  'The World',
                                  style: TextStyle(
                                    fontSize: 10, 
                                    fontWeight: FontWeight.bold,
                                    color: _selectedTargeting == 'globe' ? Colors.white : null,
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                              ],
                            ),
                          ),
                          selected: _selectedTargeting == 'globe',
                          showCheckmark: false,
                          onSelected: (selected) {
                            if (selected) {
                              setState(() => _selectedTargeting = 'globe');
                            }
                          },
                          selectedColor: Theme.of(context).primaryColor,
                          padding: EdgeInsets.symmetric(vertical: 12, horizontal: 8),
                          materialTapTargetSize: MaterialTapTargetSize.padded,
                        ),
                      ),
                    ),
                    SizedBox(width: 8),
                    Expanded(
                      child: Container(
                        height: 80,
                        child: ChoiceChip(
                          label: SizedBox(
                            width: double.infinity,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.flag, 
                                  size: 24,
                                  color: _selectedTargeting == 'country' ? Colors.white : null,
                                ),
                                SizedBox(height: 4),
                                Text(
                                  'My Country',
                                  style: TextStyle(
                                    fontSize: 10, 
                                    fontWeight: FontWeight.bold,
                                    color: _selectedTargeting == 'country' ? Colors.white : null,
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                              ],
                            ),
                          ),
                          selected: _selectedTargeting == 'country',
                          showCheckmark: false,
                          onSelected: hasCountry ? (selected) {
                            if (selected) {
                              setState(() => _selectedTargeting = 'country');
                            }
                          } : null,
                          selectedColor: Theme.of(context).primaryColor,
                          backgroundColor: hasCountry ? null : Colors.grey.shade200,
                          padding: EdgeInsets.symmetric(vertical: 12, horizontal: 8),
                          materialTapTargetSize: MaterialTapTargetSize.padded,
                        ),
                      ),
                    ),
                    SizedBox(width: 8),
                    Expanded(
                      child: Container(
                        height: 80,
                        child: Tooltip(
                          message: !hasCity ? 'Set your city in Settings to target local audience' : 'Target people in ${cityName}',
                          child: ChoiceChip(
                            label: SizedBox(
                              width: double.infinity,
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.location_city, 
                                    size: 24,
                                    color: _selectedTargeting == 'city' ? Colors.white : null,
                                  ),
                                  SizedBox(height: 4),
                                  Text(
                                    'My City',
                                    style: TextStyle(
                                      fontSize: 10, 
                                      fontWeight: FontWeight.bold,
                                      color: _selectedTargeting == 'city' ? Colors.white : null,
                                    ),
                                    textAlign: TextAlign.center,
                                  ),
                                ],
                              ),
                            ),
                            selected: _selectedTargeting == 'city',
                            showCheckmark: false,
                            onSelected: hasCity ? (selected) {
                              if (selected) {
                                setState(() => _selectedTargeting = 'city');
                              }
                            } : (selected) {
                              // Navigate to settings screen to set up city
                              Navigator.pushNamed(context, '/settings').then((_) {
                                // Show message about setting up city when they return
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text('Please set your city to target local audience'),
                                    backgroundColor: Colors.orange,
                                    duration: Duration(seconds: 3),
                                  ),
                                );
                              });
                            },
                            selectedColor: Theme.of(context).primaryColor,
                            backgroundColor: hasCity ? null : Colors.grey.shade200,
                            padding: EdgeInsets.symmetric(vertical: 12, horizontal: 8),
                            materialTapTargetSize: MaterialTapTargetSize.padded,
                            // Add a visual indicator when city is not set
                            side: !hasCity ? BorderSide(
                              color: Colors.grey.shade400,
                              style: BorderStyle.solid,
                              width: 1,
                            ) : null,
                          ),
                        ),
                      ),
                    ),
                    ],
                  );
                },
              ),
            
            // Targeting explanation
            Container(
              margin: EdgeInsets.only(top: 8),
              padding: EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: Theme.of(context).dividerColor,
                ),
              ),
              child: Consumer<LocationService>(
                builder: (context, locationService, child) {
                  IconData explanationIcon;
                  Color explanationColor;
                  Widget explanationWidget;
                  
                  // Show private explanation if private mode is enabled
                  if (_isPrivate) {
                    explanationIcon = Icons.lock;
                    explanationColor = Theme.of(context).primaryColor;
                    explanationWidget = RichText(
                      text: TextSpan(
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: explanationColor,
                        ),
                        children: [
                          TextSpan(text: 'This question will be '),
                          TextSpan(
                            text: 'private and only accessible via direct link',
                            style: TextStyle(fontWeight: FontWeight.bold),
                          ),
                          TextSpan(text: '. It won\'t appear in feeds or search results.'),
                        ],
                      ),
                    );
                  } else {
                    switch (_selectedTargeting) {
                    case 'globe':
                      explanationIcon = Icons.public;
                      explanationColor = Theme.of(context).primaryColor;
                      explanationWidget = RichText(
                        text: TextSpan(
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: explanationColor,
                          ),
                          children: [
                            TextSpan(text: 'Address your question to '),
                            TextSpan(
                              text: 'everyone in the world',
                              style: TextStyle(fontWeight: FontWeight.bold),
                            ),
                          ],
                        ),
                      );
                      break;
                    case 'country':
                      final countryName = locationService.selectedCountry ?? 'your country';
                      explanationIcon = Icons.flag;
                      explanationColor = Theme.of(context).primaryColor;
                      explanationWidget = RichText(
                        text: TextSpan(
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: explanationColor,
                          ),
                          children: [
                            TextSpan(text: 'Address your question to people in '),
                            TextSpan(
                              text: countryName,
                              style: TextStyle(fontWeight: FontWeight.bold),
                            ),
                          ],
                        ),
                      );
                      break;
                    case 'city':
                      final cityName = locationService.selectedCity?['name'] ?? 'your city';
                      final countryName = locationService.selectedCity?['country_name_en'] ?? 'your country';
                      explanationIcon = Icons.location_city;
                      explanationColor = Theme.of(context).primaryColor;
                      explanationWidget = RichText(
                        text: TextSpan(
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: explanationColor,
                          ),
                          children: [
                            TextSpan(text: 'Address your question to people near '),
                            TextSpan(
                              text: '$cityName',
                              style: TextStyle(fontWeight: FontWeight.bold),
                            ),
                          ],
                        ),
                      );
                      break;
                    default:
                      explanationIcon = Icons.info_outline;
                      explanationColor = Theme.of(context).primaryColor;
                      explanationWidget = Text(
                        'Select a targeting option above',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: explanationColor,
                        ),
                      );
                  }
                  }
                  
                  return Row(
                    children: [
                      Icon(
                        explanationIcon,
                        size: 16,
                        color: explanationColor,
                      ),
                      SizedBox(width: 8),
                      Expanded(
                        child: explanationWidget,
                      ),
                    ],
                  );
                },
              ),
            ),
            SizedBox(height: 24),
            
            // 6. Topics
            Text(
              'Topics (select 1–5)',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            SizedBox(height: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // First row: Always show Serious and Funny
                if (_categoryCountsLoaded) ...[
                  Wrap(
                    spacing: 8.0,
                    runSpacing: 8.0,
                    children: () {
                      final orderedCategories = Category.getOrderedCategoriesByStaticUsage();
                      final seriousAndFunny = orderedCategories.take(2).toList(); // Serious and Funny are always first
                      
                      return seriousAndFunny.map((category) {
                        final isSelected = _selectedCategories.contains(category);
                        
                        return FilterChip(
                          label: Text(
                            category.name,
                            style: TextStyle(
                              color: isSelected 
                                  ? Theme.of(context).colorScheme.onSurface
                                  : Theme.of(context).textTheme.bodyMedium?.color,
                            ),
                          ),
                          selected: isSelected,
                          onSelected: (selected) => _toggleCategory(category),
                          showCheckmark: false,
                          selectedColor: category.isNSFW 
                              ? Colors.red.withOpacity(0.2)
                              : Theme.of(context).primaryColor.withOpacity(0.2),
                          checkmarkColor: Theme.of(context).primaryColor,
                        );
                      }).toList();
                    }(),
                  ),
                  SizedBox(height: 8),
                  
                  // Remaining categories (top 13 more, or all if show more is enabled)
                  Wrap(
                    spacing: 8.0,
                    runSpacing: 8.0,
                    children: () {
                      final orderedCategories = Category.getOrderedCategoriesByStaticUsage();
                      final remainingCategories = orderedCategories.skip(2); // Skip Serious and Funny
                      final categoriesToShow = _showAllCategories 
                          ? remainingCategories.toList()
                          : remainingCategories.take(8).toList(); // Show 8 more (total 10)
                      
                      return categoriesToShow.map((category) {
                        final isSelected = _selectedCategories.contains(category);
                        
                        return FilterChip(
                          label: Text(
                            category.name,
                            style: TextStyle(
                              color: isSelected 
                                  ? Theme.of(context).colorScheme.onSurface
                                  : Theme.of(context).textTheme.bodyMedium?.color,
                            ),
                          ),
                          selected: isSelected,
                          onSelected: (selected) => _toggleCategory(category),
                          showCheckmark: false,
                          selectedColor: category.isNSFW 
                              ? Colors.red.withOpacity(0.2)
                              : Theme.of(context).primaryColor.withOpacity(0.2),
                          checkmarkColor: Theme.of(context).primaryColor,
                        );
                      }).toList();
                    }(),
                  ),
                  
                  // Show more/less button
                  if (Category.allCategories.length > 10) ...[
                    SizedBox(height: 8),
                    GestureDetector(
                      onTap: () {
                        setState(() {
                          _showAllCategories = !_showAllCategories;
                        });
                      },
                      child: Text(
                        _showAllCategories ? '(show less)' : '(show more)',
                        style: TextStyle(
                          color: Theme.of(context).primaryColor,
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                      ),
                    ),
                  ],
                ] else ...[
                  // Loading indicator
                  Container(
                    padding: EdgeInsets.all(16),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        SizedBox(width: 8),
                        Text(
                          'Loading categories...',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
            SizedBox(height: 24),
            SwitchListTile(
              title: Row(
                children: [
                  Text('NSFW content (18+)'),
                  if (_profanityDetected) ...[
                    SizedBox(width: 8),
                    Tooltip(
                      message: 'Profanity detected - this question must be marked as NSFW',
                      child: Icon(Icons.warning_amber_rounded, color: Colors.orange),
                    ),
                  ],
                ],
              ),
              subtitle: Text('This question is addressed to adults only'),
              value: _isNSFW,
              onChanged: (bool value) {
                // Only allow turning off NSFW if no profanity is detected
                if (_profanityDetected && !value) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Cannot disable NSFW flag because profanity was detected.'),
                      backgroundColor: Colors.orange,
                    ),
                  );
                  return;
                }
                setState(() {
                  _isNSFW = value;
                });
              },
            ),
            SizedBox(height: 24),
            GestureDetector(
              onTap: () {
                if (!_canPreview()) {
                  _showPreviewRequirements();
                }
              },
              child: ElevatedButton(
                onPressed: _canPreview() ? _showPreview : null,
                child: Text('See Preview'),
                style: ElevatedButton.styleFrom(
                  padding: EdgeInsets.symmetric(vertical: 16),
                  backgroundColor: Theme.of(context).primaryColor,
                  foregroundColor: Colors.white,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
