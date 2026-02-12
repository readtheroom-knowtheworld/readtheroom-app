// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../services/location_service.dart';
import '../../services/user_service.dart';
import '../../services/analytics_service.dart';
import '../../screens/authentication_screen.dart';
import '../../utils/generation_utils.dart';
import '../location_settings_widget.dart';
import 'onboarding_slide.dart';

class LocationSetupSlide extends StatefulWidget {
  final VoidCallback onComplete;
  final String? triggeredFrom;

  const LocationSetupSlide({
    Key? key,
    required this.onComplete,
    this.triggeredFrom,
  }) : super(key: key);

  @override
  _LocationSetupSlideState createState() => _LocationSetupSlideState();
}

class _LocationSetupSlideState extends State<LocationSetupSlide> {
  bool _showAuthentication = false;
  bool _locationSetupCompleted = false;
  String? _selectedGeneration;

  @override
  void initState() {
    super.initState();
    _checkAuthenticationStatus();

    // Check initial location setup after build is complete
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkInitialLocationSetup();
      // Load existing generation if set
      final userService = Provider.of<UserService>(context, listen: false);
      if (userService.hasGeneration) {
        setState(() {
          _selectedGeneration = userService.generation;
        });
      }
    });
  }

  void _checkAuthenticationStatus() {
    if (Supabase.instance.client.auth.currentUser == null) {
      setState(() {
        _showAuthentication = true;
      });
    }
  }

  void _checkInitialLocationSetup() {
    final locationService = Provider.of<LocationService>(context, listen: false);

    final hasCountry = locationService.selectedCountry != null;
    final hasCity = locationService.selectedCity != null;
    final isCompleted = hasCountry && hasCity;

    print('🦎 LOCATION_SETUP: Initial check - country: ${hasCountry ? locationService.selectedCountry : "null"}, city: ${hasCity ? (locationService.selectedCity?['name'] ?? "null") : "null"}, completed: $isCompleted');

    // Check if user already has both country and city set
    if (isCompleted && !_locationSetupCompleted) {
      print('🦎 LOCATION_SETUP: Setting completed to true');
      setState(() {
        _locationSetupCompleted = true;
      });
    } else if (!isCompleted && _locationSetupCompleted) {
      print('🦎 LOCATION_SETUP: Setting completed to false');
      setState(() {
        _locationSetupCompleted = false;
      });
    }
  }

  void _onAuthComplete() {
    setState(() {
      _showAuthentication = false;
    });
  }

  void _onLocationChanged() {
    final locationService = Provider.of<LocationService>(context, listen: false);

    final hasCountry = locationService.selectedCountry != null;
    final hasCity = locationService.selectedCity != null;
    final isCompleted = hasCountry && hasCity;

    print('🦎 LOCATION_SETUP: Location changed - country: ${hasCountry ? locationService.selectedCountry : "null"}, city: ${hasCity ? (locationService.selectedCity?['name'] ?? "null") : "null"}, completed: $isCompleted');

    // Check if user has set both country and city
    if (isCompleted && !_locationSetupCompleted) {
      print('🦎 LOCATION_SETUP: Location change - setting completed to true');
      setState(() {
        _locationSetupCompleted = true;
      });
    } else if (!isCompleted && _locationSetupCompleted) {
      print('🦎 LOCATION_SETUP: Location change - setting completed to false');
      setState(() {
        _locationSetupCompleted = false;
      });
    }
  }

  bool get _isFullyCompleted => _locationSetupCompleted && _selectedGeneration != null;

  Future<void> _completeSetup() async {
    final locationService = Provider.of<LocationService>(context, listen: false);
    final userService = Provider.of<UserService>(context, listen: false);

    print('🦎 LOCATION_SETUP: _completeSetup() called - country: ${locationService.selectedCountry}, city: ${locationService.selectedCity?['name']}, generation: $_selectedGeneration');

    // Save generation
    if (_selectedGeneration != null) {
      await userService.setGeneration(_selectedGeneration);
    }

    // Track completion
    AnalyticsService().trackOnboardingStep('location_setup_completed', 12, {
      'country': locationService.selectedCountry,
      'city': locationService.selectedCity?['name'],
      'has_city': locationService.selectedCity != null,
      'generation': _selectedGeneration,
      'triggered_from': widget.triggeredFrom ?? 'unknown',
    });

    // Track generation selection
    if (_selectedGeneration != null) {
      AnalyticsService().trackEvent('generation_selected', {
        'generation': _selectedGeneration,
        'source': 'onboarding',
      });
    }

    print('🦎 LOCATION_SETUP: Calling widget.onComplete()');
    widget.onComplete();
  }

  @override
  Widget build(BuildContext context) {
    if (_showAuthentication) {
      return AuthenticationScreen(
        onAuthComplete: _onAuthComplete,
      );
    }

    return Consumer<LocationService>(
      builder: (context, locationService, child) {
        // Update completion state based on current location service state
        final hasCountry = locationService.selectedCountry != null;
        final hasCity = locationService.selectedCity != null;
        final shouldBeCompleted = hasCountry && hasCity;

        // Update completion state if needed
        if (shouldBeCompleted != _locationSetupCompleted) {
          print('🦎 LOCATION_SETUP: Consumer update - country: ${hasCountry ? locationService.selectedCountry : "null"}, city: ${hasCity ? (locationService.selectedCity?['name'] ?? "null") : "null"}, should be completed: $shouldBeCompleted');
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              setState(() {
                _locationSetupCompleted = shouldBeCompleted;
              });
            }
          });
        }

        print('🦎 LOCATION_SETUP: Consumer render - completion state: $_locationSetupCompleted, generation: $_selectedGeneration, button enabled: ${_isFullyCompleted ? 'YES' : 'NO'}');

        return OnboardingSlide(
          title: "Ready to get started?",
          description: "Set up your location and generation so you can compare answers across cities and age groups.",
          showCurio: true,
          onNext: _isFullyCompleted ? _completeSetup : null,
          buttonText: "Let's go! 🚀",
          customContent: Container(
            padding: EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LocationSettingsWidget(
                  showTitle: false,
                  showDescription: true,
                  showGuidancePrompts: true,
                  onLocationChanged: _onLocationChanged,
                ),
                SizedBox(height: 24),
                Text(
                  'Your generation',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  'Compare answers between generations',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Colors.grey[600],
                  ),
                ),
                SizedBox(height: 16),
                Text(
                  'Your answers are tied to your city and generation — not to you.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Colors.grey[600],
                  ),
                ),
                SizedBox(height: 16),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final chipWidth = (constraints.maxWidth - 8) / 2;
                    return Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: generations.map((gen) {
                        final isSelected = _selectedGeneration == gen.id;
                        return SizedBox(
                          width: chipWidth,
                          child: ChoiceChip(
                            label: SizedBox(
                              width: double.infinity,
                              child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(gen.label),
                                Text(
                                  gen.years ?? ' ',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: gen.years != null
                                        ? (isSelected ? Colors.white70 : Colors.grey[500])
                                        : Colors.transparent,
                                  ),
                                ),
                              ],
                            ),
                            ),
                            selected: isSelected,
                            showCheckmark: false,
                            onSelected: (selected) {
                              setState(() {
                                _selectedGeneration = selected ? gen.id : null;
                              });
                            },
                            selectedColor: Theme.of(context).primaryColor,
                            labelStyle: TextStyle(
                              color: isSelected ? Colors.white : null,
                            ),
                          ),
                        );
                      }).toList(),
                    );
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
