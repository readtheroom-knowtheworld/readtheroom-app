// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../services/user_service.dart';
import '../services/location_service.dart';
import '../services/question_service.dart';
import '../models/category.dart';
import '../utils/time_utils.dart';
import '../widgets/question_type_badge.dart';
import '../utils/category_navigation.dart';

class QuestionPreviewScreen extends StatefulWidget {
  final String title;
  final String? description;
  final String type;
  final List<String>? options;
  final List<String> categories;
  final bool isNSFW;
  final List<String>? mentionedCountries;
  final String targeting;
  final bool isPrivate;
  final Future<String?> Function() onSubmit;

  const QuestionPreviewScreen({
    Key? key,
    required this.title,
    this.description,
    required this.type,
    this.options,
    required this.categories,
    required this.isNSFW,
    this.mentionedCountries,
    required this.targeting,
    required this.isPrivate,
    required this.onSubmit,
  }) : super(key: key);

  @override
  _QuestionPreviewScreenState createState() => _QuestionPreviewScreenState();
}

class _QuestionPreviewScreenState extends State<QuestionPreviewScreen> {
  bool _isSubmitting = false;
  String? _selectedOption;
  double _approvalValue = 0.0;
  final _textController = TextEditingController();
  String? _questionId;

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  void _handleSubmit() async {
    setState(() {
      _isSubmitting = true;
    });

    try {
      // Call the onSubmit callback and get the question ID
      final questionId = await widget.onSubmit();
      
      // If this is a private question and we got a question ID, copy the link to clipboard
      if (widget.isPrivate && questionId != null) {
        // Generate the share text exactly like the "Share" functionality
        final shareText = 'Check out this question on Read the Room:\n\n${widget.title}\n\nhttps://readtheroom.site/question/$questionId';
        
        // Copy to clipboard
        await Clipboard.setData(ClipboardData(text: shareText));
        
        // Show success message
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Row(
                children: [
                  Icon(Icons.check_circle, color: Colors.white),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text('Private question posted! Link copied to clipboard.'),
                  ),
                ],
              ),
              backgroundColor: Theme.of(context).primaryColor,
              duration: Duration(seconds: 3),
            ),
          );
        }
      }
    } catch (e) {
      setState(() {
        _isSubmitting = false;
      });
      // Error handling is done in the original submit method
    }
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
          value: _approvalValue,
          min: -1.0,
          max: 1.0,
          divisions: 100,
          onChanged: (value) {
            setState(() {
              _approvalValue = value;
            });
          },
        ),
        
        // Current selection icon
        SizedBox(height: 12),
        _getIconForValue(_approvalValue),
      ],
    );
  }

  String _getTargetingText() {
    if (widget.isPrivate) {
      return 'This is a private question. Only those with the link will be able to view or answer it';
    }
    
    final locationService = Provider.of<LocationService>(context, listen: false);
    
    switch (widget.targeting) {
      case 'globe':
        return 'Addressed to everyone in the world';
      case 'country':
        final countryName = locationService.selectedCountry ?? 'your country';
        return 'Addressed to people in $countryName';
      case 'city':
        final cityName = locationService.selectedCity?['name'] ?? 'your city';
        return 'Addressed to people in $cityName';
      default:
        return 'Addressed to everyone';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Preview Question'),
        backgroundColor: Colors.orange.withOpacity(0.1),
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: Column(
        children: [
          // Preview banner
          Container(
            width: double.infinity,
            padding: EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.orange.withOpacity(0.1),
              border: Border(
                bottom: BorderSide(
                  color: Colors.orange.withOpacity(0.3),
                  width: 1,
                ),
              ),
            ),
            child: Row(
              children: [
                Icon(Icons.preview, color: Colors.orange, size: 20),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'This is how your question will appear to others',
                    style: TextStyle(
                      color: Colors.orange.shade700,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
          
          Expanded(
            child: ListView(
              padding: EdgeInsets.all(16.0),
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
                            widget.title,
                            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          if (widget.description != null) ...[
                            SizedBox(height: 8),
                            Text(
                              widget.description!,
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                          ],
                        ],
                      ),
                    ),
                    SizedBox(width: 16),
                    QuestionTypeBadge(type: widget.type),
                  ],
                ),
                
                SizedBox(height: 16),
                
                // Categories and targeting info
                Wrap(
                  spacing: 8.0,
                  runSpacing: 8.0,
                  children: [
                    ...widget.categories.map((categoryName) {
                      return CategoryNavigation.buildClickableCategoryChip(
                        context,
                        categoryName,
                      );
                    }).toList(),
                    if (widget.isNSFW)
                      Chip(
                        label: Text('18+', style: TextStyle(fontSize: 12)),
                        backgroundColor: Colors.red.withOpacity(0.1),
                      ),
                  ],
                ),
                
                SizedBox(height: 8),
                Container(
                  padding: widget.isPrivate ? EdgeInsets.all(12) : EdgeInsets.zero,
                  decoration: widget.isPrivate ? BoxDecoration(
                    color: Theme.of(context).primaryColor.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: Theme.of(context).primaryColor.withOpacity(0.3),
                    ),
                  ) : null,
                  child: Row(
                    children: [
                      if (widget.isPrivate) ...[
                        Icon(
                          Icons.lock,
                          size: 16,
                          color: Theme.of(context).primaryColor,
                        ),
                        SizedBox(width: 8),
                      ],
                      Expanded(
                        child: Text(
                          _getTargetingText(),
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: widget.isPrivate 
                                ? Theme.of(context).primaryColor 
                                : Colors.grey[600],
                            fontStyle: widget.isPrivate ? FontStyle.normal : FontStyle.italic,
                            fontWeight: widget.isPrivate ? FontWeight.w500 : FontWeight.normal,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                
                SizedBox(height: 24),
                
                // Answer interface based on question type
                if (widget.type == 'approval_rating') ...[
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
                ] else if (widget.type == 'multiple_choice' && widget.options != null) ...[
                  Text(
                    'Choose one:',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  SizedBox(height: 16),
                  ...widget.options!.asMap().entries.map((entry) {
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
                        onChanged: (value) {
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
                ] else if (widget.type == 'text') ...[
                  Text(
                    'Your response:',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  SizedBox(height: 16),
                  TextField(
                    controller: _textController,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: InputDecoration(
                      hintText: 'Share your thoughts...',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    maxLines: 4,
                    maxLength: 500,
                  ),
                ],
              ],
            ),
          ),
          
          // Submit button
          Container(
            padding: EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              border: Border(
                top: BorderSide(
                  color: Theme.of(context).dividerColor,
                ),
              ),
            ),
            child: SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _isSubmitting ? null : _handleSubmit,
                child: _isSubmitting
                    ? SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                        ),
                      )
                    : Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (widget.isPrivate) ...[
                            Icon(Icons.lock, size: 18),
                            SizedBox(width: 8),
                          ],
                          Text(widget.isPrivate ? 'Post & Share Link' : 'Post Question'),
                        ],
                      ),
                style: ElevatedButton.styleFrom(
                  padding: EdgeInsets.symmetric(vertical: 16),
                  backgroundColor: Theme.of(context).primaryColor,
                  foregroundColor: Colors.white,
                  textStyle: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
} 