// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import '../services/room_service.dart';
import '../models/room.dart';
import 'package:provider/provider.dart';
import '../services/user_service.dart';

class CountryComparisonDialog extends StatefulWidget {
  final Map<String, Map<String, dynamic>> countryResponses;
  final Function(String, String) onCompare;
  final String questionTitle;
  final String questionId;
  final String questionType;
  final Map<String, double>? countryAverages;
  final List<Map<String, dynamic>>? allResponses; // All responses for room counting
  final Map<String, int>? roomResponseCounts;
  final int? myNetworkResponseCount;
  final Map<String, String>? roomNames;

  const CountryComparisonDialog({
    Key? key,
    required this.countryResponses,
    required this.onCompare,
    required this.questionTitle,
    required this.questionId,
    required this.questionType,
    this.countryAverages,
    this.allResponses,
    this.roomResponseCounts,
    this.myNetworkResponseCount,
    this.roomNames,
  }) : super(key: key);

  static Future<List<String>?> show({
    required BuildContext context,
    required Map<String, Map<String, dynamic>> countryResponses,
    required String questionTitle,
    required String questionId,
    required String questionType,
    Map<String, double>? countryAverages,
    List<Map<String, dynamic>>? allResponses,
    Map<String, int>? roomResponseCounts,
    int? myNetworkResponseCount,
    Map<String, String>? roomNames,
  }) {
    return showDialog<List<String>?>(
      context: context,
      builder: (context) => CountryComparisonDialog(
        countryResponses: countryResponses,
        questionTitle: questionTitle,
        questionId: questionId,
        questionType: questionType,
        countryAverages: countryAverages,
        allResponses: allResponses,
        roomResponseCounts: roomResponseCounts,
        myNetworkResponseCount: myNetworkResponseCount,
        roomNames: roomNames,
        onCompare: (country1, country2) {
          Navigator.of(context).pop([country1, country2]);
        },
      ),
    );
  }

  @override
  State<CountryComparisonDialog> createState() => _CountryComparisonDialogState();
}

class _CountryComparisonDialogState extends State<CountryComparisonDialog> {
  String? _selectedCountry1;
  String? _selectedCountry2;
  String _searchQuery = '';
  late List<String> _sortedCountries;
  List<Room> _userRooms = [];
  bool _isLoadingRooms = true;
  Map<String, int> _roomResponseCounts = {};
  int _myNetworkResponseCount = 0;

  @override
  void initState() {
    super.initState();
    _sortedCountries = widget.countryResponses.entries
        .map((e) => e.key)
        .toList()
      ..sort((a, b) {
        final aTotal = widget.countryResponses[a]?['total'] as int? ?? 0;
        final bTotal = widget.countryResponses[b]?['total'] as int? ?? 0;
        return bTotal.compareTo(aTotal);
      });
    
    // Add "World" as an option for comparison
    _sortedCountries.insert(0, 'World');
    _loadUserRooms();
  }

  Future<void> _loadUserRooms() async {
    try {
      // Use passed data if available, otherwise fetch from service
      if (widget.roomResponseCounts != null && widget.roomNames != null) {
        // Use pre-loaded data for instant display
        final roomCounts = widget.roomResponseCounts!;
        final networkTotal = widget.myNetworkResponseCount ?? 0;
        
        // Create Room objects from passed data
        final rooms = roomCounts.entries.map((entry) {
          final roomId = entry.key;
          final roomName = widget.roomNames![roomId] ?? 'Room';
          return Room(
            id: roomId,
            name: roomName,
            description: '',
            avatarUrl: null,
            inviteCode: roomId, // Placeholder
            inviteCodeActive: true,
            memberCount: 5, // Assume unlocked since it has responses
            nsfwEnabled: false,
            rqiScore: null,
            globalRank: null,
            createdBy: null,
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          );
        }).toList();
        
        if (mounted) {
          setState(() {
            _userRooms = rooms;
            _roomResponseCounts = roomCounts;
            _myNetworkResponseCount = networkTotal;
            _isLoadingRooms = false;
          });
        }
      } else {
        // Fallback to fetching rooms if data not provided
        final roomService = RoomService();
        final rooms = await roomService.getUserRooms();
        
        if (mounted) {
          setState(() {
            _userRooms = rooms;
            _roomResponseCounts = {};
            _myNetworkResponseCount = 0;
            _isLoadingRooms = false;
          });
        }
      }
    } catch (e) {
      print('Error loading user rooms: $e');
      if (mounted) {
        setState(() {
          _isLoadingRooms = false;
        });
      }
    }
  }

  bool get _hasActiveUnlockedRoom {
    return _userRooms.any((room) => room.isUnlocked);
  }

  bool get _hasEnoughNetworkResponses {
    return _myNetworkResponseCount >= 5;
  }

  bool get _shouldShowMyNetwork {
    return _hasActiveUnlockedRoom && _hasEnoughNetworkResponses;
  }

  bool get _shouldShowMyNetworkGreyed {
    return _hasActiveUnlockedRoom && !_hasEnoughNetworkResponses;
  }

  String get _myNetworkSnackbarMessage {
    if (!_hasActiveUnlockedRoom) {
      return 'Create or join a room to build your network!';
    } else if (!_hasEnoughNetworkResponses) {
      return 'Not enough responses from your network';
    }
    return '';
  }

  // Get display name for selected country/room/network
  String _getDisplayName(String? selection) {
    if (selection == null) return 'Select';
    if (selection == 'My Network') return 'My Network';
    if (selection == 'World') return 'World';
    if (selection.startsWith('Room:')) {
      final roomId = selection.substring(5);
      return widget.roomNames?[roomId] ?? 'Room';
    }
    return selection; // Regular country name
  }


  Color _getColorForValue(double value) {
    final normalizedValue = (value + 1) / 2;
    
    if (normalizedValue < 0.2) {
      return Colors.red;
    } else if (normalizedValue < 0.4) {
      return Colors.red[300]!;
    } else if (normalizedValue < 0.6) {
      return Colors.grey.shade300;
    } else if (normalizedValue < 0.8) {
      return Colors.lightGreen;
    } else {
      return Colors.green;
    }
  }

  Color _getCountryColor(String countryName) {
    // Handle World option specially
    if (countryName == 'World') {
      final totalResponsesGlobal = widget.countryResponses.values.fold<int>(0, 
        (sum, data) => sum + (data['total'] as int? ?? 0));
      
      if (widget.questionType == 'approval' && widget.countryAverages != null) {
        // Calculate weighted global average from country averages
        double totalWeightedValue = 0;
        int totalResponsesFromAverages = 0;
        
        widget.countryAverages!.forEach((country, average) {
          final countryResponseCount = widget.countryResponses[country]?['total'] as int? ?? 0;
          totalWeightedValue += average * countryResponseCount;
          totalResponsesFromAverages += countryResponseCount;
        });
        
        if (totalResponsesFromAverages > 0) {
          final globalAverage = totalWeightedValue / totalResponsesFromAverages;
          return _getColorForValue(globalAverage);
        }
      }
      
      return totalResponsesGlobal > 3 
          ? Theme.of(context).primaryColor
          : Colors.grey[400]!;
    }
    
    if (widget.questionType == 'approval' && widget.countryAverages != null) {
      final average = widget.countryAverages![countryName];
      if (average != null) {
        return _getColorForValue(average);
      }
    }
    
    final responseCount = widget.countryResponses[countryName]?['total'] as int? ?? 0;
    return responseCount > 3 
        ? Theme.of(context).primaryColor
        : Colors.grey[400]!;
  }

  // Get colors that will be used in the comparison plot
  Color _getComparisonColor(bool isCountry1) {
    if (isCountry1) {
      // Country 1 color based on theme (matches approval_results_screen logic)
      return Theme.of(context).brightness == Brightness.light 
          ? Theme.of(context).primaryColor 
          : Color(0xFF55C5B4);
    } else {
      // Country 2 color
      return Color(0xFFFF6569);
    }
  }

  @override
  Widget build(BuildContext context) {
    final totalResponsesGlobal = widget.countryResponses.values.fold<int>(0, 
      (sum, data) => sum + (data['total'] as int? ?? 0));

    return AlertDialog(
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Compare'),
          SizedBox(height: 4),
          Text(
            widget.questionTitle.length > 50 
                ? '${widget.questionTitle.substring(0, 50)}...'
                : widget.questionTitle,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Colors.grey[600],
            ),
          ),
        ],
      ),
      content: Container(
        width: double.maxFinite,
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.7,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Selected countries display
            Container(
              padding: EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context).primaryColor.withOpacity(0.05),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: Theme.of(context).primaryColor.withOpacity(0.2),
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      children: [
                        Text(
                          'Room 1',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey[600],
                          ),
                        ),
                        SizedBox(height: 4),
                        Text(
                          _getDisplayName(_selectedCountry1),
                          style: TextStyle(
                            fontWeight: _selectedCountry1 != null ? FontWeight.bold : null,
                            color: _selectedCountry1 != null 
                                ? _getComparisonColor(true)
                                : Colors.grey[400],
                          ),
                        ),
                      ],
                    ),
                  ),
                  Icon(
                    Icons.compare_arrows,
                    color: Theme.of(context).primaryColor,
                  ),
                  Expanded(
                    child: Column(
                      children: [
                        Text(
                          'Room 2',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey[600],
                          ),
                        ),
                        SizedBox(height: 4),
                        Text(
                          _getDisplayName(_selectedCountry2),
                          style: TextStyle(
                            fontWeight: _selectedCountry2 != null ? FontWeight.bold : null,
                            color: _selectedCountry2 != null 
                                ? _getComparisonColor(false)
                                : Colors.grey[400],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            
            SizedBox(height: 16),
            
            // World option (always visible at top)
            _buildCountryOption(
              countryName: 'World',
              responseCount: totalResponsesGlobal,
              percentage: 100,
              subtitle: 'All responses ($totalResponsesGlobal)',
            ),
            
            // My Network option
            if (!_isLoadingRooms) ...[
              _buildMyNetworkOption(),
            ],
            
            // Divider between fixed options and searchable content
            Divider(),
            
            SizedBox(height: 8),
            
            // Search bar for rooms and countries
            if (_sortedCountries.isNotEmpty || _userRooms.isNotEmpty) ...[
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 8),
                child: TextField(
                  decoration: InputDecoration(
                    hintText: 'Search...',
                    prefixIcon: Icon(Icons.search),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8.0),
                    ),
                    contentPadding: EdgeInsets.symmetric(vertical: 8.0),
                  ),
                  onChanged: (value) {
                    setState(() {
                      _searchQuery = value;
                    });
                  },
                ),
              ),
              SizedBox(height: 12),
            ],
            
            // Combined list: Top 3 rooms (on top) + Top 5 countries (below)
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  // Top 3 rooms with >5 responses
                  ..._buildTopRoomsList(),
                  
                  // Top 5 countries
                  ..._buildTopCountriesList(totalResponsesGlobal),
                ],
              ),
            ),
            
            SizedBox(height: 16),
            
            // Compare button
            Center(
              child: ElevatedButton(
                onPressed: (_selectedCountry1 != null && _selectedCountry2 != null)
                    ? () {
                        widget.onCompare(_selectedCountry1!, _selectedCountry2!);
                      }
                    : null,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Theme.of(context).primaryColor,
                  foregroundColor: Colors.white,
                  padding: EdgeInsets.symmetric(horizontal: 40, vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(24),
                  ),
                ),
                child: Text(
                  'Compare',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text('Cancel'),
        ),
      ],
    );
  }

  Widget _buildCountryOption({
    required String countryName,
    required int responseCount,
    required int percentage,
    required String subtitle,
    bool isEnabled = true,
    String? displayName,
    VoidCallback? onTapOverride,
  }) {
    final isSelected = _selectedCountry1 == countryName || _selectedCountry2 == countryName;
    final isCountry1 = _selectedCountry1 == countryName;
    final effectiveDisplayName = displayName ?? countryName;
    
    return InkWell(
      onTap: onTapOverride ?? (isEnabled ? () {
        setState(() {
          if (_selectedCountry1 == countryName) {
            _selectedCountry1 = null;
          } else if (_selectedCountry2 == countryName) {
            _selectedCountry2 = null;
          } else if (_selectedCountry1 == null) {
            _selectedCountry1 = countryName;
          } else if (_selectedCountry2 == null) {
            _selectedCountry2 = countryName;
          } else {
            // Replace the first selection
            _selectedCountry1 = countryName;
          }
        });
      } : null),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: EdgeInsets.symmetric(vertical: 12, horizontal: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          color: isSelected && isEnabled
              ? Theme.of(context).primaryColor.withOpacity(0.1)
              : null,
        ),
        child: Row(
          children: [
            Container(
              width: 20,
              height: 20,
              decoration: BoxDecoration(
                color: isEnabled 
                  ? _getCountryColor(countryName)
                  : Colors.grey[400]!,
                shape: BoxShape.circle,
              ),
            ),
            SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    effectiveDisplayName,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      color: isEnabled
                        ? (isSelected 
                            ? Theme.of(context).primaryColor 
                            : null)
                        : Colors.grey[500],
                      fontWeight: isSelected && isEnabled ? FontWeight.bold : null,
                    ),
                  ),
                  SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: isEnabled ? Colors.grey[600] : Colors.grey[400],
                    ),
                  ),
                ],
              ),
            ),
            if (isSelected && isEnabled)
              Container(
                padding: EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: Theme.of(context).primaryColor,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  isCountry1 ? '1' : '2',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildMyNetworkOption() {
    final isEnabled = _shouldShowMyNetwork;
    final isGreyed = _shouldShowMyNetworkGreyed;
    final isVisible = isEnabled || isGreyed;
    
    if (!isVisible) return SizedBox.shrink();
    
    return _buildCountryOption(
      countryName: 'My Network',
      responseCount: _myNetworkResponseCount,
      percentage: 0, // Not used for My Network
      subtitle: 'Your room network',
      isEnabled: isEnabled,
      onTapOverride: isEnabled ? null : () {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_myNetworkSnackbarMessage),
            backgroundColor: Colors.orange,
            duration: Duration(seconds: 3),
            behavior: SnackBarBehavior.floating,
            margin: EdgeInsets.only(
              bottom: MediaQuery.of(context).size.height * 0.8,
              left: 16,
              right: 16,
            ),
          ),
        );
      },
    );
  }

  List<Widget> _buildTopRoomsList() {
    // Get top 3 rooms with >5 responses, filtered by search
    final roomsWithEnoughResponses = _userRooms.where((room) {
      final responseCount = _roomResponseCounts[room.id] ?? 0;
      return responseCount >= 5;
    }).toList();
    
    // Sort by response count (highest first)
    roomsWithEnoughResponses.sort((a, b) {
      final aCount = _roomResponseCounts[a.id] ?? 0;
      final bCount = _roomResponseCounts[b.id] ?? 0;
      return bCount.compareTo(aCount);
    });
    
    // Filter by search query
    final filteredRooms = _searchQuery.isEmpty 
        ? roomsWithEnoughResponses
        : roomsWithEnoughResponses.where((room) {
            return room.name.toLowerCase().contains(_searchQuery.toLowerCase());
          }).toList();
    
    // Take top 3
    final topRooms = filteredRooms.take(3).toList();
    
    return topRooms.map((room) {
      final responseCount = _roomResponseCounts[room.id] ?? 0;
      return _buildCountryOption(
        countryName: 'Room:${room.id}',
        responseCount: responseCount,
        percentage: 0, // Not used for rooms
        subtitle: '${room.name} ($responseCount responses)',
        isEnabled: true, // All rooms shown are enabled (>=5 responses)
        displayName: room.name,
      );
    }).toList();
  }

  List<Widget> _buildTopCountriesList(int totalResponsesGlobal) {
    // Get countries excluding World
    final countriesWithoutWorld = _sortedCountries.where((country) => country != 'World').toList();
    
    // Filter countries by search query
    final filteredCountries = _searchQuery.isEmpty 
        ? countriesWithoutWorld
        : countriesWithoutWorld.where((country) {
            return country.toLowerCase().contains(_searchQuery.toLowerCase());
          }).toList();
    
    // Take top 5 countries
    final topCountries = filteredCountries.take(5).toList();
    
    return topCountries.map((country) {
      final data = widget.countryResponses[country];
      final total = data?['total'] as int? ?? 0;
      final percentage = totalResponsesGlobal > 0 ? (total / totalResponsesGlobal * 100).round() : 0;
      
      return _buildCountryOption(
        countryName: country,
        responseCount: total,
        percentage: percentage,
        subtitle: '$percentage% ($total responses)',
      );
    }).toList();
  }
}