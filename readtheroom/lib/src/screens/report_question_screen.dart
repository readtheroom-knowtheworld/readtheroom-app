// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/user_service.dart';
import '../services/location_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class ReportQuestionScreen extends StatefulWidget {
  final Map<String, dynamic> question;

  const ReportQuestionScreen({
    Key? key,
    required this.question,
  }) : super(key: key);

  @override
  _ReportQuestionScreenState createState() => _ReportQuestionScreenState();
}

class _ReportQuestionScreenState extends State<ReportQuestionScreen> {
  final Set<String> _selectedReasons = {};
  final TextEditingController _otherReasonController = TextEditingController();
  bool _isSubmitting = false;
  static const int _maxReasons = 3;

  // Organized report reasons by category
  final Map<String, List<String>> _reportReasons = {
    'Quality Issues': [
      'Not a question',
      'Low quality',
      'Not categorized correctly',
      'Not marked as NSFW/18+',
      'Spam',
    ],
    'Content Violations': [
      'Profanity',
      'Offensive content',
      'Harassment or bullying',
      'Spreading misinformation',
      'Inciting violence',
      'Illegal content',
    ],
    'Other': [
      'Other',
    ],
  };

  void _toggleReason(String reason, bool? isSelected) {
    if (isSelected == null) return;

    setState(() {
      if (isSelected) {
        // Don't allow more than max selections
        if (_selectedReasons.length >= _maxReasons) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('You can select up to $_maxReasons reasons'),
              backgroundColor: Colors.orange,
            ),
          );
          return;
        }
        _selectedReasons.add(reason);
      } else {
        _selectedReasons.remove(reason);
      }
    });
  }

  void _submitReport() async {
    // Check if user is on cooldown
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

    // Validate selections
    if (_selectedReasons.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Please select at least one reason for reporting'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    if (_selectedReasons.contains('Other') && _otherReasonController.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Please provide details for "Other"'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    // Prepare report reasons
    final reasons = _selectedReasons.toList();
    if (_selectedReasons.contains('Other') && _otherReasonController.text.isNotEmpty) {
      reasons[reasons.indexOf('Other')] = 'Other: ${_otherReasonController.text}';
    }
    
    // Check if report contains only helpful reasons that shouldn't cause local hiding
    // Helpful reasons: categorization feedback that shouldn't penalize good samaritans
    final helpfulReasons = {'Not marked as NSFW/18+', 'Not categorized correctly'};
    final shouldHideLocally = reasons.any((reason) => !helpfulReasons.contains(reason));

    setState(() {
      _isSubmitting = true;
    });

    try {
      // Get user's location for the report
      final locationService = Provider.of<LocationService>(context, listen: false);
      final userLocation = locationService.userLocation;
      final selectedCity = locationService.selectedCity;
      
      // Get current user ID (null if not authenticated)
      final currentUser = Supabase.instance.client.auth.currentUser;
      
      // Submit report to database
      final reportData = {
        'question_id': widget.question['id'].toString(),
        'reasons': reasons, // Store as JSON array
      };
      
      // Add user ID if authenticated (for abuse prevention)
      if (currentUser != null) {
        reportData['user_id'] = currentUser.id;
      }
      
      // Add location data if available
      if (selectedCity != null) {
        reportData['city_id'] = selectedCity['id'];
        reportData['country_code'] = selectedCity['country_code'];
      } else if (userLocation != null && userLocation['country_code'] != null) {
        reportData['country_code'] = userLocation['country_code'];
      }
      
      print('Submitting report to database: $reportData');
      
      // Submit to Supabase
      await Supabase.instance.client
          .from('reports')
          .insert(reportData);
      
      print('Report submitted successfully to database');
      
      // Add the question to the local reported list only if it contains non-helpful reasons
      if (shouldHideLocally) {
        Provider.of<UserService>(context, listen: false)
            .reportQuestion(widget.question['id'].toString(), reasons);
      }

      // Display success message
      final reasonsText = reasons.join(', ');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Thank you for reporting this question and helping build a great community <3'),
          duration: Duration(seconds: 4),
          backgroundColor: Theme.of(context).primaryColor, // Teal color
        ),
      );

      // Navigate to home screen
      Future.delayed(Duration(milliseconds: 500), () {
        if (mounted) {
          Navigator.of(context).popUntil((route) => route.isFirst);
        }
      });
      
    } catch (e) {
      print('Error submitting report: $e');
      
      // Still add to local list even if database submission fails, but only for non-helpful reasons
      if (shouldHideLocally) {
        Provider.of<UserService>(context, listen: false)
            .reportQuestion(widget.question['id'].toString(), reasons);
      }
      
      // Show appropriate error message
      final errorMessage = shouldHideLocally 
          ? 'Report submitted locally. Network error prevented server submission.'
          : 'Report recorded locally. Network error prevented server submission.';
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(errorMessage),
          duration: Duration(seconds: 3),
          backgroundColor: Colors.orange,
        ),
      );
      
      // Still navigate back
      Future.delayed(Duration(milliseconds: 500), () {
        if (mounted) {
          Navigator.of(context).popUntil((route) => route.isFirst);
        }
      });
    } finally {
      if (mounted) {
        setState(() {
          _isSubmitting = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Report Question'),
      ),
      body: Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              padding: EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Card(
                    child: Padding(
                      padding: EdgeInsets.all(16.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Question:',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          SizedBox(height: 8),
                          Text(
                            widget.question['prompt'] ?? widget.question['title'] ?? 'No Title',
                            style: Theme.of(context).textTheme.bodyLarge,
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
                  ),
                  SizedBox(height: 24),
                  Text(
                    'Reason for report: (select up to $_maxReasons)',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  SizedBox(height: 8),
                  Text(
                    'Please select at least one reason',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  SizedBox(height: 16),
                  ..._reportReasons.entries.map((entry) {
                    final category = entry.key;
                    final reasons = entry.value;
                    
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: EdgeInsets.only(bottom: 8.0, top: category == 'Technical & Quality Issues' ? 0 : 16.0),
                          child: Text(
                            category,
                            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.bold,
                              color: Theme.of(context).primaryColor,
                            ),
                          ),
                        ),
                        ...reasons.map((reason) => CheckboxListTile(
                          title: Text(reason),
                          value: _selectedReasons.contains(reason),
                          onChanged: (isSelected) => _toggleReason(reason, isSelected),
                          activeColor: Theme.of(context).primaryColor,
                          checkColor: Colors.white,
                          dense: true,
                        )).toList(),
                      ],
                    );
                  }).toList(),
                  if (_selectedReasons.contains('Other')) ...[
                    SizedBox(height: 16),
                    TextField(
                      controller: _otherReasonController,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: InputDecoration(
                        labelText: 'Please specify reason',
                        border: OutlineInputBorder(),
                        helperText: 'Provide details for "Other" reason',
                      ),
                      maxLines: 3,
                    ),
                  ],
                  SizedBox(height: 32),
                ],
              ),
            ),
          ),
          // Button at the bottom
          Container(
            width: double.infinity,
            padding: EdgeInsets.all(16.0),
            decoration: BoxDecoration(
              color: Theme.of(context).scaffoldBackgroundColor,
              border: Border(
                top: BorderSide(
                  color: Theme.of(context).dividerColor,
                ),
              ),
            ),
            child: ElevatedButton(
              onPressed: _isSubmitting ? null : _submitReport,
              child: _isSubmitting
                ? SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                    ),
                  )
                : Text('Submit Report'),
              style: ElevatedButton.styleFrom(
                padding: EdgeInsets.symmetric(vertical: 16),
                backgroundColor: Colors.orange,
                foregroundColor: Colors.white,
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _otherReasonController.dispose();
    super.dispose();
  }
} 