// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import '../country_approval_map.dart';
import 'onboarding_slide.dart';
import '../../services/country_service.dart';

class VotingSlide extends StatefulWidget {
  final VoidCallback onNext;

  const VotingSlide({Key? key, required this.onNext}) : super(key: key);

  @override
  _VotingSlideState createState() => _VotingSlideState();
}

class _VotingSlideState extends State<VotingSlide> {
  bool _isPreloading = true;

  @override
  void initState() {
    super.initState();
    _preloadCountryData();
  }

  Future<void> _preloadCountryData() async {
    try {
      await CountryService.preloadCountryMappings();
    } catch (e) {
      print('Error preloading country mappings: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isPreloading = false;
        });
      }
    }
  }

  // Hardcoded demonstration data for consistent onboarding experience
  List<Map<String, dynamic>> _getDemoResponseData() {
    return [
      // United States - Mixed but leaning positive
      {'country': 'United States', 'answer': 0.7},
      {'country': 'United States', 'answer': 0.5},
      {'country': 'United States', 'answer': 0.8},
      {'country': 'United States', 'answer': -0.6},
      {'country': 'United States', 'answer': 0.9},
      {'country': 'United States', 'answer': 0.4},
      {'country': 'United States', 'answer': -0.4},
      {'country': 'United States', 'answer': 0.6},
      
      // United Kingdom - Moderate optimism
      {'country': 'United Kingdom', 'answer': 0.5},
      {'country': 'United Kingdom', 'answer': 0.6},
      {'country': 'United Kingdom', 'answer': 0.3},
      {'country': 'United Kingdom', 'answer': 0.7},
      {'country': 'United Kingdom', 'answer': 0.4},
      {'country': 'United Kingdom', 'answer': -0.2},
      
      // Germany - Cautiously optimistic
      {'country': 'Germany', 'answer': 0.4},
      {'country': 'Germany', 'answer': 0.5},
      {'country': 'Germany', 'answer': 0.2},
      {'country': 'Germany', 'answer': 0.6},
      {'country': 'Germany', 'answer': 0.3},
      {'country': 'Germany', 'answer': 0.5},
      {'country': 'Germany', 'answer': 0.4},
      
      // France - Mixed views
      {'country': 'France', 'answer': 0.3},
      {'country': 'France', 'answer': -0.5},
      {'country': 'France', 'answer': 0.6},
      {'country': 'France', 'answer': 0.2},
      {'country': 'France', 'answer': -0.3},
      {'country': 'France', 'answer': 0.7},
      
      // Japan - Moderate optimism
      {'country': 'Japan', 'answer': 0.4},
      {'country': 'Japan', 'answer': 0.5},
      {'country': 'Japan', 'answer': 0.3},
      {'country': 'Japan', 'answer': 0.6},
      {'country': 'Japan', 'answer': 0.4},
      {'country': 'Japan', 'answer': 0.5},
      {'country': 'Japan', 'answer': 0.2},
      {'country': 'Japan', 'answer': 0.7},
      
      // Australia - High optimism
      {'country': 'Australia', 'answer': 0.8},
      {'country': 'Australia', 'answer': 0.9},
      {'country': 'Australia', 'answer': 0.7},
      {'country': 'Australia', 'answer': 0.6},
      {'country': 'Australia', 'answer': 0.8},
      {'country': 'Australia', 'answer': 0.5},
      
      // Canada - Very optimistic
      {'country': 'Canada', 'answer': 0.9},
      {'country': 'Canada', 'answer': 0.8},
      {'country': 'Canada', 'answer': 0.7},
      {'country': 'Canada', 'answer': 0.8},
      {'country': 'Canada', 'answer': 0.6},
      {'country': 'Canada', 'answer': 0.9},
      {'country': 'Canada', 'answer': 0.7},
      
      // Brazil - Energetic optimism
      {'country': 'Brazil', 'answer': 0.8},
      {'country': 'Brazil', 'answer': 0.9},
      {'country': 'Brazil', 'answer': 0.6},
      {'country': 'Brazil', 'answer': 0.7},
      {'country': 'Brazil', 'answer': 0.8},
      {'country': 'Brazil', 'answer': 0.5},
      {'country': 'Brazil', 'answer': 0.9},
      {'country': 'Brazil', 'answer': 0.7},
      {'country': 'Brazil', 'answer': 0.6},
      
      // India - Mixed but trending positive
      {'country': 'India', 'answer': 0.6},
      {'country': 'India', 'answer': 0.4},
      {'country': 'India', 'answer': 0.8},
      {'country': 'India', 'answer': 0.3},
      {'country': 'India', 'answer': 0.7},
      {'country': 'India', 'answer': 0.5},
      {'country': 'India', 'answer': 0.6},
      {'country': 'India', 'answer': 0.4},
      {'country': 'India', 'answer': 0.9},
      {'country': 'India', 'answer': 0.2},
      
      // China - Moderate views
      {'country': 'China', 'answer': 0.3},
      {'country': 'China', 'answer': 0.4},
      {'country': 'China', 'answer': 0.2},
      {'country': 'China', 'answer': 0.5},
      {'country': 'China', 'answer': 0.3},
      {'country': 'China', 'answer': 0.4},
      {'country': 'China', 'answer': 0.6},
      
      // Additional countries with various sentiments...
      {'country': 'Sweden', 'answer': 0.9},
      {'country': 'Norway', 'answer': 0.9},
      {'country': 'Netherlands', 'answer': 0.8},
      {'country': 'Spain', 'answer': 0.5},
      {'country': 'Italy', 'answer': 0.3},
      {'country': 'Mexico', 'answer': 0.6},
    ];
  }

  @override
  Widget build(BuildContext context) {
    return OnboardingSlide(
      title: "Chameleons Vote & Map Responses",
      description: "Other chameleons vote on behalf of the cities and countries they are a part of. When enough responses are collected, we can visualize how different regions feel about questions in real-time.",
      showCurio: true,
      onNext: widget.onNext,
      customContent: SingleChildScrollView(
        child: Container(
          padding: EdgeInsets.all(20),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Mock response distribution
              Container(
                width: double.infinity,
                padding: EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Theme.of(context).cardColor,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.grey[300]!),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.1),
                      blurRadius: 8,
                      offset: Offset(0, 2),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      "Are you liking the vibe so far?",
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    SizedBox(height: 16),
                    _buildResponseOption("Yes, absolutely!", 67, Colors.green),
                    SizedBox(height: 8),
                    _buildResponseOption("Maybe, depends", 23, Colors.orange),
                    SizedBox(height: 8),
                    _buildResponseOption("No, not really", 10, Colors.red),
                    SizedBox(height: 16),
                    Row(
                      children: [
                        Icon(Icons.people, size: 16, color: Colors.grey[600]),
                        SizedBox(width: 4),
                        Text(
                          "1,247 chameleons responded",
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context).brightness == Brightness.dark 
                                ? Colors.white70 
                                : Colors.black87,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    "🦎",
                    style: TextStyle(fontSize: 24),
                  ),
                  SizedBox(width: 8),
                  Text(
                    "Every voice counts!",
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w500,
                      color: Theme.of(context).primaryColor,
                    ),
                  ),
                ],
              ),
              
              SizedBox(height: 32),
              
              // Map section
              Text(
                "Global Response Map",
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
              ),
              SizedBox(height: 8),
              Text(
                "Questions with enough responses produce maps showing regional sentiment:",
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).brightness == Brightness.dark 
                      ? Colors.white70 
                      : Colors.black87,
                ),
                textAlign: TextAlign.center,
              ),
              SizedBox(height: 16),
              
              // Show loading while preloading country data
              _isPreloading
                  ? Container(
                      height: 300,
                      child: Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            CircularProgressIndicator(),
                            SizedBox(height: 16),
                            Text(
                              "Loading world map...",
                              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                color: Colors.grey[600],
                              ),
                            ),
                          ],
                        ),
                      ),
                    )
                  : CountryApprovalMap(
                      key: ValueKey('onboarding_demo_map'),
                      responsesByCountry: _getDemoResponseData(),
                      questionTitle: "How optimistic are you about the future?",
                    ),
              SizedBox(height: 20),
              Text(
                "Watch opinions flow across the globe",
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  fontStyle: FontStyle.italic,
                  color: Theme.of(context).brightness == Brightness.dark 
                      ? Colors.white70 
                      : Colors.black87,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildResponseOption(String text, int percentage, Color color) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Text(
                text,
                style: TextStyle(
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            Text(
              "$percentage%",
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),
          ],
        ),
        SizedBox(height: 4),
        LinearProgressIndicator(
          value: percentage / 100,
          backgroundColor: Colors.grey[200],
          valueColor: AlwaysStoppedAnimation<Color>(color),
        ),
      ],
    );
  }
}
