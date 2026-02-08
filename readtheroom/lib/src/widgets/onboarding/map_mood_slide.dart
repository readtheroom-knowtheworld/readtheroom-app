// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import '../country_approval_map.dart';
import 'onboarding_slide.dart';
import '../../services/country_service.dart';

class MapMoodSlide extends StatefulWidget {
  final VoidCallback onNext;

  const MapMoodSlide({Key? key, required this.onNext}) : super(key: key);

  @override
  _MapMoodSlideState createState() => _MapMoodSlideState();
}

class _MapMoodSlideState extends State<MapMoodSlide> {
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
      
      // South Korea - Tech optimism
      {'country': 'South Korea', 'answer': 0.7},
      {'country': 'South Korea', 'answer': 0.6},
      {'country': 'South Korea', 'answer': 0.8},
      {'country': 'South Korea', 'answer': 0.5},
      {'country': 'South Korea', 'answer': 0.7},
      {'country': 'South Korea', 'answer': 0.6},
      
      // Netherlands - High satisfaction
      {'country': 'Netherlands', 'answer': 0.8},
      {'country': 'Netherlands', 'answer': 0.7},
      {'country': 'Netherlands', 'answer': 0.9},
      {'country': 'Netherlands', 'answer': 0.6},
      {'country': 'Netherlands', 'answer': 0.8},
      
      // Sweden - Very optimistic
      {'country': 'Sweden', 'answer': 0.9},
      {'country': 'Sweden', 'answer': 0.8},
      {'country': 'Sweden', 'answer': 0.9},
      {'country': 'Sweden', 'answer': 0.7},
      {'country': 'Sweden', 'answer': 0.8},
      
      // Norway - Highly optimistic
      {'country': 'Norway', 'answer': 0.9},
      {'country': 'Norway', 'answer': 0.8},
      {'country': 'Norway', 'answer': 1.0},
      {'country': 'Norway', 'answer': 0.7},
      {'country': 'Norway', 'answer': 0.9},
      
      // Spain - Moderate optimism
      {'country': 'Spain', 'answer': 0.5},
      {'country': 'Spain', 'answer': 0.6},
      {'country': 'Spain', 'answer': 0.4},
      {'country': 'Spain', 'answer': 0.7},
      {'country': 'Spain', 'answer': 0.3},
      {'country': 'Spain', 'answer': 0.6},
      
      // Italy - Mixed feelings
      {'country': 'Italy', 'answer': 0.3},
      {'country': 'Italy', 'answer': -0.2},
      {'country': 'Italy', 'answer': 0.5},
      {'country': 'Italy', 'answer': 0.1},
      {'country': 'Italy', 'answer': 0.4},
      {'country': 'Italy', 'answer': -0.1},
      
      // Mexico - Resilient optimism
      {'country': 'Mexico', 'answer': 0.6},
      {'country': 'Mexico', 'answer': 0.7},
      {'country': 'Mexico', 'answer': 0.5},
      {'country': 'Mexico', 'answer': 0.8},
      {'country': 'Mexico', 'answer': 0.4},
      {'country': 'Mexico', 'answer': 0.6},
      {'country': 'Mexico', 'answer': 0.7},
      
      // Argentina - Cautious optimism
      {'country': 'Argentina', 'answer': 0.4},
      {'country': 'Argentina', 'answer': 0.3},
      {'country': 'Argentina', 'answer': 0.6},
      {'country': 'Argentina', 'answer': 0.2},
      {'country': 'Argentina', 'answer': 0.5},
      
      // South Africa - Mixed but hopeful
      {'country': 'South Africa', 'answer': 0.5},
      {'country': 'South Africa', 'answer': 0.3},
      {'country': 'South Africa', 'answer': 0.7},
      {'country': 'South Africa', 'answer': 0.4},
      {'country': 'South Africa', 'answer': 0.6},
      {'country': 'South Africa', 'answer': 0.2},
      
      // Egypt - Moderate views
      {'country': 'Egypt', 'answer': 0.3},
      {'country': 'Egypt', 'answer': 0.4},
      {'country': 'Egypt', 'answer': 0.2},
      {'country': 'Egypt', 'answer': 0.5},
      {'country': 'Egypt', 'answer': 0.1},
      
      // Turkey - Cautious
      {'country': 'Turkey', 'answer': 0.2},
      {'country': 'Turkey', 'answer': 0.3},
      {'country': 'Turkey', 'answer': 0.1},
      {'country': 'Turkey', 'answer': 0.4},
      {'country': 'Turkey', 'answer': 0.2},
      
      // Russia - More pessimistic
      {'country': 'Russia', 'answer': -0.2},
      {'country': 'Russia', 'answer': 0.1},
      {'country': 'Russia', 'answer': -0.1},
      {'country': 'Russia', 'answer': 0.2},
      {'country': 'Russia', 'answer': -0.3},
      {'country': 'Russia', 'answer': 0.0},
      
      // Venezuela - Economic concerns
      {'country': 'Venezuela', 'answer': -0.7},
      {'country': 'Venezuela', 'answer': -0.5},
      {'country': 'Venezuela', 'answer': -0.8},
      {'country': 'Venezuela', 'answer': -0.4},
      {'country': 'Venezuela', 'answer': -0.6},
      {'country': 'Venezuela', 'answer': -0.9},
      
      // Syria - Challenging times
      {'country': 'Syria', 'answer': -0.8},
      {'country': 'Syria', 'answer': -0.6},
      {'country': 'Syria', 'answer': -0.9},
      {'country': 'Syria', 'answer': -0.5},
      {'country': 'Syria', 'answer': -0.7},
      
      // Afghanistan - Difficult situation
      {'country': 'Afghanistan', 'answer': -0.9},
      {'country': 'Afghanistan', 'answer': -0.7},
      {'country': 'Afghanistan', 'answer': -0.8},
      {'country': 'Afghanistan', 'answer': -0.6},
      {'country': 'Afghanistan', 'answer': -0.9},
      
      // Yemen - Ongoing challenges
      {'country': 'Yemen', 'answer': -0.8},
      {'country': 'Yemen', 'answer': -0.7},
      {'country': 'Yemen', 'answer': -0.9},
      {'country': 'Yemen', 'answer': -0.5},
      
      // Lebanon - Economic crisis
      {'country': 'Lebanon', 'answer': -0.6},
      {'country': 'Lebanon', 'answer': -0.8},
      {'country': 'Lebanon', 'answer': -0.5},
      {'country': 'Lebanon', 'answer': -0.7},
      {'country': 'Lebanon', 'answer': -0.4},
      
      // Myanmar - Political instability
      {'country': 'Myanmar', 'answer': -0.7},
      {'country': 'Myanmar', 'answer': -0.6},
      {'country': 'Myanmar', 'answer': -0.8},
      {'country': 'Myanmar', 'answer': -0.5},
      
      // Belarus - Political tensions
      {'country': 'Belarus', 'answer': -0.5},
      {'country': 'Belarus', 'answer': -0.4},
      {'country': 'Belarus', 'answer': -0.6},
      {'country': 'Belarus', 'answer': -0.3},
      {'country': 'Belarus', 'answer': -0.7},
    ];
  }

  @override
  Widget build(BuildContext context) {
    return OnboardingSlide(
      title: "Map of Responses",
      description: "On Read the Room, we can all see how different cities and countries respond to questions in real-time.\n\nAny questions with enough responses will produce a map that summarize the results, providing a snapshot of the world's sentiment. Here's an example:",
      showCurio: true,
      onNext: widget.onNext,
      customContent: Container(
        padding: EdgeInsets.all(20),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
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
    );
  }
}
