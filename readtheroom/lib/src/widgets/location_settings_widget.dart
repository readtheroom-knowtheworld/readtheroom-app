// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../services/location_service.dart';
import '../services/user_service.dart';
import '../utils/theme_utils.dart';
import '../screens/authentication_screen.dart';

class LocationSettingsWidget extends StatefulWidget {
  final bool showTitle;
  final bool showDescription;
  final bool showGuidancePrompts;
  final VoidCallback? onLocationChanged;

  const LocationSettingsWidget({
    Key? key,
    this.showTitle = true,
    this.showDescription = true,
    this.showGuidancePrompts = true,
    this.onLocationChanged,
  }) : super(key: key);

  @override
  _LocationSettingsWidgetState createState() => _LocationSettingsWidgetState();
}

class _LocationSettingsWidgetState extends State<LocationSettingsWidget> {
  final TextEditingController _locationController = TextEditingController();
  final TextEditingController _cityController = TextEditingController();
  final FocusNode _countryFocusNode = FocusNode();
  final FocusNode _cityFocusNode = FocusNode();
  
  List<String> _suggestions = [];
  List<Map<String, dynamic>> _citySuggestions = [];
  bool _showSuggestions = false;
  bool _showCitySuggestions = false;
  bool _isInitialized = false;
  bool _countryFocused = false;
  bool _cityFocused = false;

  @override
  void initState() {
    super.initState();
    _initializeLocationService();
    
    // Listen to focus changes
    _countryFocusNode.addListener(() {
      setState(() {
        _countryFocused = _countryFocusNode.hasFocus;
      });
    });
    
    _cityFocusNode.addListener(() {
      setState(() {
        _cityFocused = _cityFocusNode.hasFocus;
      });
    });
  }

  @override
  void dispose() {
    _countryFocusNode.dispose();
    _cityFocusNode.dispose();
    _locationController.dispose();
    _cityController.dispose();
    super.dispose();
  }

  Future<void> _initializeLocationService() async {
    final locationService = Provider.of<LocationService>(context, listen: false);
    await locationService.initialize();
    
    if (mounted) {
      setState(() {
        _isInitialized = true;
        if (locationService.selectedCountry != null) {
          _locationController.text = locationService.selectedCountry!;
        }
        if (locationService.selectedCity != null) {
          _cityController.text = locationService.selectedCity!['name'] ?? '';
        }
      });
    }
  }

  void _onLocationChanged(String value) async {
    final locationService = Provider.of<LocationService>(context, listen: false);
    
    if (!locationService.isInitialized) {
      return;
    }
    
    final results = await locationService.searchCountries(value);
    
    if (mounted) {
      setState(() {
        _suggestions = results;
        _showSuggestions = value.isNotEmpty && results.isNotEmpty;
      });
    }
  }

  void _onLocationSelected(String location) {
    setState(() {
      _locationController.text = location;
      _showSuggestions = false;
      _cityController.clear();
      _showCitySuggestions = false;
    });
    
    _countryFocusNode.unfocus();
    
    final locationService = Provider.of<LocationService>(context, listen: false);
    
    try {
      locationService.clearSelectedCity();
      locationService.setSelectedCountry(location);
      
      if (widget.onLocationChanged != null) {
        widget.onLocationChanged!();
      }
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Country updated to $location'),
          backgroundColor: Theme.of(context).primaryColor,
          duration: Duration(seconds: 2),
        ),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error updating country. Please try again.'),
          backgroundColor: Colors.red,
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  void _onCityChanged(String value) {
    final locationService = Provider.of<LocationService>(context, listen: false);
    
    if (!locationService.isInitialized || locationService.selectedCountry == null) {
      return;
    }
    
    _performCitySearch(value, locationService);
  }
  
  void _performCitySearch(String value, LocationService locationService) async {
    final results = await locationService.searchCitiesInCountry(value, locationService.selectedCountry!);
    
    if (mounted) {
      setState(() {
        _citySuggestions = results;
        _showCitySuggestions = value.isNotEmpty && results.isNotEmpty;
      });
    }
  }

  void _onCitySelected(Map<String, dynamic> city) {
    setState(() {
      _cityController.text = city['display_name'] ?? city['name'];
      _showCitySuggestions = false;
    });
    
    _cityFocusNode.unfocus();
    
    final locationService = Provider.of<LocationService>(context, listen: false);
    
    try {
      if (city['id'] == null) {
        throw Exception('Selected city is missing ID');
      }
      
      final cityForStorage = Map<String, dynamic>.from(city);
      
      locationService.setSelectedCity(cityForStorage);
      
      // Add to location history
      final userService = Provider.of<UserService>(context, listen: false);
      userService.addLocationToHistory({
        'country': cityForStorage['country_name_en'],
        'city': cityForStorage['name'],
        'cityObject': cityForStorage,
      });
      
      if (widget.onLocationChanged != null) {
        widget.onLocationChanged!();
      }
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('City updated to ${cityForStorage['name']} • You\'re all set!'),
          backgroundColor: Theme.of(context).primaryColor,
          duration: Duration(seconds: 2),
        ),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error updating city. Please try again.'),
          backgroundColor: Colors.red,
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  String _formatPopulation(int population) {
    if (population >= 1000000) {
      return '${(population / 1000000).toStringAsFixed(1)}M';
    } else if (population >= 1000) {
      return '${(population / 1000).toStringAsFixed(0)}K';
    } else {
      return population.toString();
    }
  }

  Widget _buildGuidancePrompt() {
    if (!widget.showGuidancePrompts) return SizedBox.shrink();
    
    return Consumer<LocationService>(
      builder: (context, locationService, child) {
        final isAuthenticated = Supabase.instance.client.auth.currentUser != null;
        final hasCountry = locationService.selectedCountry != null;
        final hasCity = locationService.selectedCity != null;
        
        if (!isAuthenticated || (hasCountry && hasCity)) {
          return SizedBox.shrink();
        }
        
        String title;
        String description;
        
        if (!hasCountry) {
          title = 'Welcome!';
          description = 'Please set your location to participate in Read The Room.';
        } else if (!hasCity) {
          title = 'Almost there! 🦎';
          description = 'Set your city to join the conversation.';
        } else {
          return SizedBox.shrink();
        }
        
        return Container(
          margin: EdgeInsets.only(bottom: 20),
          padding: EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Theme.of(context).brightness == Brightness.dark
                ? Colors.orange.shade900.withOpacity(0.3)
                : Colors.orange.shade50,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: Theme.of(context).brightness == Brightness.dark
                  ? Colors.orange.shade700.withOpacity(0.6)
                  : Colors.orange.shade300,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.location_on,
                    color: Theme.of(context).brightness == Brightness.dark
                        ? Colors.orange.shade400
                        : Colors.orange.shade600,
                    size: 24,
                  ),
                  SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      title,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        color: Theme.of(context).brightness == Brightness.dark
                            ? Colors.orange.shade300
                            : Colors.orange.shade800,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
              SizedBox(height: 8),
              Text(
                description,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).brightness == Brightness.dark
                      ? Colors.white
                      : Colors.grey[600],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Title
        if (widget.showTitle)
          Padding(
            padding: EdgeInsets.only(bottom: 12),
            child: Text(
              'Location',
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ),

        // Guidance prompt
        _buildGuidancePrompt(),

        // Country suggestions dropdown
        if (Supabase.instance.client.auth.currentUser != null && _showSuggestions && _suggestions.isNotEmpty)
          Container(
            margin: EdgeInsets.only(bottom: 4),
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
              itemCount: _suggestions.length,
              itemBuilder: (context, index) {
                return ListTile(
                  dense: true,
                  title: Text(_suggestions[index]),
                  onTap: () => _onLocationSelected(_suggestions[index]),
                );
              },
            ),
          ),

        // Country field
        Consumer<LocationService>(
          builder: (context, locationService, child) {
            final isAuthenticated = Supabase.instance.client.auth.currentUser != null;
            final hasCountry = isAuthenticated ? (locationService.selectedCountry != null) : false;
            
            // Clear location fields if user is not authenticated
            if (!isAuthenticated && _locationController.text.isNotEmpty) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                _locationController.clear();
                _cityController.clear();
              });
            }
            
            // Update controller text when LocationService changes, but only if user isn't typing
            if (isAuthenticated && !_countryFocused && locationService.selectedCountry != null) {
              if (_locationController.text != locationService.selectedCountry!) {
                _locationController.text = locationService.selectedCountry!;
              }
            } else if (isAuthenticated && !_countryFocused && locationService.selectedCountry == null) {
              if (_locationController.text.isNotEmpty) {
                _locationController.clear();
              }
            }
            
            return Column(
              children: [
                // Authentication prompt for country field
                if (!isAuthenticated)
                  Container(
                    margin: EdgeInsets.only(bottom: 20),
                    padding: EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Theme.of(context).brightness == Brightness.dark
                          ? Colors.orange.shade900.withOpacity(0.3)
                          : Colors.orange.shade50,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: Theme.of(context).brightness == Brightness.dark
                            ? Colors.orange.shade700.withOpacity(0.6)
                            : Colors.orange.shade300,
                      ),
                    ),
                    child: GestureDetector(
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) => AuthenticationScreen(),
                          ),
                        );
                      },
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(
                                Icons.warning_amber_rounded,
                                color: Theme.of(context).brightness == Brightness.dark
                                    ? Colors.orange.shade400
                                    : Colors.orange.shade600,
                                size: 24,
                              ),
                              SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  'Are you human?',
                                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                                    color: Theme.of(context).brightness == Brightness.dark
                                        ? Colors.orange.shade300
                                        : Colors.orange.shade800,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              Icon(
                                Icons.arrow_forward_ios,
                                color: Theme.of(context).brightness == Brightness.dark
                                    ? Colors.orange.shade400
                                    : Colors.orange.shade600,
                                size: 16,
                              ),
                            ],
                          ),
                          SizedBox(height: 8),
                          Text(
                            'Authenticating as human allows you to anonymously participate in Read The Room.',
                            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: Theme.of(context).brightness == Brightness.dark
                                  ? Colors.white
                                  : Colors.grey[600],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                Padding(
                  padding: EdgeInsets.symmetric(vertical: 8.0),
                  child: TextField(
                    controller: _locationController,
                    focusNode: _countryFocusNode,
                    decoration: InputDecoration(
                      labelText: 'Set your country',
                      labelStyle: TextStyle(
                        color: !isAuthenticated ? Colors.grey : (Theme.of(context).brightness == Brightness.dark ? Colors.white : Colors.black),
                      ),
                      floatingLabelStyle: TextStyle(
                        color: !isAuthenticated 
                            ? Colors.grey
                            : (_countryFocused 
                                ? (hasCountry ? Theme.of(context).primaryColor : Colors.orange)
                                : (hasCountry ? (Theme.of(context).brightness == Brightness.dark ? Colors.white : Colors.black) : Colors.orange)),
                      ),
                      hintText: !isAuthenticated ? 'Authentication required' : 'Enter country name',
                      prefixIcon: Icon(
                        Icons.location_on,
                        color: !isAuthenticated ? Colors.grey : null,
                      ),
                      border: OutlineInputBorder(
                        borderSide: BorderSide(
                          color: !isAuthenticated 
                              ? Colors.grey
                              : (!hasCountry ? Colors.orange : (Theme.of(context).brightness == Brightness.dark ? Colors.white : Colors.black)),
                          width: (!isAuthenticated || hasCountry) ? 1.0 : 2.0,
                        ),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderSide: BorderSide(
                          color: !isAuthenticated 
                              ? Colors.grey
                              : (!hasCountry ? Colors.orange : (Theme.of(context).brightness == Brightness.dark ? Colors.white : Colors.black)),
                          width: (!isAuthenticated || hasCountry) ? 1.0 : 2.0,
                        ),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderSide: BorderSide(
                          color: !isAuthenticated 
                              ? Colors.grey
                              : (!hasCountry ? Colors.orange : Theme.of(context).primaryColor),
                          width: 2.0,
                        ),
                      ),
                      suffixIcon: (isAuthenticated && hasCountry)
                          ? IconButton(
                              icon: Icon(Icons.clear, color: Colors.grey),
                              onPressed: () {
                                setState(() {
                                  _locationController.clear();
                                  _showSuggestions = false;
                                  _cityController.clear();
                                  _showCitySuggestions = false;
                                });
                                locationService.clearSelectedCountry();
                                locationService.clearSelectedCity();
                                if (widget.onLocationChanged != null) {
                                  widget.onLocationChanged!();
                                }
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text('Country and city selection cleared'),
                                    backgroundColor: Theme.of(context).primaryColor,
                                    duration: Duration(seconds: 1),
                                  ),
                                );
                              },
                            )
                          : null,
                    ),
                    onChanged: isAuthenticated ? _onLocationChanged : null,
                    enabled: isAuthenticated && _isInitialized,
                    onTap: !isAuthenticated ? () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => AuthenticationScreen(),
                        ),
                      );
                    } : null,
                  ),
                ),
              ],
            );
          },
        ),

        // City field
        Consumer<LocationService>(
          builder: (context, locationService, child) {
            final isAuthenticated = Supabase.instance.client.auth.currentUser != null;
            final hasCountry = isAuthenticated ? (locationService.selectedCountry != null) : false;
            final hasCity = isAuthenticated ? (locationService.selectedCity != null) : false;
            
            // Update city controller text when LocationService changes, but only if user isn't typing
            if (isAuthenticated && !_cityFocused && locationService.selectedCity != null) {
              final selectedCityName = locationService.selectedCity!['name'] ?? '';
              if (_cityController.text != selectedCityName) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  _cityController.text = selectedCityName;
                });
              }
            } else if (isAuthenticated && !_cityFocused && locationService.selectedCity == null) {
              if (_cityController.text.isNotEmpty) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  _cityController.clear();
                });
              }
            }
            
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Show "Type more letters" when user has typed 1-2 characters
                if (isAuthenticated &&
                    _cityController.text.isNotEmpty && 
                    _cityController.text.length < 3 && 
                    hasCountry &&
                    !hasCity)
                  Container(
                    margin: EdgeInsets.only(bottom: 4),
                    decoration: BoxDecoration(
                      color: ThemeUtils.getDropdownBackgroundColor(context),
                      borderRadius: BorderRadius.circular(4),
                      boxShadow: ThemeUtils.getDropdownShadow(context),
                    ),
                    child: ListTile(
                      dense: true,
                      leading: Icon(Icons.search, size: 16, color: Colors.grey),
                      title: Text(
                        'Type ${3 - _cityController.text.length} more letter${3 - _cityController.text.length == 1 ? '' : 's'} to search cities',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Colors.grey[600]),
                      ),
                      subtitle: Text(
                        'This helps find the exact city you\'re looking for',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.grey[500]),
                      ),
                    ),
                  ),
                
                // City suggestions dropdown
                if (isAuthenticated && _showCitySuggestions && _citySuggestions.isNotEmpty)
                  Container(
                    margin: EdgeInsets.only(bottom: 4),
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
                      itemCount: _citySuggestions.length,
                      itemBuilder: (context, index) {
                        final city = _citySuggestions[index];
                        final populationText = city['population'] != null && city['population'] > 0
                            ? ' • ${_formatPopulation(city['population'])}'
                            : '';
                        
                        return ListTile(
                          dense: true,
                          leading: Icon(Icons.location_city, size: 16),
                          title: Text(city['name']),
                          subtitle: Text('${city['country_name_en']}$populationText'),
                          onTap: () => _onCitySelected(city),
                        );
                      },
                    ),
                  ),
                
                // Show "City not found" when search has 3+ characters but no results AND user doesn't already have a city
                if (isAuthenticated &&
                    _cityController.text.length >= 3 && 
                    !_showCitySuggestions && 
                    _citySuggestions.isEmpty &&
                    hasCountry &&
                    !hasCity)
                  Container(
                    margin: EdgeInsets.only(bottom: 4),
                    decoration: BoxDecoration(
                      color: ThemeUtils.getDropdownBackgroundColor(context),
                      borderRadius: BorderRadius.circular(4),
                      boxShadow: ThemeUtils.getDropdownShadow(context),
                    ),
                    child: Column(
                      children: [
                        ListTile(
                          dense: true,
                          leading: Icon(Icons.search_off, size: 16, color: Colors.grey),
                          title: Text(
                            'City not found in ${locationService.selectedCountry}',
                            style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Colors.grey[600]),
                          ),
                          subtitle: Text(
                            'Try selecting from available cities below',
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.grey[500]),
                          ),
                        ),
                        
                        // Show available cities in this country
                        FutureBuilder<List<Map<String, dynamic>>>(
                          future: locationService.getAvailableCitiesForCountry(
                            locationService.selectedCountry!
                          ),
                          builder: (context, snapshot) {
                            if (snapshot.connectionState == ConnectionState.waiting) {
                              return ListTile(
                                dense: true,
                                leading: SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                ),
                                title: Text(
                                  'Loading available cities...',
                                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Colors.grey[600]),
                                ),
                              );
                            }
                            
                            final availableCities = snapshot.data ?? [];
                            
                            if (availableCities.isEmpty) {
                              return ListTile(
                                dense: true,
                                leading: Icon(Icons.info_outline, size: 16, color: Colors.orange),
                                title: Text(
                                  'No cities available for ${locationService.selectedCountry}',
                                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Colors.orange[600]),
                                ),
                                subtitle: Text(
                                  'You can still use country-level targeting for questions',
                                  style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.orange[400]),
                                ),
                              );
                            }
                            
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Padding(
                                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                                  child: Text(
                                    'Available cities (${availableCities.length}):',
                                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                      color: Theme.of(context).primaryColor,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ),
                                ...availableCities.take(5).map((city) => ListTile(
                                  dense: true,
                                  leading: Icon(Icons.location_city, size: 16),
                                  title: Text(city['name']),
                                  subtitle: city['population'] != null && city['population'] > 0
                                      ? Text('${_formatPopulation(city['population'])} people')
                                      : null,
                                  onTap: () => _onCitySelected(city),
                                )).toList(),
                                if (availableCities.length > 5)
                                  Padding(
                                    padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                                    child: Text(
                                      '... and ${availableCities.length - 5} more',
                                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                        color: Colors.grey[500],
                                        fontStyle: FontStyle.italic,
                                      ),
                                    ),
                                  ),
                              ],
                            );
                          },
                        ),
                      ],
                    ),
                  ),

                Padding(
                  padding: EdgeInsets.symmetric(vertical: 8.0),
                  child: TextField(
                    controller: _cityController,
                    focusNode: _cityFocusNode,
                    decoration: InputDecoration(
                      labelText: 'Set your city',
                      labelStyle: TextStyle(
                        color: !isAuthenticated ? Colors.grey : (Theme.of(context).brightness == Brightness.dark ? Colors.white : Colors.black),
                      ),
                      floatingLabelStyle: TextStyle(
                        color: !isAuthenticated
                            ? Colors.grey
                            : (_cityFocused
                                ? (hasCity ? Theme.of(context).primaryColor : (hasCountry ? Colors.orange : Colors.grey))
                                : (hasCity ? (Theme.of(context).brightness == Brightness.dark ? Colors.white : Colors.black) : (hasCountry ? Colors.orange : Colors.grey))),
                      ),
                      hintText: !isAuthenticated
                          ? 'Authentication required'
                          : (hasCountry 
                              ? 'Search cities in ${locationService.selectedCountry}'
                              : 'Select a country first'),
                      prefixIcon: Icon(
                        Icons.location_city,
                        color: !isAuthenticated ? Colors.grey : null,
                      ),
                      border: OutlineInputBorder(
                        borderSide: BorderSide(
                          color: !isAuthenticated
                              ? Colors.grey
                              : ((hasCountry && !hasCity) ? Colors.orange : (Theme.of(context).brightness == Brightness.dark ? Colors.white : Colors.black)),
                          width: (!isAuthenticated || hasCity || !hasCountry) ? 1.0 : 2.0,
                        ),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderSide: BorderSide(
                          color: !isAuthenticated
                              ? Colors.grey
                              : ((hasCountry && !hasCity) ? Colors.orange : (Theme.of(context).brightness == Brightness.dark ? Colors.white : Colors.black)),
                          width: (!isAuthenticated || hasCity || !hasCountry) ? 1.0 : 2.0,
                        ),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderSide: BorderSide(
                          color: !isAuthenticated
                              ? Colors.grey
                              : ((hasCountry && !hasCity) ? Colors.orange : Theme.of(context).primaryColor),
                          width: 2.0,
                        ),
                      ),
                      suffixIcon: (isAuthenticated && hasCity)
                          ? IconButton(
                              icon: Icon(Icons.clear, color: Colors.grey),
                              onPressed: () {
                                setState(() {
                                  _cityController.clear();
                                  _showCitySuggestions = false;
                                });
                                locationService.clearSelectedCity();
                                if (widget.onLocationChanged != null) {
                                  widget.onLocationChanged!();
                                }
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text('City selection cleared'),
                                    backgroundColor: Theme.of(context).primaryColor,
                                    duration: Duration(seconds: 1),
                                  ),
                                );
                              },
                            )
                          : null,
                    ),
                    onChanged: isAuthenticated ? _onCityChanged : null,
                    enabled: isAuthenticated && _isInitialized && hasCountry,
                    onTap: !isAuthenticated ? () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => AuthenticationScreen(),
                        ),
                      );
                    } : null,
                  ),
                ),
              ],
            );
          },
        ),
        
        // Description - only show when city is not set
        Consumer<LocationService>(
          builder: (context, locationService, child) {
            final hasCity = locationService.selectedCity != null;
            
            if (widget.showDescription && !hasCity)
              return Padding(
                padding: EdgeInsets.only(top: 16),
                child: Text(
                  'Setting your location allows us to serve a feed relevant to your community. Your information stays on-device, and is only transmitted when you submit a response. This keeps your responses anonymous as you are voting on behalf of a city and not as an individual.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Colors.grey[600],
                  ),
                ),
              );
            
            return SizedBox.shrink();
          },
        ),
      ],
    );
  }
}
